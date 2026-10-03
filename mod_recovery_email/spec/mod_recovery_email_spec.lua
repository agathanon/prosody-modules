-- Unit tests for mod_recovery_email, run outside Prosody with stubbed APIs
local module_path = debug.getinfo(1, "S").source:match("^@(.-)spec/[^/]*$").."mod_recovery_email.lua";

local function new_store()
	local data = {};
	return {
		data = data;
		get = function (_, key) return data[key]; end;
		set = function (_, key, value) data[key] = value; return true; end;
	};
end

-- Load a fresh instance of the module; returns its environment and the stubs
local function load_module()
	local store = new_store();
	local accounts = { alice = { created = 1000 } };
	local events, hooks, items, logs = {}, {}, {}, {};
	local throttle_state = { allow = true, polls = 0 };

	local stubs = {
		["prosody.util.adhoc"] = {
			new_initial_data_form = function (_, initial, result)
				return { initial = initial, result = result };
			end;
		};
		["prosody.util.cache"] = {
			new = function ()
				local t = {};
				return { get = function (_, k) return t[k]; end, set = function (_, k, v) t[k] = v; end };
			end;
		};
		["prosody.util.dataforms"] = { new = function (layout) return layout; end };
		["prosody.util.jid"] = {
			prepped_split = function (jid)
				local node, host = jid:match("^([^@/]+)@([^/]+)");
				if not node then return nil, jid:match("^([^/]+)"); end
				return node, host;
			end;
		};
		["prosody.util.throttle"] = {
			create = function ()
				return {
					peek = function () return throttle_state.allow; end;
					poll = function () throttle_state.polls = throttle_state.polls + 1; return true; end;
				};
			end;
		};
		["prosody.core.usermanager"] = {
			user_exists = function (username) return accounts[username] ~= nil; end;
			get_account_info = function (username) return accounts[username]; end;
		};
		["prosody.util.encodings"] = { utf8 = { valid = function (s) return utf8.len(s) ~= nil; end } };
	};

	local module = {
		host = "localhost";
		name = "recovery_email";
		log = function (_, level, fmt, ...) logs[#logs+1] = level..": "..fmt:format(...); end;
		open_store = function () return store; end;
		require = function () return { new = function (...) return { ... }; end }; end;
		fire_event = function (_, name, payload) events[#events+1] = { name = name, payload = payload }; end;
		hook = function (_, name, handler) hooks[name] = handler; end;
		hook_global = function (_, name, handler) hooks[name] = handler; end;
		default_permission = function () end;
		depends = function () end;
		provides = function (_, kind, item) items[kind] = item; end;
		add_item = function (_, kind, item) items[kind..":"..item.name] = item; end;
	};
	local env = setmetatable({
		module = module;
		require = function (name) return assert(stubs[name], "unexpected require: "..name); end;
	}, { __index = _G });
	assert(loadfile(module_path, "t", env))();

	return env, {
		store = store, accounts = accounts, events = events, hooks = hooks,
		items = items, throttle = throttle_state, logs = logs,
	};
end

describe("mod_recovery_email", function ()
	local env, s;
	before_each(function ()
		env, s = load_module();
	end);

	describe("validate()", function ()
		local function valid(input, expected)
			local result, err = env.validate(input);
			assert.is_nil(err);
			assert.equal(expected or input, result);
		end
		local function invalid(input)
			local result, err = env.validate(input);
			assert.is_nil(result);
			assert.is_string(err);
		end

		it("accepts ordinary addresses", function ()
			valid("user@example.org");
			valid("first.last+tag@mail.example.co.uk");
			valid("ünïcødé@example.org");
		end);

		it("trims surrounding whitespace", function ()
			valid("  user@example.org\t\n", "user@example.org");
		end);

		it("lowercases the domain but not the local part", function ()
			valid("John.Smith@Example.ORG", "John.Smith@example.org");
		end);

		it("rejects empty and non-string input", function ()
			invalid("");
			invalid("   ");
			invalid(nil);
			invalid(42);
		end);

		it("rejects a missing or repeated @", function ()
			invalid("user.example.org");
			invalid("user@@example.org");
			invalid("a@b@example.org");
			invalid("@example.org");
			invalid("user@");
		end);

		it("rejects domains without a dot or with empty labels", function ()
			invalid("user@localhost");
			invalid("a@.");
			invalid("a@b.");
			invalid("a@.b");
			invalid("a@b..c");
		end);

		it("rejects internal whitespace and control characters", function ()
			invalid("us er@example.org");
			invalid("user@exa\tmple.org");
			invalid("user\0@example.org");
			invalid("user\127@example.org");
			invalid("user\u{85}@example.org");
			invalid("user\u{A0}@example.org");
			invalid("user\u{200B}@example.org");
		end);

		it("rejects invalid UTF-8", function ()
			invalid("user\255@example.org");
			invalid("user\192\128@example.org");
		end);

		it("enforces length limits", function ()
			local domain = "@"..("d"):rep(60)..".org";
			valid(("a"):rep(64)..domain);
			invalid(("a"):rep(65)..domain);
			local long_domain = "@"..("d"):rep(63).."."..("e"):rep(63).."."..("f"):rep(63).."."..("g"):rep(60);
			valid("a"..long_domain);
			assert.equal(254, #("a"..long_domain));
			invalid("ab"..long_domain);
		end);
	end);

	describe("set()", function ()
		it("stores a normalized, unverified record and fires an event", function ()
			assert.same({ true, "changed" }, { env.set("alice", " A@Example.org ") });
			local record = s.store.data.alice;
			assert.equal("A@example.org", record.email);
			assert.equal("unverified", record.status);
			assert.equal(1, record.version);
			assert.equal(1000, record.account_created);
			assert.is_number(record.created_at);
			assert.equal(record.created_at, record.updated_at);
			assert.same({ name = "recovery-email-set", payload = {
				username = "alice", host = "localhost", email = "A@example.org",
			} }, s.events[1]);
		end);

		it("changes nothing when the normalized address is the same", function ()
			env.set("alice", "a@example.org");
			local before = s.store.data.alice;
			assert.same({ true, "unchanged" }, { env.set("alice", "a@EXAMPLE.org") });
			assert.equal(before, s.store.data.alice);
			assert.equal(1, #s.events);
		end);

		it("resets verification and keeps created_at on change", function ()
			s.store.data.alice = {
				version = 1, email = "old@example.org", status = "verified", created_at = 5, updated_at = 5,
				verified_at = 6, verify_token_hash = "x", verify_expires = 7, account_created = 1000,
			};
			assert.truthy(env.set("alice", "new@example.org"));
			local record = s.store.data.alice;
			assert.equal("unverified", record.status);
			assert.equal(5, record.created_at);
			assert.is_nil(record.verified_at);
			assert.is_nil(record.verify_token_hash);
			assert.is_nil(record.verify_expires);
			assert.equal("old@example.org", s.events[1].payload.previous_email);
		end);

		it("rejects invalid addresses without touching storage", function ()
			local ok, code = env.set("alice", "nope");
			assert.is_nil(ok);
			assert.equal("bad-request", code);
			assert.is_nil(s.store.data.alice);
			assert.equal(0, #s.events);
		end);

		it("fails for accounts that don't exist", function ()
			local ok, code = env.set("bob", "bob@example.org");
			assert.is_nil(ok);
			assert.equal("item-not-found", code);
			assert.is_nil(s.store.data.bob);
		end);
	end);

	describe("get()", function ()
		it("ignores and deletes records from an earlier account", function ()
			s.store.data.alice = { email = "old@example.org", status = "verified", account_created = 1 };
			assert.is_nil(env.get("alice"));
			assert.is_nil(s.store.data.alice);
		end);

		it("returns nothing for accounts that no longer exist", function ()
			s.store.data.bob = { email = "bob@example.org", status = "unverified" };
			assert.is_nil(env.get("bob"));
		end);
	end);

	describe("clear()", function ()
		it("removes the record and fires an event", function ()
			env.set("alice", "a@example.org");
			assert.same({ true, "removed" }, { env.clear("alice") });
			assert.is_nil(s.store.data.alice);
			assert.same({ name = "recovery-email-cleared", payload = {
				username = "alice", host = "localhost", previous_email = "a@example.org",
			} }, s.events[2]);
		end);

		it("reports when there was nothing to remove", function ()
			assert.same({ true, "absent" }, { env.clear("alice") });
			assert.equal(0, #s.events);
		end);
	end);

	describe("account lifecycle", function ()
		it("removes the record when the account is deleted", function ()
			env.set("alice", "a@example.org");
			s.hooks["user-deleted"]({ username = "alice", host = "localhost" });
			assert.is_nil(s.store.data.alice);
		end);

		it("ignores deletions on other hosts", function ()
			env.set("alice", "a@example.org");
			s.hooks["user-deleted"]({ username = "alice", host = "example.com" });
			assert.is_table(s.store.data.alice);
		end);

		it("removes leftover records on registration", function ()
			s.store.data.alice = { email = "old@example.org" };
			s.hooks["user-registered"]({ username = "alice", host = "localhost" });
			assert.is_nil(s.store.data.alice);
		end);
	end);

	describe("ad-hoc command", function ()
		local function command() return s.items.adhoc[3]; end
		local function submit(fields, from)
			return command().result(fields, nil, { from = from or "alice@localhost/res" });
		end

		it("requires the role-based permission check", function ()
			assert.equal("recovery-email", s.items.adhoc[2]);
			assert.equal("check", s.items.adhoc[4]);
		end);

		it("prefills the form from the current record", function ()
			assert.same({ current = "No recovery email set", email = "", remove = false },
				command().initial({ from = "alice@localhost/res" }));
			env.set("alice", "a@example.org");
			assert.same({ current = "a@example.org (unverified)", email = "a@example.org", remove = false },
				command().initial({ from = "alice@localhost/res" }));
		end);

		it("refuses users of other hosts", function ()
			local values, err = command().initial({ from = "alice@example.com/res" });
			assert.is_nil(values);
			assert.equal("forbidden", err.condition);
			assert.is_table(submit({ email = "a@example.org" }, "alice@example.com/res").error);
			assert.is_nil(s.store.data.alice);
		end);

		it("saves a new address", function ()
			assert.equal("Recovery email saved.", submit({ email = "a@example.org" }).info);
			assert.equal(1, s.throttle.polls);
			assert.same({ "info: Recovery email for alice set to a***@example.org" }, s.logs);
		end);

		it("reports unchanged and empty submissions without using the limit", function ()
			submit({ email = "a@example.org" });
			assert.equal("No changes made.", submit({ email = "a@example.org" }).info);
			assert.equal("No changes made.", submit({ email = "  " }).info);
			assert.equal(1, s.throttle.polls);
		end);

		it("shows validation errors without using the limit", function ()
			assert.is_string(submit({ email = "nope" }).error.message);
			assert.equal(0, s.throttle.polls);
		end);

		it("removes the address, taking precedence over the email field", function ()
			submit({ email = "a@example.org" });
			assert.equal("Recovery email removed.", submit({ email = "b@example.org", remove = true }).info);
			assert.is_nil(s.store.data.alice);
			assert.equal("No recovery email was set.", submit({ remove = true }).info);
			assert.equal(2, s.throttle.polls);
		end);

		it("refuses changes when rate limited", function ()
			s.throttle.allow = false;
			assert.is_string(submit({ email = "a@example.org" }).error.message);
			assert.is_nil(s.store.data.alice);
		end);
	end);

	describe("shell commands", function ()
		local printed;
		local function run(name, ...)
			printed = {};
			local shell = { session = { print = function (line) printed[#printed+1] = line; end } };
			return s.items["shell-command:"..name].handler(shell, ...);
		end

		it("sets, shows and clears through the API", function ()
			assert.same({ true, "Recovery email set" }, { run("set", "alice@localhost", "a@example.org") });
			assert.truthy(run("show", "alice@localhost"));
			assert.equal("Email:       a@example.org", printed[1]);
			assert.same({ true, "Recovery email removed" }, { run("clear", "alice@localhost") });
			assert.equal(2, #s.events);
		end);

		it("are in a section whose name works with 'help'", function ()
			for _, name in ipairs({ "show", "set", "clear" }) do
				assert.equal("recovery", s.items["shell-command:"..name].section);
			end
		end);

		it("marks changes made from the shell in the log", function ()
			run("set", "alice@localhost", "alice@example.org");
			run("clear", "alice@localhost");
			assert.same({
				"info: Recovery email for alice set to a***@example.org (via shell)",
				"info: Recovery email for alice (a***@example.org) removed (via shell)",
			}, s.logs);
		end);

		it("validates input", function ()
			assert.is_nil((run("set", "alice@localhost", "nope")));
			assert.is_nil((run("set", "bob@localhost", "b@example.org")));
			assert.is_nil((run("show", "localhost")));
			assert.same({ nil, "No such account" }, { run("show", "bob@localhost") });
		end);
	end);
end);

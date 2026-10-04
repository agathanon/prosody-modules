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

local function to_hex(s)
	return (s:gsub(".", function (c) return ("%02x"):format(c:byte()); end));
end

-- Load a fresh instance of the module; config sets module options.
-- Returns its environment and the stubs.
local function load_module(config)
	config = config or {};
	local stores = { recovery_email = new_store(); recovery_email_removed = new_store() };
	local store = stores.recovery_email;
	local accounts = { alice = { created = 1000 } };
	local events, hooks, items, logs = {}, {}, {}, {};
	-- Rate limiters by their limit: 5 for changes, 3 for resends
	local throttles = { [5] = { allow = true, polls = 0 }; [3] = { allow = true, polls = 0 } };
	-- Queued 4-byte outputs for util.random.bytes, used for codes; anything
	-- else (e.g. salts) gets random bytes
	local random_queue = {};

	local stubs = {
		["prosody.util.cache"] = {
			new = function ()
				local t = {};
				return { get = function (_, k) return t[k]; end, set = function (_, k, v) t[k] = v; end };
			end;
		};
		["prosody.util.dataforms"] = {
			new = function (layout)
				-- Submissions are passed as plain tables of field values
				return setmetatable(layout, { __index = { data = function (_, form) return form; end } });
			end;
		};
		["prosody.util.hashes"] = {
			sha256 = function (s, hex) assert(hex); return to_hex(s); end;
			equals = function (a, b) return a == b; end;
		};
		["prosody.util.hex"] = { encode = to_hex };
		["prosody.util.jid"] = {
			prepped_split = function (jid)
				local node, host = jid:match("^([^@/]+)@([^/]+)");
				if not node then return nil, jid:match("^([^/]+)"); end
				return node, host;
			end;
		};
		["prosody.util.random"] = {
			bytes = function (n)
				if n == 4 and #random_queue > 0 then
					return table.remove(random_queue, 1);
				end
				local b = {};
				for i = 1, n do b[i] = string.char(math.random(0, 255)); end
				return table.concat(b);
			end;
		};
		["prosody.util.throttle"] = {
			create = function (limit)
				local state = throttles[limit];
				return {
					peek = function () return state.allow; end;
					poll = function () state.polls = state.polls + 1; return true; end;
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
		get_option_period = function (_, name, default)
			if name == "recovery_email_code_lifetime" then
				assert(default == "24 hours");
				return 86400;
			end
			if config[name] == nil then return default; end
			return config[name];
		end;
		open_store = function (_, name) return assert(stores[name], "unexpected store "..name); end;
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
		store = store, removed = stores.recovery_email_removed, accounts = accounts, events = events, hooks = hooks,
		items = items, throttles = throttles, logs = logs, random_queue = random_queue,
	};
end

-- The code from the most recent verification request
local function last_code(s)
	for i = #s.events, 1, -1 do
		if s.events[i].name == "recovery-email-verification-requested" then
			return s.events[i].payload.code;
		end
	end
end

local function event_names(s)
	local names = {};
	for i, e in ipairs(s.events) do names[i] = e.name; end
	return names;
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
		it("stores a normalized, unverified record and starts verification", function ()
			assert.same({ true, "changed" }, { env.set("alice", " A@Example.org ") });
			local record = s.store.data.alice;
			assert.equal("A@example.org", record.email);
			assert.equal("unverified", record.status);
			assert.equal(1, record.version);
			assert.equal(1000, record.account_created);
			assert.is_number(record.created_at);
			assert.equal(record.created_at, record.updated_at);
			assert.matches("^%x+%$%x+$", record.verify_token_hash);
			assert.equal(record.created_at + 86400, record.verify_expires);
			assert.equal(0, record.verify_attempts);
			assert.same({ "recovery-email-set", "recovery-email-verification-requested" }, event_names(s));
			assert.same({ username = "alice", host = "localhost", email = "A@example.org" }, s.events[1].payload);
			local request = s.events[2].payload;
			assert.matches("^%d%d%d%d%d%d$", request.code);
			assert.same({ username = "alice", host = "localhost", email = "A@example.org",
				code = request.code, expires = record.verify_expires }, request);
		end);

		it("never stores the code itself", function ()
			env.set("alice", "a@example.org");
			local code = last_code(s);
			for _, value in pairs(s.store.data.alice) do
				assert.falsy(tostring(value):find(code, 1, true));
			end
		end);

		it("changes nothing when the normalized address is the same", function ()
			env.set("alice", "a@example.org");
			local before = s.store.data.alice;
			assert.same({ true, "unchanged" }, { env.set("alice", "a@EXAMPLE.org") });
			assert.equal(before, s.store.data.alice);
			assert.equal(2, #s.events);
		end);

		it("resets verification, keeps created_at, and reports the previous status", function ()
			s.store.data.alice = {
				version = 1, email = "old@example.org", status = "verified", created_at = 5, updated_at = 5,
				verified_at = 6, account_created = 1000,
			};
			assert.truthy(env.set("alice", "new@example.org", "shell"));
			local record = s.store.data.alice;
			assert.equal("unverified", record.status);
			assert.equal(5, record.created_at);
			assert.is_nil(record.verified_at);
			assert.same({ username = "alice", host = "localhost", email = "new@example.org",
				previous_email = "old@example.org", previous_status = "verified", source = "shell" }, s.events[1].payload);
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
		it("removes the record and fires an event with the previous status", function ()
			env.set("alice", "a@example.org");
			assert.same({ true, "removed" }, { env.clear("alice", "shell") });
			assert.is_nil(s.store.data.alice);
			assert.same({ name = "recovery-email-cleared", payload = {
				username = "alice", host = "localhost", previous_email = "a@example.org",
				previous_status = "unverified", source = "shell",
			} }, s.events[3]);
		end);

		it("reports when there was nothing to remove", function ()
			assert.same({ true, "absent" }, { env.clear("alice") });
			assert.equal(0, #s.events);
		end);
	end);

	describe("verification codes", function ()
		it("are uniform: values that would bias the result are discarded", function ()
			table.insert(s.random_queue, "\255\255\255\255"); -- 4294967295, above the limit
			table.insert(s.random_queue, "\0\0\0\42");
			env.set("alice", "a@example.org");
			assert.equal("000042", last_code(s));
		end);

		it("accept spaces and hyphens in the input", function ()
			table.insert(s.random_queue, "\0\1\226\64"); -- 123456
			env.set("alice", "a@example.org");
			assert.equal("123456", last_code(s));
			assert.same({ true, "verified" }, { env.verify("alice", " 123-456 ") });
		end);
	end);

	describe("verify()", function ()
		before_each(function ()
			env.set("alice", "a@example.org");
		end);

		it("verifies the address with the right code", function ()
			assert.same({ true, "verified" }, { env.verify("alice", last_code(s)) });
			local record = s.store.data.alice;
			assert.equal("verified", record.status);
			assert.is_number(record.verified_at);
			assert.is_nil(record.verify_token_hash);
			assert.is_nil(record.verify_expires);
			assert.is_nil(record.verify_attempts);
			assert.same({ name = "recovery-email-verified", payload = {
				username = "alice", host = "localhost", email = "a@example.org" } }, s.events[#s.events]);
		end);

		it("counts wrong codes and cancels the code after 5", function ()
			local code = last_code(s);
			local wrong = code == "000000" and "111111" or "000000";
			for i = 1, 4 do
				local ok, condition, message = env.verify("alice", wrong);
				assert.is_nil(ok);
				assert.equal("not-acceptable", condition);
				local left = 5 - i;
				assert.equal(("That code is incorrect. %d %s left."):format(left, left == 1 and "attempt" or "attempts"), message);
				assert.equal(i, s.store.data.alice.verify_attempts);
			end
			-- the fifth wrong attempt (malformed input counts) cancels the code
			local ok, condition = env.verify("alice", "not a code");
			assert.is_nil(ok);
			assert.equal("resource-constraint", condition);
			assert.is_nil(s.store.data.alice.verify_token_hash);
			-- after which even the right code is refused
			assert.equal("resource-constraint", select(2, env.verify("alice", code)));
			assert.equal("unverified", s.store.data.alice.status);
		end);

		it("rejects expired codes and clears them", function ()
			s.store.data.alice.verify_expires = os.time() - 1;
			local ok, condition = env.verify("alice", last_code(s));
			assert.is_nil(ok);
			assert.equal("resource-constraint", condition);
			assert.is_nil(s.store.data.alice.verify_token_hash);
		end);

		it("refuses when already verified or when there is no address", function ()
			env.verify("alice", last_code(s));
			assert.equal("conflict", select(2, env.verify("alice", "123456")));
			env.clear("alice");
			assert.equal("item-not-found", select(2, env.verify("alice", "123456")));
		end);

		it("never logs the code", function ()
			local code = last_code(s);
			env.verify("alice", "000000");
			env.verify("alice", code);
			for _, line in ipairs(s.logs) do
				assert.falsy(line:find(code, 1, true));
			end
		end);
	end);

	describe("resend_verification()", function ()
		it("replaces the pending code and requests another email", function ()
			table.insert(s.random_queue, "\0\0\0\1");
			table.insert(s.random_queue, "\0\0\0\2");
			env.set("alice", "a@example.org");
			assert.equal("000001", last_code(s));
			s.store.data.alice.verify_attempts = 3;
			assert.is_true(env.resend_verification("alice"));
			assert.equal("000002", last_code(s));
			assert.equal(0, s.store.data.alice.verify_attempts);
			assert.equal("recovery-email-verification-requested", s.events[#s.events].name);
			-- the old code no longer works; the new one does
			assert.equal("not-acceptable", select(2, env.verify("alice", "000001")));
			assert.same({ true, "verified" }, { env.verify("alice", "000002") });
		end);

		it("refuses for verified or missing addresses", function ()
			assert.equal("item-not-found", select(2, env.resend_verification("alice")));
			env.set("alice", "a@example.org");
			env.verify("alice", last_code(s));
			assert.equal("conflict", select(2, env.resend_verification("alice")));
		end);
	end);

	describe("get_reset_address()", function ()
		it("returns only a verified address", function ()
			assert.same({ nil, "none" }, { env.get_reset_address("alice") });
			env.set("alice", "a@example.org");
			assert.same({ nil, "unverified" }, { env.get_reset_address("alice") });
			env.verify("alice", last_code(s));
			assert.same({ "a@example.org" }, { env.get_reset_address("alice") });
		end);

		it("ignores stale records from an earlier account", function ()
			s.store.data.alice = { email = "old@example.org", status = "verified", account_created = 1 };
			assert.same({ nil, "none" }, { env.get_reset_address("alice") });
		end);
	end);

	describe("cooling-off period", function ()
		local DELAY = 7 * 86400;

		-- Sets an address and verifies it
		local function set_verified(email)
			env.set("alice", email);
			assert.same({ true, "verified" }, { env.verify("alice", last_code(s)) });
		end

		local function assert_cooling_off()
			local address, reason, ends = env.get_reset_address("alice");
			assert.is_nil(address);
			assert.equal("cooling-off", reason);
			assert.equal(s.store.data.alice.verified_at + DELAY, ends);
		end

		it("is off by default", function ()
			set_verified("a@example.org");
			set_verified("b@example.org");
			assert.is_nil(s.store.data.alice.reset_allowed_after);
			assert.equal("b@example.org", env.get_reset_address("alice"));
			env.clear("alice");
			assert.is_nil(s.removed.data.alice);
		end);

		describe("when configured", function ()
			before_each(function ()
				env, s = load_module({ recovery_email_reset_delay = DELAY });
			end);

			it("doesn't apply to a first address", function ()
				set_verified("a@example.org");
				assert.equal("a@example.org", env.get_reset_address("alice"));
			end);

			it("applies to an address that replaced a verified one", function ()
				set_verified("a@example.org");
				set_verified("b@example.org");
				assert_cooling_off();
				assert.is_nil(s.store.data.alice.replaced_verified);
			end);

			it("carries through unverified addresses in between", function ()
				set_verified("a@example.org");
				env.set("alice", "b@example.org");
				set_verified("c@example.org");
				assert_cooling_off();
			end);

			it("doesn't apply to an address that replaced an unverified one", function ()
				env.set("alice", "a@example.org");
				set_verified("b@example.org");
				assert.equal("b@example.org", env.get_reset_address("alice"));
			end);

			it("can't be skipped by removing the verified address first", function ()
				set_verified("a@example.org");
				env.clear("alice");
				assert.is_number(s.removed.data.alice.at);
				set_verified("b@example.org");
				assert_cooling_off();
				assert.is_nil(s.removed.data.alice);
			end);

			it("doesn't apply once the removal is older than the delay", function ()
				set_verified("a@example.org");
				env.clear("alice");
				s.removed.data.alice.at = os.time() - DELAY - 1;
				set_verified("b@example.org");
				assert.equal("b@example.org", env.get_reset_address("alice"));
			end);

			it("ends after the delay", function ()
				set_verified("a@example.org");
				set_verified("b@example.org");
				s.store.data.alice.reset_allowed_after = os.time() - 1;
				assert.equal("b@example.org", env.get_reset_address("alice"));
			end);

			it("is shown by the shell", function ()
				set_verified("a@example.org");
				set_verified("b@example.org");
				local printed = {};
				local shell = { session = { print = function (line) printed[#printed+1] = line; end } };
				s.items["shell-command:show"].handler(shell, "alice@localhost");
				assert.matches("^Reset:       usable from .* UTC$", printed[6]);
			end);

			it("forgets removals when the account is deleted", function ()
				set_verified("a@example.org");
				env.clear("alice");
				s.hooks["user-deleted"]({ username = "alice", host = "localhost" });
				assert.is_nil(s.removed.data.alice);
			end);
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
		local function handler() return s.items.adhoc[3]; end
		local function open(from)
			return handler()(nil, { from = from or "alice@localhost/res"; action = "execute" });
		end
		local function submit(fields, from)
			return handler()(nil, { from = from or "alice@localhost/res"; action = "complete"; form = fields }, "executing");
		end
		local function field_names(reply)
			local names = {};
			for i, field in ipairs(reply.form.layout) do names[i] = field.name; end
			return names;
		end

		it("requires the role-based permission check", function ()
			assert.equal("recovery-email", s.items.adhoc[2]);
			assert.equal("check", s.items.adhoc[4]);
		end);

		it("shows only the fields that apply to the current state", function ()
			local reply = open();
			assert.equal("executing", reply.status);
			assert.same({ "current", "email", "remove" }, field_names(reply));
			assert.same({ current = "No recovery email set", email = "", remove = false }, reply.form.values);

			env.set("alice", "a@example.org");
			reply = open();
			assert.same({ "current", "code", "resend", "email", "remove" }, field_names(reply));
			assert.same({ current = "a@example.org (unverified)", email = "a@example.org", remove = false }, reply.form.values);

			env.verify("alice", last_code(s));
			reply = open();
			assert.same({ "current", "email", "remove" }, field_names(reply));
			assert.equal("a@example.org (verified)", reply.form.values.current);
		end);

		it("refuses users of other hosts", function ()
			assert.equal("forbidden", open("alice@example.com/res").error.condition);
			assert.equal("forbidden", submit({ email = "a@example.org" }, "alice@example.com/res").error.condition);
			assert.is_nil(s.store.data.alice);
		end);

		it("saves a new address and says a code was sent", function ()
			assert.equal("Recovery email saved. A verification code has been sent to it.",
				submit({ email = "a@example.org" }).info);
			assert.equal(1, s.throttles[5].polls);
			assert.same({ "info: Recovery email for alice set to a***@example.org" }, s.logs);
		end);

		it("verifies with a code, and a changed address takes precedence over it", function ()
			submit({ email = "a@example.org" });
			local code = last_code(s);
			assert.equal("Recovery email saved. A verification code has been sent to it.",
				submit({ email = "b@example.org"; code = code }).info);
			assert.equal("unverified", s.store.data.alice.status);
			assert.equal("Recovery email verified.", submit({ email = "b@example.org"; code = last_code(s) }).info);
			assert.equal("verified", s.store.data.alice.status);
			assert.equal(2, s.throttles[5].polls);
		end);

		it("reports wrong codes", function ()
			submit({ email = "a@example.org" });
			local wrong = last_code(s) == "000000" and "111111" or "000000";
			assert.equal("That code is incorrect. 4 attempts left.",
				submit({ email = "a@example.org"; code = wrong }).error.message);
		end);

		it("sends a new code on request, within its own limit", function ()
			submit({ email = "a@example.org" });
			assert.equal("A new code has been sent.", submit({ email = "a@example.org"; resend = true }).info);
			assert.equal(1, s.throttles[3].polls);
			s.throttles[3].allow = false;
			assert.equal("Too many codes requested. Please try again later.",
				submit({ email = "a@example.org"; resend = true }).error.message);
			assert.equal(1, s.throttles[5].polls);
		end);

		it("reports unchanged and empty submissions without using the limit", function ()
			submit({ email = "a@example.org" });
			assert.equal("No changes made.", submit({ email = "a@example.org" }).info);
			assert.equal("No changes made.", submit({ email = "  " }).info);
			assert.equal(1, s.throttles[5].polls);
		end);

		it("shows validation errors without using the limit", function ()
			assert.is_string(submit({ email = "nope" }).error.message);
			assert.equal(0, s.throttles[5].polls);
		end);

		it("removes the address, taking precedence over the other fields", function ()
			submit({ email = "a@example.org" });
			assert.equal("Recovery email removed.",
				submit({ email = "b@example.org"; code = last_code(s); resend = true; remove = true }).info);
			assert.is_nil(s.store.data.alice);
			assert.equal("No recovery email was set.", submit({ remove = true }).info);
			assert.equal(2, s.throttles[5].polls);
		end);

		it("refuses changes when rate limited", function ()
			s.throttles[5].allow = false;
			assert.is_string(submit({ email = "a@example.org" }).error.message);
			assert.is_nil(s.store.data.alice);
		end);

		it("can be cancelled", function ()
			local reply = handler()(nil, { from = "alice@localhost/res"; action = "cancel" }, "executing");
			assert.equal("canceled", reply.status);
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
			assert.same({ true, "Recovery email set (unverified; verification code requested)" },
				{ run("set", "alice@localhost", "a@example.org") });
			assert.truthy(run("show", "alice@localhost"));
			assert.equal("Email:       a@example.org", printed[1]);
			assert.equal("Reset:       not usable (unverified)", printed[6]);
			assert.matches("^Code:        pending, expires .* UTC, 0 of 5 attempts used$", printed[7]);
			assert.same({ true, "Recovery email removed" }, { run("clear", "alice@localhost") });
			assert.same({ "recovery-email-set", "recovery-email-verification-requested", "recovery-email-cleared" },
				event_names(s));
		end);

		it("never shows the code or its hash", function ()
			run("set", "alice@localhost", "a@example.org");
			run("show", "alice@localhost");
			local output = table.concat(printed, "\n");
			assert.falsy(output:find(last_code(s), 1, true));
			assert.falsy(output:find(s.store.data.alice.verify_token_hash, 1, true));
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

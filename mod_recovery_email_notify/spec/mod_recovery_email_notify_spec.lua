-- Unit tests for mod_recovery_email_notify, run outside Prosody with stubbed APIs
local module_path = debug.getinfo(1, "S").source:match("^@(.-)spec/[^/]*$").."mod_recovery_email_notify.lua";

-- Stand-in for util.interpolation, supporting the forms the templates use:
-- {name}, {name&shown if set} and {name~shown if not set}
local function render(template, values)
	return (template:gsub("%b{}", function (block)
		local name, opt, rest = block:sub(2, -2):match("^([%a_][%w_]*)([&~]?)(.*)$");
		if not name then return; end
		local value = values[name];
		if opt == "&" then return value and render(rest, values) or ""; end
		if opt == "~" then return value and "" or render(rest, values); end
		if value ~= nil then return tostring(value); end
	end));
end

-- Load a fresh instance; config sets module options
local function load_module(config)
	config = config or {};
	local sent, logs, hooks = {}, {}, {};
	local smtp = {
		send = function (message)
			local entry = { message = message };
			sent[#sent+1] = entry;
			return {
				next = function (_, on_ok, on_fail)
					entry.resolve = function () on_ok(true); end;
					entry.reject = function (err) on_fail(err); end;
				end;
			};
		end;
	};
	local module = {
		host = "example.com";
		log = function (_, level, fmt, ...) logs[#logs+1] = level..": "..fmt:format(...); end;
		depends = function (_, name) if name == "smtp_async" then return smtp; end end;
		get_option = function (_, name, default)
			if config[name] == nil then return default; end
			return config[name];
		end;
		get_option_string = function (_, name, default)
			if config[name] == nil then return default; end
			return config[name];
		end;
		hook = function (_, name, handler) hooks[name] = handler; end;
	};
	local env = setmetatable({
		module = module;
		require = function (name)
			assert(name == "prosody.util.interpolation", "unexpected require: "..name);
			return { new = function () return render; end };
		end;
	}, { __index = _G });
	assert(loadfile(module_path, "t", env))();
	return { sent = sent; logs = logs; hooks = hooks };
end

local function fire(s, name, payload)
	payload.username = payload.username or "alice";
	payload.host = payload.host or "example.com";
	s.hooks[name](payload);
end

describe("mod_recovery_email_notify", function ()
	local s;
	before_each(function ()
		s = load_module();
	end);

	describe("verification email", function ()
		it("sends the code to the new address", function ()
			fire(s, "recovery-email-verification-requested", {
				email = "alice@example.org"; code = "123456"; expires = 1791048944;
			});
			assert.equal(1, #s.sent);
			local m = s.sent[1].message;
			assert.equal("alice@example.org", m.to);
			assert.is_nil(m.from); -- left to mod_smtp_async (smtp_async_from)
			assert.equal("Your verification code for alice@example.com", m.subject);
			assert.truthy(m.body:find("Your verification code is: 123456\n", 1, true));
			assert.truthy(m.body:find("valid until 2026-10-03 17:35 UTC.", 1, true));
			assert.same({ ["Auto-Submitted"] = "auto-generated" }, m.headers);
			assert.falsy(m.body:find("{", 1, true));
		end);

		it("logs the outcome without the code or the full address", function ()
			fire(s, "recovery-email-verification-requested", {
				email = "alice@example.org"; code = "123456"; expires = 0;
			});
			s.sent[1].resolve();
			fire(s, "recovery-email-verification-requested", {
				email = "alice@example.org"; code = "654321"; expires = 0;
			});
			s.sent[2].reject({ text = "server replied 550 5.1.1 to rcpt" });
			assert.same({
				"info: Sent verification email for alice to a***@example.org",
				"warn: Unable to send verification email for alice to a***@example.org: server replied 550 5.1.1 to rcpt",
			}, s.logs);
		end);
	end);

	describe("change notices", function ()
		it("tells a verified previous address that it was replaced", function ()
			fire(s, "recovery-email-set", {
				email = "new@example.org"; previous_email = "old@example.org"; previous_status = "verified";
			});
			assert.equal(1, #s.sent);
			local m = s.sent[1].message;
			assert.equal("old@example.org", m.to);
			assert.equal("The recovery email for alice@example.com was changed", m.subject);
			assert.truthy(m.body:find("was changed\nfrom the account at ", 1, true));
			assert.falsy(m.body:find("new@example.org", 1, true));
		end);

		it("tells a verified address that it was removed", function ()
			fire(s, "recovery-email-cleared", { previous_email = "old@example.org"; previous_status = "verified" });
			assert.equal("old@example.org", s.sent[1].message.to);
			assert.equal("The recovery email for alice@example.com was removed", s.sent[1].message.subject);
		end);

		it("says when an administrator made the change", function ()
			fire(s, "recovery-email-cleared", {
				previous_email = "old@example.org"; previous_status = "verified"; source = "shell";
			});
			assert.truthy(s.sent[1].message.body:find("was removed\nby a server administrator at ", 1, true));
		end);

		it("never emails addresses that weren't verified", function ()
			fire(s, "recovery-email-set", { email = "new@example.org" });
			fire(s, "recovery-email-set", {
				email = "new@example.org"; previous_email = "old@example.org"; previous_status = "unverified";
			});
			fire(s, "recovery-email-cleared", { previous_email = "old@example.org"; previous_status = "unverified" });
			assert.equal(0, #s.sent);
		end);
	end);

	describe("password reset emails", function ()
		local url = "https://example.com/recovery_email_reset/reset/SECRETTOKEN";

		it("sends the reset link to the verified address", function ()
			fire(s, "recovery-email-reset-requested", { email = "alice@example.org"; url = url; expires = 1791048944 });
			local m = s.sent[1].message;
			assert.equal("alice@example.org", m.to);
			assert.equal("Reset your password for alice@example.com", m.subject);
			assert.truthy(m.body:find("\n"..url.."\n", 1, true));
			assert.truthy(m.body:find("valid until 2026-10-03 17:35 UTC.", 1, true));
			assert.same({ ["Auto-Submitted"] = "auto-generated" }, m.headers);
			assert.falsy(m.body:find("{", 1, true));
		end);

		it("confirms a completed reset without any link", function ()
			fire(s, "recovery-email-password-reset", { email = "alice@example.org" });
			local m = s.sent[1].message;
			assert.equal("alice@example.org", m.to);
			assert.equal("The password for alice@example.com was reset", m.subject);
			assert.truthy(m.body:find("was reset at %d%d%d%d%-%d%d%-%d%d %d%d:%d%d UTC"));
			assert.truthy(m.body:find("Contact the administrator of example.com.\n", 1, true));
			assert.falsy(m.body:find("http", 1, true));
		end);

		it("never logs the link or the full address", function ()
			fire(s, "recovery-email-reset-requested", { email = "alice@example.org"; url = url; expires = 0 });
			s.sent[1].resolve();
			fire(s, "recovery-email-password-reset", { email = "alice@example.org" });
			s.sent[2].reject({ text = "server replied 450 4.2.0 to rcpt" });
			assert.same({
				"info: Sent reset email for alice to a***@example.org",
				"warn: Unable to send reset_done email for alice to a***@example.org: server replied 450 4.2.0 to rcpt",
			}, s.logs);
		end);

		it("can be overridden in the configuration", function ()
			s = load_module({ recovery_email_messages = { reset = { body = "Link: {url}" }; reset_done = { subject = "Done" } } });
			fire(s, "recovery-email-reset-requested", { email = "a@example.org"; url = url; expires = 0 });
			fire(s, "recovery-email-password-reset", { email = "a@example.org" });
			assert.equal("Link: "..url, s.sent[1].message.body);
			assert.equal("Done", s.sent[2].message.subject);
			assert.same({}, s.logs);
		end);
	end);

	describe("configuration", function ()
		local function notice_body(config)
			s = load_module(config);
			fire(s, "recovery-email-cleared", { previous_email = "old@example.org"; previous_status = "verified" });
			return s.sent[1].message.body;
		end

		it("names the admin contact from contact_info, or the host", function ()
			local body = notice_body({ contact_info = { admin = { "mailto:admin@example.com", "xmpp:admin@example.com" } } });
			assert.truthy(body:find("Contact the server administrator: admin@example.com, xmpp:admin@example.com\n", 1, true));
			assert.falsy(body:find("Contact the administrator of", 1, true));

			body = notice_body({});
			assert.truthy(body:find("Contact the administrator of example.com.\n", 1, true));
		end);

		it("uses the configured sender and message overrides", function ()
			s = load_module({
				recovery_email_from = "accounts@example.com";
				recovery_email_messages = { verification = { subject = "Code for {jid}: {code}" }; bogus = {} };
			});
			fire(s, "recovery-email-verification-requested", { email = "a@example.org"; code = "111222"; expires = 0 });
			local m = s.sent[1].message;
			assert.equal("accounts@example.com", m.from);
			assert.equal("Code for alice@example.com: 111222", m.subject);
			assert.truthy(m.body:find("Your verification code is: 111222", 1, true));
			assert.same({ 'warn: Ignoring unknown message "bogus" in recovery_email_messages' }, s.logs);
		end);
	end);
end);

-- Unit tests for mod_smtp_async, run outside Prosody with stubbed APIs
local module_path = debug.getinfo(1, "S").source:match("^@(.-)spec/[^/]*$").."mod_smtp_async.lua";

local b64chars = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/";

local function b64encode(s)
	return ((s:gsub(".", function (c)
		local bits, byte = "", c:byte();
		for i = 8, 1, -1 do bits = bits..(byte % 2^i - byte % 2^(i-1) > 0 and "1" or "0"); end
		return bits;
	end).."0000"):gsub("%d%d%d?%d?%d?%d?", function (bits)
		if #bits < 6 then return ""; end
		local n = 0;
		for i = 1, 6 do n = n + (bits:sub(i, i) == "1" and 2^(6-i) or 0); end
		return b64chars:sub(n + 1, n + 1);
	end)..({ "", "==", "=" })[#s % 3 + 1]);
end

local function b64decode(s)
	s = s:gsub("[^%w%+/]", "");
	return (s:gsub(".", function (c)
		local n, bits = b64chars:find(c, 1, true) - 1, "";
		for i = 6, 1, -1 do bits = bits..(n % 2^i - n % 2^(i-1) > 0 and "1" or "0"); end
		return bits;
	end):gsub("%d%d%d%d%d%d%d%d", function (bits)
		local n = 0;
		for i = 1, 8 do n = n + (bits:sub(i, i) == "1" and 2^(8-i) or 0); end
		return string.char(math.floor(n));
	end));
end

-- Load a fresh instance; config overrides module options
local function load_module(config)
	config = config or {};
	local timers, connects, logs = {}, {}, {};
	local function option(name, default)
		local value = config[name];
		if value == nil then return default; end
		return value;
	end
	local stubs = {
		["prosody.util.encodings"] = { base64 = { encode = b64encode } };
		["prosody.net.resolvers.basic"] = {
			new = function (host, port) return { host = host; port = port }; end;
		};
		["prosody.core.certmanager"] = {
			create_context = function (_, mode, opts) return { mode = mode; opts = opts }; end;
		};
		["prosody.net.connect"] = {
			connect = function (resolver, listeners, options)
				connects[#connects+1] = { resolver = resolver; listeners = listeners; options = options };
			end;
		};
		["prosody.util.error"] = { new = function (e) return e; end };
		["prosody.util.id"] = { medium = function () return "MSGID"; end };
		["prosody.util.promise"] = {
			new = function (f)
				local p = { state = "pending" };
				f(function (v) p.state, p.value = "resolved", v; end,
					function (e) p.state, p.reason = "rejected", e; end);
				return p;
			end;
		};
		["prosody.util.x509"] = { verify_identity = function () return true; end };
	};
	local module = {
		host = "example.com";
		log = function (_, level, fmt, ...) logs[#logs+1] = level..": "..fmt:format(...); end;
		get_option_string = function (_, name, default) return option(name, default); end;
		get_option_enum = function (_, name, default) return option(name, default); end;
		get_option_integer = function (_, name, default) return option(name, default); end;
		get_option_boolean = function (_, name, default) return option(name, default); end;
		get_option_period = function (_, name, default)
			local value = option(name, default);
			return value == "30s" and 30 or value;
		end;
		get_option_path = function (_, name, default) return option(name, default); end;
		add_timer = function (_, delay, callback)
			local t = { delay = delay; callback = callback };
			t.stop = function () t.stopped = true; end;
			timers[#timers+1] = t;
			return t;
		end;
	};
	local env = setmetatable({
		module = module;
		require = function (name) return assert(stubs[name], "unexpected require: "..name); end;
	}, { __index = _G });
	assert(loadfile(module_path, "t", env))();
	return env, { timers = timers; connects = connects; logs = logs };
end

local message = { to = "user@example.org"; subject = "Hello"; body = "Line one\nLine two" };

describe("mod_smtp_async", function ()
	local env, s, t;
	before_each(function ()
		env, s = load_module();
		t = env._test;
	end);

	describe("reply parsing", function ()
		it("parses single replies", function ()
			assert.same({ 250, false, "OK" }, { t.parse_reply_line("250 OK") });
			assert.same({ 250, true, "SIZE 1000" }, { t.parse_reply_line("250-SIZE 1000") });
			assert.same({ 354, false, "" }, { t.parse_reply_line("354") });
			assert.is_nil(t.parse_reply_line("hello"));
		end);

		it("assembles multi-line replies across chunks", function ()
			local read = t.new_reply_reader();
			assert.same({}, read("250-mail.example.org\r\n250-STARTT"));
			assert.same({ { code = 250; lines = { "mail.example.org", "STARTTLS", "AUTH PLAIN" } } },
				read("LS\r\n250 AUTH PLAIN\r\n"));
			assert.same({ { code = 220; lines = { "ready" } } }, read("220 ready\n"));
		end);

		it("rejects invalid and overlong replies", function ()
			assert.is_nil((t.new_reply_reader()("nonsense\r\n")));
			assert.is_nil((t.new_reply_reader()(("x"):rep(5000))));
		end);

		it("reads EHLO capabilities", function ()
			assert.same({ STARTTLS = ""; AUTH = "PLAIN LOGIN"; SMTPUTF8 = "" },
				t.parse_capabilities({ "mail.example.org", "STARTTLS", "auth plain login", "SMTPUTF8" }));
		end);
	end);

	describe("message formatting", function ()
		it("formats dates per RFC 5322", function ()
			assert.equal("Thu, 01 Jan 1970 00:00:00 +0000", t.format_date(0));
			assert.equal("Sat, 03 Oct 2026 17:35:44 +0000", t.format_date(1791048944));
		end);

		it("splits UTF-8 without breaking characters", function ()
			local chunks = t.utf8_chunks(("é"):rep(10), 5);
			assert.equal(("é"):rep(10), table.concat(chunks));
			for _, chunk in ipairs(chunks) do
				assert.truthy(utf8.len(chunk));
				assert.truthy(#chunk <= 5);
			end
		end);

		it("encodes non-ASCII subjects as encoded-words", function ()
			assert.equal("Hello", t.encode_header_value("Hello"));
			local subject = ("Bestätigungscode für Ihr Konto "):rep(4);
			local encoded = t.encode_header_value(subject);
			local decoded = {};
			for word in encoded:gmatch("[^\r\n ]+") do
				assert.truthy(#word <= 75);
				decoded[#decoded+1] = b64decode(word:match("^=%?UTF%-8%?B%?(.*)%?=$"));
			end
			assert.equal(subject, table.concat(decoded));
		end);

		it("formats a message with headers and a base64 body", function ()
			local checked = assert(t.validate_message(message, "noreply@example.com"));
			local data = t.format_message(checked, 0, "<MSGID@example.com>");
			local headers, body = data:match("^(.-)\r\n\r\n(.*)$");
			assert.truthy(headers:find("Date: Thu, 01 Jan 1970 00:00:00 +0000", 1, true));
			assert.truthy(headers:find("From: noreply@example.com\r\n", 1, true));
			assert.truthy(headers:find("To: user@example.org\r\n", 1, true));
			assert.truthy(headers:find("Message-ID: <MSGID@example.com>", 1, true));
			assert.truthy(headers:find("Content-Type: text/plain; charset=utf-8", 1, true));
			assert.equal("Line one\r\nLine two", b64decode(body));
			for line in body:gmatch("[^\r\n]+") do
				assert.truthy(#line <= 76);
			end
		end);

		it("includes extra headers in a stable order", function ()
			local checked = assert(t.validate_message({ to = "a@example.org"; subject = "s"; body = "b";
				headers = { ["Reply-To"] = "admin@example.com"; ["Auto-Submitted"] = "auto-generated" } }, "x@example.com"));
			local data = t.format_message(checked, 0, "<id@example.com>");
			assert.truthy(data:find("Auto%-Submitted: auto%-generated\r\nReply%-To: admin@example.com\r\n"));
		end);

		it("dot-stuffs lines starting with a dot", function ()
			assert.equal("a\r\n..b\r\n.\r\n", t.dot_stuff("a\r\n.b\r\n"));
			assert.equal("..x\r\n.\r\n", t.dot_stuff(".x\r\n"));
		end);
	end);

	describe("message validation", function ()
		local function invalid(m)
			local checked, err = t.validate_message(m, "noreply@example.com");
			assert.is_nil(checked);
			assert.is_string(err);
		end

		it("uses the default sender", function ()
			assert.equal("noreply@example.com", t.validate_message(message, "noreply@example.com").from);
		end);

		it("rejects bad addresses", function ()
			invalid({ to = "nobody"; subject = "s"; body = "b" });
			invalid({ to = "a@example.org\r\nRCPT TO:<b@example.org>"; subject = "s"; body = "b" });
			invalid({ to = "<a@example.org>"; subject = "s"; body = "b" });
			invalid({ to = "a@example.org"; from = "x y@example.com"; subject = "s"; body = "b" });
			for _, c in ipairs({ ",", ";", ":", '"', "(", ")", "[", "]", "\\" }) do
				invalid({ to = "a"..c.."b@example.org"; subject = "s"; body = "b" });
			end
		end);

		it("rejects header injection", function ()
			invalid({ to = "a@example.org"; subject = "Hi\r\nBcc: victim@example.org"; body = "b" });
			invalid({ to = "a@example.org"; subject = "s"; body = "b"; headers = { ["X-A"] = "v\r\nBcc: x" } });
			invalid({ to = "a@example.org"; subject = "s"; body = "b"; headers = { ["Bad Name"] = "v" } });
			invalid({ to = "a@example.org"; subject = "s"; body = "b"; headers = { ["Subject"] = "v" } });
		end);

		it("rejects invalid UTF-8 and missing fields", function ()
			invalid({ to = "a@example.org"; subject = "\255"; body = "b" });
			invalid({ to = "a@example.org"; subject = "s"; body = "\192\128" });
			invalid({ to = "a@example.org"; subject = "s" });
			invalid("not a table");
		end);
	end);

	describe("SMTP session", function ()
		-- Drives a session with scripted server replies, recording what the client does
		local function new_test_session(opts, msg)
			local log = {};
			local result = {};
			local transport = {
				write = function (data) log[#log+1] = data; end;
				starttls = function () log[#log+1] = "<starttls>"; end;
				close = function () log[#log+1] = "<close>"; end;
			};
			local checked = assert(t.validate_message(msg or message, "noreply@example.com"));
			local session = t.new_session(checked, "DATA\r\n", opts, transport, function (ok, err)
				result.ok, result.err = ok, err;
			end);
			return session, log, result;
		end

		local starttls_opts = { helo = "example.com"; tls = "starttls"; username = "user"; password = "secret" };
		local ehlo_tls = "250-mail.example.org\r\n250-STARTTLS\r\n250 AUTH PLAIN LOGIN\r\n";
		local ehlo_after = "250-mail.example.org\r\n250 AUTH PLAIN LOGIN\r\n";

		it("sends a message with STARTTLS and AUTH PLAIN", function ()
			local session, log, result = new_test_session(starttls_opts);
			assert.is_true(session:connected(false));
			session:receive("220 mail.example.org ESMTP\r\n");
			session:receive(ehlo_tls);
			session:receive("220 Go ahead\r\n");
			session:tls_ready();
			session:receive(ehlo_after);
			session:receive("235 OK\r\n");
			session:receive("250 OK\r\n");
			session:receive("250 OK\r\n");
			session:receive("354 Go\r\n");
			session:receive("250 Queued\r\n");
			assert.same({
				"EHLO example.com\r\n", "STARTTLS\r\n", "<starttls>", "EHLO example.com\r\n",
				"AUTH PLAIN "..b64encode("\0user\0secret").."\r\n",
				"MAIL FROM:<noreply@example.com>\r\n", "RCPT TO:<user@example.org>\r\n", "DATA\r\n",
				"DATA\r\n.\r\n", "QUIT\r\n", "<close>",
			}, log);
			assert.is_true(result.ok);
		end);

		it("uses AUTH LOGIN when PLAIN isn't offered", function ()
			local session, log, result = new_test_session(starttls_opts);
			session:connected(true); -- implicit TLS
			session:receive("220 hi\r\n");
			session:receive("250-mail.example.org\r\n250 AUTH LOGIN\r\n");
			session:receive("334 VXNlcm5hbWU6\r\n");
			session:receive("334 UGFzc3dvcmQ6\r\n");
			session:receive("235 OK\r\n");
			assert.same({ "EHLO example.com\r\n", "AUTH LOGIN\r\n", b64encode("user").."\r\n",
				b64encode("secret").."\r\n", "MAIL FROM:<noreply@example.com>\r\n" }, log);
			assert.is_nil(result.ok);
		end);

		it("fails permanently when STARTTLS isn't offered", function ()
			local session, log, result = new_test_session(starttls_opts);
			session:connected(false);
			session:receive("220 hi\r\n");
			session:receive("250 mail.example.org\r\n");
			assert.is_false(result.ok);
			assert.is_false(result.err.temporary);
			assert.equal("<close>", log[#log]);
		end);

		it("refuses to authenticate without TLS", function ()
			local session, _, result = new_test_session({ helo = "example.com"; tls = "none"; username = "u"; password = "p" });
			session:connected(false);
			session:receive("220 hi\r\n");
			session:receive("250 AUTH PLAIN\r\n");
			assert.is_false(result.ok);
			assert.is_false(result.err.temporary);
		end);

		it("treats 4xx as temporary and 5xx as permanent, without server text", function ()
			local session, _, result = new_test_session({ helo = "example.com"; tls = "none" });
			session:connected(false);
			session:receive("220 hi\r\n250 OK\r\n250 OK\r\n");
			session:receive("450 4.2.0 <user@example.org>: Mailbox busy\r\n");
			assert.is_true(result.err.temporary);
			assert.equal("server replied 450 4.2.0 to rcpt", result.err.text);

			session, _, result = new_test_session({ helo = "example.com"; tls = "none" });
			session:connected(false);
			session:receive("220 hi\r\n250 OK\r\n");
			session:receive("550 5.7.1 Relaying denied for user@example.org\r\n");
			assert.is_false(result.err.temporary);
			assert.falsy(result.err.text:find("@", 1, true));
		end);

		it("requires SMTPUTF8 for non-ASCII addresses", function ()
			local utf8_message = { to = "jürgen@example.org"; subject = "s"; body = "b" };
			local session, _, result = new_test_session({ helo = "example.com"; tls = "none" }, utf8_message);
			session:connected(false);
			session:receive("220 hi\r\n250 mail\r\n");
			assert.is_false(result.ok);

			local log;
			session, log = new_test_session({ helo = "example.com"; tls = "none" }, utf8_message);
			session:connected(false);
			session:receive("220 hi\r\n250-mail\r\n250 SMTPUTF8\r\n");
			assert.equal("MAIL FROM:<noreply@example.com> SMTPUTF8\r\n", log[#log]);
		end);

		it("treats a dropped connection as temporary", function ()
			local session, _, result = new_test_session({ helo = "example.com"; tls = "none" });
			session:connected(false);
			session:receive("220 hi\r\n");
			session:disconnected("closed");
			assert.is_true(result.err.temporary);
		end);

		it("refuses data sent after the STARTTLS reply before encryption", function ()
			-- complete reply in the same packet (response injection)
			local session, log, result = new_test_session(starttls_opts);
			session:connected(false);
			session:receive("220 hi\r\n"..ehlo_tls.."220 Go ahead\r\n250 injected\r\n");
			assert.is_false(result.ok);
			assert.is_false(result.err.temporary);
			assert.equal("unexpected data after STARTTLS reply", result.err.text);
			for _, entry in ipairs(log) do assert.not_equal("<starttls>", entry); end

			-- a partial line in the same packet
			session, log, result = new_test_session(starttls_opts);
			session:connected(false);
			session:receive("220 hi\r\n"..ehlo_tls.."220 Go ahead\r\n250 inj");
			assert.equal("unexpected data after STARTTLS reply", result.err.text);
			for _, entry in ipairs(log) do assert.not_equal("<starttls>", entry); end

			-- anything arriving while the handshake is in progress
			session, log, result = new_test_session(starttls_opts);
			session:connected(false);
			session:receive("220 hi\r\n"..ehlo_tls.."220 Go ahead\r\n");
			assert.equal("<starttls>", log[#log]);
			session:receive("250 injected\r\n");
			assert.equal("unexpected data during STARTTLS", result.err.text);
		end);

		it("treats TLS handshake failures as permanent", function ()
			local session, _, result = new_test_session(starttls_opts);
			session:connected(false);
			session:receive("220 hi\r\n"..ehlo_tls.."220 Go ahead\r\n");
			session:disconnected("handshake failure");
			assert.is_false(result.err.temporary);
			assert.equal("TLS handshake failed: handshake failure", result.err.text);

			-- implicit TLS: the failure arrives before the connection is reported
			session, _, result = new_test_session(starttls_opts);
			session:disconnected("certificate verify failed");
			assert.is_false(result.err.temporary);
		end);

		it("ignores events after it has finished", function ()
			local session, log, result = new_test_session({ helo = "example.com"; tls = "none" });
			session:fail(true, "timed out");
			assert.is_false(session:connected(false));
			session:receive("220 hi\r\n");
			session:disconnected("closed");
			assert.same({ "<close>" }, log);
			assert.equal("timed out", result.err.text);
		end);
	end);

	describe("send()", function ()
		-- Plays a complete plain-text conversation on a captured connection
		local function deliver(connection)
			local writes = {};
			local conn = {
				write = function (_, data) writes[#writes+1] = data; end;
				close = function () writes[#writes+1] = "<close>"; end;
			};
			local l = connection.listeners;
			l.onconnect(conn);
			-- Line mode: complete lines arrive without their line ending
			for _, reply in ipairs({ "220 hi", "250 mail", "250 OK", "250 OK", "354 go", "250 queued" }) do
				l.onincoming(conn, reply);
			end
			return writes;
		end

		it("delivers through the configured server", function ()
			env, s = load_module({ smtp_async_tls = "none"; smtp_async_server = "mail.example.net" });
			local p = env.send(message);
			assert.equal(1, #s.connects);
			assert.same({ host = "mail.example.net"; port = 25 }, s.connects[1].resolver);
			-- line by line, to avoid Prosody 13.0 closing connections whose
			-- server speaks first
			assert.equal("*l", s.connects[1].options.pattern);
			deliver(s.connects[1]);
			assert.equal("resolved", p.state);
			assert.truthy(s.logs[#s.logs]:find("Sent email MSGID to u***@example.org", 1, true));
		end);

		it("joins lines that arrive in parts", function ()
			env, s = load_module({ smtp_async_tls = "none" });
			local writes = {};
			local conn = { write = function (_, data) writes[#writes+1] = data; end; close = function () end };
			env.send(message);
			local l = s.connects[1].listeners;
			l.onconnect(conn);
			l.onincoming(conn, "22", "timeout"); -- partial line
			l.onincoming(conn, "0 mail.example.org ESMTP"); -- rest of the line
			assert.same({ "EHLO example.com\r\n" }, writes);
		end);

		it("rejects invalid messages without connecting", function ()
			local p = env.send({ to = "nobody"; subject = "s"; body = "b" });
			assert.equal("rejected", p.state);
			assert.equal("bad-request", p.reason.condition);
			assert.equal(0, #s.connects);
		end);

		it("rejects everything when credentials would be sent without TLS", function ()
			env, s = load_module({ smtp_async_tls = "none"; smtp_async_username = "u"; smtp_async_password = "p" });
			local p = env.send(message);
			assert.equal("rejected", p.state);
			assert.equal(0, #s.connects);
		end);

		it("uses implicit TLS on port 465", function ()
			env, s = load_module({ smtp_async_tls = "tls" });
			env.send(message);
			assert.equal(465, s.connects[1].resolver.port);
			assert.is_table(s.connects[1].options.sslctx);
		end);

		it("limits simultaneous connections", function ()
			for _ = 1, 6 do env.send(message); end
			assert.equal(4, #s.connects);
		end);

		it("retries temporary failures, then gives up", function ()
			env, s = load_module({ smtp_async_tls = "none"; smtp_async_retries = 2 });
			local p = env.send(message);
			s.connects[1].listeners.onfail(nil, "connection refused");
			local retry = s.timers[#s.timers];
			assert.equal(60, retry.delay);
			assert.equal(1, #s.connects);
			retry.callback();
			assert.equal(2, #s.connects);
			s.connects[2].listeners.onfail(nil, "connection refused");
			assert.equal(300, s.timers[#s.timers].delay);
			s.timers[#s.timers].callback();
			s.connects[3].listeners.onfail(nil, "connection refused");
			assert.equal("rejected", p.state);
			assert.equal("wait", p.reason.type);
		end);

		it("times out a silent server", function ()
			env, s = load_module({ smtp_async_tls = "none" });
			local p = env.send(message);
			s.connects[1].listeners.onconnect({ write = function () end; close = function () end });
			local timeout = s.timers[1];
			assert.equal(30, timeout.delay);
			timeout.callback();
			-- the first retry is scheduled after the timeout
			assert.equal("pending", p.state);
			assert.equal(60, s.timers[#s.timers].delay);
		end);

		it("never logs message content or full addresses", function ()
			env, s = load_module({ smtp_async_tls = "none" });
			env.send({ to = "secret.person@example.org"; subject = "Your code"; body = "123456" });
			deliver(s.connects[1]);
			for _, line in ipairs(s.logs) do
				assert.falsy(line:find("secret.person", 1, true));
				assert.falsy(line:find("123456", 1, true));
			end
		end);
	end);
end);

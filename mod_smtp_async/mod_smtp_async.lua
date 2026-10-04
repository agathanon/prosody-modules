-- Send plain-text email over SMTP without blocking Prosody
local base64 = require "prosody.util.encodings".base64.encode;
local basic_resolver = require "prosody.net.resolvers.basic";
local certmanager = require "prosody.core.certmanager";
local connect = require "prosody.net.connect".connect;
local errors = require "prosody.util.error";
local id = require "prosody.util.id";
local promise = require "prosody.util.promise";
local verify_identity = require "prosody.util.x509".verify_identity;

local t_concat, t_insert, t_remove = table.concat, table.insert, table.remove;

local MAX_CONNECTIONS = 4;
local RETRY_DELAYS = { 60, 300, 900 };

-- Pure helpers (unit tested without Prosody)

local function mask(address)
	local local_part, domain = address:match("^(.+)@(.*)$");
	if not local_part then return "***"; end
	return local_part:sub(1, utf8.offset(local_part, 2) - 1).."***@"..domain;
end

local function is_ascii(s)
	return not s:find("[\128-\255]");
end

-- Parse an SMTP reply line: code, whether more lines follow, text
local function parse_reply_line(line)
	local code, sep, text = line:match("^(%d%d%d)([ %-]?)(.*)$");
	if not code then return nil; end
	return tonumber(code), sep == "-", text;
end

-- Returns a function that is fed incoming data and returns complete replies
local function new_reply_reader()
	local buffer, lines = "", {};
	return function (data)
		buffer = buffer..data;
		local replies = {};
		while true do
			local line, rest = buffer:match("^(.-)\r?\n(.*)$");
			if not line then break; end
			buffer = rest;
			local code, more, text = parse_reply_line(line);
			if not code then
				return nil, "invalid reply from server";
			end
			t_insert(lines, text);
			if not more then
				t_insert(replies, { code = code; lines = lines });
				lines = {};
			end
		end
		if #buffer > 4096 then
			return nil, "reply line too long";
		end
		return replies;
	end
end

-- EHLO reply lines after the first are "KEYWORD params"
local function parse_capabilities(lines)
	local caps = {};
	for i = 2, #lines do
		local keyword, params = lines[i]:match("^(%S+)%s*(.*)$");
		if keyword then
			caps[keyword:upper()] = params:upper();
		end
	end
	return caps;
end

local function has_word(list, word)
	for w in list:gmatch("%S+") do
		if w == word then return true; end
	end
	return false;
end

local days = { "Sun", "Mon", "Tue", "Wed", "Thu", "Fri", "Sat" };
local months = { "Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec" };

-- RFC 5322 date, independent of the C locale
local function format_date(t)
	local d = os.date("!*t", t);
	return ("%s, %02d %s %04d %02d:%02d:%02d +0000"):format(
		days[d.wday], d.day, months[d.month], d.year, d.hour, d.min, d.sec);
end

-- Split a UTF-8 string into chunks of at most max_bytes without breaking characters
local function utf8_chunks(s, max_bytes)
	local chunks, start = {}, 1;
	while start <= #s do
		local stop = math.min(start + max_bytes - 1, #s);
		while stop > start and stop < #s and s:byte(stop + 1) >= 0x80 and s:byte(stop + 1) < 0xC0 do
			stop = stop - 1;
		end
		t_insert(chunks, s:sub(start, stop));
		start = stop + 1;
	end
	return chunks;
end

-- RFC 2047 encoded-words for non-ASCII or long header values, folded across lines
local function encode_header_value(value)
	if is_ascii(value) and #value <= 900 then
		return value;
	end
	local words = {};
	for _, chunk in ipairs(utf8_chunks(value, 45)) do
		t_insert(words, "=?UTF-8?B?"..base64(chunk).."?=");
	end
	return t_concat(words, "\r\n ");
end

local function wrap_lines(s, width)
	local lines = {};
	for i = 1, #s, width do
		t_insert(lines, s:sub(i, i + width - 1));
	end
	return t_concat(lines, "\r\n");
end

local reserved_headers = {
	["date"] = true; ["from"] = true; ["to"] = true; ["subject"] = true; ["message-id"] = true;
	["mime-version"] = true; ["content-type"] = true; ["content-transfer-encoding"] = true;
};

local function valid_utf8(s)
	return type(s) == "string" and utf8.len(s) ~= nil;
end

local function valid_address(address)
	return valid_utf8(address) and address:match("^[^%s%c<>@]+@[^%s%c<>@]+$") ~= nil;
end

-- Returns a checked copy of the message, or nil and a reason
local function validate_message(message, default_from)
	if type(message) ~= "table" then
		return nil, "message must be a table";
	end
	local from = message.from or default_from;
	if not valid_address(message.to) then
		return nil, "invalid recipient address";
	elseif not valid_address(from) then
		return nil, "invalid sender address";
	elseif not valid_utf8(message.subject) or message.subject:find("[\r\n]") then
		return nil, "invalid subject";
	elseif not valid_utf8(message.body) then
		return nil, "invalid body";
	end
	local headers = {};
	for name, value in pairs(message.headers or {}) do
		if type(name) ~= "string" or not name:match("^%a[%w%-]*$") or reserved_headers[name:lower()] then
			return nil, "invalid header name";
		elseif type(value) ~= "string" or value:find("[%c]") or not is_ascii(value) or #value > 900 then
			return nil, "invalid value for header "..name;
		end
		headers[name] = value;
	end
	return { to = message.to; from = from; subject = message.subject; body = message.body; headers = headers };
end

-- The message as sent after DATA, with CRLF line endings and a final CRLF
local function format_message(message, now, message_id)
	local header_lines = {
		"Date: "..format_date(now);
		"From: "..message.from;
		"To: "..message.to;
		"Subject: "..encode_header_value(message.subject);
		"Message-ID: "..message_id;
		"MIME-Version: 1.0";
		"Content-Type: text/plain; charset=utf-8";
		"Content-Transfer-Encoding: base64";
	};
	local names = {};
	for name in pairs(message.headers) do t_insert(names, name); end
	table.sort(names);
	for _, name in ipairs(names) do
		t_insert(header_lines, name..": "..message.headers[name]);
	end
	local body = message.body:gsub("\r?\n", "\r\n");
	return t_concat(header_lines, "\r\n").."\r\n\r\n"..wrap_lines(base64(body), 76).."\r\n";
end

-- Escape lines starting with "." and append the end-of-data marker
local function dot_stuff(data)
	data = data:gsub("\r\n%.", "\r\n..");
	if data:sub(1, 1) == "." then
		data = "."..data;
	end
	return data..".\r\n";
end

-- The SMTP conversation for one message, independent of networking.
-- transport: { write(data), starttls(), close() }
-- on_done(ok, err): err is { temporary = boolean; text = string }
local session_methods = {};
local session_mt = { __index = session_methods };

local function new_session(message, data, opts, transport, on_done)
	return setmetatable({
		message = message; data = data; opts = opts; transport = transport; on_done = on_done;
		state = "connecting"; tls_active = false; caps = {}; progress = 0;
		read = new_reply_reader();
	}, session_mt);
end

function session_methods:finish(ok, err)
	if self.state == "done" then return; end
	self.state = "done";
	if ok then
		self.transport.write("QUIT\r\n");
	end
	self.transport.close();
	self.on_done(ok, err);
end

function session_methods:fail(temporary, text)
	self:finish(false, { temporary = temporary; text = text });
end

function session_methods:send(state, command, log_as)
	self.state = state;
	module:log("debug", "SMTP send: %s", log_as or command);
	self.transport.write(command.."\r\n");
end

-- Returns false if the session already ended (e.g. timed out while connecting)
function session_methods:connected(tls_active)
	if self.state ~= "connecting" then return false; end
	self.tls_active = tls_active;
	self.state = "greeting";
	return true;
end

function session_methods:tls_ready()
	if self.state ~= "tls-handshake" then return; end
	self.progress = self.progress + 1;
	self.tls_active = true;
	self:send("ehlo", "EHLO "..self.opts.helo);
end

function session_methods:disconnected(reason)
	if self.state == "done" then return; end
	reason = tostring(reason or "unknown reason");
	-- Certificate problems won't fix themselves, so don't retry them. With
	-- implicit TLS the handshake fails before the connection is reported,
	-- so it can only be recognized by the error text.
	if self.state == "tls-handshake" or reason:find("certificate", 1, true) then
		return self:fail(false, "TLS handshake failed: "..reason);
	end
	self:fail(true, "connection closed: "..reason);
end

function session_methods:receive(data)
	if self.state == "done" then return; end
	local replies, err = self.read(data);
	if not replies then
		return self:fail(false, err);
	end
	for _, reply in ipairs(replies) do
		if self.state == "done" then return; end
		self.progress = self.progress + 1;
		self:handle_reply(reply);
	end
end

local expected_codes = {
	greeting = { [220] = true };
	ehlo = { [250] = true };
	starttls = { [220] = true };
	auth = { [235] = true };
	["auth-login-user"] = { [334] = true };
	["auth-login-pass"] = { [334] = true };
	mail = { [250] = true };
	rcpt = { [250] = true; [251] = true };
	data = { [354] = true };
	sent = { [250] = true };
};

function session_methods:handle_reply(reply)
	local state, code = self.state, reply.code;
	module:log("debug", "SMTP reply in state %s: %d", state, code);
	local expected = expected_codes[state];
	if not expected then
		return self:fail(false, ("unexpected reply %d in state %s"):format(code, state));
	elseif not expected[code] then
		-- Only the code and enhanced status are kept: server text may contain addresses
		local status = reply.lines[1]:match("^(%d%.%d+%.%d+)");
		local text = ("server replied %d%s to %s"):format(code, status and " "..status or "", state);
		return self:fail(code >= 400 and code < 500, text);
	end

	local opts = self.opts;
	if state == "greeting" then
		self:send("ehlo", "EHLO "..opts.helo);
	elseif state == "ehlo" then
		self.caps = parse_capabilities(reply.lines);
		if opts.tls == "starttls" and not self.tls_active then
			if not self.caps.STARTTLS then
				return self:fail(false, "server does not offer STARTTLS");
			end
			self:send("starttls", "STARTTLS");
		else
			self:authenticate();
		end
	elseif state == "starttls" then
		self.state = "tls-handshake";
		self.transport.starttls();
	elseif state == "auth-login-user" then
		self:send("auth-login-pass", base64(opts.username), "(username)");
	elseif state == "auth-login-pass" then
		self:send("auth", base64(opts.password), "(password)");
	elseif state == "auth" then
		self:mail_from();
	elseif state == "mail" then
		self:send("rcpt", "RCPT TO:<"..self.message.to..">", "RCPT TO");
	elseif state == "rcpt" then
		self:send("data", "DATA");
	elseif state == "data" then
		self.state = "sent";
		module:log("debug", "SMTP send: (message, %d bytes)", #self.data);
		self.transport.write(dot_stuff(self.data));
	elseif state == "sent" then
		self:finish(true);
	end
end

function session_methods:authenticate()
	local opts = self.opts;
	if not opts.username then
		return self:mail_from();
	elseif not self.tls_active then
		return self:fail(false, "refusing to authenticate without TLS");
	end
	local mechanisms = self.caps.AUTH or "";
	if has_word(mechanisms, "PLAIN") then
		self:send("auth", "AUTH PLAIN "..base64("\0"..opts.username.."\0"..opts.password), "AUTH PLAIN (credentials)");
	elseif has_word(mechanisms, "LOGIN") then
		self:send("auth-login-user", "AUTH LOGIN");
	else
		self:fail(false, "server offers no supported authentication mechanism");
	end
end

function session_methods:mail_from()
	local message = self.message;
	local needs_utf8 = not (is_ascii(message.from) and is_ascii(message.to));
	if needs_utf8 and not self.caps.SMTPUTF8 then
		return self:fail(false, "address needs SMTPUTF8, which the server does not offer");
	end
	self:send("mail", "MAIL FROM:<"..message.from..">"..(needs_utf8 and " SMTPUTF8" or ""), "MAIL FROM");
end

-- Configuration

local server = module:get_option_string("smtp_async_server", "localhost");
local tls_mode = module:get_option_enum("smtp_async_tls", "starttls", "tls", "none");
local default_ports = { starttls = 587; tls = 465; none = 25 };
local port = module:get_option_integer("smtp_async_port", default_ports[tls_mode], 1, 65535);
local username = module:get_option_string("smtp_async_username");
local password = module:get_option_string("smtp_async_password");
local default_from = module:get_option_string("smtp_async_from", "noreply@"..module.host);
local helo = module:get_option_string("smtp_async_helo", module.host);
local cafile = module:get_option_path("smtp_async_cafile", nil, "config");
local verify_certificate = module:get_option_boolean("smtp_async_verify_certificate", true);
local step_timeout = module:get_option_period("smtp_async_timeout", "30s");
local retries = module:get_option_integer("smtp_async_retries", 3, 0);

-- Problems that make every send fail
local config_error;
if (username == nil) ~= (password == nil) then
	config_error = "smtp_async_username and smtp_async_password must be set together";
elseif username and tls_mode == "none" then
	config_error = "refusing to send credentials with smtp_async_tls = \"none\"";
elseif helo:find("%s") then
	config_error = "invalid smtp_async_helo";
end

local tls_ctx;
if not config_error and tls_mode ~= "none" then
	local err;
	tls_ctx, err = certmanager.create_context("smtp_async port 0", "client", {
		cafile = cafile;
		verify = verify_certificate and "peer" or "none";
	});
	if not tls_ctx then
		config_error = "unable to create TLS context: "..tostring(err);
	end
end
if config_error then
	module:log("error", "Configuration problem, all email will fail: %s", config_error);
end
if not verify_certificate then
	module:log("warn", "Not verifying the mail server's certificate (smtp_async_verify_certificate = false)");
end

local session_opts = { helo = helo; tls = tls_mode; username = username; password = password };

-- Networking

local function check_certificate(conn)
	if not verify_certificate then return true; end
	if not conn:ssl_peerverification() then
		return nil, "mail server certificate is not trusted";
	end
	local cert = conn:ssl_peercertificate();
	if not cert or not verify_identity(server, false, cert) then
		return nil, "mail server certificate does not match "..server;
	end
	return true;
end

local queue, active = {}, 0;
local pump;

local function finish_job(job, ok, err)
	local recipient = mask(job.message.to);
	if ok then
		module:log("info", "Sent email %s to %s", job.id, recipient);
		return job.resolve(true);
	end
	if err.temporary and job.attempt <= retries then
		local delay = RETRY_DELAYS[job.attempt] or RETRY_DELAYS[#RETRY_DELAYS];
		module:log("warn", "Email %s to %s failed (attempt %d): %s; retrying in %ds",
			job.id, recipient, job.attempt, err.text, delay);
		job.attempt = job.attempt + 1;
		module:add_timer(delay, function ()
			t_insert(queue, job);
			pump();
		end);
		return;
	end
	module:log("warn", "Email %s to %s failed (attempt %d): %s", job.id, recipient, job.attempt, err.text);
	job.reject(errors.new({
		type = err.temporary and "wait" or "cancel";
		condition = err.temporary and "remote-server-timeout" or "undefined-condition";
		text = err.text;
	}));
end

local function attempt(job)
	active = active + 1;
	local conn;
	local transport = {
		write = function (data) if conn then conn:write(data); end end;
		starttls = function () conn:starttls(tls_ctx); end;
		close = function () if conn then conn:close(); end end;
	};
	local timeout_timer;
	local session = new_session(job.message, job.data, session_opts, transport, function (ok, err)
		if timeout_timer then timeout_timer:stop(); end
		active = active - 1;
		finish_job(job, ok, err);
		pump();
	end);

	-- Fail the session if a step makes no progress within the timeout
	local last_progress = 0;
	timeout_timer = module:add_timer(step_timeout, function ()
		if session.state == "done" then return; end
		if session.progress == last_progress then
			session:fail(true, "timed out in state "..session.state);
			return;
		end
		last_progress = session.progress;
		return step_timeout;
	end);

	local listeners = {};
	function listeners.onconnect(c)
		if session.state ~= "connecting" then
			return c:close();
		end
		conn = c;
		if tls_mode == "tls" then
			local ok, err = check_certificate(c);
			if not ok then return session:fail(false, err); end
		end
		session:connected(tls_mode == "tls");
	end
	-- Reading line by line (pattern "*l" below), a complete line arrives
	-- without its line ending and with no error; a partial line arrives
	-- with an error such as "timeout"
	function listeners.onincoming(_, data, err)
		session:receive(err and data or data.."\n");
	end
	function listeners.onstatus(c, status)
		if status == "ssl-handshake-complete" and session.state == "tls-handshake" then
			local ok, err = check_certificate(c);
			if not ok then return session:fail(false, err); end
			session:tls_ready();
		end
	end
	function listeners.ondisconnect(_, reason)
		session:disconnected(reason);
	end
	function listeners.onfail(_, reason)
		session:disconnected(reason or "connection failed");
	end

	module:log("debug", "Connecting to %s port %d for email %s", server, port, job.id);
	-- Read line by line: Prosody 13.0's net.server_epoll closes a new
	-- connection if its first read returns only part of the data available
	-- before the connection is marked as connected, which happens when a
	-- fast server's greeting arrives first. A complete line avoids that.
	connect(basic_resolver.new(server, port, "tcp", { servername = server }), listeners,
		{ sslctx = tls_mode == "tls" and tls_ctx or nil; pattern = "*l" });
end

function pump()
	while active < MAX_CONNECTIONS and #queue > 0 do
		attempt(t_remove(queue, 1));
	end
end

-- API

-- Returns a promise that resolves with true once the server accepts the message
function send(message) --luacheck: ignore 131/send
	return promise.new(function (resolve, reject)
		if config_error then
			return reject(errors.new({ type = "cancel"; condition = "internal-server-error"; text = config_error }));
		end
		local checked, invalid = validate_message(message, default_from);
		if not checked then
			return reject(errors.new({ type = "modify"; condition = "bad-request"; text = invalid }));
		end
		local message_id = id.medium();
		t_insert(queue, {
			id = message_id;
			message = checked;
			data = format_message(checked, os.time(), "<"..message_id.."@"..helo..">");
			attempt = 1;
			resolve = resolve;
			reject = reject;
		});
		pump();
	end);
end

-- Exposed for unit tests, not a public API
_test = { --luacheck: ignore 131/_test
	mask = mask;
	parse_reply_line = parse_reply_line;
	new_reply_reader = new_reply_reader;
	parse_capabilities = parse_capabilities;
	format_date = format_date;
	utf8_chunks = utf8_chunks;
	encode_header_value = encode_header_value;
	validate_message = validate_message;
	format_message = format_message;
	dot_stuff = dot_stuff;
	new_session = new_session;
};

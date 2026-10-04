-- Unit tests for mod_recovery_email_reset, run outside Prosody with stubbed APIs
local module_dir = debug.getinfo(1, "S").source:match("^@(.-)spec/[^/]*$");
local module_path = module_dir.."mod_recovery_email_reset.lua";

local function xml_escape(s)
	return (s:gsub("[&<>\"']", { ["&"] = "&amp;"; ["<"] = "&lt;"; [">"] = "&gt;"; ['"'] = "&quot;"; ["'"] = "&apos;" }));
end

-- Stand-in for util.interpolation with the forms the templates use:
-- {name}, {name!} (unescaped), {name&shown if set} and {name~shown if not set}
local function new_render(escape)
	local function render(template, values)
		return (template:gsub("%b{}", function (block)
			local name, raw, opt, rest = block:sub(2, -2):match("^([%a_][%w_]*)(!?)([&~]?)(.*)$");
			if not name then return; end
			local value = values[name];
			if opt == "&" then return value and render(rest, values) or ""; end
			if opt == "~" then return value and "" or render(rest, values); end
			if value == nil then return; end
			return raw == "!" and tostring(value) or escape(tostring(value));
		end));
	end
	return render;
end

local function new_store()
	local data = {};
	return {
		data = data;
		get = function (_, key) return data[key]; end;
		set = function (_, key, value) data[key] = value; return true; end;
		users = function ()
			local keys = {};
			for k in pairs(data) do keys[#keys+1] = k; end
			local i = 0;
			return function () i = i + 1; return keys[i]; end;
		end;
	};
end

local function to_hex(s)
	return (s:gsub(".", function (c) return ("%02x"):format(c:byte()); end));
end

local function urldecode(s)
	return (s:gsub("+", " "):gsub("%%(%x%x)", function (h) return string.char(tonumber(h, 16)); end));
end

local function formdecode(s)
	if not s:match("=") then return urldecode(s); end
	local r = {};
	for k, v in s:gmatch("([^=&]*)=([^&]*)") do r[urldecode(k)] = urldecode(v); end
	return r;
end

local function formencode(t)
	local parts = {};
	for k, v in pairs(t) do
		parts[#parts+1] = k.."="..v:gsub("[^%w]", function (c) return ("%%%02X"):format(c:byte()); end);
	end
	return table.concat(parts, "&");
end

-- Stand-in for util.ip: parses IPv4 and IPv6 (with "::" and embedded IPv4)
local function v6_packed(addr)
	local v4 = addr:match("(%d+%.%d+%.%d+%.%d+)$");
	if v4 then
		local a, b, c, d = v4:match("(%d+)%.(%d+)%.(%d+)%.(%d+)");
		addr = addr:sub(1, -#v4 - 1)..("%x:%x"):format(a * 256 + b, c * 256 + d);
	end
	local head, tail = addr:match("^(.-)::(.-)$");
	local function groups(part)
		local t = {};
		for g in part:gmatch("[^:]+") do t[#t+1] = tonumber(g, 16); end
		return t;
	end
	local hg, tg = groups(head or addr), groups(tail or "");
	local all = {};
	for _, g in ipairs(hg) do all[#all+1] = g; end
	for _ = 1, 8 - #hg - #tg do all[#all+1] = 0; end
	for _, g in ipairs(tg) do all[#all+1] = g; end
	local bytes = {};
	for _, g in ipairs(all) do bytes[#bytes+1] = string.char(g // 256, g % 256); end
	return table.concat(bytes);
end

local function new_ip(addr)
	if addr:match("^%d+%.%d+%.%d+%.%d+$") then
		return { proto = "IPv4"; normal = addr; packed = addr };
	elseif addr:find(":", 1, true) then
		local packed = v6_packed(addr);
		return { proto = "IPv6"; packed = packed; normal = to_hex(packed) };
	end
	return nil, "invalid";
end

local ip_stub = {
	new_ip = new_ip;
	truncate = function (ip, bits)
		local packed = ip.packed:sub(1, bits // 8)..("\0"):rep(#ip.packed - bits // 8);
		return { proto = ip.proto; packed = packed; normal = to_hex(packed) };
	end;
};

-- Load a fresh instance; config sets module options
local function load_module(config)
	config = config or {};
	local stores = { recovery_email_reset_tokens = new_store(); recovery_email_reset_pending = new_store() };
	local events, hooks, logs, routes, daily = {}, {}, {}, nil, {};
	local accounts = { alice = { enabled = true; password = "old" } };
	local reset_addresses = { alice = "alice@example.org" };
	local throttles = {}; -- by limit: { allow, polls }
	local loaded_modules = {};
	local token_counter = 0;

	local function option(name, default)
		if config[name] == nil then return default; end
		return config[name];
	end

	local stubs = {
		["prosody.util.cache"] = {
			new = function ()
				local t = {};
				return { get = function (_, k) return t[k]; end, set = function (_, k, v) t[k] = v; end };
			end;
		};
		["prosody.util.http"] = { formdecode = formdecode };
		["prosody.util.hashes"] = { sha256 = function (s, hex) assert(hex); return to_hex(s); end };
		["prosody.util.id"] = {
			long = function ()
				token_counter = token_counter + 1;
				return ("Token%d_abcdefghijklmnopqrstuvwxyz"):format(token_counter);
			end;
		};
		["prosody.util.interpolation"] = { new = function (_, escape) return new_render(escape); end };
		["prosody.util.ip"] = ip_stub;
		["prosody.util.jid"] = {
			prepped_split = function (jid)
				local node, host = jid:match("^([^@/%s<>]+)@([^@/%s<>]+)$");
				if not node then return nil; end
				return node:lower(), host:lower();
			end;
		};
		["prosody.core.modulemanager"] = {
			get_module = function (_, name) return loaded_modules[name]; end;
		};
		["prosody.util.throttle"] = {
			create = function (limit)
				throttles[limit] = throttles[limit] or { allow = true; polls = 0; created = 0 };
				local state = throttles[limit];
				state.created = state.created + 1; -- one per rate-limit key
				return {
					poll = function () state.polls = state.polls + 1; return state.allow; end;
				};
			end;
		};
		["prosody.core.usermanager"] = {
			user_exists = function (username) return accounts[username] ~= nil; end;
			user_is_enabled = function (username) return accounts[username] and accounts[username].enabled; end;
			set_password = function (username, password)
				accounts[username].password = password;
				return true;
			end;
		};
		["prosody.util.encodings"] = { utf8 = { valid = function (s) return utf8.len(s) ~= nil; end } };
		["prosody.util.stanza"] = { xml_escape = xml_escape };
	};

	local recovery_email = {
		get_reset_address = function (username)
			local address = reset_addresses[username];
			if address then return address; end
			return nil, "none";
		end;
	};

	local module = {
		host = "example.com";
		log = function (_, level, fmt, ...) logs[#logs+1] = level..": "..fmt:format(...); end;
		depends = function (_, name) if name == "recovery_email" then return recovery_email; end end;
		get_option_period = function (_, name, default)
			local value = option(name, default);
			return value == "1 hour" and 3600 or value;
		end;
		get_option_integer = function (_, name, default) return option(name, default); end;
		get_option_string = function (_, name, default) return option(name, default); end;
		get_option_path = function (_, name, default) return option(name, default); end;
		get_directory = function () return module_dir:gsub("/$", ""); end;
		load_resource = function (_, path) return io.open(path); end;
		open_store = function (_, name) return assert(stores[name], "unexpected store "..name); end;
		http_url = function () return option("http_url", "https://example.com/recovery_email_reset"); end;
		fire_event = function (_, name, payload) events[#events+1] = { name = name; payload = payload }; end;
		hook_global = function (_, name, handler) hooks[name] = handler; end;
		provides = function (_, kind, item) assert(kind == "http"); routes = item; end;
		daily = function (_, name, f) daily[#daily+1] = { name = name; run = f }; end;
	};
	local env = setmetatable({
		module = module;
		require = function (name) return assert(stubs[name], "unexpected require: "..name); end;
	}, { __index = _G });
	assert(loadfile(module_path, "t", env))();

	return {
		env = env; stores = stores; events = events; hooks = hooks; logs = logs; routes = routes;
		daily = daily; accounts = accounts; reset_addresses = reset_addresses; throttles = throttles;
		loaded_modules = loaded_modules;
	};
end

-- Calls a route like mod_http would; returns status, body and headers
local function http(s, method, path, form, ip, headers, peer)
	local response = { headers = {} };
	ip = ip or "192.0.2.1";
	local event = {
		request = {
			ip = ip; body = form and formencode(form) or ""; headers = headers or {};
			conn = { ip = function () return peer or ip; end };
		};
		response = response;
	};
	local body;
	local reset_token = path:match("^/reset/(.*)$");
	if reset_token then
		body = s.routes.route[method.." /reset/*"](event, reset_token);
	else
		body = s.routes.route[method](event);
	end
	return response.status_code, body, response.headers;
end

-- The page's paragraphs, without the site name
local function text(body)
	local paragraphs = {};
	for attrs, p in body:gmatch("<p([^>]*)>(.-)</p>") do
		if attrs ~= ' class="site"' then paragraphs[#paragraphs+1] = p; end
	end
	return table.concat(paragraphs, "\n");
end

-- Requests a link for alice and returns its token
local function request_link(s)
	http(s, "POST", "/", { jid = "alice@example.com" });
	local event = s.events[#s.events];
	assert(event and event.name == "recovery-email-reset-requested", "no reset requested");
	return event.payload.url:match("/reset/(.+)$"), event.payload;
end

describe("mod_recovery_email_reset", function ()
	local s;
	before_each(function ()
		s = load_module();
	end);

	describe("pages", function ()
		it("serve the request form with security headers and no CORS", function ()
			local status, body, headers = http(s, "GET", "/");
			assert.equal(200, status);
			assert.truthy(body:find('<form method="post" action="https://example.com/recovery_email_reset">', 1, true));
			assert.truthy(body:find('placeholder="name@example.com"', 1, true));
			assert.falsy(body:find("{%a"));
			assert.equal("text/html; charset=utf-8", headers.content_type);
			assert.matches("default%-src 'none'", headers.content_security_policy);
			assert.matches("frame%-ancestors 'none'", headers.content_security_policy);
			assert.equal("no-referrer", headers.referrer_policy);
			assert.equal("no-store", headers.cache_control);
			assert.equal("nosniff", headers.x_content_type_options);
			assert.same({ enabled = false }, s.routes.cors);
		end);

		it("escape what users submit", function ()
			local _, body = http(s, "POST", "/", { jid = "<script>alert(1)</script>" });
			assert.falsy(body:find("<script>", 1, true));
			assert.truthy(body:find("&lt;script&gt;", 1, true));
		end);
	end);

	describe("requests", function ()
		it("send a link for an eligible account", function ()
			local status, body = http(s, "POST", "/", { jid = "alice@example.com" });
			assert.equal(200, status);
			assert.equal("If this account has a verified recovery email address, we&apos;ve sent a link to it. "
				.."The link is valid for 1 hour.", text(body));
			local event = s.events[1];
			assert.equal("recovery-email-reset-requested", event.name);
			local token = event.payload.url:match("^https://example%.com/recovery_email_reset/reset/(.+)$");
			assert.equal("Token1_abcdefghijklmnopqrstuvwxyz", token);
			assert.same({ username = "alice"; host = "example.com"; email = "alice@example.org";
				url = event.payload.url; expires = event.payload.expires }, event.payload);
			assert.near(os.time() + 3600, event.payload.expires, 2);
		end);

		it("store only a hash of the token", function ()
			local token = request_link(s);
			for key, value in pairs(s.stores.recovery_email_reset_tokens.data) do
				assert.equal(to_hex(token), key);
				assert.falsy(tostring(value.username..value.email):find(token, 1, true));
			end
		end);

		it("accept a bare username", function ()
			http(s, "POST", "/", { jid = "  Alice " });
			assert.equal(1, #s.events);
		end);

		it("give the same answer whether or not an email is sent", function ()
			local _, eligible = http(s, "POST", "/", { jid = "alice@example.com" });
			s.reset_addresses.alice = nil;
			local cases = {
				{ jid = "alice@example.com" }; -- no usable address
				{ jid = "nobody@example.com" }; -- no such account
				{ jid = "alice@elsewhere.example" }; -- another host
			};
			s.accounts.bob = { enabled = false };
			s.reset_addresses.bob = "bob@example.org";
			cases[#cases+1] = { jid = "bob@example.com" }; -- disabled account
			for _, form in ipairs(cases) do
				local status, body = http(s, "POST", "/", form);
				assert.equal(200, status);
				assert.equal(eligible, body);
			end
			assert.equal(1, #s.events);
		end);

		it("ask again for input that isn't a JID", function ()
			local status, body = http(s, "POST", "/", { jid = "not valid@example.com" });
			assert.equal(400, status);
			assert.truthy(text(body):find("Enter your chat address, e.g. name@example.com.", 1, true));
			assert.truthy(body:find('value="not valid@example.com"', 1, true));
		end);

		it("are rate limited per IP and per JID", function ()
			assert.is_nil(s.throttles[3]); -- created on first use
			http(s, "POST", "/", { jid = "alice@example.com" });
			s.throttles[10].allow = false;
			local status, body = http(s, "POST", "/", { jid = "alice@example.com" });
			assert.equal(429, status);
			assert.truthy(text(body):find("Too many requests", 1, true));
			s.throttles[10].allow = true;
			s.throttles[3].allow = false;
			assert.equal(429, (http(s, "POST", "/", { jid = "alice@example.com" })));
			assert.equal(1, #s.events);
		end);

		it("apply per-IP limits to whole IPv6 /64s, and to IPv4-mapped addresses as IPv4", function ()
			local function keys_created()
				return s.throttles[10] and s.throttles[10].created or 0;
			end
			http(s, "POST", "/", { jid = "a" }, "2001:db8:1:2::1");
			http(s, "POST", "/", { jid = "b" }, "2001:db8:1:2:ffff:ffff:ffff:ffff");
			assert.equal(1, keys_created()); -- same /64, same limit
			http(s, "POST", "/", { jid = "c" }, "2001:db8:1:3::1");
			assert.equal(2, keys_created()); -- another /64
			http(s, "POST", "/", { jid = "d" }, "192.0.2.7");
			http(s, "POST", "/", { jid = "e" }, "::ffff:192.0.2.7");
			assert.equal(3, keys_created()); -- mapped address counts as the IPv4 address
		end);

		it("warn once when an untrusted proxy forwards requests", function ()
			local function proxy_warnings()
				local n = 0;
				for _, line in ipairs(s.logs) do
					if line:match("^warn: Requests from 10%.0%.0%.1 carry X%-Forwarded%-For") then n = n + 1; end
				end
				return n;
			end
			-- trusted proxy: mod_http has replaced request.ip with the client's address
			http(s, "POST", "/", { jid = "a" }, "198.51.100.9", { x_forwarded_for = "198.51.100.9" }, "10.0.0.1");
			assert.equal(0, proxy_warnings());
			-- untrusted: request.ip is still the proxy's address
			http(s, "POST", "/", { jid = "a" }, "10.0.0.1", { x_forwarded_for = "198.51.100.9" });
			http(s, "POST", "/", { jid = "a" }, "10.0.0.1", { x_forwarded_for = "198.51.100.9" });
			assert.equal(1, proxy_warnings());
		end);

		it("replace the previous link", function ()
			local first = request_link(s);
			local second = request_link(s);
			assert.equal(404, (http(s, "GET", "/reset/"..first)));
			assert.equal(200, (http(s, "GET", "/reset/"..second)));
		end);
	end);

	describe("reset links", function ()
		it("show the password form", function ()
			local token = request_link(s);
			local status, body = http(s, "GET", "/reset/"..token);
			assert.equal(200, status);
			assert.truthy(body:find("Choose a new password for <strong>alice@example.com</strong>", 1, true));
			assert.truthy(body:find('action="https://example.com/recovery_email_reset/reset/'..token..'"', 1, true));
			assert.truthy(body:find('minlength="8"', 1, true));
			assert.falsy(body:find("{%a"));
		end);

		it("are refused when unknown, malformed, expired or for a changed address", function ()
			assert.equal(404, (http(s, "GET", "/reset/unknown")));
			assert.equal(404, (http(s, "GET", "/reset/../../etc")));
			assert.equal(404, (http(s, "GET", "/reset/"..("a"):rep(100))));

			local token = request_link(s);
			s.reset_addresses.alice = "new@example.org";
			assert.equal(404, (http(s, "GET", "/reset/"..token)));

			s.reset_addresses.alice = "alice@example.org";
			token = request_link(s);
			s.stores.recovery_email_reset_tokens.data[to_hex(token)].expires = os.time() - 1;
			local status, body = http(s, "GET", "/reset/"..token);
			assert.equal(404, status);
			assert.truthy(body:find("Request a new reset link", 1, true));
			assert.is_nil(s.stores.recovery_email_reset_tokens.data[to_hex(token)]);
		end);

		it("are refused once the account is disabled", function ()
			local token = request_link(s);
			s.accounts.alice.enabled = false;
			assert.equal(404, (http(s, "GET", "/reset/"..token)));
		end);
	end);

	describe("password submissions", function ()
		local token;
		before_each(function ()
			token = request_link(s);
		end);

		local function submit(password, confirm)
			return http(s, "POST", "/reset/"..token, { password = password; confirm = confirm or password });
		end

		it("change the password once, and confirm it", function ()
			local status, body = submit("correct horse ü");
			assert.equal(200, status);
			assert.equal("Your password has been changed. You can now sign in with it.", text(body));
			assert.equal("correct horse ü", s.accounts.alice.password);
			assert.same({ name = "recovery-email-password-reset";
				payload = { username = "alice"; host = "example.com"; email = "alice@example.org" } }, s.events[2]);
			assert.same({}, s.stores.recovery_email_reset_pending.data);
			assert.same({}, s.stores.recovery_email_reset_tokens.data);
			assert.equal(404, (submit("another password")));
			assert.equal("correct horse ü", s.accounts.alice.password);
		end);

		it("check the passwords match and follow the rules", function ()
			local status, body = submit("abcdefgh", "abcdefgi");
			assert.equal(400, status);
			assert.truthy(text(body):find("The passwords don&apos;t match.", 1, true));
			status, body = submit("short");
			assert.equal(400, status);
			assert.truthy(text(body):find("The password must be at least 8 characters long.", 1, true));
			assert.equal(400, (submit("\255\254\253\252\251\250\249\248")));
			assert.equal(400, (submit(("x"):rep(1025))));
			assert.equal(400, (submit("")));
			assert.equal("old", s.accounts.alice.password);
		end);

		it("apply mod_password_policy when it's loaded", function ()
			s.loaded_modules.password_policy = {
				check_password = function (password, info)
					if password:find(info.username, 1, true) then
						return nil, "Password must not include your username";
					end
					return true;
				end;
			};
			local status, body = submit("my name is alice");
			assert.equal(400, status);
			assert.truthy(text(body):find("Password must not include your username", 1, true));
			assert.equal(200, (submit("something else entirely")));
		end);

		it("are rate limited per IP", function ()
			s.throttles[10].allow = false;
			assert.equal(429, (submit("correct horse")));
			assert.equal("old", s.accounts.alice.password);
		end);

		it("never log tokens or passwords", function ()
			submit("correct horse");
			for _, line in ipairs(s.logs) do
				assert.falsy(line:find(token, 1, true));
				assert.falsy(line:find("correct horse", 1, true));
			end
		end);
	end);

	describe("housekeeping", function ()
		it("drops pending links when the password changes or the account is deleted", function ()
			request_link(s);
			s.hooks["user-password-changed"]({ username = "alice"; host = "example.com" });
			assert.same({}, s.stores.recovery_email_reset_tokens.data);
			request_link(s);
			s.hooks["user-deleted"]({ username = "alice"; host = "elsewhere.example" });
			assert.is_not.same({}, s.stores.recovery_email_reset_tokens.data);
			s.hooks["user-deleted"]({ username = "alice"; host = "example.com" });
			assert.same({}, s.stores.recovery_email_reset_tokens.data);
		end);

		it("removes expired links daily", function ()
			local token = request_link(s);
			assert.equal(1, #s.daily);
			s.daily[1].run();
			assert.is_not_nil(s.stores.recovery_email_reset_tokens.data[to_hex(token)]);
			s.stores.recovery_email_reset_tokens.data[to_hex(token)].expires = os.time() - 1;
			s.daily[1].run();
			assert.same({}, s.stores.recovery_email_reset_tokens.data);
			assert.same({}, s.stores.recovery_email_reset_pending.data);
		end);

		it("warns at startup when links would use plain HTTP", function ()
			s = load_module({ http_url = "http://chat.example.com/recovery_email_reset" });
			assert.matches("^warn: Password reset links will use plain HTTP", s.logs[1]);
			s = load_module({ http_url = "http://localhost:5280/recovery_email_reset" });
			assert.same({}, s.logs);
		end);
	end);
end);

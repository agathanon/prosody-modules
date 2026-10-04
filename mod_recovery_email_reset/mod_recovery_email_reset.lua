-- Let users reset a forgotten password through their verified recovery email address
local cache = require "prosody.util.cache";
local formdecode = require "prosody.util.http".formdecode;
local hashes = require "prosody.util.hashes";
local id = require "prosody.util.id";
local interpolation = require "prosody.util.interpolation";
local jid_prepped_split = require "prosody.util.jid".prepped_split;
local modulemanager = require "prosody.core.modulemanager";
local throttle = require "prosody.util.throttle";
local usermanager = require "prosody.core.usermanager";
local utf8_valid = require "prosody.util.encodings".utf8.valid;
local xml_escape = require "prosody.util.stanza".xml_escape;

local recovery_email = module:depends("recovery_email");
module:depends("http");

local MAX_PASSWORD_BYTES = 1024;

local link_lifetime = module:get_option_period("recovery_email_reset_link_lifetime", "1 hour");
local requests_per_jid = module:get_option_integer("recovery_email_reset_requests_per_jid", 3, 1);
local requests_per_ip = module:get_option_integer("recovery_email_reset_requests_per_ip", 10, 1);
local min_password_length = module:get_option_integer("recovery_email_reset_min_password_length", 8, 1);
local site_name = module:get_option_string("recovery_email_reset_site_name", module.host);
local template_path = module:get_option_path("recovery_email_reset_template_path", nil, "config")
	or (module:get_directory().."/html");

-- Tokens are stored only as hashes: token hash -> { username, email, expires },
-- and username -> { hash } so that a new request replaces the previous link
local tokens = module:open_store("recovery_email_reset_tokens");
local pending = module:open_store("recovery_email_reset_pending");

local base_url = module:http_url();
if base_url:match("^http:") and not base_url:match("^http://localhost[:/]") and not base_url:match("^http://127%.0%.0%.1[:/]") then
	module:log("warn", "Password reset links will use plain HTTP (%s); set up HTTPS or http_external_url", base_url);
end

-- Pages

local render = interpolation.new("%b{}", xml_escape);

local templates = {};
for _, name in ipairs({ "layout", "request", "reset", "message" }) do
	local file = assert(module:load_resource(template_path.."/"..name..".html"));
	templates[name] = file:read("*a");
	file:close();
end

local security_headers = {
	content_type = "text/html; charset=utf-8";
	content_security_policy = "default-src 'none'; style-src 'unsafe-inline'; form-action 'self'; frame-ancestors 'none'; base-uri 'none'";
	referrer_policy = "no-referrer";
	cache_control = "no-store";
	x_content_type_options = "nosniff";
};

local function page(event, status, title, template, values)
	local response = event.response;
	response.status_code = status;
	for name, value in pairs(security_headers) do
		response.headers[name] = value;
	end
	values.site_name = site_name;
	values.host = module.host;
	values.base_url = base_url;
	return render(templates.layout, {
		title = title;
		site_name = site_name;
		content = render(templates[template], values);
	});
end

-- Errors also offer a link back to the request page
local function message_page(event, status, title, message, is_error)
	return page(event, status, title, "message", {
		message = message;
		class = is_error and "error" or nil;
		link = is_error and base_url or nil;
		link_text = "Request a new reset link";
	});
end

local function describe_period(seconds)
	if seconds % 3600 == 0 then
		local hours = math.floor(seconds / 3600);
		return ("%d %s"):format(hours, hours == 1 and "hour" or "hours");
	end
	local minutes = math.ceil(seconds / 60);
	return ("%d %s"):format(minutes, minutes == 1 and "minute" or "minutes");
end

local function too_many_requests(event)
	return message_page(event, 429, "Too many requests", "Too many requests. Please try again later.", true);
end

local function invalid_link(event)
	return message_page(event, 404, "Link not valid",
		"This link is invalid or has expired. You can request a new one.", true);
end

local function form_data(request)
	local form = request.body and request.body ~= "" and formdecode(request.body);
	return type(form) == "table" and form or {};
end

-- Rate limits

local function new_throttles(limit)
	local throttles = cache.new(4096);
	return function (key)
		local t = throttles:get(key);
		if not t then
			t = throttle.create(limit, 3600);
			throttles:set(key, t);
		end
		return t;
	end;
end

local jid_throttle = new_throttles(requests_per_jid);
local request_ip_throttle = new_throttles(requests_per_ip);
local reset_ip_throttle = new_throttles(requests_per_ip);

-- Tokens

local function hash_token(token)
	return hashes.sha256(token, true);
end

-- Creates a reset link for the user, replacing any previous one
local function create_token(username, email)
	local token = id.long();
	local hash = hash_token(token);
	local expires = os.time() + link_lifetime;
	local previous = pending:get(username);
	if previous then
		tokens:set(previous.hash, nil);
	end
	local ok, err = tokens:set(hash, { username = username; email = email; expires = expires });
	if not ok then
		return nil, err;
	end
	pending:set(username, { hash = hash });
	return token, expires;
end

local function remove_token(username, hash)
	tokens:set(hash, nil);
	local current = pending:get(username);
	if current and current.hash == hash then
		pending:set(username, nil);
	end
end

-- The entry for a valid token, and its hash
local function find_token(token)
	if type(token) ~= "string" or #token > 64 or not token:match("^[%w_%-]+$") then
		return nil;
	end
	local hash = hash_token(token);
	local entry = tokens:get(hash);
	if not entry then
		return nil;
	end
	if entry.expires <= os.time() then
		remove_token(entry.username, hash);
		return nil;
	end
	return entry, hash;
end

-- The verified address a reset may go to, or nil and a reason for the log
local function reset_address(username)
	if not usermanager.user_exists(username, module.host) then
		return nil, "no such account";
	elseif not usermanager.user_is_enabled(username, module.host) then
		return nil, "account disabled";
	end
	local email, reason = recovery_email.get_reset_address(username);
	if not email then
		return nil, "recovery address "..reason;
	end
	return email;
end

-- Request page

local function show_request_form(event)
	return page(event, 200, "Reset your password", "request", { jid = "" });
end

local function handle_request(event)
	local request = event.request;
	local ip = request.ip or "unknown";
	if not request_ip_throttle(ip):poll(1) then
		module:log("debug", "Too many reset requests from %s", ip);
		return too_many_requests(event);
	end

	local submitted = form_data(request).jid;
	local input = type(submitted) == "string" and submitted:match("^%s*(.-)%s*$") or "";
	if not input:find("@", 1, true) then
		input = input.."@"..module.host; -- accept a bare username
	end
	local username, host = jid_prepped_split(input);
	if not username or not host then
		return page(event, 400, "Reset your password", "request", {
			error = "Enter your chat address, e.g. name@"..module.host..".";
			jid = type(submitted) == "string" and submitted or "";
		});
	end

	local jid = username.."@"..host;
	if not jid_throttle(jid):poll(1) then
		module:log("debug", "Too many reset requests for %s", jid);
		return too_many_requests(event);
	end

	if host ~= module.host then
		module:log("debug", "Not sending reset link for %s: not on this host", jid);
	else
		local email, reason = reset_address(username);
		if not email then
			module:log("debug", "Not sending reset link for %s: %s", username, reason);
		else
			local token, expires = create_token(username, email);
			if not token then
				module:log("error", "Unable to store reset link for %s: %s", username, expires);
			else
				module:log("info", "Sending password reset link for %s", username);
				-- The event carries the secret link: listeners must never log or store it
				module:fire_event("recovery-email-reset-requested", {
					username = username;
					host = module.host;
					email = email;
					url = base_url.."/reset/"..token;
					expires = expires;
				});
			end
		end
	end

	-- The same answer whatever happened, so it doesn't reveal which accounts exist
	return message_page(event, 200, "Check your email",
		"If this account has a verified recovery email address, we've sent a link to it. "
		.."The link is valid for "..describe_period(link_lifetime)..".");
end

-- Reset page

local function show_reset_form(event, entry, token, error_message)
	return page(event, error_message and 400 or 200, "Choose a new password", "reset", {
		jid = entry.username.."@"..module.host;
		action = base_url.."/reset/"..token;
		min_length = tostring(min_password_length);
		error = error_message or false;
	});
end

-- Returns true, or nil and a reason to show the user
local function check_password(password, username)
	if type(password) ~= "string" or password == "" then
		return nil, "Enter a new password.";
	elseif not (utf8_valid(password) and utf8.len(password)) then
		return nil, "The password contains invalid characters.";
	elseif utf8.len(password) < min_password_length then
		return nil, ("The password must be at least %d characters long."):format(min_password_length);
	elseif #password > MAX_PASSWORD_BYTES then
		return nil, "The password is too long.";
	end
	-- Also apply mod_password_policy's rules if that module is loaded
	local password_policy = modulemanager.get_module(module.host, "password_policy");
	if password_policy and password_policy.check_password then
		local ok, reason = password_policy.check_password(password, { username = username });
		if not ok then
			return nil, reason or "The password doesn't meet the server's password policy.";
		end
	end
	return true;
end

local function get_reset(event, token)
	local entry = find_token(token);
	if not entry or entry.email ~= reset_address(entry.username) then
		return invalid_link(event);
	end
	return show_reset_form(event, entry, token);
end

local function post_reset(event, token)
	local request = event.request;
	local ip = request.ip or "unknown";
	if not reset_ip_throttle(ip):poll(1) then
		module:log("debug", "Too many password submissions from %s", ip);
		return too_many_requests(event);
	end

	local entry, hash = find_token(token);
	-- The link is only valid while it matches the account's current usable address
	if not entry or entry.email ~= reset_address(entry.username) then
		return invalid_link(event);
	end

	local form = form_data(request);
	if form.password ~= form.confirm then
		return show_reset_form(event, entry, token, "The passwords don't match.");
	end
	local ok, reason = check_password(form.password, entry.username);
	if not ok then
		return show_reset_form(event, entry, token, reason);
	end

	local username = entry.username;
	local set_ok, set_err = usermanager.set_password(username, form.password, module.host);
	if not set_ok then
		module:log("error", "Unable to reset password for %s: %s", username, set_err);
		return message_page(event, 500, "Something went wrong",
			"Your password could not be changed. Please try again later or contact the server administrator.", true);
	end
	remove_token(username, hash);

	module:log("info", "Password for %s reset through recovery email", username);
	module:fire_event("recovery-email-password-reset", {
		username = username;
		host = module.host;
		email = entry.email;
	});
	return message_page(event, 200, "Password changed",
		"Your password has been changed. You can now sign in with it.");
end

module:provides("http", {
	-- Other sites' scripts have no business reading these pages
	cors = { enabled = false };
	route = {
		["GET"] = show_request_form;
		["POST"] = handle_request;
		["GET /reset/*"] = get_reset;
		["POST /reset/*"] = post_reset;
	};
});

-- Housekeeping

-- A password changed some other way makes a pending link pointless
module:hook_global("user-password-changed", function (event)
	if event.host ~= module.host then return; end
	local current = pending:get(event.username);
	if current then
		remove_token(event.username, current.hash);
	end
end);

module:hook_global("user-deleted", function (event)
	if event.host ~= module.host then return; end
	local current = pending:get(event.username);
	if current then
		remove_token(event.username, current.hash);
	end
end);

module:daily("Remove expired password reset links", function ()
	local now, removed = os.time(), 0;
	for hash in tokens:users() do
		local entry = tokens:get(hash);
		if entry and entry.expires <= now then
			remove_token(entry.username, hash);
			removed = removed + 1;
		end
	end
	if removed > 0 then
		module:log("debug", "Removed %d expired password reset links", removed);
	end
end);

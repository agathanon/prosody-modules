-- Store one private recovery email address per user, managed via ad-hoc command
local adhocutil = require "prosody.util.adhoc";
local cache = require "prosody.util.cache";
local dataforms = require "prosody.util.dataforms";
local jid_split = require "prosody.util.jid".prepped_split;
local throttle = require "prosody.util.throttle";
local usermanager = require "prosody.core.usermanager";
local utf8_valid = require "prosody.util.encodings".utf8.valid;

local new_adhoc = module:require("adhoc").new;

local store = module:open_store("recovery_email");

local SCHEMA_VERSION = 1;
local MAX_LENGTH = 254;
local MAX_LOCAL_PART_LENGTH = 64;
local RATE_LIMIT_CHANGES, RATE_LIMIT_PERIOD = 5, 3600;

-- Non-ASCII whitespace and invisible characters that Lua's %s does not match
local unicode_space = {
	[0x00A0] = true; [0x1680] = true; [0x2028] = true; [0x2029] = true;
	[0x202F] = true; [0x205F] = true; [0x3000] = true; [0xFEFF] = true;
};
for c = 0x2000, 0x200B do unicode_space[c] = true; end

-- Returns the normalized address, or nil and a message for the user
function validate(email) --luacheck: ignore 131/validate
	if type(email) ~= "string" then
		return nil, "No address given";
	end
	email = email:match("^%s*(.-)%s*$");
	if email == "" then
		return nil, "No address given";
	end
	if not (utf8_valid(email) and utf8.len(email)) then
		return nil, "The address contains invalid characters";
	end
	if #email > MAX_LENGTH then
		return nil, "The address is too long";
	end
	if email:find("[%s%c]") then
		return nil, "The address must not contain spaces or control characters";
	end
	for _, c in utf8.codes(email) do
		if unicode_space[c] or (c >= 0x80 and c <= 0x9F) then
			return nil, "The address must not contain spaces or control characters";
		end
	end
	local local_part, domain = email:match("^([^@]+)@([^@]+)$");
	if not local_part then
		return nil, "Enter an address in the form name@example.org";
	end
	if #local_part > MAX_LOCAL_PART_LENGTH then
		return nil, "The part before the @ is too long";
	end
	if not domain:find(".", 1, true) or domain:find("^%.") or domain:find("%.$") or domain:find("..", 1, true) then
		return nil, "The domain part of the address is not valid";
	end
	return local_part.."@"..domain:lower();
end

local function mask(email)
	local local_part, domain = email:match("^(.+)@(.*)$");
	if not local_part then return "***"; end
	return local_part:sub(1, utf8.offset(local_part, 2) - 1).."***@"..domain;
end

local function account_created(username)
	local info = usermanager.get_account_info(username, module.host);
	return info and info.created;
end

function get(username) --luacheck: ignore 131/get
	local record, err = store:get(username);
	if not record then
		return nil, err;
	end
	if not usermanager.user_exists(username, module.host) then
		return nil;
	end
	-- A record from an earlier account with the same username must never apply to a new one
	local created = account_created(username);
	if record.account_created and created and record.account_created ~= created then
		module:log("info", "Removing stale recovery email record for %s", username);
		store:set(username, nil);
		return nil;
	end
	return record;
end

-- Optional source (e.g. "shell") is noted in the log
local function via(source)
	return source and " (via "..source..")" or "";
end

-- Returns true and "changed"/"unchanged", or nil, error_code, message
function set(username, email, source) --luacheck: ignore 131/set
	if not usermanager.user_exists(username, module.host) then
		return nil, "item-not-found", "No such account";
	end
	local normalized, invalid = validate(email);
	if not normalized then
		return nil, "bad-request", invalid;
	end
	local record, get_err = get(username);
	if get_err then
		module:log("error", "Unable to read recovery email for %s: %s", username, get_err);
		return nil, "internal-server-error", "Unable to read the stored address";
	end
	if record and record.email == normalized then
		return true, "unchanged";
	end

	local now = os.time();
	local ok, set_err = store:set(username, {
		version = SCHEMA_VERSION;
		email = normalized;
		status = "unverified";
		created_at = record and record.created_at or now;
		updated_at = now;
		account_created = account_created(username);
	});
	if not ok then
		module:log("error", "Unable to store recovery email for %s: %s", username, set_err);
		return nil, "internal-server-error", "Unable to store the address";
	end

	module:log("info", "Recovery email for %s set to %s%s", username, mask(normalized), via(source));
	module:fire_event("recovery-email-set", {
		username = username;
		host = module.host;
		email = normalized;
		previous_email = record and record.email;
	});
	return true, "changed";
end

-- Returns true and "removed"/"absent", or nil, error_code, message
function clear(username, source) --luacheck: ignore 131/clear
	local record, get_err = get(username);
	if get_err then
		module:log("error", "Unable to read recovery email for %s: %s", username, get_err);
		return nil, "internal-server-error", "Unable to read the stored address";
	end
	if not record then
		return true, "absent";
	end
	local ok, set_err = store:set(username, nil);
	if not ok then
		module:log("error", "Unable to remove recovery email for %s: %s", username, set_err);
		return nil, "internal-server-error", "Unable to remove the address";
	end
	module:log("info", "Recovery email for %s (%s) removed%s", username, mask(record.email), via(source));
	module:fire_event("recovery-email-cleared", {
		username = username;
		host = module.host;
		previous_email = record.email;
	});
	return true, "removed";
end

-- Account lifecycle

module:hook_global("user-deleted", function (event)
	if event.host ~= module.host then return; end
	local ok, err = store:set(event.username, nil);
	if not ok then
		module:log("error", "Unable to remove recovery email of deleted user %s: %s", event.username, err);
	end
end);

module:hook("user-registered", function (event)
	local ok, err = store:set(event.username, nil);
	if not ok then
		module:log("error", "Unable to remove leftover recovery email for %s: %s", event.username, err);
	end
end);

-- Ad-hoc command

local throttles = cache.new(1024);

local function get_throttle(username)
	local t = throttles:get(username);
	if not t then
		t = throttle.create(RATE_LIMIT_CHANGES, RATE_LIMIT_PERIOD);
		throttles:set(username, t);
	end
	return t;
end

local form = dataforms.new({
	title = "Recovery email";
	instructions = "This address can be used to help you regain access to your account. "
		.."It is stored privately on the server and is not shown to your contacts.";
	{ name = "current"; type = "fixed"; label = "Current address" };
	{ name = "email"; type = "text-single"; label = "Recovery email address" };
	{ name = "remove"; type = "boolean"; label = "Remove my recovery email" };
});

local function describe(record)
	if not record then
		return "No recovery email set";
	end
	return ("%s (%s)"):format(record.email, record.status);
end

local function local_username(from)
	local username, host = jid_split(from);
	if host ~= module.host or not username then
		return nil;
	end
	return username;
end

local function completed(info)
	return { status = "completed"; info = info };
end

local function failed(message)
	return { status = "completed"; error = { message = message } };
end

local function initial_data(data)
	local username = local_username(data.from);
	if not username then
		return nil, { type = "auth"; condition = "forbidden"; text = "This command is only available to users of "..module.host };
	end
	local record, err = get(username);
	if err then
		return nil, "Unable to read the stored address";
	end
	return { current = describe(record); email = record and record.email or ""; remove = false };
end

local function handle_submit(fields, err, data)
	local username = local_username(data.from);
	if not username then
		return failed("This command is only available to users of "..module.host);
	end
	if err then
		return failed("The form was not filled in correctly");
	end

	local changes = get_throttle(username);
	local email = fields.email and fields.email:match("^%s*(.-)%s*$") or "";
	if not fields.remove and email == "" then
		return completed("No changes made.");
	end
	if not changes:peek(1) then
		return failed("Too many changes. Please try again later.");
	end

	if fields.remove then
		local ok, result, message = clear(username);
		if not ok then
			return failed(message);
		elseif result == "absent" then
			return completed("No recovery email was set.");
		end
		changes:poll(1);
		return completed("Recovery email removed.");
	end

	local ok, result, message = set(username, email);
	if not ok then
		return failed(message);
	elseif result == "unchanged" then
		return completed("No changes made.");
	end
	changes:poll(1);
	return completed("Recovery email saved.");
end

module:default_permission("prosody:registered", "adhoc:recovery-email");
module:depends("adhoc");
module:provides("adhoc", new_adhoc("Recovery email", "recovery-email",
	adhocutil.new_initial_data_form(form, initial_data, handle_submit), "check"));

-- Admin shell

local function shell_username(user_jid)
	local username, host = jid_split(user_jid);
	if not username or host ~= module.host then
		return nil, "Invalid JID: "..tostring(user_jid);
	end
	return username;
end

module:add_item("shell-command", {
	section = "recovery";
	section_desc = "View and manage users' recovery email addresses";
	name = "show";
	desc = "Show a user's recovery email record";
	args = { { name = "jid"; type = "string" } };
	host_selector = "jid";
	handler = function (self, user_jid)
		local username, jid_err = shell_username(user_jid);
		if not username then return nil, jid_err; end
		if not usermanager.user_exists(username, module.host) then return nil, "No such account"; end
		local record, err = get(username);
		if err then return nil, "Unable to read record: "..tostring(err); end
		if not record then return true, "No recovery email set"; end
		local print = self.session.print;
		local function date(t) return t and os.date("!%Y-%m-%d %H:%M:%S UTC", t) or "-"; end
		print("Email:       "..record.email);
		print("Status:      "..record.status);
		print("Created:     "..date(record.created_at));
		print("Updated:     "..date(record.updated_at));
		print("Verified:    "..date(record.verified_at));
		return true, "Showing recovery email for "..user_jid;
	end;
});

module:add_item("shell-command", {
	section = "recovery";
	section_desc = "View and manage users' recovery email addresses";
	name = "set";
	desc = "Set a user's recovery email (stored as unverified)";
	args = { { name = "jid"; type = "string" }, { name = "email"; type = "string" } };
	host_selector = "jid";
	handler = function (self, user_jid, email) --luacheck: ignore 212/self
		local username, jid_err = shell_username(user_jid);
		if not username then return nil, jid_err; end
		local ok, result, message = set(username, email, "shell");
		if not ok then return nil, message; end
		return true, result == "unchanged" and "No changes made" or "Recovery email set";
	end;
});

module:add_item("shell-command", {
	section = "recovery";
	section_desc = "View and manage users' recovery email addresses";
	name = "clear";
	desc = "Remove a user's recovery email";
	args = { { name = "jid"; type = "string" } };
	host_selector = "jid";
	handler = function (self, user_jid) --luacheck: ignore 212/self
		local username, jid_err = shell_username(user_jid);
		if not username then return nil, jid_err; end
		local ok, result, message = clear(username, "shell");
		if not ok then return nil, message; end
		return true, result == "absent" and "No recovery email was set" or "Recovery email removed";
	end;
});

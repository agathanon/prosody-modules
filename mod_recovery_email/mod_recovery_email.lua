-- Store one private recovery email address per user, managed via ad-hoc command
local cache = require "prosody.util.cache";
local dataforms = require "prosody.util.dataforms";
local hashes = require "prosody.util.hashes";
local hex = require "prosody.util.hex";
local jid_split = require "prosody.util.jid".prepped_split;
local random_bytes = require "prosody.util.random".bytes;
local throttle = require "prosody.util.throttle";
local usermanager = require "prosody.core.usermanager";
local utf8_valid = require "prosody.util.encodings".utf8.valid;

local new_adhoc = module:require("adhoc").new;

local store = module:open_store("recovery_email");
-- When verified addresses were removed, to apply reset_delay to the next one
local removed_store = module:open_store("recovery_email_removed");

local SCHEMA_VERSION = 1;
local MAX_LENGTH = 254;
local MAX_LOCAL_PART_LENGTH = 64;
local RATE_LIMIT_CHANGES, RATE_LIMIT_PERIOD = 5, 3600;
local RATE_LIMIT_RESENDS, RATE_LIMIT_RESEND_PERIOD = 3, 3600;
local MAX_CODE_ATTEMPTS = 5;

local code_lifetime = module:get_option_period("recovery_email_code_lifetime", "24 hours");
-- Cooling-off period before an address that took the place of a verified
-- one can be used for password resets; 0 turns it off
local reset_delay = module:get_option_period("recovery_email_reset_delay", 0);

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

-- Verification codes

-- A uniformly random 6-digit code. Values at the top of the 32-bit range
-- are discarded so that every code is equally likely.
local function new_code()
	local limit = 4294000000; -- largest multiple of 10^6 below 2^32
	while true do
		local b1, b2, b3, b4 = random_bytes(4):byte(1, 4);
		local n = ((b1 * 256 + b2) * 256 + b3) * 256 + b4;
		if n < limit then
			return ("%06d"):format(n % 1000000);
		end
	end
end

-- Stored as "salt$hash". A 6-digit code can't be protected against someone
-- who can read the storage; the hash keeps codes out of backups and output,
-- while the short lifetime and attempt limit are the real protection.
local function hash_code(code)
	local salt = hex.encode(random_bytes(16));
	return salt.."$"..hashes.sha256(salt..code, true);
end

local function check_code(token, code)
	local salt, hash = token:match("^(%x+)%$(%x+)$");
	if not salt then return false; end
	return hashes.equals(hashes.sha256(salt..code, true), hash);
end

-- Spaces and hyphens are ignored, so "123 456" and "123-456" work
local function normalize_code(input)
	if type(input) ~= "string" then return nil; end
	local code = input:gsub("[%s%-]", "");
	return code:match("^%d%d%d%d%d%d$");
end

-- Adds a new pending code to the record and returns it
local function start_verification(record, now)
	local code = new_code();
	record.verify_token_hash = hash_code(code);
	record.verify_expires = now + code_lifetime;
	record.verify_attempts = 0;
	return code;
end

local function clear_verification(record)
	record.verify_token_hash, record.verify_expires, record.verify_attempts = nil, nil, nil;
end

-- Storage and API

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

local function read_failed(username, err)
	module:log("error", "Unable to read recovery email for %s: %s", username, err);
	return nil, "internal-server-error", "Unable to read the stored address";
end

local function write_failed(username, err)
	module:log("error", "Unable to store recovery email for %s: %s", username, err);
	return nil, "internal-server-error", "Unable to store the address";
end

-- The event carries the raw code: listeners must never log or store it
local function request_verification_email(username, record, code)
	module:fire_event("recovery-email-verification-requested", {
		username = username;
		host = module.host;
		email = record.email;
		code = code;
		expires = record.verify_expires;
	});
end

-- Whether a new address takes the place of a verified one: directly, through
-- unverified addresses in between, or soon after a verified one was removed
local function replaces_verified(username, record, now)
	if record then
		return record.status == "verified" or record.replaced_verified == true;
	end
	local removed = removed_store:get(username);
	if not removed then
		return false;
	end
	removed_store:set(username, nil);
	return reset_delay > 0 and removed.at + reset_delay > now;
end

-- Returns true and "changed"/"unchanged", or nil, error_code, message.
-- A changed address is stored unverified and a verification code is sent.
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
		return read_failed(username, get_err);
	end
	if record and record.email == normalized then
		return true, "unchanged";
	end

	local now = os.time();
	local new_record = {
		version = SCHEMA_VERSION;
		email = normalized;
		status = "unverified";
		created_at = record and record.created_at or now;
		updated_at = now;
		account_created = account_created(username);
		replaced_verified = replaces_verified(username, record, now) or nil;
	};
	local code = start_verification(new_record, now);
	local ok, set_err = store:set(username, new_record);
	if not ok then
		return write_failed(username, set_err);
	end

	module:log("info", "Recovery email for %s set to %s%s", username, mask(normalized), via(source));
	module:fire_event("recovery-email-set", {
		username = username;
		host = module.host;
		email = normalized;
		previous_email = record and record.email;
		previous_status = record and record.status;
		source = source;
	});
	request_verification_email(username, new_record, code);
	return true, "changed";
end

-- Returns true and "removed"/"absent", or nil, error_code, message
function clear(username, source) --luacheck: ignore 131/clear
	local record, get_err = get(username);
	if get_err then
		return read_failed(username, get_err);
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
	-- Remember removals of verified addresses, and of addresses that replaced
	-- one, so that removing and re-adding can't skip the cooling-off period
	if (record.status == "verified" or record.replaced_verified) and reset_delay > 0 then
		local removed_ok, removed_err = removed_store:set(username, { at = os.time() });
		if not removed_ok then
			module:log("error", "Unable to record removal of recovery email for %s: %s", username, removed_err);
		end
	end
	module:fire_event("recovery-email-cleared", {
		username = username;
		host = module.host;
		previous_email = record.email;
		previous_status = record.status;
		source = source;
	});
	return true, "removed";
end

local NO_LONGER_VALID = "That code is no longer valid. Tick \"Send a new code\" to get another.";

-- Returns true, "verified", or nil, error_code, message
function verify(username, input) --luacheck: ignore 131/verify
	local record, get_err = get(username);
	if get_err then
		return read_failed(username, get_err);
	elseif not record then
		return nil, "item-not-found", "No recovery email is set.";
	elseif record.status == "verified" then
		return nil, "conflict", "Your recovery email is already verified.";
	elseif not record.verify_token_hash then
		return nil, "resource-constraint", NO_LONGER_VALID;
	end

	local now = os.time();
	local attempts = record.verify_attempts or 0;
	if record.verify_expires <= now or attempts >= MAX_CODE_ATTEMPTS then
		clear_verification(record);
		local ok, set_err = store:set(username, record);
		if not ok then return write_failed(username, set_err); end
		return nil, "resource-constraint", NO_LONGER_VALID;
	end

	local code = normalize_code(input);
	if code and check_code(record.verify_token_hash, code) then
		record.status = "verified";
		record.verified_at = now;
		if record.replaced_verified and reset_delay > 0 then
			record.reset_allowed_after = now + reset_delay;
		end
		record.replaced_verified = nil;
		clear_verification(record);
		local ok, set_err = store:set(username, record);
		if not ok then return write_failed(username, set_err); end
		module:log("info", "Recovery email for %s (%s) verified", username, mask(record.email));
		module:fire_event("recovery-email-verified", {
			username = username;
			host = module.host;
			email = record.email;
		});
		return true, "verified";
	end

	-- Malformed input counts as a wrong attempt too
	attempts = attempts + 1;
	if attempts >= MAX_CODE_ATTEMPTS then
		clear_verification(record);
	else
		record.verify_attempts = attempts;
	end
	local ok, set_err = store:set(username, record);
	if not ok then return write_failed(username, set_err); end
	module:log("info", "Incorrect verification code for %s (attempt %d of %d)", username, attempts, MAX_CODE_ATTEMPTS);
	if attempts >= MAX_CODE_ATTEMPTS then
		return nil, "resource-constraint", NO_LONGER_VALID;
	end
	local left = MAX_CODE_ATTEMPTS - attempts;
	return nil, "not-acceptable",
		("That code is incorrect. %d %s left."):format(left, left == 1 and "attempt" or "attempts");
end

-- Returns true, or nil, error_code, message
function resend_verification(username, source) --luacheck: ignore 131/resend_verification
	local record, get_err = get(username);
	if get_err then
		return read_failed(username, get_err);
	elseif not record then
		return nil, "item-not-found", "No recovery email is set.";
	elseif record.status == "verified" then
		return nil, "conflict", "Your recovery email is already verified.";
	end
	local code = start_verification(record, os.time());
	local ok, set_err = store:set(username, record);
	if not ok then
		return write_failed(username, set_err);
	end
	module:log("info", "New verification code for %s (%s) requested%s", username, mask(record.email), via(source));
	request_verification_email(username, record, code);
	return true;
end

-- The address to send a password reset link to, or nil and a reason:
-- "none", "unverified", "cooling-off" (with the time it ends) or "error"
function get_reset_address(username) --luacheck: ignore 131/get_reset_address
	local record, err = get(username);
	if err then
		module:log("error", "Unable to read recovery email for %s: %s", username, err);
		return nil, "error";
	elseif not record then
		return nil, "none";
	elseif record.status ~= "verified" then
		return nil, "unverified";
	elseif record.reset_allowed_after and os.time() < record.reset_allowed_after then
		return nil, "cooling-off", record.reset_allowed_after;
	end
	return record.email;
end

-- Account lifecycle

module:hook_global("user-deleted", function (event)
	if event.host ~= module.host then return; end
	local ok, err = store:set(event.username, nil);
	if not ok then
		module:log("error", "Unable to remove recovery email of deleted user %s: %s", event.username, err);
	end
	removed_store:set(event.username, nil);
end);

module:hook("user-registered", function (event)
	local ok, err = store:set(event.username, nil);
	if not ok then
		module:log("error", "Unable to remove leftover recovery email for %s: %s", event.username, err);
	end
	removed_store:set(event.username, nil);
end);

-- Ad-hoc command

local function new_throttles(limit, period)
	local throttles = cache.new(1024);
	return function (username)
		local t = throttles:get(username);
		if not t then
			t = throttle.create(limit, period);
			throttles:set(username, t);
		end
		return t;
	end;
end

local change_throttle = new_throttles(RATE_LIMIT_CHANGES, RATE_LIMIT_PERIOD);
local resend_throttle = new_throttles(RATE_LIMIT_RESENDS, RATE_LIMIT_RESEND_PERIOD);

local title = "Recovery email";
local instructions = "This address can be used to help you regain access to your account. "
	.."It is stored privately on the server and is not shown to your contacts.";
local current_field = { name = "current"; type = "fixed"; label = "Current address" };
local email_field = { name = "email"; type = "text-single"; label = "Recovery email address" };
local remove_field = { name = "remove"; type = "boolean"; label = "Remove my recovery email" };
local code_field = { name = "code"; type = "text-single"; label = "Verification code" };
local resend_field = { name = "resend"; type = "boolean"; label = "Send a new code" };

-- Shown when there is no address, or a verified one
local form = dataforms.new({
	title = title; instructions = instructions;
	current_field; email_field; remove_field;
});

-- Shown while an address is unverified; also used to read all submissions
local pending_form = dataforms.new({
	title = title;
	instructions = instructions.." To verify your address, enter the code we sent to it.";
	current_field; code_field; resend_field; email_field; remove_field;
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

local function trim(s)
	return s and s:match("^%s*(.-)%s*$") or "";
end

local function show_form(username)
	local record, err = get(username);
	if err then
		return { status = "error"; error = { type = "cancel"; condition = "internal-server-error"; text = "Unable to read the stored address" } };
	end
	local pending = record and record.status ~= "verified";
	return {
		status = "executing";
		actions = { "next", "complete", default = "complete" };
		form = {
			layout = pending and pending_form or form;
			values = { current = describe(record); email = record and record.email or ""; remove = false };
		};
	}, "executing";
end

local function handle_submit(fields, username)
	local email = trim(fields.email);
	local code = trim(fields.code);

	-- Order: remove, then a changed address, then a code, then resend
	if fields.remove then
		local changes = change_throttle(username);
		if not changes:peek(1) then
			return failed("Too many changes. Please try again later.");
		end
		local ok, result, message = clear(username);
		if not ok then
			return failed(message);
		elseif result == "absent" then
			return completed("No recovery email was set.");
		end
		changes:poll(1);
		return completed("Recovery email removed.");
	end

	if email ~= "" then
		local record, err = get(username);
		if err then
			return failed("Unable to read the stored address");
		end
		local normalized = validate(email);
		if not (record and normalized == record.email) then
			local changes = change_throttle(username);
			if not changes:peek(1) then
				return failed("Too many changes. Please try again later.");
			end
			local ok, result, message = set(username, email);
			if not ok then
				return failed(message);
			elseif result == "changed" then
				changes:poll(1);
				return completed("Recovery email saved. A verification code has been sent to it.");
			end
		end
	end

	if code ~= "" then
		local ok, _, message = verify(username, code);
		if not ok then
			return failed(message);
		end
		return completed("Recovery email verified.");
	end

	if fields.resend then
		local resends = resend_throttle(username);
		if not resends:peek(1) then
			return failed("Too many codes requested. Please try again later.");
		end
		local ok, _, message = resend_verification(username);
		if not ok then
			return failed(message);
		end
		resends:poll(1);
		return completed("A new code has been sent.");
	end

	return completed("No changes made.");
end

local function command_handler(_, data, state)
	local username = local_username(data.from);
	if not username then
		return { status = "error"; error = { type = "auth"; condition = "forbidden"; text = "This command is only available to users of "..module.host } };
	end
	if data.action == "cancel" then
		return { status = "canceled" };
	end
	if not (state or data.form) then
		return show_form(username);
	end
	if not data.form then
		return failed("The form was not filled in correctly");
	end
	-- The pending form has every field, so it can read any submission
	local fields, err = pending_form:data(data.form);
	if err then
		return failed("The form was not filled in correctly");
	end
	return handle_submit(fields, username);
end

module:default_permission("prosody:registered", "adhoc:recovery-email");
module:depends("adhoc");
module:provides("adhoc", new_adhoc("Recovery email", "recovery-email", command_handler, "check"));

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
		if record.status ~= "verified" then
			print("Reset:       not usable (unverified)");
		elseif record.reset_allowed_after and os.time() < record.reset_allowed_after then
			print("Reset:       usable from "..date(record.reset_allowed_after));
		else
			print("Reset:       usable");
		end
		if record.verify_token_hash then
			print(("Code:        pending, expires %s, %d of %d attempts used"):format(
				date(record.verify_expires), record.verify_attempts or 0, MAX_CODE_ATTEMPTS));
		elseif record.status ~= "verified" then
			print("Code:        none pending");
		end
		return true, "Showing recovery email for "..user_jid;
	end;
});

module:add_item("shell-command", {
	section = "recovery";
	section_desc = "View and manage users' recovery email addresses";
	name = "set";
	desc = "Set a user's recovery email (stored as unverified; starts verification)";
	args = { { name = "jid"; type = "string" }, { name = "email"; type = "string" } };
	host_selector = "jid";
	handler = function (self, user_jid, email) --luacheck: ignore 212/self
		local username, jid_err = shell_username(user_jid);
		if not username then return nil, jid_err; end
		local ok, result, message = set(username, email, "shell");
		if not ok then return nil, message; end
		return true, result == "unchanged" and "No changes made" or "Recovery email set (unverified; verification code requested)";
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

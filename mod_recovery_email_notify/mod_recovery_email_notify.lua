-- Send the emails for mod_recovery_email: verification codes and change notices
local interpolation = require "prosody.util.interpolation";

module:depends("recovery_email");
local smtp = module:depends("smtp_async");

-- Plain text, so values are inserted as they are
local render = interpolation.new("%b{}", function (s) return s; end);

local default_messages = {
	verification = {
		subject = "Your verification code for {jid}";
		body = [[
Hello,

Someone, hopefully you, entered this address as the recovery email for
the account {jid}.

Your verification code is: {code}

Enter it in the "Recovery email" command in your XMPP client. The code
is valid until {expires}.

If you didn't do this, you can ignore this email. This address won't be
used for account recovery unless the code is entered.
]];
	};
	replaced = {
		subject = "The recovery email for {jid} was changed";
		body = [[
Hello,

The recovery email address for the account {jid} was changed
{changed_by} at {time}.

This address will no longer be used to recover the account.

If you made this change, no action is needed.

If you didn't, someone else may have access to your account.
{contact&Contact the server administrator: {contact}}{contact~Contact the administrator of {host}.}
]];
	};
	removed = {
		subject = "The recovery email for {jid} was removed";
		body = [[
Hello,

The recovery email address for the account {jid} was removed
{changed_by} at {time}.

This address will no longer be used to recover the account.

If you made this change, no action is needed.

If you didn't, someone else may have access to your account.
{contact&Contact the server administrator: {contact}}{contact~Contact the administrator of {host}.}
]];
	};
};

local from = module:get_option_string("recovery_email_from", "noreply@"..module.host);

-- Built-in texts, with any subjects and bodies overridden from the config
local messages = {};
local overrides = module:get_option("recovery_email_messages", {});
for kind, defaults in pairs(default_messages) do
	local override = type(overrides) == "table" and type(overrides[kind]) == "table" and overrides[kind] or {};
	messages[kind] = {
		subject = type(override.subject) == "string" and override.subject or defaults.subject;
		body = type(override.body) == "string" and override.body or defaults.body;
	};
end
for kind in pairs(type(overrides) == "table" and overrides or {}) do
	if not default_messages[kind] then
		module:log("warn", "Ignoring unknown message %q in recovery_email_messages", tostring(kind));
	end
end

-- The admin contact from Prosody's contact_info option, if configured
local function admin_contact()
	local contact_info = module:get_option("contact_info", {});
	local admin = type(contact_info) == "table" and contact_info.admin;
	if type(admin) == "string" then admin = { admin }; end
	if type(admin) ~= "table" or #admin == 0 then return nil; end
	local addresses = {};
	for i, uri in ipairs(admin) do
		addresses[i] = (tostring(uri):gsub("^mailto:", ""));
	end
	return table.concat(addresses, ", ");
end
local contact = admin_contact();

local function mask(email)
	local local_part, domain = email:match("^(.+)@(.*)$");
	if not local_part then return "***"; end
	return local_part:sub(1, utf8.offset(local_part, 2) - 1).."***@"..domain;
end

local function format_time(t)
	return os.date("!%Y-%m-%d %H:%M UTC", t);
end

local function changed_by(source)
	return source == "shell" and "by a server administrator" or "from the account";
end

local function send(kind, to, username, values)
	local template = messages[kind];
	values.jid = username.."@"..module.host;
	values.host = module.host;
	values.contact = contact;
	smtp.send({
		to = to;
		from = from;
		subject = render(template.subject, values);
		body = render(template.body, values);
		headers = { ["Auto-Submitted"] = "auto-generated" };
	}):next(function ()
		module:log("info", "Sent %s email for %s to %s", kind, username, mask(to));
	end, function (err)
		module:log("warn", "Unable to send %s email for %s to %s: %s", kind, username, mask(to),
			type(err) == "table" and err.text or tostring(err));
	end);
end

-- The event carries the raw code: it goes into the email and nowhere else
module:hook("recovery-email-verification-requested", function (event)
	send("verification", event.email, event.username, {
		code = event.code;
		expires = format_time(event.expires);
	});
end);

-- Notices go only to addresses that were verified, so this module can't be
-- used to send email to addresses that were merely typed in
module:hook("recovery-email-set", function (event)
	if event.previous_email and event.previous_status == "verified" then
		send("replaced", event.previous_email, event.username, {
			changed_by = changed_by(event.source);
			time = format_time(os.time());
		});
	end
end);

module:hook("recovery-email-cleared", function (event)
	if event.previous_status == "verified" then
		send("removed", event.previous_email, event.username, {
			changed_by = changed_by(event.source);
			time = format_time(os.time());
		});
	end
end);

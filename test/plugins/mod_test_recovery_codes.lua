-- Test only: send each recovery email verification code to the user's
-- sessions as an XMPP message, so scansion scripts can capture it.
-- Never load this on a real server.
local st = require "prosody.util.stanza";

local users = module:get_option_set("test_recovery_codes_users", {});

module:hook("recovery-email-verification-requested", function (event)
	if not users:contains(event.username) then return; end
	local user = prosody.hosts[event.host].sessions[event.username];
	for _, session in pairs(user and user.sessions or {}) do
		session.send(st.message({ to = session.full_jid; from = event.host })
			:tag("code", { xmlns = "urn:test:recovery-code"; value = event.code }));
	end
end);

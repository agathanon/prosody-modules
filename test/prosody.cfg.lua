-- Prosody config for scansion integration tests. Not for production use:
-- any password is accepted and connections are unencrypted.
--luacheck: ignore

plugin_paths = { "/opt/xmpp-modules" }

modules_enabled = {
	"roster";
	"saslauth";
	"disco";
	"register"; -- account deletion (XEP-0077 <remove/>)
	"admin_shell"; -- for debugging: prosodyctl shell
}

c2s_require_encryption = false
allow_unencrypted_plain_auth = true
authentication = "insecure"
insecure_open_authentication = "Yes please, I know what I'm doing!"
allow_registration = false

-- TEST_STORAGE selects the backend under test: "internal" (default) or "sql"
if ENV_TEST_STORAGE == "sql" then
	storage = "sql"
	sql = { driver = "SQLite3"; database = "prosody.sqlite" }
else
	storage = "internal"
end

log = { [ENV_TEST_LOGLEVEL or "info"] = "*console" }

-- Modules under test
VirtualHost "localhost"
	modules_enabled = { "recovery_email" }

-- Users of another host on the same server
VirtualHost "other.localhost"

-- Anonymous users (role prosody:guest), with the module loaded on their own host
VirtualHost "anon.localhost"
	authentication = "anonymous"
	modules_enabled = { "recovery_email" }

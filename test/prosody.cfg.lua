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

-- mod_smtp_async: every host sends to a test mail server from test/certs.sh
smtp_async_port = 1025
smtp_async_username = "prosody"
smtp_async_password = "secret"
smtp_async_cafile = "/certs/ca.crt"
smtp_async_timeout = "5s"

-- Modules under test. mod_smtp_async here uses STARTTLS.
VirtualHost "localhost"
	modules_enabled = { "recovery_email", "smtp_async" }
	smtp_async_server = "mailpit"

-- Users of another host on the same server. mod_smtp_async here uses
-- implicit TLS.
VirtualHost "other.localhost"
	modules_enabled = { "smtp_async" }
	smtp_async_server = "mailpit-tls"
	smtp_async_tls = "tls"

-- Anonymous users (role prosody:guest), with the module loaded on their own
-- host. mod_smtp_async here connects under a name the certificate doesn't
-- cover, so sending must fail.
VirtualHost "anon.localhost"
	authentication = "anonymous"
	modules_enabled = { "recovery_email", "smtp_async" }
	smtp_async_server = "wrongname"
	smtp_async_retries = 0

-- mod_smtp_async trusting only the system CAs, which don't include the test
-- CA, so sending must fail
VirtualHost "untrusted.localhost"
	modules_enabled = { "smtp_async" }
	smtp_async_server = "mailpit"
	smtp_async_cafile = "/etc/ssl/certs/ca-certificates.crt"
	smtp_async_retries = 0

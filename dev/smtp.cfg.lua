-- Dev server only: send mod_smtp_async's email to the Mailpit service in
-- docker-compose.yml (web UI: http://127.0.0.1:8025). Plain SMTP without
-- login, which is only acceptable because Mailpit runs next to Prosody.
--luacheck: ignore

-- Options for the dev VirtualHost
VirtualHost "localhost"
	smtp_async_server = "mailpit"
	smtp_async_port = 1025
	smtp_async_tls = "none"

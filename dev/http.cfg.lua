-- Dev server only: listen for plain HTTP on all of the container's
-- interfaces, so the port published in docker-compose.yml works, and use
-- that address in links (e.g. password reset links).
--luacheck: ignore

http_interfaces = { "*" }
http_external_url = "http://localhost:5280/"

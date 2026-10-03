# Prosody community modules

Third-party modules for Prosody 13.0.x (Lua 5.4), written in prosody-modules
style so they can be released publicly.

## Source of truth
- Prosody 13 changed many module APIs (roles/permissions replaced permission
  strings, shell commands, account deletion). Don't rely on memory of older
  versions: check `reference/prosody-src` (13.0 branch) before using any API,
  and copy patterns from its `plugins/`.
- `reference/prosody-modules` has many real modules to learn from. Both
  reference checkouts are read-only: never edit them.
- If a module includes a plan will be in `mod_<name>/docs/PLAN.md`. Read it
  first and ask before deviating from it. If there is no plan, have a dialog
  with the user to clarify the requirements and develop a plan.

## Portability
- Never hardcode hostnames, domains, or JIDs. Use `module.host` and config
  options with sensible defaults.
- Don't assume a deployment layout (component names, parent hosts, storage
  backend). Use Prosody's APIs for storage, HTTP, and permissions so modules
  work on any server.
- Hostnames in `PLAN.md` files are examples, not requirements.

## Conventions
- One directory per module: `mod_<name>/mod_<name>.lua` plus `README.md`
  (config options, Compatibility section) and `spec/` for tests.
- Prosody APIs only: `module:open_store()` for storage, `module:log()` for
  logging, `util.*` libraries. No external Lua dependencies unless there is
  a good reason and it is discussed with the user.
- Never block the event loop: no blocking I/O, sockets, or `os.execute`.
  Use Prosody's async/net APIs.
- Expose APIs to other modules as module globals consumed via
  `module:depends()` (see `mod_invites`).
- Never log secrets, tokens, or full email addresses.

## Dev environment (Docker)
All runtime testing uses the Prosody container defined in `docker-compose.yml`,
never a system-installed Prosody.
- Start or apply changes to `docker-compose.yml`: `docker compose up -d`
- Logs: `docker compose logs -f prosody`
- The repo is mounted read-only at `/opt/xmpp-modules` (the plugin path).
  The test VirtualHost is `localhost`; the admin JID is `admin@localhost`.
- Enable a module by adding it to `PROSODY_ENABLE_MODULES` in `docker-compose.yml`.
- For more complex configurations, write a `prosody.cfg.lua` file and volume mount
  it in the development container.
- Reload after code changes (check `help module` in the shell if the syntax
  differs):
  `docker compose exec prosody prosodyctl shell module reload <name> localhost`
- Create test accounts:
  `docker compose exec prosody prosodyctl adduser <user>@localhost`
- Inspect or exercise a module interactively: `docker compose exec prosody prosodyctl shell`
- Wipe all test data: `docker compose down -v`

## Checks (run before considering a change done)
- Lint: `luacheck mod_<name>/` (config in `.luacheckrc`, from prosody-modules)
- Unit tests: `busted mod_<name>/spec`, for pure functions; keep logic
  testable outside Prosody where practical.
- Integration tests: `test/run-scansion.sh mod_<name>/spec/scansion/*.scs`
  (scansion scripts, run against internal and SQL storage; see README.md).
- Reload the module in the container and confirm the log shows no errors.

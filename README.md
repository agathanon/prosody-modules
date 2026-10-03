# Prosody community modules

Third-party modules for [Prosody](https://prosody.im/) 13.0.x (Lua 5.4),
written in the style of the [prosody-modules](https://modules.prosody.im/)
collection so they can be released publicly.

## Layout

Each module lives in its own directory:

```
mod_<name>/
  mod_<name>.lua   the module
  README.md        configuration options and a Compatibility section
  spec/            busted unit tests
  docs/PLAN.md     design plan (optional)
```

## Installation

Copy (or symlink) a module directory into a directory on Prosody's
`plugin_paths`, then add the module to `modules_enabled`. See each
module's README for its configuration options.

## Development

### Reference checkouts

Development uses read-only checkouts of Prosody 13.0 and the upstream
prosody-modules repository in `reference/` (ignored by git):

```sh
hg clone -u 13.0 https://hg.prosody.im/trunk reference/prosody-src
hg clone https://hg.prosody.im/prosody-modules reference/prosody-modules
```

### Test server

`docker-compose.yml` runs Prosody 13.0 with this repository mounted
read-only as a plugin path. The VirtualHost is `localhost` and the admin
JID is `admin@localhost`; add modules under test to
`PROSODY_ENABLE_MODULES`.

```sh
docker compose up -d
docker compose exec prosody prosodyctl adduser admin@localhost
docker compose exec prosody prosodyctl shell module reload <name> localhost
docker compose logs -f prosody
docker compose down -v   # wipe all test data
```

### Checks

```sh
luacheck mod_<name>/
busted mod_<name>/spec
```

`.luacheckrc` is taken from prosody-modules and declares Prosody's
module globals.

# Plan: Prosody Recovery Email Storage & Ad-hoc Command

Oct 3, 2026 · @C

## Overview and scope

Build a Prosody module, `mod_recovery_email`, that stores one optional recovery email address per user in private server-side storage and lets each user view, set, and remove it through an ad-hoc command (XEP-0050). This is phase 1 of a self-service password reset feature; later phases will build on the storage and API defined here.

**In scope:**

- A module-owned private store holding at most one recovery email record per user.
- An internal Lua API (get, set, clear) and events that later phases can use.
- An ad-hoc command for users to view, set, and remove their own address.
- Cleanup of the record when an account is deleted.
- Admin shell commands to inspect, set, and clear a user's record.

**Out of scope (do not build):**

- **Any web interface for managing the address.** Management is through the ad-hoc command only.
- Sending email of any kind, including SMTP or email-API integration.
- Verification emails and confirmation links. The schema reserves fields for them, but nothing in phase 1 verifies an address.
- The password reset request page and the reset flow itself.

In phase 1, every stored address has status `unverified`, and nothing uses it for resets.

## Environment and constraints

The module targets Prosody 13.0.x running on Lua 5.4 and must use only Prosody's own APIs and utility libraries.

| Item | Value |
| --- | --- |
| Prosody | 13.0.x, Debian package from packages.prosody.im, pinned to `13.0.*` |
| Lua | 5.4 |
| VirtualHost | `example.com` (users are `user@example.com`) |
| Components | `conference.xmpp.example.com`, `upload.xmpp.example.com` (both with `parent_host = "example.com"`) |
| Storage backend | Prosody default (internal files); must also work with SQL backends |
| Install location | Prosody's custom plugin path; loaded via `modules_enabled` on the VirtualHost |
| Test clients | Gajim (desktop) and Cheogram (Android), both with good ad-hoc command support |

Constraints:

- Follow prosody-modules conventions: a single `mod_recovery_email.lua` plus a `README.md` with configuration and a Compatibility section.
- No external Lua dependencies beyond what Prosody ships.
- Never block Prosody's event loop: no blocking I/O or network calls. Phase 1 needs none, but the API design must not assume synchronous email sending later.
- Use Prosody's storage API exclusively; never read or write data files directly.

## Storage design

Store records in a module-owned key-value store opened with `module:open_store("recovery_email")`, keyed by the account's username (local part). Prosody scopes the store to the host automatically, and only server-side code can read it.

Each record is a Lua table with this schema:

| Field | Type | Written in phase 1 | Purpose |
| --- | --- | --- | --- |
| `version` | number | Yes, always `1` | Schema version for future migrations |
| `email` | string | Yes | The normalized address (see Validation under the ad-hoc command section) |
| `status` | string | Yes, always `"unverified"` | `"unverified"` or `"verified"`; only phase 2 sets `"verified"` |
| `created_at` | number | Yes | Unix time the record was first created |
| `updated_at` | number | Yes | Unix time of the last change to `email` |
| `account_created` | number or nil | Yes | The account's `created` time from `usermanager.get_account_info()`, binding the record to this specific account (nil if the auth backend doesn't report it) |
| `verified_at` | number or nil | No (reserved) | Unix time of verification |
| `verify_token_hash` | string or nil | No (reserved) | Hash of a pending verification token; the raw token is never stored |
| `verify_expires` | number or nil | No (reserved) | Expiry of the pending verification token |

Rules:

- A user has either no record or exactly one record. Removing the address deletes the record rather than storing an empty one.
- Setting a different address always resets `status` to `"unverified"` and clears all reserved verification fields.
- Submitting the same address (after normalization) changes nothing, including timestamps.
- A record whose `account_created` doesn't match the current account's `created` time belongs to an earlier account with the same username. Treat it as absent and delete it. Without this, someone who registers a reused username could inherit the previous owner's address, and in phase 2 the previous owner could reset the new owner's password.

Why not existing XMPP storage: vCards are public and readable by anyone, including users on other servers. Private XML storage (`mod_private`) and private PEP nodes are writable by any of the user's client sessions directly, which would let an address be changed without going through this module's validation, events, and future verification. A module-owned store avoids both problems.

## Internal API for later phases

Expose the module's functions so later modules can call them via `module:depends("recovery_email")`, following the same pattern Prosody's `mod_invites` uses for `mod_invites_adhoc` and `mod_invites_register`. All writes, whether from the ad-hoc command, the shell, or another module, must go through these functions so validation and events always apply.

| Function | Returns | Behavior |
| --- | --- | --- |
| `get(username)` | record table or `nil` | Reads the user's record; returns `nil` (and deletes the record) if it belongs to an earlier account (see storage rules) |
| `set(username, email)` | `true, "changed"` or `true, "unchanged"`, or `nil, error_code, message` | Fails if the account doesn't exist (`usermanager.user_exists()`). Validates and normalizes, writes the record per the storage rules, fires `recovery-email-set` only when the result is `"changed"` |
| `clear(username)` | `true, "removed"` or `true, "absent"` | Deletes the record and fires `recovery-email-cleared` only when the result is `"removed"` |
| `validate(email)` | normalized email or `nil, message` | Pure function with no storage access, so it can be unit tested in isolation |

Events, fired on the host with `module:fire_event()`:

| Event | Payload | Future use |
| --- | --- | --- |
| `recovery-email-set` | `{ username, host, email, previous_email }` (`previous_email` may be `nil`) | Phase 2 sends a verification email and notifies the previous address |
| `recovery-email-cleared` | `{ username, host, previous_email }` | Phase 2 notifies the removed address |

The second return value of `set()` and `clear()` lets callers such as the ad-hoc command choose the right message without reading the record again.

No lookup by email address is needed. The future reset flow starts from a JID.

## Ad-hoc command design

Provide one ad-hoc command, named "Recovery email" with node `recovery-email`, that presents a single prefilled form and acts only on the invoking user's own record.

**Access:**

- Only authenticated, registered users of the host (`module.host`) may see or execute the command. Remote and anonymous users must neither see it in the command list nor be able to execute it.
- Use Prosody 13's roles and permissions: declare `module:default_permission("prosody:registered", "adhoc:recovery-email")` and register the command with the `"check"` permission mode (see `plugins/adhoc/adhoc.lib.lua` and `check_permissions()` in `plugins/adhoc/mod_adhoc.lua`). Don't use the `"local_user"` mode that `mod_invites_adhoc` uses: it only compares the sender's host and doesn't exclude `prosody:guest` (anonymous) sessions. With `"check"`, remote JIDs get no role and are refused, and admins can change access per role.
- Derive the username from the stanza's sender (bare JID). As defense in depth, the handler also refuses senders whose host isn't `module.host`. Never accept a username or JID from form input.

**Form**, built with `util.dataforms` and prefilled from the current record (check `util.adhoc` for a helper that supports initial data):

| Field | Type | Content |
| --- | --- | --- |
| Instructions | form instructions | Explains what the address is for and that it is private to the server |
| `current` | fixed | The current address and its status, or "No recovery email set" |
| `email` | text-single | Prefilled with the current address; empty if none |
| `remove` | boolean | "Remove my recovery email"; default false |

**Outcomes on submit:**

| Submission | Result | Note shown to user |
| --- | --- | --- |
| `remove` is true (takes precedence over `email`) | `clear()` | "Recovery email removed." (`"removed"`) or "No recovery email was set." (`"absent"`) |
| New valid address | `set()` returns `"changed"` | "Recovery email saved." |
| Same address as stored, after normalization | `set()` returns `"unchanged"` | "No changes made." |
| Empty `email`, `remove` false | Nothing changes | "No changes made." |
| Invalid address | Nothing stored | Error note with the validation message |
| Rate limit exceeded | Nothing stored | Error note asking the user to try later |

**Validation** (implemented in `validate()`):

1. Trim leading and trailing whitespace.
2. Reject if it isn't valid UTF-8 (`util.encodings.utf8.valid`), is longer than 254 bytes, or contains whitespace or control characters.
3. Require exactly one `@`, with a local part of 1–64 bytes. The domain must have at least two dot-separated labels, all non-empty, so `a@.`, `a@b.`, `a@.b`, and `a@b..c` are all rejected. Quoted local parts (RFC 5321) are deliberately unsupported.
4. Lowercase the domain part (ASCII only, via `string.lower`); keep the local part as entered. Comparisons for "same address" use the normalized form, so a change in the local part's case counts as a new address and resets verification. This is intentional.

**Rate limit:** at most 5 successful changes (set or remove) per user in a burst, refilling at 5 per hour, using `util.throttle` (a token bucket: `throttle.create(5, 3600)`, which regains one change every 12 minutes). This costs little now and prevents abuse once phase 2 sends emails on each change.

- The limit is applied in the ad-hoc command, not in `set()`/`clear()`, so admin shell commands aren't throttled.
- Only successful changes count: `peek()` before acting, spend the token after `set()` returns `"changed"` or `clear()` returns `"removed"`. Invalid and no-op submissions are free.
- Keep per-user throttles in a bounded `util.cache`. They live in memory and reset on module reload or restart, which is acceptable.

## Lifecycle and admin tooling

The record must disappear with the account, and admins need shell access for support cases.

**Account deletion:** `user-deleted` is fired on the global event bus (`core/usermanager.lua`), so hook it with `module:hook_global()` and ignore events where `event.host ~= module.host`, as `mod_tombstones` does. Then delete the user's record. With Prosody 13's deletion grace period (`registration_delete_grace_period`), the account is first only disabled, and `user-deleted` fires later when it is actually deleted, so the record survives the grace period and is still there if the account is restored.

**Registration:** also hook `user-registered` (same host filter) and delete any leftover record for that username. Together with the `account_created` check this covers records left behind when the module wasn't loaded at deletion time.

**Logging:** log set and clear operations at `info` level with the username and a masked address (for example `j***@example.org`). Never log a full address.

**Admin shell commands**, registered through Prosody 13's shell-command mechanism and available in `prosodyctl shell`:

| Command | Behavior |
| --- | --- |
| `recovery_email show <jid>` | Prints the record: email, status, and timestamps |
| `recovery_email set <jid> <email>` | Calls `set()`; the result is `unverified` like any other change |
| `recovery_email clear <jid>` | Calls `clear()` |

Shell commands must go through the internal API so validation, logging, and events apply. Register them with `module:add_item("shell-command", ...)` and `host_selector = "jid"` (see `mod_roster.lua`) so each call reaches the module instance for the JID's host. `set` fails for a JID with no account (enforced by `set()`). It's allowed for disabled accounts, so admins can fix a record before restoring an account. The shell isn't rate limited.

## Security and privacy requirements

The address must be visible only to its owner and to server admins through the shell.

- Never expose the address through service discovery, vCards, PEP, presence, or any stanza except the ad-hoc command response to its owner.
- The command only ever reads or writes the requesting user's own record.
- Treat all form input as untrusted: validate strictly and store only the normalized address.
- Never log full addresses; mask them as described under Logging.
- Nothing in phase 1 uses the address for password resets. The reset flow in a later phase must only use addresses with status `"verified"`, must read them through `get()` so stale records from earlier accounts are ignored, and must refuse resets for disabled accounts, including those pending deletion.
- Because all writes go through `set()` and `clear()`, phase 2 can add verification and change notifications without modifying the command.

## Testing and acceptance criteria

Phase 1 is done when every item below passes on Prosody 13.0.x.

**Automated:**

- [ ] `luacheck` passes with Prosody's module globals.
- [ ] Unit tests (busted) for `validate()`: valid addresses, whitespace trimming, domain lowercasing, and rejection of missing or multiple `@`, missing domain dot, empty domain labels (`a@.`, `a@b.`, `a@.b`, `a@b..c`), internal whitespace, control characters, invalid UTF-8, local parts over 64 bytes, and addresses over 254 bytes.

**Manual, with Gajim and Cheogram:**

- [ ] Module loads with no errors in `prosodyctl check` or the Prosody log.
- [ ] A local user sees "Recovery email" in the server's command list.
- [ ] A user on another server cannot see the command, and executing it directly is refused.
- [ ] An anonymous user (`prosody:guest`) cannot see or execute the command.
- [ ] Setting a valid address stores it with status `unverified` and both timestamps.
- [ ] Reopening the command shows the form prefilled with the current address and status.
- [ ] An invalid address is rejected with a clear message, and the stored record is unchanged.
- [ ] Resubmitting the same address changes nothing, including `updated_at`, and fires no event.
- [ ] Removing the address deletes the record.
- [ ] A sixth change made right after five quick changes is refused; a change about 12 minutes later succeeds. No-op and invalid submissions don't use up the limit.
- [ ] `recovery-email-set` and `recovery-email-cleared` fire with correct payloads (verify with a small test module that logs them).
- [ ] Records persist across a Prosody restart.
- [ ] Deleting the account removes the record; with a deletion grace period, the record survives until the account is actually deleted.
- [ ] A record left behind for a deleted username (e.g. module unloaded during deletion) is not visible to a new account registered with that username.
- [ ] All three shell commands work, `set` goes through validation, and `set` fails for a JID with no account.
- [ ] Logs show only masked addresses.

## Reference material

Read the Prosody 13 sources below before writing code; they are the authority wherever this plan and the actual APIs differ.

- [Prosody 13.0.0 release notes](https://prosody.im/doc/release/13.0.0): the roles and permissions framework, `parent_host`, and other changes affecting modules.
- [Prosody HTTP and module docs](https://prosody.im/doc), including the module API and developer documentation.
- Prosody 13 source, in the 13.0 branch at hg.prosody.im:
  - `plugins/mod_invites.lua`: the pattern for exposing an API to other modules.
  - `plugins/mod_invites_adhoc.lua`: ad-hoc commands with Prosody 13 permissions.
  - `util/adhoc.lua` and `util/dataforms.lua`: command and form helpers.
  - `plugins/mod_admin_shell.lua`: how modules register shell commands.
- [XEP-0050: Ad-Hoc Commands](https://xmpp.org/extensions/xep-0050.html) and XEP-0004: Data Forms.
- The prosody-modules repository, for README and Compatibility section conventions.


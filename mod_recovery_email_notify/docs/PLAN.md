# Plan: Recovery email notifications

Oct 3, 2026

## Overview and scope

Build `mod_recovery_email_notify`, which sends the emails that `mod_recovery_email` phase 2 calls for. It listens to `mod_recovery_email`'s events, writes each message, and hands it to `mod_smtp_async` for delivery. It stores nothing and makes no decisions about verification; those belong to `mod_recovery_email` (see the phase 2 section of `mod_recovery_email/docs/PLAN.md`).

**In scope:**

- Three emails: the verification code, a notice that the address was replaced, and a notice that it was removed.
- Configurable sender address, subjects and message text, with sensible English defaults.
- Logging of delivery results, with masked addresses.

**Out of scope:**

- Sending mail itself (that's `mod_smtp_async`).
- HTML email, attachments, or translations into other languages. Admins can rewrite the text in any language through configuration.
- Emails on account deletion.

## Environment and constraints

Same as the other modules: Prosody 13.0.x, Lua 5.4, Prosody APIs only, never block the event loop. Loaded on the same VirtualHost as `mod_recovery_email`, with `module:depends("recovery_email")` and `module:depends("smtp_async")`.

## Emails

| Email | Sent when | To | Purpose |
| --- | --- | --- | --- |
| Verification code | `recovery-email-verification-requested` | The new address | Gives the user the code and how long it's valid |
| Address replaced | `recovery-email-set` with `previous_email` set and `previous_status == "verified"` | The previous address | Warns the owner in case the change wasn't theirs |
| Address removed | `recovery-email-cleared` with `previous_status == "verified"` | The removed address | Same, for removal |

Rules:

- Never email an address that was never verified, except for the verification code itself. This stops the module being used to send mail to strangers.
- The notices don't include the new address, only the account (JID), the time, and who made the change. If the change wasn't the owner's, the new address belongs to the attacker, and naming it gives nothing useful to the owner while exposing more than needed.
- When `source == "shell"`, the notices say the change was made by a server administrator; otherwise, that it was made from the account.
- Each notice ends with what to do if the change wasn't the owner's: contact the server admin. The contact address comes from Prosody's `contact_info` option (the `admin` entry, as used by `mod_server_contact_info`) when it's configured, and is left out otherwise.

## Message content

Plain text, UTF-8. Each email is a subject and a body template, rendered with `util.interpolation` (as Prosody's own modules do). Available variables:

| Variable | Value |
| --- | --- |
| `{jid}` | The account, e.g. `user@example.com` |
| `{host}` | The VirtualHost |
| `{code}` | The verification code (verification email only) |
| `{expires}` | When the code expires, as a UTC date and time (verification email only) |
| `{changed_by}` | "you" or "a server administrator" (notices only) |
| `{time}` | When the change happened, UTC (notices only) |
| `{contact}` | The admin contact address, or empty |

**Configuration** (all optional):

| Option | Default | Purpose |
| --- | --- | --- |
| `recovery_email_from` | `noreply@` + the VirtualHost name | The `From` address |
| `recovery_email_messages` | Built-in English texts | A table overriding any of the subjects and bodies, keyed by `verification`, `replaced` and `removed` |

The defaults are drafted during implementation and reviewed with the user before release.

## Delivery and failures

- Each email is a single call to `mod_smtp_async`'s `send()`, which returns a promise. The notifier logs success at `info` and failure at `warn`, with the masked recipient and the error, and never retries itself; retrying temporary failures is `mod_smtp_async`'s job.
- A failed verification email leaves the code pending; the user can ask for a new one in the ad-hoc command. A failed notice is only logged.
- Codes and full addresses never appear in logs.

## Testing and acceptance criteria

**Automated:**

- [ ] `luacheck` clean.
- [ ] Unit tests (busted, with a fake `mod_smtp_async`): which events produce which email, the verified-only rule, "you" vs "a server administrator", the contact line with and without `contact_info`, configured overrides, and that nothing is logged containing a code or full address.
- [ ] Integration: with the test Prosody sending to a mail catcher, the verification email arrives with the same code the test helper module reports, and the notices arrive at the previous address.

**Manual:**

- [ ] Each of the three emails arrives in the dev mail catcher with the expected text.
- [ ] Overriding a subject and body in the config takes effect after a reload.

## Reference material

- `mod_recovery_email/docs/PLAN.md`, phase 2: the events and their payloads.
- `mod_smtp_async/docs/PLAN.md`: the sending API.
- Prosody 13 source: `util/interpolation.lua` (used by `plugins/mod_invites.lua` and `plugins/mod_http_errors.lua`), and `plugins/mod_server_contact_info.lua` for the `contact_info` option.
- prosody-modules: `mod_invites_page/mod_invites_page.lua` for templating with `util.interpolation` in a community module.

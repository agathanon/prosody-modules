# Plan: Password reset through the recovery email address

Oct 4, 2026

## Overview and scope

Build `mod_recovery_email_reset`, phase 3 of self-service password reset: someone who has forgotten their password enters their JID on a web page, receives a single-use link at the account's verified recovery address, and uses it to choose a new password.

It builds on the earlier phases: `mod_recovery_email` decides which address may be used, `mod_recovery_email_notify` writes the emails, and `mod_smtp_async` sends them. Phase 3 also adds a little to each of the first two; see the "Phase 3" sections of their plans.

**Decisions made in planning:**

- The reset happens on **our own web pages**, not through Prosody's `create_account_reset()` invites. Those can only be redeemed by XMPP clients that support XEP-0401 invites, and no web page in Prosody or prosody-modules handles them (`mod_invites_page` explicitly skips reset invites). The community `mod_password_reset` has a web flow, but offers no API to other modules and stores and logs tokens in plain text, so it's a reference only.
- The email contains a **single-use link**, not a code.
- An optional **cooling-off period** (off by default) stops a newly verified address that replaced a verified one from being used for resets for a while.
- After a reset, the verified address gets a **"password was reset"** confirmation email.

**In scope:**

- A request page (enter a JID) and a reset page (choose a new password), served by Prosody's `mod_http`.
- Reset tokens: creation, storage as hashes, expiry and single use.
- Rate limits per JID and per client IP address.
- Events for the notifier, and two new emails in `mod_recovery_email_notify`.
- The cooling-off period, stored and enforced by `mod_recovery_email`.

**Out of scope:**

- Resetting through XMPP clients (XEP-0401 invites) or an ad-hoc command.
- CAPTCHAs, translations of the pages (templates can be overridden), and JavaScript.
- Admin-initiated reset links.
- Warning emails when account deletion is requested, and a persistent SMTP retry queue (both deferred).

## Environment and constraints

Same as the other modules: Prosody 13.0.x, Lua 5.4, Prosody APIs only, never block the event loop. Loaded per VirtualHost with `module:depends("recovery_email")` and `module:depends("http")`; the notifier is a separate module the admin enables, as in phase 2.

Facts from the Prosody 13 sources this design relies on:

- `usermanager.set_password()` fires `user-password-changed`, and `mod_c2s` then disconnects all of the user's sessions; `mod_tokenauth` invalidates grants issued before the last password change. So a reset locks out anyone using a stolen session or app token without extra work here.
- `mod_http` gives each request's client address as `request.ip`, taking `X-Forwarded-For` into account for proxies listed in `trusted_proxies`, and builds public URLs with `module:http_url()` from `http_external_url`.
- `usermanager.user_is_enabled()` reports disabled accounts, including those pending deletion.

## User flow

1. **Request page** (`GET /`): a form with one field, the JID.
2. **Request submitted** (`POST /`): the page always answers the same way: *"If this account has a verified recovery email address, we've sent a link to it. The link is valid for 1 hour."* If the account is eligible, a token is created and the reset email requested.
3. **Link opened** (`GET /reset/<token>`): if the token is valid, a form with "New password" and "Confirm password". Otherwise: *"This link is invalid or has expired. You can request a new one."*, linking to the request page. Opening the link changes nothing, so email security scanners that follow links can't use it up.
4. **New password submitted** (`POST /reset/<token>`): checks the token again, the two passwords match, and the password rules. On success, the password is changed, the token is deleted, and the page says *"Your password has been changed. You can now sign in with it."* On a rule failure, the form is shown again with the reason.

Paths are relative to the module's HTTP path, by default `/recovery_email_reset`, which admins can change with Prosody's `http_paths` option.

## Eligibility

A request results in an email only if all of these hold; otherwise nothing is sent and the response is the same:

- The JID is on this module's host and the account exists.
- The account is enabled (not disabled or pending deletion).
- `mod_recovery_email` reports a recovery address usable for resets: verified, and outside any cooling-off period (see the phase 3 section of `mod_recovery_email/docs/PLAN.md`).
- The request is within the rate limits.

The reason a request was refused is logged at `debug` level for admins, never shown on the page.

## Tokens

- Generated with `util.id.long()` (cryptographically random) and placed in the link: `https://<http_url>/reset/<token>`.
- Stored only as a SHA-256 hash, with the username and expiry. A hash is enough here: unlike phase 2's 6-digit codes, a long random token can't be guessed, so knowing the hash doesn't help.
- At most one pending link per user: a new request replaces the previous token.
- Valid for 1 hour by default (`recovery_email_reset_link_lifetime`), and for one successful reset only.
- Never logged, and never shown anywhere but in the email and the address bar.
- Expired tokens are deleted when looked up, and a daily cleanup (via `module:daily()`) removes the rest.

## Rate limits

In memory, using `util.throttle` as in phase 1:

| Limit | Default | Option |
| --- | --- | --- |
| Requests per JID | 3 per hour | `recovery_email_reset_requests_per_jid` |
| Requests per client IP | 10 per hour | `recovery_email_reset_requests_per_ip` |
| Password submissions per client IP | 10 per hour | (same as above) |

When a limit is reached, the page says *"Too many requests. Please try again later."* This reveals nothing about the account, since the limits apply to every JID alike. Behind a reverse proxy, `trusted_proxies` must be configured for per-IP limits to see real addresses; the README will say so.

## Password rules

- At least `recovery_email_reset_min_password_length` characters (default 8), at most 1024 bytes, and valid UTF-8.
- If the community `mod_password_policy` is loaded on the host, its `check_password()` is used as well (soft dependency).

## Pages

- Plain HTML with inline CSS, no JavaScript, no external resources. Built-in templates are in the module's `html/` directory and can be replaced with `recovery_email_reset_template_path`. The site name shown on the pages is `recovery_email_reset_site_name`, by default the host name.
- Rendered with `util.interpolation`, escaping all values with `util.stanza.xml_escape`.
- Every response sets: `Content-Security-Policy: default-src 'none'; style-src 'unsafe-inline'; form-action 'self'; frame-ancestors 'none'`, `Referrer-Policy: no-referrer` (the token is in the URL), `Cache-Control: no-store`, and `X-Content-Type-Options: nosniff`.
- The module logs a warning at startup if its public URL isn't HTTPS, unless the host is `localhost`.

## Events

| Event | Payload | Used by |
| --- | --- | --- |
| `recovery-email-reset-requested` | `{ username, host, email, url, expires }` | The notifier sends the link. Carries the secret link, so handlers must never log or store it |
| `recovery-email-password-reset` | `{ username, host, email }` | The notifier sends the confirmation |

`email` is the verified address the link was sent to.

## Security notes

- Responses to requests don't reveal whether an account exists, has an address, or is enabled. Response timing could differ slightly (the email is sent asynchronously, so the difference is a storage lookup); this is accepted.
- The request form can be submitted from other sites (cross-site request forgery), but the most it can do is send the owner a reset email, which the per-JID limit bounds. The reset form is protected by the token itself.
- A reset disconnects all the user's sessions and invalidates older app tokens (Prosody does this), and the owner is emailed a confirmation.

## Logging

- `info`: a reset link was sent (username, masked address); a password was reset (username).
- `debug`: refused requests with the reason; rate-limit hits with the client IP.
- Never: tokens, links, passwords, or full addresses.

## Testing and acceptance criteria

**Automated:**

- [ ] `luacheck` clean.
- [ ] Unit tests: eligibility rules, token creation, hashing, single use, expiry and replacement, rate limits, password rules, template escaping, response headers, identical responses for eligible and ineligible requests, and that nothing secret is logged.
- [ ] Integration (in `test/run-smtp.sh` or a new runner): on a test VirtualHost with real password storage (`internal_hashed`, since the existing test hosts accept any password), set and verify an address from the shell, request a reset over HTTP, read the link from Mailpit, set a new password through the page, and confirm with `usermanager.test_password()` that the new password works and the old one doesn't. Also: an ineligible JID gets the same response and no email; a used or expired link is refused; the confirmation email arrives.

**Manual, with a browser, Gajim and Mailpit on the dev server:**

- [ ] The dev `docker-compose.yml` publishes Prosody's HTTP port on `127.0.0.1`.
- [ ] Request, link, new password, and signing in to Gajim with the new password all work; an existing Gajim session is disconnected by the reset.
- [ ] The pages work without JavaScript and look reasonable on a phone-sized window.
- [ ] Logs contain no tokens or passwords.

## Reference material

- Prosody 13 source: `plugins/mod_http.lua` (`request.ip`, `trusted_proxies`, `http_url`), `core/usermanager.lua` (`set_password`, `user_is_enabled`), `plugins/mod_c2s.lua` and `plugins/mod_tokenauth.lua` (what happens on a password change), `util/interpolation.lua`, `util/id.lua`.
- prosody-modules: `mod_password_reset` (web reset flow, for reference), `mod_invites_register_web` (templates, form handling), `mod_password_policy` (optional password rules).
- `mod_recovery_email/docs/PLAN.md` and `mod_recovery_email_notify/docs/PLAN.md`, phase 3 sections.

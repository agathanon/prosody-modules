# Security controls: recovery email and password reset modules

Written 2026-10-04 for security review, against `master` at commit
`a8587ab` (after phase 3 was merged).

This document describes the security controls in four Prosody 13
modules that together provide self-service password reset through a
recovery email address, and the risks that remain. It is meant to be
checked against the code: every control names the module and function
or option that implements it. Where this document and the code disagree,
the code is authoritative and the disagreement is a finding.

## Contents

1. [Scope](#1-scope)
2. [System overview](#2-system-overview)
3. [Threat model](#3-threat-model)
4. [Controls](#4-controls)
5. [Limits and lifetimes](#5-limits-and-lifetimes)
6. [Known risks and limitations](#6-known-risks-and-limitations)
7. [Security testing performed](#7-security-testing-performed)
8. [Suggested review focus](#8-suggested-review-focus)
9. [References](#9-references)

## 1. Scope

| Module | Role |
| --- | --- |
| `mod_recovery_email` | Stores one recovery address per user; "Recovery email" ad-hoc command; verification codes; cooling-off period; admin shell commands (`recovery show/set/clear`); API and events for the other modules |
| `mod_recovery_email_notify` | Writes the emails (verification code, change notices, reset link, reset confirmation) in response to events |
| `mod_recovery_email_reset` | Unauthenticated web pages: request a reset link, then choose a new password |
| `mod_smtp_async` | Generic non-blocking SMTP client used to send all of the above |

Also in the repository but **not for production**:

- `test/plugins/mod_test_recovery_codes.lua`: a test-only module that
  sends verification codes to listed users over XMPP. It must never be
  loaded on a real server.
- `dev/*.cfg.lua` and `docker-compose.yml`: a local development setup
  with plain-text SMTP and plain HTTP by design.

Out of scope: Prosody itself, other community modules, the mail server,
and the deployment (TLS termination, reverse proxy, OS).

## 2. System overview

### Flows

1. **Set address:** an authenticated user opens the "Recovery email"
   ad-hoc command (XEP-0050) and saves an address. It is stored as
   `unverified`, and a 6-digit code is emailed to it.
2. **Verify:** the user enters the code in the same command. The
   address becomes `verified`.
3. **Change or remove:** the user (or an admin via the shell) changes or
   removes the address. If the previous address was verified, it is
   emailed a notice.
4. **Reset:** an unauthenticated visitor enters a JID on the web page.
   If the account is enabled and has a verified address usable for
   resets, a single-use link is emailed to that address. The link opens
   a form to set a new password. Afterwards a confirmation is emailed to
   the address, and Prosody signs out the user's sessions.

### Actors and trust boundaries

| Actor | Trust | Interface |
| --- | --- | --- |
| Authenticated local user (`prosody:registered`) | Trusted for their own account only | Ad-hoc command over XMPP |
| Anonymous user (`prosody:guest`), users of other hosts | Untrusted | Must not reach the ad-hoc command |
| Unauthenticated web visitor | Untrusted | Reset web pages (`mod_recovery_email_reset`) |
| Server admin | Fully trusted | `prosodyctl shell` (local socket), configuration |
| Other Prosody modules | Fully trusted (same process) | Module APIs and events |
| Mail server | Trusted to relay; connection authenticated by TLS certificate | SMTP submission |
| Recipient mailbox | Proves control of an address by receiving codes/links | Email |

### Assets

| Asset | Where it lives |
| --- | --- |
| Recovery email addresses (personal data) | `recovery_email` store, plain text (needed to send email) |
| Verification codes | Only in memory, events and email; stored as salted SHA-256 hashes |
| Reset tokens | Only in memory, events, email and the URL; stored as SHA-256 hashes |
| Account passwords | Set through `usermanager.set_password()`; never stored or logged by these modules |
| SMTP credentials | Prosody configuration; never logged |

## 3. Threat model

**Defended against:**

- Account takeover through the reset flow by someone who doesn't
  control the account's verified recovery address.
- Using the reset page to find out which accounts exist, are enabled, or
  have a recovery address (account enumeration).
- Someone with brief access to a logged-in session (e.g. an unlocked
  device) silently making their own address the recovery address.
- Using the modules to send email to arbitrary addresses (spam/harassment
  relay).
- Guessing verification codes or reset tokens.
- Interception or tampering of email submission (TLS downgrade, wrong
  certificate).
- Injection: SMTP commands or email headers, HTML/script in web pages.
- Leaking codes, tokens, passwords or full addresses through logs.
- Records outliving their account and applying to a new account with
  the same username.
- Blocking Prosody's event loop (availability) while sending email.

**Explicitly not defended against** (by design or out of scope):

- A compromised recovery mailbox: whoever controls the verified address
  can reset the password. This is inherent to email-based recovery.
- A malicious or compromised server admin, Prosody process, or storage.
- Malicious modules loaded in the same Prosody.
- Requiring the account password to change the recovery address. This
  was considered and rejected as too much friction; see risk R1.

## 4. Controls

### 4.1 Access control

| Control | Implementation |
| --- | --- |
| The ad-hoc command uses Prosody 13's role-based permissions, not a host check alone | `mod_recovery_email`: `module:default_permission("prosody:registered", "adhoc:recovery-email")` and `new_adhoc(..., "check")`. Anonymous (`prosody:guest`) sessions and remote JIDs have no such permission |
| Defense in depth: the handler refuses senders not on this host | `mod_recovery_email`: `local_username()` in `command_handler()` |
| Users can only act on their own record | Username is taken from the stanza's `from`, never from form input |
| Admin operations only through `prosodyctl shell` | Shell commands registered with `host_selector = "jid"`; the shell is reached through Prosody's local admin socket |
| Admin changes are marked in logs and notices | `source = "shell"` passed to `set()`/`clear()`: logged "(via shell)", and notices say "by a server administrator" |
| Reset pages need no login, but only change a password with a valid link | `mod_recovery_email_reset`: `post_reset()` requires a valid token bound to the account |

### 4.2 Input validation

**Recovery addresses** (`mod_recovery_email`: `validate()`):

- Trimmed; must be valid UTF-8 (`util.encodings.utf8.valid` and
  `utf8.len`); at most 254 bytes; local part at most 64 bytes.
- No ASCII whitespace or control characters, no C1 controls, and no
  Unicode spaces or invisible characters (U+00A0, U+1680, U+2000–U+200B,
  U+2028, U+2029, U+202F, U+205F, U+3000, U+FEFF).
- Exactly one `@`; domain needs a dot and no empty labels.
- Domain lowercased; local part kept as entered.

**Verification codes** (`normalize_code()`): spaces and hyphens removed,
then must be exactly 6 digits; anything else counts as a wrong attempt.

**Reset requests** (`handle_request()`): input trimmed; a bare username
gets `@<host>` appended; parsed with `jid.prepped_split()` (stringprep);
invalid input gets an "enter your chat address" error, which reveals
nothing about accounts. JIDs on other hosts are treated as ineligible.

**Reset tokens** (`find_token()`): must be at most 64 characters of
`[A-Za-z0-9_-]` before any lookup, so path tricks such as `../` are
rejected early.

**New passwords** (`check_password()`): non-empty, valid UTF-8, at least
`recovery_email_reset_min_password_length` characters (default 8), at
most 1024 bytes, both fields equal; plus `mod_password_policy`'s
`check_password()` (with the username) when that module is loaded.

**Form bodies:** decoded with `util.http.formdecode()`; non-table results
(bodies without `=`) are treated as empty forms (`form_data()`).

**Outgoing email** (`mod_smtp_async`: `validate_message()`):

- `to` and `from` must be valid UTF-8 and match
  `^[^%s%c<>@]+@[^%s%c<>@]+$`, so no spaces, control characters,
  angle brackets or second `@`.
- Subject: valid UTF-8 and no CR or LF.
- Body: valid UTF-8.
- Extra header names: `^%a[%w%-]*$` and not one of the headers the
  module sets itself; values ASCII, no control characters, at most 900
  bytes.

### 4.3 Secrets: codes, tokens, credentials

**Verification codes** (`mod_recovery_email`):

- 6 decimal digits from `util.random.bytes()` (cryptographically
  secure), with rejection sampling so all codes are equally likely
  (`new_code()`).
- Stored only as `salt$hash`: SHA-256 over a random 16-byte salt and the
  code (`hash_code()`); compared with `util.hashes.equals()`, which is
  constant-time (`check_code()`).
- Valid for 24 hours (`recovery_email_code_lifetime`); at most 5 wrong
  attempts, after which the code is cancelled; attempts are counted in
  storage, so they survive restarts.
- A new code replaces the old one; changing the address starts over.
- Never logged; never shown by `recovery show`; carried only in the
  `recovery-email-verification-requested` event and the email.

**Reset tokens** (`mod_recovery_email_reset`):

- `util.id.long()`: 27 random bytes (216 bits), base64url-encoded.
- Stored only as a SHA-256 hash (no salt needed: unguessable input), as
  the storage key; the plain token never touches storage
  (`create_token()`).
- Valid for 1 hour (`recovery_email_reset_link_lifetime`); single use
  (deleted on success); at most one pending link per user (a new request
  replaces it).
- Bound to the account and to the address it was sent to: the link is
  refused if `get_reset_address()` no longer returns that address, or the
  account is disabled or gone (`get_reset()`, `post_reset()`).
- Cancelled when the password changes by any other means
  (`user-password-changed` hook) and when the account is deleted.
- Expired tokens are deleted on lookup and by a daily job
  (`module:daily`).
- Never logged by these modules (but see R3); carried only in the
  `recovery-email-reset-requested` event, the email and the URL.

**SMTP credentials** (`mod_smtp_async`): never logged (the AUTH exchange
is logged as "(credentials)", "(username)", "(password)"); never sent
without TLS (see 4.8).

**Passwords:** passed straight to `usermanager.set_password()`; not
stored, logged or echoed back in pages.

### 4.4 Account takeover defenses

| Defense | Implementation |
| --- | --- |
| Only verified addresses can receive reset links | `get_reset_address()` returns an address only when `status == "verified"` |
| Disabled accounts (including those pending deletion) get no reset | `reset_address()` in `mod_recovery_email_reset` checks `usermanager.user_is_enabled()` |
| The owner is warned when a verified address is replaced or removed | `mod_recovery_email_notify`: "replaced" and "removed" notices to the previous **verified** address, saying whether an admin made the change |
| Optional cooling-off period | `recovery_email_reset_delay` (off by default): an address that took the place of a verified one can't be used for resets until the delay has passed after verification (`replaced_verified`, `reset_allowed_after`) |
| Cooling-off can't be skipped by removing first | `clear()` of a verified address records the time in the `recovery_email_removed` store; `replaces_verified()` applies the delay to an address set within the delay after that |
| The owner is told when the password is reset | "reset_done" email to the verified address |
| A reset ends other sessions | Prosody core: `usermanager.set_password()` fires `user-password-changed`, and `mod_c2s` disconnects all of the user's sessions; `mod_tokenauth` invalidates grants issued before the change |
| Records can't outlive their account | Record stores the account's `created` time (`account_created`); `get()` deletes and ignores records whose time doesn't match the current account; records also removed on `user-deleted` and `user-registered`, and by Prosody's purge of user data on deletion |
| Links can't be redirected by request headers | The link's base URL comes from configuration (`module:http_url()`, computed at load), never from the request's `Host` header |

### 4.5 Enumeration resistance and privacy

- The reset request page gives a byte-for-byte identical response for
  eligible and ineligible requests (unknown account, other host,
  disabled account, no or unverified address, cooling-off). The reason is
  logged at `debug` only. Verified by unit and integration tests.
- Rate limits apply to every JID alike, so "Too many requests" reveals
  nothing about a specific account.
- The recovery address is never exposed over XMPP except to its owner in
  the ad-hoc form. It isn't in vCards, PEP, presence or disco.
- Change notices name the account, time and who made the change, but not
  the new address.
- Notices go only to addresses that were verified, so typing someone
  else's address can trigger at most the single verification email.
- Logs show addresses masked (`a***@example.org`) in all four modules.
- `mod_smtp_async` keeps only the SMTP reply code and enhanced status
  code in errors and logs, never the server's text, which may contain
  addresses.

### 4.6 Rate limiting and abuse

See [section 5](#5-limits-and-lifetimes) for values. Notes:

- Ad-hoc changes and new codes have separate per-user limits; the change
  limit is only consumed by successful changes, and verifying doesn't
  consume it.
- Reset requests are limited per IP before the per-JID limit is
  consulted, and password submissions have their own per-IP limit.
- Per-IP limits use `request.ip`, which `mod_http` derives from
  `X-Forwarded-For` only for proxies listed in `trusted_proxies`.
- Shell commands are not rate limited (admins are trusted).

### 4.7 Web pages (`mod_recovery_email_reset`)

| Control | Implementation |
| --- | --- |
| No JavaScript, no external resources | Templates in `html/`; inline CSS only |
| Content Security Policy | `default-src 'none'; style-src 'unsafe-inline'; form-action 'self'; frame-ancestors 'none'; base-uri 'none'` |
| No referrer (token is in the URL) | `Referrer-Policy: no-referrer` |
| No caching of pages with tokens | `Cache-Control: no-store` |
| No MIME sniffing | `X-Content-Type-Options: nosniff` |
| Clickjacking | `frame-ancestors 'none'` |
| Cross-origin reads | CORS turned off (`cors = { enabled = false }`); `mod_http` enables it by default otherwise |
| Output escaping | All template values go through `util.interpolation` with `util.stanza.xml_escape`; only the already-rendered page content is inserted raw (`{content!}`) |
| Link scanners can't use up links | `GET /reset/<token>` only shows the form; the password changes only on `POST` |
| CSRF | The reset form is protected by the secret token in its URL. The request form has no CSRF token, by design: a forged request can only send the real owner a reset email, bounded by the per-JID limit |
| HTTPS | Links use `module:http_url()` (HTTPS when configured, or `http_external_url`); a warning is logged at startup if links would use plain HTTP, except for localhost |
| No open redirects | The module never redirects |
| Search engines | `<meta name="robots" content="noindex">` |

### 4.8 Email transport (`mod_smtp_async`)

| Control | Implementation |
| --- | --- |
| Encryption required by default | `smtp_async_tls = "starttls"` (default) fails if the server doesn't offer STARTTLS; it never falls back to plain text. `"tls"` uses implicit TLS from the start |
| Server certificate verified | TLS context from `certmanager.create_context()` with `verify = "peer"` (and optional `smtp_async_cafile`); after the handshake, `ssl_peerverification()` (chain) and `util.x509.verify_identity()` against `smtp_async_server` (name), as Prosody's own `net.http` does. LuaSec additionally aborts handshakes with untrusted chains |
| Certificate failures are permanent | Not retried (`session:disconnected()` treats handshake failures as permanent) |
| Turning verification off is loud | `smtp_async_verify_certificate = false` logs a warning at startup |
| Credentials only over TLS | `authenticate()` refuses AUTH without TLS; configuring credentials with `smtp_async_tls = "none"` makes every send fail (fail closed), with an error at startup |
| No injection | Message fields validated (4.2); body base64-encoded; non-ASCII subjects as RFC 2047 encoded-words; dot-stuffing applied anyway (`dot_stuff()`); commands built only from validated values |
| SMTPUTF8 | Non-ASCII addresses only sent if the server offers SMTPUTF8; otherwise the send fails instead of mangling the address |
| Bounded resources | At most 4 simultaneous connections; per-step timeout (default 30 s); at most 3 retries (1, 5, 15 minutes) for temporary failures only (4xx, timeouts, dropped connections); 5xx and certificate errors are permanent |
| Never blocks Prosody | Uses Prosody's `net.connect` and event loop; no LuaSocket SMTP, `io.popen` or `os.execute` |
| Automated mail marked as such | `mod_recovery_email_notify` sets `Auto-Submitted: auto-generated` (RFC 3834) |

A Prosody 13.0 networking bug (connections whose server speaks first
are closed as "connection timeout") is worked around by reading replies
line by line (`pattern = "*l"`); see
`docs/upstream/server-epoll-connection-timeout.md`. This is an
availability issue, not a security one.

### 4.9 Data lifecycle

| Data | Lifetime |
| --- | --- |
| Recovery record | Until removed by the user/admin or the account is deleted; ignored and deleted if it belongs to an earlier account |
| Pending verification code (hash) | 24 hours or 5 wrong attempts; replaced by a new code |
| Removal marker (cooling-off) | Only written when the delay is enabled; consumed by the next `set()` or ignored once older than the delay; removed on account deletion/registration |
| Reset token (hash) | 1 hour, single use; replaced by a new request; removed on any password change or account deletion; daily cleanup of expired entries |
| Rate-limit state | In memory only; lost on restart |
| Queued emails | In memory only; lost on restart |

### 4.10 Logging

| Module | Logs at `info`/`warn` | Never logs |
| --- | --- | --- |
| `mod_recovery_email` | Address set/removed/verified (username, masked address, "(via shell)"); wrong code attempts (count only); stale records removed | Codes, code hashes, full addresses |
| `mod_recovery_email_notify` | Email type, username, masked recipient, outcome | Codes, reset links, full addresses, message text |
| `mod_recovery_email_reset` | Link sent, password reset (username only). Refused requests and rate-limit hits (with client IP) at `debug` | Tokens, links, passwords, full addresses |
| `mod_smtp_async` | Sent/failed with message ID, masked recipient, reply code and enhanced status, attempt. Protocol steps at `debug` with addresses and AUTH data omitted | Passwords, message content, full addresses, server reply text |

These guarantees hold for these modules only. See R3 for what Prosody
itself logs at `debug` level.

## 5. Limits and lifetimes

| Limit | Default | Configurable | Where |
| --- | --- | --- | --- |
| Address changes per user (ad-hoc) | 5 in a burst, refilling 5/hour | No | `mod_recovery_email` |
| New codes per user (ad-hoc "Send a new code") | 3 in a burst, refilling 3/hour | No | `mod_recovery_email` |
| Wrong attempts per code | 5 | No | `mod_recovery_email` |
| Code lifetime | 24 hours | `recovery_email_code_lifetime` | `mod_recovery_email` |
| Cooling-off after replacing a verified address | Off | `recovery_email_reset_delay` | `mod_recovery_email` |
| Reset requests per JID | 3/hour | `recovery_email_reset_requests_per_jid` | `mod_recovery_email_reset` |
| Reset requests per IP | 10/hour | `recovery_email_reset_requests_per_ip` | `mod_recovery_email_reset` |
| Password submissions per IP | 10/hour | (same option) | `mod_recovery_email_reset` |
| Reset link lifetime | 1 hour | `recovery_email_reset_link_lifetime` | `mod_recovery_email_reset` |
| Minimum new password length | 8 characters | `recovery_email_reset_min_password_length` | `mod_recovery_email_reset` |
| Maximum new password size | 1024 bytes | No | `mod_recovery_email_reset` |
| Rate-limit entries kept in memory | 1024 users (ad-hoc), 4096 keys per limit (web) | No | both |
| Simultaneous SMTP connections | 4 | No | `mod_smtp_async` |
| SMTP step timeout | 30 seconds | `smtp_async_timeout` | `mod_smtp_async` |
| SMTP retries | 3 (after 1, 5, 15 minutes) | `smtp_async_retries` | `mod_smtp_async` |

All rate limits use `util.throttle` (token buckets), so "N per hour"
means a burst of N, then one more every 60/N minutes.

## 6. Known risks and limitations

Severity is the author's assessment, for reviewers to challenge.

| ID | Risk | Severity | Status / mitigation |
| --- | --- | --- | --- |
| R1 | **No password needed to change the recovery address.** Someone with brief access to a logged-in session can set and verify their own address, then later reset the password. | Medium | Accepted design decision (too much friction). Mitigated by the notice to the previous verified address, and optionally by the cooling-off period (R2). |
| R2 | **Cooling-off is off by default**, so R1's window is open unless an admin configures `recovery_email_reset_delay`. | Medium | Accepted (decided in planning). Documented in `mod_recovery_email`'s README. |
| R3 | **Prosody's debug logging exposes secrets.** Prosody's HTTP server logs request paths at `debug`, so reset tokens appear in debug logs. If the optional `mod_stanza_debug` is loaded, full stanzas, including codes and addresses entered in the ad-hoc form, are logged too. (By default Prosody logs only stanzas' top tags, which contain neither.) | Low–Medium (depends on log access) | Documented for reset tokens in `mod_recovery_email_reset`'s README; tokens are single-use and expire in an hour. `mod_stanza_debug` isn't documented yet. |
| R4 | **Codes can be recovered from storage.** With read access to storage, a 6-digit code's salted hash can be brute-forced instantly. | Low (requires storage access) | Accepted; codes are short-lived; documented. |
| R5 | **Rate-limit state is evictable and volatile.** Limits are in memory (reset on restart), and the web limits keep at most 4096 keys each. An attacker with many IP addresses could push a victim's per-JID entry out of the cache and so exceed 3 reset emails/hour to the victim's mailbox (email bombing). This doesn't enable takeover. | Low | Not mitigated beyond per-IP limits (about 410 IPs needed to fill the cache within an hour). Possible improvement: per-JID limits in storage, or a global limit. |
| R6 | **Response timing differs.** After the eligibility checks, an eligible reset request does extra work before responding: a storage read, two or three storage writes, firing an event, and rendering and queuing an email. The page content is identical, but timing could distinguish eligible from ineligible requests in principle, particularly with SQL storage. `mod_recovery_email_reset`'s README calls this "one storage write", which understates it. | Low | Not mitigated. Possible improvement: defer token creation and email to a timer so all requests return after the same work; correct the README. |
| R7 | **Validators disagree.** `mod_recovery_email` accepts and stores addresses containing `<` or `>` (e.g. `a<b@example.org`), which `mod_smtp_async` refuses to send to. Such an address can never be verified. | Low (fails closed, no injection) | Found while writing this report. Fix: reject `<` and `>` in `validate()` (and arguably other characters outside RFC 5322's unquoted local part). |
| R8 | **The SMTP queue is unbounded and volatile.** `mod_smtp_async` queues messages in memory without a size cap, and loses them on restart. Volume is bounded indirectly by the callers' rate limits. | Low | Accepted (documented). Possible improvement: a queue size cap; a persistent queue was deferred. |
| R9 | **Anyone can trigger reset emails for any JID** (up to 3/hour per JID, more under R5). The email tells recipients to ignore it if unexpected. | Low (nuisance) | Accepted; no CAPTCHA (out of scope). |
| R10 | **Weak default password policy:** only a minimum of 8 characters, unless `mod_password_policy` is loaded. | Low–Medium (deployment-dependent) | Documented; admins can load `mod_password_policy`. |
| R11 | **Some authentication backends** (e.g. LDAP) don't report account creation times, so a record can't be tied to a specific account; accounts deleted outside Prosody leave records that a re-created account would inherit. | Medium for such deployments | Documented in `mod_recovery_email`'s README (admins should `recovery clear` when removing accounts externally). |
| R12 | **HTTPS isn't enforced** for reset links; only a startup warning is logged. | Low (misconfiguration) | Documented; warning at startup. |
| R13 | **The reset token is in the URL**, so it can end up in browser history and in reverse proxy logs. | Low | Single use, 1-hour lifetime, `no-referrer`, `no-store`. |
| R14 | **Verifying an address you don't control:** a user (or session holder) can try about 40 codes/hour (8 codes × 5 attempts), roughly 1 in 25,000 per hour of verifying an address without receiving its email. The only effect is a verified address the account owner doesn't control, which harms only that account. | Info | Accepted. |
| R15 | **Internationalized domains** aren't normalized (`ü.example` ≠ `xn--tda.example`), and local-part case is kept, so the same mailbox can be stored in different forms. | Info | Documented. |
| R16 | **Subjects may contain control characters other than CR/LF** (`mod_smtp_async` only rejects CR and LF in subjects). Subjects come from admin-configured templates plus the JID, which can't contain control characters. | Info | Possible hardening: reject all control characters in subjects. |
| R17 | **Test and dev code is insecure on purpose.** `test/plugins/mod_test_recovery_codes.lua` delivers codes over XMPP, defeating email verification; dev configs use plain SMTP/HTTP. | Info | Kept under `test/` and `dev/`, not as top-level `mod_*` directories; must never be deployed. |

## 7. Security testing performed

Automated (all passing on `master` at `a8587ab`):

- **Unit tests (busted), 124 total:** 60 for `mod_recovery_email`, 12 for
  `mod_recovery_email_notify`, 20 for `mod_recovery_email_reset`, 32 for
  `mod_smtp_async`. Security-relevant coverage includes: address
  validation (control characters, Unicode spaces, invalid UTF-8,
  lengths); code uniformity, hashing, expiry, attempt limits and
  cancellation; that codes and tokens are never stored or logged;
  cooling-off cases including remove-then-add; stale-record handling;
  identical responses for eligible and ineligible reset requests; XSS
  escaping on the reset pages; security headers and CORS; token
  single-use, replacement, expiry, and binding to the current address
  and enabled account; password rules; SMTP header and command injection
  attempts; STARTTLS absence; auth refused without TLS; handshake
  failures treated as permanent; no server text, passwords or content in
  logs.
- **Mutation checks:** for several controls, the protecting code was
  temporarily disabled to confirm a test fails (role-based permission vs.
  host-only check; code verification; remove-then-add cooling-off; token
  binding to the current address).
- **Scansion (XMPP) tests:** access control for remote and anonymous
  users, the verification flow, attempt exhaustion; on internal and SQL
  storage.
- **SMTP integration tests** (`test/run-smtp.sh`, 27 checks, against
  Mailpit with a throwaway CA): STARTTLS with login, implicit TLS,
  refusal of a certificate for the wrong name and of an untrusted CA,
  end-to-end verification and notices, the full web reset flow on a host
  with real password storage (new password works, old doesn't, link
  can't be reused, unknown accounts get the same answer), and log checks
  for codes, tokens, passwords and full addresses. Passes with internal
  and SQL storage.

Manual: three checklists run by the project owner in Gajim, a browser and
Mailpit (phases 1–3), including Gajim being signed out by a reset.

Not performed: fuzzing, load/DoS testing, timing measurements (R6),
review by a third party, testing behind a real reverse proxy, testing
with external authentication backends.

## 8. Suggested review focus

1. Whether the identical-response claim (4.5) holds for every code path
   in `handle_request()`, including storage errors and rate limits, and
   how measurable the timing difference (R6) is.
2. The cooling-off state machine (`replaces_verified()`, `verify()`,
   `clear()`): are there sequences of set/verify/clear/resend that avoid
   the delay when it's enabled?
3. Token handling in `mod_recovery_email_reset`: lookup, expiry, the
   two-store design (`tokens`, `pending`), and races between concurrent
   requests for the same user.
4. `mod_smtp_async`'s SMTP state machine and certificate checks,
   especially the STARTTLS path (`listeners.onstatus`) and implicit TLS
   (`listeners.onconnect`).
5. Whether R3 needs more than documentation, and whether R7 and R16
   should be fixed before wider deployment.
6. Anything this document claims that the code doesn't do.

## 9. References

- Code: `mod_recovery_email/`, `mod_recovery_email_notify/`,
  `mod_recovery_email_reset/`, `mod_smtp_async/` (each with `README.md`,
  `docs/PLAN.md` where present, and `spec/`).
- Tests: `test/run-scansion.sh`, `test/run-smtp.sh`, `test/prosody.cfg.lua`,
  `mod_*/spec/`.
- Upstream bug: `docs/upstream/server-epoll-connection-timeout.md`.
- Prosody 13 behaviors relied on: `core/usermanager.lua`
  (`set_password`, `user_is_enabled`), `plugins/mod_c2s.lua` (sessions
  closed on `user-password-changed`), `plugins/mod_tokenauth.lua` (grants
  invalidated after a password change), `plugins/mod_http.lua`
  (`request.ip`, `trusted_proxies`, `http_url`, CORS defaults),
  `core/stanza_router.lua` (debug logs only top tags).

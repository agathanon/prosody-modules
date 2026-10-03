# Plan: Non-blocking SMTP sending

Oct 3, 2026

## Overview and scope

Build `mod_smtp_async`, a generic module that sends plain-text email over SMTP without blocking Prosody's event loop, and exposes a small API to other modules. Its first user is `mod_recovery_email_notify`, but it knows nothing about recovery email and is meant to be reusable.

Existing community modules that send email (`mod_email`, `mod_email_pass`) use LuaSocket's SMTP client or run `sendmail`; both block the whole server until the mail is handed off, which our conventions forbid. This module implements the SMTP client conversation itself on top of Prosody's own networking.

**In scope:**

- Submission to one configured mail server (a relay or submission service), with STARTTLS or implicit TLS, certificate verification, and username/password authentication.
- Plain-text UTF-8 messages to a single recipient.
- Retrying temporary failures, in memory.
- An API that returns a promise, for use from any module.

**Out of scope:**

- Delivering directly to recipients' mail servers (MX lookup). Always go through the configured server.
- HTML, attachments, multiple recipients per message, CC/BCC.
- A persistent outgoing queue: messages waiting for a retry are lost if Prosody restarts.
- Replacing `mod_email`'s `module:send_email()`. That API is synchronous and `mod_email` refuses to share it, so this module has its own.

## Environment and constraints

- Prosody 13.0.x, Lua 5.4, Prosody APIs only; no LuaSocket SMTP, no `io.popen`, no `os.execute`.
- Built from: `net.connect` with `net.resolvers.basic` (outgoing connection and DNS), the connection object's `starttls()` (STARTTLS), `core.certmanager.create_context` (TLS settings), `util.x509.verify_identity` and the connection's peer verification (certificate checks, as `net.http` does them), `util.promise` (the API), `util.timer` (timeouts and retry delays), `util.encodings.base64`, `util.datetime`, `util.id`.
- Loaded per VirtualHost, with options inherited from the global section as usual, so one global configuration serves all hosts.

## API

Exposed as module globals, used via `module:depends("smtp_async")`:

| Function | Returns | Behavior |
| --- | --- | --- |
| `send(message)` | A promise | Resolves with `true` once the server accepts the message, or rejects with an error object (`util.error`) once it's refused or retries are used up |

`message` fields:

| Field | Required | Notes |
| --- | --- | --- |
| `to` | Yes | One address |
| `subject` | Yes | UTF-8 |
| `body` | Yes | UTF-8 plain text |
| `from` | No | Defaults to `smtp_async_from` |
| `headers` | No | Extra headers, e.g. `Reply-To`; names must be valid header names |

Every string is checked for CR and LF before use, so a value can't inject extra headers or SMTP commands.

## Configuration

| Option | Default | Purpose |
| --- | --- | --- |
| `smtp_async_server` | `"localhost"` | Mail server hostname |
| `smtp_async_port` | `587` with `starttls`, `465` with `tls`, `25` with `none` | Port |
| `smtp_async_tls` | `"starttls"` | `"starttls"` (required, not opportunistic), `"tls"` (implicit TLS), or `"none"` (only sensible for a relay on the same machine) |
| `smtp_async_username` / `smtp_async_password` | None | Credentials. Authentication is refused unless the connection is encrypted |
| `smtp_async_from` | `noreply@` + the VirtualHost name | Default `From` address |
| `smtp_async_helo` | The VirtualHost name | Name sent in `EHLO` |
| `smtp_async_cafile` | System default | CA bundle for verifying the server, e.g. for a private CA |
| `smtp_async_verify_certificate` | `true` | Set `false` only for testing against a self-signed server |
| `smtp_async_timeout` | `"30s"` | Limit for each step of the conversation |
| `smtp_async_retries` | `3` | Retries after temporary failures, at 1, 5 and 15 minutes |

Passwords never appear in logs; the module logs a warning at startup if credentials are configured with `smtp_async_tls = "none"`, and refuses to use them.

## SMTP conversation

One connection per message, with a small cap on simultaneous connections (default 4); extra messages wait in an in-memory queue.

1. Connect (with implicit TLS if configured) and read the `220` greeting.
2. `EHLO`, and read the server's capabilities.
3. With `starttls`: send `STARTTLS`, upgrade the connection, check the certificate against `smtp_async_server`, then `EHLO` again. If the server doesn't offer STARTTLS, fail; never fall back to plain text.
4. If credentials are configured: `AUTH PLAIN` (and `AUTH LOGIN` if PLAIN isn't offered).
5. `MAIL FROM`, `RCPT TO`, `DATA`, the message, `.`; then `QUIT`.

Every reply is parsed, including multi-line replies. `2xx`/`3xx` continue, `4xx` is a temporary failure (retried), `5xx` is permanent (rejected immediately). A timeout or dropped connection counts as temporary.

**Message format** (RFC 5322 / MIME):

- Headers: `Date`, `From`, `To`, `Subject`, `Message-ID` (random, at `smtp_async_helo`), `MIME-Version: 1.0`, `Content-Type: text/plain; charset=utf-8`, `Content-Transfer-Encoding: base64`, then any extra headers.
- Non-ASCII subjects are encoded as RFC 2047 encoded-words; the body is base64, so no 8-bit support is needed from the server.
- Addresses with non-ASCII characters need the server's `SMTPUTF8` extension; without it, sending fails with a clear error rather than mangling the address.
- Lines end in CRLF, and the body is base64, which also avoids the need for dot-stuffing.

## Logging

- Each send: `info` on success and `warn` on failure, with the masked recipient (`j***@example.org`), the server's reply code, and the attempt number.
- Protocol traffic at `debug`, with the `AUTH` exchange redacted and message content omitted.

## Testing and acceptance criteria

The pure parts are written as plain functions in the module so they can be unit tested outside Prosody, as in `mod_recovery_email`.

**Automated:**

- [ ] `luacheck` clean.
- [ ] Unit tests: reply parsing (single and multi-line), the conversation as a state machine driven by a fake connection (success, `4xx` retry, `5xx` rejection, missing STARTTLS, auth refused without TLS), message formatting (headers, encoded-word subjects, base64 body, `Message-ID`), CR/LF rejection, and option defaults.
- [ ] Integration: the test environment gains a mail-catching SMTP server (Mailpit is the likely choice, with STARTTLS and authentication enabled; to be confirmed during implementation). The runner checks delivered messages through its HTTP API.

**Manual:**

- [ ] The dev `docker-compose.yml` gains the same mail catcher, with a web UI on a local port, so emails sent during Gajim testing can be read.
- [ ] Sending succeeds with STARTTLS and with implicit TLS; a server without STARTTLS is refused; a wrong certificate name is refused unless verification is turned off.
- [ ] Stopping the mail server produces retries, then a failure, without delaying any other Prosody activity.
- [ ] Logs never contain passwords, message bodies or full addresses.

## Reference material

- Prosody 13 source: `net/connect.lua`, `net/resolvers/basic.lua`, `net/http.lua` (TLS context and certificate checks for an outgoing client), `net/server_epoll.lua` (`starttls`, `ssl_peerverification`), `core/certmanager.lua`, `util/promise.lua`, `util/x509.lua`.
- prosody-modules: `mod_email` and `mod_email_pass`, for what not to do (blocking) and for how existing modules expect to send mail.
- RFC 5321 (SMTP), RFC 3207 (STARTTLS), RFC 4954 and RFC 4616 (AUTH and PLAIN), RFC 5322 (message format), RFC 2045 (MIME), RFC 2047 (encoded-words), RFC 6531 (SMTPUTF8), RFC 8314 (implicit TLS for submission).

---
labels:
- 'Stage-Alpha'
summary: 'Send email over SMTP without blocking Prosody'
...

Introduction
============

This module lets other modules send plain-text email through an SMTP
server, without blocking Prosody while the mail is handed off. It does
not send anything by itself; it provides an API for modules that need
to send email, such as [mod_recovery_email_notify].

Other modules that send email, such as [mod_email], use LuaSocket's SMTP
client or run `sendmail`, which stop the whole server until the mail has
been handed over. This module talks SMTP using Prosody's own networking
instead.

Mail is always submitted to one configured server (your mail provider's
submission service, or a relay), never directly to recipients' servers.

Configuration
=============

  Option                            Default                          Description
  --------------------------------- -------------------------------- ------------------------------------------------------------------------
  `smtp_async_server`               `"localhost"`                    Mail server hostname
  `smtp_async_port`                 587, 465 or 25 (see below)       Port
  `smtp_async_tls`                  `"starttls"`                     `"starttls"`, `"tls"` (implicit TLS) or `"none"`
  `smtp_async_username`             none                             Username for authentication
  `smtp_async_password`             none                             Password for authentication
  `smtp_async_from`                 `"noreply@"` + the host          Default sender address
  `smtp_async_helo`                 the host                         Name sent in `EHLO`
  `smtp_async_cafile`               system default                   File of CA certificates to trust for the mail server, e.g. a private CA
  `smtp_async_verify_certificate`   `true`                           Whether to verify the mail server's certificate
  `smtp_async_timeout`              `"30s"`                          How long to wait for each step of the conversation
  `smtp_async_retries`              `3`                              How many times to retry temporary failures, after 1, 5 and 15 minutes

The default port depends on `smtp_async_tls`: 587 for `"starttls"`, 465
for `"tls"`, and 25 for `"none"`.

A typical setup, using a mail provider's submission service:

```lua
smtp_async_server = "smtp.example.net"
smtp_async_username = "prosody@example.com"
smtp_async_password = "..."
smtp_async_from = "noreply@example.com"
```

Options can be set globally or per VirtualHost.

Security
--------

-   With `"starttls"`, the server must offer STARTTLS; the module never
    falls back to an unencrypted connection.
-   The server's certificate is checked against `smtp_async_server`.
    Only turn this off with `smtp_async_verify_certificate = false` for
    testing.
-   Credentials are never sent without TLS: if a username is configured
    with `smtp_async_tls = "none"`, the module logs an error and every
    send fails.
-   Logs show recipients masked (`j***@example.org`), and never contain
    passwords or message content.

API
===

``` lua
local smtp = module:depends("smtp_async");

smtp.send({
    to = "user@example.org";
    subject = "Hello";
    body = "Plain text, UTF-8.";
}):next(function ()
    module:log("info", "Email accepted by the mail server");
end, function (err)
    module:log("warn", "Email failed: %s", err.text);
end);
```

`send(message)` returns a promise. It resolves with `true` once the mail
server accepts the message, and rejects with an error object if the
message is invalid, the server refuses it, or all retries fail.

  Field       Required   Description
  ----------- ---------- --------------------------------------------------------
  `to`        Yes        One recipient address
  `subject`   Yes        Subject, UTF-8
  `body`      Yes        Plain-text body, UTF-8
  `from`      No         Sender address; defaults to `smtp_async_from`
  `headers`   No         Table of extra headers, e.g. `{ ["Reply-To"] = "..." }`

Values containing line breaks are rejected, so they can't be used to add
headers or SMTP commands.

Limitations
===========

-   One recipient per message, and plain text only: no HTML or
    attachments.
-   Messages waiting to be retried are kept in memory and are lost if
    Prosody restarts or the module is reloaded.
-   Addresses with non-ASCII characters can only be sent if the mail
    server supports SMTPUTF8.
-   At most 4 connections to the mail server at a time; further messages
    wait their turn.

Compatibility
=============

  Prosody Version   Status
  ----------------- ---------------------------------------------
  13.0              Works
  0.12              Untested

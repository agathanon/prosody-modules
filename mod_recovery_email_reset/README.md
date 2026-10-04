---
labels:
- 'Stage-Alpha'
summary: 'Reset a forgotten password through the recovery email address'
...

Introduction
============

This module lets users who have forgotten their password reset it
through the recovery email address they verified with
[mod_recovery_email]:

1.  On a web page, they enter their chat address (JID).
2.  If the account has a verified recovery address, a single-use link is
    emailed to it.
3.  The link opens a page where they choose a new password.

The request page always gives the same answer, so it can't be used to
find out which accounts exist or have a recovery address. When the
password is changed, Prosody signs out all of the user's devices and
invalidates older app tokens, and a confirmation is emailed to the
recovery address.

The pages are plain HTML with no JavaScript or external resources.

Usage
=====

```lua
VirtualHost "example.com"
    modules_enabled = {
        "recovery_email";
        "recovery_email_notify";
        "recovery_email_reset";
    }

-- Plus mod_smtp_async's settings, see its README
```

[mod_recovery_email_notify] sends the emails (through [mod_smtp_async]);
without it, links are created but never sent. [mod_recovery_email] and
Prosody's HTTP server (mod_http) are loaded automatically.

The pages are served at `/recovery_email_reset` on Prosody's HTTP server,
e.g. `https://example.com:5281/recovery_email_reset`. Link to this page
from your website or login help. The path can be changed with Prosody's
`http_paths` option:

```lua
http_paths = {
    recovery_email_reset = "/reset-password";
}
```

Prosody must be reachable over **HTTPS** at the address used in the
links, which it takes from `http_external_url` if set (typically when
Prosody is behind a reverse proxy). The module logs a warning if the
links would use plain HTTP. See Prosody's HTTP documentation
for setting up HTTPS and reverse proxies:
https://prosody.im/doc/http

Behind a reverse proxy, also set `trusted_proxies` so that the per-IP
rate limits see visitors' real addresses rather than the proxy's.
Otherwise all visitors share the proxy's address, and so a single
per-IP limit, which can make the reset page unusable for everyone. The
module logs a warning when requests carry `X-Forwarded-For` from an
address that isn't in `trusted_proxies`.

Configuration
=============

  Option                                       Default                   Description
  -------------------------------------------- ------------------------- ------------------------------------------------------
  `recovery_email_reset_link_lifetime`         `"1 hour"`                How long a reset link stays valid
  `recovery_email_reset_requests_per_jid`      `3`                       Reset requests per account per hour
  `recovery_email_reset_requests_per_ip`       `10`                      Requests, and password submissions, per IP (IPv6: per /64) per hour
  `recovery_email_reset_min_password_length`   `8`                       Minimum length of the new password
  `recovery_email_reset_site_name`             the host                  Name shown on the pages
  `recovery_email_reset_template_path`         built-in templates        Directory with replacement page templates

If [mod_password_policy] is loaded on the host, new passwords must also
satisfy its rules.

To change the pages' look or wording, copy the `html/` directory from
this module, edit the copies, and point
`recovery_email_reset_template_path` at it. `layout.html` wraps every
page; `request.html`, `reset.html` and `message.html` are the contents.

The cooling-off period for recently replaced addresses is configured in
[mod_recovery_email] (`recovery_email_reset_delay`).

Security
========

-   Reset links contain a long random token, are stored only as a hash,
    can be used once, and expire after an hour. A new request replaces
    the previous link, and so does changing the password any other way.
-   A link stops working if the account's recovery address changes or the
    account is disabled after it was sent.
-   Opening a link only shows the form; nothing changes until the form is
    submitted, so email security scanners that open links can't use them
    up.
-   Pages send headers that forbid scripts, framing and other sites'
    access (CORS), and stop the link from leaking through the `Referer`
    header.
-   Requests are rate limited per account and per IP address. IPv6
    addresses are limited per /64, since one client usually controls a
    whole /64. Requests for unknown accounts count the same as for real
    ones.

Logging
=======

The module logs, at `info` level, when a link is sent and when a password
is reset (with the username only). Refused requests are logged at
`debug` level with the reason. It never logs tokens, links, passwords or
full email addresses.

Limitations
===========

-   **Debug logs contain reset links.** Prosody's HTTP server logs every
    request's path at `debug` level, and the reset token is part of the
    path. On a server logging at `debug` level, anyone who can read the
    logs while a link is valid could use it. Links are single-use and
    expire after an hour, so a token in an old log is useless.
-   **Rate limits are kept in memory.** They reset when the module is
    reloaded or Prosody restarts.
-   **Pages are in English.** They can be translated by replacing the
    templates (see above).
-   **Response timing.** The request page answers the same way for every
    account, but an eligible request does more work before answering:
    creating and storing the link, and preparing and queuing the email.
    Someone measuring response times precisely, particularly with SQL
    storage, could in principle tell eligible requests from others.

Compatibility
=============

  Prosody Version   Status
  ----------------- ---------------------------------------------
  13.0              Works
  0.12              Does not work (requires mod_recovery_email)

Tested with Prosody's internal (file) storage and SQL storage (SQLite3).

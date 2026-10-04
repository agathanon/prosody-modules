---
labels:
- 'Stage-Alpha'
summary: 'Send the emails for mod_recovery_email'
---

Introduction
============

This module sends the emails that [mod_recovery_email] calls for:

-   **Verification code:** when a user saves a new recovery address, the
    code they need to verify it.
-   **Address changed:** when a verified address is replaced, a notice
    to the old address.
-   **Address removed:** when a verified address is removed, a notice to
    that address.
-   **Password reset link:** when a password reset is requested through
    [mod_recovery_email_reset], the single-use link, to the verified
    address.
-   **Password was reset:** after a reset, a confirmation to the
    verified address, so its owner learns if someone else did it.

The notices let the owner of an address find out if someone else changed
their account's recovery address. They only go to addresses that were
verified, so the module can't be used to send email to addresses that
were merely typed in. They name the account and the time of the change,
but not the new address.

Email is sent with [mod_smtp_async], which must be configured with your
mail server.

Usage
=====

```lua
-- mod_smtp_async settings (see its README), e.g. in the global section:
smtp_async_server = "smtp.example.net"
smtp_async_username = "prosody@example.com"
smtp_async_password = "..."
smtp_async_from = "noreply@example.com"   -- an address the account may send as

VirtualHost "example.com"
    modules_enabled = { "recovery_email", "recovery_email_notify" }
```

[mod_recovery_email] and [mod_smtp_async] are loaded automatically.
Emails are sent from `smtp_async_from` unless `recovery_email_from` is
set.

Configuration
=============

| Option | Default | Description |
| --- | --- | --- |
| `recovery_email_from` | `smtp_async_from` | Sender address of the emails, if different from mod_smtp_async's |
| `recovery_email_messages` | built-in English texts | Subjects and bodies to use instead (see below) |

If Prosody's `contact_info` option has an `admin` entry (as used by
mod_server_contact_info), the notices tell the reader to contact those
addresses if the change wasn't theirs. Otherwise they say to contact the
administrator of the host.

Changing the messages
---------------------

`recovery_email_messages` can replace the subject or body of any of the
emails, for example to translate them:

```lua
recovery_email_messages = {
    verification = {
        subject = "Ihr Bestätigungscode für {jid}";
        body = [[
Ihr Bestätigungscode lautet: {code}

Er ist gültig bis {expires}.
]];
    };
}
```

The keys are `verification`, `replaced`, `removed`, `reset` and
`reset_done`, each with an optional `subject` and `body`; anything not
given keeps its built-in text. Messages are plain text. These
placeholders are filled in:

| Placeholder | Value |
| --- | --- |
| `{jid}` | The account, e.g. `user@example.com` |
| `{host}` | The host, e.g. `example.com` |
| `{code}` | The verification code (`verification` only) |
| `{url}` | The password reset link (`reset` only) |
| `{expires}` | When the code or link expires, in UTC (`verification` and `reset` only) |
| `{changed_by}` | "from the account" or "by a server administrator" (`replaced` and `removed` only) |
| `{time}` | When the change or reset happened, in UTC (`replaced`, `removed` and `reset_done` only) |
| `{contact}` | The admin contact addresses from `contact_info`, if any |

`{contact&text}` shows `text` only when a contact is configured, and
`{contact~text}` only when it isn't.

Logging
=======

Each email is logged with its type and the masked recipient (e.g.
`a***@example.org`). Codes, reset links and full addresses are never
logged.

Compatibility
=============

| Prosody Version | Status |
| --- | --- |
| 13.0 | Works |
| 0.12 | Does not work (requires mod_recovery_email) |

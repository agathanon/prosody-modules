---
labels:
- 'Stage-Alpha'
summary: 'Let users store a private recovery email address'
...

Introduction
============

This module lets each user store one optional recovery email address on
the server, and view, change or remove it through an
[ad-hoc command][XEP-0050] named "Recovery email". The address is kept in
the module's own private storage: it is never published via vCard, PEP or
any other protocol, and only the user and server admins can see it.

Users prove they control the address by entering a code that is emailed
to it. This module creates and checks the codes; it does not send email
itself. [mod_recovery_email_notify] sends the codes and change notices,
using [mod_smtp_async].

This is part of a self-service password reset feature:
[mod_recovery_email_reset] lets users who have forgotten their password
reset it through their verified address. Other modules can build on this
module through its API and events, described below.

Usage
=====

Add the module to `modules_enabled` on a VirtualHost:

```lua
VirtualHost "example.com"
    modules_enabled = { "recovery_email", "recovery_email_notify" }
```

Without [mod_recovery_email_notify] (or another module that handles the
`recovery-email-verification-requested` event), codes are created but
never sent, so no address can be verified.

Users will find "Recovery email" in their client's list of server
commands (e.g. in Gajim or Cheogram). The form shows the current address
and lets the user enter a new one or tick "Remove my recovery email".

Verification
------------

Saving a new address stores it as unverified and emails a 6-digit code
to it. While the address is unverified, the form also shows a
"Verification code" field and a "Send a new code" option. Entering the
code marks the address as verified.

-   Codes are valid for 24 hours by default, and are cancelled after 5
    wrong attempts. Spaces and hyphens in the code are ignored.
-   A new code replaces the previous one. Users can request at most 3
    new codes in a burst, after which one more becomes available every
    20 minutes.
-   Changing the address starts verification again for the new address.
-   Codes are stored only as salted hashes, and are never logged.

Addresses are trimmed, checked for basic validity (one `@`, a domain with
a dot, no spaces or control characters, at most 254 bytes) and stored with
the domain lowercased. Each user can make at most 5 changes in a burst,
after which one more change becomes available every 12 minutes.

When an account is deleted, its record is removed with it. A record is
also tied to the account's creation time where the authentication
backend reports one (e.g. `internal_hashed`), so it never carries over to
a new account that reuses the same username.

Configuration
=============

  Option                           Default        Description
  -------------------------------- -------------- ------------------------------------------------------------------
  `recovery_email_code_lifetime`   `"24 hours"`   How long a verification code stays valid
  `recovery_email_reset_delay`     `0` (off)      Cooling-off period before a replacement address can be used for resets

Cooling-off period
------------------

Changing the address doesn't require the account's password, so someone
with brief access to a logged-in session could replace a verified
address with their own. The previous address is warned by
[mod_recovery_email_notify], and `recovery_email_reset_delay` can add a
second line of defense: an address that took the place of a verified one
can't be used for password resets until the delay has passed after it is
verified.

```lua
recovery_email_reset_delay = "7 days"
```

The delay applies when the new address replaced a verified address
(directly, or through unverified addresses in between), or was set within
the delay after a verified address was removed, so removing and re-adding
can't be used to skip it. It doesn't apply to a user's first address, or
to one that replaced an address that was never verified.

Access to the command is controlled by the `adhoc:recovery-email`
permission, which is granted to `prosody:registered` by default. Anonymous
(`prosody:guest`) users and users of other hosts cannot see or use the
command.

Administration
==============

Admins can manage records with `prosodyctl shell`:

```sh
prosodyctl shell recovery show user@example.com
prosodyctl shell recovery set user@example.com someone@example.org
prosodyctl shell recovery clear user@example.com
```

Inside an interactive shell, use `recovery:show("user@example.com")`
and so on.

Addresses set from the shell are validated and stored as `unverified`,
like any other change, and a verification code is sent to them; the user
enters it in the ad-hoc command. The shell is not rate limited, and
changes made from it are marked "(via shell)" in the log. `show` also
reports whether a code is pending (but never shows the code), and whether
the address can be used for password resets.

Server logs only ever show masked addresses (e.g. `s***@example.org`).

API
===

Other modules can use `module:depends("recovery_email")` to access these
functions. All of them take the local username on the current host.

  Function                                 Returns
  ---------------------------------------- ---------------------------------------------------------------
  `get(username)`                          The record table, or `nil`
  `set(username, email, source)`           `true, "changed"` or `true, "unchanged"`; `nil, code, message` on error
  `clear(username, source)`                `true, "removed"` or `true, "absent"`; `nil, code, message` on error
  `verify(username, code)`                 `true, "verified"`; `nil, code, message` on error
  `resend_verification(username, source)`  `true`; `nil, code, message` on error
  `get_reset_address(username)`            The address to use for a password reset, or `nil, reason`
  `validate(email)`                        The normalized address, or `nil, message`

When `set()` returns `"changed"`, verification has started and a
verification email has been requested. `verify()` fails with
`not-acceptable` for a wrong code (the message says how many attempts
remain), `resource-constraint` when the code has expired or used up its
attempts, `conflict` when the address is already verified, and
`item-not-found` when there is no address.

`get_reset_address()` returns the address only if it is verified and
outside any cooling-off period. Otherwise the reason is `"none"` (no
address), `"unverified"`, `"cooling-off"` (with the time it ends as a
third value), or `"error"` if storage failed. It doesn't check whether
the account is enabled.

`source` is optional: a short label such as `"shell"` that is added to
the log line for the change, e.g. "(via shell)". Changes made by users
through the ad-hoc command have none.

A record has the fields `version`, `email`, `status` (`"unverified"` or
`"verified"`), `created_at`, `updated_at`, `account_created` and
`verified_at`, plus `verify_token_hash`, `verify_expires` and
`verify_attempts` while a code is pending, and `replaced_verified` and
`reset_allowed_after` for the cooling-off period.

The module fires these events on the host:

  Event                                     Payload
  ----------------------------------------- ----------------------------------------------------------------------
  `recovery-email-set`                      `username`, `host`, `email`, `previous_email`, `previous_status`, `source`
  `recovery-email-cleared`                  `username`, `host`, `previous_email`, `previous_status`, `source`
  `recovery-email-verification-requested`   `username`, `host`, `email`, `code`, `expires`
  `recovery-email-verified`                 `username`, `host`, `email`

`recovery-email-set` fires only when the address actually changes, and
is followed by `recovery-email-verification-requested`. Neither
`recovery-email-set` nor `recovery-email-cleared` fires when a record is
removed because the account was deleted.

`recovery-email-verification-requested` carries the code itself: handlers
must never log or store it.

Limitations
===========

-   **Authentication backends without account metadata.** Records are
    tied to an account through the account's creation time, which only
    some authentication backends report (`internal_hashed` does). With
    others, such as LDAP, a record can't be told apart from one left by
    an earlier account with the same username. If accounts are deleted
    outside Prosody, for example directly in LDAP, Prosody never learns
    of the deletion, so the record remains and applies to any new
    account created with that username. Clear such records with
    `prosodyctl shell recovery clear` when removing accounts.
-   **Deletion relies on Prosody's cleanup.** When an account is
    deleted, Prosody removes all of the user's stored data, and this
    module also removes its record. If the module is not loaded at that
    moment and the storage backend can't remove all user data, the
    record is left behind; the creation-time check above then hides it
    from a new account where the backend supports that.
-   **Rate limits are kept in memory.** They reset when the module is
    reloaded or Prosody restarts, and are kept for up to 1024 users at a
    time; beyond that, the oldest entries are dropped and those users'
    limits reset.
-   **Address validation is basic.** It checks the form of the address
    only: it does not check that the domain exists or accepts email,
    does not support quoted local parts (`"john doe"@example.org`), and
    does not convert internationalized domain names, so `ü.example` and
    `xn--tda.example` count as different addresses.
-   **Changing the address doesn't require the password.** Someone with
    brief access to a logged-in session could set and verify their own
    address. [mod_recovery_email_notify] warns the previous verified
    address when this happens, and the optional cooling-off period (see
    above) delays when the new address can be used for resets.
-   **A 6-digit code is only as safe as its limits.** Someone who can read
    the server's storage could find a pending code from its hash; the
    24-hour lifetime and 5-attempt limit are what protect codes in normal
    use.

Compatibility
=============

  Prosody Version   Status
  ----------------- ---------------------------------------------
  13.0              Works
  0.12              Does not work (requires the roles framework)

Tested with Prosody's internal (file) storage and SQL storage
(SQLite3).

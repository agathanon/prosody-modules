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

This is the storage part of a self-service password reset feature. The
module itself does not send email, verify addresses, or reset passwords;
every address is stored with status `unverified`. Other modules can build
on it through its API and events, described below.

Usage
=====

Add the module to `modules_enabled` on a VirtualHost:

```lua
VirtualHost "example.com"
    modules_enabled = { "recovery_email" }
```

Users will find "Recovery email" in their client's list of server
commands (e.g. in Gajim or Cheogram). The form shows the current address
and lets the user enter a new one or tick "Remove my recovery email".

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

There are no configuration options.

Access to the command is controlled by the `adhoc:recovery-email`
permission, which is granted to `prosody:registered` by default. Anonymous
(`prosody:guest`) users and users of other hosts cannot see or use the
command.

Administration
==============

Admins can manage records with `prosodyctl shell`:

```sh
prosodyctl shell recovery_email show user@example.com
prosodyctl shell recovery_email set user@example.com someone@example.org
prosodyctl shell recovery_email clear user@example.com
```

Inside an interactive shell, use `recovery_email:show("user@example.com")`
and so on.

Addresses set from the shell are validated and stored as `unverified`,
like any other change. The shell is not rate limited.

Server logs only ever show masked addresses (e.g. `s***@example.org`).

API
===

Other modules can use `module:depends("recovery_email")` to access these
functions. All of them take the local username on the current host.

  Function                 Returns
  ------------------------ ---------------------------------------------------------------
  `get(username)`          The record table, or `nil`
  `set(username, email)`   `true, "changed"` or `true, "unchanged"`; `nil, code, message` on error
  `clear(username)`        `true, "removed"` or `true, "absent"`; `nil, code, message` on error
  `validate(email)`        The normalized address, or `nil, message`

A record has the fields `version`, `email`, `status` (`"unverified"` or
`"verified"`), `created_at`, `updated_at` and `account_created`. The
fields `verified_at`, `verify_token_hash` and `verify_expires` are
reserved for address verification.

The module fires these events on the host:

  Event                      Payload
  -------------------------- ------------------------------------------------
  `recovery-email-set`       `username`, `host`, `email`, `previous_email`
  `recovery-email-cleared`   `username`, `host`, `previous_email`

`recovery-email-set` fires only when the address actually changes.
Neither event fires when a record is removed because the account was
deleted.

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
    `prosodyctl shell recovery_email clear` when removing accounts.
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
-   **Addresses are not verified.** Every address is stored as
    `unverified`; nothing confirms that the user controls it.

Compatibility
=============

  Prosody Version   Status
  ----------------- ---------------------------------------------
  13.0              Works
  0.12              Does not work (requires the roles framework)

Tested with Prosody's internal (file) storage and SQL storage
(SQLite3).

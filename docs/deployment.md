# Deploying the recovery email modules from a Git checkout

This guide deploys `mod_recovery_email`, `mod_recovery_email_notify`,
`mod_recovery_email_reset` and `mod_smtp_async` on a production Prosody
by pointing Prosody at a checkout of this repository. (Installing them as
packages with `prosodyctl install` isn't set up yet.)

The examples use these placeholders; substitute your own:

| Placeholder | Meaning |
| --- | --- |
| `example.com` | Your XMPP domain (the `VirtualHost`) |
| `chat.example.com` | The public web hostname for the reset page |
| `smtp.example.net` | Your mail provider's SMTP server |
| `noreply@example.com` | The address emails are sent from |

It assumes Prosody 13.0.x from packages.prosody.im on Debian or Ubuntu,
with config in `/etc/prosody/`, data in `/var/lib/prosody/` and logs in
`/var/log/prosody/`. Adjust paths for other systems.

## 1. What you get

- Users find **"Recovery email"** in their client's server commands, add
  an address, and verify it with an emailed code.
- A **reset page** at `https://chat.example.com/recovery_email_reset`
  lets people who forgot their password get a reset link at their
  verified address.
- When a verified address is changed or removed, the old address is
  **emailed a notice**.

## 2. Prerequisites

- **Prosody 13.0.x**, running, with valid TLS certificates for your
  domain.
- **`git`** on the server.
- **An SMTP account** for sending: port 465 with implicit TLS, or port
  587 with STARTTLS, and a username and password. Set up SPF, DKIM and
  DMARC for the sending domain, or the emails will land in spam.
- **HTTPS for the reset page**: a reverse proxy you already run (nginx,
  Caddy, Apache), or Prosody serving HTTPS itself. See
  [step 6](#6-make-the-reset-page-reachable-over-https).
- Optional: the community module **`mod_password_policy`**, for stronger
  password rules on resets (otherwise the only rule is a minimum of 8
  characters).

## 3. Get the code

Put the checkout somewhere stable, outside Prosody's data directory, and
pin it to a known commit or tag:

```sh
sudo git clone https://github.com/agathanon/prosody-modules.git /opt/prosody-modules-custom
cd /opt/prosody-modules-custom
sudo git checkout master        # or, better, a release tag (see step 10)
sudo chown -R root:root /opt/prosody-modules-custom
sudo chmod -R a+rX /opt/prosody-modules-custom
```

Prosody only needs to read these files, so they're owned by root:
Prosody can't modify its own code.

Prosody only looks for modules at the top level of each plugin path
(`mod_name.lua` or `mod_name/mod_name.lua`), so the test-only module in
`test/plugins/` can't be loaded by accident. **Never add `test/plugins`
or `dev/` to `plugin_paths`**: the test module bypasses email
verification, and the dev configs are insecure by design.

## 4. Store the SMTP password outside the main config

```sh
sudo sh -c 'printf "%s" "YOUR-SMTP-PASSWORD" > /etc/prosody/smtp-password'
sudo chown root:prosody /etc/prosody/smtp-password
sudo chmod 640 /etc/prosody/smtp-password
```

The config reads it with `FileLine("smtp-password")`, which returns the
file's first line, relative to the config directory. Don't use
`FileContents()` for this: it keeps any trailing newline, which would
break the SMTP login. (With systemd credentials, Prosody 13's
`Credential("name")` also works.)

## 5. Configure Prosody

Edit `/etc/prosody/prosody.cfg.lua`.

### Global section

Above the first `VirtualHost`:

```lua
-- Where the custom modules live
plugin_paths = { "/opt/prosody-modules-custom" }

-- Sending email (mod_smtp_async); these can also go under a VirtualHost
smtp_async_server = "smtp.example.net"
smtp_async_tls = "tls"                 -- implicit TLS; the port defaults to 465
smtp_async_username = "noreply@example.com"
smtp_async_password = FileLine("smtp-password")
smtp_async_from = "noreply@example.com"

-- Shown in the "address changed/removed" and "password reset" emails
contact_info = {
    admin = { "mailto:admin@example.com", "xmpp:admin@example.com" };
}

-- Only if your reverse proxy is NOT on the same machine (the default
-- already trusts 127.0.0.1 and ::1):
-- trusted_proxies = { "127.0.0.1", "::1", "10.0.0.5" }
```

For a mail server on port 587 with STARTTLS instead, use
`smtp_async_tls = "starttls"` (the default; the port then defaults to
587). Use `smtp_async_tls = "none"` only for a relay on the same machine,
and never with a username and password: the module refuses to send
credentials without TLS.

### Your VirtualHost

Add the three modules to the host's existing `modules_enabled` list (or
the global one if you have a single host). Add them to the existing list
rather than writing a second `modules_enabled` line, which would replace
the first.

```lua
VirtualHost "example.com"
    modules_enabled = {
        -- ...whatever is already here...
        "recovery_email";          -- the address and the "Recovery email" command
        "recovery_email_notify";   -- writes the emails (loads mod_smtp_async)
        "recovery_email_reset";    -- the reset web pages (loads mod_http)
    }

    -- Recommended: an address that replaced a verified one can't be used
    -- for resets for 7 days (off by default; see step 11)
    recovery_email_reset_delay = "7 days"

    -- Web address of the reset page (see step 6)
    http_host = "chat.example.com"
    http_external_url = "https://chat.example.com/"

    -- Optional
    recovery_email_from = "noreply@example.com"
    recovery_email_reset_site_name = "Example Chat"
```

`mod_smtp_async`, `mod_http` and `mod_cron` are loaded automatically as
dependencies. Everything else, such as code and link lifetimes, rate
limits, password length, page templates and email wording, has defaults
documented in each module's README.

## 6. Make the reset page reachable over HTTPS

Choose one option.

### Option A: reverse proxy (recommended)

Prosody serves plain HTTP on `127.0.0.1:5280` (loopback only, by
default) and your web server adds HTTPS. For nginx:

```nginx
server {
    listen 443 ssl;
    server_name chat.example.com;
    # ssl_certificate / ssl_certificate_key as for your other sites

    location /recovery_email_reset {
        proxy_pass http://127.0.0.1:5280;
        proxy_set_header Host chat.example.com;      # must equal http_host
        proxy_set_header X-Forwarded-For $remote_addr;
        proxy_set_header X-Forwarded-Proto https;
    }
}
```

- **`Host` must match `http_host`.** Prosody chooses the virtual host from
  it, and a mismatch gives a 404.
- **`X-Forwarded-For` must be set**, and the proxy must be in
  `trusted_proxies`. Otherwise every visitor appears to come from the
  proxy and shares one rate limit (10 requests an hour for everyone).
  The module logs a warning when it detects this.
- Setting `X-Forwarded-For` to `$remote_addr`, rather than appending to
  it, stops visitors from adding fake entries of their own.

### Option B: Prosody serves HTTPS itself

Leave out `http_host` and `http_external_url`. Users visit
`https://example.com:5281/recovery_email_reset`, and Prosody uses its
certificate for `example.com`. This is simpler, but the address includes
a port number, and port 5281 must be open in your firewall.

Either way, the module logs a warning at startup if reset links would use
plain `http://`.

## 7. Check and restart

```sh
sudo prosodyctl check config
sudo systemctl restart prosody      # simplest way to load newly enabled modules
sudo tail -n 50 /var/log/prosody/prosody.log
```

In the log, look for:

- `Serving 'recovery_email_reset' at https://chat.example.com/recovery_email_reset`,
  showing the public HTTPS address.
- **No** `Configuration problem, all email will fail` from `smtp_async`,
  which means a setting is wrong (e.g. a username without a password, or
  credentials with `smtp_async_tls = "none"`).
- **No** `Password reset links will use plain HTTP`.

## 8. Verify it works

With a test account (or your own):

```sh
sudo prosodyctl adduser test@example.com
```

- [ ] **Recovery email command:** "Recovery email" appears in your
  client's server commands. Save your real address; the code email
  arrives (check the sender, and that it isn't in spam). Enter the code:
  "Recovery email verified."
- [ ] **Shell:**
  `sudo prosodyctl shell recovery show test@example.com` shows
  `Status: verified` and `Reset: usable` (or "usable from …" during the
  cooling-off period).
- [ ] **Reset page:** `https://chat.example.com/recovery_email_reset`
  shows the form. Enter `test@example.com`: the reset email arrives; the
  link opens the new-password page; setting a password signs the test
  account out of your client and sends a confirmation email.
- [ ] **Unknown accounts:** entering a made-up account shows the same
  "Check your email" page.
- [ ] **Logs:**
  `sudo grep -E "recovery_email|smtp_async" /var/log/prosody/prosody.log`
  shows only masked addresses (`t***@…`), and no codes or links.

To test sending on its own:

```sh
sudo prosodyctl shell "> require'prosody.core.modulemanager'.get_module('example.com', 'smtp_async').send({ to = 'you@example.org'; subject = 'Test from Prosody'; body = 'It works.' }); return 'sent'"
```

Then look for `Sent email … to y***@example.org` in the log, or an
error explaining why not.

## 9. Tell your users

- To add an address, open the server's commands in their XMPP client (in
  Gajim: the account menu, **Execute Command…**, then the server) and
  choose **Recovery email**, then enter the code from the email.
- Link the reset page from your website or login help.
- Only a verified address can be used for password resets.

## 10. Running it

### Upgrading

Once the repository has release tags, pin to them:

```sh
cd /opt/prosody-modules-custom
sudo git fetch --tags
sudo git log --oneline HEAD..v2     # review what changed
sudo git checkout v2
```

Then reload without disconnecting users:

```sh
sudo prosodyctl shell module reload recovery_email example.com
```

Modules that depend on the reloaded one are reloaded with it. Restarting
Prosody at a quiet time also works. Check the commits or READMEs for new
options first.

### Rolling back

`git checkout` the previous tag, then reload or restart.

### Backups

Records are kept in Prosody's normal storage, in the stores
`recovery_email`, `recovery_email_removed`,
`recovery_email_reset_tokens` and `recovery_email_reset_pending`. Back up
`/var/lib/prosody` (or your SQL database) as usual. Only
`recovery_email` matters long-term; the others hold short-lived data.

### Monitoring

Watch the log for:

- `Unable to send`: an email failed, with the reason.
- `Configuration problem`: `mod_smtp_async` is misconfigured.
- `certificate`: TLS problems with the mail server.
- The `X-Forwarded-For` warning about `trusted_proxies`.

### Disabling

Remove the modules from `modules_enabled` and restart. The data stays in
storage, so enabling them again restores users' addresses without
re-verification.

## 11. Security checklist

From [`docs/security-controls.md`](security-controls.md):

- [ ] **HTTPS** for the reset page, and no plain-HTTP warning in the log.
- [ ] **`trusted_proxies`** set correctly if your proxy is on another
  machine, and `X-Forwarded-For` set by the proxy.
- [ ] **`recovery_email_reset_delay`** set (e.g. `"7 days"`). Without it,
  someone who briefly gets into a user's logged-in client can swap in
  their own address and reset the password right away. The owner is
  emailed either way, but the delay gives them time to react.
- [ ] **No `debug` logging in production.** Prosody's own debug logging
  records reset links. Also leave `mod_stanza_debug` unloaded: it would
  log codes and addresses.
- [ ] **`smtp_async_verify_certificate`** left at its default (`true`),
  and **`smtp_async_tls`** never `"none"` for a remote server.
- [ ] **SMTP password file** readable only by root and the prosody group.
- [ ] **No `test/` or `dev/` paths** in `plugin_paths`.
- [ ] Optional: **`mod_password_policy`** loaded for stronger passwords.
- [ ] With an **external authentication backend (e.g. LDAP)**, read
  risk R11 in the security report: records can outlive accounts deleted
  outside Prosody, and resets may not invalidate app tokens.

## 12. Troubleshooting

| Symptom | Likely cause |
| --- | --- |
| Reset page gives 404 | The `Host` header from the proxy doesn't match `http_host`, or the path isn't proxied. Check the `Serving 'recovery_email_reset' at …` log line. |
| Everyone gets "Too many requests" | The proxy isn't in `trusted_proxies` or doesn't set `X-Forwarded-For` (look for the warning). Rate limits also reset on restart. |
| No email after a reset request | The page deliberately doesn't say why. Check `recovery show`: the address must be `verified` and `usable`, and the account enabled. The `debug` log gives the reason if you enable it briefly. |
| `Configuration problem, all email will fail` | `smtp_async_username` without a password (or the reverse), credentials with `smtp_async_tls = "none"`, or a TLS context error. |
| `timed out in state greeting` | Probably `smtp_async_tls = "starttls"` (or `"none"`) against an implicit-TLS port such as 465: the server waits for a TLS handshake while Prosody waits for its greeting. Use `smtp_async_tls = "tls"`. |
| `server does not offer STARTTLS` | The server doesn't support STARTTLS on that port. If your provider uses implicit TLS (port 465), set `smtp_async_tls = "tls"`. |
| `TLS handshake failed` | `smtp_async_tls = "tls"` against a STARTTLS port such as 587 (use `"starttls"`), or the server's certificate isn't trusted (for a private CA, set `smtp_async_cafile`). |
| `certificate does not match` | `smtp_async_server` must be the name on the mail server's certificate, not an IP address or alias. |
| `failed (attempt 1) … retrying in 60s` | The mail server is unreachable or busy. Retries happen after 1, 5 and 15 minutes; queued emails are lost on restart. |
| Emails land in spam | SPF, DKIM and DMARC for the sender's domain, at your mail provider. |
| "Recovery email" isn't in the client's command list | The module isn't enabled on that host, or the user is anonymous or on another server. |

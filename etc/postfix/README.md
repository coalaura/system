# Postfix

This directory configures Postfix for:

- receiving Internet mail on TCP/25;
- TLS-only authenticated message submission on TCP/587;
- virtual mailboxes for `example.com`;
- recipient validation through `virtual_mailbox`;
- Dovecot SMTP AUTH;
- delivery to Dovecot via LMTP;
- DKIM signing through OpenDKIM for authenticated submission;
- rejection of unknown virtual recipients during SMTP delivery.

This setup does not use Unix users, `/etc/passwd`, local delivery, or Procmail for mail addressed to `example.com`.

## Requirements

- Dovecot configured with:
  - SMTP AUTH socket: `/var/spool/postfix/private/auth`
  - LMTP socket: `/var/spool/postfix/private/dovecot-lmtp`
- OpenDKIM configured with:
  - Unix socket: `/var/spool/postfix/opendkim/opendkim.sock`
- A valid certificate for `mail.example.com`.
- DNS records and PTR/rDNS configured before production use.

Install Postfix:

```bash
sudo apt update
sudo apt install postfix
```

During package setup, choose a normal Internet-site configuration. The repository configuration replaces the relevant defaults.

## Install configuration files

Install:

```text
/etc/postfix/main.cf
/etc/postfix/master.cf
/etc/postfix/virtual_mailbox
/etc/postfix/sender_login
```

Replace all placeholders before deployment:

```text
example.com
mail.example.com
203.0.113.10
```

Do not commit generated `.db` files. They are generated from the source maps with `postmap`.

## Required `main.cf` design

The active configuration must have these properties.

### Server identity

```cf
myhostname = mail.example.com
myorigin = /etc/mailname
inet_interfaces = all
```

`/etc/mailname` should contain:

```text
example.com
```

### Virtual mailbox domain

Do not put `example.com` in `mydestination`.

Use virtual mailbox delivery:

```cf
mydestination = $myhostname, localhost.localdomain, localhost

virtual_mailbox_domains = example.com
virtual_mailbox_maps = hash:/etc/postfix/virtual_mailbox
virtual_transport = lmtp:unix:private/dovecot-lmtp
```

Do not configure:

```cf
mailbox_command = procmail -a "$EXTENSION"
```

Do not use `mailbox_transport`, `home_mailbox`, or local Unix delivery for the virtual domain.

### SMTP AUTH through Dovecot

```cf
smtpd_sasl_auth_enable = yes
smtpd_sasl_type = dovecot
smtpd_sasl_path = private/auth
smtpd_sasl_security_options = noanonymous
smtpd_tls_auth_only = yes
```

### Relay protection

```cf
mynetworks = 127.0.0.0/8, [::1]/128

smtpd_relay_restrictions =
    permit_mynetworks,
    permit_sasl_authenticated,
    reject_unauth_destination
```

Do not put the server's public IP address in `mynetworks` unless there is a specific trusted-proxy/NAT reason.

### TLS

Port 25 should use opportunistic TLS for Internet compatibility:

```cf
smtpd_tls_cert_file = /etc/letsencrypt/live/mail.example.com/fullchain.pem
smtpd_tls_key_file = /etc/letsencrypt/live/mail.example.com/privkey.pem
smtpd_tls_security_level = may
smtpd_tls_mandatory_protocols = >=TLSv1.2
```

Port 587 is made mandatory-TLS in `master.cf`.

### OpenDKIM integration

Do not attach OpenDKIM globally to public SMTP/25:

```cf
smtpd_milters =
```

Authenticated submission gets its own milter configuration in `master.cf`.

For mail injected locally using `/usr/sbin/sendmail`, use this only if all local processes are trusted:

```cf
non_smtpd_milters = unix:opendkim/opendkim.sock
```

If no local service sends mail through the Postfix sendmail interface, leave it empty:

```cf
non_smtpd_milters =
```

## Virtual recipient map

`virtual_mailbox` is the authoritative Postfix recipient list.

Example `/etc/postfix/virtual_mailbox`:

```text
noreply@example.com OK
err@example.com     OK
```

It must contain only complete valid email addresses.

After every change:

```bash
sudo postmap /etc/postfix/virtual_mailbox
sudo chown root:postfix \
  /etc/postfix/virtual_mailbox \
  /etc/postfix/virtual_mailbox.db
sudo chmod 0640 \
  /etc/postfix/virtual_mailbox \
  /etc/postfix/virtual_mailbox.db
sudo systemctl reload postfix
```

Test it:

```bash
sudo postmap -q noreply@example.com hash:/etc/postfix/virtual_mailbox
sudo postmap -q invalid@example.com hash:/etc/postfix/virtual_mailbox
```

Expected result:

- valid user: `OK`;
- invalid user: no output.

This map prevents Postfix from accepting mail for unknown recipients and generating backscatter later.

## Sender/login map

`sender_login` binds each authenticated account to its allowed SMTP envelope sender.

Example `/etc/postfix/sender_login`:

```text
noreply@example.com noreply@example.com
err@example.com     err@example.com
```

Build it:

```bash
sudo postmap /etc/postfix/sender_login
sudo chown root:postfix \
  /etc/postfix/sender_login \
  /etc/postfix/sender_login.db
sudo chmod 0640 \
  /etc/postfix/sender_login \
  /etc/postfix/sender_login.db
```

The submission service uses:

```cf
-o smtpd_sender_login_maps=hash:/etc/postfix/sender_login
-o smtpd_sender_restrictions=reject_sender_login_mismatch
```

This validates SMTP `MAIL FROM`, not the visible `From:` header. Applications should send matching envelope and visible sender addresses.

## Required submission service

The active `submission` service in `/etc/postfix/master.cf` must contain:

```cf
submission inet n       -       y       -       -       smtpd
  -o syslog_name=postfix/submission
  -o smtpd_tls_security_level=encrypt
  -o smtpd_sasl_auth_enable=yes
  -o smtpd_relay_restrictions=permit_sasl_authenticated,reject
  -o smtpd_sender_login_maps=hash:/etc/postfix/sender_login
  -o smtpd_sender_restrictions=reject_sender_login_mismatch
  -o smtpd_milters=unix:opendkim/opendkim.sock
  -o milter_default_action=tempfail
```

Meaning:

- TCP/587 requires TLS.
- TCP/587 requires SMTP AUTH before mail can be submitted.
- OpenDKIM signs accepted submission mail.
- If OpenDKIM is unavailable, submission fails temporarily instead of accepting unsigned mail.

Do not expose TCP/465 unless explicitly configuring implicit-TLS submission as a separate service.

## Start and validate

```bash
sudo postfix check
sudo postconf -n
sudo systemctl enable --now postfix
sudo systemctl reload postfix
```

Verify important effective settings:

```bash
sudo postconf -h virtual_mailbox_domains
sudo postconf -h virtual_mailbox_maps
sudo postconf -h virtual_transport
sudo postconf -h smtpd_milters
sudo postconf -P | grep '^submission/inet/'
```

Expected important values:

```text
virtual_transport = lmtp:unix:private/dovecot-lmtp
smtpd_milters =
submission/inet/smtpd_milters = unix:opendkim/opendkim.sock
submission/inet/milter_default_action = tempfail
submission/inet/smtpd_tls_security_level = encrypt
submission/inet/smtpd_sasl_auth_enable = yes
```

Follow logs while testing:

```bash
sudo journalctl -fu postfix
```

On Debian/Ubuntu systems also check:

```bash
sudo tail -f /var/log/mail.log
```

## Firewall

Allow:

```text
TCP/25   SMTP receiving
TCP/587  authenticated SMTP submission
```

Do not allow TCP/465 unless it has been configured intentionally.

## DNS requirements

Before production use, configure:

```text
mail.example.com A     -> server IPv4 address
example.com      MX    -> mail.example.com
server IP PTR         -> mail.example.com
```

The forward and reverse DNS relationship must match:

```text
mail.example.com -> server IP
server IP        -> mail.example.com
```

Also configure SPF, DKIM, and DMARC. The OpenDKIM directory documents DKIM setup.
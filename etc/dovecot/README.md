# Dovecot

This directory configures Dovecot for:

- virtual mail users only;
- password authentication through `/etc/dovecot/users`;
- Maildir storage under `/var/mail/vhosts`;
- IMAPS only on TCP/993;
- Postfix SMTP AUTH through Dovecot;
- Postfix-to-Dovecot delivery through LMTP.

This setup does not use Unix users as mail accounts.

## Requirements

- Debian or Ubuntu system.
- A public hostname such as `mail.example.com`.
- A valid TLS certificate for `mail.example.com`.
- Postfix configured to use:
  - SMTP AUTH socket: `private/auth`
  - LMTP socket: `private/dovecot-lmtp`

Install the required packages:

```bash
sudo apt update
sudo apt install dovecot-core dovecot-imapd dovecot-lmtpd
```

## Install the configuration

Copy `conf.d/99-local-mailserver.conf` to:

```text
/etc/dovecot/conf.d/99-local-mailserver.conf
```

Replace this placeholder everywhere in that file:

```text
mail.example.com
```

with the actual public hostname, for example:

```text
mail.example.com
```

The file is loaded after the standard `10-*.conf` files and overrides their relevant defaults.

## Disable other authentication databases

Dovecot must have only the passwd-file `passdb` and static `userdb` from `99-local-mailserver.conf`.

In `/etc/dovecot/conf.d/10-auth.conf`:

- remove or comment any existing active `passdb { ... }` block;
- remove or comment any existing active `userdb { ... }` block;
- ensure that these include lines remain commented:

```text
#!include auth-system.conf.ext
#!include auth-sql.conf.ext
#!include auth-ldap.conf.ext
#!include auth-passwdfile.conf.ext
```

Do not enable PAM, system-user, SQL, LDAP, or another passwd-file backend unless intentionally changing this design.

## Create the virtual-mail service account

`vmail` is a Unix service account that owns mailbox files. It is not a login account and is not an email user.

```bash
getent group vmail >/dev/null || sudo groupadd --system vmail

id -u vmail >/dev/null 2>&1 || sudo useradd \
  --system \
  --gid vmail \
  --home-dir /var/mail/vhosts \
  --shell /usr/sbin/nologin \
  vmail
```

Create the mail-storage root and the domain directory:

```bash
sudo install -d -o root -g vmail -m 0750 /var/mail/vhosts
sudo install -d -o vmail -g vmail -m 0750 /var/mail/vhosts/example.com
```

Replace `example.com` with the hosted mail domain.

When adding an account, create its home directory before accepting mail for it:

```bash
sudo install -d \
  -o vmail \
  -g vmail \
  -m 0700 \
  /var/mail/vhosts/example.com/noreply
```

Dovecot/LMTP creates the `Maildir` directory inside the account directory when mail is first delivered.

## Create the password file

Copy the template:

```bash
sudo install \
  -o root \
  -g dovecot \
  -m 0640 \
  etc/dovecot/users.example \
  /etc/dovecot/users
```

The production file must be:

```text
/etc/dovecot/users
owner: root:dovecot
mode:  0640
```

Dovecot's auth process must be able to read password hashes. Do not set this file to `root:root 0600`.

Generate a password hash interactively:

```bash
sudo doveadm pw -l
sudo doveadm pw -s ARGON2ID
```

Use `ARGON2ID` when the installed Dovecot build supports it. Otherwise use a supported strong scheme such as `SHA512-CRYPT`.

Use full lowercase addresses in `/etc/dovecot/users`:

```text
noreply@example.com:{ARGON2ID}<generated-hash>
err@example.com:{ARGON2ID}<generated-hash>
```

Do not commit the real `/etc/dovecot/users` file to Git.

## TLS certificate

The local config expects Let's Encrypt files at:

```text
/etc/letsencrypt/live/mail.example.com/fullchain.pem
/etc/letsencrypt/live/mail.example.com/privkey.pem
```

Obtain the certificate before starting Dovecot:

```bash
sudo certbot certonly --standalone -d mail.example.com
```

Use a different Certbot method if Nginx or another web server already owns TCP/80.

After certificate renewal, reload Dovecot:

```bash
sudo systemctl reload dovecot
```

## Start and validate

```bash
sudo doveconf -n
sudo systemctl enable --now dovecot
sudo systemctl restart dovecot
sudo systemctl --no-pager status dovecot
```

Validate a known account:

```bash
sudo doveadm user noreply@example.com
```

Expected fields include:

```text
uid   vmail
gid   vmail
home  /var/mail/vhosts/example.com/noreply
```

Test authentication without placing a password in shell history:

```bash
sudo doveadm auth test noreply@example.com
```

Test IMAPS from another host:

```bash
openssl s_client -connect mail.example.com:993 -servername mail.example.com
```

The certificate must be valid, and port 143 should not be listening.

## Firewall

Allow IMAPS:

```text
TCP/993
```

Do not expose Dovecot's LMTP socket or authentication socket to the network. They are Unix sockets for local Postfix use only.

## Adding an email account

For `newuser@example.com`:

1. Create the mail home:

   ```bash
   sudo install -d \
     -o vmail \
     -g vmail \
     -m 0700 \
     /var/mail/vhosts/example.com/newuser
   ```

2. Generate a password hash:

   ```bash
   sudo doveadm pw -s ARGON2ID
   ```

3. Add the full address and generated hash to `/etc/dovecot/users`.

4. Add `newuser@example.com OK` to Postfix's `virtual_mailbox` map.

5. Rebuild the Postfix map:

   ```bash
   sudo postmap /etc/postfix/virtual_mailbox
   sudo systemctl reload postfix
   ```

6. Reload Dovecot:

   ```bash
   sudo systemctl reload dovecot
   ```

The Dovecot password file and Postfix virtual-recipient map must stay synchronized.
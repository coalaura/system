# OpenDKIM

This directory configures OpenDKIM to sign mail from `example.com`.

The intended security model is:

- Postfix does not attach OpenDKIM globally to public SMTP/25.
- Postfix attaches OpenDKIM only to authenticated submission on TCP/587.
- Postfix optionally sends locally injected mail through OpenDKIM.
- OpenDKIM considers all sources internal because it receives only trusted,
  authenticated submission or trusted local injection.
- Untrusted Internet mail received on TCP/25 is not sent to OpenDKIM and is
  therefore never signed by this server.

Do not change `InternalHosts` to an all-hosts configuration while also attaching
OpenDKIM globally through `smtpd_milters`. Doing so could cause the server to
DKIM-sign forged inbound mail.

## Requirements

- Postfix configured with:

  ```cf
  smtpd_milters =
  ```

- Postfix `submission` service configured with:

  ```cf
  -o smtpd_milters=unix:opendkim/opendkim.sock
  -o milter_default_action=tempfail
  ```

- A public DNS zone for `example.com`.

Install packages:

```bash
sudo apt update
sudo apt install opendkim opendkim-tools
```

## Install configuration files

Install:

```text
/etc/opendkim.conf
/etc/opendkim/KeyTable
/etc/opendkim/SigningTable
/etc/opendkim/TrustedHosts
/etc/opendkim/InternalHosts
```

Replace:

```text
example.com
mail.example.com
```

with the actual domain and mail hostname.

## Milter socket

OpenDKIM uses a Unix socket inside Postfix's chroot:

```text
/var/spool/postfix/opendkim/opendkim.sock
```

Create the socket directory:

```bash
sudo install -d \
  -o opendkim \
  -g opendkim \
  -m 0750 \
  /var/spool/postfix/opendkim
```

Allow Postfix to connect to the socket:

```bash
sudo usermod -aG opendkim postfix
sudo systemctl restart postfix
```

OpenDKIM should use:

```cf
UserID opendkim
UMask 007
Socket local:/var/spool/postfix/opendkim/opendkim.sock
```

Postfix refers to that socket from within its chroot as:

```cf
unix:opendkim/opendkim.sock
```

Do not use a publicly accessible TCP milter listener.

## Internal and external host lists

`TrustedHosts` is used as the external-ignore list and should remain narrow:

```text
127.0.0.1
::1
localhost
```

`InternalHosts` should contain:

```text
127.0.0.1
::1
0.0.0.0/0
::/0
```

The broad `InternalHosts` list is safe only because OpenDKIM is attached only
to authenticated TCP/587 submission and optional trusted local injection.

It is not safe if OpenDKIM is also attached to public SMTP/25.

## Signing and key tables

Use `refile:` for the signing table so wildcard entries work.

In `/etc/opendkim.conf`:

```cf
KeyTable                /etc/opendkim/KeyTable
SigningTable            refile:/etc/opendkim/SigningTable
ExternalIgnoreList      /etc/opendkim/TrustedHosts
InternalHosts           /etc/opendkim/InternalHosts
```

Example `SigningTable`:

```text
*@example.com default._domainkey.example.com
```

Example `KeyTable`:

```text
default._domainkey.example.com example.com:default:/etc/opendkim/keys/example.com/default.private
```

The selector is `default`, so the published DNS name is:

```text
default._domainkey.example.com
```

## Generate a DKIM key

Create a domain-specific key directory:

```bash
sudo install -d \
  -o root \
  -g opendkim \
  -m 0750 \
  /etc/opendkim/keys/example.com
```

Generate a 2048-bit RSA key:

```bash
sudo opendkim-genkey \
  -b 2048 \
  -D /etc/opendkim/keys/example.com \
  -d example.com \
  -s default
```

This creates:

```text
/etc/opendkim/keys/example.com/default.private
/etc/opendkim/keys/example.com/default.txt
```

## Secure the private key

The Postfix user belongs to the `opendkim` group so it can access the milter
socket. Therefore the DKIM private key must not be group-readable by
`opendkim`.

Use these permissions:

```bash
sudo chown root:opendkim /etc/opendkim/keys
sudo chmod 0750 /etc/opendkim/keys

sudo chown root:opendkim /etc/opendkim/keys/example.com
sudo chmod 0750 /etc/opendkim/keys/example.com

sudo chown opendkim:root /etc/opendkim/keys/example.com/default.private
sudo chmod 0600 /etc/opendkim/keys/example.com/default.private
```

Expected key ownership:

```text
-rw------- opendkim root ... /etc/opendkim/keys/example.com/default.private
```

Verify access:

```bash
sudo -u opendkim test -r /etc/opendkim/keys/example.com/default.private \
  && echo "OpenDKIM can read the key"

sudo -u postfix test -r /etc/opendkim/keys/example.com/default.private \
  && echo "ERROR: Postfix can read the key" \
  || echo "Good: Postfix cannot read the key"
```

Never commit `default.private` to Git.

## Publish the DNS record

Display the generated public DKIM DNS record:

```bash
sudo cat /etc/opendkim/keys/example.com/default.txt
```

Publish it as a TXT record for:

```text
default._domainkey.example.com
```

The value contains the public key and is safe to publish.

After DNS propagation, validate it:

```bash
sudo opendkim-testkey -d example.com -s default -vvv
```

A DNS failure can cause receiving providers to report `dkim=fail` or
`dkim=permerror`. A message with `dkim=none` usually means OpenDKIM did not
add a signature at all.

## Start and validate

```bash
sudo opendkim -n -x /etc/opendkim.conf
sudo systemctl enable --now opendkim
sudo systemctl restart opendkim
sudo systemctl --no-pager --full status opendkim
```

Watch logs during a submission test:

```bash
sudo journalctl -fu opendkim
```

For temporary troubleshooting, enable:

```cf
LogWhy yes
```

A successful submission should produce a log similar to:

```text
DKIM-Signature field added (s=default, d=example.com)
```

The delivered message should contain:

```text
DKIM-Signature: v=1; ... d=example.com; s=default; ...
```

The receiving provider should report:

```text
dkim=pass header.d=example.com
```

## Test fail-closed submission

Postfix submission should not accept unsigned mail if OpenDKIM is unavailable.

Stop OpenDKIM:

```bash
sudo systemctl stop opendkim
```

Submit a test message through TCP/587. It should fail temporarily rather than
be accepted and queued.

Restore OpenDKIM:

```bash
sudo systemctl start opendkim
```

If submission succeeds while OpenDKIM is stopped, verify:

```bash
sudo postconf -P | grep '^submission/inet/'
```

Required effective settings include:

```text
submission/inet/smtpd_milters = unix:opendkim/opendkim.sock
submission/inet/milter_default_action = tempfail
```
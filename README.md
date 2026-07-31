# system

Common, optimized, opinionated linux system/server configurations.

## Structure

```text
├── build-nginx.sh
└── etc/
    ├── dovecot/
    │   ├── README.md
    │   ├── users.example
    │   └── conf.d/
    │       └── 99-mailserver.conf
    ├── nginx/
    │   ├── mime.types
    │   ├── nginx.conf # for dedicated
    │   ├── nginx.vps.conf # for small VPS
    │   └── wall.conf
    ├── opendkim/
    │   ├── README.md
    │   ├── InternalHosts
    │   ├── KeyTable
    │   ├── SigningTable
    │   └── TrustedHosts
    ├── postfix/
    │   ├── README.md
    │   ├── main.cf
    │   ├── master.cf
    │   ├── sender_login
    │   └── virtual_mailbox
    ├── ssh/
    │   └── sshd_config
    ├── unbound/
    │   ├── unbound.conf
    │   └── unbound.conf.d/
    │       ├── dot.conf
    │       ├── remote-control.conf
    │       └── root-auto-trust-anchor-file.conf
    ├── update-motd.d/
    │   ├── 00-welcome
    │   ├── 10-sysinfo
    │   ├── 20-updates
    │   └── 98-reboot-required
    ├── mailname
    └── opendkim.conf
```

## Notes

- Nginx is self-compiled with PQ, HTTP/3 and `headers-more-nginx-module` support; see [build-nginx.sh](build-nginx.sh).
- MOTD scripts must be executable: `chmod +x`.
- Test SSH configuration before restarting: `sshd -t`.
- Mail configuration uses Postfix, Dovecot, and OpenDKIM with virtual Maildir users, TLS-only SMTP submission, Dovecot LMTP delivery and DKIM signing. See the service-specific READMEs.

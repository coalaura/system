# system

Common Linux system configurations for my servers.

## Structure

```
etc/
├── nginx/
│   ├── mime.types
│   ├── nginx.conf
│   └── wall.conf
├── ssh/
│   └── sshd_config
└── update-motd.d/
    ├── 00-welcome
    ├── 10-sysinfo
    ├── 20-updates
    └── 98-reboot-required
```

## Notes

- nginx is self-compiled with PQ, HTTP/3 and headers-more-nginx-module support
- MOTD scripts must be executable (`chmod +x`)
- Test SSH config before restarting: `sshd -t`

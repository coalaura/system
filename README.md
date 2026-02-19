# system

Common, optimized, opinionated linux system/server configurations.

## Structure

```
├── build-nginx.sh
└── etc/
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

- nginx is self-compiled with PQ, HTTP/3 and headers-more-nginx-module support, see [build-nginx.sh](build-nginx.sh)
- MOTD scripts must be executable (`chmod +x`)
- Test SSH config before restarting: `sshd -t`

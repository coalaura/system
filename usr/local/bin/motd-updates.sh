#!/bin/sh
# Compute upgradable/security counts and write atomically to /var/cache/motd-updates
OUT="/var/cache/motd-updates"
TMP="${OUT}.$$.tmp"

# prefer apt-check if available (accurate "N;M"), fallback to apt list
if [ -x /usr/lib/update-notifier/apt-check ]; then
    out=$(/usr/lib/update-notifier/apt-check 2>/dev/null || true)
    upg=$(printf "%s" "$out" | cut -d';' -f1)
    sec=$(printf "%s" "$out" | cut -d';' -f2)
else
    upg=$(apt list --upgradable 2>/dev/null | awk 'NR>1{c++}END{print c+0}')
    sec=0
fi

# ensure numeric
upg=${upg:-0}; sec=${sec:-0}

printf "%d\n%d\n" "$upg" "$sec" >"$TMP" && mv "$TMP" "$OUT"
chmod 0644 "$OUT"

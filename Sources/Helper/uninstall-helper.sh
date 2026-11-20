#!/bin/sh
# Removes the Steady Wi-Fi helper (root, after the administrator prompt) and makes sure
# AirDrop's radio is back on if a pause was still active.
set -u
LABEL=io.github.mirage-pxplay.steady-wifi
ROOT="${MIRAGE_SYSTEM_ROOT:-}"
SHARED="$ROOT/Users/Shared/Mirage for PXPlay"
active=0
for request in "$SHARED/steady-wifi"/*.pid; do
    [ -e "$request" ] && active=1
done
if [ -z "$ROOT" ]; then
    /bin/launchctl bootout "system/$LABEL" 2>/dev/null || true
fi
/bin/rm -f "$ROOT/Library/LaunchDaemons/$LABEL.plist" "$ROOT/Library/PrivilegedHelperTools/$LABEL"
/bin/rm -rf "$SHARED"
if [ "$active" = 1 ] && [ -z "$ROOT" ]; then
    /sbin/ifconfig awdl0 up 2>/dev/null || true
fi
echo "Mirage Steady Wi-Fi helper removed."

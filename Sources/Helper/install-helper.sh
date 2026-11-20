#!/bin/sh
# Installs the Steady Wi-Fi helper. macOS runs this as root after the administrator
# password prompt (once). Copies a root-owned copy of steady-wifi.sh into
# /Library/PrivilegedHelperTools and a launchd job that runs it when PXPlay asks.
set -eu
LABEL=io.github.mirage-pxplay.steady-wifi
ROOT="${MIRAGE_SYSTEM_ROOT:-}"
HERE=$(cd "$(dirname "$0")" && pwd)
TOOL="$ROOT/Library/PrivilegedHelperTools/$LABEL"
PLIST="$ROOT/Library/LaunchDaemons/$LABEL.plist"
SHARED="$ROOT/Users/Shared/Mirage for PXPlay"

/bin/mkdir -p "$ROOT/Library/PrivilegedHelperTools" "$ROOT/Library/LaunchDaemons" "$SHARED/steady-wifi"
/bin/chmod 0755 "$SHARED"
# Every account on this Mac may ask for a pause; the sticky bit keeps requests apart.
/bin/chmod 1777 "$SHARED/steady-wifi"
/bin/cp "$HERE/steady-wifi.sh" "$TOOL.new"
/bin/chmod 0755 "$TOOL.new"
/bin/cat > "$PLIST.new" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>$LABEL</string>
    <key>ProgramArguments</key>
    <array>
        <string>/bin/sh</string>
        <string>$TOOL</string>
    </array>
    <key>WatchPaths</key>
    <array>
        <string>$SHARED/steady-wifi</string>
    </array>
    <key>RunAtLoad</key>
    <true/>
    <key>ThrottleInterval</key>
    <integer>2</integer>
</dict>
</plist>
EOF
/bin/chmod 0644 "$PLIST.new"
if [ "$(/usr/bin/id -u)" = 0 ]; then
    /usr/sbin/chown root:wheel "$TOOL.new" "$PLIST.new"
fi
/bin/mv -f "$TOOL.new" "$TOOL"
/bin/mv -f "$PLIST.new" "$PLIST"
if [ -z "$ROOT" ]; then
    /bin/launchctl bootout "system/$LABEL" 2>/dev/null || true
    /bin/launchctl bootstrap system "$PLIST"
fi
echo "Mirage Steady Wi-Fi helper installed."

#!/bin/sh
# Mirage Steady Wi-Fi helper. Runs as root from launchd whenever the request folder
# changes. While a PXPlay process that asked for it is alive, it keeps awdl0 (AirDrop,
# iPhone Mirroring, Sidecar) paused so the Wi-Fi radio stays on the network's channel.
# When the last request is gone it brings awdl0 back up if it paused it.
#
# A request is "<user>.pid" holding a process id. Only regular files are read, only
# digits are used, and the process must be a PXPlay executable. Nothing from the file
# is ever executed.

DIR="${MIRAGE_SYSTEM_ROOT:-}/Users/Shared/Mirage for PXPlay/steady-wifi"
IFCONFIG="${MIRAGE_IFCONFIG:-/sbin/ifconfig}"
TEST_PROCESS="${MIRAGE_TEST_PROCESS:-/nonexistent/process}"
paused=0

has_request() {
    result=1
    for request in "$DIR"/*.pid; do
        [ -f "$request" ] && [ ! -L "$request" ] || continue
        pid=$(/usr/bin/head -c 12 "$request" 2>/dev/null | /usr/bin/tr -cd '0-9')
        command=""
        [ -n "$pid" ] && command=$(/bin/ps -o comm= -p "$pid" 2>/dev/null)
        case "$command" in
            */Contents/MacOS/PXPlay|PXPlay|"$TEST_PROCESS") result=0 ;;
            *) /bin/rm -f "$request" ;;
        esac
    done
    return $result
}

awdl_up() {
    "$IFCONFIG" awdl0 2>/dev/null | /usr/bin/head -1 | /usr/bin/grep -q '<UP'
}

while has_request; do
    if awdl_up; then
        paused=1
        "$IFCONFIG" awdl0 down
    fi
    /bin/sleep 1
done
if [ "$paused" = 1 ]; then
    "$IFCONFIG" awdl0 up
fi
exit 0

#!/bin/bash
# Installer smoke test: detection, validation of good and bad apps (the same check the
# drag-and-drop zone and the Choose… panel use), install, launcher, uninstall.
# Everything goes into a scratch home (MIRAGE_TEST_HOME / MIRAGE_SYSTEM_ROOT); your real
# Mirage install, PXPlay settings and /Library are not touched.
#
#   Tests/smoke-test.sh          scripted checks only
#   Tests/smoke-test.sh --live   also starts the real PXPlay through the launcher, checks the
#                                agent loaded, then quits PXPlay (PXPlay must not be running)
set -euo pipefail
cd "$(dirname "$0")/.."
repo="$PWD"
installer="$repo/build/Mirage Installer.app/Contents/MacOS/Mirage Installer"
[ -x "$installer" ] || { echo "Build first: ./build.sh"; exit 1; }
full="${PXPLAY_APP:-/Applications/PXPlay.app}"
demo="${PXPLAY_DEMO_APP:-/Applications/PXPlay_Demo.app}"
work="$repo/build/smoke"
rm -rf "$work"
mkdir -p "$work/home/Library/Application Support/PXPlay/Data" "$work/system" "$work/apps"
export MIRAGE_TEST_HOME="$work/home" MIRAGE_SYSTEM_ROOT="$work/system" MIRAGE_LANGUAGE=en
pass() { printf '  \033[32mok\033[0m  %s\n' "$*"; }
fail() { printf '  \033[31mFAIL\033[0m %s\n' "$*"; exit 1; }

echo "Detection"
detected=$("$installer" --detect)
sed 's/^/      /' <<<"$detected"
grep -q "^READY	full	3.2.0	$full	" <<<"$detected" || fail "PXPlay 3.2.0 not detected at $full"
pass "finds PXPlay 3.2.0 (Launch Services, Spotlight, usual folders)"
if [ -d "$demo" ]; then
    grep -q "^READY	demo	3.2.0	$demo	" <<<"$detected" || fail "PXPlay Demo not detected"
    pass "finds PXPlay Demo 3.2.0"
fi
grep -q "/Contents/.*PXPlay.app" <<<"$detected" && fail "nested copies inside other apps must be skipped"
pass "skips PXPlay copies nested inside other apps"

echo "Validation (drag and drop / Choose…)"
"$installer" --validate "$full" >/dev/null || fail "good app refused"
pass "PXPlay 3.2.0 accepted"
[ -d "$demo" ] && { "$installer" --validate "$demo" >/dev/null || fail "demo refused"; pass "PXPlay Demo 3.2.0 accepted"; }
old="$work/apps/PXPlay.app"
mkdir -p "$old/Contents/Resources/Java" "$old/Contents/MacOS"
cp "$full/Contents/Info.plist" "$old/Contents/Info.plist"
plutil -replace CFBundleShortVersionString -string 3.1.4 "$old/Contents/Info.plist"
out=$("$installer" --validate "$old") && fail "old version accepted"
grep -q "Version 3.1.4 isn.*t supported" <<<"$out" || fail "wrong reason: $out"
pass "PXPlay 3.1.4 refused: $(cut -f5 <<<"$out")"
fake="$work/apps/Fake/PXPlay.app"
mkdir -p "$fake/Contents/Resources/Java" "$fake/Contents/MacOS"
cp "$full/Contents/Info.plist" "$fake/Contents/Info.plist"
cp /usr/bin/true "$fake/Contents/MacOS/PXPlay"
echo "not a jar" > "$fake/Contents/Resources/Java/PXPlay-3.2.0-runnable.jar"
out=$("$installer" --validate "$fake") && fail "modified copy accepted"
pass "copy that claims 3.2.0 but is not the signed original refused: $(cut -f5 <<<"$out")"
out=$("$installer" --validate /System/Applications/Calculator.app) && fail "other app accepted"
pass "another app refused: $(cut -f5 <<<"$out")"

echo "Install"
payload="$work/payload"
cp -R "$repo/build/Mirage Installer.app/Contents/Resources/Payload" "$payload"
xattr -w com.apple.quarantine "0081;00000000;Safari;" "$payload/lib/MirageAgent.dylib"
xattr -w com.apple.quarantine "0081;00000000;Safari;" "$payload/Apps/Mirage for PXPlay.app"
prefs="$work/home/Library/Application Support/PXPlay/Data/prefs.json"
printf '{"REMOTE_FPS":"HIGH","USE_HDR":"true","SELECTED_PSN_PROFILE_ACCOUNT_ID":"keep-me","STREAM_WINDOW_WIDTH":"900"}' > "$prefs"
args=(--install --full "$full" --style picture --pxplay-settings --wifi)
[ -d "$demo" ] && args+=(--demo "$demo")
MIRAGE_PAYLOAD="$payload" "$installer" "${args[@]}" | sed 's/^/      /'
support="$work/home/Library/Application Support/Mirage for PXPlay"
for item in lib/MirageAgent.dylib lib/libFGBackends.dylib Resources/Mirage.jar Resources/FG/rife-v4.25.rmw \
    Resources/FG/Turbo.metal Helper/install-helper.sh Licenses/THIRD-PARTY-NOTICES.md config.plist settings.properties; do
    [ -e "$support/$item" ] || fail "missing $item"
done
pass "payload installed to ~/Library/Application Support/Mirage for PXPlay"
[ -z "$(xattr -r "$support" "$work/home/Applications" 2>/dev/null | grep quarantine)" ] || fail "quarantine flag kept"
pass "quarantine flag dropped from installed files"
launcher="$work/home/Applications/Mirage for PXPlay.app"
codesign --verify --strict "$launcher" || fail "launcher signature"
[ "$(defaults read "$launcher/Contents/Info" CFBundleIdentifier)" = io.github.mirage-pxplay.launcher ] || fail "launcher id"
pass "launcher in ~/Applications, signature intact"
if [ -d "$demo" ]; then
    [ "$(defaults read "$work/home/Applications/Mirage for PXPlay Demo.app/Contents/Info" MirageTarget)" = demo ] || fail "demo launcher"
    pass "separate launcher for PXPlay Demo"
fi
grep -q "style=picture" "$support/settings.properties" && grep -q "steadyWifi=true" "$support/settings.properties" \
    && grep -q "wait=12" "$support/settings.properties" || fail "settings: $(cat "$support/settings.properties")"
pass "chosen style and Steady Wi-Fi written for the panel inside PXPlay"
python3 -I - "$prefs" <<'EOF' || fail "PXPlay settings"
import json, sys
p = json.load(open(sys.argv[1]))
assert p["VIDEO_RENDERING_FRAME_GENERATION"] == "ENABLED" and p["REMOTE_VIDEO_RENDERING_TYPE_NEW"] == "METAL"
assert p["REMOTE_FPS"] == "STANDARD" and p["USE_HDR"] == "false" and p["REMOTE_MANUAL_BITRATE"] == "100000"
assert p["SELECTED_PSN_PROFILE_ACCOUNT_ID"] == "keep-me" and p["STREAM_WINDOW_WIDTH"] == "900"
EOF
pass "recommended PXPlay settings applied, account and window entries left alone"
[ -f "$work/system/Library/LaunchDaemons/io.github.mirage-pxplay.steady-wifi.plist" ] || fail "helper not installed"
pass "Steady Wi-Fi helper installed (scratch /Library)"

echo "Launcher"
out=$(MIRAGE_HOME="$support" "$launcher/Contents/MacOS/MirageLauncher" --mirage-dry-run)
grep -q "^app=$full$" <<<"$out" && grep -q "^JAVA_TOOL_OPTIONS=-agentpath:\"$support/lib/MirageAgent.dylib\"$" <<<"$out" \
    && grep -q "^PXPLAY_FG_RESOURCES=$support/Resources/FG$" <<<"$out" || fail "launch plan: $out"
pass "starts the original $full with the agent and resources"
plutil -replace full -string "/Volumes/Gone/PXPlay.app" "$support/config.plist"
out=$(MIRAGE_HOME="$support" "$launcher/Contents/MacOS/MirageLauncher" --mirage-dry-run)
grep -q "^app=$full$" <<<"$out" && [ "$(plutil -extract full raw "$support/config.plist")" = "$full" ] || fail "re-detect: $out"
pass "PXPlay moved: launcher finds it again and remembers the new place"

echo "Uninstall"
"$installer" --uninstall --restore-settings | sed 's/^/      /'
[ ! -e "$support" ] && [ ! -e "$launcher" ] || fail "files left behind"
[ ! -e "$work/system/Library/LaunchDaemons/io.github.mirage-pxplay.steady-wifi.plist" ] || fail "helper left behind"
pass "Mirage files, launchers and helper removed"
python3 -I - "$prefs" <<'EOF' || fail "settings not restored: $(cat "$prefs")"
import json, sys
p = json.load(open(sys.argv[1]))
assert p["REMOTE_FPS"] == "HIGH" and p["USE_HDR"] == "true", p
assert "VIDEO_RENDERING_FRAME_GENERATION" not in p and p["SELECTED_PSN_PROFILE_ACCOUNT_ID"] == "keep-me", p
EOF
pass "previous PXPlay settings restored"
[ -d "$full" ] && "$installer" --validate "$full" >/dev/null || fail "PXPlay changed"
pass "PXPlay itself untouched (signature still valid)"

if [ "${1:-}" = --live ]; then
    echo "Live start of the real PXPlay"
    pgrep -f "PXPlay.app/Contents/MacOS/PXPlay" >/dev/null && fail "quit PXPlay first"
    MIRAGE_PAYLOAD="$payload" "$installer" --install --full "$full" >/dev/null
    log="$HOME/Library/Logs/Mirage for PXPlay/PXPlay.log"
    MIRAGE_HOME="$support" "$launcher/Contents/MacOS/MirageLauncher"
    for _ in $(seq 1 40); do grep -q "Settings panel ready" "$log" 2>/dev/null && break; sleep 0.5; done
    grep "\[Mirage\]" "$log" | sed 's/^/      /'
    grep -q "\[Mirage\] Mirage loaded into PXPlay 3.2.0" "$log" || fail "agent did not load"
    pass "JAVA_TOOL_OPTIONS reached PXPlay's Java runtime and the agent loaded"
    osascript -e 'tell application id "com.grill.psplay.PXPlay" to quit' >/dev/null 2>&1 || true
    for _ in $(seq 1 30); do pgrep -f "PXPlay.app/Contents/MacOS/PXPlay" >/dev/null || break; sleep 0.5; done
    "$installer" --uninstall >/dev/null
    pass "PXPlay quit, scratch install removed"
fi
echo "Smoke test passed."

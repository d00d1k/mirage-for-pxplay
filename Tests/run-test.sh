#!/bin/bash
# Mirage test suite. Runs the built agent (build/payload) against the classes of the
# PXPlay 3.2.0 installed on this Mac and against a mock of PXPlay's native renderer.
# Nothing here starts PXPlay itself; see smoke-test.sh --live for that.
set -euo pipefail
cd "$(dirname "$0")/.."
repo="$PWD"
[ -n "${JAVA_HOME:-}" ] || JAVA_HOME="$(/usr/libexec/java_home -v 25+)"
app="${PXPLAY_APP:-/Applications/PXPlay.app}"
java_root="$app/Contents/Resources/Java"
libs="$java_root/libs"
jar="$java_root/PXPlay-3.2.0-runnable.jar"
payload="$repo/build/payload"
agent="$payload/lib/MirageAgent.dylib"
work="$repo/build/test"
rm -rf "$work"
mkdir -p "$work/classes" "$work/verify" "$work/home" "$work/system"
pass() { printf '  \033[32mok\033[0m  %s\n' "$*"; }
fail() { printf '  \033[31mFAIL\033[0m %s\n' "$*"; exit 1; }

xcrun clang -fobjc-arc -O2 -dynamiclib -I"$JAVA_HOME/include" -I"$JAVA_HOME/include/darwin" \
    -framework Foundation -framework CoreVideo Tests/Mock.m -o "$work/Mock.dylib"
"$JAVA_HOME/bin/javac" --release 25 -Xlint:-options -cp "$libs/*:$payload/Resources/Mirage.jar" -d "$work/classes" \
    Tests/MetalRenderer.java Tests/FXSettingsCheck.java Tests/I18nCheck.java
"$JAVA_HOME/bin/javac" --release 25 -Xlint:-options -d "$work/verify" Tests/VerifyClassHook.java

export MIRAGE_HOME="$work/home" MIRAGE_SYSTEM_ROOT="$work/system" PXPLAY_FG_RESOURCES="$payload/Resources/FG"
java=("$JAVA_HOME/bin/java" -Duser.language=en "-agentpath:$agent")

# PXPlay's classes write their own data files into the working folder; keep them in build/test.
cd "$work"
echo "Version gate"
out=$(MIRAGE_HOST_APP="$app" "${java[@]}" -Xverify:all -cp "$work/verify:$jar:$libs/*" VerifyClassHook 2>&1) || fail "$out"
grep -q "Mirage loaded into PXPlay 3.2.0" <<<"$out" && grep -q "Stick-aware smoothing ready" <<<"$out" \
    && grep -q "Early RIFE start ready" <<<"$out" || fail "class edits not applied: $out"
pass "PXPlay 3.2.0: agent on, both classes edited in memory and pass -Xverify:all"
out=$("${java[@]}" -cp "$work/verify:$jar:$libs/*" VerifyClassHook 2>&1)
grep -q "\[Mirage\] Off: host .* is not PXPlay" <<<"$out" && ! grep -q "ready" <<<"$out" || fail "not inert outside PXPlay: $out"
pass "other host app: agent stays off, classes untouched"
fake="$work/PXPlay 3.1.0.app"
mkdir -p "$fake/Contents/Resources/Java"
cp "$app/Contents/Info.plist" "$fake/Contents/Info.plist"
plutil -replace CFBundleShortVersionString -string 3.1.0 "$fake/Contents/Info.plist"
out=$(MIRAGE_HOST_APP="$fake" "${java[@]}" -cp "$work/verify:$jar:$libs/*" VerifyClassHook 2>&1)
grep -q "PXPlay 3.1.0 is not supported" <<<"$out" && ! grep -q "ready" <<<"$out" || fail "other version not refused: $out"
pass "PXPlay 3.1.0: agent stays off"

echo "Frame generation (mock renderer)"
# HudNet runs one frame behind, so exact pixel parity between two runs needs it off (as in the lab).
out=$(FGLAB_HUDNET=0 MIRAGE_HOST_APP="$app" MIRAGE_TEST_KNOWN_RENDERER=1 "${java[@]}" --enable-native-access=ALL-UNNAMED \
    -cp "$work/classes:$jar:$libs/*" com.grill.streamutils.metal.MetalRenderer "$work/Mock.dylib" 2>&1) || fail "$out"
grep -E "^(RIFE|Matches|Dropped|Native HUD|Extrapolation|Hold)" <<<"$out" | sed 's/^/      /'
pass "RIFE pacing, NV12 parity, overlay label, real-frame-first prediction and hold"
out=$(MIRAGE_HOST_APP="$app" "${java[@]}" --enable-native-access=ALL-UNNAMED -cp "$work/classes:$jar:$libs/*" \
    com.grill.streamutils.metal.MetalRenderer "$work/Mock.dylib" 2>&1) && fail "label check should need the known renderer"
grep -q "MetalFX scale label off for this PXPlay build" <<<"$out" || fail "unknown renderer not detected: $out"
pass "unknown native renderer build: scale label skipped"

echo "Settings panel and languages"
printf 'style=picture\nsteadyWifi=false\n' > "$work/home/settings.properties"
out=$(MIRAGE_HOST_APP="$app" "${java[@]}" -cp "$work/classes:$jar:$libs/*" mirage.FXSettingsCheck 2>&1) || fail "$out"
grep "^Settings:" <<<"$out" | sed 's/^/      /'
pass "Video settings block"
out=$(MIRAGE_HOST_APP="$app" "${java[@]}" -cp "$work/classes:$jar:$libs/*" mirage.I18nCheck 2>&1) || fail "$out"
grep "^Languages:" <<<"$out" | sed 's/^/      /'
pass "translations"

echo "Steady Wi-Fi helper"
system="$work/system"
MIRAGE_SYSTEM_ROOT="$system" /bin/sh "$payload/Helper/install-helper.sh" "$USER" >/dev/null
plutil -lint "$system/Library/LaunchDaemons/io.github.mirage-pxplay.steady-wifi.plist" >/dev/null || fail "helper plist"
[ "$(stat -f %Sp "$system/Users/Shared/Mirage for PXPlay/steady-wifi")" = drwxrwxrwt ] || fail "request folder mode"
pass "installer writes a valid launchd job and a shared request folder"
calls="$work/ifconfig.calls"
cat > "$work/fake-ifconfig" <<EOF
#!/bin/sh
state="$work/awdl.state"; [ -f "\$state" ] || echo up > "\$state"
case "\$2" in down|up) echo "\$2" > "\$state"; echo "\$2" >> "$calls";; *) [ "\$(cat "\$state")" = up ] && echo "awdl0: flags=8943<UP,BROADCAST>" || echo "awdl0: flags=8902<BROADCAST>";; esac
EOF
chmod +x "$work/fake-ifconfig"
sleep 30 & sleeper=$!
process=$(ps -o comm= -p $sleeper)
echo $sleeper > "$system/Users/Shared/Mirage for PXPlay/steady-wifi/tester.pid"
echo 999999 > "$system/Users/Shared/Mirage for PXPlay/steady-wifi/stale.pid"
MIRAGE_SYSTEM_ROOT="$system" MIRAGE_IFCONFIG="$work/fake-ifconfig" MIRAGE_TEST_PROCESS="$process" \
    /bin/sh "$system/Library/PrivilegedHelperTools/io.github.mirage-pxplay.steady-wifi" & helper=$!
sleep 2
[ "$(cat "$calls" 2>/dev/null)" = down ] || fail "AWDL not paused while the PXPlay process runs"
[ ! -e "$system/Users/Shared/Mirage for PXPlay/steady-wifi/stale.pid" ] || fail "stale request kept"
kill $sleeper; wait $sleeper 2>/dev/null || true
for _ in 1 2 3 4; do kill -0 $helper 2>/dev/null || break; sleep 1; done
kill -0 $helper 2>/dev/null && fail "helper did not stop after PXPlay quit"
[ "$(tr '\n' ' ' < "$calls")" = "down up " ] || fail "AWDL not restored: $(cat "$calls")"
pass "pauses AWDL only while the requesting process lives, drops stale requests, restores AWDL"
MIRAGE_SYSTEM_ROOT="$system" /bin/sh "$payload/Helper/uninstall-helper.sh" >/dev/null
[ ! -e "$system/Library/LaunchDaemons/io.github.mirage-pxplay.steady-wifi.plist" ] || fail "helper not removed"
pass "uninstall removes the helper"
echo "All tests passed."

#!/bin/bash
# Builds Mirage Installer.app and the release zip.
#
#   ./build.sh            everything: payload, installer, zip
#   ./build.sh payload    only the files the installer copies (agent, jar, launchers, helper)
#
# Needs: Xcode 26 (clang, swift), a JDK 25+ (JAVA_HOME, else /usr/libexec/java_home -v 25+),
# and PXPlay 3.2.0 installed (its JavaFX jars are needed to compile the settings panel;
# PXPLAY_APP overrides the location). Nothing from PXPlay is copied into the build.
set -euo pipefail
cd "$(dirname "$0")"
repo="$PWD"
build="$repo/build"
stage="${1:-all}"
source "$repo/release.config"

if [ -z "${JAVA_HOME:-}" ]; then
    JAVA_HOME="$(/usr/libexec/java_home -v 25+ 2>/dev/null || true)"
fi
[ -x "${JAVA_HOME:-}/bin/javac" ] || { echo "build: set JAVA_HOME to a JDK 25 or newer" >&2; exit 1; }
pxplay="${PXPLAY_APP:-/Applications/PXPlay.app}"
fxlibs="$pxplay/Contents/Resources/Java/libs"
[ -d "$fxlibs" ] || { echo "build: PXPlay 3.2.0 not found at $pxplay (set PXPLAY_APP)" >&2; exit 1; }

payload="$build/payload"
rm -rf "$payload" "$build/classes"
mkdir -p "$build" && touch "$build/.metadata_never_index"
mkdir -p "$payload/lib" "$payload/Resources/FG/RifeShaders" "$payload/Helper" "$payload/Licenses" \
    "$payload/Apps" "$build/classes" "$build/bin"

echo "== Texts"
python3 Tools/gen-i18n.py "$build/i18n"

echo "== Icon"
if [ ! -f "$build/Mirage.icns" ] || [ Tools/make-icon.swift -nt "$build/Mirage.icns" ]; then
    rm -rf "$build/Mirage.iconset"
    xcrun swift Tools/make-icon.swift "$build/Mirage.iconset"
    iconutil -c icns "$build/Mirage.iconset" -o "$build/Mirage.icns"
fi

echo "== RIFE backend (Swift)"
xcrun swift build --package-path Sources/Backends --scratch-path "$build/swift" -c release --jobs 6 2>&1 | grep -vE "warning:|^\s*\||^\s*[0-9]+ \|" || true
backend="$build/swift/release/libFGBackends.dylib"
[ -f "$backend" ] || { echo "build: Swift backend failed" >&2; exit 1; }
cp "$backend" "$payload/lib/"

echo "== Agent"
xcrun clang -O2 -fobjc-arc -dynamiclib -arch arm64 -mmacosx-version-min=26.0 -Wall -Wno-unused-variable \
    -Wno-unused-function -I"$JAVA_HOME/include" -I"$JAVA_HOME/include/darwin" \
    -framework Foundation -framework AppKit -framework QuartzCore -framework CoreVideo -framework CoreMedia \
    -L"$build/swift/release" -lFGBackends -Wl,-rpath,@loader_path \
    -install_name @rpath/MirageAgent.dylib Sources/Agent/MirageAgent.m -o "$payload/lib/MirageAgent.dylib"

echo "== Settings panel (Java)"
"$JAVA_HOME/bin/javac" --release 25 -Xlint:-options -cp "$fxlibs/*" -d "$build/classes" Sources/Bridge/mirage/*.java
cp -R "$build/i18n/mirage/i18n" "$build/classes/mirage/"
"$JAVA_HOME/bin/jar" --create --file "$payload/Resources/Mirage.jar" -C "$build/classes" .

echo "== Frame generation resources"
cp Sources/RifeRuntime/Sources/RifeMetal/Resources/rife-v4.25.rmw "$payload/Resources/FG/"
cp Sources/RifeRuntime/Sources/RifeMetalCore/Shaders/*.metal "$payload/Resources/FG/RifeShaders/"
cp Sources/Shaders/Turbo.metal "$payload/Resources/FG/"
# HudNet: Neural Engine HUD mask; the backend falls back to the stillness rules if it is missing.
cp -R Sources/Models/HudNet.mlmodelc "$payload/Resources/FG/"
cp i18n/strings.json "$payload/Resources/"
cp Sources/Helper/*.sh "$payload/Helper/"
chmod 0755 "$payload/Helper/"*.sh
cp LICENSE "$payload/Licenses/Mirage-LICENSE.txt"
cp THIRD-PARTY-NOTICES.md "$payload/Licenses/"
cp Sources/RifeRuntime/LICENSE "$payload/Licenses/rife-metal-LICENSE-Apache-2.0.txt"
cp Sources/RifeRuntime/THIRD-PARTY.md "$payload/Licenses/rife-metal-THIRD-PARTY.md"
cp Licenses/OpenDuckFrame-LICENSE.txt "$payload/Licenses/"

echo "== Launchers"
xcrun clang -O2 -fobjc-arc -arch arm64 -mmacosx-version-min=26.0 -Wall -framework Cocoa -framework Security \
    -framework UniformTypeIdentifiers Sources/Launcher/MirageLauncher.m -o "$build/bin/MirageLauncher"
make_launcher() {   # name, bundle id, target
    local app="$payload/Apps/$1.app"
    mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources"
    cp "$build/bin/MirageLauncher" "$app/Contents/MacOS/MirageLauncher"
    cp "$build/Mirage.icns" "$app/Contents/Resources/Mirage.icns"
    cp i18n/strings.json "$app/Contents/Resources/strings.json"
    cat > "$app/Contents/Info.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleExecutable</key><string>MirageLauncher</string>
    <key>CFBundleIdentifier</key><string>$2</string>
    <key>CFBundleName</key><string>$1</string>
    <key>CFBundleDisplayName</key><string>$1</string>
    <key>CFBundleIconFile</key><string>Mirage</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>$MIRAGE_VERSION</string>
    <key>CFBundleVersion</key><string>$MIRAGE_VERSION</string>
    <key>LSMinimumSystemVersion</key><string>26.0</string>
    <key>LSUIElement</key><true/>
    <key>LSApplicationCategoryType</key><string>public.app-category.games</string>
    <key>MirageTarget</key><string>$3</string>
    <key>NSHumanReadableCopyright</key><string>Mirage for PXPlay. Not affiliated with PXPlay or its developer.</string>
</dict>
</plist>
EOF
    codesign --force --sign - --timestamp=none "$app"
}
make_launcher "Mirage for PXPlay" io.github.mirage-pxplay.launcher full
make_launcher "Mirage for PXPlay Demo" io.github.mirage-pxplay.launcher.demo demo
codesign --force --sign - --timestamp=none "$payload/lib/libFGBackends.dylib" "$payload/lib/MirageAgent.dylib"
echo "$MIRAGE_VERSION" > "$payload/VERSION"
[ "$stage" = payload ] && { echo "build: payload ready in $payload"; exit 0; }

echo "== Installer"
installer="$build/Mirage Installer.app"
rm -rf "$installer"
mkdir -p "$installer/Contents/MacOS" "$installer/Contents/Resources"
xcrun swiftc -O -parse-as-library -target arm64-apple-macos26.0 -module-name MirageInstaller \
    -framework SwiftUI -framework AppKit -framework MetalKit -framework Metal -framework Security \
    -framework UniformTypeIdentifiers Sources/Installer/*.swift -o "$installer/Contents/MacOS/Mirage Installer" \
    2>&1 | grep -v "^$" || true
[ -x "$installer/Contents/MacOS/Mirage Installer" ] || { echo "build: installer failed" >&2; exit 1; }
cp -R "$payload" "$installer/Contents/Resources/Payload"
cp "$build/Mirage.icns" "$installer/Contents/Resources/Mirage.icns"
cp i18n/strings.json "$installer/Contents/Resources/strings.json"
cat > "$installer/Contents/Info.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleExecutable</key><string>Mirage Installer</string>
    <key>CFBundleIdentifier</key><string>io.github.mirage-pxplay.installer</string>
    <key>CFBundleName</key><string>Mirage Installer</string>
    <key>CFBundleDisplayName</key><string>Mirage Installer</string>
    <key>CFBundleIconFile</key><string>Mirage</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>$MIRAGE_VERSION</string>
    <key>CFBundleVersion</key><string>$MIRAGE_VERSION</string>
    <key>LSMinimumSystemVersion</key><string>26.0</string>
    <key>LSArchitecturePriority</key><array><string>arm64</string></array>
    <key>NSHighResolutionCapable</key><true/>
    <key>MirageDonateURL</key><string>$MIRAGE_DONATE_URL</string>
    <key>MirageProjectURL</key><string>$MIRAGE_PROJECT_URL</string>
    <key>NSHumanReadableCopyright</key><string>Mirage for PXPlay. Not affiliated with PXPlay or its developer.</string>
</dict>
</plist>
EOF
codesign --force --sign - --timestamp=none --deep "$installer"
codesign --verify --deep --strict "$installer"

echo "== Release zip"
release="$build/release"
rm -rf "$release"
mkdir -p "$release"
ditto "$installer" "$release/Mirage Installer.app"
cp "Read me first.txt" "$release/"
zip_name="Mirage-for-PXPlay-$MIRAGE_VERSION.zip"
rm -f "$build/$zip_name"
(cd "$release" && /usr/bin/zip -qry "$build/$zip_name" "Mirage Installer.app" "Read me first.txt")
du -sh "$installer" "$build/$zip_name"
echo "build: done → $build/$zip_name"

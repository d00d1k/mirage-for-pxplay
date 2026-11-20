// Exact PXPlay 3.2.0 (arm64) builds that Mirage knows. Shared by the agent; the installer
// and launcher check the same values. Anything else leaves Mirage switched off.
#pragma once

#define MIRAGE_PXPLAY_VERSION "3.2.0"
#define MIRAGE_FULL_BUNDLE_ID "com.grill.psplay.PXPlay"
#define MIRAGE_DEMO_BUNDLE_ID "com.grill.psplay.PXPlay.demo"
#define MIRAGE_FULL_JAR "PXPlay-3.2.0-runnable.jar"
#define MIRAGE_DEMO_JAR "PXPlay_Demo-3.2.0-runnable.jar"

// com/grill/psplay/video/desktop/renderer/metal/MetalRendererBackend.class (same in full and demo)
#define FG_INPUT_CLASS_SIZE 42425
#define FG_INPUT_CLASS_FNV UINT64_C(0x1c758f5d0f823131)
// com/grill/psplay/gamepad/data/ControllerRemoteState.class (same in full and demo)
#define FG_STICK_CLASS_SIZE 4337
#define FG_STICK_CLASS_FNV UINT64_C(0xb37c96afc36b76d3)

// SHA-256 of native-binaries/libstreamutils-native-arm64.dylib inside libstreamutils-java-1.7.jar
// of the full PXPlay 3.2.0. Only this build has the renderer layout the scale reader expects.
#define MIRAGE_FULL_STREAMUTILS_SHA256 "8cc26b33d474993aa1ace33fefe3d75128f11d48d8a2772e9fd83f5692b3382f"

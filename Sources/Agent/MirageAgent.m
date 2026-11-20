// Mirage for PXPlay: a JVMTI agent loaded into the user's own, unmodified PXPlay 3.2.0
// through JAVA_TOOL_OPTIONS. It replaces PXPlay's in-between frames with RIFE frames on
// Metal. It stays completely inert on any other app or PXPlay version.
#import <Foundation/Foundation.h>
#import <AppKit/AppKit.h>
#import <CoreVideo/CoreVideo.h>
#import <CommonCrypto/CommonDigest.h>
#include <dlfcn.h>
#include <fcntl.h>
#include <jni.h>
#include <jvmti.h>
#include <math.h>
#include <stdatomic.h>
#include <time.h>
#include <unistd.h>
#include "PXPlayFingerprints.h"

#if !defined(__arm64__)
#error Mirage supports Apple silicon only
#endif

typedef jint (JNICALL *DecodeFn)(JNIEnv *, jobject, jlong, jlong);
typedef jboolean (JNICALL *InterpolateFn)(JNIEnv *, jobject, jlong, jfloat);
typedef jboolean (JNICALL *SetFGFn)(JNIEnv *, jobject, jlong, jboolean);
typedef void (JNICALL *DisposeFn)(JNIEnv *, jobject, jlong);
typedef void (JNICALL *RenderFn)(JNIEnv *, jobject, jlong, jlong);
typedef jlong (JNICALL *InitFn)(JNIEnv *, jobject, jlong, jint, jint, jboolean, jboolean,
    jdouble, jint, jfloat, jfloat, jboolean, jboolean);
typedef jboolean (JNICALL *PresentLatestFn)(JNIEnv *, jobject, jlong);
typedef void (JNICALL *PerfOverlayFn)(JNIEnv *, jobject, jlong, jboolean, jboolean, jstring);

static _Atomic(DecodeFn) originalDecode;
static _Atomic(InterpolateFn) originalInterpolate;
static _Atomic(SetFGFn) originalSetFG;
static _Atomic(DisposeFn) originalDispose;
static _Atomic(RenderFn) originalRender;
static _Atomic(InitFn) originalInit;
static _Atomic(PerfOverlayFn) originalPerfOverlay;
static _Atomic(PresentLatestFn) originalPresentLatest;

static const uint64_t historyLimit = 250 * NSEC_PER_MSEC;
static const unsigned maxConsecutiveErrors = 3;

@protocol FGSession <NSObject>
- (void)capture:(CVPixelBufferRef)buffer ready:(BOOL)ready;
- (CVPixelBufferRef)copyInterpolatedFrame CF_RETURNS_RETAINED;
- (void)recordGeneratedFrame;
- (void)recordFallback;
- (NSString *)generationStatus;
- (void)close;
@end

// Engine sessions and the presentation hooks, shared with the lab tree.
#include "MirageGlue.inc"

#pragma mark - Version gate

static NSString *hostDescription = @"";

// Mirage runs only inside PXPlay or PXPlay Demo 3.2.0 started from its own bundle with
// the expected runnable jar. MIRAGE_HOST_APP names the bundle for the test suite, which
// runs plain `java` against the installed app's classes.
static BOOL hostSupported(jvmtiEnv *jvmti, NSString **reason) {
    const char *override = getenv("MIRAGE_HOST_APP");
    NSBundle *host = override ? [NSBundle bundleWithPath:@(override)] : NSBundle.mainBundle;
    NSString *identifier = host.bundleIdentifier;
    BOOL full = [identifier isEqualToString:@MIRAGE_FULL_BUNDLE_ID];
    BOOL demo = [identifier isEqualToString:@MIRAGE_DEMO_BUNDLE_ID];
    if (!full && !demo) {
        *reason = [NSString stringWithFormat:@"host %@ is not PXPlay", identifier ?: @"(unknown)"];
        return NO;
    }
    NSString *version = host.infoDictionary[@"CFBundleShortVersionString"];
    if (![version isEqualToString:@MIRAGE_PXPLAY_VERSION]) {
        *reason = [NSString stringWithFormat:@"PXPlay %@ is not supported (needs %s)", version ?: @"?",
            MIRAGE_PXPLAY_VERSION];
        return NO;
    }
    NSString *jar = full ? @MIRAGE_FULL_JAR : @MIRAGE_DEMO_JAR;
    NSString *jarPath = [host.bundlePath stringByAppendingPathComponent:
        [@"Contents/Resources/Java" stringByAppendingPathComponent:jar]];
    if (![NSFileManager.defaultManager fileExistsAtPath:jarPath]) {
        *reason = [NSString stringWithFormat:@"%@ is missing", jar];
        return NO;
    }
    char *classPath = NULL;
    BOOL onClassPath = (*jvmti)->GetSystemProperty(jvmti, "java.class.path", &classPath) == JVMTI_ERROR_NONE &&
        classPath && strstr(classPath, jar.UTF8String);
    if (classPath) (*jvmti)->Deallocate(jvmti, (unsigned char *)classPath);
    if (!onClassPath) {
        *reason = [NSString stringWithFormat:@"%@ is not the running application", jar];
        return NO;
    }
    hostDescription = full ? @"PXPlay 3.2.0" : @"PXPlay Demo 3.2.0";
    return YES;
}

#pragma mark - MetalFX scale label

// The scale label reads three fields of PXPlay's native renderer. Their offsets are known
// for one exact build of libstreamutils (full PXPlay 3.2.0); for any other file the label
// is skipped and PXPlay's own overlay text stays as it is.
static _Atomic(int) scaleReader = -1;

static BOOL scaleReaderAllowed(void *address) {
    int known = atomic_load(&scaleReader);
    if (known >= 0) return known == 1;
    BOOL allowed = NO;
    Dl_info info;
    const char *testRenderer = getenv("MIRAGE_TEST_KNOWN_RENDERER");   // test suite's mock renderer only
    if (testRenderer && !strcmp(testRenderer, "1")) {
        allowed = YES;
    } else if (dladdr(address, &info) && info.dli_fname) {
        NSData *data = [NSData dataWithContentsOfFile:@(info.dli_fname) options:NSDataReadingMappedIfSafe error:NULL];
        if (data) {
            unsigned char digest[CC_SHA256_DIGEST_LENGTH];
            CC_SHA256(data.bytes, (CC_LONG)data.length, digest);
            NSMutableString *hex = [NSMutableString stringWithCapacity:64];
            for (int i = 0; i < CC_SHA256_DIGEST_LENGTH; ++i) [hex appendFormat:@"%02x", digest[i]];
            allowed = [hex isEqualToString:@MIRAGE_FULL_STREAMUTILS_SHA256];
        }
    }
    int expected = -1;
    if (atomic_compare_exchange_strong(&scaleReader, &expected, allowed ? 1 : 0)) {
        fprintf(stderr, "[Mirage] MetalFX scale label %s.\n", allowed ? "on" : "off for this PXPlay build");
    }
    return atomic_load(&scaleReader) == 1;
}

#pragma mark - Native method binding

static void JNICALL nativeBind(jvmtiEnv *jvmti, JNIEnv *env, jthread thread, jmethodID method,
    void *address, void **replacement) {
    (void)thread;
    if (!env) return;
    jvmtiPhase phase;
    if ((*jvmti)->GetPhase(jvmti, &phase) != JVMTI_ERROR_NONE || phase != JVMTI_PHASE_LIVE) return;
    char *name = NULL, *signature = NULL, *owner = NULL;
    jclass klass = NULL;
    if ((*jvmti)->GetMethodName(jvmti, method, &name, &signature, NULL) != JVMTI_ERROR_NONE) goto cleanup;
    if (strcmp(name, "nativeSetFrameGeneration") && strcmp(name, "nativeDecodeRealFrame") &&
        strcmp(name, "nativeRenderInterpolated") && strcmp(name, "nativeRenderAvFrame") &&
        strcmp(name, "nativeDispose") && strcmp(name, "nativeInit") &&
        strcmp(name, "nativeSetPerfOverlay") && strcmp(name, "nativePresentLatestReal")) goto cleanup;
    if ((*jvmti)->GetMethodDeclaringClass(jvmti, method, &klass) != JVMTI_ERROR_NONE ||
        (*jvmti)->GetClassSignature(jvmti, klass, &owner, NULL) != JVMTI_ERROR_NONE ||
        strcmp(owner, "Lcom/grill/streamutils/metal/MetalRenderer;")) goto cleanup;
    if (!strcmp(name, "nativeInit") && !strcmp(signature, "(JIIZZDIFFZZ)J")) {
        if (!scaleReaderAllowed(address)) goto cleanup;
        atomic_store(&originalInit, (InitFn)address);
        *replacement = (void *)&initRenderer;
    } else if (!strcmp(name, "nativeSetPerfOverlay") && !strcmp(signature, "(JZZLjava/lang/String;)V")) {
        if (!scaleReaderAllowed(address)) goto cleanup;
        atomic_store(&originalPerfOverlay, (PerfOverlayFn)address);
        *replacement = (void *)&setPerfOverlay;
    } else if (!strcmp(name, "nativeSetFrameGeneration") && !strcmp(signature, "(JZ)Z")) {
        atomic_store(&originalSetFG, (SetFGFn)address);
        *replacement = (void *)&setFG;
    } else if (!strcmp(name, "nativeDecodeRealFrame") && !strcmp(signature, "(JJ)I")) {
        atomic_store(&originalDecode, (DecodeFn)address);
        *replacement = (void *)&decode;
    } else if (!strcmp(name, "nativeRenderInterpolated") && !strcmp(signature, "(JF)Z")) {
        atomic_store(&originalInterpolate, (InterpolateFn)address);
        Dl_info source;
        if (dladdr(address, &source) && source.dli_fname) {
            void *lib = dlopen(source.dli_fname, RTLD_LAZY | RTLD_NOLOAD | RTLD_FIRST);
            if (lib) {
                RenderFn render = (RenderFn)dlsym(lib, "Java_com_grill_streamutils_metal_MetalRenderer_nativeRenderAvFrame");
                if (render) atomic_store(&originalRender, render);
                PresentLatestFn latest = (PresentLatestFn)dlsym(lib,
                    "Java_com_grill_streamutils_metal_MetalRenderer_nativePresentLatestReal");
                PresentLatestFn none = NULL;
                if (latest) atomic_compare_exchange_strong(&originalPresentLatest, &none, latest);
                dlclose(lib);
            }
        }
        *replacement = (void *)&interpolate;
    } else if (!strcmp(name, "nativePresentLatestReal") && !strcmp(signature, "(J)Z")) {
        atomic_store(&originalPresentLatest, (PresentLatestFn)address);
        *replacement = (void *)&presentLatest;
    } else if (!strcmp(name, "nativeRenderAvFrame") && !strcmp(signature, "(JJ)V")) {
        atomic_store(&originalRender, (RenderFn)address);
    } else if (!strcmp(name, "nativeDispose") && !strcmp(signature, "(J)V")) {
        atomic_store(&originalDispose, (DisposeFn)address);
        *replacement = (void *)&dispose;
    } else {
        goto cleanup;
    }
    fprintf(stderr, "[Mirage] PXPlay native binding: %s%s\n", name, signature);
cleanup:
    if (klass) (*env)->DeleteLocalRef(env, klass);
    if (owner) (*jvmti)->Deallocate(jvmti, (unsigned char *)owner);
    if (signature) (*jvmti)->Deallocate(jvmti, (unsigned char *)signature);
    if (name) (*jvmti)->Deallocate(jvmti, (unsigned char *)name);
}

#pragma mark - Settings bridge (mirage.MirageBridge natives)

static jstring JNICALL lastStatus(JNIEnv *env, jclass klass) {
    (void)klass;
    @autoreleasepool {
        [registryLock lock];
        NSString *status = [NSString stringWithFormat:@"%@\n%@", lastScaleStatus ?: @"", lastGenerationStatus ?: @""];
        [registryLock unlock];
        unichar chars[256];
        NSUInteger count = MIN(status.length, sizeof(chars) / sizeof(chars[0]));
        [status getCharacters:chars range:NSMakeRange(0, count)];
        return (*env)->NewString(env, (const jchar *)chars, (jsize)count);
    }
}

static void JNICALL selectFG(JNIEnv *env, jclass klass, jint engine, jint profile, jint budget) {
    (void)env; (void)klass;
    if ((engine != FGLabStock && engine != FGLabRife) || profile < 0 || profile > 1 || budget < 0 || budget > 32) return;
    atomic_store(&fgSelection, (uint32_t)(engine | (profile << 8) | (budget << 16)));
}

static jboolean JNICALL isRifePrefetchEnabled(JNIEnv *env, jclass klass) {
    (void)env; (void)klass;
    return atomic_load(&earlyRife) && (atomic_load(&fgSelection) & 0xff) == FGLabRife;
}

static void JNICALL prefetchVideoFrame(JNIEnv *env, jclass klass, jobject metal, jlong buffer) {
    if (!metal || !buffer || !isRifePrefetchEnabled(env, klass)) return;
    @autoreleasepool {
        jclass type = (*env)->GetObjectClass(env, metal);
        if (!type) return;
        jfieldID field = (*env)->GetFieldID(env, type, "nativeHandle", "J");
        (*env)->DeleteLocalRef(env, type);
        if (!field) {
            (*env)->ExceptionClear(env);
            return;
        }
        jlong renderer = (*env)->GetLongField(env, metal, field);
        id session = sessionFor(renderer, NO);
        if ([session isKindOfClass:AlternativeFGSession.class]) {
            [(AlternativeFGSession *)session prefetch:(CVPixelBufferRef)(uintptr_t)buffer];
        }
    }
}

static void JNICALL setRifePrefetch(JNIEnv *env, jclass klass, jboolean enabled) {
    (void)env; (void)klass;
    atomic_store(&earlyRife, enabled);
}

static void JNICALL setExtrapolationTuning(JNIEnv *env, jclass klass, jint strength, jint damping, jint stickDelay) {
    (void)env; (void)klass;
    if (strength < 10 || strength > 100 || damping < 0 || damping > 2 || stickDelay > 500) return;
    atomic_store(&extrapStrength, strength);
    atomic_store(&extrapDamping, damping);
    atomic_store(&extrapStickDelayMs, stickDelay);
    fprintf(stderr, "[Mirage] Prediction tuning: strength %d%%, camera smoothing %d, stick %d ms.\n",
        strength, damping, stickDelay);
}

static void JNICALL stickInputNative(JNIEnv *env, jclass klass, jint rx, jint ry, jint lx, jint ly) {
    (void)env; (void)klass; (void)lx; (void)ly;
    reportStick(rx, ry);
}

static void JNICALL setRifeExtrapolation(JNIEnv *env, jclass klass, jboolean enabled) {
    (void)env; (void)klass;
    atomic_store(&extrapolateRife, enabled);
}

static void JNICALL setRifeHudProtection(JNIEnv *env, jclass klass, jboolean enabled) {
    (void)env; (void)klass;
    atomic_store(&protectRifeHud, enabled);
}

#pragma mark - Class patches

// Two PXPlay classes get a one-line call into Mirage: the decoded-frame submission (so RIFE
// can start before the frame is due) and the controller state copy (stick-aware smoothing).
// The bytes are transformed in memory by mirage.ClassPatches, only for the exact 3.2.0
// class files, so no PXPlay code is stored or shipped by Mirage.
static jclass patcherClass;
static jmethodID patcherMethod;

static uint64_t fnv1a(const unsigned char *data, jint length) {
    uint64_t print = UINT64_C(0xcbf29ce484222325);
    for (jint i = 0; i < length; ++i) print = (print ^ data[i]) * UINT64_C(0x100000001b3);
    return print;
}

static void JNICALL classHook(jvmtiEnv *jvmti, JNIEnv *jni, jclass redefining, jobject loader,
    const char *name, jobject protectionDomain, jint length, const unsigned char *data, jint *outLength,
    unsigned char **outData) {
    (void)redefining; (void)loader; (void)protectionDomain;
    if (!name || !patcherClass || redefining) return;
    BOOL renderer = !strcmp(name, "com/grill/psplay/video/desktop/renderer/metal/MetalRendererBackend") &&
        length == FG_INPUT_CLASS_SIZE;
    BOOL stick = !strcmp(name, "com/grill/psplay/gamepad/data/ControllerRemoteState") && length == FG_STICK_CLASS_SIZE;
    if (!renderer && !stick) return;
    if (fnv1a(data, length) != (renderer ? FG_INPUT_CLASS_FNV : FG_STICK_CLASS_FNV)) {
        fprintf(stderr, "[Mirage] %s differs from PXPlay 3.2.0; left unchanged.\n", name);
        return;
    }
    jstring className = (*jni)->NewStringUTF(jni, name);
    jbyteArray original = (*jni)->NewByteArray(jni, length);
    if (!className || !original) {
        (*jni)->ExceptionClear(jni);
        return;
    }
    (*jni)->SetByteArrayRegion(jni, original, 0, length, (const jbyte *)data);
    jbyteArray patched = (jbyteArray)(*jni)->CallStaticObjectMethod(jni, patcherClass, patcherMethod, className, original);
    if ((*jni)->ExceptionCheck(jni)) {
        (*jni)->ExceptionDescribe(jni);
        (*jni)->ExceptionClear(jni);
        patched = NULL;
    }
    if (patched) {
        jsize size = (*jni)->GetArrayLength(jni, patched);
        unsigned char *bytes = NULL;
        if (size > 0 && (*jvmti)->Allocate(jvmti, size, &bytes) == JVMTI_ERROR_NONE) {
            (*jni)->GetByteArrayRegion(jni, patched, 0, size, (jbyte *)bytes);
            *outData = bytes;
            *outLength = size;
            fprintf(stderr, renderer ? "[Mirage] Early RIFE start ready.\n" : "[Mirage] Stick-aware smoothing ready.\n");
        }
        (*jni)->DeleteLocalRef(jni, patched);
    } else {
        fprintf(stderr, "[Mirage] Could not prepare %s; using normal timing.\n", name);
    }
    (*jni)->DeleteLocalRef(jni, original);
    (*jni)->DeleteLocalRef(jni, className);
}

#pragma mark - Start-up

static void JNICALL startBridge(jvmtiEnv *jvmti, JNIEnv *env, jthread thread) {
    (void)jvmti; (void)thread;
    jclass patches = (*env)->FindClass(env, "mirage/ClassPatches");
    if (patches) {
        jmethodID patch = (*env)->GetStaticMethodID(env, patches, "patch", "(Ljava/lang/String;[B)[B");
        if (patch) {
            patcherMethod = patch;
            patcherClass = (*env)->NewGlobalRef(env, patches);
        }
        (*env)->DeleteLocalRef(env, patches);
    }
    if ((*env)->ExceptionCheck(env)) {
        (*env)->ExceptionDescribe(env);
        (*env)->ExceptionClear(env);
    }
    jclass helper = (*env)->FindClass(env, "mirage/MirageBridge");
    if (helper) {
        JNINativeMethod methods[] = {
            { "lastStatus", "()Ljava/lang/String;", (void *)&lastStatus },
            { "selectFG", "(III)V", (void *)&selectFG },
            { "rifePrefetchEnabled", "()Z", (void *)&isRifePrefetchEnabled },
            { "prefetchVideoFrame", "(Ljava/lang/Object;J)V", (void *)&prefetchVideoFrame },
            { "setRifePrefetch", "(Z)V", (void *)&setRifePrefetch },
            { "setRifeHudProtection", "(Z)V", (void *)&setRifeHudProtection },
            { "setRifeExtrapolation", "(Z)V", (void *)&setRifeExtrapolation },
            { "setExtrapolationTuning", "(III)V", (void *)&setExtrapolationTuning },
            { "stickInputNative", "(IIII)V", (void *)&stickInputNative },
        };
        if ((*env)->RegisterNatives(env, helper, methods, sizeof(methods) / sizeof(methods[0])) == JNI_OK) {
            jmethodID begin = (*env)->GetStaticMethodID(env, helper, "begin", "()V");
            if (begin) (*env)->CallStaticVoidMethod(env, helper, begin);
        }
        (*env)->DeleteLocalRef(env, helper);
    }
    if ((*env)->ExceptionCheck(env)) {
        (*env)->ExceptionDescribe(env);
        (*env)->ExceptionClear(env);
        fprintf(stderr, "[Mirage] Settings panel could not start.\n");
    } else {
        fprintf(stderr, "[Mirage] Settings panel ready.\n");
    }
}

// MIRAGE_LOG: the launcher starts PXPlay through Launch Services, so stderr has nowhere
// to go. The agent sends it (its own lines and PXPlay's) to the log file instead.
static void openLog(void) {
    const char *path = getenv("MIRAGE_LOG");
    if (!path || !*path) return;
    int fd = open(path, O_WRONLY | O_CREAT | O_APPEND | O_NOFOLLOW | O_CLOEXEC, 0600);
    if (fd < 0) return;
    dup2(fd, STDERR_FILENO);
    close(fd);
    setvbuf(stderr, NULL, _IOLBF, 0);
}

JNIEXPORT jint JNICALL Agent_OnLoad(JavaVM *vm, char *options, void *reserved) {
    (void)options; (void)reserved;
    openLog();
    jvmtiEnv *jvmti = NULL;
    if ((*vm)->GetEnv(vm, (void **)&jvmti, JVMTI_VERSION_1_2) != JNI_OK) return JNI_OK;
    @autoreleasepool {
        NSString *reason = nil;
        if (!hostSupported(jvmti, &reason)) {
            fprintf(stderr, "[Mirage] Off: %s. PXPlay runs unchanged.\n", reason.UTF8String);
            return JNI_OK;
        }
        // <home>/lib/MirageAgent.dylib → <home>/Resources/{Mirage.jar, FG/}
        Dl_info self;
        if (!dladdr((void *)&Agent_OnLoad, &self) || !self.dli_fname) return JNI_OK;
        NSString *home = [[@(self.dli_fname) stringByDeletingLastPathComponent] stringByDeletingLastPathComponent];
        NSString *resources = [home stringByAppendingPathComponent:@"Resources"];
        const char *fg = getenv("PXPLAY_FG_RESOURCES");
        fgResourcesPath = fg && *fg ? @(fg) : [resources stringByAppendingPathComponent:@"FG"];
        setenv("PXPLAY_FG_RESOURCES", fgResourcesPath.fileSystemRepresentation, 0);
        NSString *jar = [resources stringByAppendingPathComponent:@"Mirage.jar"];
        registryLock = [[NSLock alloc] init];
        sessions = [[NSMutableDictionary alloc] init];
        activeRenderers = [[NSMutableSet alloc] init];

        jvmtiCapabilities capabilities = {0};
        capabilities.can_generate_native_method_bind_events = 1;
        capabilities.can_generate_all_class_hook_events = 1;
        jvmtiEventCallbacks callbacks = {0};
        callbacks.NativeMethodBind = &nativeBind;
        callbacks.ClassFileLoadHook = &classHook;
        callbacks.VMInit = &startBridge;
        if ((*jvmti)->AddToSystemClassLoaderSearch(jvmti, jar.fileSystemRepresentation) != JVMTI_ERROR_NONE ||
            (*jvmti)->AddCapabilities(jvmti, &capabilities) != JVMTI_ERROR_NONE ||
            (*jvmti)->SetEventCallbacks(jvmti, &callbacks, sizeof(callbacks)) != JVMTI_ERROR_NONE ||
            (*jvmti)->SetEventNotificationMode(jvmti, JVMTI_ENABLE, JVMTI_EVENT_NATIVE_METHOD_BIND, NULL) != JVMTI_ERROR_NONE ||
            (*jvmti)->SetEventNotificationMode(jvmti, JVMTI_ENABLE, JVMTI_EVENT_VM_INIT, NULL) != JVMTI_ERROR_NONE) {
            fprintf(stderr, "[Mirage] Off: the Java runtime refused the agent. PXPlay runs unchanged.\n");
            return JNI_OK;
        }
        if ((*jvmti)->SetEventNotificationMode(jvmti, JVMTI_ENABLE, JVMTI_EVENT_CLASS_FILE_LOAD_HOOK, NULL) !=
            JVMTI_ERROR_NONE) {
            fprintf(stderr, "[Mirage] Early start unavailable. Using normal timing.\n");
        }
        fprintf(stderr, "[Mirage] Mirage loaded into %s.\n", hostDescription.UTF8String);
    }
    return JNI_OK;
}

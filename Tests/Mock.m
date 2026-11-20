#import <Foundation/Foundation.h>
#import <CoreVideo/CoreVideo.h>
#include <jni.h>
#include <math.h>
#define M(name) Java_com_grill_streamutils_metal_MetalRenderer_##name

static int stockCalls, otherCalls;
static CVPixelBufferRef lastGenerated;
static uint8_t renderer[256];
static NSString *lastOverlay;

JNIEXPORT jlong JNICALL M(nativeInit)(JNIEnv *e,jobject o,jlong v,jint w,jint h,jboolean fx,jboolean hdr,
        jdouble scale,jint aspect,jfloat one,jfloat two,jboolean extra1,jboolean extra2) {
    renderer[0x90] = 1;
    renderer[0x98] = fx;
    memcpy(renderer + 0xa0, &scale, sizeof(scale));
    return (jlong)(uintptr_t)renderer;
}
JNIEXPORT jboolean JNICALL M(nativeSetFrameGeneration)(JNIEnv *e,jobject o,jlong h,jboolean enable) { return h && enable; }
JNIEXPORT jint JNICALL M(nativeDecodeRealFrame)(JNIEnv *e,jobject o,jlong h,jlong buffer) { return buffer ? 1 : -1; }
JNIEXPORT jboolean JNICALL M(nativeRenderInterpolated)(JNIEnv *e,jobject o,jlong h,jfloat phase) {
    ++stockCalls;
    return JNI_TRUE;
}
static int realCalls;
JNIEXPORT jboolean JNICALL M(nativePresentLatestReal)(JNIEnv *e,jobject o,jlong h) { ++realCalls; return JNI_TRUE; }
JNIEXPORT jint JNICALL M(realCount)(JNIEnv *e,jclass c) { return realCalls; }
JNIEXPORT void JNICALL M(nativeRenderAvFrame)(JNIEnv *e,jobject o,jlong h,jlong frame) {
    CVPixelBufferRef buffer = (CVPixelBufferRef)(uintptr_t)frame;
    if (!buffer || CVPixelBufferGetPixelFormatType(buffer) != kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange) return;
    ++otherCalls;
    if (lastGenerated) CVPixelBufferRelease(lastGenerated);
    lastGenerated = CVPixelBufferRetain(buffer);
}
static uint64_t hashGenerated(CVPixelBufferRef buffer) {
    if (!buffer) return 0;
    CVPixelBufferLockBaseAddress(buffer, kCVPixelBufferLock_ReadOnly);
    uint64_t hash = UINT64_C(0xcbf29ce484222325);
    for (size_t plane = 0; plane < 2; ++plane) {
        const uint8_t *bytes = CVPixelBufferGetBaseAddressOfPlane(buffer, plane);
        size_t stride = CVPixelBufferGetBytesPerRowOfPlane(buffer, plane);
        size_t columns = CVPixelBufferGetWidthOfPlane(buffer, plane) * (plane == 0 ? 1 : 2);
        size_t rows = CVPixelBufferGetHeightOfPlane(buffer, plane);
        for (size_t y = 0; y < rows; ++y) {
            for (size_t x = 0; x < columns; ++x) {
                hash = (hash ^ bytes[y * stride + x]) * UINT64_C(0x100000001b3);
            }
        }
    }
    CVPixelBufferUnlockBaseAddress(buffer, kCVPixelBufferLock_ReadOnly);
    return hash;
}
JNIEXPORT void JNICALL M(nativeSetPerfOverlay)(JNIEnv *e,jobject o,jlong h,jboolean visible,jboolean share,jstring text) {
    const char *chars = (*e)->GetStringUTFChars(e, text, NULL);
    lastOverlay = @(chars);
    (*e)->ReleaseStringUTFChars(e, text, chars);
}
JNIEXPORT void JNICALL M(nativeDispose)(JNIEnv *e,jobject o,jlong h) {
    if (lastGenerated) CVPixelBufferRelease(lastGenerated);
    lastGenerated = NULL;
}
JNIEXPORT jlong JNICALL M(lastGeneratedHash)(JNIEnv *e,jclass c) { return (jlong)hashGenerated(lastGenerated); }
JNIEXPORT jint JNICALL M(stockCount)(JNIEnv *e,jclass c) { return stockCalls; }
JNIEXPORT jint JNICALL M(generatedCount)(JNIEnv *e,jclass c) { return otherCalls; }
JNIEXPORT jstring JNICALL M(overlay)(JNIEnv *e,jclass c) { return (*e)->NewStringUTF(e, lastOverlay.UTF8String); }

JNIEXPORT jlong JNICALL M(makeFrame)(JNIEnv *e,jclass c,jint width,jint height,jint shift) {
    @autoreleasepool {
        CVPixelBufferRef frame = NULL;
        NSDictionary *attributes = @{(NSString *)kCVPixelBufferIOSurfacePropertiesKey:@{},
            (NSString *)kCVPixelBufferMetalCompatibilityKey:@YES};
        if (CVPixelBufferCreate(NULL,width,height,kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
            (__bridge CFDictionaryRef)attributes,&frame) != kCVReturnSuccess) return 0;
        CVPixelBufferLockBaseAddress(frame,0);
        uint8_t *luma = CVPixelBufferGetBaseAddressOfPlane(frame,0);
        size_t stride = CVPixelBufferGetBytesPerRowOfPlane(frame,0);
        for (int y=0;y<height;++y) {
            for (int x=0;x<width;++x) {
                luma[y*stride+x] = ((y+shift+(x/45)*3)%48<24) ? 205 : 55;
            }
        }
        memset(CVPixelBufferGetBaseAddressOfPlane(frame,1),128,
            CVPixelBufferGetBytesPerRowOfPlane(frame,1)*CVPixelBufferGetHeightOfPlane(frame,1));
        CVPixelBufferUnlockBaseAddress(frame,0);
        return (jlong)(uintptr_t)frame;
    }
}

// Non-repeating texture panned by `shift` px: optical flow tracks it unambiguously, unlike
// the stripes above (whose period makes the motion ambiguous).
JNIEXPORT jlong JNICALL M(makeTexturedFrame)(JNIEnv *e,jclass c,jint width,jint height,jint shift) {
    @autoreleasepool {
        CVPixelBufferRef frame = NULL;
        NSDictionary *attributes = @{(NSString *)kCVPixelBufferIOSurfacePropertiesKey:@{},
            (NSString *)kCVPixelBufferMetalCompatibilityKey:@YES};
        if (CVPixelBufferCreate(NULL,width,height,kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
            (__bridge CFDictionaryRef)attributes,&frame) != kCVReturnSuccess) return 0;
        CVPixelBufferLockBaseAddress(frame,0);
        uint8_t *luma = CVPixelBufferGetBaseAddressOfPlane(frame,0);
        size_t stride = CVPixelBufferGetBytesPerRowOfPlane(frame,0);
        for (int y=0;y<height;++y) {
            for (int x=0;x<width;++x) {
                float u = x + shift, v = y;
                float t = 128 + 45 * sinf(u * 0.031f + 0.7f * sinf(v * 0.013f)) * cosf(v * 0.027f + 0.4f * sinf(u * 0.009f))
                        + 30 * sinf(u * 0.11f + v * 0.07f) + 15 * sinf((u - v) * 0.23f);
                luma[y*stride+x] = (uint8_t)(16 + t * 219 / 255);
            }
        }
        memset(CVPixelBufferGetBaseAddressOfPlane(frame,1),128,
            CVPixelBufferGetBytesPerRowOfPlane(frame,1)*CVPixelBufferGetHeightOfPlane(frame,1));
        CVPixelBufferUnlockBaseAddress(frame,0);
        return (jlong)(uintptr_t)frame;
    }
}

// Same picture in a new buffer, fast enough to sit inside a timed sequence.
JNIEXPORT jlong JNICALL M(copyFrame)(JNIEnv *e,jclass c,jlong source) {
    CVPixelBufferRef from = (CVPixelBufferRef)(uintptr_t)source, to = NULL;
    NSDictionary *attributes = @{(NSString *)kCVPixelBufferIOSurfacePropertiesKey:@{},
        (NSString *)kCVPixelBufferMetalCompatibilityKey:@YES};
    if (CVPixelBufferCreate(NULL, CVPixelBufferGetWidth(from), CVPixelBufferGetHeight(from),
        CVPixelBufferGetPixelFormatType(from), (__bridge CFDictionaryRef)attributes, &to) != kCVReturnSuccess) return 0;
    CVPixelBufferLockBaseAddress(from, kCVPixelBufferLock_ReadOnly);
    CVPixelBufferLockBaseAddress(to, 0);
    for (size_t plane = 0; plane < 2; ++plane) {
        const uint8_t *src = CVPixelBufferGetBaseAddressOfPlane(from, plane);
        uint8_t *dst = CVPixelBufferGetBaseAddressOfPlane(to, plane);
        size_t ss = CVPixelBufferGetBytesPerRowOfPlane(from, plane), ds = CVPixelBufferGetBytesPerRowOfPlane(to, plane);
        size_t rows = CVPixelBufferGetHeightOfPlane(from, plane), bytes = ss < ds ? ss : ds;
        for (size_t y = 0; y < rows; ++y) memcpy(dst + y * ds, src + y * ss, bytes);
    }
    CVPixelBufferUnlockBaseAddress(to, 0);
    CVPixelBufferUnlockBaseAddress(from, kCVPixelBufferLock_ReadOnly);
    return (jlong)(uintptr_t)to;
}

JNIEXPORT void JNICALL M(releaseFrame)(JNIEnv *e,jclass c,jlong ptr) { CVPixelBufferRelease((CVPixelBufferRef)(uintptr_t)ptr); }

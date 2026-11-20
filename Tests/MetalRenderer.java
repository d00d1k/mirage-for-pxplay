package com.grill.streamutils.metal;

import java.lang.reflect.Method;
import java.util.Arrays;
import java.util.concurrent.locks.LockSupport;
import mirage.MirageBridge;

public final class MetalRenderer {
    private long nativeHandle;
    private native long nativeInit(long window, int w, int h, boolean fx, boolean hdr, double scale,
                                   int aspect, float one, float two, boolean extra1, boolean extra2);
    private native boolean nativeSetFrameGeneration(long renderer, boolean enabled);
    private native int nativeDecodeRealFrame(long renderer, long buffer);
    private native boolean nativeRenderInterpolated(long renderer, float phase);
    private native boolean nativePresentLatestReal(long renderer);
    private static native int realCount();
    private native void nativeDispose(long renderer);
    private static native long makeFrame(int width, int height, int shift);
    private static native long makeTexturedFrame(int width, int height, int shift);
    private static native long copyFrame(long frame);
    private static native void releaseFrame(long ptr);
    private static native int generatedCount();
    private static native long lastGeneratedHash();
    private native void nativeSetPerfOverlay(long renderer, boolean visible, boolean share, String text);
    private static native String overlay();

    private record Results(long[] hashes, long[] nanos) {}
    private Results run(long[] buffers, boolean early, long leadNanos, int budget) throws Exception {
        Method select = MirageBridge.class.getDeclaredMethod("selectFG", int.class, int.class, int.class);
        Method setEarly = MirageBridge.class.getDeclaredMethod("setRifePrefetch", boolean.class);
        select.setAccessible(true);
        setEarly.setAccessible(true);
        select.invoke(null, 2, 0, budget);
        setEarly.invoke(null, early);
        if (!nativeSetFrameGeneration(nativeHandle, true)) throw new AssertionError("FG must enable");
        nativeDecodeRealFrame(nativeHandle, buffers[0]);

        // Compilation and first texture allocation are outside the measurement.
        Thread.sleep(2300);
        int warmup = 18, count = 90;
        long[] hashes = new long[count];
        long[] nanos = new long[count];
        for (int frame = 1; frame <= warmup + count; frame++) {
            long arrival = System.nanoTime();
            long current = buffers[frame % buffers.length];
            if (early) MirageBridge.prefetchVideoFrame(this, current);
            waitUntil(arrival + leadNanos);
            long start = System.nanoTime();
            int before = generatedCount();
            nativeDecodeRealFrame(nativeHandle, current);
            if (!nativeRenderInterpolated(nativeHandle, .5f)) throw new AssertionError("no fallback");
            long elapsed = System.nanoTime() - start;
            if (frame > warmup) {
                int offset = frame - warmup - 1;
                if (generatedCount() > before) {
                    hashes[offset] = lastGeneratedHash();
                    nanos[offset] = elapsed;
                }
            }
            waitUntil(arrival + 33_333_333);
        }
        nativeSetFrameGeneration(nativeHandle, false);
        return new Results(hashes, nanos);
    }

    private long verifySkippedInput(long[] frames, boolean prefetched) throws Exception {
        Method select = MirageBridge.class.getDeclaredMethod("selectFG", int.class, int.class, int.class);
        Method setEarly = MirageBridge.class.getDeclaredMethod("setRifePrefetch", boolean.class);
        select.setAccessible(true);
        setEarly.setAccessible(true);
        Method noHud = MirageBridge.class.getDeclaredMethod("setRifeHudProtection", boolean.class);
        noHud.setAccessible(true);
        noHud.invoke(null, false);
        select.invoke(null, 2, 0, 32);
        setEarly.invoke(null, prefetched);
        if (!nativeSetFrameGeneration(nativeHandle, true)) throw new AssertionError("FG must enable");
        nativeDecodeRealFrame(nativeHandle, frames[4]);
        Thread.sleep(2100);
        // Warm both sessions on the same sequence before testing a dropped submission.
        for (int i = 5; i <= 12; i++) {
            nativeDecodeRealFrame(nativeHandle, frames[i]);
            Thread.sleep(50);
            nativeRenderInterpolated(nativeHandle, .5f);
        }
        if (prefetched) {
            MirageBridge.prefetchVideoFrame(this, frames[13]);
            Thread.sleep(70);
        }
        int before = generatedCount();
        nativeDecodeRealFrame(nativeHandle, frames[14]);
        Thread.sleep(70);
        nativeRenderInterpolated(nativeHandle, .5f);
        long hash = generatedCount() > before ? lastGeneratedHash() : 0;
        nativeSetFrameGeneration(nativeHandle, false);
        return hash;
    }

    private void verifyHudLabel(long[] frames) throws Exception {
        Method setHud = MirageBridge.class.getDeclaredMethod("setRifeHudProtection", boolean.class);
        setHud.setAccessible(true);
        setHud.invoke(null, true);
        if (!nativeSetFrameGeneration(nativeHandle, true)) throw new AssertionError("HUD FG must enable");
        nativeDecodeRealFrame(nativeHandle, frames[0]);
        Thread.sleep(2200);
        int before = generatedCount();
        for (int i = 1; i <= 14; i++) {
            MirageBridge.prefetchVideoFrame(this, frames[i]);
            Thread.sleep(12);
            nativeDecodeRealFrame(nativeHandle, frames[i]);
            nativeRenderInterpolated(nativeHandle, .5f);
            Thread.sleep(15);
        }
        nativeSetPerfOverlay(nativeHandle, true, false, "1080p (MetalFX) | RTT: 1ms | FG 2x: 30 -> 60 FPS");
        if (generatedCount() == before || !overlay().contains("Mirage")) {
            throw new AssertionError("HUD did not generate or appear in stats: " + overlay());
        }
        System.out.println("Native HUD display: " + overlay());
        nativeSetFrameGeneration(nativeHandle, false);
        setHud.invoke(null, false);
    }

    private static void waitUntil(long target) {
        for (long remains; (remains = target - System.nanoTime()) > 0; ) LockSupport.parkNanos(remains);
    }

    private static void summarize(String label, Results r) {
        long[] sorted = Arrays.stream(r.nanos()).filter(n -> n > 0).sorted().toArray();
        if (sorted.length == 0) throw new AssertionError("no generated frames for " + label);
        System.out.printf("%s: %d/%d RIFE | median %.2f ms, p95 %.2f ms of simulated presenter work%n",
            label, sorted.length, r.nanos().length, sorted[sorted.length / 2] / 1e6,
            sorted[(int) Math.ceil(sorted.length * .95) - 1] / 1e6);
    }

    private static void parity(Results baseline, Results early) {
        int matched = 0;
        for (int i = 0; i < baseline.hashes().length; i++) {
            long a = baseline.hashes()[i], b = early.hashes()[i];
            if (a == 0 || b == 0) continue;
            if (a != b) throw new AssertionError("NV12 pixel mismatch on pair " + i);
            ++matched;
        }
        System.out.printf("Matches exact NV12 pixel hashes on %d comparable frame pairs%n", matched);
        if (matched < 20) throw new AssertionError("too few matches");
    }

    private static void extrapolation(boolean enabled) throws Exception {
        Method set = MirageBridge.class.getDeclaredMethod("setRifeExtrapolation", boolean.class);
        set.setAccessible(true);
        set.invoke(null, enabled);
    }

    // Extrapolation order: the real frame on the first refresh with no waiting,
    // the prediction from RIFE on the next one.
    private void verifyExtrapolation(long[] frames) throws Exception {
        extrapolation(true);
        Method select = MirageBridge.class.getDeclaredMethod("selectFG", int.class, int.class, int.class);
        Method setEarly = MirageBridge.class.getDeclaredMethod("setRifePrefetch", boolean.class);
        select.setAccessible(true);
        setEarly.setAccessible(true);
        select.invoke(null, 2, 0, 10);
        setEarly.invoke(null, true);
        if (!nativeSetFrameGeneration(nativeHandle, true)) throw new AssertionError("FG must enable");
        nativeDecodeRealFrame(nativeHandle, frames[0]);
        Thread.sleep(2200);
        int predictions = 0, realOnTime = 0, segments = 0;
        long worstRealNs = 0;
        for (int i = 1; i < frames.length; i++) {
            long start = System.nanoTime();
            MirageBridge.prefetchVideoFrame(this, frames[i]);
            nativeDecodeRealFrame(nativeHandle, frames[i]);
            Thread.sleep(3);
            int realBefore = realCount(), generatedBefore = generatedCount();
            long tick = System.nanoTime();
            nativeRenderInterpolated(nativeHandle, .5f);
            long realNs = System.nanoTime() - tick;
            if (realCount() == realBefore + 1 && generatedCount() == generatedBefore) realOnTime++;
            else System.out.printf("real miss at %d: real +%d generated +%d%n", i, realCount() - realBefore, generatedCount() - generatedBefore);
            worstRealNs = Math.max(worstRealNs, realNs);
            waitUntil(start + 19_700_000L);
            int before = generatedCount();
            nativePresentLatestReal(nativeHandle);
            if (generatedCount() == before + 1) predictions++;
            waitUntil(start + 33_333_333L);
            if (i >= 3) segments++;
        }
        nativeSetFrameGeneration(nativeHandle, false);
        extrapolation(false);
        System.out.printf("Extrapolation: real frame first %d/%d (worst %.2f ms), predictions %d/%d%n",
            realOnTime, frames.length - 1, worstRealNs / 1e6, predictions, frames.length - 1);
        if (realOnTime != frames.length - 1 || worstRealNs > 5_000_000L || predictions < (frames.length - 1) * 2 / 3) {
            throw new AssertionError("extrapolation order");
        }
    }

    // One extrapolated segment: real frame on the first refresh, prediction on the second.
    // Returns true when the prediction went out.
    private boolean segment(long frame) throws Exception {
        long start = System.nanoTime();
        MirageBridge.prefetchVideoFrame(this, frame);
        nativeDecodeRealFrame(nativeHandle, frame);
        Thread.sleep(3);
        nativeRenderInterpolated(nativeHandle, .5f);
        waitUntil(start + 19_700_000L);
        int before = generatedCount();
        nativePresentLatestReal(nativeHandle);
        waitUntil(start + 33_333_333L);
        return generatedCount() == before + 1;
    }

    // A game hitch makes the console send the same picture twice. The prediction already
    // on screen must stay there instead of stepping back to the older real frame, and the
    // same when no new frame arrives at all; a genuinely new frame goes out as usual.
    private void verifyHold() throws Exception {
        // 12 px of motion per frame: the prediction visibly moves the picture (holds need >= 2 px).
        long[] frames = new long[20];
        for (int i = 0; i < frames.length; i++) frames[i] = makeTexturedFrame(1920, 1080, i * 12);
        extrapolation(true);
        Method select = MirageBridge.class.getDeclaredMethod("selectFG", int.class, int.class, int.class);
        Method setEarly = MirageBridge.class.getDeclaredMethod("setRifePrefetch", boolean.class);
        select.setAccessible(true);
        setEarly.setAccessible(true);
        select.invoke(null, 2, 0, 10);
        setEarly.invoke(null, true);
        if (!nativeSetFrameGeneration(nativeHandle, true)) throw new AssertionError("FG must enable");
        nativeDecodeRealFrame(nativeHandle, frames[0]);
        Thread.sleep(2200);
        int k = 1;
        boolean predicted = false;
        while (k < 12 && !(predicted = segment(frames[k]))) k++;
        if (!predicted) throw new AssertionError("hold: no prediction to hold");
        for (int extra = 0; extra < 3; extra++) {   // settle into a steady run of predictions
            if (!segment(frames[k + 1])) throw new AssertionError("hold: prediction missed");
            k++;
        }
        long held = lastGeneratedHash();
        long repeat = copyFrame(frames[k]);   // same picture as frames[k], new buffer
        try {
            int real0 = realCount(), gen0 = generatedCount();
            long start = System.nanoTime();
            nativeDecodeRealFrame(nativeHandle, repeat);
            Thread.sleep(3);
            nativeRenderInterpolated(nativeHandle, .5f);
            boolean realSlotHeld = realCount() == real0 && generatedCount() == gen0 + 1 && lastGeneratedHash() == held;
            waitUntil(start + 19_700_000L);
            nativePresentLatestReal(nativeHandle);
            boolean predictionSlotHeld = realCount() == real0 && generatedCount() == gen0 + 2 && lastGeneratedHash() == held;
            waitUntil(start + 33_333_333L);
            nativePresentLatestReal(nativeHandle);         // late: nothing new decoded
            boolean lateHeld = realCount() == real0 && generatedCount() == gen0 + 3 && lastGeneratedHash() == held;
            waitUntil(start + 125_000_000L);              // a pause: the hold expires after 120 ms
            int gen2 = generatedCount();
            nativePresentLatestReal(nativeHandle);
            boolean expired = realCount() == real0 + 1 && generatedCount() == gen2;
            waitUntil(start + 140_000_000L);
            int real1 = realCount();
            long next = System.nanoTime();
            nativeDecodeRealFrame(nativeHandle, frames[k + 1]);
            Thread.sleep(3);
            nativeRenderInterpolated(nativeHandle, .5f);
            boolean newFrameReal = realCount() == real1 + 1;
            waitUntil(next + 19_700_000L);
            int gen1 = generatedCount();
            nativePresentLatestReal(nativeHandle);
            boolean newPrediction = generatedCount() == gen1 + 1 && lastGeneratedHash() != held;
            System.out.printf("Hold: repeated frame keeps prediction (real slot %b, prediction slot %b), late frame %b, "
                + "real frame back after 120 ms %b, next frame real %b, next prediction %b%n",
                realSlotHeld, predictionSlotHeld, lateHeld, expired, newFrameReal, newPrediction);
            if (!(realSlotHeld && predictionSlotHeld && lateHeld && expired && newFrameReal && newPrediction)) {
                throw new AssertionError("hold");
            }
        } finally {
            nativeSetFrameGeneration(nativeHandle, false);
            extrapolation(false);
            releaseFrame(repeat);
            for (long frame : frames) releaseFrame(frame);
        }
    }

    public static void main(String[] args) throws Exception {
        System.load(args[0]);
        extrapolation(false);
        MetalRenderer renderer = new MetalRenderer();
        renderer.nativeHandle = renderer.nativeInit(0, 1920, 1080, true, false, 2, 0, 0, 0, false, false);
        long[] buffers = new long[24];
        for (int i = 0; i < buffers.length; i++) buffers[i] = makeFrame(1920, 1080, i * 2);
        try {
            Results baseline = renderer.run(buffers, false, 12_000_000, 25);
            Results early = renderer.run(buffers, true, 12_000_000, 25);
            summarize("RIFE standard", baseline);
            summarize("RIFE prefetched 12ms", early);
            parity(baseline, early);
            // Run the skipped-pair check with the same two inputs in both modes.
            long expected = renderer.verifySkippedInput(buffers, false);
            long actual = renderer.verifySkippedInput(buffers, true);
            if (expected == 0 || actual != expected) {
                throw new AssertionError("Dropped input check: expected " + expected + ", saw " + actual);
            }
            System.out.println("Dropped prefetched input was replaced by the exact native pair");
            renderer.verifyHudLabel(buffers);
            renderer.verifyExtrapolation(buffers);
            renderer.verifyHold();
        } finally {
            renderer.nativeDispose(renderer.nativeHandle);
            for (long buffer : buffers) releaseFrame(buffer);
        }
    }
}

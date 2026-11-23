import CoreVideo
import Foundation
import Metal
import Vision

/// People mask from Apple's built-in person segmentation (Vision, Neural Engine).
/// Used at the edges of characters: the person is in front, so the prediction keeps the
/// person's own motion inside the mask and the backdrop's outside, instead of the blend RIFE's
/// quarter-resolution flow gives there (the halo around a head while the camera orbits).
/// Runs behind the stream: the mask belongs to an earlier frame (`maskFrame`), which the
/// extrapolation kernel moves along RIFE's motion onto the current one.
///
/// Env (experimental):
///   FGLAB_PERSON_QUALITY = fast | balanced (default) | accurate
///   FGLAB_PERSON_EVERY   = start a new mask every N frames (default 1)
///   FGLAB_PERSON_SYNC=1  = offline: wait for each mask (exactly one frame late, deterministic)
///   FGLAB_PERSON_LAG0=1  = offline oracle: the mask of the current frame itself
final class PersonMask {
    enum Quality: String { case fast, balanced, accurate }

    let quality: Quality
    let every: Int
    let sync: Bool
    let lagZero: Bool
    /// The frame scaled down for Vision (filled by the GPU, kernel personInput).
    let input: CVPixelBuffer
    private let textures: [MTLTexture]   // r8Unorm masks; Vision writes one while the GPU reads the other
    private var readIndex = 0
    var mask: MTLTexture { textures[readIndex] }
    /// Stream frame the readable mask was computed from.
    private(set) var maskFrame: UInt64 = 0
    private var pendingFrame: UInt64 = 0
    private let request: VNGeneratePersonSegmentationRequest
    private let queue = DispatchQueue(label: "local.pxplay.lab.person", qos: .userInteractive)
    private var pending: DispatchGroup?
    private var ok = false
    private var hasResult = false
    private(set) var lastMilliseconds = 0.0

    init?(device: MTLDevice) {
        let env = ProcessInfo.processInfo.environment
        quality = Quality(rawValue: env["FGLAB_PERSON_QUALITY"] ?? "") ?? .balanced
        every = max(1, Int(env["FGLAB_PERSON_EVERY"] ?? "") ?? 1)
        sync = env["FGLAB_PERSON_SYNC"] == "1"
        lagZero = env["FGLAB_PERSON_LAG0"] == "1"
        // Vision's output size depends only on the quality level (4:3, stretched over the frame).
        let (inW, inH, maskW, maskH): (Int, Int, Int, Int)
        switch quality {
        case .fast: (inW, inH, maskW, maskH) = (512, 288, 256, 192)
        case .balanced: (inW, inH, maskW, maskH) = (512, 288, 512, 384)
        case .accurate: (inW, inH, maskW, maskH) = (1024, 576, 2016, 1512)
        }
        var buffer: CVPixelBuffer?
        let attrs = [kCVPixelBufferIOSurfacePropertiesKey as String: [:],
                     kCVPixelBufferMetalCompatibilityKey as String: true] as CFDictionary
        guard CVPixelBufferCreate(nil, inW, inH, kCVPixelFormatType_32BGRA, attrs, &buffer) == kCVReturnSuccess,
              let buffer else { return nil }
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .r8Unorm, width: maskW, height: maskH,
                                                                  mipmapped: false)
        descriptor.usage = [.shaderRead]
        descriptor.storageMode = .shared
        guard let t0 = device.makeTexture(descriptor: descriptor), let t1 = device.makeTexture(descriptor: descriptor) else {
            return nil
        }
        let request = VNGeneratePersonSegmentationRequest()
        request.qualityLevel = quality == .fast ? .fast : quality == .accurate ? .accurate : .balanced
        request.outputPixelFormat = kCVPixelFormatType_OneComponent8
        self.input = buffer
        self.textures = [t0, t1]
        self.request = request
        fputs("[Mirage] person mask: \(quality.rawValue), every \(every), sync \(sync), lag0 \(lagZero)\n", stderr)
    }

    /// Waits for nothing (unless `sync`): reports whether `mask` holds a result.
    func waitIdle() -> Bool {
        if let group = pending, !sync, group.wait(timeout: .now()) == .timedOut { return hasResult }
        finish()
        return hasResult
    }

    /// Blocks until the running request is done and makes its mask readable.
    func finish() {
        guard let group = pending else { return }
        group.wait()
        pending = nil
        if ok {
            readIndex = 1 - readIndex
            maskFrame = pendingFrame
        }
    }

    var busy: Bool {
        guard let group = pending else { return false }
        return group.wait(timeout: .now()) == .timedOut
    }

    func start(frame: UInt64) {
        let group = DispatchGroup()
        group.enter()
        pending = group
        pendingFrame = frame
        ok = false
        let target = textures[1 - readIndex]
        queue.async { [self] in
            defer { group.leave() }
            let t0 = DispatchTime.now().uptimeNanoseconds
            let handler = VNImageRequestHandler(cvPixelBuffer: input, options: [:])
            guard (try? handler.perform([request])) != nil,
                  let out = request.results?.first?.pixelBuffer,
                  CVPixelBufferLockBaseAddress(out, .readOnly) == kCVReturnSuccess else { return }
            defer { CVPixelBufferUnlockBaseAddress(out, .readOnly) }
            let w = CVPixelBufferGetWidth(out), h = CVPixelBufferGetHeight(out)
            guard let base = CVPixelBufferGetBaseAddress(out), w == target.width, h == target.height else {
                fputs("[Mirage] person mask: unexpected size \(w)x\(h)\n", stderr)
                return
            }
            target.replace(region: MTLRegionMake2D(0, 0, w, h), mipmapLevel: 0, withBytes: base,
                           bytesPerRow: CVPixelBufferGetBytesPerRow(out))
            lastMilliseconds = Double(DispatchTime.now().uptimeNanoseconds - t0) / 1e6
            ok = true
            hasResult = true
        }
        if sync { finish() }
    }
}

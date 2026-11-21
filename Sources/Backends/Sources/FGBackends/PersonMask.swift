import CoreVideo
import Foundation
import Metal
import Vision

/// People mask from Apple's built-in person segmentation (Vision, Neural Engine).
/// Used at the edges of characters: the person is in front, so the prediction keeps the
/// person's own motion inside the mask and the backdrop's outside, instead of the blend RIFE's
/// quarter-resolution flow gives there (the halo around a head while the camera orbits).
/// Runs one frame behind, like HudNet: the mask belongs to the previous frame, which the
/// extrapolation kernel moves along RIFE's motion onto the current one.
final class PersonMask {
    static let width = 512, height = 288

    /// The frame scaled down for Vision (filled by the GPU, kernel personInput).
    let input: CVPixelBuffer
    private let textures: [MTLTexture]   // r8Unorm masks; Vision writes one while the GPU reads the other
    private var readIndex = 0
    var mask: MTLTexture { textures[readIndex] }
    private let request: VNGeneratePersonSegmentationRequest
    private let queue = DispatchQueue(label: "local.pxplay.lab.person", qos: .userInteractive)
    private var pending: DispatchGroup?
    private var ok = false
    private var hasResult = false
    private(set) var lastMilliseconds = 0.0

    init?(device: MTLDevice) {
        var buffer: CVPixelBuffer?
        let attrs = [kCVPixelBufferIOSurfacePropertiesKey as String: [:],
                     kCVPixelBufferMetalCompatibilityKey as String: true] as CFDictionary
        guard CVPixelBufferCreate(nil, Self.width, Self.height, kCVPixelFormatType_32BGRA, attrs, &buffer) == kCVReturnSuccess,
              let buffer else { return nil }
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .r8Unorm, width: 512, height: 384,
                                                                  mipmapped: false)
        descriptor.usage = [.shaderRead]
        descriptor.storageMode = .shared
        guard let t0 = device.makeTexture(descriptor: descriptor), let t1 = device.makeTexture(descriptor: descriptor) else {
            return nil
        }
        let request = VNGeneratePersonSegmentationRequest()
        request.qualityLevel = .balanced
        request.outputPixelFormat = kCVPixelFormatType_OneComponent8
        self.input = buffer
        self.textures = [t0, t1]
        self.request = request
    }

    /// Waits for nothing: reports whether `mask` holds a result (from the previous frame).
    func waitIdle() -> Bool {
        if let group = pending, group.wait(timeout: .now()) == .timedOut { return hasResult }
        if let group = pending {
            group.wait()
            pending = nil
            if ok { readIndex = 1 - readIndex }
        }
        return hasResult
    }

    var busy: Bool {
        guard let group = pending else { return false }
        return group.wait(timeout: .now()) == .timedOut
    }

    func start() {
        let group = DispatchGroup()
        group.enter()
        pending = group
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
            let w = min(CVPixelBufferGetWidth(out), target.width), h = min(CVPixelBufferGetHeight(out), target.height)
            guard let base = CVPixelBufferGetBaseAddress(out), w == target.width, h == target.height else { return }
            target.replace(region: MTLRegionMake2D(0, 0, w, h), mipmapLevel: 0, withBytes: base,
                           bytesPerRow: CVPixelBufferGetBytesPerRow(out))
            lastMilliseconds = Double(DispatchTime.now().uptimeNanoseconds - t0) / 1e6
            ok = true
            hasResult = true
        }
    }
}

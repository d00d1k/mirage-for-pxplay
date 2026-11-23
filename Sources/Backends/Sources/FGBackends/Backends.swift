import CoreVideo
import Foundation
import Metal
import RifeMetal
import RifeMetalCore
import VideoToolbox

private enum BackendError: Error {
    case unavailable, allocation, missingFrame, transfer(OSStatus)
}

private func makeBuffer(_ width: Int, _ height: Int) throws -> CVPixelBuffer {
    try PixelBufferConvert.makeOutputPixelBuffer(width: width, height: height)
}

private protocol Interpolator {
    func render(previous: CVPixelBuffer, current: CVPixelBuffer, consecutive: Bool,
                into output: CVPixelBuffer) throws
    var flows: (MTLTexture, MTLTexture)? { get }
}

extension Interpolator {
    var flows: (MTLTexture, MTLTexture)? { nil }
}

private final class Rife: Interpolator {
    private let stream: RifeStream

    init(width: Int, height: Int, profile: Int32, resources: URL) throws {
        let tier: RifeQualityTier = profile == 1 ? .balanced : .fast
        let options = RifeConfiguration(
            modelURL: resources.appendingPathComponent("rife-v4.25.rmw"), qualityTier: tier
        )
        stream = try RifeInterpolator(configuration: options).makeStream(width: width, height: height)
    }

    func render(previous: CVPixelBuffer, current: CVPixelBuffer, consecutive: Bool,
                into output: CVPixelBuffer) throws {
        if !consecutive {
            stream.reset()
            _ = try stream.push(previous, timesteps: [])
        }
        guard try stream.push(current, into: output) else { throw BackendError.missingFrame }
    }

    var flows: (MTLTexture, MTLTexture)? { stream.finalFlowTextures }
}

private final class Backend {
    private let interpolator: Interpolator
    private let io: TurboIO
    private var previousBGRA: CVPixelBuffer
    private var currentBGRA: CVPixelBuffer
    private let generatedBGRA: CVPixelBuffer
    private let extrapolatedBGRA: CVPixelBuffer
    /// 0 = interpolation (midpoint between N-1 and N). >0 = predict this many source frames after N.
    var extrapolationStep: Float = 0
    var extrapolationDamping = 0
    /// Character edges at fast camera moves (see TurboIO.haloMode).
    var haloMode: UInt32 {
        get { io.haloMode }
        set { if io.haloMode != newValue { io.haloMode = newValue } }
    }
    private let protectHud: Bool
    private let pool: CVPixelBufferPool
    /// Neural Engine HUD mask; nil (rules only) when the model is missing or FGLAB_HUDNET=0.
    private let hudNet: HudNet?
    /// Apple's people segmentation for character edges; nil when FGLAB_PERSON=0.
    private let personMask: PersonMask?
    private var personFrame: UInt64 = 0
    private var lastPair: UInt64?
    private var hudPrimed = false
    private let profile = ProcessInfo.processInfo.environment["FGLAB_PROFILE"] == "1"
    private var timings: [Double] = []
    /// Offline analysis only: buffers of the last render, valid until the next one.
    var debugInterpolated: CVPixelBuffer?
    var debugShown: CVPixelBuffer?
    var debugInfo: (SIMD2<Float>, Float, Float, Float, Float) {
        (io.lastMotion, io.lastGain, io.lastResidual, io.lastRaw, io.lastTrust)
    }

    init(engine: Int32, profile: Int32, width: Int, height: Int, pixelFormat: OSType,
         protectHud: Bool, resources: URL) throws {
        interpolator = try Rife(width: width, height: height, profile: profile, resources: resources)
        io = try TurboIO(width: width, height: height, resources: resources)
        previousBGRA = try makeBuffer(width, height)
        currentBGRA = try makeBuffer(width, height)
        generatedBGRA = try makeBuffer(width, height)
        extrapolatedBGRA = try makeBuffer(width, height)
        self.protectHud = protectHud && engine == 2
        if self.protectHud, ProcessInfo.processInfo.environment["FGLAB_HUDNET"] != "0",
           let device = MTLCreateSystemDefaultDevice() {
            hudNet = HudNet(resources: resources, device: device)
        } else {
            hudNet = nil
        }
        if hudNet != nil { fputs("[Mirage] HudNet ready (Neural Engine HUD mask).\n", stderr) }
        // Experimental, off by default (FGLAB_PERSON=1): on GTA VI clips the Vision mask is too
        // coarse and a frame late at a fast orbit, so it chewed heads more than it helped, and it
        // costs ~24 ms of Neural Engine time per frame.
        if ProcessInfo.processInfo.environment["FGLAB_PERSON"] == "1", let device = MTLCreateSystemDefaultDevice() {
            personMask = PersonMask(device: device)
        } else {
            personMask = nil
        }
        let attrs = [
            kCVPixelBufferWidthKey as String: width,
            kCVPixelBufferHeightKey as String: height,
            kCVPixelBufferPixelFormatTypeKey as String: pixelFormat,
            kCVPixelBufferIOSurfacePropertiesKey as String: [:],
            kCVPixelBufferMetalCompatibilityKey as String: true,
        ] as CFDictionary
        var result: CVPixelBufferPool?
        guard CVPixelBufferPoolCreate(nil, nil, attrs, &result) == kCVReturnSuccess,
              let result else { throw BackendError.allocation }
        pool = result
    }

    func render(previous: CVPixelBuffer, current: CVPixelBuffer, pair: UInt64) throws -> CVPixelBuffer {
        let t0 = DispatchTime.now().uptimeNanoseconds
        let consecutive = lastPair.map { $0 + 1 == pair } ?? false
        lastPair = nil
        if consecutive {
            try io.toBGRA([(current, currentBGRA)])
        } else {
            try io.toBGRA([(previous, previousBGRA), (current, currentBGRA)])
        }
        var output: CVPixelBuffer?
        let limit = [kCVPixelBufferPoolAllocationThresholdKey as String: 8] as CFDictionary
        guard CVPixelBufferPoolCreatePixelBufferWithAuxAttributes(nil, pool, limit, &output) == kCVReturnSuccess,
              let output else { throw BackendError.allocation }
        let t1 = DispatchTime.now().uptimeNanoseconds
        // The HUD network runs on the Neural Engine one frame behind: started once this frame
        // is finished (below), so it uses the idle time until the next frame instead of
        // competing with RIFE, and nothing ever waits for it.
        let netReady = hudNet?.waitIdle() ?? false
        personFrame += 1
        var personReady = personMask?.waitIdle() ?? false

        let bypass = ProcessInfo.processInfo.environment["FGLAB_BYPASS"] == "1"
        if !bypass {
            try interpolator.render(previous: previousBGRA, current: currentBGRA, consecutive: consecutive,
                                    into: generatedBGRA)
        }
        let t2 = DispatchTime.now().uptimeNanoseconds
        // Advance the model's stream cache before the presentation-only pass.
        let a = previousBGRA
        let b = currentBGRA
        swap(&previousBGRA, &currentBGRA)
        lastPair = pair
        var shown = bypass ? b : generatedBGRA
        var maskUpdated = false
        // Missing or failed network: the rules alone, exactly as before.
        let netMask = netReady ? hudNet?.mask : nil
        if extrapolationStep > 0, !bypass, let flows = interpolator.flows {
            if !consecutive { io.resetMotionHistory() }
            // Offline oracle: the mask of this very frame (no delay at all).
            if let personMask, personMask.lagZero, consecutive,
               (try? io.preparePerson(current: b, input: personMask.input)) != nil {
                personMask.start(frame: personFrame)
                personMask.finish()
                personReady = personMask.waitIdle()
            }
            // Mask age in stream frames; too old (or across a jump) is not used.
            let personAge = personMask.map { Int(personFrame &- $0.maskFrame) } ?? 0
            let usePerson = personReady && consecutive && personAge <= 4
            maskUpdated = try io.extrapolate(previous: a, current: b, flows: flows, step: extrapolationStep,
                                             damping: extrapolationDamping,
                                             hudReset: protectHud ? !hudPrimed : nil, net: netMask,
                                             person: usePerson ? personMask?.mask : nil, personAge: personAge,
                                             into: extrapolatedBGRA)
            if profile { fputs(String(format: "[Mirage] extrapolation gain %.2f\n", io.lastGain), stderr) }
            shown = extrapolatedBGRA
        }
        try io.compose(generated: shown, previous: a, current: b, currentNV12: current,
                       output: output, protectHud: protectHud, reset: !hudPrimed, updateMask: !maskUpdated,
                       net: netMask)
        hudPrimed = hudPrimed || protectHud
        CVBufferPropagateAttachments(current, output)
        if let hudNet, !hudNet.busy, (try? io.prepareNet(current: b, input: hudNet.input)) != nil {
            hudNet.start()
        }
        if let personMask, !personMask.lagZero, !personMask.busy, personFrame % UInt64(personMask.every) == 0,
           (try? io.preparePerson(current: b, input: personMask.input)) != nil {
            personMask.start(frame: personFrame)
        }
        debugInterpolated = bypass ? nil : generatedBGRA
        debugShown = shown
        if profile {
            let t3 = DispatchTime.now().uptimeNanoseconds
            fputs(String(format: "[Mirage] stages in %.2f model %.2f out %.2f total %.2f ms, hudnet %.2f ms\n",
                         Double(t1 - t0) / 1e6, Double(t2 - t1) / 1e6, Double(t3 - t2) / 1e6,
                         Double(t3 - t0) / 1e6, hudNet?.lastMilliseconds ?? 0), stderr)
            fputs(String(format: "[Mirage] person mask %.2f ms\n", personMask?.lastMilliseconds ?? 0), stderr)
        }
        return output
    }
}

@_cdecl("FGLabBackendCreate")
public func create(_ engine: Int32, _ profile: Int32, _ width: Int32, _ height: Int32, _ pixelFormat: UInt32,
                   _ protectHud: Int32, _ resources: UnsafePointer<CChar>?) -> UnsafeMutableRawPointer? {
    guard let resources, engine == 2 else { return nil }
    do {
        let root = URL(fileURLWithPath: String(cString: resources), isDirectory: true)
        let backend = try Backend(engine: engine, profile: profile, width: Int(width), height: Int(height),
                                  pixelFormat: pixelFormat, protectHud: protectHud != 0, resources: root)
        return Unmanaged.passRetained(backend).toOpaque()
    } catch {
        fputs("[Mirage] Backend setup failed: \(error)\n", stderr)
        return nil
    }
}

@_cdecl("FGLabBackendRender")
public func render(_ handle: UnsafeMutableRawPointer, _ previous: UnsafeRawPointer, _ current: UnsafeRawPointer,
                   _ pair: UInt64) -> UnsafeMutableRawPointer? {
    let backend = Unmanaged<Backend>.fromOpaque(handle).takeUnretainedValue()
    do {
        let frame = try backend.render(previous: Unmanaged<CVPixelBuffer>.fromOpaque(previous).takeUnretainedValue(),
                                       current: Unmanaged<CVPixelBuffer>.fromOpaque(current).takeUnretainedValue(), pair: pair)
        return Unmanaged.passRetained(frame).toOpaque()
    } catch {
        fputs("[Mirage] Frame generation failed: \(error)\n", stderr)
        return nil
    }
}

@_cdecl("FGLabBackendSetExtrapolation")
public func setExtrapolation(_ handle: UnsafeMutableRawPointer, _ step: Float) {
    Unmanaged<Backend>.fromOpaque(handle).takeUnretainedValue().extrapolationStep = step
}

@_cdecl("FGLabBackendSetExtrapolationTuning")
public func setExtrapolationTuning(_ handle: UnsafeMutableRawPointer, _ step: Float, _ damping: Int32) {
    let backend = Unmanaged<Backend>.fromOpaque(handle).takeUnretainedValue()
    backend.extrapolationStep = step
    backend.extrapolationDamping = Int(damping)
}

@_cdecl("FGLabBackendSetHaloMode")
public func setHaloMode(_ handle: UnsafeMutableRawPointer, _ mode: UInt32) {
    Unmanaged<Backend>.fromOpaque(handle).takeUnretainedValue().haloMode = mode
}

@_cdecl("FGLabBackendDestroy")
public func destroy(_ handle: UnsafeMutableRawPointer) {
    Unmanaged<Backend>.fromOpaque(handle).release()
}

/// Offline analysis: out = motion x, motion y (px per source frame), applied gain, warp residual,
/// unwarped difference, cut trust (0 = treated as a cut).
/// interpolated/shown receive unretained BGRA buffers that stay valid until the next render.
@_cdecl("FGLabBackendDebugInfo")
public func debugInfo(_ handle: UnsafeMutableRawPointer, _ out: UnsafeMutablePointer<Float>,
                      _ interpolated: UnsafeMutablePointer<UnsafeMutableRawPointer?>?,
                      _ shown: UnsafeMutablePointer<UnsafeMutableRawPointer?>?) {
    let backend = Unmanaged<Backend>.fromOpaque(handle).takeUnretainedValue()
    let (motion, gain, residual, raw, trust) = backend.debugInfo
    out[0] = motion.x; out[1] = motion.y; out[2] = gain; out[3] = residual; out[4] = raw; out[5] = trust
    interpolated?.pointee = backend.debugInterpolated.map { Unmanaged.passUnretained($0).toOpaque() }
    shown?.pointee = backend.debugShown.map { Unmanaged.passUnretained($0).toOpaque() }
}

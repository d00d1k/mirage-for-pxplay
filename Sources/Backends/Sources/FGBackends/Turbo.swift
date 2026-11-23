import CoreVideo
import Foundation
import Metal
import simd

/// GPU colour conversion and HUD protection in single Metal passes.
/// Replaces two VideoToolbox transfers and the separate HUD command buffer,
/// which each added a CPU/GPU round trip to every generated frame.
final class TurboIO {
    enum Failure: Error { case metal, texture, render }

    private struct ColorParams {
        var kr: Float
        var kb: Float
        var fullRange: UInt32
    }

    private struct HudParams {
        var width: UInt32
        var height: UInt32
        var threshold: Float
        var reset: UInt32
    }

    private let queue: MTLCommandQueue
    private let cache: CVMetalTextureCache
    private let toRGB: MTLComputePipelineState
    private let update: MTLComputePipelineState
    private let compose: MTLComputePipelineState
    private let extrapolate: MTLComputePipelineState
    private let haloFieldPipeline: MTLComputePipelineState
    /// Halo modes: slowest/fastest motion near each 8x8 block and edge strength (haloField).
    private let haloMotion: MTLTexture
    private let haloEdge: MTLTexture
    private let motion: MTLComputePipelineState
    private let refine: MTLComputePipelineState
    private let netInput: MTLComputePipelineState
    private let personInputPipeline: MTLComputePipelineState
    private let layered: MTLComputePipelineState
    /// Sharp per-layer motion at half resolution (see refineMotion in Turbo.metal).
    private let refined: MTLTexture
    private let refinedClean: MTLTexture
    private let clean: MTLComputePipelineState
    /// Edge-aware layered extrapolation (experimental, FGLAB_EDGE=1). Off by default: it
    /// removes the halo around a still character on synthetic scenes (edge error 6.2 -> 2.4)
    /// but on real GTA VI footage, judged against the real in-between game frame, it was
    /// 1-3% worse overall than the plain warp (motion blur and perspective fool the
    /// front/back layer guess). Kept for further work.
    private let edgeAware = ProcessInfo.processInfo.environment["FGLAB_EDGE"] == "1"
    private let edgeDebug = UInt32(ProcessInfo.processInfo.environment["FGLAB_EDGE_DEBUG"] ?? "") ?? 0
    /// Character edges at fast camera moves (HaloParams in Turbo.metal): bits 1 soft, 2 calm,
    /// 4 hero, 8 still, 16 split; 0 = off. Set from the FG settings; FGLAB_HALO_MODE overrides
    /// (offline). Measured on the 21:43 orbit clip against the real in-between game frame
    /// (edge band 8 px inside / 16 px outside a character): soft −0.5% / −1.3%, calm −7% / +1%,
    /// still + soft (25) −10% / +1.5%, still −10% / +4%; on six minutes of ordinary play soft
    /// changed 1 frame for the worse, the others 200-440 of 5388 slightly (half-rate replay,
    /// twice the live motion).
    var haloMode: UInt32 = 0 {
        didSet { if let forced = haloForced { haloMode = forced } }
    }
    private let haloForced = UInt32(ProcessInfo.processInfo.environment["FGLAB_HALO_MODE"] ?? "")
    private let haloLo = Float(ProcessInfo.processInfo.environment["FGLAB_HALO_LO"] ?? "") ?? 10
    private let haloHi = Float(ProcessInfo.processInfo.environment["FGLAB_HALO_HI"] ?? "") ?? 24
    private let haloBlur = Float(ProcessInfo.processInfo.environment["FGLAB_HALO_BLUR"] ?? "") ?? 1.2
    private let blocks: MTLBuffer
    /// Per-block prediction trust for a still camera (see localTrust).
    private let blockTrust: MTLBuffer
    private var anyUntrusted = false
    /// Per-block motion of the previous pair (nil after a reset or a cut).
    private var previousBlocks: [SIMD2<Float>]?
    private static let blocksX = 48, blocksY = 27
    /// Camera motion (px per source frame) measured on the previous pair.
    private var lastCamera: SIMD2<Float>?
    private(set) var lastGain: Float = 1
    /// Camera motion and median warp disagreement of the last pair (diagnostics, cut detection).
    private(set) var lastMotion = SIMD2<Float>(0, 0)
    private(set) var lastResidual: Float = 0
    private(set) var lastRaw: Float = 0
    private(set) var lastTrust: Float = 1
    /// A cut to a new shot (or a full-screen flash) leaves RIFE nothing to match, and the
    /// prediction would shove the first frame of the new shot sideways by up to maxShift for
    /// one refresh. Such pairs show the real frame instead.
    private let cutGuard = ProcessInfo.processInfo.environment["FGLAB_CUT"] != "0"
    /// Crosshair detection and HUD-aware prediction (FGLAB_HUD2=0 restores the old behaviour).
    private let motionHud = ProcessInfo.processInfo.environment["FGLAB_HUD2"] != "0"
    private let still: MTLBuffer
    private let width: Int
    private let height: Int

    init(width: Int, height: Int, resources: URL) throws {
        guard let device = MTLCreateSystemDefaultDevice(), let queue = device.makeCommandQueue() else {
            throw Failure.metal
        }
        var cache: CVMetalTextureCache?
        guard CVMetalTextureCacheCreate(nil, nil, device, nil, &cache) == kCVReturnSuccess,
              let cache else { throw Failure.metal }
        let source = try String(contentsOf: resources.appendingPathComponent("Turbo.metal"), encoding: .utf8)
        let library = try device.makeLibrary(source: source, options: nil)
        guard let a = library.makeFunction(name: "nv12ToBGRA"),
              let b = library.makeFunction(name: "hudUpdate"),
              let c = library.makeFunction(name: "composeNV12"),
              let x = library.makeFunction(name: "extrapolateFrame"),
              let hf = library.makeFunction(name: "haloField"),
              let m = library.makeFunction(name: "motionBlocks"),
              let r = library.makeFunction(name: "refineMotion"),
              let l = library.makeFunction(name: "extrapolateLayered"),
              let k = library.makeFunction(name: "cleanMotion"),
              let n = library.makeFunction(name: "netInput"),
              let pi = library.makeFunction(name: "personInput"),
              let blocks = device.makeBuffer(length: TurboIO.blocksX * TurboIO.blocksY * 16, options: .storageModeShared),
              let blockTrust = device.makeBuffer(length: TurboIO.blocksX * TurboIO.blocksY * 4, options: .storageModeShared),
              let still = device.makeBuffer(length: width * height, options: .storageModePrivate) else {
            throw Failure.metal
        }
        toRGB = try device.makeComputePipelineState(function: a)
        update = try device.makeComputePipelineState(function: b)
        compose = try device.makeComputePipelineState(function: c)
        extrapolate = try device.makeComputePipelineState(function: x)
        haloFieldPipeline = try device.makeComputePipelineState(function: hf)
        let fieldMotion = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba16Float, width: (width + 7) / 8,
                                                                   height: (height + 7) / 8, mipmapped: false)
        fieldMotion.usage = [.shaderRead, .shaderWrite]
        fieldMotion.storageMode = .private
        let fieldEdge = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .r16Float, width: (width + 7) / 8,
                                                                 height: (height + 7) / 8, mipmapped: false)
        fieldEdge.usage = [.shaderRead, .shaderWrite]
        fieldEdge.storageMode = .private
        guard let haloMotion = device.makeTexture(descriptor: fieldMotion),
              let haloEdge = device.makeTexture(descriptor: fieldEdge) else { throw Failure.metal }
        self.haloMotion = haloMotion
        self.haloEdge = haloEdge
        motion = try device.makeComputePipelineState(function: m)
        refine = try device.makeComputePipelineState(function: r)
        layered = try device.makeComputePipelineState(function: l)
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba16Float, width: (width + 1) / 2,
                                                                  height: (height + 1) / 2, mipmapped: false)
        descriptor.usage = [.shaderRead, .shaderWrite]
        descriptor.storageMode = .private
        guard let refined = device.makeTexture(descriptor: descriptor),
              let refinedClean = device.makeTexture(descriptor: descriptor) else { throw Failure.metal }
        self.refined = refined
        self.refinedClean = refinedClean
        clean = try device.makeComputePipelineState(function: k)
        netInput = try device.makeComputePipelineState(function: n)
        personInputPipeline = try device.makeComputePipelineState(function: pi)
        self.blocks = blocks
        self.blockTrust = blockTrust
        self.queue = queue
        self.cache = cache
        self.still = still
        self.width = width
        self.height = height
    }

    private func texture(_ buffer: CVPixelBuffer, plane: Int, format: MTLPixelFormat) throws -> (MTLTexture, CVMetalTexture) {
        let planar = CVPixelBufferIsPlanar(buffer)
        let w = planar ? CVPixelBufferGetWidthOfPlane(buffer, plane) : CVPixelBufferGetWidth(buffer)
        let h = planar ? CVPixelBufferGetHeightOfPlane(buffer, plane) : CVPixelBufferGetHeight(buffer)
        var bound: CVMetalTexture?
        guard CVMetalTextureCacheCreateTextureFromImage(nil, cache, buffer, nil, format, w, h, plane, &bound) == kCVReturnSuccess,
              let bound, let texture = CVMetalTextureGetTexture(bound) else { throw Failure.texture }
        return (texture, bound)
    }

    private func colorParams(_ buffer: CVPixelBuffer) -> ColorParams {
        var kr: Float = 0.2126, kb: Float = 0.0722
        if let matrix = CVBufferCopyAttachment(buffer, kCVImageBufferYCbCrMatrixKey, nil) {
            if CFEqual(matrix, kCVImageBufferYCbCrMatrix_ITU_R_601_4) || CFEqual(matrix, kCVImageBufferYCbCrMatrix_SMPTE_240M_1995) {
                kr = 0.299; kb = 0.114
            } else if CFEqual(matrix, kCVImageBufferYCbCrMatrix_ITU_R_2020) {
                kr = 0.2627; kb = 0.0593
            }
        }
        let full = CVPixelBufferGetPixelFormatType(buffer) == kCVPixelFormatType_420YpCbCr8BiPlanarFullRange
        return ColorParams(kr: kr, kb: kb, fullRange: full ? 1 : 0)
    }

    private func dispatch(_ encoder: MTLComputeCommandEncoder, _ pipeline: MTLComputePipelineState, _ w: Int, _ h: Int) {
        let tw = pipeline.threadExecutionWidth
        let th = max(1, min(8, pipeline.maxTotalThreadsPerThreadgroup / tw))
        encoder.setComputePipelineState(pipeline)
        encoder.dispatchThreads(MTLSize(width: w, height: h, depth: 1),
                                threadsPerThreadgroup: MTLSize(width: tw, height: th, depth: 1))
    }

    private func finish(_ command: MTLCommandBuffer, keeping owners: [CVMetalTexture]) throws {
        command.commit()
        withExtendedLifetime(owners) { command.waitUntilCompleted() }
        guard command.status == .completed else { throw Failure.render }
    }

    /// Writes the HudNet input (frame scaled to 960x540 + 4 black rows) from a BGRA frame.
    func prepareNet(current: CVPixelBuffer, input: MTLBuffer) throws {
        guard let command = queue.makeCommandBuffer(), let encoder = command.makeComputeCommandEncoder() else {
            throw Failure.metal
        }
        let c = try texture(current, plane: 0, format: .bgra8Unorm)
        encoder.setTexture(c.0, index: 0)
        encoder.setBuffer(input, offset: 0, index: 0)
        dispatch(encoder, netInput, HudNet.width, HudNet.height)
        encoder.endEncoding()
        try finish(command, keeping: [c.1])
    }

    /// Writes the Vision input (frame scaled to its size) from a BGRA frame.
    private let personFrontOnly = ProcessInfo.processInfo.environment["FGLAB_PERSON_FRONT"] == "1"
    private let personSoft = ProcessInfo.processInfo.environment["FGLAB_PERSON_FRONT"] == "2"

    func preparePerson(current: CVPixelBuffer, input: CVPixelBuffer) throws {
        guard let command = queue.makeCommandBuffer(), let encoder = command.makeComputeCommandEncoder() else {
            throw Failure.metal
        }
        let c = try texture(current, plane: 0, format: .bgra8Unorm)
        let o = try texture(input, plane: 0, format: .bgra8Unorm)
        encoder.setTexture(c.0, index: 0)
        encoder.setTexture(o.0, index: 1)
        dispatch(encoder, personInputPipeline, o.0.width, o.0.height)
        encoder.endEncoding()
        try finish(command, keeping: [c.1, o.1])
    }

    private func bindNet(_ encoder: MTLComputeCommandEncoder, _ net: MTLBuffer?) {
        var use: UInt32 = net == nil ? 0 : 1
        encoder.setBuffer(net ?? still, offset: 0, index: 3)
        encoder.setBytes(&use, length: MemoryLayout<UInt32>.stride, index: 4)
    }

    /// NV12 frames from the decoder into the BGRA buffers RIFE consumes.
    func toBGRA(_ sources: [(CVPixelBuffer, CVPixelBuffer)]) throws {
        guard let command = queue.makeCommandBuffer(), let encoder = command.makeComputeCommandEncoder() else {
            throw Failure.metal
        }
        var owners: [CVMetalTexture] = []
        for (nv12, bgra) in sources {
            let y = try texture(nv12, plane: 0, format: .r8Unorm)
            let c = try texture(nv12, plane: 1, format: .rg8Unorm)
            let o = try texture(bgra, plane: 0, format: .bgra8Unorm)
            owners += [y.1, c.1, o.1]
            var params = colorParams(nv12)
            encoder.setTexture(y.0, index: 0)
            encoder.setTexture(c.0, index: 1)
            encoder.setTexture(o.0, index: 2)
            encoder.setBytes(&params, length: MemoryLayout<ColorParams>.stride, index: 0)
            dispatch(encoder, toRGB, o.0.width, o.0.height)
        }
        encoder.endEncoding()
        try finish(command, keeping: owners)
    }

    /// Robust camera motion: component-wise median of the block means.
    private func cameraMotion(_ flows: (MTLTexture, MTLTexture), previous: CVPixelBuffer,
                              current: CVPixelBuffer) throws -> SIMD2<Float> {
        guard let command = queue.makeCommandBuffer(), let encoder = command.makeComputeCommandEncoder() else {
            throw Failure.metal
        }
        let a = try texture(previous, plane: 0, format: .bgra8Unorm)
        let b = try texture(current, plane: 0, format: .bgra8Unorm)
        var dims = SIMD4<UInt32>(UInt32(width), UInt32(height), UInt32(Self.blocksX), UInt32(Self.blocksY))
        encoder.setTexture(flows.0, index: 0)
        encoder.setTexture(flows.1, index: 1)
        encoder.setTexture(a.0, index: 2)
        encoder.setTexture(b.0, index: 3)
        encoder.setBuffer(blocks, offset: 0, index: 0)
        encoder.setBytes(&dims, length: MemoryLayout<SIMD4<UInt32>>.stride, index: 1)
        dispatch(encoder, motion, Self.blocksX, Self.blocksY)
        encoder.endEncoding()
        try finish(command, keeping: [a.1, b.1])
        let count = Self.blocksX * Self.blocksY
        let values = blocks.contents().bindMemory(to: SIMD4<Float>.self, capacity: count)
        var xs = [Float](), ys = [Float](), rs = [Float](), ws = [Float]()
        xs.reserveCapacity(count); ys.reserveCapacity(count); rs.reserveCapacity(count); ws.reserveCapacity(count)
        for i in 0..<count { xs.append(values[i].x); ys.append(values[i].y); rs.append(values[i].z); ws.append(values[i].w) }
        xs.sort(); ys.sort(); rs.sort(); ws.sort()
        lastResidual = rs[count / 2]
        lastRaw = ws[count / 2]
        lastMotion = SIMD2(xs[count / 2], ys[count / 2])
        localTrust(values)
        return lastMotion
    }

    /// Damping: a game camera eases out over a few frames. When the measured camera
    /// speed along its previous direction drops, scale the prediction by the same ratio
    /// (the next step is expected to be slower still); a reversal predicts nothing.
    /// mode: 0 off, 1 soft (ratio), 2 strong (ratio squared).
    private func dampingGain(now: SIMD2<Float>, mode: Int) -> Float {
        defer { lastCamera = now }
        guard mode > 0, let previous = lastCamera else { return 1 }
        let previousSpeed2 = simd_dot(previous, previous)
        guard previousSpeed2 > 2.25 else { return 1 }  // under 1.5 px/frame: no trend to read
        let ratio = simd_dot(now, previous) / previousSpeed2
        if ratio <= 0 { return 0 }
        let gain = min(1, ratio)
        return mode == 2 ? gain * gain : gain
    }

    func resetMotionHistory() { lastCamera = nil; previousBlocks = nil }

    /// With the camera (nearly) still, a block whose change the warp cannot explain is a
    /// menu highlight jumping between slots, text being replaced, a UI panel popping in.
    /// RIFE still invents a motion for it and the prediction would fling it sideways, so
    /// such blocks and their neighbours keep the real frame. Only for a truly still picture
    /// (menus measure ~0.02 px): a camera following a boat or a car at 1-2 px per frame is
    /// left alone, its waving arms and splashes are better predicted than frozen.
    ///
    /// Second rule, for a camera at rest (< 1 px): a block that was at rest in the previous
    /// pair and now moves by more than 2 px started moving this very frame. That is how menu
    /// highlights travel (one item down in a single frame, RIFE reads it as plain motion),
    /// while people and cars move continuously. Such a jump is not continued; something that
    /// really starts to move only misses its prediction for that one frame.
    private func localTrust(_ values: UnsafeMutablePointer<SIMD4<Float>>) {
        let bx = Self.blocksX, by = Self.blocksY
        let count = bx * by
        let trust = blockTrust.contents().bindMemory(to: Float.self, capacity: count)
        for i in 0..<count { trust[i] = 1 }
        anyUntrusted = false
        let before = previousBlocks
        previousBlocks = (0..<count).map { SIMD2(values[$0].x, values[$0].y) }
        let camera = simd_length(lastMotion)
        guard motionHud, camera < 1 else { return }
        func distrust(_ x: Int, _ y: Int) {
            anyUntrusted = true
            for ny in max(0, y - 1)...min(by - 1, y + 1) {
                for nx in max(0, x - 1)...min(bx - 1, x + 1) { trust[ny * bx + nx] = 0 }
            }
        }
        for y in 0..<by {
            for x in 0..<bx {
                let v = values[y * bx + x]
                if camera < 0.5, v.z > 0.03, v.z > 0.7 * v.w {
                    distrust(x, y)
                } else if let before, simd_length(SIMD2(v.x, v.y) - lastMotion) > 2,
                          simd_length(before[y * bx + x] - lastMotion) < 0.75 {
                    distrust(x, y)
                }
            }
        }
    }

    /// Tuned on 9 min of PS5 GTA VI captures: steady fast camera turns (up to 115 px per
    /// frame, mid-shootout) keep the ratio at or below 0.57, cuts sit at 0.75-1.1.
    private func isCut(residual: Float, raw: Float) -> Bool {
        residual > 0.02 && residual > 0.65 * raw
    }

    /// Predicts the frame `step` source frames after `current` from RIFE's midpoint flows.
    /// Runs the HUD mask update (with crosshair detection) first so the prediction can avoid
    /// dragging overlay pixels; compose then reuses the mask without updating it again.
    /// Returns true when the mask was updated here.
    @discardableResult
    func extrapolate(previous: CVPixelBuffer, current: CVPixelBuffer, flows: (MTLTexture, MTLTexture),
                     step: Float, damping: Int, hudReset: Bool?, net: MTLBuffer? = nil,
                     person: MTLTexture? = nil, personAge: Int = 1, into output: CVPixelBuffer) throws -> Bool {
        var gain = dampingGain(now: try cameraMotion(flows, previous: previous, current: current), mode: damping)
        let trust: Float = cutGuard && isCut(residual: lastResidual, raw: lastRaw) ? 0 : 1
        lastTrust = trust
        if trust <= 0 { lastCamera = nil; previousBlocks = nil }  // a new shot starts a new motion history
        gain *= trust
        lastGain = gain
        let step = step * gain
        guard let command = queue.makeCommandBuffer(), let encoder = command.makeComputeCommandEncoder() else {
            throw Failure.metal
        }
        let c = try texture(current, plane: 0, format: .bgra8Unorm)
        let o = try texture(output, plane: 0, format: .bgra8Unorm)
        let a = try texture(previous, plane: 0, format: .bgra8Unorm)
        var owners = [c.1, o.1, a.1]
        var hud = HudParams(width: UInt32(width), height: UInt32(height), threshold: 0.035,
                            reset: hudReset == true ? 1 : 0)
        let updated = hudReset != nil && motionHud
        // Halo modes: the edge field first; it only reads the flows, so the HUD update runs
        // after it without a barrier in between, and one barrier covers both.
        struct HaloParams { var mode: UInt32; var lo: Float; var hi: Float; var blur: Float; var camera: SIMD2<Float> }
        var halo = HaloParams(mode: step > 0 && !edgeAware ? haloForced ?? haloMode : 0, lo: haloLo,
                              hi: max(haloHi, haloLo + 1), blur: haloBlur, camera: lastMotion)
        if halo.mode != 0 {
            var fieldStep = step
            encoder.setTexture(flows.0, index: 0)
            encoder.setTexture(flows.1, index: 1)
            encoder.setTexture(haloMotion, index: 2)
            encoder.setTexture(haloEdge, index: 3)
            encoder.setBytes(&halo, length: MemoryLayout<HaloParams>.stride, index: 0)
            encoder.setBytes(&fieldStep, length: MemoryLayout<Float>.stride, index: 1)
            dispatch(encoder, haloFieldPipeline, haloMotion.width, haloMotion.height)
        }
        if updated {
            var reticle: UInt32 = 1
            encoder.setTexture(a.0, index: 0)
            encoder.setTexture(c.0, index: 1)
            encoder.setTexture(flows.0, index: 2)
            encoder.setTexture(flows.1, index: 3)
            encoder.setBuffer(still, offset: 0, index: 0)
            encoder.setBytes(&hud, length: MemoryLayout<HudParams>.stride, index: 1)
            encoder.setBytes(&reticle, length: MemoryLayout<UInt32>.stride, index: 2)
            bindNet(encoder, net)
            dispatch(encoder, update, width, height)
        }
        if updated && halo.mode != 0 {
            encoder.memoryBarrier(scope: [.buffers, .textures])
        } else if updated {
            encoder.memoryBarrier(scope: .buffers)
        } else if halo.mode != 0 {
            encoder.memoryBarrier(scope: .textures)
        }
        var avoidHud: UInt32 = updated ? 1 : 0
        if edgeAware && step > 0 {
            var camera = lastMotion
            encoder.setTexture(a.0, index: 0)
            encoder.setTexture(c.0, index: 1)
            encoder.setTexture(flows.0, index: 2)
            encoder.setTexture(flows.1, index: 3)
            encoder.setTexture(refined, index: 4)
            encoder.setBytes(&camera, length: MemoryLayout<SIMD2<Float>>.stride, index: 0)
            dispatch(encoder, refine, refined.width, refined.height)
            encoder.memoryBarrier(scope: .textures)
            encoder.setTexture(refined, index: 0)
            encoder.setTexture(refinedClean, index: 1)
            encoder.setBytes(&camera, length: MemoryLayout<SIMD2<Float>>.stride, index: 0)
            dispatch(encoder, clean, refined.width, refined.height)
            encoder.memoryBarrier(scope: .textures)
            struct LayerParams { var step: Float; var maxShift: Float; var camera: SIMD2<Float>; var debug: UInt32 }
            var params = LayerParams(step: step, maxShift: 96, camera: lastMotion, debug: edgeDebug)
            encoder.setTexture(c.0, index: 0)
            encoder.setTexture(refinedClean, index: 1)
            encoder.setTexture(o.0, index: 2)
            encoder.setTexture(flows.0, index: 3)
            encoder.setTexture(flows.1, index: 4)
            encoder.setBytes(&params, length: MemoryLayout<LayerParams>.stride, index: 0)
        } else {
            struct ExtrapParams { var step: Float; var maxShift: Float }
            var params = ExtrapParams(step: step, maxShift: 96)
            encoder.setTexture(c.0, index: 0)
            encoder.setTexture(flows.0, index: 1)
            encoder.setTexture(flows.1, index: 2)
            encoder.setTexture(o.0, index: 3)
            encoder.setBytes(&params, length: MemoryLayout<ExtrapParams>.stride, index: 0)
        }
        encoder.setBuffer(still, offset: 0, index: 1)
        encoder.setBytes(&hud, length: MemoryLayout<HudParams>.stride, index: 2)
        encoder.setBytes(&avoidHud, length: MemoryLayout<UInt32>.stride, index: 3)
        var grid = SIMD4<UInt32>(UInt32(width), UInt32(height),
                                 anyUntrusted ? UInt32(Self.blocksX) : 0, UInt32(Self.blocksY))
        encoder.setBuffer(blockTrust, offset: 0, index: 4)
        encoder.setBytes(&grid, length: MemoryLayout<SIMD4<UInt32>>.stride, index: 5)
        // 0 = off, else 1 + the mask's age in frames (the kernel moves it that many frames on).
        var usePerson: UInt32 = person == nil ? 0 : 1 + UInt32(min(254, max(0, personAge)))
        if person != nil, personFrontOnly { usePerson |= 256 }
        if person != nil, personSoft { usePerson |= 512 }
        encoder.setTexture(person ?? c.0, index: 4)
        encoder.setBytes(&usePerson, length: MemoryLayout<UInt32>.stride, index: 6)
        encoder.setBytes(&halo, length: MemoryLayout<HaloParams>.stride, index: 7)
        encoder.setTexture(haloMotion, index: 5)
        encoder.setTexture(haloEdge, index: 6)
        dispatch(encoder, edgeAware && step > 0 ? layered : extrapolate, o.0.width, o.0.height)
        encoder.endEncoding()
        try finish(command, keeping: owners)
        return updated
    }

    /// Generated BGRA -> NV12 output, with stable HUD pixels taken from the real frame.
    func compose(generated: CVPixelBuffer, previous: CVPixelBuffer, current: CVPixelBuffer,
                 currentNV12: CVPixelBuffer, output: CVPixelBuffer, protectHud: Bool, reset: Bool,
                 updateMask: Bool = true, net: MTLBuffer? = nil) throws {
        guard let command = queue.makeCommandBuffer(), let encoder = command.makeComputeCommandEncoder() else {
            throw Failure.metal
        }
        let g = try texture(generated, plane: 0, format: .bgra8Unorm)
        let cy = try texture(currentNV12, plane: 0, format: .r8Unorm)
        let cc = try texture(currentNV12, plane: 1, format: .rg8Unorm)
        let oy = try texture(output, plane: 0, format: .r8Unorm)
        let oc = try texture(output, plane: 1, format: .rg8Unorm)
        var owners = [g.1, cy.1, cc.1, oy.1, oc.1]
        var hud = HudParams(width: UInt32(width), height: UInt32(height), threshold: 0.035, reset: reset ? 1 : 0)
        if protectHud && updateMask {
            let a = try texture(previous, plane: 0, format: .bgra8Unorm)
            let b = try texture(current, plane: 0, format: .bgra8Unorm)
            owners += [a.1, b.1]
            var reticle: UInt32 = 0
            encoder.setTexture(a.0, index: 0)
            encoder.setTexture(b.0, index: 1)
            encoder.setTexture(a.0, index: 2)  // flow slots unused without the reticle test
            encoder.setTexture(b.0, index: 3)
            encoder.setBuffer(still, offset: 0, index: 0)
            encoder.setBytes(&hud, length: MemoryLayout<HudParams>.stride, index: 1)
            encoder.setBytes(&reticle, length: MemoryLayout<UInt32>.stride, index: 2)
            bindNet(encoder, net)
            dispatch(encoder, update, width, height)
            encoder.memoryBarrier(scope: .buffers)
        }
        var color = colorParams(currentNV12)
        var protect: UInt32 = protectHud ? 1 : 0
        encoder.setTexture(g.0, index: 0)
        encoder.setTexture(cy.0, index: 1)
        encoder.setTexture(cc.0, index: 2)
        encoder.setTexture(oy.0, index: 3)
        encoder.setTexture(oc.0, index: 4)
        encoder.setBuffer(still, offset: 0, index: 0)
        encoder.setBytes(&hud, length: MemoryLayout<HudParams>.stride, index: 1)
        encoder.setBytes(&color, length: MemoryLayout<ColorParams>.stride, index: 2)
        encoder.setBytes(&protect, length: MemoryLayout<UInt32>.stride, index: 3)
        dispatch(encoder, compose, oc.0.width, oc.0.height)
        encoder.endEncoding()
        try finish(command, keeping: owners)
    }
}

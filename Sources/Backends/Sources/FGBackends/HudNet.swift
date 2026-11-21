import CoreML
import CoreVideo
import Foundation
import Metal

/// HUD mask from a small network on the Neural Engine (trained in l/work/pxplay-hudnet).
/// Input: the frame scaled to 960x540 plus 4 black rows (`input`, filled by the GPU).
/// Output: per-pixel HUD probability at 960x544, copied into `mask` (Float16) for the GPU.
/// Runs on its own queue so it overlaps RIFE on the GPU.
final class HudNet {
    static let width = 960, height = 544

    private let model: MLModel
    /// Planar float16 RGB, 3 x 544 x 960, written by the GPU (netInput) and read by Core ML.
    let input: MTLBuffer
    private let inputArray: MLMultiArray
    /// Two masks: the network writes one while the GPU reads the other (`mask`).
    private let masks: [MTLBuffer]
    private var readIndex = 0
    var mask: MTLBuffer { masks[readIndex] }
    private let queue = DispatchQueue(label: "local.pxplay.lab.hudnet", qos: .userInteractive)
    private var pending: DispatchGroup?
    private var ok = false
    private(set) var lastMilliseconds = 0.0
    /// Core ML writes the result straight into `mask` when it accepts this backing.
    private var backings: [MLMultiArray]?
    private var hasResult = false
    private let debug = ProcessInfo.processInfo.environment["FGLAB_HUDNET_DEBUG"] == "1"
    private var runs = 0

    private func report(_ index: Int, _ how: String) {
        runs += 1
        guard runs % 60 == 1 else { return }
        let p = masks[index].contents().bindMemory(to: Float16.self, capacity: Self.width * Self.height)
        var hud = 0, maxv: Float = 0
        for i in 0..<(Self.width * Self.height) { let v = Float(p[i]); if v > 0.5 { hud += 1 }; maxv = max(maxv, v) }
        fputs(String(format: "[Mirage] HudNet %@ run %d: %.2f%% HUD, max %.2f, %.2f ms\n", how, runs,
                     100 * Double(hud) / Double(Self.width * Self.height), maxv, lastMilliseconds), stderr)
    }

    init?(resources: URL, device: MTLDevice) {
        let url = resources.appendingPathComponent("HudNet.mlmodelc")
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        let config = MLModelConfiguration()
        config.computeUnits = .cpuAndNeuralEngine
        guard let model = try? MLModel(contentsOf: url, configuration: config) else {
            fputs("[Mirage] HudNet: model failed to load\n", stderr)
            return nil
        }
        let plane = Self.width * Self.height
        guard let buffer = device.makeBuffer(length: 3 * plane * 2, options: .storageModeShared),
              let array = try? MLMultiArray(dataPointer: buffer.contents(),
                                            shape: [1, 3, Self.height as NSNumber, Self.width as NSNumber],
                                            dataType: .float16,
                                            strides: [3 * plane as NSNumber, plane as NSNumber, Self.width as NSNumber, 1]),
              let m0 = device.makeBuffer(length: Self.width * Self.height * 2, options: .storageModeShared),
              let m1 = device.makeBuffer(length: Self.width * Self.height * 2, options: .storageModeShared) else {
            return nil
        }
        memset(m0.contents(), 0, m0.length)
        memset(m1.contents(), 0, m1.length)
        self.model = model
        self.input = buffer
        self.inputArray = array
        self.masks = [m0, m1]
        let shape: [NSNumber] = [1, 1, Self.height as NSNumber, Self.width as NSNumber]
        let strides: [NSNumber] = [plane as NSNumber, plane as NSNumber, Self.width as NSNumber, 1]
        if let b0 = try? MLMultiArray(dataPointer: m0.contents(), shape: shape, dataType: .float16, strides: strides),
           let b1 = try? MLMultiArray(dataPointer: m1.contents(), shape: shape, dataType: .float16, strides: strides) {
            backings = [b0, b1]
        }
    }

    /// One frame behind: waits for the previous run (normally long finished, since a frame
    /// arrives every 33 ms) and reports whether `mask` holds a usable result. The caller then
    /// writes the new input and calls start(). RIFE never waits for the network; the HUD does
    /// not move in 33 ms, and what does change (menus) the stillness rules still catch.
    func waitIdle() -> Bool {
        if let group = pending, group.wait(timeout: .now()) == .timedOut {
            return hasResult   // still running: keep the last mask, never stall the frame
        }
        _ = wait()
        return hasResult
    }

    /// True while a run is in flight (its input must not be rewritten).
    var busy: Bool {
        guard let group = pending else { return false }
        return group.wait(timeout: .now()) == .timedOut
    }

    /// Starts the network on `input` (already written for the current frame).
    func start() {
        let group = DispatchGroup()
        group.enter()
        pending = group
        ok = false
        let target = 1 - readIndex
        queue.async { [self] in
            defer { group.leave() }
            let t0 = DispatchTime.now().uptimeNanoseconds
            let features = try? MLDictionaryFeatureProvider(dictionary: ["frame": MLFeatureValue(multiArray: inputArray)])
            if let backings, let features {
                let options = MLPredictionOptions()
                options.outputBackings = ["hud": backings[target]]
                do {
                    _ = try model.prediction(from: features, options: options)
                    lastMilliseconds = Double(DispatchTime.now().uptimeNanoseconds - t0) / 1e6
                    if debug { report(target, "backing") }
                    ok = true
                    hasResult = true
                    return
                } catch {
                    if debug { fputs("[Mirage] HudNet backing refused: \(error)\n", stderr) }
                }
                self.backings = nil   // layout not accepted: copy from now on
            }
            guard let features, let result = try? model.prediction(from: features),
                  let out = result.featureValue(for: "hud")?.multiArrayValue,
                  out.shape.count == 4, out.shape[2].intValue == Self.height, out.shape[3].intValue == Self.width else {
                return
            }
            let rowStride = out.strides[2].intValue, colStride = out.strides[3].intValue
            let dst = masks[target].contents().bindMemory(to: Float16.self, capacity: Self.width * Self.height)
            switch out.dataType {
            case .float16:
                out.withUnsafeBufferPointer(ofType: Float16.self) { src in
                    for y in 0..<Self.height {
                        for x in 0..<Self.width { dst[y * Self.width + x] = src[y * rowStride + x * colStride] }
                    }
                }
            case .float32:
                out.withUnsafeBufferPointer(ofType: Float.self) { src in
                    for y in 0..<Self.height {
                        for x in 0..<Self.width { dst[y * Self.width + x] = Float16(src[y * rowStride + x * colStride]) }
                    }
                }
            default:
                return
            }
            lastMilliseconds = Double(DispatchTime.now().uptimeNanoseconds - t0) / 1e6
            if debug { report(target, "copy") }
            ok = true
            hasResult = true
        }
    }

    /// Waits for the run started by `start()`; true when `mask` holds its result.
    func wait() -> Bool {
        guard let group = pending else { return false }
        group.wait()
        pending = nil
        if ok { readIndex = 1 - readIndex }   // the fresh mask becomes the one the GPU reads
        return ok
    }
}

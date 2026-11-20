import Foundation
import CryptoKit
import CoreVideo
import RifeMetalCore

public final class RifeInterpolator: @unchecked Sendable {

    private let context: InferenceContext
    private let weights: WeightStore
    private let airDiagnosticActualModelURL: URL
    private let airDiagnosticOverrideApplied: Bool
    private let qualityTier: RifeQualityTier
    private let experimentOptions: RifeExperimentOptions
    internal let queue = DispatchQueue(label: "rife.metal.interpolator", qos: .userInitiated)
    internal var graph: IFNetGraph?
    private var graphResolution: (Int, Int)?


    /// Caller serializes begin/read with makeStream/interpolate/push on its existing executor.
    public func airServiceTraceBegin(jobID: UInt64, stage: UInt32) {
        context.airServiceTraceCollector?.begin(jobID: jobID, stage: stage)
    }

    public var airServiceTraceCount: Int { context.airServiceTraceCollector?.count ?? 0 }

    public func airServiceTraceRecord(at index: Int) -> AirServiceTraceRecord {
        context.airServiceTraceCollector?.record(at: index) ?? .init()
    }

    public var airServiceTraceOverflow: UInt64 { context.airServiceTraceCollector?.overflow ?? 0 }

    // AIR_SERVICE_MODEL_IDENTITY_BEGIN
    public var airDiagnosticModelIdentity: [String: Any] {
        ["stageCount": weights.header.scaleList.count,
         "graphID": weights.header.graphID.map { $0 as Any } ?? NSNull(),
         "model": weights.header.model,
         "tensorCount": weights.header.tensors.count,
         "containerVersion": weights.containerVersion,
         "actualModelPath": airDiagnosticActualModelURL.path,
         "sha256": weights.airDiagnosticSourceSHA256,
         "overrideApplied": airDiagnosticOverrideApplied]
    }
    // AIR_SERVICE_MODEL_IDENTITY_END

    public init(configuration: RifeConfiguration) throws {
        let airSelection = try airSelectDiagnosticModel(configuration: configuration)
        self.airDiagnosticActualModelURL = airSelection.url
        self.airDiagnosticOverrideApplied = airSelection.overridden
        do {
            self.context = try InferenceContext(preferredDevice: configuration.preferredDevice)
        } catch {
            throw RifeError.metalUnavailable
        }

        do {
            let loaded = try WeightStore(url: airSelection.url)
            if airSelection.overridden {
                guard loaded.airDiagnosticSourceSHA256 == "729ea555016da98e207bc4570e0be81dddbbd37302f7330c89696da798fba22d",
                      loaded.containerVersion == 2,
                      loaded.header.graphID == "odf-ifnet425-fourstage-acc-v1",
                      loaded.header.model == "odf-ifnet425-fourstage-acc-v1",
                      loaded.header.maskUpdate == "accumulate",
                      loaded.header.scaleList == [16, 8, 4, 2],
                      loaded.header.ifblockChannels == [192, 128, 96, 64],
                      loaded.header.tensors.count == 128 else {
                    throw RifeError.modelLoadFailed("four-stage diagnostic actual loaded model identity mismatch")
                }
            }
            self.weights = loaded
        } catch {
            throw RifeError.modelLoadFailed(String(describing: error))
        }

        self.qualityTier = configuration.qualityTier
        self.experimentOptions = configuration.experimentOptions
    }

    public func interpolate(previous: CVPixelBuffer,
                            current:  CVPixelBuffer) throws -> CVPixelBuffer {
        let results = try interpolate(previous: previous, current: current, timesteps: [0.5])
        return results[0]
    }

    public func interpolate(previous: CVPixelBuffer,
                            current:  CVPixelBuffer,
                            timesteps: [Float]) throws -> [CVPixelBuffer] {
        guard !timesteps.isEmpty else {
            throw RifeError.invalidTimesteps("timesteps must not be empty")
        }
        for t in timesteps {
            guard t > 0.0, t < 1.0 else {
                throw RifeError.invalidTimesteps("timestep \(t) is out of (0, 1)")
            }
        }

        let prevW = CVPixelBufferGetWidth(previous)
        let prevH = CVPixelBufferGetHeight(previous)
        let currW = CVPixelBufferGetWidth(current)
        let currH = CVPixelBufferGetHeight(current)
        guard prevW == currW, prevH == currH else { throw RifeError.dimensionMismatch }

        let prevFmt = CVPixelBufferGetPixelFormatType(previous)
        let currFmt = CVPixelBufferGetPixelFormatType(current)
        let allowed: Set<OSType> = [kCVPixelFormatType_32BGRA, kCVPixelFormatType_32RGBA]
        guard allowed.contains(prevFmt), allowed.contains(currFmt) else {
            throw RifeError.unsupportedPixelFormat(prevFmt)
        }

        return try queue.sync {
            let padMul = qualityTier.paddingMultiple
            let paddedW = ((prevW + padMul - 1) / padMul) * padMul
            let paddedH = ((prevH + padMul - 1) / padMul) * padMul
            let needsPad = (paddedW != prevW) || (paddedH != prevH)

            let g = try ensureGraph(width: paddedW, height: paddedH)
            let prevPadded = try inputForGraph(previous, needsPad: needsPad, paddedW: paddedW, paddedH: paddedH)
            let currPadded = try inputForGraph(current, needsPad: needsPad, paddedW: paddedW, paddedH: paddedH)
            let directCrop = needsPad && g.usesDirectCroppedReturn

            var results: [CVPixelBuffer] = []
            results.reserveCapacity(timesteps.count)
            for t in timesteps {
                let outPadded: CVPixelBuffer
                do {
                    outPadded = try PixelBufferConvert.makeOutputPixelBuffer(
                        width: directCrop ? prevW : paddedW, height: directCrop ? prevH : paddedH)
                } catch {
                    throw RifeError.inferenceFailed(String(describing: error))
                }
                do {
                    try g.run(previous: prevPadded, current: currPadded,
                              output: outPadded, timestep: t)
                } catch {
                    throw RifeError.inferenceFailed(String(describing: error))
                }
                if needsPad && !directCrop {
                    do {
                        let cropped = try cropPixelBufferForStream(outPadded, width: prevW, height: prevH)
                        results.append(cropped)
                    } catch {
                        throw RifeError.inferenceFailed(String(describing: error))
                    }
                } else {
                    results.append(outPadded)
                }
            }
            return results
        }
    }

    public func interpolate(previous: CVPixelBuffer,
                            current:  CVPixelBuffer,
                            output:   CVPixelBuffer) throws {
        let prevW = CVPixelBufferGetWidth(previous)
        let prevH = CVPixelBufferGetHeight(previous)
        let currW = CVPixelBufferGetWidth(current)
        let currH = CVPixelBufferGetHeight(current)
        let outW  = CVPixelBufferGetWidth(output)
        let outH  = CVPixelBufferGetHeight(output)
        guard prevW == currW, prevH == currH, prevW == outW, prevH == outH else {
            throw RifeError.dimensionMismatch
        }

        let prevFmt = CVPixelBufferGetPixelFormatType(previous)
        let currFmt = CVPixelBufferGetPixelFormatType(current)
        let outFmt  = CVPixelBufferGetPixelFormatType(output)
        let allowed: Set<OSType> = [kCVPixelFormatType_32BGRA, kCVPixelFormatType_32RGBA]
        guard allowed.contains(prevFmt), allowed.contains(currFmt), allowed.contains(outFmt) else {
            throw RifeError.unsupportedPixelFormat(prevFmt)
        }

        try queue.sync {
            let padMul  = qualityTier.paddingMultiple
            let paddedW = ((prevW + padMul - 1) / padMul) * padMul
            let paddedH = ((prevH + padMul - 1) / padMul) * padMul

            let needsPad = (paddedW != prevW) || (paddedH != prevH)
            let g = try ensureGraph(width: paddedW, height: paddedH)
            let prevPadded = try inputForGraph(previous, needsPad: needsPad, paddedW: paddedW, paddedH: paddedH)
            let currPadded = try inputForGraph(current, needsPad: needsPad, paddedW: paddedW, paddedH: paddedH)
            let directCrop = needsPad && g.supportsCroppedOutput
                && outFmt == kCVPixelFormatType_32BGRA && CVPixelBufferGetIOSurface(output) != nil
            let outPadded = needsPad && !directCrop
                ? try PixelBufferConvert.makeOutputPixelBuffer(width: paddedW, height: paddedH) : output
            do {
                try g.run(previous: prevPadded, current: currPadded, output: outPadded)
            } catch {
                throw RifeError.inferenceFailed(String(describing: error))
            }

            if needsPad && !directCrop {
                do {
                    try cropPixelBufferForStream(outPadded, into: output)
                } catch {
                    throw RifeError.inferenceFailed(String(describing: error))
                }
            }
        }
    }

    private func inputForGraph(_ frame: CVPixelBuffer, needsPad: Bool,
                               paddedW: Int, paddedH: Int) throws -> CVPixelBuffer {
        if !needsPad || (experimentOptions.gpuIO
            && CVPixelBufferGetPixelFormatType(frame) == kCVPixelFormatType_32BGRA
            && CVPixelBufferGetIOSurface(frame) != nil) { return frame }
        do {
            return try padPixelBufferForStream(frame, paddedW: paddedW, paddedH: paddedH)
        } catch {
            throw RifeError.inferenceFailed(String(describing: error))
        }
    }

    internal func padPixelBufferForStream(_ buffer: CVPixelBuffer,
                                          paddedW: Int,
                                          paddedH: Int,
                                          reusing destination: CVPixelBuffer? = nil) throws -> CVPixelBuffer {
        let srcW = CVPixelBufferGetWidth(buffer)
        let srcH = CVPixelBufferGetHeight(buffer)
        if srcW == paddedW && srcH == paddedH { return buffer }

        let attrs: [String: Any] = [
            kCVPixelBufferPixelFormatTypeKey as String: Int(kCVPixelFormatType_32BGRA),
            kCVPixelBufferWidthKey as String: paddedW,
            kCVPixelBufferHeightKey as String: paddedH,
            kCVPixelBufferMetalCompatibilityKey as String: true,
            kCVPixelBufferIOSurfacePropertiesKey as String: [:] as [String: Any],
        ]
        var dst = destination
        let err = dst == nil ? CVPixelBufferCreate(kCFAllocatorDefault,
                                      paddedW, paddedH,
                                      kCVPixelFormatType_32BGRA,
                                      attrs as CFDictionary, &dst) : kCVReturnSuccess
        guard err == kCVReturnSuccess, let dst else {
            throw RifeError.inferenceFailed("padPixelBuffer: CVPixelBufferCreate failed: \(err)")
        }

        CVPixelBufferLockBaseAddress(buffer, .readOnly)
        CVPixelBufferLockBaseAddress(dst, [])
        defer {
            CVPixelBufferUnlockBaseAddress(buffer, .readOnly)
            CVPixelBufferUnlockBaseAddress(dst, [])
        }

        let srcBytesPerRow = CVPixelBufferGetBytesPerRow(buffer)
        let dstBytesPerRow = CVPixelBufferGetBytesPerRow(dst)
        guard let srcBase = CVPixelBufferGetBaseAddress(buffer),
              let dstBase = CVPixelBufferGetBaseAddress(dst) else {
            throw RifeError.inferenceFailed("padPixelBuffer: base address nil")
        }

        let srcRowBytesUsed = srcW * 4
        for y in 0..<paddedH {
            let srcY = min(y, srcH - 1)
            let srcRow = srcBase.advanced(by: srcY * srcBytesPerRow)
            let dstRow = dstBase.advanced(by: y * dstBytesPerRow)
            // Copy main content
            memcpy(dstRow, srcRow, srcRowBytesUsed)
            // Replicate last column for the padding region
            if paddedW > srcW {
                let lastPixel = srcRow.advanced(by: (srcW - 1) * 4)
                for x in srcW..<paddedW {
                    dstRow.advanced(by: x * 4).copyMemory(from: lastPixel, byteCount: 4)
                }
            }
        }
        return dst
    }

    internal func cropPixelBufferForStream(_ buffer: CVPixelBuffer,
                                            width: Int,
                                            height: Int) throws -> CVPixelBuffer {
        let srcW = CVPixelBufferGetWidth(buffer)
        let srcH = CVPixelBufferGetHeight(buffer)
        if srcW == width && srcH == height { return buffer }

        let attrs: [String: Any] = [
            kCVPixelBufferPixelFormatTypeKey as String: Int(kCVPixelFormatType_32BGRA),
            kCVPixelBufferWidthKey as String: width,
            kCVPixelBufferHeightKey as String: height,
            kCVPixelBufferMetalCompatibilityKey as String: true,
            kCVPixelBufferIOSurfacePropertiesKey as String: [:] as [String: Any],
        ]
        var dst: CVPixelBuffer?
        let err = CVPixelBufferCreate(kCFAllocatorDefault,
                                      width, height,
                                      kCVPixelFormatType_32BGRA,
                                      attrs as CFDictionary, &dst)
        guard err == kCVReturnSuccess, let dst else {
            throw RifeError.inferenceFailed("cropPixelBuffer: CVPixelBufferCreate failed: \(err)")
        }

        CVPixelBufferLockBaseAddress(buffer, .readOnly)
        CVPixelBufferLockBaseAddress(dst, [])
        defer {
            CVPixelBufferUnlockBaseAddress(buffer, .readOnly)
            CVPixelBufferUnlockBaseAddress(dst, [])
        }

        let srcBytesPerRow = CVPixelBufferGetBytesPerRow(buffer)
        let dstBytesPerRow = CVPixelBufferGetBytesPerRow(dst)
        guard let srcBase = CVPixelBufferGetBaseAddress(buffer),
              let dstBase = CVPixelBufferGetBaseAddress(dst) else {
            throw RifeError.inferenceFailed("cropPixelBuffer: base address nil")
        }

        let rowBytes = width * 4
        for y in 0..<height {
            let srcRow = srcBase.advanced(by: y * srcBytesPerRow)
            let dstRow = dstBase.advanced(by: y * dstBytesPerRow)
            memcpy(dstRow, srcRow, rowBytes)
        }
        return dst
    }

    internal func cropPixelBufferForStream(_ buffer: CVPixelBuffer,
                                            into dst: CVPixelBuffer) throws {
        let w = CVPixelBufferGetWidth(dst)
        let h = CVPixelBufferGetHeight(dst)
        CVPixelBufferLockBaseAddress(buffer, .readOnly)
        CVPixelBufferLockBaseAddress(dst, [])
        defer {
            CVPixelBufferUnlockBaseAddress(buffer, .readOnly)
            CVPixelBufferUnlockBaseAddress(dst, [])
        }
        let srcStride = CVPixelBufferGetBytesPerRow(buffer)
        let dstStride = CVPixelBufferGetBytesPerRow(dst)
        guard let srcBase = CVPixelBufferGetBaseAddress(buffer),
              let dstBase = CVPixelBufferGetBaseAddress(dst) else {
            throw RifeError.inferenceFailed("cropPixelBuffer(into:): base address nil")
        }
        let rowBytes = w * 4
        for y in 0..<h {
            let srcRow = srcBase.advanced(by: y * srcStride)
            let dstRow = dstBase.advanced(by: y * dstStride)
            memcpy(dstRow, srcRow, rowBytes)
        }
    }

    private func ensureGraph(width: Int, height: Int) throws -> IFNetGraph {
        if let g = graph, let res = graphResolution, res == (width, height) {
            return g
        }
        do {
            let g = try IFNetGraph(context: context, weights: weights,
                                   width: width, height: height,
                                   internalScale: qualityTier.internalScale,
                                   experimentOptions: experimentOptions)
            self.graph = g
            self.graphResolution = (width, height)
            return g
        } catch {
            throw RifeError.inferenceFailed(String(describing: error))
        }
    }

    /// Creates a stateful stream session locked to the given resolution.
    /// Throws if the underlying IFNetGraph or buffers cannot be allocated.
    public func makeStream(width: Int, height: Int) throws -> RifeStream {
        guard width > 0, height > 0 else {
            throw RifeError.dimensionMismatch
        }
        let padMul = qualityTier.paddingMultiple
        let paddedW = ((width + padMul - 1) / padMul) * padMul
        let paddedH = ((height + padMul - 1) / padMul) * padMul

        let g = try ensureGraph(width: paddedW, height: paddedH)
        let intScale = qualityTier.internalScale
        let paddedIntW = Int((Double(paddedW) * intScale).rounded(.toNearestOrAwayFromZero))
        let paddedIntH = Int((Double(paddedH) * intScale).rounded(.toNearestOrAwayFromZero))

        return RifeStream(interpolator: self,
                          graph: g,
                          width: width, height: height,
                          paddedW: paddedW, paddedH: paddedH,
                          paddedIntW: paddedIntW, paddedIntH: paddedIntH,
                          queue: queue)
    }
}

// AIR_FOURSTAGE_DIAGNOSTIC_OVERRIDE_BEGIN
private func airSelectDiagnosticModel(configuration: RifeConfiguration) throws -> (url: URL, overridden: Bool) {
    guard let raw = ProcessInfo.processInfo.environment["ODF_AIR_FOURSTAGE_MODEL_PATH"] else {
        return (configuration.modelURL, false)
    }
    guard Bundle.main.bundleIdentifier == "app.openduckframe.SelfWindowDiagnostic" else {
        throw RifeError.modelLoadFailed("four-stage model override requires the self-window diagnostic bundle")
    }
    guard raw.hasPrefix("/"), !raw.isEmpty, configuration.modelURL.isFileURL else {
        throw RifeError.modelLoadFailed("four-stage model override requires an absolute local file path and original local model")
    }
    let original = try Data(contentsOf: configuration.modelURL, options: .mappedIfSafe)
    let digest = SHA256.hash(data: original).map { String(format: "%02x", $0) }.joined()
    guard digest == "ef29a643a76a9202600458a23dddce16919337ef01743d0fbe817684ec990f74" else {
        throw RifeError.modelLoadFailed("four-stage diagnostic original source is not the frozen RIFE4.25 control")
    }
    return (URL(fileURLWithPath: raw).standardizedFileURL, true)
}
// AIR_FOURSTAGE_DIAGNOSTIC_OVERRIDE_END

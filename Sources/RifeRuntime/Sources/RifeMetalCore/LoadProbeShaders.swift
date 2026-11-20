import Foundation
import Metal

func loadProbeShaders(device: MTLDevice) throws -> MTLLibrary {
    let directory: URL
    if let root = ProcessInfo.processInfo.environment["PXPLAY_FG_RESOURCES"] {
        directory = URL(fileURLWithPath: root).appendingPathComponent("RifeShaders")
    } else {
        directory = Bundle.module.resourceURL!.appendingPathComponent("Shaders")
    }
    let files = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
    let source = try files.filter { $0.pathExtension == "metal" }.sorted { $0.path < $1.path }
        .map { try String(contentsOf: $0, encoding: .utf8) }.joined(separator: "\n")
    return try device.makeLibrary(source: source, options: nil)
}

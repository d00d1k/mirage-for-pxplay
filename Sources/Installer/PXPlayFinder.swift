import AppKit
import Foundation
import MachO
import Security

/// The two PXPlay 3.2.0 builds Mirage supports. Same values as Sources/Agent/PXPlayFingerprints.h.
enum PXPlayKind: String, Codable {
    case full, demo

    static let version = "3.2.0"
    var bundleID: String { self == .full ? "com.grill.psplay.PXPlay" : "com.grill.psplay.PXPlay.demo" }
    var jarName: String { self == .full ? "PXPlay-3.2.0-runnable.jar" : "PXPlay_Demo-3.2.0-runnable.jar" }
    var displayName: String { self == .full ? "PXPlay" : "PXPlay Demo" }
    var launcherName: String { self == .full ? "Mirage for PXPlay" : "Mirage for PXPlay Demo" }

    init?(bundleID: String?) {
        switch bundleID {
        case "com.grill.psplay.PXPlay": self = .full
        case "com.grill.psplay.PXPlay.demo": self = .demo
        default: return nil
        }
    }
}

/// Classes Mirage edits in memory; both builds share them byte for byte.
private let knownClasses: [(entry: String, size: Int, fnv: UInt64)] = [
    ("com/grill/psplay/video/desktop/renderer/metal/MetalRendererBackend.class", 42425, 0x1c758f5d0f823131),
    ("com/grill/psplay/gamepad/data/ControllerRemoteState.class", 4337, 0xb37c96afc36b76d3),
]

struct Candidate: Identifiable, Equatable {
    var id: String { url.path }
    let url: URL
    let kind: PXPlayKind?
    let version: String
    /// nil when Mirage can be installed for this copy.
    let problem: String?
    var ready: Bool { problem == nil && kind != nil }
}

enum PXPlayFinder {
    /// Every PXPlay copy macOS knows about: Launch Services, Spotlight and the usual folders.
    static func locate() -> [URL] {
        var urls: [URL] = []
        for kind in [PXPlayKind.full, .demo] {
            urls += NSWorkspace.shared.urlsForApplications(withBundleIdentifier: kind.bundleID)
        }
        let home = FileManager.default.homeDirectoryForCurrentUser
        for folder in [URL(fileURLWithPath: "/Applications"), home.appendingPathComponent("Applications"),
                       home.appendingPathComponent("Downloads"), home.appendingPathComponent("Desktop")] {
            for name in ["PXPlay.app", "PXPlay_Demo.app", "PXPlay Demo.app"] {
                let url = folder.appendingPathComponent(name)
                if FileManager.default.fileExists(atPath: url.path) { urls.append(url) }
            }
        }
        urls += spotlight()
        var seen = Set<String>()
        // Screenshots and tests: MIRAGE_SEARCH_ONLY=/Applications limits results to these folders.
        let only = ProcessInfo.processInfo.environment["MIRAGE_SEARCH_ONLY"]?.split(separator: ":").map(String.init)
        return urls.compactMap { url -> URL? in
            let path = url.resolvingSymlinksInPath().standardizedFileURL.path
            if let only, !only.contains(where: { path.hasPrefix($0 + "/") }) { return nil }
            // Skip copies in the Trash and PXPlay bundles nested inside other apps.
            if path.contains("/.Trash") || path.dropLast(4).contains("/Contents/") { return nil }
            return seen.insert(path).inserted ? URL(fileURLWithPath: path) : nil
        }.sorted { $0.path < $1.path }
    }

    private static func spotlight() -> [URL] {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/mdfind")
        process.arguments = ["kMDItemCFBundleIdentifier == 'com.grill.psplay.PXPlay' || kMDItemCFBundleIdentifier == 'com.grill.psplay.PXPlay.demo'"]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        guard (try? process.run()) != nil else { return [] }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return String(decoding: data, as: UTF8.self).split(separator: "\n").map { URL(fileURLWithPath: String($0)) }
    }

    /// Checks a copy: identity, exact version, jar, Apple silicon, PXPlay developer signature,
    /// and the two class files Mirage touches.
    static func validate(_ url: URL) -> Candidate {
        let bundle = Bundle(url: url)
        let info = bundle?.infoDictionary
        let version = info?["CFBundleShortVersionString"] as? String ?? "?"
        guard url.pathExtension == "app", let bundle else {
            return Candidate(url: url, kind: nil, version: version, problem: L("app.reason.notApp"))
        }
        guard let kind = PXPlayKind(bundleID: bundle.bundleIdentifier) else {
            return Candidate(url: url, kind: nil, version: version, problem: L("app.reason.notPXPlay"))
        }
        func fail(_ reason: String) -> Candidate { Candidate(url: url, kind: kind, version: version, problem: reason) }
        guard version == PXPlayKind.version else { return fail(L("app.reason.version", version)) }
        let jar = url.appendingPathComponent("Contents/Resources/Java/\(kind.jarName)")
        guard let executable = bundle.executableURL, FileManager.default.fileExists(atPath: jar.path) else {
            return fail(L("app.reason.damaged"))
        }
        guard hasArm64(executable) else { return fail(L("app.reason.intel")) }
        guard signedByPXPlayDeveloper(url, identifier: kind.bundleID) else { return fail(L("app.reason.damaged")) }
        for known in knownClasses {
            guard let bytes = unzipEntry(jar, known.entry), bytes.count == known.size, fnv1a(bytes) == known.fnv else {
                return fail(L("app.reason.damaged"))
            }
        }
        return Candidate(url: url, kind: kind, version: version, problem: nil)
    }

    static func hasArm64(_ executable: URL) -> Bool {
        guard let handle = try? FileHandle(forReadingFrom: executable),
              let head = try? handle.read(upToCount: 4096), head.count >= 8 else { return false }
        try? handle.close()
        return head.withUnsafeBytes { raw -> Bool in
            let magic = raw.load(as: UInt32.self)
            if magic == MH_MAGIC_64 { return raw.load(fromByteOffset: 4, as: Int32.self) == CPU_TYPE_ARM64 }
            guard magic == FAT_CIGAM || magic == FAT_MAGIC else { return false }
            let count = Int(UInt32(bigEndian: raw.load(fromByteOffset: 4, as: UInt32.self)))
            for index in 0..<count {
                let offset = 8 + index * MemoryLayout<fat_arch>.size
                guard offset + 4 <= raw.count else { break }
                if Int32(bitPattern: UInt32(bigEndian: raw.load(fromByteOffset: offset, as: UInt32.self))) == CPU_TYPE_ARM64 {
                    return true
                }
            }
            return false
        }
    }

    static func signedByPXPlayDeveloper(_ url: URL, identifier: String) -> Bool {
        var code: SecStaticCode?
        var requirement: SecRequirement?
        let text = "anchor apple generic and certificate leaf[subject.OU] = \"CHDS428K5R\" and identifier \"\(identifier)\""
        guard SecStaticCodeCreateWithPath(url as CFURL, [], &code) == errSecSuccess, let code,
              SecRequirementCreateWithString(text as CFString, [], &requirement) == errSecSuccess else { return false }
        return SecStaticCodeCheckValidity(code, SecCSFlags(rawValue: kSecCSDoNotValidateResources), requirement) == errSecSuccess
    }

    private static func unzipEntry(_ jar: URL, _ entry: String) -> Data? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/unzip")
        process.arguments = ["-p", jar.path, entry]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        guard (try? process.run()) != nil else { return nil }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return process.terminationStatus == 0 ? data : nil
    }

    private static func fnv1a(_ data: Data) -> UInt64 {
        var hash: UInt64 = 0xcbf29ce484222325
        for byte in data { hash = (hash ^ UInt64(byte)) &* 0x100000001b3 }
        return hash
    }
}

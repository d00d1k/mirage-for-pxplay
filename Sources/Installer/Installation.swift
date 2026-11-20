import AppKit
import CoreServices
import Foundation

enum Style: String, CaseIterable, Identifiable {
    case recommended, picture, original
    var id: String { rawValue }
    var title: String { L("pxplay.style.\(rawValue)") }
    var note: String { L("pxplay.style.\(rawValue).note") }
}

struct InstallOptions {
    var targets: [Candidate]
    var style: Style = .recommended
    var pxplaySettings = true
    var steadyWifi = false
}

struct InstallResult {
    var launchers: [PXPlayKind: URL] = [:]
    var wifiSkipped = false
    var settingsApplied = false
}

enum InstallStep: String, CaseIterable {
    case check, copy, prepare, apps, settings, helper
    var title: String { L("app.step.\(rawValue)") }
}

struct InstallError: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

/// Where Mirage puts things. MIRAGE_TEST_HOME and MIRAGE_SYSTEM_ROOT redirect everything for tests.
struct Paths {
    static let launcherPrefix = "io.github.mirage-pxplay.launcher"
    static let helperLabel = "io.github.mirage-pxplay.steady-wifi"
    let home: URL
    let systemRoot: String

    static let current: Paths = {
        let env = ProcessInfo.processInfo.environment
        let home = env["MIRAGE_TEST_HOME"].map { URL(fileURLWithPath: $0) } ?? FileManager.default.homeDirectoryForCurrentUser
        return Paths(home: home, systemRoot: env["MIRAGE_SYSTEM_ROOT"] ?? "")
    }()

    var support: URL { home.appendingPathComponent("Library/Application Support/Mirage for PXPlay") }
    var applications: URL { home.appendingPathComponent("Applications") }
    var logs: URL { home.appendingPathComponent("Library/Logs/Mirage for PXPlay") }
    var pxplayPrefs: URL { home.appendingPathComponent("Library/Application Support/PXPlay/Data/prefs.json") }
    var settingsBackup: URL { support.appendingPathComponent("pxplay-settings-backup.json") }
    var helperPlist: URL { URL(fileURLWithPath: systemRoot + "/Library/LaunchDaemons/\(Paths.helperLabel).plist") }
    var testing: Bool { !systemRoot.isEmpty }

    func launcher(_ kind: PXPlayKind) -> URL { applications.appendingPathComponent("\(kind.launcherName).app") }
    var installed: Bool { FileManager.default.fileExists(atPath: support.appendingPathComponent("lib/MirageAgent.dylib").path) }
    var helperInstalled: Bool { FileManager.default.fileExists(atPath: helperPlist.path) }
}

/// PXPlay settings that work best with Mirage, taken from the author's tested setup. Only
/// video, network and controller options: no account, console, window or device entries.
let recommendedPXPlaySettings: [String: String] = [
    "VIDEO_RENDERING_FRAME_GENERATION": "ENABLED",
    "REMOTE_VIDEO_RENDERING_TYPE_NEW": "METAL",
    "RENDERING_VSYNC_NEW": "true",
    "VIDEO_RENDERING_FRAME_PRESENTATION": "LOWEST_LATENCY",
    "METAL_SUPER_RESOLUTION": "UPSCALING_4K",
    "FSR_UPSCALING": "ENABLED",
    "REMOTE_RESOLUTION": "BEST",
    "REMOTE_FPS": "STANDARD",
    "REMOTE_BITRATE": "MANUAL",
    "REMOTE_MANUAL_BITRATE": "100000",
    "USE_HEVC": "true",
    "USE_HDR": "false",
    "REMOTE_AUDIO_BUFFER_SIZE": "SMALL",
    "GAMEPAD_REFRESH_RATE_V2": "ULTRA",
    "OPERATING_MODE": "TURBO",
    "VIDEO_FRAME_BUFFER_RATE": "FEW",
    "BITSTREAM_PARSING": "true",
    "ERROR_CONCEALMENT": "true",
    "ALWAYS_REQUEST_KEY_FRAME": "false",
    "SOFTWARE_DECODER_FALLBACK": "false",
    "REMOTE_STREAM_COMPATIBILITY_MODE": "false",
    "FOCUS_STREAM_WINDOW": "true",
    "PREVENT_SCREEN_SAVER": "true",
    "RAW_TOUCH_INPUT": "false",
    "REMOTE_AMBIENT_BACKGROUND_MODE": "AMBIENT_COLORS",
    "REMOTE_STREAM_VIDEO_FORMAT": "KEEP_ASPECT_RATIO",
    "REMOTE_STREAM_VIDEO_FORMAT_NEW": "AMBIENT",
    "USE_BORDERLESS_FULLSCREEN": "false",
    "VULKAN_RENDERING_PRESET": "DEFAULT",
]

enum Installation {
    static var payload: URL {
        if let override = ProcessInfo.processInfo.environment["MIRAGE_PAYLOAD"] { return URL(fileURLWithPath: override) }
        return Bundle.main.resourceURL!.appendingPathComponent("Payload")
    }

    static var pxplayRunning: Bool {
        PXPlayKind.allCasesRunning.isEmpty == false
    }

    static func quitPXPlay() async -> Bool {
        let running = PXPlayKind.allCasesRunning
        running.forEach { $0.terminate() }
        for _ in 0..<100 {
            if running.allSatisfy(\.isTerminated) { return true }
            try? await Task.sleep(nanoseconds: 100_000_000)
        }
        return false
    }

    /// Runs one install step. The UI calls them in order and animates between them.
    static func run(_ step: InstallStep, _ options: InstallOptions, _ result: inout InstallResult,
                    paths: Paths = .current) async throws {
        let fm = FileManager.default
        switch step {
        case .check:
            for target in options.targets where !PXPlayFinder.validate(target.url).ready {
                throw InstallError(message: "\(target.url.lastPathComponent): \(PXPlayFinder.validate(target.url).problem ?? "")")
            }
        case .copy:
            try fm.createDirectory(at: paths.support, withIntermediateDirectories: true)
            for item in ["lib", "Resources", "Helper", "Licenses", "VERSION"] {
                let target = paths.support.appendingPathComponent(item)
                if fm.fileExists(atPath: target.path) { try fm.removeItem(at: target) }
                try fm.copyItem(at: payload.appendingPathComponent(item), to: target)
            }
            removeQuarantine(paths.support)
        case .prepare:
            var config = (NSDictionary(contentsOf: paths.support.appendingPathComponent("config.plist")) as? [String: String]) ?? [:]
            for target in options.targets { if let kind = target.kind { config[kind.rawValue] = target.url.path } }
            try (config as NSDictionary).write(to: paths.support.appendingPathComponent("config.plist"))
            try writeSettings(style: options.style, steadyWifi: options.steadyWifi, paths: paths)
        case .apps:
            try fm.createDirectory(at: paths.applications, withIntermediateDirectories: true)
            for target in options.targets {
                guard let kind = target.kind else { continue }
                let destination = paths.launcher(kind)
                if fm.fileExists(atPath: destination.path) { try fm.removeItem(at: destination) }
                try fm.copyItem(at: payload.appendingPathComponent("Apps/\(kind.launcherName).app"), to: destination)
                removeQuarantine(destination)
                if !paths.testing { LSRegisterURL(destination as CFURL, true) }
                result.launchers[kind] = destination
            }
        case .settings:
            guard options.pxplaySettings else { return }
            try applyPXPlaySettings(paths: paths)
            result.settingsApplied = true
        case .helper:
            guard options.steadyWifi, !paths.helperInstalled else { return }
            let installed = await runHelperScript("install-helper.sh", prompt: L("pxplay.wifi.prompt"), paths: paths)
            if !installed {
                result.wifiSkipped = true
                try writeSettings(style: options.style, steadyWifi: false, paths: paths)
            }
        }
    }

    static func writeSettings(style: Style, steadyWifi: Bool, paths: Paths) throws {
        let file = paths.support.appendingPathComponent("settings.properties")
        var values: [String: String] = [:]
        if let existing = try? String(contentsOf: file, encoding: .utf8) {
            for line in existing.split(separator: "\n") where !line.hasPrefix("#") {
                let parts = line.split(separator: "=", maxSplits: 1).map(String.init)
                if parts.count == 2 { values[parts[0]] = parts[1] }
            }
        }
        values["style"] = style.rawValue
        if style == .recommended {
            values.merge(["mode": "predict", "strength": "70", "smoothing": "2", "stick": "-1", "wait": "0",
                          "hud": "true", "early": "true"]) { $1 }
        } else if style == .picture {
            values.merge(["mode": "blend", "wait": "12", "hud": "true", "early": "true"]) { $1 }
        }
        values["steadyWifi"] = steadyWifi ? "true" : "false"
        let text = "# Mirage for PXPlay\n" + values.keys.sorted().map { "\($0)=\(values[$0]!)" }.joined(separator: "\n") + "\n"
        try text.write(to: file, atomically: true, encoding: .utf8)
    }

    /// Writes the recommended settings into PXPlay's prefs.json. The values they replace are
    /// kept in a backup so Uninstall can put them back.
    static func applyPXPlaySettings(paths: Paths) throws {
        let fm = FileManager.default
        var prefs: [String: Any] = [:]
        if let data = try? Data(contentsOf: paths.pxplayPrefs) {
            guard let parsed = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                throw InstallError(message: "PXPlay prefs.json")
            }
            prefs = parsed
        }
        var backup = (try? JSONSerialization.jsonObject(with: Data(contentsOf: paths.settingsBackup))) as? [String: Any] ?? [:]
        var previous = backup["previous"] as? [String: Any] ?? [:]
        for (key, value) in recommendedPXPlaySettings where previous[key] == nil {
            previous[key] = prefs[key] ?? NSNull()
            _ = value
        }
        backup = ["applied": recommendedPXPlaySettings, "previous": previous]
        try fm.createDirectory(at: paths.support, withIntermediateDirectories: true)
        try JSONSerialization.data(withJSONObject: backup, options: [.prettyPrinted, .sortedKeys]).write(to: paths.settingsBackup)
        for (key, value) in recommendedPXPlaySettings { prefs[key] = value }
        try fm.createDirectory(at: paths.pxplayPrefs.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONSerialization.data(withJSONObject: prefs, options: [.prettyPrinted, .sortedKeys])
            .write(to: paths.pxplayPrefs, options: .atomic)
    }

    /// Puts back the PXPlay settings Mirage changed, except ones the user has changed since.
    static func restorePXPlaySettings(paths: Paths) throws {
        guard let backup = (try? JSONSerialization.jsonObject(with: Data(contentsOf: paths.settingsBackup))) as? [String: Any],
              let applied = backup["applied"] as? [String: String],
              let previous = backup["previous"] as? [String: Any],
              let data = try? Data(contentsOf: paths.pxplayPrefs),
              var prefs = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { return }
        for (key, value) in applied where (prefs[key] as? String) == value {
            if let old = previous[key], !(old is NSNull) { prefs[key] = old } else { prefs.removeValue(forKey: key) }
        }
        try JSONSerialization.data(withJSONObject: prefs, options: [.prettyPrinted, .sortedKeys])
            .write(to: paths.pxplayPrefs, options: .atomic)
    }

    static var hasSettingsBackup: Bool { FileManager.default.fileExists(atPath: Paths.current.settingsBackup.path) }

    /// Removes everything Mirage added. PXPlay itself is never touched.
    static func uninstall(restoreSettings: Bool, paths: Paths = .current) async throws {
        let fm = FileManager.default
        if paths.helperInstalled {
            _ = await runHelperScript("uninstall-helper.sh", prompt: L("app.uninstall.message"), paths: paths)
        }
        if restoreSettings { try restorePXPlaySettings(paths: paths) }
        for kind in [PXPlayKind.full, .demo] {
            let launcher = paths.launcher(kind)
            if Bundle(url: launcher)?.bundleIdentifier?.hasPrefix(Paths.launcherPrefix) == true {
                try fm.removeItem(at: launcher)
            }
        }
        for folder in [paths.support, paths.logs] where fm.fileExists(atPath: folder.path) {
            try fm.removeItem(at: folder)
        }
    }

    /// Runs a helper script as root behind macOS's administrator prompt (directly in tests).
    static func runHelperScript(_ name: String, prompt: String, paths: Paths) async -> Bool {
        let script = paths.support.appendingPathComponent("Helper/\(name)")
        let user = NSUserName()
        let process = Process()
        if paths.testing {
            process.executableURL = URL(fileURLWithPath: "/bin/sh")
            process.arguments = [script.path, user]
        } else {
            guard !script.path.contains("'"), !user.contains("'") else { return false }
            func quoted(_ text: String) -> String {
                text.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
            }
            let shell = "/bin/sh '\(script.path)' '\(user)'"
            process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
            process.arguments = ["-e", "do shell script \"\(quoted(shell))\" with prompt \"\(quoted(prompt))\" with administrator privileges"]
        }
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        return await withCheckedContinuation { continuation in
            process.terminationHandler = { continuation.resume(returning: $0.terminationStatus == 0) }
            do { try process.run() } catch { continuation.resume(returning: false) }
        }
    }

    /// Files copied out of a downloaded installer carry its quarantine flag; Mirage's own
    /// installed copies drop it so macOS does not ask again for each part.
    static func removeQuarantine(_ root: URL) {
        removexattr(root.path, "com.apple.quarantine", XATTR_NOFOLLOW)
        guard let walker = FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil) else { return }
        for case let url as URL in walker {
            removexattr(url.path, "com.apple.quarantine", XATTR_NOFOLLOW)
        }
    }
}

extension PXPlayKind {
    static var allCasesRunning: [NSRunningApplication] {
        [PXPlayKind.full, .demo].flatMap { NSRunningApplication.runningApplications(withBundleIdentifier: $0.bundleID) }
    }
}

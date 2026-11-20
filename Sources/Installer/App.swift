import AppKit
import SwiftUI

@main
enum Entry {
    static func main() {
        let arguments = Array(CommandLine.arguments.dropFirst())
        if let command = arguments.first, CLI.commands.contains(command) {
            exit(CLI.run(arguments))
        }
        MirageInstallerApp.main()
    }
}

struct MirageInstallerApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate

    var body: some Scene {
        Window("Mirage", id: "installer") {
            InstallerView()
        }
        .windowResizability(.contentSize)
        .windowStyle(.hiddenTitleBar)
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
}

/// Text interface for scripted tests (smoke-test.sh). Same code paths as the window.
enum CLI {
    static let commands: Set<String> = ["--detect", "--validate", "--install", "--uninstall", "--status"]

    static func run(_ arguments: [String]) -> Int32 {
        func value(_ flag: String) -> String? {
            guard let index = arguments.firstIndex(of: flag), index + 1 < arguments.count else { return nil }
            return arguments[index + 1]
        }
        func line(_ candidate: Candidate) -> String {
            "\(candidate.ready ? "READY" : "NO")\t\(candidate.kind?.rawValue ?? "-")\t\(candidate.version)\t\(candidate.url.path)\t\(candidate.problem ?? "")"
        }
        switch arguments[0] {
        case "--detect":
            PXPlayFinder.locate().map(PXPlayFinder.validate).forEach { print(line($0)) }
            return 0
        case "--validate":
            guard let path = value("--validate") else { return 2 }
            let candidate = PXPlayFinder.validate(URL(fileURLWithPath: path))
            print(line(candidate))
            return candidate.ready ? 0 : 1
        case "--status":
            let paths = Paths.current
            print("installed=\(paths.installed) helper=\(paths.helperInstalled) support=\(paths.support.path)")
            return 0
        case "--install":
            var targets: [Candidate] = []
            for flag in ["--full", "--demo"] {
                if let path = value(flag) { targets.append(PXPlayFinder.validate(URL(fileURLWithPath: path))) }
            }
            guard !targets.isEmpty else { print("usage: --install --full <PXPlay.app> [--demo <PXPlay_Demo.app>]"); return 2 }
            let options = InstallOptions(targets: targets, style: Style(rawValue: value("--style") ?? "") ?? .recommended,
                                         pxplaySettings: arguments.contains("--pxplay-settings"),
                                         steadyWifi: arguments.contains("--wifi"))
            return blocking {
                var result = InstallResult()
                do {
                    for step in InstallStep.allCases {
                        try await Installation.run(step, options, &result)
                        print("step \(step.rawValue) ok")
                    }
                    for (kind, url) in result.launchers { print("launcher \(kind.rawValue)\t\(url.path)") }
                    print("settings=\(result.settingsApplied) wifiSkipped=\(result.wifiSkipped)")
                    return 0
                } catch {
                    print("error: \(error.localizedDescription)")
                    return 1
                }
            }
        case "--uninstall":
            return blocking {
                do {
                    try await Installation.uninstall(restoreSettings: arguments.contains("--restore-settings"))
                    print("uninstalled")
                    return 0
                } catch {
                    print("error: \(error.localizedDescription)")
                    return 1
                }
            }
        default:
            return 2
        }
    }

    private static func blocking(_ work: @escaping () async -> Int32) -> Int32 {
        var status: Int32 = 1
        let done = DispatchSemaphore(value: 0)
        Task.detached {
            status = await work()
            done.signal()
        }
        done.wait()
        return status
    }
}

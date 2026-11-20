import AppKit
import SwiftUI

@MainActor
final class InstallerModel: ObservableObject {
    enum Screen { case find, style, installing, done, removed }

    static let releasePage = URL(string: "https://github.com/streamingdv/PSPlay-Application-Hosting/releases/tag/v3.2.0_v9.0.0")!
    static let donateURL = (Bundle.main.object(forInfoDictionaryKey: "MirageDonateURL") as? String).flatMap(link)
    static let projectURL = (Bundle.main.object(forInfoDictionaryKey: "MirageProjectURL") as? String).flatMap(link)
    private static func link(_ text: String) -> URL? {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        return trimmed.hasPrefix("https://") ? URL(string: trimmed) : nil
    }

    @Published var screen = Screen.find
    @Published var candidates: [Candidate] = []
    @Published var selected = Set<String>()
    @Published var searching = true
    @Published var style = Style.recommended
    @Published var pxplaySettings = true
    @Published var steadyWifi = false
    @Published var progress = 0.0
    @Published var stepTitle = ""
    @Published var result = InstallResult()
    @Published var error: String?
    @Published var askQuit = false
    @Published var askUninstall = false
    @Published var restoreSettings = true
    @Published var installed = Paths.current.installed
    @Published var busy = false

    init() {
        // Screenshots and visual checks: MIRAGE_PREVIEW=style|installing:0.3|done opens that screen.
        guard let preview = ProcessInfo.processInfo.environment["MIRAGE_PREVIEW"] else { return }
        let parts = preview.split(separator: ":")
        switch parts.first {
        case "style": screen = .style
        case "installing":
            screen = .installing
            progress = parts.count > 1 ? Double(parts[1]) ?? 0.3 : 0.3
            stepTitle = InstallStep.copy.title
        case "demo":
            // A looping installation for the README animation: still, then sharpening over eight seconds.
            screen = .installing
            stepTitle = InstallStep.prepare.title
            let start = Date()
            Timer.scheduledTimer(withTimeInterval: 1.0 / 30, repeats: true) { [weak self] _ in
                let t = Date().timeIntervalSince(start)
                Task { @MainActor in self?.progress = min(1, max(0, (t - 3) / 8)) }
            }
        case "done":
            screen = .done
            result.launchers = [.full: Paths.current.launcher(.full), .demo: Paths.current.launcher(.demo)]
            result.settingsApplied = true
        default: break
        }
    }

    var readySelection: [Candidate] { candidates.filter { $0.ready && selected.contains($0.id) } }
    var anyReady: Bool { candidates.contains(where: \.ready) }

    func search() async {
        searching = true
        let found = await Task.detached { PXPlayFinder.locate().map(PXPlayFinder.validate) }.value
        for candidate in found { insert(candidate) }
        searching = false
    }

    /// From drag and drop or the open panel.
    func add(_ url: URL) {
        Task {
            let candidate = await Task.detached { PXPlayFinder.validate(url) }.value
            insert(candidate)
        }
    }

    private func insert(_ candidate: Candidate) {
        if let index = candidates.firstIndex(where: { $0.id == candidate.id }) {
            candidates[index] = candidate
        } else {
            candidates.append(candidate)
        }
        candidates.sort { ($0.ready ? 0 : 1, $0.kind == .demo ? 1 : 0, $0.url.path) < ($1.ready ? 0 : 1, $1.kind == .demo ? 1 : 0, $1.url.path) }
        // One copy per kind: the first ready full and the first ready demo are selected.
        if candidate.ready, let kind = candidate.kind,
           !candidates.contains(where: { selected.contains($0.id) && $0.kind == kind && $0.id != candidate.id }) {
            selected.insert(candidate.id)
        }
    }

    func toggle(_ candidate: Candidate) {
        guard candidate.ready else { return }
        if selected.contains(candidate.id) {
            selected.remove(candidate.id)
        } else {
            selected = selected.filter { id in candidates.first { $0.id == id }?.kind != candidate.kind }
            selected.insert(candidate.id)
        }
    }

    func choose() {
        let panel = NSOpenPanel()
        panel.directoryURL = URL(fileURLWithPath: "/Applications")
        panel.allowedContentTypes = [.applicationBundle]
        panel.treatsFilePackagesAsDirectories = false
        if panel.runModal() == .OK, let url = panel.url { add(url) }
    }

    func startInstall() {
        if pxplaySettings && Installation.pxplayRunning {
            askQuit = true
            return
        }
        Task { await install() }
    }

    func quitPXPlayAndInstall() {
        Task {
            _ = await Installation.quitPXPlay()
            await install()
        }
    }

    private func install() async {
        let options = InstallOptions(targets: readySelection, style: style, pxplaySettings: pxplaySettings, steadyWifi: steadyWifi)
        result = InstallResult()
        progress = 0
        error = nil
        screen = .installing
        let steps = InstallStep.allCases
        do {
            for (index, step) in steps.enumerated() {
                stepTitle = step.title
                var stepResult = result
                try await Installation.run(step, options, &stepResult)
                result = stepResult
                // The scene sharpens with the progress: about eight seconds in all.
                let from = Double(index) / Double(steps.count), to = Double(index + 1) / Double(steps.count)
                for frame in 1...40 {
                    progress = from + (to - from) * Double(frame) / 40
                    try? await Task.sleep(nanoseconds: 33_000_000)
                }
            }
            installed = true
            screen = .done
        } catch {
            self.error = error.localizedDescription
            screen = .style
        }
    }

    func open(_ kind: PXPlayKind) {
        guard let launcher = result.launchers[kind] ?? Optional(Paths.current.launcher(kind)) else { return }
        NSWorkspace.shared.openApplication(at: launcher, configuration: NSWorkspace.OpenConfiguration())
    }

    func uninstall() {
        busy = true
        Task {
            do {
                try await Installation.uninstall(restoreSettings: restoreSettings && Installation.hasSettingsBackup)
                installed = false
                screen = .removed
            } catch {
                self.error = error.localizedDescription
            }
            busy = false
        }
    }
}

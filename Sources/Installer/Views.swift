import AppKit
import SwiftUI
import UniformTypeIdentifiers

private let ink = Color(red: 0.06, green: 0.04, blue: 0.12)
private let card = Color.white.opacity(0.06)
private let neon = Color(red: 1.0, green: 0.36, blue: 0.62)
private let sunset = LinearGradient(colors: [Color(red: 1.0, green: 0.55, blue: 0.3), neon, Color(red: 0.55, green: 0.3, blue: 1.0)],
                                    startPoint: .leading, endPoint: .trailing)

struct InstallerView: View {
    @StateObject private var model = InstallerModel()

    var body: some View {
        VStack(spacing: 0) {
            hero
            Group {
                switch model.screen {
                case .find: FindScreen(model: model)
                case .style: StyleScreen(model: model)
                case .installing: InstallingScreen(model: model)
                case .done: DoneScreen(model: model)
                case .removed: RemovedScreen()
                }
            }
            .padding(.horizontal, 28)
            .padding(.top, 20)
            .padding(.bottom, 18)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
        .frame(width: 640, height: 800)
        .background(ink)
        .foregroundStyle(.white)
        .preferredColorScheme(.dark)
        .environment(\.layoutDirection, Texts.rightToLeft ? .rightToLeft : .leftToRight)
        .task { await model.search() }
        .sheet(isPresented: $model.askUninstall) { UninstallSheet(model: model) }
        .alert(L("app.quit.title"), isPresented: $model.askQuit) {
            Button(L("app.quit.button")) { model.quitPXPlayAndInstall() }
            Button(L("launcher.cancel"), role: .cancel) {}
        } message: { Text(L("app.quit.message")) }
    }

    private var hero: some View {
        ZStack(alignment: .bottomLeading) {
            RoadView(clarity: model.screen == .installing ? model.progress : 1)
            LinearGradient(stops: [.init(color: .clear, location: 0.78), .init(color: ink.opacity(0.7), location: 1)],
                           startPoint: .top, endPoint: .bottom)
            VStack(alignment: .leading, spacing: 2) {
                Text("Mirage").font(.system(size: 40, weight: .heavy, design: .rounded)).tracking(1)
                    .shadow(color: neon.opacity(0.8), radius: 12)
                Text("for PXPlay").font(.system(size: 15, weight: .semibold, design: .rounded)).opacity(0.85)
            }
            .environment(\.layoutDirection, .leftToRight)
            .padding(.horizontal, 28)
            .padding(.bottom, 14)
        }
        .frame(height: [.find, .style].contains(model.screen) ? 220 : 420)
        .clipped()
        .animation(.easeInOut(duration: 0.4), value: model.screen)
    }
}

private struct Title: View {
    let title: String
    let subtitle: String?
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(.system(size: 24, weight: .bold, design: .rounded))
            if let subtitle { Text(subtitle).font(.system(size: 13)).foregroundStyle(.white.opacity(0.7)).fixedSize(horizontal: false, vertical: true) }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct PrimaryButton: View {
    let title: String
    var enabled = true
    let action: () -> Void
    var body: some View {
        Button(action: action) {
            Text(title).font(.system(size: 14, weight: .semibold)).padding(.horizontal, 22).padding(.vertical, 9)
                .background(sunset.opacity(enabled ? 1 : 0.35), in: Capsule())
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
        .keyboardShortcut(.defaultAction)
    }
}

private struct QuietButton: View {
    let title: String
    let action: () -> Void
    var body: some View {
        Button(action: action) {
            Text(title).font(.system(size: 13, weight: .medium)).padding(.horizontal, 16).padding(.vertical, 8)
                .background(card, in: Capsule())
        }
        .buttonStyle(.plain)
    }
}

private struct Footer: View {
    @ObservedObject var model: InstallerModel
    var body: some View {
        HStack {
            Text(L("app.footer")).font(.system(size: 11)).foregroundStyle(.white.opacity(0.45))
            Spacer()
            if model.installed {
                Button(L("app.uninstall")) { model.askUninstall = true }
                    .buttonStyle(.plain).font(.system(size: 11, weight: .medium)).foregroundStyle(.white.opacity(0.6))
            }
        }
    }
}

// MARK: - Find PXPlay

private struct FindScreen: View {
    @ObservedObject var model: InstallerModel
    @State private var dropTargeted = false

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Title(title: L("app.find.title"), subtitle: L("app.find.subtitle"))
            if model.installed {
                HStack(spacing: 8) {
                    Image(systemName: "checkmark.seal.fill").foregroundStyle(.green)
                    Text(L("app.installed.banner")).font(.system(size: 12, weight: .medium))
                }
                .padding(.horizontal, 12).padding(.vertical, 8)
                .background(Color.green.opacity(0.12), in: RoundedRectangle(cornerRadius: 10))
            }
            Text(L("app.find.found")).font(.system(size: 11, weight: .semibold)).foregroundStyle(.white.opacity(0.5))
            if model.searching {
                HStack(spacing: 8) { ProgressView().controlSize(.small); Text(L("app.find.searching")).font(.system(size: 13)) }
            } else if model.candidates.isEmpty {
                Text(L("app.find.none")).font(.system(size: 13)).foregroundStyle(.white.opacity(0.7))
            }
            ScrollView {
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(model.candidates) { candidate in
                        CandidateRow(candidate: candidate, selected: model.selected.contains(candidate.id)) { model.toggle(candidate) }
                    }
                }
            }
            .frame(maxHeight: 210)
            dropZone
            if !model.searching && !model.anyReady {
                Link(destination: InstallerModel.releasePage) {
                    Label(L("app.find.download"), systemImage: "arrow.down.circle").font(.system(size: 13, weight: .medium))
                }
            }
            Spacer(minLength: 0)
            HStack {
                Footer(model: model)
                PrimaryButton(title: model.installed ? L("app.reinstall") : L("app.continue"), enabled: !model.readySelection.isEmpty) {
                    model.screen = .style
                }
            }
        }
    }

    private var dropZone: some View {
        HStack(spacing: 12) {
            Image(systemName: "square.and.arrow.down.on.square").font(.system(size: 22)).foregroundStyle(neon)
            Text(L("app.find.drop")).font(.system(size: 13)).foregroundStyle(.white.opacity(0.8))
            Spacer()
            QuietButton(title: L("app.find.choose")) { model.choose() }
        }
        .padding(14)
        .background(RoundedRectangle(cornerRadius: 14).fill(dropTargeted ? neon.opacity(0.12) : card))
        .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(style: StrokeStyle(lineWidth: 1.5, dash: [6, 5]))
            .foregroundStyle(dropTargeted ? neon : .white.opacity(0.25)))
        .onDrop(of: [.fileURL], isTargeted: $dropTargeted) { providers in
            for provider in providers {
                _ = provider.loadObject(ofClass: URL.self) { url, _ in
                    if let url { Task { @MainActor in model.add(url) } }
                }
            }
            return true
        }
    }
}

private struct CandidateRow: View {
    let candidate: Candidate
    let selected: Bool
    let toggle: () -> Void

    var body: some View {
        Button(action: toggle) {
            HStack(spacing: 12) {
                Image(nsImage: NSWorkspace.shared.icon(forFile: candidate.url.path)).resizable().frame(width: 36, height: 36)
                VStack(alignment: .leading, spacing: 2) {
                    Text("\(candidate.kind?.displayName ?? candidate.url.deletingPathExtension().lastPathComponent) \(candidate.version)")
                        .font(.system(size: 14, weight: .semibold))
                    Text((candidate.url.path as NSString).abbreviatingWithTildeInPath)
                        .font(.system(size: 11, design: .monospaced)).foregroundStyle(.white.opacity(0.5)).lineLimit(1).truncationMode(.middle)
                    if candidate.ready && candidate.kind == .demo {
                        Text(L("app.find.demoNote")).font(.system(size: 11)).foregroundStyle(.white.opacity(0.6))
                    }
                    if let problem = candidate.problem {
                        Text(problem).font(.system(size: 11, weight: .medium)).foregroundStyle(Color(red: 1, green: 0.45, blue: 0.45))
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                Spacer()
                if candidate.ready {
                    Text(L("app.find.ready")).font(.system(size: 11, weight: .semibold)).padding(.horizontal, 8).padding(.vertical, 3)
                        .background(Color.green.opacity(0.18), in: Capsule()).foregroundStyle(Color.green)
                    Image(systemName: selected ? "checkmark.circle.fill" : "circle").font(.system(size: 20))
                        .foregroundStyle(selected ? neon : .white.opacity(0.35))
                } else {
                    Image(systemName: "xmark.octagon.fill").foregroundStyle(Color(red: 1, green: 0.45, blue: 0.45))
                }
            }
            .padding(10)
            .background(RoundedRectangle(cornerRadius: 12).fill(card))
            .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(selected ? neon : .clear, lineWidth: 1.5))
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Style and options

private struct StyleScreen: View {
    @ObservedObject var model: InstallerModel
    @State private var showDetails = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Title(title: L("app.style.title"), subtitle: L("app.style.subtitle"))
            ScrollView {
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(Style.allCases) { style in
                        Button { model.style = style } label: {
                            HStack(spacing: 12) {
                                Image(systemName: model.style == style ? "largecircle.fill.circle" : "circle").font(.system(size: 18))
                                    .foregroundStyle(model.style == style ? neon : .white.opacity(0.4))
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(style.title).font(.system(size: 14, weight: .semibold))
                                    Text(style.note).font(.system(size: 12)).foregroundStyle(.white.opacity(0.65))
                                }
                                Spacer()
                            }
                            .padding(10)
                            .background(RoundedRectangle(cornerRadius: 12).fill(card))
                            .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(model.style == style ? neon : .clear, lineWidth: 1.5))
                        }
                        .buttonStyle(.plain)
                    }
                    option(isOn: $model.pxplaySettings, title: L("app.settings.title"), note: L("app.settings.note")) {
                        Button(showDetails ? L("app.settings.hide") : L("app.settings.show")) { showDetails.toggle() }
                            .buttonStyle(.plain).font(.system(size: 12, weight: .medium)).foregroundStyle(neon)
                        if showDetails {
                            VStack(alignment: .leading, spacing: 3) {
                                ForEach(["render", "quality", "upscale", "latency", "controller"], id: \.self) { item in
                                    Label(L("app.settings.item.\(item)"), systemImage: "checkmark").font(.system(size: 11))
                                        .foregroundStyle(.white.opacity(0.75))
                                }
                            }
                        }
                    }
                    option(isOn: $model.steadyWifi, title: L("pxplay.wifi"), note: L("app.wifi.auto") + ". " + L("app.wifi.note")) { EmptyView() }
                    HStack(alignment: .top, spacing: 8) {
                        Image(systemName: "info.circle").foregroundStyle(.white.opacity(0.6))
                        Text(L("app.update.note")).font(.system(size: 11)).foregroundStyle(.white.opacity(0.6))
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .padding(.top, 2)
                    if let error = model.error {
                        Text("\(L("app.error.title")): \(error)").font(.system(size: 12, weight: .medium))
                            .foregroundStyle(Color(red: 1, green: 0.45, blue: 0.45))
                    }
                }
            }
            HStack {
                QuietButton(title: L("app.back")) { model.screen = .find }
                Spacer()
                PrimaryButton(title: L("app.install")) { model.startInstall() }
            }
        }
    }

    private func option<Extra: View>(isOn: Binding<Bool>, title: String, note: String, @ViewBuilder extra: () -> Extra) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Toggle("", isOn: isOn).toggleStyle(.switch).labelsHidden().tint(neon)
            VStack(alignment: .leading, spacing: 4) {
                Text(title).font(.system(size: 14, weight: .semibold))
                Text(note).font(.system(size: 12)).foregroundStyle(.white.opacity(0.65)).fixedSize(horizontal: false, vertical: true)
                extra()
            }
            Spacer(minLength: 0)
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 12).fill(card))
    }
}

// MARK: - Installing, done, removed

private struct InstallingScreen: View {
    @ObservedObject var model: InstallerModel
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Title(title: L("app.installing.title"), subtitle: model.stepTitle + "…")
            ProgressView(value: model.progress).tint(neon)
            Text("\(Int((model.progress * 100).rounded())) %").font(.system(size: 12, design: .monospaced)).foregroundStyle(.white.opacity(0.6))
            Spacer()
        }
    }
}

private struct DoneScreen: View {
    @ObservedObject var model: InstallerModel
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Title(title: L("app.done.title"), subtitle: L("app.done.subtitle"))
            HStack(spacing: 10) {
                if model.result.launchers[.full] != nil {
                    PrimaryButton(title: L("app.done.open")) { model.open(.full) }
                }
                if model.result.launchers[.demo] != nil {
                    if model.result.launchers[.full] != nil {
                        QuietButton(title: L("app.done.openDemo")) { model.open(.demo) }
                    } else {
                        PrimaryButton(title: L("app.done.openDemo")) { model.open(.demo) }
                    }
                }
            }
            if model.result.wifiSkipped { note(L("app.done.wifiSkipped"), icon: "wifi.exclamationmark") }
            if !model.result.settingsApplied { note(L("app.done.turnOnFG"), icon: "sparkles") }
            note(L("app.update.note"), icon: "info.circle")
            HStack(spacing: 10) {
                if let donate = InstallerModel.donateURL {
                    QuietButton(title: "⚡ " + L("app.done.coffee")) { NSWorkspace.shared.open(donate) }
                }
                if let project = InstallerModel.projectURL {
                    QuietButton(title: L("app.done.project")) { NSWorkspace.shared.open(project) }
                }
            }
            Spacer()
            Footer(model: model)
        }
    }

    private func note(_ text: String, icon: String) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: icon).foregroundStyle(.white.opacity(0.6))
            Text(text).font(.system(size: 12)).foregroundStyle(.white.opacity(0.7)).fixedSize(horizontal: false, vertical: true)
        }
    }
}

private struct RemovedScreen: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Title(title: L("app.uninstall.done"), subtitle: nil)
            QuietButton(title: L("app.close")) { NSApp.terminate(nil) }
            Spacer()
        }
    }
}

private struct UninstallSheet: View {
    @ObservedObject var model: InstallerModel
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(L("app.uninstall.title")).font(.system(size: 18, weight: .bold))
            Text(L("app.uninstall.message")).font(.system(size: 13)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            if Installation.hasSettingsBackup {
                Toggle(L("app.uninstall.restore"), isOn: $model.restoreSettings)
            }
            HStack {
                Spacer()
                Button(L("launcher.cancel")) { dismiss() }.keyboardShortcut(.cancelAction)
                Button(L("app.uninstall"), role: .destructive) {
                    dismiss()
                    model.uninstall()
                }
                .disabled(model.busy)
            }
        }
        .padding(22)
        .frame(width: 400)
        .environment(\.layoutDirection, Texts.rightToLeft ? .rightToLeft : .leftToRight)
    }
}

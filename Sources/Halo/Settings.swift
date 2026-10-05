import AppKit
import Observation
import ServiceManagement
import SwiftUI

/// Everything you can tune in Halo. Each change is saved at once and applied live.
@MainActor
@Observable
final class HaloSettings {
    /// The interface language: French, English, Hebrew, or the Mac's own.
    var language: LanguageChoice = .automatic { didSet { changed("language", language.rawValue) } }
    var iconSize: Double = DockMetrics.standardItem { didSet { changed("iconSize", iconSize) } }
    /// Dock-style magnification under the pointer; 1 turns it off.
    var magnification: Double = 1.55 { didSet { changed("magnification", magnification) } }
    /// Icons shown at once when the bar is docked into the notch.
    var compactVisible: Int = 3 { didSet { changed("compactVisible", compactVisible) } }

    var showPaused = true { didSet { changed("showPaused", showPaused) } }
    var pausedDays: Int = 7 { didSet { changed("pausedDays", pausedDays) } }
    var pausedLimit: Int = 6 { didSet { changed("pausedLimit", pausedLimit) } }
    /// The card that tells what a session is asking or doing, on hover.
    var showDetails = true { didSet { changed("showDetails", showDetails) } }

    var workingEffects = true { didSet { changed("workingEffects", workingEffects) } }
    var bounce = true { didSet { changed("bounce", bounce) } }
    var celebration = true { didSet { changed("celebration", celebration) } }

    var soundWhenWaiting = false { didSet { changed("soundWhenWaiting", soundWhenWaiting) } }
    var soundWhenDone = false { didSet { changed("soundWhenDone", soundWhenDone) } }

    var lang: Lang { language.resolved }
    var strings: Strings { Strings(lang: lang) }

    @ObservationIgnored var onChange: (() -> Void)?
    @ObservationIgnored private let persistent: Bool

    private static let prefix = "halo.settings."

    /// `persistent: false` gives the defaults without touching the saved settings (snapshots).
    init(persistent: Bool = true) {
        self.persistent = persistent
        guard persistent else { return }
        let saved = UserDefaults.standard
        func load<T>(_ key: String, _ apply: (T) -> Void) {
            if let value = saved.object(forKey: Self.prefix + key) as? T { apply(value) }
        }
        load("language") { (raw: String) in language = LanguageChoice(rawValue: raw) ?? .automatic }
        load("iconSize") { iconSize = $0 }
        load("magnification") { magnification = $0 }
        load("compactVisible") { compactVisible = $0 }
        load("showPaused") { showPaused = $0 }
        load("pausedDays") { pausedDays = $0 }
        load("pausedLimit") { pausedLimit = $0 }
        load("showDetails") { showDetails = $0 }
        load("workingEffects") { workingEffects = $0 }
        load("bounce") { bounce = $0 }
        load("celebration") { celebration = $0 }
        load("soundWhenWaiting") { soundWhenWaiting = $0 }
        load("soundWhenDone") { soundWhenDone = $0 }
    }

    func resetToDefaults() {
        let defaults = HaloSettings(persistent: false)
        // The language stays: "defaults" is about how the bar looks and behaves.
        iconSize = defaults.iconSize
        magnification = defaults.magnification
        compactVisible = defaults.compactVisible
        showPaused = defaults.showPaused
        pausedDays = defaults.pausedDays
        pausedLimit = defaults.pausedLimit
        showDetails = defaults.showDetails
        workingEffects = defaults.workingEffects
        bounce = defaults.bounce
        celebration = defaults.celebration
        soundWhenWaiting = defaults.soundWhenWaiting
        soundWhenDone = defaults.soundWhenDone
    }

    private func changed(_ key: String, _ value: Any) {
        guard persistent else { return }
        UserDefaults.standard.set(value, forKey: Self.prefix + key)
        onChange?()
    }
}

// MARK: - Window

struct SettingsActions {
    let hiddenCount: () -> Int
    let unhideAll: () -> Void
    let resetPosition: () -> Void
    let launchAtLogin: Binding<Bool>
}

@MainActor
final class SettingsWindowController {
    private var window: NSWindow?

    func show(settings: HaloSettings, actions: SettingsActions) {
        if window == nil {
            let hosting = NSHostingController(rootView: SettingsView(settings: settings, actions: actions))
            let window = NSWindow(contentViewController: hosting)
            window.title = settings.strings.windowTitle
            window.styleMask = [.titled, .closable]
            window.isReleasedWhenClosed = false
            window.center()
            self.window = window
        }
        updateTitle(settings.strings)
        // Halo has no Dock icon: bring it forward so the window comes to the front.
        NSApp.activate()
        window?.makeKeyAndOrderFront(nil)
    }

    func updateTitle(_ strings: Strings) {
        window?.title = strings.windowTitle
    }
}

struct SettingsView: View {
    @Bindable var settings: HaloSettings
    let actions: SettingsActions

    @State private var hiddenCount = 0
    @State private var trusted = SplitOpener.isTrusted

    var body: some View {
        let s = settings.strings
        Form {
            Section {
                Picker(s.language, selection: $settings.language) {
                    Text(s.languageAutomatic).tag(LanguageChoice.automatic)
                    Divider()
                    ForEach([LanguageChoice.fr, .en, .he]) { choice in
                        Text(choice.resolved.nativeName).tag(choice)
                    }
                }
            }

            Section(s.appearance) {
                LabeledContent(s.iconSize) {
                    Slider(value: $settings.iconSize, in: Double(DockMetrics.itemRange.lowerBound)...Double(DockMetrics.itemRange.upperBound))
                        .frame(width: 200)
                }
                LabeledContent(s.magnification) {
                    HStack {
                        Slider(value: $settings.magnification, in: 1...2).frame(width: 160)
                        Text(settings.magnification < 1.02 ? s.off : String(format: "×%.1f", settings.magnification))
                            .monospacedDigit().foregroundStyle(.secondary).frame(width: 64, alignment: .leading)
                    }
                }
                Stepper(s.notchIcons(settings.compactVisible), value: $settings.compactVisible, in: 2...5)
            }

            Section {
                Toggle(s.showPaused, isOn: $settings.showPaused)
                Picker(s.activeWithin, selection: $settings.pausedDays) {
                    ForEach([1, 3, 7, 14, 30], id: \.self) { Text(s.days($0)).tag($0) }
                }
                .disabled(!settings.showPaused)
                Stepper(s.atMost(settings.pausedLimit), value: $settings.pausedLimit, in: 1...12)
                    .disabled(!settings.showPaused)
                Toggle(s.detailCard, isOn: $settings.showDetails)
                LabeledContent(s.removedSessions) {
                    HStack {
                        Text("\(hiddenCount)").monospacedDigit().foregroundStyle(.secondary)
                        Button(s.showAgain) {
                            actions.unhideAll()
                            hiddenCount = actions.hiddenCount()
                        }
                        .disabled(hiddenCount == 0)
                    }
                }
            } header: {
                Text(s.sessions)
            } footer: {
                Text(s.detailFooter).foregroundStyle(.secondary)
            }

            Section {
                Toggle(s.workingEffects, isOn: $settings.workingEffects)
                Toggle(s.bounces, isOn: $settings.bounce)
                Toggle(s.sparks, isOn: $settings.celebration)
            } header: {
                Text(s.animations)
            } footer: {
                Text(s.motionFooter).foregroundStyle(.secondary)
            }

            Section(s.sounds) {
                Toggle(s.soundWaiting, isOn: $settings.soundWhenWaiting)
                Toggle(s.soundDone, isOn: $settings.soundWhenDone)
            }

            Section {
                Toggle(s.launchAtLogin, isOn: actions.launchAtLogin)
                LabeledContent(s.sideBySide) {
                    HStack {
                        Label(trusted ? s.allowed : s.needsPermission,
                              systemImage: trusted ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                            .foregroundStyle(trusted ? .green : .orange)
                        if !trusted {
                            Button(s.openSystemSettings) {
                                SplitOpener.requestTrust()
                                if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
                                    NSWorkspace.shared.open(url)
                                }
                            }
                        }
                    }
                }
                HStack {
                    Button(s.resetPosition, action: actions.resetPosition)
                    Spacer()
                    Button(s.resetDefaults) { settings.resetToDefaults() }
                }
            } header: {
                Text(s.system)
            } footer: {
                Text("Halo \(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "dev")")
                    .foregroundStyle(.secondary)
            }
        }
        .environment(\.layoutDirection, settings.lang.layoutDirection)
        .environment(\.locale, Locale(identifier: settings.lang.rawValue))
        .formStyle(.grouped)
        .frame(width: 480)
        .fixedSize(horizontal: false, vertical: true)
        .onAppear { hiddenCount = actions.hiddenCount() }
        .task {
            // The permission is granted in System Settings: watch for it while this is open.
            while !Task.isCancelled {
                trusted = SplitOpener.isTrusted
                hiddenCount = actions.hiddenCount()
                try? await Task.sleep(for: .seconds(1))
            }
        }
    }
}

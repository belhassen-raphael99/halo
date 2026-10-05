import AppKit
import Carbon.HIToolbox
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

    /// The system-wide shortcut that shows or hides the bar (Carbon key code and modifier mask).
    var hotKeyEnabled = true { didSet { changed("hotKeyEnabled", hotKeyEnabled) } }
    var hotKeyCode: Int = kVK_ANSI_H { didSet { changed("hotKeyCode", hotKeyCode) } }
    var hotKeyModifiers: Int = controlKey | optionKey { didSet { changed("hotKeyModifiers", hotKeyModifiers) } }
    var hotKeyLabel = "⌃⌥H" { didSet { changed("hotKeyLabel", hotKeyLabel) } }

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
        load("hotKeyEnabled") { hotKeyEnabled = $0 }
        load("hotKeyCode") { hotKeyCode = $0 }
        load("hotKeyModifiers") { hotKeyModifiers = $0 }
        load("hotKeyLabel") { hotKeyLabel = $0 }
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
    let store: SessionStore
    let resetPosition: () -> Void
    let launchAtLogin: Binding<Bool>
}

/// The Settings window: one tab per subject, in the toolbar, like Safari's or Mail's settings.
@MainActor
final class SettingsWindowController {
    private var window: NSWindow?
    var isOpen: Bool { window?.isVisible ?? false }
    private var labels: [(item: NSTabViewItem, text: (Strings) -> String)] = []

    func show(settings: HaloSettings, actions: SettingsActions) {
        if window == nil { window = makeWindow(settings: settings, actions: actions) }
        updateLanguage(settings.strings)
        // Halo has no Dock icon: bring it forward so the window comes to the front.
        NSApp.activate()
        window?.makeKeyAndOrderFront(nil)
    }

    func updateLanguage(_ strings: Strings) {
        window?.title = strings.windowTitle
        for entry in labels { entry.item.label = entry.text(strings) }
    }

    private func makeWindow(settings: HaloSettings, actions: SettingsActions) -> NSWindow {
        let tabs = NSTabViewController()
        tabs.tabStyle = .toolbar
        tabs.transitionOptions = [.crossfade, .allowUserInteraction]

        func add<Content: View>(_ symbol: String, _ text: @escaping (Strings) -> String, _ content: Content) {
            let host = NSHostingController(rootView: SettingsTab(settings: settings, content: content))
            host.sizingOptions = [.preferredContentSize]
            let item = NSTabViewItem(viewController: host)
            item.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)
            item.label = text(settings.strings)
            tabs.addTabViewItem(item)
            labels.append((item, text))
        }
        add("gearshape", { $0.tabGeneral }, GeneralTab(settings: settings, actions: actions))
        add("paintbrush", { $0.tabAppearance }, AppearanceTab(settings: settings))
        add("rectangle.stack", { $0.tabSessions }, SessionsTab(settings: settings, store: actions.store))
        add("sparkles", { $0.tabAnimations }, AnimationsTab(settings: settings))
        add("app.badge", { $0.tabIcons }, IconsTab())

        let window = NSWindow(contentViewController: tabs)
        window.styleMask = [.titled, .closable, .miniaturizable, .resizable]
        window.toolbarStyle = .preference
        window.isReleasedWhenClosed = false
        window.center()
        return window
    }
}

/// What every tab shares: grouped form, the chosen language, right to left in Hebrew.
private struct SettingsTab<Content: View>: View {
    let settings: HaloSettings
    let content: Content

    var body: some View {
        content
            .formStyle(.grouped)
            .frame(minWidth: 500, idealWidth: 560, maxWidth: .infinity, minHeight: 340, idealHeight: 560, maxHeight: .infinity)
            .environment(\.strings, settings.strings)
            .environment(\.layoutDirection, settings.lang.layoutDirection)
            .environment(\.locale, Locale(identifier: settings.lang.rawValue))
    }
}

// MARK: - General

struct GeneralTab: View {
    @Bindable var settings: HaloSettings
    let actions: SettingsActions
    @Environment(\.strings) private var s
    @State private var trusted = SplitOpener.isTrusted

    var body: some View {
        Form {
            Section {
                Picker(s.language, selection: $settings.language) {
                    Text(s.languageAutomatic).tag(LanguageChoice.automatic)
                    Divider()
                    ForEach([LanguageChoice.fr, .en, .he]) { Text($0.resolved.nativeName).tag($0) }
                }
                Toggle(s.launchAtLogin, isOn: actions.launchAtLogin)
            }

            Section {
                LabeledContent(s.shortcut) { ShortcutRecorder(settings: settings) }
            } footer: {
                Text(s.shortcutFooter).foregroundStyle(.secondary)
            }

            Section {
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
            } footer: {
                Text(s.sideBySideFooter).foregroundStyle(.secondary)
            }

            Section {
                HStack {
                    Button(s.resetPosition, action: actions.resetPosition)
                    Spacer()
                    Button(s.resetDefaults) { settings.resetToDefaults() }
                }
            } header: {
                Text(s.position)
            } footer: {
                Text("Halo \(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "dev")")
                    .foregroundStyle(.secondary)
            }
        }
        .task {
            // The permission is granted in System Settings: watch for it while this is open.
            while !Task.isCancelled {
                trusted = SplitOpener.isTrusted
                try? await Task.sleep(for: .seconds(1))
            }
        }
    }
}

/// Click, then type the shortcut. Esc cancels. It needs ⌘, ⌥ or ⌃.
private struct ShortcutRecorder: View {
    @Bindable var settings: HaloSettings
    @Environment(\.strings) private var s
    @State private var recording = false
    @State private var monitor: Any?

    var body: some View {
        HStack(spacing: 8) {
            Button {
                recording ? stop() : start()
            } label: {
                Text(recording ? s.shortcutRecording : (settings.hotKeyEnabled ? settings.hotKeyLabel : s.shortcutRecord))
                    .font(.system(.body, design: settings.hotKeyEnabled && !recording ? .rounded : .default).weight(.medium))
                    .frame(minWidth: 130)
            }
            if settings.hotKeyEnabled && !recording {
                Button(s.shortcutClear) { settings.hotKeyEnabled = false }
            }
        }
        .onDisappear { stop() }
    }

    private func start() {
        recording = true
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            MainActor.assumeIsolated { record(event) }
            return nil
        }
    }

    private func record(_ event: NSEvent) {
        if event.keyCode == UInt16(kVK_Escape) {
            stop()
            return
        }
        let flags = event.modifierFlags.intersection([.command, .option, .control, .shift])
        guard !flags.subtracting(.shift).isEmpty else { return }
        let modifiers = HotKey.carbonModifiers(flags)
        settings.hotKeyCode = Int(event.keyCode)
        settings.hotKeyModifiers = Int(modifiers)
        settings.hotKeyLabel = HotKey.label(modifiers: modifiers, key: HotKey.keyName(event))
        settings.hotKeyEnabled = true
        stop()
    }

    private func stop() {
        recording = false
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
    }
}

// MARK: - Appearance

struct AppearanceTab: View {
    @Bindable var settings: HaloSettings
    @Environment(\.strings) private var s

    var body: some View {
        Form {
            Section(s.preview) {
                BarPreview(settings: settings)
                    .frame(height: 150)
                    .listRowInsets(EdgeInsets(top: 6, leading: 6, bottom: 6, trailing: 6))
            }
            Section {
                LabeledContent(s.iconSize) {
                    HStack {
                        Slider(value: $settings.iconSize,
                               in: Double(DockMetrics.itemRange.lowerBound)...Double(DockMetrics.itemRange.upperBound))
                        Text("\(Int(settings.iconSize)) pt").monospacedDigit().foregroundStyle(.secondary)
                            .frame(width: 48, alignment: .trailing)
                    }
                    .frame(width: 260)
                }
                LabeledContent(s.magnification) {
                    HStack {
                        Slider(value: $settings.magnification, in: 1...2)
                        Text(settings.magnification < 1.02 ? s.off : String(format: "×%.1f", settings.magnification))
                            .monospacedDigit().foregroundStyle(.secondary).frame(width: 48, alignment: .trailing)
                    }
                    .frame(width: 260)
                }
            }
            Section {
                Stepper(s.notchIcons(settings.compactVisible), value: $settings.compactVisible, in: 2...5)
            } footer: {
                Text(s.notchFooter).foregroundStyle(.secondary)
            }
        }
    }
}

/// A live bar with sample sessions: size, magnification and animations as you set them.
/// The pointer sweeps along it so the magnification shows.
private struct BarPreview: View {
    let settings: HaloSettings
    @State private var store = SessionStore(preview: Samples.sessions())
    @State private var pointer = Pointer()
    @State private var layout: DockLayout

    init(settings: HaloSettings) {
        self.settings = settings
        _layout = State(initialValue: DockLayout(settings: settings))
    }

    var body: some View {
        GeometryReader { geo in
            let metrics = layout.metrics
            let size = metrics.windowSize(store.strip, edge: .bottom)
            let barWidth = metrics.barLength(store.strip) + metrics.item
            let visible = metrics.barThickness + metrics.lift + 6
            let scale = min(1, (geo.size.width - 24) / barWidth, (geo.size.height - 12) / visible)
            ZStack(alignment: .bottom) {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(LinearGradient(colors: [Color(hex: 0x5B6FB0), Color(hex: 0xC08A94)],
                                         startPoint: .topLeading, endPoint: .bottomTrailing))
                DockView(store: store, pointer: pointer, layout: layout, actions: .none)
                    .frame(width: size.width, height: size.height)
                    .frame(width: barWidth, height: visible, alignment: .bottom)
                    .clipped()
                    .scaleEffect(scale, anchor: .bottom)
                    .padding(.bottom, 6)
            }
            .frame(width: geo.size.width, height: geo.size.height)
            .task(id: "\(geo.size.width)") { await sweep(windowWidth: size.width) }
        }
    }

    private func sweep(windowWidth: CGFloat) async {
        let start = Date()
        while !Task.isCancelled {
            let centers = layout.metrics.baseCenters(store.strip, mainLength: windowWidth)
            if let first = centers.first, let last = centers.last {
                let phase = 0.5 - 0.5 * cos(Date().timeIntervalSince(start) * 0.8)
                pointer.hover = first + (last - first) * phase
            }
            try? await Task.sleep(for: .milliseconds(33))
        }
    }
}

// MARK: - Sessions

private struct SessionsTab: View {
    @Bindable var settings: HaloSettings
    let store: SessionStore
    @Environment(\.strings) private var s

    var body: some View {
        Form {
            Section {
                Toggle(s.showPaused, isOn: $settings.showPaused)
                if settings.showPaused {
                    Picker(s.pausedWithin, selection: $settings.pausedDays) {
                        ForEach([1, 3, 7, 14, 30], id: \.self) { Text(s.days($0)).tag($0) }
                    }
                    Stepper(s.atMost(settings.pausedLimit), value: $settings.pausedLimit, in: 1...12)
                }
            } footer: {
                Text(settings.showPaused ? s.pausedShown(store.sessions.filter { !$0.isLive }.count) : s.pausedOffFooter)
                    .foregroundStyle(.secondary)
            }

            Section {
                Toggle(s.detailCard, isOn: $settings.showDetails)
            } footer: {
                Text(s.detailFooter).foregroundStyle(.secondary)
            }

            Section {
                if store.hidden.isEmpty {
                    Text(s.removedEmpty).foregroundStyle(.secondary)
                } else {
                    ForEach(store.hidden) { item in
                        HStack(spacing: 10) {
                            IconFace(icon: AppIcon.for(name: item.name, cwd: ""), size: 24, state: .rest)
                            Text(item.name).lineLimit(1)
                            Spacer()
                            Button(s.showAgain) { store.unhide(item.id) }
                        }
                    }
                    if store.hidden.count > 1 {
                        Button(s.showAllAgain) { store.unhideAll() }
                    }
                }
            } header: {
                Text(s.removedSessions)
            } footer: {
                Text(s.removedFooter).foregroundStyle(.secondary)
            }
        }
    }
}

// MARK: - Animations and sounds

private struct AnimationsTab: View {
    @Bindable var settings: HaloSettings
    @Environment(\.strings) private var s

    var body: some View {
        Form {
            Section {
                Toggle(s.workingEffects, isOn: $settings.workingEffects)
                Toggle(s.bounces, isOn: $settings.bounce)
                Toggle(s.sparks, isOn: $settings.celebration)
            } footer: {
                Text(s.motionFooter).foregroundStyle(.secondary)
            }
            Section(s.sounds) {
                sound(s.soundWaiting, isOn: $settings.soundWhenWaiting, name: "Glass")
                sound(s.soundDone, isOn: $settings.soundWhenDone, name: "Pop")
            }
        }
    }

    private func sound(_ title: String, isOn: Binding<Bool>, name: String) -> some View {
        LabeledContent(title) {
            HStack(spacing: 10) {
                Button {
                    NSSound(named: name)?.play()
                } label: {
                    Label(s.play, systemImage: "speaker.wave.2.fill")
                }
                Toggle("", isOn: isOn).labelsHidden()
            }
        }
    }
}

// MARK: - Icons

private struct IconsTab: View {
    @State private var rules = IconRulesStore.shared
    @State private var sample = ""
    @State private var editing: UUID?
    @Environment(\.strings) private var s

    var body: some View {
        Form {
            Section {
                Text(s.iconsIntro).foregroundStyle(.secondary)
                let match = AppIcon.match(name: sample, cwd: "")
                HStack(spacing: 12) {
                    IconFace(icon: match.icon, size: 36, state: .rest)
                    TextField(s.tryName, text: $sample, prompt: Text(s.tryPlaceholder))
                    if !sample.isEmpty {
                        Text(source(match.source)).foregroundStyle(.secondary).fixedSize()
                    }
                }
            }

            Section {
                if rules.rules.isEmpty {
                    Text(s.noRules).foregroundStyle(.secondary)
                }
                ForEach(rules.rules) { rule in
                    RuleRow(rule: rule, expanded: editing == rule.id) {
                        editing = editing == rule.id ? nil : rule.id
                    }
                }
            } header: {
                HStack {
                    Text(s.yourRules)
                    Spacer()
                    Button {
                        rules.add()
                        editing = rules.rules.first?.id
                    } label: {
                        Label(s.addRule, systemImage: "plus")
                    }
                    .buttonStyle(.borderless)
                }
            }
        }
    }

    private func source(_ source: AppIcon.Source) -> String {
        switch source {
        case .yours: return s.sourceYours
        case .halo: return s.sourceHalo
        case .fallback: return s.sourceFallback
        }
    }
}

/// A rule: its icon and keywords; expanded, everything is editable.
private struct RuleRow: View {
    let rule: CustomIconRule
    let expanded: Bool
    let toggle: () -> Void
    @Environment(\.strings) private var s
    @State private var keywords = ""
    @State private var symbol = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 12) {
                IconFace(icon: icon, size: 30, state: .rest)
                Text(rule.keywords.isEmpty ? "—" : rule.keywords.joined(separator: ", "))
                    .lineLimit(1)
                Spacer()
                Button(expanded ? s.done : s.edit, action: toggle)
                Button(role: .destructive) {
                    IconRulesStore.shared.remove(rule.id)
                } label: {
                    Image(systemName: "trash")
                }
                .buttonStyle(.borderless)
                .accessibilityLabel(s.delete)
            }
            if expanded {
                TextField(s.keywords, text: $keywords, prompt: Text("client, acme"))
                    .onChange(of: keywords) {
                        var updated = rule
                        updated.keywords = keywords.split(separator: ",")
                            .map { $0.trimmingCharacters(in: .whitespaces) }
                            .filter { !$0.isEmpty }
                        IconRulesStore.shared.update(updated)
                    }
                HStack {
                    TextField(s.symbolName, text: $symbol)
                        .onChange(of: symbol) {
                            guard SymbolChoices.exists(symbol) else { return }
                            var updated = rule
                            updated.symbol = symbol
                            IconRulesStore.shared.update(updated)
                        }
                    if !SymbolChoices.exists(symbol) {
                        Text(s.unknownSymbol).foregroundStyle(.orange).font(.caption)
                    }
                }
                LazyVGrid(columns: Array(repeating: GridItem(.fixed(30), spacing: 6), count: 10), spacing: 6) {
                    ForEach(SymbolChoices.all, id: \.self) { name in
                        Button {
                            symbol = name
                        } label: {
                            Image(systemName: name)
                                .frame(width: 30, height: 26)
                                .background(RoundedRectangle(cornerRadius: 6)
                                    .fill(rule.symbol == name ? Color.accentColor.opacity(0.35) : Color.primary.opacity(0.06)))
                        }
                        .buttonStyle(.plain)
                    }
                }
                HStack(spacing: 18) {
                    ColorPicker(s.colorTop, selection: color(\.top))
                    ColorPicker(s.colorBottom, selection: color(\.bottom))
                }
            }
        }
        .padding(.vertical, 4)
        .onAppear {
            keywords = rule.keywords.joined(separator: ", ")
            symbol = rule.symbol
        }
    }

    private var icon: AppIcon {
        AppIcon(symbol: rule.symbol,
                top: Color(hex: CustomIconRule.hex(rule.top) ?? 0x888888),
                bottom: Color(hex: CustomIconRule.hex(rule.bottom) ?? 0x444444))
    }

    private func color(_ key: WritableKeyPath<CustomIconRule, String>) -> Binding<Color> {
        Binding(
            get: { Color(hex: CustomIconRule.hex(rule[keyPath: key]) ?? 0x888888) },
            set: { newColor in
                var updated = rule
                updated[keyPath: key] = CustomIconRule.hexString(newColor)
                IconRulesStore.shared.update(updated)
            })
    }
}

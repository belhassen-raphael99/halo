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
    /// Dock-style magnification under the pointer.
    var zoomEnabled = true { didSet { changed("zoomEnabled", zoomEnabled) } }
    var magnification: Double = 1.55 { didSet { changed("magnification", magnification) } }
    /// The notch shows few icons: there, the hovered one only grows a little, unless this is on.
    var zoomInNotch = false { didSet { changed("zoomInNotch", zoomInNotch) } }
    /// Icons shown at once when the bar is docked into the notch.
    var compactVisible: Int = 3 { didSet { changed("compactVisible", compactVisible) } }

    var showPaused = true { didSet { changed("showPaused", showPaused) } }
    var pausedDays: Int = 7 { didSet { changed("pausedDays", pausedDays) } }
    var pausedLimit: Int = 6 { didSet { changed("pausedLimit", pausedLimit) } }
    /// The card that tells what a session is asking or doing, on hover.
    var showDetails = true { didSet { changed("showDetails", showDetails) } }

    var workingEffects = true { didSet { changed("workingEffects", workingEffects) } }
    /// What a working session looks like: ring, glow, comet, trace, waves or dots.
    var workingStyle = WorkingStyle.aurora { didSet { changed("workingStyle", workingStyle.rawValue) } }
    var bounce = true { didSet { changed("bounce", bounce) } }
    var celebration = true { didSet { changed("celebration", celebration) } }

    var soundWhenWaiting = false { didSet { changed("soundWhenWaiting", soundWhenWaiting) } }
    var soundWhenDone = false { didSet { changed("soundWhenDone", soundWhenDone) } }
    /// macOS notifications, clickable to open the session.
    var notifyWaiting = false { didSet { changed("notifyWaiting", notifyWaiting) } }
    var notifyDone = false { didSet { changed("notifyDone", notifyDone) } }

    /// The bar fades away when nothing needs you, or over a full-screen app.
    var hideWhenCalm = false { didSet { changed("hideWhenCalm", hideWhenCalm) } }
    var hideInFullScreen = false { didSet { changed("hideInFullScreen", hideInFullScreen) } }

    var sessionOrder = SessionOrder.opened { didSet { changed("sessionOrder", sessionOrder.rawValue) } }
    /// Project folders whose sessions stay off the bar.
    var excludedProjects: [String] = [] { didSet { changed("excludedProjects", excludedProjects) } }

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

    /// The demo (`Halo --demo`): defaults, in English, never saved.
    static func demo() -> HaloSettings {
        let settings = HaloSettings(persistent: false)
        settings.language = .en
        return settings
    }

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
        // Before 0.4 a magnification of 1 meant "off".
        if saved.object(forKey: Self.prefix + "zoomEnabled") == nil, magnification < 1.02 {
            zoomEnabled = false
            magnification = 1.55
        }
        load("zoomEnabled") { zoomEnabled = $0 }
        load("zoomInNotch") { zoomInNotch = $0 }
        load("compactVisible") { compactVisible = $0 }
        load("showPaused") { showPaused = $0 }
        load("pausedDays") { pausedDays = $0 }
        load("pausedLimit") { pausedLimit = $0 }
        load("showDetails") { showDetails = $0 }
        load("workingEffects") { workingEffects = $0 }
        load("workingStyle") { (raw: String) in workingStyle = WorkingStyle(rawValue: raw) ?? .aurora }
        load("bounce") { bounce = $0 }
        load("celebration") { celebration = $0 }
        load("soundWhenWaiting") { soundWhenWaiting = $0 }
        load("soundWhenDone") { soundWhenDone = $0 }
        load("notifyWaiting") { notifyWaiting = $0 }
        load("notifyDone") { notifyDone = $0 }
        load("hideWhenCalm") { hideWhenCalm = $0 }
        load("hideInFullScreen") { hideInFullScreen = $0 }
        load("sessionOrder") { (raw: String) in sessionOrder = SessionOrder(rawValue: raw) ?? .opened }
        load("excludedProjects") { excludedProjects = $0 }
        load("hotKeyEnabled") { hotKeyEnabled = $0 }
        load("hotKeyCode") { hotKeyCode = $0 }
        load("hotKeyModifiers") { hotKeyModifiers = $0 }
        load("hotKeyLabel") { hotKeyLabel = $0 }
    }

    func resetToDefaults() {
        let defaults = HaloSettings(persistent: false)
        // The language stays: "defaults" is about how the bar looks and behaves.
        iconSize = defaults.iconSize
        zoomEnabled = defaults.zoomEnabled
        magnification = defaults.magnification
        zoomInNotch = defaults.zoomInNotch
        compactVisible = defaults.compactVisible
        showPaused = defaults.showPaused
        pausedDays = defaults.pausedDays
        pausedLimit = defaults.pausedLimit
        showDetails = defaults.showDetails
        workingEffects = defaults.workingEffects
        workingStyle = defaults.workingStyle
        bounce = defaults.bounce
        celebration = defaults.celebration
        soundWhenWaiting = defaults.soundWhenWaiting
        soundWhenDone = defaults.soundWhenDone
        hideWhenCalm = defaults.hideWhenCalm
        hideInFullScreen = defaults.hideInFullScreen
        sessionOrder = defaults.sessionOrder
    }

    private func changed(_ key: String, _ value: Any) {
        guard persistent else { return }
        UserDefaults.standard.set(value, forKey: Self.prefix + key)
        onChange?()
    }
}

/// The order of the icons on the bar (pinned sessions always come first).
enum SessionOrder: String, CaseIterable, Identifiable, Sendable {
    case opened, recent, name, urgency
    var id: String { rawValue }
}

// MARK: - Window

struct SettingsActions {
    let store: SessionStore
    let layout: DockLayout
    /// "bottom", "top", "left", "right" or "floating".
    let place: (String) -> Void
    let moveToScreen: (Int) -> Void
    let launchAtLogin: Binding<Bool>
}

/// The Settings window: one tab per subject, in the toolbar, like Safari's or Mail's settings.
@MainActor
final class SettingsWindowController {
    private var window: NSWindow?
    var isOpen: Bool { window?.isVisible ?? false }
    /// Over every other window (the demo, filmed over a backdrop).
    var floatsAbove = false
    private var labels: [(item: NSTabViewItem, text: (Strings) -> String)] = []

    func show(settings: HaloSettings, actions: SettingsActions) {
        if window == nil { window = makeWindow(settings: settings, actions: actions) }
        if floatsAbove { window?.level = AppController.demoLevel }
        updateLanguage(settings.strings)
        // Halo has no Dock icon: bring it forward so the window comes to the front.
        NSApp.activate()
        window?.makeKeyAndOrderFront(nil)
    }

    func updateLanguage(_ strings: Strings) {
        window?.title = strings.windowTitle
        for entry in labels {
            entry.item.label = entry.text(strings)
            // The window takes the selected tab's title, like Safari's settings.
            entry.item.viewController?.title = entry.text(strings)
        }
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
            host.title = item.label
            tabs.addTabViewItem(item)
            labels.append((item, text))
        }
        add("gearshape", { $0.tabGeneral }, GeneralTab(settings: settings, actions: actions))
        add("paintbrush", { $0.tabAppearance }, AppearanceTab(settings: settings))
        add("rectangle.stack", { $0.tabSessions }, SessionsTab(settings: settings, store: actions.store))
        add("sparkles", { $0.tabAnimations }, AnimationsTab(settings: settings))
        add("app.badge", { $0.tabIcons }, IconsTab(store: actions.store))

        let window = NSWindow(contentViewController: tabs)
        window.styleMask = [.titled, .closable, .miniaturizable, .resizable]
        window.toolbarStyle = .preference
        window.isReleasedWhenClosed = false
        window.center()
        // A closed window keeps its views, and their live preview would keep running:
        // drop it all, it is rebuilt next time.
        NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification, object: window,
                                               queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                DispatchQueue.main.async {
                    self?.window?.contentViewController = nil
                    self?.window = nil
                    self?.labels = []
                }
            }
        }
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

    private var placeChoice: String { actions.layout.floating ? "floating" : actions.layout.edge.rawValue }

    /// Whether the bar's screen has a notch (the "top" choice then melts into it).
    private var hasNotch: Bool {
        let screens = NSScreen.screens
        let screen = screens.indices.contains(actions.layout.screenIndex) ? screens[actions.layout.screenIndex] : NSScreen.main
        return (screen?.safeAreaInsets.top ?? 0) > 0
    }

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
                Picker(s.barPlace, selection: Binding(get: { placeChoice }, set: { actions.place($0) })) {
                    Text(s.placeBottom).tag("bottom")
                    Text(s.placeTop(notch: hasNotch)).tag("top")
                    Text(s.placeLeft).tag("left")
                    Text(s.placeRight).tag("right")
                    Text(s.placeFree).tag("floating")
                }
                if NSScreen.screens.count > 1 {
                    Picker(s.screen, selection: Binding(get: { actions.layout.screenIndex },
                                                        set: { actions.moveToScreen($0) })) {
                        ForEach(Array(NSScreen.screens.enumerated()), id: \.offset) { index, screen in
                            Text(screen.localizedName).tag(index)
                        }
                    }
                }
            } header: {
                Text(s.position)
            } footer: {
                Text(s.positionFooter).foregroundStyle(.secondary)
            }

            Section {
                Toggle(s.hideWhenCalm, isOn: $settings.hideWhenCalm)
                Toggle(s.hideInFullScreen, isOn: $settings.hideInFullScreen)
            } header: {
                Text(s.autoHide)
            } footer: {
                Text(s.autoHideFooter(settings.hotKeyEnabled ? settings.hotKeyLabel : nil)).foregroundStyle(.secondary)
            }

            Section {
                HStack {
                    Text("Halo \(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "dev")")
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button(s.resetDefaults) { settings.resetToDefaults() }
                }
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
            }
            Section {
                Toggle(s.zoomOnHover, isOn: $settings.zoomEnabled)
                if settings.zoomEnabled {
                    LabeledContent(s.zoomStrength) {
                        HStack {
                            Slider(value: $settings.magnification, in: 1.1...2)
                            Text(String(format: "×%.1f", settings.magnification))
                                .monospacedDigit().foregroundStyle(.secondary).frame(width: 48, alignment: .trailing)
                        }
                        .frame(width: 260)
                    }
                    Toggle(s.zoomInNotch, isOn: $settings.zoomInNotch)
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
            // One pass of the pointer when the tab opens and after each change, then it rests.
            .task(id: "\(geo.size.width)|\(settings.iconSize)|\(settings.magnification)|\(settings.zoomEnabled)") {
                await sweep(windowWidth: size.width)
            }
        }
    }

    private func sweep(windowWidth: CGFloat) async {
        let start = Date()
        let duration = 3.2
        while !Task.isCancelled, Date().timeIntervalSince(start) < duration {
            let centers = layout.metrics.baseCenters(store.strip, mainLength: windowWidth)
            if let first = centers.first, let last = centers.last {
                let phase = 0.5 - 0.5 * cos(Date().timeIntervalSince(start) / duration * 2 * .pi)
                pointer.hover = first + (last - first) * phase
            }
            try? await Task.sleep(for: .milliseconds(33))
        }
        pointer.hover = nil
    }
}

// MARK: - Sessions

struct SessionsTab: View {
    @Bindable var settings: HaloSettings
    let store: SessionStore
    @Environment(\.strings) private var s

    private var pinnedSessions: [Session] {
        store.pinned.compactMap { id in store.sessions.first { $0.id == id } }
    }

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
                Picker(s.order, selection: $settings.sessionOrder) {
                    ForEach(SessionOrder.allCases) { Text(s.orderName($0)).tag($0) }
                }
                if !pinnedSessions.isEmpty {
                    LabeledContent(s.pinned) {
                        Text(pinnedSessions.map(\.name).joined(separator: ", ")).lineLimit(2).foregroundStyle(.secondary)
                    }
                }
            } footer: {
                Text(s.orderFooter).foregroundStyle(.secondary)
            }

            Section {
                if store.projects.isEmpty {
                    Text(s.noProjects).foregroundStyle(.secondary)
                }
                ForEach(store.projects, id: \.self) { path in
                    Toggle(isOn: Binding(
                        get: { !settings.excludedProjects.contains(path) },
                        set: { shown in
                            if shown { settings.excludedProjects.removeAll { $0 == path } }
                            else { settings.excludedProjects.append(path) }
                        })) {
                        Label(URL(fileURLWithPath: path).lastPathComponent, systemImage: "folder")
                    }
                    .help(path)
                }
            } header: {
                Text(s.projects)
            } footer: {
                Text(s.projectsFooter).foregroundStyle(.secondary)
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

struct AnimationsTab: View {
    @Bindable var settings: HaloSettings
    @Environment(\.strings) private var s
    @State private var notifier = Notifier.shared

    var body: some View {
        Form {
            Section {
                StyleGallery(selection: $settings.workingStyle)
                    .listRowInsets(EdgeInsets(top: 8, leading: 8, bottom: 8, trailing: 8))
            } header: {
                Text(s.whileWorking)
            } footer: {
                Text(s.styleDescription(settings.workingStyle)).foregroundStyle(.secondary)
            }
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
            Section {
                Toggle(s.notifyWaiting, isOn: notifying($settings.notifyWaiting))
                Toggle(s.notifyDone, isOn: notifying($settings.notifyDone))
                if notifier.allowed == false {
                    LabeledContent(s.notificationsDenied) {
                        Button(s.openSystemSettings) {
                            if let url = URL(string: "x-apple.systempreferences:com.apple.Notifications-Settings.extension") {
                                NSWorkspace.shared.open(url)
                            }
                        }
                    }
                    .foregroundStyle(.orange)
                }
            } header: {
                Text(s.notifications)
            } footer: {
                Text(s.notificationsFooter).foregroundStyle(.secondary)
            }
        }
        .task {
            // The choice is made in System Settings: follow it while this is open.
            while !Task.isCancelled {
                await notifier.refresh()
                try? await Task.sleep(for: .seconds(2))
            }
        }
    }

    /// Turning a notification on asks macOS for permission the first time.
    private func notifying(_ binding: Binding<Bool>) -> Binding<Bool> {
        Binding(get: { binding.wrappedValue }, set: { on in
            binding.wrappedValue = on
            if on, notifier.allowed == nil { Task { await notifier.requestPermission() } }
        })
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

/// The working animations side by side, each one live: click to choose.
private struct StyleGallery: View {
    @Binding var selection: WorkingStyle
    @Environment(\.strings) private var s

    private static let sample = Session(id: "style-preview", pid: 1, name: "Landing page redesign", cwd: "",
                                        isDesktop: true, hostSessionId: nil, state: .working, stateSince: 0)

    var body: some View {
        LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 10), count: 3), spacing: 10) {
            ForEach(WorkingStyle.allCases) { style in
                let selected = style == selection
                VStack(spacing: 4) {
                    IconView(session: Self.sample, size: 40, metrics: DockMetrics(item: 40), edge: .bottom,
                             showName: false, showClose: false, close: {})
                        .environment(\.dockEffects, DockEffects(style: style))
                        .frame(width: 96, height: 72)
                    Text(s.styleName(style))
                        .font(.callout.weight(selected ? .semibold : .regular))
                }
                .padding(.vertical, 6)
                .frame(maxWidth: .infinity)
                .background(RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(selected ? Color.accentColor.opacity(0.12) : Color.primary.opacity(0.03)))
                .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .strokeBorder(selected ? Color.accentColor : Color.primary.opacity(0.1), lineWidth: selected ? 2 : 1))
                .contentShape(Rectangle())
                .onTapGesture { selection = style }
                .accessibilityElement()
                .accessibilityLabel(s.styleName(style))
                .accessibilityAddTraits(selected ? [.isButton, .isSelected] : .isButton)
            }
        }
    }
}

// MARK: - Icons

struct IconsTab: View {
    let store: SessionStore
    @State private var rules = IconRulesStore.shared
    @State private var sample = ""
    @State private var editing: UUID?
    @Environment(\.strings) private var s

    var body: some View {
        Form {
            Section {
                Text(s.iconsIntro).foregroundStyle(.secondary)
                Picker(s.autoIcons, selection: $rules.autoStyle) {
                    Text(s.autoSymbols).tag(AutoIconStyle.symbols)
                    Text(s.autoInitials).tag(AutoIconStyle.initials)
                    Text(s.autoSparkle).tag(AutoIconStyle.sparkle)
                }
            } footer: {
                Text(s.autoFooter(SymbolCatalog.shared.names.count)).foregroundStyle(.secondary)
            }

            Section {
                if store.sessions.isEmpty {
                    Text(s.noSessions).foregroundStyle(.secondary)
                }
                ForEach(store.sessions) { session in
                    let match = AppIcon.match(name: session.name, cwd: session.cwd)
                    HStack(spacing: 10) {
                        IconFace(icon: match.icon, size: 28, state: .rest)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(session.name).lineLimit(1)
                            Text(source(match.source)).font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        if match.source != .yours {
                            Button {
                                rules.nextIcon(for: session.name)
                            } label: {
                                Label(s.another, systemImage: "dice")
                            }
                            Button(s.keep) {
                                rules.add(keeping: match.icon, for: session.name)
                                editing = rules.rules.first?.id
                            }
                        }
                    }
                }
            } header: {
                Text(s.yourSessions)
            } footer: {
                Text(s.yourSessionsFooter).foregroundStyle(.secondary)
            }

            Section {
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
        case .generated: return s.sourceGenerated
        case .initials: return s.sourceInitials
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
    @State private var query = ""

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
                // Every SF Symbol of this Mac, searchable; a short list until you type.
                let found = query.isEmpty ? SymbolChoices.all : SymbolCatalog.shared.search(query)
                HStack {
                    TextField(s.searchSymbols, text: $query, prompt: Text(s.searchPrompt))
                    if !query.isEmpty {
                        Text(s.symbolCount(found.count)).foregroundStyle(.secondary).font(.caption).fixedSize()
                    }
                }
                if found.isEmpty {
                    Text(s.noSymbol).foregroundStyle(.secondary)
                } else {
                    ScrollView {
                        LazyVGrid(columns: Array(repeating: GridItem(.fixed(30), spacing: 6), count: 10), spacing: 6) {
                            ForEach(found, id: \.self) { name in
                                Button {
                                    symbol = name
                                } label: {
                                    Image(systemName: name)
                                        .frame(width: 30, height: 26)
                                        .background(RoundedRectangle(cornerRadius: 6)
                                            .fill(rule.symbol == name ? Color.accentColor.opacity(0.35)
                                                                      : Color.primary.opacity(0.06)))
                                }
                                .buttonStyle(.plain)
                                .help(name)
                            }
                        }
                    }
                    .frame(height: found.count > 40 ? 170 : nil)
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

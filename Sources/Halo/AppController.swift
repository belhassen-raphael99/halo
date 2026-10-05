import AppKit
import ServiceManagement
import SwiftUI

/// A floating panel that never steals focus from the app you are working in.
final class HaloPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

/// Lets the first click on an inactive window reach the icon instead of being eaten.
final class HaloHostingView<Content: View>: NSHostingView<Content> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

/// Where the bar sits on screen.
enum Placement: Equatable {
    /// Free-floating, horizontal: the bar's bottom-center, in screen coordinates.
    case floating(NSPoint)
    /// Stuck to a screen edge; the point picks the screen and the position along the edge.
    case docked(DockEdge, NSPoint)
}

@MainActor
final class AppController: NSObject, NSApplicationDelegate {
    /// `Halo --demo`: sample sessions that come to life on a script, in English, with
    /// nothing read from Claude and nothing saved. To try Halo, or to film it.
    static var demo = false
    /// Just above the menu bar (and a backdrop covering it), below menus.
    static let demoLevel = NSWindow.Level(rawValue: NSWindow.Level.statusBar.rawValue + 1)

    private let settings = AppController.demo ? HaloSettings.demo() : HaloSettings()
    private lazy var store = AppController.demo ? SessionStore(demo: Samples.demoScript, settings: settings)
                                                : SessionStore(settings: settings)
    private let pointer = Pointer()
    private lazy var layout = DockLayout(settings: settings)
    private let settingsWindow = SettingsWindowController()
    private var panel: HaloPanel!
    private var monitors: [Any] = []
    private var placement: Placement = .docked(.bottom, .zero)
    private var strip = Strip(count: 0, dividerBefore: nil)

    /// Mouse down inside the bar: where it started, to tell a click from a drag.
    private var press: (mouse: NSPoint, origin: NSPoint)?
    private var dragging = false
    private var lastDragEnd = Date.distantPast

    private static let placementKey = "halo.placement"
    private static let dragThreshold: CGFloat = 3
    /// Dropped closer than this to a screen edge, the bar docks to it.
    private static let snapDistance: CGFloat = 90

    func applicationDidFinishLaunching(_ notification: Notification) {
        panel = HaloPanel(contentRect: NSRect(x: 0, y: 0, width: 400, height: 170),
                          styleMask: [.borderless, .nonactivatingPanel],
                          backing: .buffered, defer: false)
        panel.isFloatingPanel = true
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = false
        panel.hidesOnDeactivate = false
        panel.acceptsMouseMovedEvents = true
        // Transparent until the pointer reaches the bar: clicks around it go to the apps below.
        panel.ignoresMouseEvents = true

        let actions = DockActions(
            open: { [weak self] session in self?.open(session) },
            openBeside: { [weak self] session in self?.open(session, beside: true) },
            close: { [weak self] session in self?.store.hide(session) },
            unhideAll: { [weak self] in self?.store.unhideAll() },
            setIconSize: { [weak self] size in self?.setIconSize(size) },
            showSettings: { [weak self] in
                // The click that ends a drag must not open the settings.
                guard let self, !dragging, Date().timeIntervalSince(lastDragEnd) > 0.3 else { return }
                showSettings()
            },
            hideBar: { [weak self] in self?.panel.orderOut(nil) },
            showWaiting: { Self.openURL("claude://code/needs-input") },
            launchAtLogin: Binding(get: { Self.launchesAtLogin }, set: { Self.setLaunchAtLogin($0) }),
            quit: { NSApp.terminate(nil) }
        )
        panel.contentView = HaloHostingView(
            rootView: DockView(store: store, pointer: pointer, layout: layout, actions: actions)
                .environment(\.previewDetails, Self.demo ? Samples.details(settings.strings) : [:]))

        placement = (Self.demo ? nil : savedPlacement())
            ?? .docked(.bottom, NSPoint(x: NSScreen.main?.frame.midX ?? 0, y: 0))
        if !Self.demo { store.loadHidden() }
        // In the demo, the bar and Settings float over everything (a backdrop may hide the desktop).
        settingsWindow.floatsAbove = Self.demo
        store.onChange = { [weak self] in self?.sessionsChanged() }
        store.onStateChange = { [weak self] session, old in self?.announce(session, from: old) }
        Notifier.shared.onOpen = { [weak self] host in self?.open(host: host) }
        if !Self.demo { Notifier.shared.setUp() }
        // Size, magnification and the notch's icon count change the window: re-place it.
        settings.onChange = { [weak self] in
            guard let self else { return }
            applyPlacement(animated: false)
            settingsWindow.updateLanguage(settings.strings)
            registerHotKey()
            updateAutoHide()
        }
        HotKey.shared.onPress = { [weak self] in self?.toggleBar() }
        registerHotKey()
        store.start()
        strip = store.strip
        applyPlacement(animated: false)
        panel.orderFrontRegardless()

        installMouseMonitors()
        statusTimer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.writeStatus() }
        }
        // Full-screen apps, for the auto-hide: checked every second, only while that option is on.
        fullScreenTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.checkFullScreen() }
        }
        NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.applyPlacement(animated: false) }
        }
    }

    // MARK: - Sessions

    private func sessionsChanged() {
        updateAutoHide()
        guard store.strip != strip else { return }
        strip = store.strip
        if !dragging { applyPlacement(animated: false) }
    }

    /// Click: open in place. ⌥-click (or "Ouvrir à côté"): open next to the session already
    /// showing, in a split pane of the Claude app.
    private func open(_ session: Session, beside: Bool = false) {
        // The click that ends a drag must not open a session.
        guard !dragging, Date().timeIntervalSince(lastDragEnd) > 0.3 else { return }
        store.acknowledge(session)
        // The id comes from files on disk: only ever build the link from a well-formed one.
        guard session.isDesktop, let host = session.hostSessionId,
              host.wholeMatch(of: /local_[A-Za-z0-9-]{1,64}/) != nil,
              let url = URL(string: "claude://code/continue?session=\(host)") else { return }
        if beside || NSEvent.modifierFlags.contains(.option) {
            if !SplitOpener.isTrusted { SplitOpener.requestTrust() }
            Task {
                if await SplitOpener.openPaneOnTheRight() {
                    // The new pane takes a moment to open and take the focus; then the session
                    // is clicked in Claude's sidebar, which opens it there, history and all.
                    try? await Task.sleep(for: .milliseconds(900))
                    // Only ever click into Claude: if another app came to the front, just say what to do.
                    if let point = await SplitOpener.sidebarPoint(title: session.name), SplitOpener.claudeIsInFront {
                        SplitOpener.click(at: point)
                    } else {
                        showToast(settings.strings.pickInSidebar(session.name))
                    }
                } else {
                    NSWorkspace.shared.open(url)
                }
            }
        } else {
            NSWorkspace.shared.open(url)
        }
    }

    /// Pinch or menu: icons and bar shrink or grow together, within `DockMetrics.itemRange`.
    private func setIconSize(_ size: CGFloat) {
        let clamped = Double(DockMetrics(item: size).item)
        guard clamped != settings.iconSize else { return }
        settings.iconSize = clamped
    }

    /// A notification was clicked: open its session (the id comes from Halo's own notification).
    private func open(host: String) {
        guard host.wholeMatch(of: /local_[A-Za-z0-9-]{1,64}/) != nil,
              let url = URL(string: "claude://code/continue?session=\(host)") else { return }
        if let session = store.sessions.first(where: { $0.hostSessionId == host }) { store.acknowledge(session) }
        NSWorkspace.shared.open(url)
    }

    private func showSettings() {
        settingsWindow.show(settings: settings, actions: SettingsActions(
            store: store,
            layout: layout,
            place: { [weak self] choice in self?.place(choice) },
            moveToScreen: { [weak self] index in self?.move(toScreen: index) },
            launchAtLogin: Binding(get: { Self.launchesAtLogin }, set: { Self.setLaunchAtLogin($0) })))
    }

    // MARK: - Show and hide

    /// The global shortcut from Settings, or none.
    // MARK: - Status

    private var statusTimer: Timer?

    /// What the running bar is doing, for `Halo --status` (checks without looking at the screen).
    /// Screen points use AppKit coordinates (origin bottom-left).
    private func writeStatus() {
        let frame = panel.frame
        let edge = layout.edge
        let metrics = layout.metrics
        let shown = layout.shownStrip(strip)
        let bar = metrics.barRect(shown, edge: edge, windowSize: frame.size, topInset: layout.topInset)
        let crossCenter = edge.isHorizontal ? bar.minY + (edge == .top ? layout.topInset : 0) + metrics.barThickness / 2
                                            : bar.midX
        func screen(along: CGFloat) -> [Double] {
            edge.isHorizontal
                ? [Double(frame.minX + along), Double(frame.maxY - crossCenter)]
                : [Double(frame.minX + crossCenter), Double(frame.maxY - along)]
        }
        let ordered = layout.isCompact ? DockView.byUrgency(store.sessions) : store.sessions
        let centers: [CGFloat] = layout.isCompact
            ? (0..<shown.count).map { (edge.isHorizontal ? bar.minX : bar.minY) + metrics.padding + metrics.item / 2
                + CGFloat($0) * (metrics.item + metrics.spacing) }
            : metrics.baseCenters(strip, mainLength: edge.isHorizontal ? frame.width : frame.height)
        let icons: [[String: Any]] = zip(ordered, centers).map { session, center in
            ["name": session.name, "state": settings.strings.label(session.state), "point": screen(along: center)]
        }
        let gearAlong = (edge.isHorizontal ? bar.maxX : bar.maxY) - metrics.padding - metrics.gearSize / 2
        let status: [String: Any] = [
            "version": Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "dev",
            "accessibilityTrusted": SplitOpener.isTrusted,
            "hotKey": settings.hotKeyEnabled ? settings.hotKeyLabel : "off",
            "hotKeyRegistered": HotKey.shared.isRegistered,
            "hotKeyHandler": Int(HotKey.shared.handlerStatus),
            "hotKeyPresses": HotKey.shared.presses,
            "barVisible": panel.isVisible,
            "autoHidden": autoHidden,
            "notifications": Notifier.shared.allowed.map { $0 ? "allowed" : "denied" } ?? "not asked",
            "fullScreenApp": fullScreenOnBarScreen,
            "edge": edge.rawValue + (layout.notch != nil ? " (notch)" : ""),
            "language": settings.lang.rawValue,
            "settingsOpen": settingsWindow.isOpen,
            "toast": pointer.toast ?? "",
            "pointerOnBar": !panel.ignoresMouseEvents,
            "hoveredIcon": pointer.hoveredIndex.map { $0 < ordered.count ? ordered[$0].name : "?" } ?? "",
            "mouse": [Double(NSEvent.mouseLocation.x), Double(NSEvent.mouseLocation.y)],
            "panelFrame": [Double(frame.minX), Double(frame.minY), Double(frame.width), Double(frame.height)],
            "icons": icons,
            "gear": screen(along: gearAlong),
            "updatedAt": ISO8601DateFormatter().string(from: Date()),
        ]
        let file = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/Halo/status.json")
        try? FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        if let data = try? JSONSerialization.data(withJSONObject: status, options: [.prettyPrinted, .sortedKeys]) {
            try? data.write(to: file, options: .atomic)
        }
    }

    private func registerHotKey() {
        guard settings.hotKeyEnabled, !Self.demo else {
            HotKey.shared.unregister()
            return
        }
        HotKey.shared.register(keyCode: UInt32(settings.hotKeyCode), modifiers: UInt32(settings.hotKeyModifiers))
    }

    private func toggleBar() {
        if autoHidden {
            // Auto-hidden: the shortcut brings it back for a few seconds.
            peekUntil = Date().addingTimeInterval(5)
            updateAutoHide()
        } else if panel.isVisible {
            panel.orderOut(nil)
        } else {
            panel.orderFrontRegardless()
        }
    }

    /// Opening Halo again (Finder, Spotlight) brings a hidden bar back, and its Settings.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        panel.orderFrontRegardless()
        if autoHidden {
            peekUntil = Date().addingTimeInterval(5)
            updateAutoHide()
        }
        showSettings()
        return false
    }

    /// Settings → Position: a screen edge (or free), on the screen the bar is on.
    private func place(_ choice: String) {
        let screen = Self.screen(containing: placementPoint) ?? NSScreen.main ?? NSScreen.screens[0]
        placement = Self.placement(choice, on: screen)
        savePlacement()
        applyPlacement(animated: true)
    }

    private func move(toScreen index: Int) {
        guard NSScreen.screens.indices.contains(index) else { return }
        placement = Self.placement(layout.floating ? "floating" : layout.edge.rawValue, on: NSScreen.screens[index])
        savePlacement()
        applyPlacement(animated: true)
    }

    private static func placement(_ choice: String, on screen: NSScreen) -> Placement {
        let visible = screen.visibleFrame
        let center = NSPoint(x: visible.midX, y: visible.midY)
        if choice == "floating" { return .floating(NSPoint(x: visible.midX, y: visible.minY + visible.height * 0.3)) }
        return .docked(DockEdge(rawValue: choice) ?? .bottom, center)
    }

    private var placementPoint: NSPoint {
        switch placement {
        case .floating(let point), .docked(_, let point): return point
        }
    }

    /// Sounds and notifications (Settings): when a session starts waiting for you, or finishes.
    private func announce(_ session: Session, from old: SessionState) {
        let new = session.state
        if new.isNeedsYou, !old.isNeedsYou {
            if settings.soundWhenWaiting { NSSound(named: "Glass")?.play() }
            if settings.notifyWaiting { notify(session) }
        } else if new == .done, old != .done {
            if settings.soundWhenDone { NSSound(named: "Pop")?.play() }
            if settings.notifyDone { notify(session) }
        }
        // Answered, or seen: its notification has done its job.
        if (old.isNeedsYou && !new.isNeedsYou) || (old == .done && new != .done) {
            Notifier.shared.withdraw(sessionId: session.id)
        }
    }

    private func notify(_ session: Session) {
        let strings = settings.strings
        let withDetail = settings.showDetails
        Task {
            // What it asks, read from its history on this Mac, as on the hover card.
            let detail = withDetail ? await SessionDetailStore.shared.detail(for: session, strings: strings) : nil
            let body = ([detail?.title] + (detail?.lines.prefix(2).map { $0 } ?? []) + [detail?.code])
                .compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: "\n")
            Notifier.shared.post(sessionId: session.id, title: session.name, subtitle: strings.label(session.state),
                                 body: body.isEmpty ? nil : body, host: session.hostSessionId)
        }
    }

    // MARK: - Auto-hide

    private var fullScreenTimer: Timer?
    private var autoHidden = false
    /// ⌃⌥H on an auto-hidden bar shows it until then.
    private var peekUntil: Date?
    private var fullScreenOnBarScreen = false
    /// The pointer is on the bar (or where it would be), and when it last left it.
    private var pointerOnBar = false
    private var pointerLeftBarAt = Date.distantPast

    private func updateAutoHide() {
        let hide = shouldAutoHide()
        guard hide != autoHidden else { return }
        autoHidden = hide
        NSAnimationContext.runAnimationGroup { context in
            context.duration = hide ? 0.4 : 0.18
            panel.animator().alphaValue = hide ? 0 : 1
        }
        if let peekUntil, !hide {
            // Hide again once the peek is over.
            DispatchQueue.main.asyncAfter(deadline: .now() + max(0.1, peekUntil.timeIntervalSinceNow + 0.05)) {
                [weak self] in MainActor.assumeIsolated { self?.updateAutoHide() }
            }
        }
    }

    private func shouldAutoHide() -> Bool {
        guard settings.hideWhenCalm || settings.hideInFullScreen else { return false }
        // Something for you: always visible.
        if store.sessions.contains(where: { $0.state.isNeedsYou || $0.state == .done }) { return false }
        if dragging || press != nil || settingsWindow.isOpen { return false }
        if let peekUntil, peekUntil > Date() { return false }
        // The pointer is on it, or just left it.
        if pointerOnBar || Date().timeIntervalSince(pointerLeftBarAt) < 0.8 { return false }
        return settings.hideWhenCalm || (settings.hideInFullScreen && fullScreenOnBarScreen)
    }

    private func checkFullScreen() {
        guard settings.hideInFullScreen || settings.hideWhenCalm else {
            if autoHidden { updateAutoHide() }
            return
        }
        if settings.hideInFullScreen {
            let screen = Self.screen(containing: NSPoint(x: panel.frame.midX, y: panel.frame.midY)) ?? NSScreen.main
            fullScreenOnBarScreen = screen.map(Self.hasFullScreenWindow) ?? false
        }
        updateAutoHide()
    }

    /// Another app is full screen on this display. With the Accessibility permission, macOS
    /// says so directly (on a notched Mac, a full-screen window stops under the notch, exactly
    /// like a merely maximized one). Without it: a window covering the whole display.
    private static func hasFullScreenWindow(on screen: NSScreen) -> Bool {
        guard let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber else {
            return false
        }
        let display = CGDisplayBounds(CGDirectDisplayID(number.uint32Value))
        if frontWindowIsFullScreen(on: display) { return true }
        let me = ProcessInfo.processInfo.processIdentifier
        let windows = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID)
            as? [[String: Any]] ?? []
        return windows.contains { info in
            guard (info[kCGWindowLayer as String] as? Int) == 0,
                  (info[kCGWindowOwnerPID as String] as? Int32) != me,
                  let bounds = info[kCGWindowBounds as String] as? NSDictionary,
                  let rect = CGRect(dictionaryRepresentation: bounds) else { return false }
            return abs(rect.minX - display.minX) < 1 && abs(rect.minY - display.minY) < 1
                && abs(rect.width - display.width) < 1 && abs(rect.height - display.height) < 1
        }
    }

    /// The front app's focused window is in full screen, on this display (`display` in CG coordinates).
    private static func frontWindowIsFullScreen(on display: CGRect) -> Bool {
        guard AXIsProcessTrusted(), let app = NSWorkspace.shared.frontmostApplication,
              app.processIdentifier != ProcessInfo.processInfo.processIdentifier else { return false }
        let element = AXUIElementCreateApplication(app.processIdentifier)
        // A busy app must not stall the bar.
        AXUIElementSetMessagingTimeout(element, 0.25)
        var focused: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXFocusedWindowAttribute as CFString, &focused) == .success,
              let focused, CFGetTypeID(focused) == AXUIElementGetTypeID() else { return false }
        let window = focused as! AXUIElement
        var fullScreen: CFTypeRef?
        guard AXUIElementCopyAttributeValue(window, "AXFullScreen" as CFString, &fullScreen) == .success,
              (fullScreen as? Bool) == true else { return false }
        var position: CFTypeRef?
        var origin = CGPoint.zero
        if AXUIElementCopyAttributeValue(window, kAXPositionAttribute as CFString, &position) == .success,
           let position, CFGetTypeID(position) == AXValueGetTypeID() {
            AXValueGetValue(position as! AXValue, .cgPoint, &origin)
        }
        return display.insetBy(dx: -1, dy: -1).contains(origin)
    }

    private var toastTask: Task<Void, Never>?

    /// A message above the bar for a few seconds.
    private func showToast(_ message: String) {
        toastTask?.cancel()
        pointer.toast = message
        toastTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(6))
            guard !Task.isCancelled else { return }
            self?.pointer.toast = nil
        }
    }

    private static func openURL(_ string: String) {
        guard let url = URL(string: string) else { return }
        NSWorkspace.shared.open(url)
    }

    // MARK: - Placement

    private func applyPlacement(animated: Bool) {
        let target = resolve(placement)
        let reshaped = layout.edge != target.edge || layout.notch != target.notch
        if reshaped {
            layout.edge = target.edge
            layout.notch = target.notch
        }
        var floating = false
        if case .floating = placement { floating = true }
        if layout.floating != floating { layout.floating = floating }
        let screen = NSScreen.screens.firstIndex { $0.frame.contains(placementPoint) } ?? 0
        if layout.screenIndex != screen { layout.screenIndex = screen }
        panel.level = Self.demo ? Self.demoLevel : target.level
        if animated && !reshaped {
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.34
                // A small overshoot, so the bar lands on the edge like a magnet.
                context.timingFunction = CAMediaTimingFunction(controlPoints: 0.2, 1.25, 0.4, 1)
                panel.animator().setFrame(target.frame, display: true)
            }
        } else {
            panel.setFrame(target.frame, display: true)
        }
    }

    private func resolve(_ placement: Placement)
        -> (edge: DockEdge, notch: CGSize?, frame: NSRect, level: NSWindow.Level) {
        let margin = layout.metrics.screenMargin
        var targetEdge = DockEdge.bottom
        if case .docked(let edge, _) = placement { targetEdge = edge }
        // In the notch the bar only shows a few icons; the window is sized for those.
        let shown = layout.shownStrip(strip, edge: targetEdge)
        let half = layout.metrics.barLength(shown) / 2
        switch placement {
        case .floating(let point):
            let size = layout.metrics.windowSize(shown, edge: .bottom)
            var x = point.x, y = point.y
            if let visible = Self.screen(containing: point)?.visibleFrame {
                x = Self.clamp(x, visible.minX + half, visible.maxX - half)
                y = Self.clamp(y, visible.minY, visible.maxY - layout.metrics.barThickness)
            }
            return (.bottom, nil, NSRect(x: x - size.width / 2, y: y, width: size.width, height: size.height), .floating)

        case .docked(let edge, let point):
            let screen = Self.screen(containing: point) ?? NSScreen.main ?? NSScreen.screens[0]
            let visible = screen.visibleFrame
            switch edge {
            case .bottom:
                let size = layout.metrics.windowSize(shown, edge: .bottom)
                let x = Self.clamp(point.x, visible.minX + half + margin, visible.maxX - half - margin)
                return (.bottom, nil, NSRect(x: x - size.width / 2, y: visible.minY + margin,
                                             width: size.width, height: size.height), .floating)
            case .left, .right:
                let size = layout.metrics.windowSize(shown, edge: edge)
                let y = Self.clamp(point.y, visible.minY + half + margin, visible.maxY - half - margin)
                let x = edge == .left ? visible.minX + margin : visible.maxX - margin - size.width
                return (edge, nil, NSRect(x: x, y: y - size.height / 2, width: size.width, height: size.height), .floating)
            case .top:
                if let notch = Self.notchSize(of: screen) {
                    // Into the notch: centered on it, flush with the top of the screen, over the menu bar.
                    let size = layout.metrics.windowSize(shown, edge: .top, topInset: notch.height)
                    return (.top, notch, NSRect(x: screen.frame.midX - size.width / 2, y: screen.frame.maxY - size.height,
                                                width: size.width, height: size.height), .statusBar)
                }
                let size = layout.metrics.windowSize(shown, edge: .top)
                let x = Self.clamp(point.x, visible.minX + half + margin, visible.maxX - half - margin)
                return (.top, nil, NSRect(x: x - size.width / 2, y: visible.maxY - margin - size.height,
                                          width: size.width, height: size.height), .floating)
            }
        }
    }

    /// Where a drop lands: docked to the nearest edge if close enough, floating otherwise.
    private func placementForDrop(at mouse: NSPoint) -> Placement {
        if let screen = Self.screen(containing: mouse) {
            let visible = screen.visibleFrame
            let distances: [(DockEdge, CGFloat)] = [
                (.top, screen.frame.maxY - mouse.y),
                (.bottom, mouse.y - visible.minY),
                (.left, mouse.x - visible.minX),
                (.right, visible.maxX - mouse.x),
            ]
            if let nearest = distances.min(by: { $0.1 < $1.1 }), nearest.1 < Self.snapDistance {
                return .docked(nearest.0, mouse)
            }
        }
        // A horizontal bar stays exactly where it was dropped; a vertical one turns
        // horizontal around the pointer.
        if layout.edge.isHorizontal && layout.notch == nil {
            let bar = barRectOnScreen()
            return .floating(NSPoint(x: bar.midX, y: bar.minY))
        }
        return .floating(NSPoint(x: mouse.x, y: mouse.y - layout.metrics.barThickness / 2))
    }

    private func barRectOnScreen() -> NSRect {
        let frame = panel.frame
        let rect = layout.metrics.barRect(layout.shownStrip(strip), edge: layout.edge,
                                          windowSize: frame.size, topInset: layout.topInset)
        return NSRect(x: frame.minX + rect.minX, y: frame.maxY - rect.maxY, width: rect.width, height: rect.height)
    }

    private static func notchSize(of screen: NSScreen) -> CGSize? {
        guard screen.safeAreaInsets.top > 0,
              let left = screen.auxiliaryTopLeftArea, let right = screen.auxiliaryTopRightArea else { return nil }
        return CGSize(width: screen.frame.width - left.width - right.width, height: screen.safeAreaInsets.top)
    }

    private static func screen(containing point: NSPoint) -> NSScreen? {
        NSScreen.screens.first { $0.frame.contains(point) } ?? NSScreen.main
    }

    private static func clamp(_ value: CGFloat, _ low: CGFloat, _ high: CGFloat) -> CGFloat {
        low > high ? (low + high) / 2 : min(max(value, low), high)
    }

    private func savedPlacement() -> Placement? {
        guard let saved = UserDefaults.standard.dictionary(forKey: Self.placementKey),
              let kind = saved["kind"] as? String,
              let x = saved["x"] as? Double, let y = saved["y"] as? Double else { return nil }
        let point = NSPoint(x: x, y: y)
        if kind == "floating" { return .floating(point) }
        return DockEdge(rawValue: kind).map { .docked($0, point) }
    }

    private func savePlacement() {
        guard !Self.demo else { return }
        let (kind, point): (String, NSPoint)
        switch placement {
        case .floating(let p): (kind, point) = ("floating", p)
        case .docked(let edge, let p): (kind, point) = (edge.rawValue, p)
        }
        UserDefaults.standard.set(["kind": kind, "x": Double(point.x), "y": Double(point.y)],
                                  forKey: Self.placementKey)
    }

    // MARK: - Pointer, hover and drag

    private func installMouseMonitors() {
        let global = NSEvent.addGlobalMonitorForEvents(matching: [.mouseMoved, .leftMouseDragged]) { [weak self] event in
            MainActor.assumeIsolated { self?.handle(event) }
        }
        let local = NSEvent.addLocalMonitorForEvents(
            matching: [.mouseMoved, .leftMouseDown, .leftMouseDragged, .leftMouseUp, .magnify]
        ) { [weak self] event in
            // Runs before the event reaches the view, so a drag is flagged before the tap fires.
            MainActor.assumeIsolated { self?.handle(event) }
            return event
        }
        monitors = [global, local].compactMap { $0 }
    }

    private func handle(_ event: NSEvent) {
        let mouse = NSEvent.mouseLocation
        switch event.type {
        case .leftMouseDown where event.window === panel:
            press = (mouse, panel.frame.origin)
            dragging = false
        case .leftMouseDragged:
            guard let press else { break }
            if !dragging, hypot(mouse.x - press.mouse.x, mouse.y - press.mouse.y) > Self.dragThreshold {
                dragging = true
                panel.level = Self.demo ? Self.demoLevel : .floating
            }
            if dragging {
                panel.setFrameOrigin(NSPoint(x: press.origin.x + mouse.x - press.mouse.x,
                                             y: press.origin.y + mouse.y - press.mouse.y))
            }
        case .magnify where event.window === panel:
            // Pinch on the trackpad to shrink or grow the bar.
            setIconSize(settings.iconSize * (1 + event.magnification))
        case .leftMouseUp:
            if dragging {
                lastDragEnd = Date()
                placement = placementForDrop(at: mouse)
                savePlacement()
                applyPlacement(animated: true)
            }
            press = nil
            dragging = false
        default:
            break
        }
        updateHover(mouse: mouse)
    }

    private func updateHover(mouse: NSPoint) {
        let frame = panel.frame
        let edge = layout.edge
        // Window coordinates with the origin at the top-left, like SwiftUI.
        let point = CGPoint(x: mouse.x - frame.minX, y: frame.maxY - mouse.y)
        let metrics = layout.metrics
        let bar = metrics.barRect(layout.shownStrip(strip), edge: edge, windowSize: frame.size, topInset: layout.topInset)
        var zone = bar.insetBy(dx: -4, dy: -4)
        if pointer.hover != nil {
            // Magnified icons stick out of the bar and widen it: keep them reachable.
            let lift = layout.metrics.lift
            switch edge {
            case .bottom: zone = CGRect(x: zone.minX - 40, y: zone.minY - lift, width: zone.width + 80, height: zone.height + lift)
            case .top: zone = CGRect(x: zone.minX - 40, y: zone.minY, width: zone.width + 80, height: zone.height + lift)
            case .left: zone = CGRect(x: zone.minX, y: zone.minY - 40, width: zone.width + lift, height: zone.height + 80)
            case .right: zone = CGRect(x: zone.minX - lift, y: zone.minY - 40, width: zone.width + lift, height: zone.height + 80)
            }
        }
        // Auto-hidden, the bar comes back when the pointer reaches its place, up to the screen edge.
        var revealZone = zone
        switch edge {
        case .bottom: revealZone.size.height = frame.height - revealZone.minY
        case .top: revealZone = CGRect(x: zone.minX, y: 0, width: zone.width, height: zone.maxY)
        case .left: revealZone = CGRect(x: 0, y: zone.minY, width: zone.maxX, height: zone.height)
        case .right: revealZone.size.width = frame.width - revealZone.minX
        }
        let near = revealZone.insetBy(dx: autoHidden ? -8 : 0, dy: autoHidden ? -8 : 0).contains(point)
        if near != pointerOnBar {
            pointerOnBar = near
            if near {
                updateAutoHide()
            } else {
                pointerLeftBarAt = Date()
                // Left the bar: hide again once the short grace period is over.
                if settings.hideWhenCalm || settings.hideInFullScreen {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.85) { [weak self] in
                        MainActor.assumeIsolated { self?.updateAutoHide() }
                    }
                }
            }
        }
        let inside = zone.contains(point) && !autoHidden
        var hover: CGFloat? = inside && !dragging ? (edge.isHorizontal ? point.x : point.y) : nil
        // Over the gear at the end of the bar: no magnification, no card.
        let gearStart = (edge.isHorizontal ? bar.maxX : bar.maxY) - metrics.padding - metrics.gearSlot + metrics.spacing / 2
        if let along = hover, along > gearStart { hover = nil }
        if hover != pointer.hover { pointer.hover = hover }
        let centers: [CGFloat]
        var scroll: CGFloat = 0
        if layout.isCompact {
            // Compact bar: sliding the pointer from one end of it to the other scrolls
            // through every session, like scrubbing a timeline.
            let start = bar.minX + metrics.padding
            let viewport = metrics.rowLength(count: layout.shownStrip(strip).count)
            let maxScroll = max(0, metrics.rowLength(count: strip.count) - viewport)
            if let hover, maxScroll > 0 {
                let travel = max(1, viewport - metrics.item)
                scroll = Self.clamp((hover - start - metrics.item / 2) / travel, 0, 1) * maxScroll
            }
            centers = (0..<strip.count).map {
                start + metrics.item / 2 + CGFloat($0) * (metrics.item + metrics.spacing) - scroll
            }
        } else {
            centers = metrics.baseCenters(strip, mainLength: edge.isHorizontal ? frame.width : frame.height)
        }
        if scroll != pointer.scroll { pointer.scroll = scroll }
        let hovered = hoveredIndex(at: hover, centers: centers)
        if hovered != pointer.hoveredIndex { pointer.hoveredIndex = hovered }
        let ignores = !(inside || press != nil)
        if panel.ignoresMouseEvents != ignores { panel.ignoresMouseEvents = ignores }
    }

    /// The icon under the pointer. It only changes once the pointer is clearly closer to
    /// a neighbour, so reaching for an icon's ✕ (in its corner) does not slip to the next one.
    private func hoveredIndex(at hover: CGFloat?, centers: [CGFloat]) -> Int? {
        guard let hover else { return nil }
        guard let nearest = centers.indices.min(by: { abs(centers[$0] - hover) < abs(centers[$1] - hover) }) else {
            return nil
        }
        if let current = pointer.hoveredIndex, centers.indices.contains(current),
           abs(centers[current] - hover) - abs(centers[nearest] - hover) < 16 * layout.metrics.unit {
            return current
        }
        return nearest
    }

    // MARK: - Launch at login

    private static var launchesAtLogin: Bool { SMAppService.mainApp.status == .enabled }

    private static func setLaunchAtLogin(_ enabled: Bool) {
        do {
            if enabled { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
        } catch {
            NSLog("Halo: launch at login change failed: \(error.localizedDescription)")
        }
    }
}

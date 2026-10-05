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
    private let settings = HaloSettings()
    private lazy var store = SessionStore(settings: settings)
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
            rootView: DockView(store: store, pointer: pointer, layout: layout, actions: actions))

        placement = savedPlacement() ?? .docked(.bottom, NSPoint(x: NSScreen.main?.frame.midX ?? 0, y: 0))
        store.loadHidden()
        store.onChange = { [weak self] in self?.sessionsChanged() }
        store.onStateChange = { [weak self] old, new in self?.playSound(from: old, to: new) }
        // Size, magnification and the notch's icon count change the window: re-place it.
        settings.onChange = { [weak self] in
            guard let self else { return }
            applyPlacement(animated: false)
            settingsWindow.updateLanguage(settings.strings)
            registerHotKey()
        }
        HotKey.shared.onPress = { [weak self] in self?.toggleBar() }
        registerHotKey()
        store.start()
        strip = store.strip
        applyPlacement(animated: false)
        panel.orderFrontRegardless()

        installMouseMonitors()
        NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.applyPlacement(animated: false) }
        }
    }

    // MARK: - Sessions

    private func sessionsChanged() {
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
                    showToast(settings.strings.pickInSidebar(session.name))
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

    private func showSettings() {
        settingsWindow.show(settings: settings, actions: SettingsActions(
            store: store,
            resetPosition: { [weak self] in self?.resetPosition() },
            launchAtLogin: Binding(get: { Self.launchesAtLogin }, set: { Self.setLaunchAtLogin($0) })))
    }

    // MARK: - Show and hide

    /// The global shortcut from Settings, or none.
    private func registerHotKey() {
        guard settings.hotKeyEnabled else {
            HotKey.shared.unregister()
            return
        }
        HotKey.shared.register(keyCode: UInt32(settings.hotKeyCode), modifiers: UInt32(settings.hotKeyModifiers))
    }

    private func toggleBar() {
        if panel.isVisible { panel.orderOut(nil) } else { panel.orderFrontRegardless() }
    }

    /// Opening Halo again (Finder, Spotlight) brings a hidden bar back.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        panel.orderFrontRegardless()
        return false
    }

    private func resetPosition() {
        placement = .docked(.bottom, NSPoint(x: NSScreen.main?.frame.midX ?? 0, y: 0))
        savePlacement()
        applyPlacement(animated: true)
    }

    /// Optional sounds (Settings): when a session starts waiting for you, or finishes.
    private func playSound(from old: SessionState, to new: SessionState) {
        if new.isNeedsYou, !old.isNeedsYou, settings.soundWhenWaiting {
            NSSound(named: "Glass")?.play()
        } else if new == .done, old != .done, settings.soundWhenDone {
            NSSound(named: "Pop")?.play()
        }
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
        panel.level = target.level
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
                panel.level = .floating
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
        let inside = zone.contains(point)
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

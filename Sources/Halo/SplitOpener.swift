import AppKit
import ApplicationServices

/// Shows a session next to the one already open in the Claude app.
///
/// Claude's session link always lands in the main (left) pane, so Halo does what you would:
/// it picks "Split View → New Session on the Right" in the app's own menu, which opens an
/// empty pane on the right, then clicks the session in Claude's sidebar, which opens it in
/// that pane. The sidebar is web content: Claude (an Electron app) only describes it to
/// Accessibility once asked to (`AXManualAccessibility`, as screen readers do). If the
/// session cannot be found there (sidebar collapsed, session in a closed group), the user
/// clicks it and Halo says which one. All of this needs the Accessibility permission.
@MainActor
enum SplitOpener {
    private static let claudeBundleId = "com.anthropic.claudefordesktop"
    /// The menu items' ids in the Claude app's translation files.
    private static let newRightMessageId = "xhaQ8bIWLL"
    private static let showSidebarMessageId = "i07Vmzxp/Q"

    static var isTrusted: Bool { AXIsProcessTrusted() }

    static var claudeIsInFront: Bool {
        NSWorkspace.shared.frontmostApplication?.bundleIdentifier == claudeBundleId
    }

    /// Shows macOS's own prompt, which leads to the Accessibility settings.
    static func requestTrust() {
        AXIsProcessTrustedWithOptions(["AXTrustedCheckOptionPrompt": true] as CFDictionary)
    }

    /// Opens an empty pane on the right of the Claude window. False if that was not possible.
    static func openPaneOnTheRight() async -> Bool {
        guard isTrusted,
              let app = NSRunningApplication.runningApplications(withBundleIdentifier: claudeBundleId).first else {
            return false
        }
        app.activate()
        try? await Task.sleep(for: .milliseconds(250))
        let element = AXUIElementCreateApplication(app.processIdentifier)
        guard let menuBar = value(element, kAXMenuBarAttribute).flatMap(asElement) else { return false }
        return press(in: menuBar, titles: newRightTitles, depth: 0)
    }

    /// Where to click, in Claude's sidebar, to open the session titled `title`: the middle of
    /// its title, once the row holds still (the list redraws itself when a pane opens, and a
    /// row can briefly show another session). Top-left screen coordinates; nil if not found.
    static func sidebarPoint(title: String) async -> CGPoint? {
        guard isTrusted,
              let app = NSRunningApplication.runningApplications(withBundleIdentifier: claudeBundleId).first else {
            return nil
        }
        let pid = app.processIdentifier
        let wanted = title.trimmingCharacters(in: .whitespacesAndNewlines)
        let screen = CGDisplayBounds(CGMainDisplayID())
        // Walking a web page through Accessibility takes a moment: off the main thread.
        return await Task.detached(priority: .userInitiated) {
            let element = AXUIElementCreateApplication(pid)
            AXUIElementSetMessagingTimeout(element, 1)
            // Left on: switching it off and on again does not reliably bring the tree back.
            AXUIElementSetAttributeValue(element, "AXManualAccessibility" as CFString, kCFBooleanTrue)
            var previous: CGRect?
            for attempt in 0..<30 {
                if let match = SidebarSearch.row(titled: wanted, in: element) {
                    let frame = SidebarSearch.frame(match.text)
                    let visible = frame.width > 0 && screen.insetBy(dx: 0, dy: 40).contains(CGPoint(x: frame.midX, y: frame.midY))
                    if !visible {
                        AXUIElementPerformAction(match.row, "AXScrollToVisible" as CFString)
                        previous = nil
                    } else if frame == previous {
                        return CGPoint(x: frame.minX + min(frame.width / 2, 40), y: frame.midY)
                    } else {
                        previous = frame
                    }
                } else {
                    previous = nil
                    // Not there: the new pane may have made the window too narrow for the
                    // sidebar, which Claude then folds away. Ask for it back, once.
                    if attempt == 6 { _ = await MainActor.run { SplitOpener.showSidebar(pid: pid) } }
                }
                try? await Task.sleep(for: .milliseconds(150))
            }
            return nil
        }.value
    }

    /// A real click, as if you clicked there yourself; the pointer then goes back where it was.
    static func click(at point: CGPoint) {
        let source = CGEventSource(stateID: .combinedSessionState)
        let back = CGEvent(source: nil)?.location
        CGWarpMouseCursorPosition(point)
        for type in [CGEventType.mouseMoved, .leftMouseDown, .leftMouseUp] {
            guard let event = CGEvent(mouseEventSource: source, mouseType: type, mouseCursorPosition: point,
                                      mouseButton: .left) else { continue }
            // ⌥ may still be down from the ⌥-click: this one is a plain click.
            event.flags = []
            event.post(tap: .cghidEventTap)
            usleep(80_000)
        }
        // Let the app take the click before the pointer goes back.
        usleep(150_000)
        if let back { CGWarpMouseCursorPosition(back) }
    }

    /// "View → Show Sidebar", if the sidebar is hidden (the item then reads "Hide Sidebar").
    static func showSidebar(pid: pid_t) -> Bool {
        let element = AXUIElementCreateApplication(pid)
        guard let menuBar = value(element, kAXMenuBarAttribute).flatMap(asElement) else { return false }
        return press(in: menuBar, titles: showSidebarTitles, depth: 0)
    }

    /// For `Halo --find-in-sidebar`: what the search finds, without clicking.
    nonisolated static func findInSidebar(title: String) async -> String? {
        guard let app = await MainActor.run(body: {
            NSRunningApplication.runningApplications(withBundleIdentifier: claudeBundleId).first?.processIdentifier
        }) else { return nil }
        let element = AXUIElementCreateApplication(app)
        AXUIElementSetAttributeValue(element, "AXManualAccessibility" as CFString, kCFBooleanTrue)
        defer { AXUIElementSetAttributeValue(element, "AXManualAccessibility" as CFString, kCFBooleanFalse) }
        for attempt in 0..<24 {
            if let match = SidebarSearch.row(titled: title, in: element) {
                return "found after \(attempt) tries: \(SidebarSearch.describe(match.row)) at \(SidebarSearch.frame(match.text))"
            }
            if attempt == 6 {
                let shown = await MainActor.run { SplitOpener.showSidebar(pid: app) }
                print("sidebar shown: \(shown)")
            }
            try? await Task.sleep(for: .milliseconds(150))
        }
        return nil
    }

    // MARK: - Menu

    /// The item's title in every language the Claude app ships, read from its own files,
    /// so this works whatever language the app runs in.
    private static let newRightTitles = menuTitles(id: newRightMessageId, english: "New Session on the Right")
    private static let showSidebarTitles = menuTitles(id: showSidebarMessageId, english: "Show Sidebar")

    private static func menuTitles(id: String, english: String) -> Set<String> {
        var titles: Set<String> = [english]
        let resources = URL(fileURLWithPath: "/Applications/Claude.app/Contents/Resources")
        let files = (try? FileManager.default.contentsOfDirectory(at: resources, includingPropertiesForKeys: nil)) ?? []
        for file in files where file.pathExtension == "json" {
            guard let data = try? Data(contentsOf: file),
                  let strings = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let title = strings[id] as? String else { continue }
            titles.insert(title)
        }
        return titles
    }

    private static func press(in element: AXUIElement, titles: Set<String>, depth: Int) -> Bool {
        guard depth < 6 else { return false }
        for child in children(of: element) {
            if let title = value(child, kAXTitleAttribute) as? String, titles.contains(title) {
                guard (value(child, kAXEnabledAttribute) as? Bool) ?? true else { return false }
                return AXUIElementPerformAction(child, kAXPressAction as CFString) == .success
            }
            if press(in: child, titles: titles, depth: depth + 1) { return true }
        }
        return false
    }

    private static func children(of element: AXUIElement) -> [AXUIElement] {
        (value(element, kAXChildrenAttribute) as? [AnyObject] ?? []).compactMap(asElement)
    }

    private static func value(_ element: AXUIElement, _ attribute: String) -> AnyObject? {
        var result: AnyObject?
        return AXUIElementCopyAttributeValue(element, attribute as CFString, &result) == .success ? result : nil
    }

    private static func asElement(_ object: AnyObject) -> AXUIElement? {
        CFGetTypeID(object) == AXUIElementGetTypeID() ? (object as! AXUIElement) : nil
    }
}

/// A session row in Claude's sidebar: a button whose own text is exactly the session's title.
/// Nonisolated: it runs on a background thread (Accessibility calls are thread-safe).
enum SidebarSearch {
    /// The row (a button) and its title text.
    static func row(titled title: String, in root: AXUIElement) -> (row: AXUIElement, text: AXUIElement)? {
        var stack: [(AXUIElement, Int)] = [(root, 0)]
        while let (element, depth) = stack.popLast() {
            if role(element) == kAXButtonRole as String, let text = titleText(title, element, depth: 0) {
                return (element, text)
            }
            guard depth < 40 else { continue }
            for child in children(element).reversed() { stack.append((child, depth + 1)) }
        }
        return nil
    }

    /// The button's own text equal to the title (a few levels down at most), not just part of one.
    private static func titleText(_ title: String, _ element: AXUIElement, depth: Int) -> AXUIElement? {
        guard depth < 4 else { return nil }
        for child in children(element) {
            if role(child) == kAXStaticTextRole as String,
               (string(child, kAXValueAttribute) ?? string(child, kAXTitleAttribute))?
                   .trimmingCharacters(in: .whitespacesAndNewlines) == title {
                return child
            }
            if role(child) != kAXButtonRole as String, let text = titleText(title, child, depth: depth + 1) {
                return text
            }
        }
        return nil
    }

    /// On screen, top-left coordinates.
    static func frame(_ element: AXUIElement) -> CGRect {
        var origin = CGPoint.zero, size = CGSize.zero
        var value: CFTypeRef?
        if AXUIElementCopyAttributeValue(element, kAXPositionAttribute as CFString, &value) == .success, let value,
           CFGetTypeID(value) == AXValueGetTypeID() {
            AXValueGetValue(value as! AXValue, .cgPoint, &origin)
        }
        if AXUIElementCopyAttributeValue(element, kAXSizeAttribute as CFString, &value) == .success, let value,
           CFGetTypeID(value) == AXValueGetTypeID() {
            AXValueGetValue(value as! AXValue, .cgSize, &size)
        }
        return CGRect(origin: origin, size: size)
    }

    static func describe(_ element: AXUIElement) -> String {
        [role(element), string(element, kAXTitleAttribute), string(element, kAXDescriptionAttribute)]
            .compactMap { $0 }.joined(separator: " | ")
    }

    private static func role(_ element: AXUIElement) -> String? { string(element, kAXRoleAttribute) }

    private static func string(_ element: AXUIElement, _ attribute: String) -> String? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success else { return nil }
        return value as? String
    }

    private static func children(_ element: AXUIElement) -> [AXUIElement] {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXChildrenAttribute as CFString, &value) == .success,
              let list = value as? [AnyObject] else { return [] }
        return list.compactMap { CFGetTypeID($0) == AXUIElementGetTypeID() ? ($0 as! AXUIElement) : nil }
    }
}

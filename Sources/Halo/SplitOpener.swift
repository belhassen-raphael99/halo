import AppKit
import ApplicationServices

/// Opens a session next to the one already showing in the Claude app.
///
/// The app has no public link for that, so Halo does what you would do by hand: it picks
/// "Split View → New Session on the Right" in the app's own menu, then opens the session's
/// link, which lands in that new pane. Driving another app's menu needs the Accessibility
/// permission (System Settings → Privacy & Security → Accessibility), granted by you.
@MainActor
enum SplitOpener {
    private static let claudeBundleId = "com.anthropic.claudefordesktop"
    /// The menu item's id in the Claude app's translation files.
    private static let newRightMessageId = "xhaQ8bIWLL"

    static var isTrusted: Bool { AXIsProcessTrusted() }

    /// Shows macOS's own prompt, which leads to the Accessibility settings.
    static func requestTrust() {
        AXIsProcessTrustedWithOptions(["AXTrustedCheckOptionPrompt": true] as CFDictionary)
    }

    /// Returns false when the split could not be made (the link is then opened in place).
    static func open(_ url: URL) async -> Bool {
        guard isTrusted,
              let app = NSRunningApplication.runningApplications(withBundleIdentifier: claudeBundleId).first else {
            NSWorkspace.shared.open(url)
            return false
        }
        app.activate()
        try? await Task.sleep(for: .milliseconds(250))
        let element = AXUIElementCreateApplication(app.processIdentifier)
        guard let menuBar = value(element, kAXMenuBarAttribute).flatMap(asElement),
              press(in: menuBar, titles: newRightTitles, depth: 0) else {
            NSWorkspace.shared.open(url)
            return false
        }
        // Let the new pane appear and take focus before the link lands in it.
        try? await Task.sleep(for: .milliseconds(450))
        NSWorkspace.shared.open(url)
        return true
    }

    // MARK: - Menu

    /// The item's title in every language the Claude app ships, read from its own files,
    /// so this works whatever language the app runs in.
    private static let newRightTitles: Set<String> = {
        var titles: Set<String> = ["New Session on the Right"]
        let resources = URL(fileURLWithPath: "/Applications/Claude.app/Contents/Resources")
        let files = (try? FileManager.default.contentsOfDirectory(at: resources, includingPropertiesForKeys: nil)) ?? []
        for file in files where file.pathExtension == "json" {
            guard let data = try? Data(contentsOf: file),
                  let strings = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let title = strings[newRightMessageId] as? String else { continue }
            titles.insert(title)
        }
        return titles
    }()

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

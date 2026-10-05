import AppKit
import Carbon.HIToolbox

/// A system-wide keyboard shortcut (Carbon hot key: works from any app, no permission needed).
@MainActor
final class HotKey {
    static let shared = HotKey()

    var onPress: (() -> Void)?

    private var hotKey: EventHotKeyRef?
    private var handler: EventHandlerRef?

    /// `modifiers` is a Carbon mask (`cmdKey`, `optionKey`, `controlKey`, `shiftKey`).
    func register(keyCode: UInt32, modifiers: UInt32) {
        unregister()
        installHandlerIfNeeded()
        let id = EventHotKeyID(signature: OSType(0x48414C4F), id: 1) // "HALO"
        RegisterEventHotKey(keyCode, modifiers, id, GetApplicationEventTarget(), 0, &hotKey)
    }

    func unregister() {
        if let hotKey { UnregisterEventHotKey(hotKey) }
        hotKey = nil
    }

    private func installHandlerIfNeeded() {
        guard handler == nil else { return }
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, _, _ in
            Task { @MainActor in HotKey.shared.onPress?() }
            return noErr
        }, 1, &spec, nil, &handler)
    }

    // MARK: - Conversions

    /// AppKit modifier flags → Carbon mask.
    static func carbonModifiers(_ flags: NSEvent.ModifierFlags) -> UInt32 {
        var mask: UInt32 = 0
        if flags.contains(.command) { mask |= UInt32(cmdKey) }
        if flags.contains(.option) { mask |= UInt32(optionKey) }
        if flags.contains(.control) { mask |= UInt32(controlKey) }
        if flags.contains(.shift) { mask |= UInt32(shiftKey) }
        return mask
    }

    /// "⌃⌥H", in the order macOS shows modifiers.
    static func label(modifiers: UInt32, key: String) -> String {
        var text = ""
        if modifiers & UInt32(controlKey) != 0 { text += "⌃" }
        if modifiers & UInt32(optionKey) != 0 { text += "⌥" }
        if modifiers & UInt32(shiftKey) != 0 { text += "⇧" }
        if modifiers & UInt32(cmdKey) != 0 { text += "⌘" }
        return text + key.uppercased()
    }

    /// What a key is called on its keycap, for keys that don't type a character.
    static func keyName(_ event: NSEvent) -> String {
        switch Int(event.keyCode) {
        case kVK_Space: return "Space"
        case kVK_Return: return "↩"
        case kVK_Tab: return "⇥"
        case kVK_Delete: return "⌫"
        case kVK_LeftArrow: return "←"
        case kVK_RightArrow: return "→"
        case kVK_UpArrow: return "↑"
        case kVK_DownArrow: return "↓"
        case kVK_F1...kVK_F20: return "F\(functionNumber(event.keyCode))"
        default: return event.charactersIgnoringModifiers ?? "?"
        }
    }

    private static func functionNumber(_ code: UInt16) -> Int {
        let keys = [kVK_F1, kVK_F2, kVK_F3, kVK_F4, kVK_F5, kVK_F6, kVK_F7, kVK_F8, kVK_F9, kVK_F10,
                    kVK_F11, kVK_F12, kVK_F13, kVK_F14, kVK_F15, kVK_F16, kVK_F17, kVK_F18, kVK_F19, kVK_F20]
        return (keys.firstIndex(of: Int(code)) ?? 0) + 1
    }
}

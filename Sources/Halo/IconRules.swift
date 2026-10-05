import AppKit
import Observation
import SwiftUI

/// One of your own "keywords → icon" rules.
struct CustomIconRule: Identifiable, Codable, Equatable {
    var id = UUID()
    var keywords: [String]
    var symbol: String
    /// "#RRGGBB"
    var top: String
    var bottom: String

    private enum Key: String, CodingKey { case keywords, symbol, top, bottom }

    init(keywords: [String], symbol: String, top: String, bottom: String) {
        self.keywords = keywords
        self.symbol = symbol
        self.top = top
        self.bottom = bottom
    }

    // The file keeps the simple format documented in the README (no ids).
    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: Key.self)
        keywords = try values.decode([String].self, forKey: .keywords)
        symbol = try values.decode(String.self, forKey: .symbol)
        top = try values.decode(String.self, forKey: .top)
        bottom = try values.decode(String.self, forKey: .bottom)
    }

    func encode(to encoder: Encoder) throws {
        var values = encoder.container(keyedBy: Key.self)
        try values.encode(keywords, forKey: .keywords)
        try values.encode(symbol, forKey: .symbol)
        try values.encode(top, forKey: .top)
        try values.encode(bottom, forKey: .bottom)
    }

    static func hex(_ text: String) -> UInt32? {
        UInt32(text.trimmingCharacters(in: CharacterSet(charactersIn: "# ")), radix: 16)
    }

    static func hexString(_ color: Color) -> String {
        guard let rgb = NSColor(color).usingColorSpace(.sRGB) else { return "#888888" }
        return String(format: "#%02X%02X%02X", Int(rgb.redComponent * 255), Int(rgb.greenComponent * 255),
                      Int(rgb.blueComponent * 255))
    }
}

/// What a session gets when no rule covers it.
enum AutoIconStyle: String, CaseIterable, Identifiable, Sendable {
    /// A symbol chosen from the words of its name (`IconGenerator`).
    case symbols
    /// Its initials on a colored tile.
    case initials
    /// The same sparkle for all, in a few colors.
    case sparkle

    var id: String { rawValue }
}

/// Your icon rules, kept in `~/Library/Application Support/Halo/icon-rules.json` (on this Mac only),
/// editable from Settings. They are checked before Halo's built-in rules. Also keeps how
/// sessions without a rule get theirs, and which of the generated icons you picked.
@MainActor
@Observable
final class IconRulesStore {
    /// Swapped for a neutral store (`persistent: false`) when Halo renders public images.
    static var shared = IconRulesStore()

    private(set) var rules: [CustomIconRule] = []

    var autoStyle: AutoIconStyle = .symbols {
        didSet { if persistent { UserDefaults.standard.set(autoStyle.rawValue, forKey: Self.autoStyleKey) } }
    }
    /// Session name → which of its generated icons to show ("another one" moves to the next).
    private(set) var variants: [String: Int] = [:]

    @ObservationIgnored private let file = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Application Support/Halo/icon-rules.json")
    @ObservationIgnored private let persistent: Bool
    /// Generated symbols by text: computed once, icons are drawn many times a second.
    @ObservationIgnored private var generated: [String: [String]] = [:]

    private static let autoStyleKey = "halo.autoIcons"
    private static let variantsKey = "halo.iconVariants"

    /// `persistent: false`: Halo's own rules only, nothing read or saved (README images, snapshots).
    init(persistent: Bool = true) {
        self.persistent = persistent
        guard persistent else { return }
        if let data = try? Data(contentsOf: file),
           let saved = try? JSONDecoder().decode([CustomIconRule].self, from: data) {
            rules = saved
        }
        if let raw = UserDefaults.standard.string(forKey: Self.autoStyleKey), let style = AutoIconStyle(rawValue: raw) {
            autoStyle = style
        }
        variants = UserDefaults.standard.dictionary(forKey: Self.variantsKey) as? [String: Int] ?? [:]
    }

    static func variantKey(_ name: String) -> String {
        name.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
            .trimmingCharacters(in: .whitespaces)
    }

    /// "Another icon" for this session: the next generated one, round and round.
    func nextIcon(for name: String) {
        variants[Self.variantKey(name), default: 0] += 1
        saveVariants()
    }

    func resetIcon(for name: String) {
        variants[Self.variantKey(name)] = nil
        saveVariants()
    }

    func generatedSymbols(for text: String) -> [String] {
        if let cached = generated[text] { return cached }
        let symbols = IconGenerator.symbols(for: text)
        generated[text] = symbols
        return symbols
    }

    private func saveVariants() {
        guard persistent else { return }
        UserDefaults.standard.set(variants, forKey: Self.variantsKey)
    }

    func add() {
        rules.insert(CustomIconRule(keywords: [], symbol: "star.fill", top: "#9AA4FF", bottom: "#5B5FE0"), at: 0)
        save()
    }

    /// A rule that keeps this session's current icon, to fine-tune it.
    func add(keeping icon: AppIcon, for name: String) {
        rules.insert(CustomIconRule(keywords: [name], symbol: icon.monogram == nil ? icon.symbol : "star.fill",
                                    top: CustomIconRule.hexString(icon.top),
                                    bottom: CustomIconRule.hexString(icon.bottom)), at: 0)
        save()
    }

    func update(_ rule: CustomIconRule) {
        guard let index = rules.firstIndex(where: { $0.id == rule.id }) else { return }
        rules[index] = rule
        save()
    }

    func remove(_ id: UUID) {
        rules.removeAll { $0.id == id }
        save()
    }

    private func save() {
        guard persistent else { return }
        try? FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .withoutEscapingSlashes]
        try? encoder.encode(rules).write(to: file, options: .atomic)
    }
}

/// Symbols offered in the editor; any other SF Symbol name can be typed.
enum SymbolChoices {
    static let all = [
        "star.fill", "sparkles", "briefcase.fill", "fork.knife", "graduationcap.fill", "waveform", "heart.fill",
        "chart.line.uptrend.xyaxis", "checkmark.seal.fill", "server.rack", "iphone", "lock.shield.fill",
        "paintpalette.fill", "film.fill", "airplane", "globe", "folder.fill", "lightbulb.fill", "house.fill",
        "cart.fill", "building.2.fill", "person.2.fill", "book.fill", "doc.text.fill", "hammer.fill",
        "wrench.and.screwdriver.fill", "terminal.fill", "cpu.fill", "camera.fill", "music.note",
        "gamecontroller.fill", "leaf.fill", "flame.fill", "bolt.fill", "cloud.fill", "map.fill",
        "bag.fill", "creditcard.fill", "bubble.left.and.bubble.right.fill", "envelope.fill",
    ]

    static func exists(_ name: String) -> Bool {
        NSImage(systemSymbolName: name, accessibilityDescription: nil) != nil
    }
}

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

/// Your icon rules, kept in `~/Library/Application Support/Halo/icon-rules.json` (on this Mac only),
/// editable from Settings. They are checked before Halo's built-in rules.
@MainActor
@Observable
final class IconRulesStore {
    static let shared = IconRulesStore()

    private(set) var rules: [CustomIconRule] = []

    @ObservationIgnored private let file = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Application Support/Halo/icon-rules.json")

    init() {
        if let data = try? Data(contentsOf: file),
           let saved = try? JSONDecoder().decode([CustomIconRule].self, from: data) {
            rules = saved
        }
    }

    func add() {
        rules.insert(CustomIconRule(keywords: [], symbol: "star.fill", top: "#9AA4FF", bottom: "#5B5FE0"), at: 0)
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

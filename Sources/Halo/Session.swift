import Foundation
import SwiftUI

/// What an icon shows.
enum SessionState: Equatable {
    /// Claude is blocked on you: a question, a permission, a dialog.
    case needsYou(reason: String)
    /// Claude is running a turn.
    case working
    /// The turn ended and you have not looked at the session since.
    case done
    /// Idle and already seen.
    case rest
    /// Listed in the Claude app but no process is running for it.
    case paused

    /// Most urgent first: what the compact bar (in the notch) shows when it has no room.
    var urgency: Int {
        switch self {
        case .needsYou: return 0
        case .done: return 1
        case .working: return 2
        case .rest: return 3
        case .paused: return 4
        }
    }

    var isNeedsYou: Bool {
        if case .needsYou = self { return true }
        return false
    }

}

/// One Claude Code session: live (from `~/.claude/sessions/<pid>.json`) or paused
/// (only in the Desktop app's session list).
struct Session: Identifiable, Equatable {
    /// The Desktop id (`local_…`) when known, so a paused session keeps its identity
    /// when it comes back to life; `pid-<n>` for terminal sessions.
    let id: String
    let pid: Int32?
    let name: String
    let cwd: String
    let isDesktop: Bool
    /// Desktop app id, used by the `claude://code/continue` deep link.
    let hostSessionId: String?
    /// Claude Code's own session id: the name of its transcript file.
    var transcriptId: String? = nil
    var state: SessionState
    /// When the current state began (ms since epoch).
    let stateSince: Double

    var isLive: Bool { pid != nil }
    var icon: AppIcon { AppIcon.for(name: name, cwd: cwd) }
}

/// An Apple-style app icon: a symbol on a gradient tile, picked from the session's
/// name and folder.
struct AppIcon: Equatable {
    let symbol: String
    let top: Color
    let bottom: Color

    private struct Rule: Decodable {
        let keywords: [String]
        let symbol: String
        let top: UInt32
        let bottom: UInt32

        init(keywords: [String], symbol: String, top: UInt32, bottom: UInt32) {
            self.keywords = keywords
            self.symbol = symbol
            self.top = top
            self.bottom = bottom
        }

        /// In the custom rules file, colors are written "#RRGGBB".
        init(from decoder: Decoder) throws {
            enum Key: String, CodingKey { case keywords, symbol, top, bottom }
            let values = try decoder.container(keyedBy: Key.self)
            func color(_ key: Key) throws -> UInt32 {
                let text = try values.decode(String.self, forKey: key).trimmingCharacters(in: CharacterSet(charactersIn: "#"))
                guard let value = UInt32(text, radix: 16) else {
                    throw DecodingError.dataCorruptedError(forKey: key, in: values, debugDescription: "expected #RRGGBB")
                }
                return value
            }
            keywords = try values.decode([String].self, forKey: .keywords)
            symbol = try values.decode(String.self, forKey: .symbol)
            top = try color(.top)
            bottom = try color(.bottom)
        }
    }

    /// Your own rules, checked before the built-in ones. They live on your Mac only:
    /// `~/Library/Application Support/Halo/icon-rules.json`, a list of
    /// `{"keywords": ["acme"], "symbol": "building.2.fill", "top": "#64C8FF", "bottom": "#0066E0"}`.
    private static let customRules: [Rule] = {
        let file = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/Halo/icon-rules.json")
        guard let data = try? Data(contentsOf: file),
              let rules = try? JSONDecoder().decode([Rule].self, from: data) else { return [] }
        return rules.map { rule in
            Rule(keywords: rule.keywords.map {
                $0.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
            }, symbol: rule.symbol, top: rule.top, bottom: rule.bottom)
        }
    }()

    // First match wins, so the most specific subjects come first.
    private static let rules: [Rule] = [
        Rule(keywords: ["career", "job", "resume", "cv", "candidature", "emploi", "interview", "recrut"],
             symbol: "briefcase.fill", top: 0x5AD8F0, bottom: 0x0A84B8),
        Rule(keywords: ["food", "kitchen", "recipe", "restaurant", "cuisine", "recette", "menu"],
             symbol: "fork.knife", top: 0xFFB340, bottom: 0xE8590C),
        Rule(keywords: ["course", "exam", "study", "school", "lesson", "cours", "examen", "revision", "devoir"],
             symbol: "graduationcap.fill", top: 0x8E8CFF, bottom: 0x4B3FD6),
        Rule(keywords: ["voice", "audio", "podcast", "dictation", "transcription", "speech", "whisper"],
             symbol: "waveform", top: 0xFF7A95, bottom: 0xD7264A),
        Rule(keywords: ["wedding", "event", "invitation", "party", "mariage"],
             symbol: "heart.fill", top: 0xFF9EC0, bottom: 0xE2457A),
        Rule(keywords: ["finance", "budget", "bank", "invoice", "billing", "payment", "facture"],
             symbol: "chart.line.uptrend.xyaxis", top: 0x5EE08A, bottom: 0x15A34A),
        Rule(keywords: ["test", "tests", "testing", "qa", "bug", "bugs"],
             symbol: "checkmark.seal.fill", top: 0x6FD8FF, bottom: 0x0A6CFF),
        Rule(keywords: ["api", "backend", "server", "database", "migration", "sql"],
             symbol: "server.rack", top: 0x7AD7C9, bottom: 0x1F8A7A),
        Rule(keywords: ["mobile", "ios", "android", "iphone"],
             symbol: "iphone", top: 0x9EB4FF, bottom: 0x4458D6),
        Rule(keywords: ["security", "securi", "auth", "cyber", "audit"],
             symbol: "lock.shield.fill", top: 0x9A9AA2, bottom: 0x3A3A40),
        Rule(keywords: ["design", "logo", "brand", "figma", "ui"],
             symbol: "paintpalette.fill", top: 0xD07CFF, bottom: 0x8E2DC5),
        Rule(keywords: ["video", "film", "trailer"],
             symbol: "film.fill", top: 0xFF8A5C, bottom: 0xC2410C),
        Rule(keywords: ["travel", "flight", "trip", "voyage"],
             symbol: "airplane", top: 0x7CC4FF, bottom: 0x2563EB),
        Rule(keywords: ["website", "site", "web", "landing", "domain", "seo"],
             symbol: "globe", top: 0x64C8FF, bottom: 0x0066E0),
        Rule(keywords: ["files", "folder", "cleanup", "dossier"],
             symbol: "folder.fill", top: 0x7EC8FF, bottom: 0x1E88E5),
        Rule(keywords: ["halo", "dock"],
             symbol: "circle.hexagongrid.fill", top: 0x9AA4FF, bottom: 0x5B5FE0),
        Rule(keywords: ["agent", "ai", "ia", "mcp", "claude", "llm"],
             symbol: "sparkles", top: 0xF2A07B, bottom: 0xC2603A),
        Rule(keywords: ["idea", "ideas", "brainstorm", "project", "projet"],
             symbol: "lightbulb.fill", top: 0xFFD84D, bottom: 0xF59E0B),
    ]

    private static let fallbacks: [(UInt32, UInt32)] = [
        (0xF2A07B, 0xC2603A), (0x8E8CFF, 0x4B3FD6), (0x5AD8F0, 0x0A84B8),
        (0x5EE08A, 0x15A34A), (0xFF9EC0, 0xE2457A), (0xFFB340, 0xE8590C),
    ]

    static func `for`(name: String, cwd: String) -> AppIcon {
        let folder = URL(fileURLWithPath: cwd).lastPathComponent
        let text = "\(name) \(folder)"
            .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
        let words = Set(text.split(whereSeparator: { !$0.isLetter && !$0.isNumber }).map(String.init))
        for rule in customRules + rules where rule.keywords.contains(where: { key in
            // Short keywords must be whole words: "ia" must not match "media".
            key.count <= 3 ? words.contains(key) : text.contains(key)
        }) {
            return AppIcon(symbol: rule.symbol, top: Color(hex: rule.top), bottom: Color(hex: rule.bottom))
        }
        var hash: UInt64 = 1469598103934665603
        for byte in name.utf8 { hash = (hash ^ UInt64(byte)) &* 1099511628211 }
        let pair = fallbacks[Int(hash % UInt64(fallbacks.count))]
        return AppIcon(symbol: "sparkle", top: Color(hex: pair.0), bottom: Color(hex: pair.1))
    }
}

extension Color {
    init(hex: UInt32) {
        self.init(red: Double((hex >> 16) & 0xFF) / 255,
                  green: Double((hex >> 8) & 0xFF) / 255,
                  blue: Double(hex & 0xFF) / 255)
    }
}

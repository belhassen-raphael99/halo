import Foundation

/// Apple's SF Symbols catalog, as macOS itself ships it: every symbol name, in Apple's
/// order, with the words Apple's own search knows each one by, and its categories.
/// Read once from the system (nothing bundled, no network). If a future macOS moves these
/// files, the catalog is empty and Halo falls back to initials.
struct SymbolCatalog: Sendable {
    /// Symbols this Mac can draw, in the order of Apple's SF Symbols app.
    let names: [String]
    let available: Set<String>
    /// Each symbol's place in Apple's order: the canonical ones come first.
    let position: [String: Int]
    let keywords: [String: [String]]
    let categories: [String: [String]]
    /// Search word → symbols it points to, with a weight (3 = in the name, 2 = Apple keyword).
    let index: [String: [(symbol: String, weight: Double)]]

    static let shared = SymbolCatalog.load()

    private static let resources = URL(fileURLWithPath:
        "/System/Library/CoreServices/CoreGlyphs.bundle/Contents/Resources")

    /// Language-specific variants (`.ar`, `.he`, `.rtl`…): the base symbol already adapts.
    private static let localeSuffixes: Set<String> = [
        "ar", "hi", "he", "zh", "th", "ja", "ko", "sat", "mni", "ml", "kn", "bn", "gu", "or", "mr", "te",
        "pa", "ta", "si", "el", "ru", "my", "km", "rtl", "traditional",
    ]

    private static func plist(_ name: String) -> Any? {
        guard let data = try? Data(contentsOf: resources.appendingPathComponent(name)) else { return nil }
        return try? PropertyListSerialization.propertyList(from: data, format: nil)
    }

    private static func load() -> SymbolCatalog {
        let order = plist("symbol_order.plist") as? [String] ?? []
        let availability = plist("name_availability.plist") as? [String: Any]
        let released = availability?["symbols"] as? [String: String] ?? [:]
        let releases = availability?["year_to_release"] as? [String: [String: String]] ?? [:]
        let os = ProcessInfo.processInfo.operatingSystemVersion
        func available(_ name: String) -> Bool {
            guard let year = released[name], let macOS = releases[year]?["macOS"] else { return false }
            let parts = macOS.split(separator: ".").compactMap { Int($0) }
            let major = parts.first ?? 99, minor = parts.count > 1 ? parts[1] : 0
            return (major, minor) <= (os.majorVersion, os.minorVersion)
        }
        let names = order.filter { name in
            !localeSuffixes.contains(String(name.split(separator: ".").last ?? "")) && available(name)
        }
        let keywords = plist("symbol_search.plist") as? [String: [String]] ?? [:]
        let categories = plist("symbol_categories.plist") as? [String: [String]] ?? [:]

        var index: [String: [String: Double]] = [:]
        for name in names {
            for part in name.split(separator: ".") where part.count > 1 {
                index[String(part), default: [:]][name] = 3
            }
            for word in keywords[name] ?? [] {
                for part in word.lowercased().split(whereSeparator: { !$0.isLetter }) where part.count > 1 {
                    let key = String(part)
                    index[key, default: [:]][name] = max(index[key]?[name] ?? 0, 2)
                }
            }
        }
        return SymbolCatalog(names: names, available: Set(names),
                             position: Dictionary(names.enumerated().map { ($1, $0) }, uniquingKeysWith: { a, _ in a }),
                             keywords: keywords, categories: categories,
                             index: index.mapValues { $0.map { (symbol: $0.key, weight: $0.value) } })
    }

    /// Symbols whose name or Apple keywords match the query (English, or French and Hebrew
    /// words Halo knows), best first.
    func search(_ query: String, limit: Int = 300) -> [String] {
        let words = IconGenerator.searchWords(query).map(\.word)
        guard !words.isEmpty else { return [] }
        let folded = query.lowercased().trimmingCharacters(in: .whitespaces)
        var scores: [String: Double] = [:]
        for word in words {
            for (key, entries) in index where key == word || (word.count >= 3 && key.hasPrefix(word)) {
                let exact = key == word ? 1.0 : 0.6
                for entry in entries { scores[entry.symbol, default: 0] += entry.weight * exact }
            }
        }
        // A query that is part of a symbol's name ("cart.fill") finds it too.
        if folded.count >= 2 {
            for name in names where name.contains(folded) { scores[name, default: 0] += 4 }
        }
        return scores.sorted {
            $0.value != $1.value ? $0.value > $1.value : (position[$0.key] ?? .max) < (position[$1.key] ?? .max)
        }
        .prefix(limit).map(\.key)
    }
}

/// Makes an icon for a session no rule covers: it reads the words of the session's name
/// and folder, translates the common French and Hebrew ones, and picks the SF Symbols
/// they describe best — the rarer the word, the more it counts. On this Mac, no AI, no network.
enum IconGenerator {
    /// Best symbols for this text, best first (several, so "another one" can cycle).
    static func symbols(for text: String, limit: Int = 10) -> [String] {
        let catalog = SymbolCatalog.shared
        let words = searchWords(text)
        guard !words.isEmpty, !catalog.names.isEmpty else { return [] }
        let total = Double(catalog.names.count)
        var scores: [String: Double] = [:]
        for (word, importance) in words {
            guard let entries = catalog.index[word] else { continue }
            // Rare words ("airplane") say more than common ones ("weather").
            let rarity = log(1 + total / Double(entries.count))
            var best: [String: Double] = [:]
            for entry in entries where usable(entry.symbol, catalog) {
                let base = filled(entry.symbol, catalog)
                best[base] = max(best[base] ?? 0, entry.weight * rarity * importance)
            }
            for (symbol, score) in best { scores[symbol, default: 0] += score }
        }
        // Simple symbols first ("airplane" over "airplane.path.dotted"), then Apple's order.
        return scores
            .map { name, score in (name, score / (1 + 0.18 * Double(name.split(separator: ".").count - 1))) }
            .sorted {
                $0.1 != $1.1 ? $0.1 > $1.1
                    : (catalog.position[$0.0] ?? .max) < (catalog.position[$1.0] ?? .max)
            }
            .prefix(limit).map(\.0)
    }

    /// Colors that go with a symbol, after its Apple category (health is red, nature green…).
    static func colors(for symbol: String, seed: String) -> (top: UInt32, bottom: UInt32) {
        let categories = SymbolCatalog.shared.categories[symbol] ?? []
        for category in categories {
            if let pair = categoryColors[category] { return pair }
        }
        var hash: UInt64 = 1469598103934665603
        for byte in seed.utf8 { hash = (hash ^ UInt64(byte)) &* 1099511628211 }
        return palette[Int(hash % UInt64(palette.count))]
    }

    /// One or two letters for a monogram icon: the first letters of the first two words.
    static func initials(_ name: String) -> String {
        let words = name.split(whereSeparator: { !$0.isLetter && !$0.isNumber })
            .filter { !stopWords.contains($0.lowercased()) }
        let letters = words.prefix(2).compactMap(\.first).map { String($0).uppercased() }
        return letters.isEmpty ? "•" : letters.joined()
    }

    // MARK: - Words

    /// The words to look up, with how much each counts: lowercased, accents removed, small
    /// words dropped, French and Hebrew words translated, plurals tried without their "s".
    /// Words for what you do ("search", "fix") count half of words for what it is about.
    static func searchWords(_ text: String) -> [(word: String, importance: Double)] {
        let folded = text.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
        var words: [(String, Double)] = []
        for raw in folded.split(whereSeparator: { !$0.isLetter }) {
            let word = String(raw)
            guard word.count > 1, !stopWords.contains(word) else { continue }
            let importance = actionWords.contains(word) ? 0.5 : 1
            if let english = translation(word) {
                words += english.split(separator: " ").map { (String($0), importance) }
            } else {
                words.append((word, importance))
                if word.count > 3, word.hasSuffix("s") { words.append((String(word.dropLast()), importance)) }
            }
        }
        var seen = Set<String>()
        return words.filter { seen.insert($0.0).inserted }
    }

    private static func translation(_ word: String) -> String? {
        if let english = dictionary[word] { return english }
        if word.count > 3, word.hasSuffix("s"), let english = dictionary[String(word.dropLast())] { return english }
        // Hebrew glues small words to the front (ה, ו, ב, ל, מ, ש, כ): try without one.
        if word.count > 3, let first = word.first, "הובלמשכ".contains(first),
           let english = dictionary[String(word.dropFirst())] { return english }
        return nil
    }

    private static func usable(_ symbol: String, _ catalog: SymbolCatalog) -> Bool {
        let parts = symbol.split(separator: ".")
        if parts.contains("slash") || parts.contains("badge") || parts.contains("dashed") { return false }
        let categories = catalog.categories[symbol] ?? []
        return !categories.contains { ["arrows", "shapes", "indices", "math", "textformatting", "keyboard"].contains($0) }
    }

    /// The filled version reads better on a tile, like Apple's own app icons.
    private static func filled(_ symbol: String, _ catalog: SymbolCatalog) -> String {
        if symbol.hasSuffix(".fill") { return symbol }
        let fill = symbol + ".fill"
        return catalog.available.contains(fill) ? fill : symbol
    }

    private static let stopWords: Set<String> = [
        // French
        "le", "la", "les", "de", "des", "du", "un", "une", "et", "ou", "pour", "avec", "sans", "sur", "dans", "en",
        "au", "aux", "ce", "ces", "cet", "cette", "mon", "ma", "mes", "ton", "ta", "tes", "son", "sa", "ses", "notre",
        "nos", "votre", "vos", "leur", "leurs", "qui", "que", "par", "plus", "tout", "tous", "est", "sont", "pas",
        "nouveau", "nouvelle", "session", "sessions", "gratuit", "gratuite", "local", "locale", "direct",
        "projet", "version", "app", "apps", "application", "applications", "page", "pages", "open", "source",
        // English
        "the", "an", "of", "and", "or", "for", "with", "without", "to", "in", "on", "at", "by", "from", "is", "are",
        "my", "your", "our", "this", "that", "it", "as", "new", "free", "project",
        // Hebrew
        "של", "את", "עם", "על", "אל", "זה", "זו", "גם", "או", "כי", "לא", "חדש",
    ]

    /// Common French and Hebrew words → English words Apple's symbol search knows.
    /// Generic vocabulary only.
    /// Words for an action rather than a subject.
    private static let actionWords: Set<String> = [
        "recherche", "chercher", "modification", "modifications", "correction", "verification", "nettoyage",
        "rangement", "reorganiser", "brouillon", "ecriture", "rapport", "search", "fix", "update", "review",
        "חיפוש", "תיקון", "בדיקה", "עדכון",
    ]

    private static let dictionary: [String: String] = [
        // Food
        "cuisine": "fork knife", "recette": "fork knife", "repas": "fork knife", "nourriture": "fork knife",
        "restaurant": "fork knife", "traiteur": "fork knife", "menu": "menucard", "gateau": "birthday cake",
        "patisserie": "birthday cake", "cafe": "cup saucer", "vin": "wineglass", "boisson": "drink",
        "מטבח": "fork knife", "מתכון": "fork knife", "מתכונים": "fork knife", "אוכל": "fork knife",
        "מסעדה": "fork knife", "קייטרינג": "fork knife", "עוגה": "birthday cake", "קפה": "cup saucer",
        // Life and events
        "mariage": "heart", "amour": "heart", "fete": "party popper", "anniversaire": "birthday cake",
        "invitation": "envelope", "cadeau": "gift", "famille": "figure", "enfant": "figure child",
        "חתונה": "heart", "אהבה": "heart", "מסיבה": "party popper", "יומולדת": "birthday cake",
        "הזמנה": "envelope", "מתנה": "gift", "משפחה": "figure", "ילד": "figure child",
        // Travel and places
        "voyage": "airplane", "vol": "airplane", "avion": "airplane", "train": "tram", "voiture": "car",
        "velo": "bicycle", "maison": "house", "appartement": "building", "immobilier": "house",
        "plan": "map", "carte": "map", "adresse": "mappin", "lieu": "mappin",
        "טיסה": "airplane", "טיול": "airplane", "מטוס": "airplane", "רכבת": "tram", "רכב": "car",
        "אוטו": "car", "בית": "house", "דירה": "building", "מפה": "map", "כתובת": "mappin",
        // Work
        "travail": "briefcase", "emploi": "briefcase", "candidature": "briefcase", "entretien": "person bubble",
        "bureau": "briefcase", "reunion": "person bubble", "equipe": "person", "client": "person",
        "contrat": "signature", "עבודה": "briefcase", "משרה": "briefcase", "ראיון": "person bubble",
        "צוות": "person", "לקוח": "person", "לקוחות": "person", "חוזה": "signature", "מכרז": "document",
        // Money and shop
        "argent": "banknote", "finance": "chart", "finances": "chart", "banque": "building columns",
        "budget": "chart", "facture": "document", "paiement": "creditcard", "prix": "tag", "achat": "cart",
        "boutique": "bag", "magasin": "storefront", "vente": "cart", "commande": "cart",
        "stock": "shippingbox", "inventaire": "shippingbox", "produit": "shippingbox", "livraison": "shippingbox",
        "כסף": "banknote", "בנק": "building columns", "תקציב": "chart", "חשבונית": "document",
        "תשלום": "creditcard", "מחיר": "tag", "קניות": "cart", "חנות": "storefront", "מלאי": "shippingbox",
        "מוצר": "shippingbox", "מוצרים": "shippingbox", "משלוח": "shippingbox", "הזמנות": "cart",
        // Media
        "musique": "music", "chanson": "music", "son": "speaker", "voix": "microphone", "dictee": "microphone",
        "enregistrement": "record", "photo": "photo", "image": "photo", "dessin": "pencil", "couleur": "paintpalette",
        "מוזיקה": "music", "שיר": "music", "קול": "microphone", "הקלטה": "microphone", "תמלול": "waveform",
        "תמונה": "photo", "סרטון": "video", "סרט": "film", "עיצוב": "paintpalette",
        // Learning
        "ecole": "graduationcap", "cours": "book", "examen": "pencil", "etude": "book", "revision": "book",
        "livre": "book", "lecture": "book", "classe": "person", "universite": "graduationcap",
"לימודים": "book", "קורס": "book", "מבחן": "pencil", "שיעור": "book",
        "ספר": "book", "כיתה": "person", "אוניברסיטה": "graduationcap", "סטודנט": "graduationcap",
        // Health and sport
        "sante": "heart medical", "medecin": "stethoscope", "hopital": "cross", "sport": "figure run",
        "בריאות": "heart medical", "רופא": "stethoscope", "ספורט": "figure run", "כושר": "dumbbell",
        // Safety
        "securite": "lock shield", "alarme": "bell", "acces": "key", "cle": "key", "incendie": "flame",
        "אבטחה": "lock shield", "מצלמה": "camera", "מצלמות": "camera", "מפתח": "key", "אש": "flame",
        // Talking
        "email": "envelope", "courriel": "envelope", "message": "bubble", "discussion": "bubble",
        "telephone": "phone", "appel": "phone", "contact": "person",
        "מייל": "envelope", "הודעה": "bubble", "הודעות": "bubble", "שיחה": "bubble", "טלפון": "phone",
        // Time
        "calendrier": "calendar", "agenda": "calendar", "planning": "calendar", "horaire": "clock",
        "heure": "clock", "meteo": "cloud sun", "weather": "cloud sun", "יומן": "calendar", "שעה": "clock", "מזג": "cloud sun",
        // Nature
        "jardin": "leaf", "plante": "leaf", "animal": "pawprint", "chien": "dog",
        "גינה": "leaf", "צמח": "leaf", "כלב": "dog", "חתול": "cat",
        // Computers
        "serveur": "server rack", "donnees": "cylinder", "tableau": "tablecells",
        "graphique": "chart", "rapport": "document", "fichier": "document", "dossier": "folder",
        "nettoyage": "trash", "rangement": "folder", "recherche": "magnifyingglass", "domaine": "globe",
        "site": "globe", "reseau": "network", "ordinateur": "desktopcomputer", "application": "app",
        "jeu": "gamecontroller", "jeux": "gamecontroller", "idee": "lightbulb", "brouillon": "pencil",
        "ecriture": "pencil", "texte": "text", "traduction": "translate", "notification": "bell",
        "alerte": "bell", "rappel": "bell", "modification": "pencil", "correction": "wrench",
        "verification": "checkmark", "intelligence": "brain", "agents": "sparkles", "ia": "sparkles",
        "קוד": "code", "שרת": "server rack", "נתונים": "cylinder", "טבלה": "tablecells", "דוח": "document",
        "קובץ": "document", "תיקייה": "folder", "חיפוש": "magnifyingglass", "אתר": "globe", "רשת": "network",
        "מחשב": "desktopcomputer", "אפליקציה": "app", "משחק": "gamecontroller", "רעיון": "lightbulb",
        "טקסט": "text", "תרגום": "translate", "התראה": "bell", "תזכורת": "bell", "תיקון": "wrench",
        "באג": "ladybug", "בדיקה": "checkmark", "בינה": "brain",
        // English words Apple's search doesn't know
        "flight": "airplane", "inventory": "shippingbox", "recipe": "fork knife", "kitchen": "fork knife",
        "wedding": "heart", "invoice": "document", "shop": "bag", "groceries": "cart",
        "apartment": "building", "exam": "pencil",
    ]

    private static let categoryColors: [String: (UInt32, UInt32)] = [
        "communication": (0x64C8FF, 0x0A84FF), "weather": (0x7CD3FF, 0x2F8FE0), "maps": (0x6EE7B7, 0x0F9D76),
        "objectsandtools": (0xFFB340, 0xE8590C), "devices": (0x9EB4FF, 0x4458D6),
        "cameraandphotos": (0xA0A6B4, 0x4A4F5C), "gaming": (0xD07CFF, 0x8E2DC5),
        "connectivity": (0x7AD7C9, 0x1F8A7A), "transportation": (0x7CC4FF, 0x2563EB),
        "automotive": (0xFF8A5C, 0xC2410C), "accessibility": (0x7CC4FF, 0x1D6FE0),
        "privacyandsecurity": (0x9A9AA2, 0x3A3A40), "human": (0xFF9EC0, 0xE2457A),
        "home": (0xFFD84D, 0xF59E0B), "fitness": (0x5EE08A, 0x15A34A), "nature": (0x8BE07A, 0x2E9E44),
        "editing": (0xB49CFF, 0x6D4AE0), "media": (0xFF7A95, 0xD7264A), "commerce": (0x5EE08A, 0x15A34A),
        "time": (0xFFB86B, 0xE8590C), "health": (0xFF8A80, 0xE0322B),
    ]

    private static let palette: [(UInt32, UInt32)] = [
        (0xF2A07B, 0xC2603A), (0x8E8CFF, 0x4B3FD6), (0x5AD8F0, 0x0A84B8), (0x5EE08A, 0x15A34A),
        (0xFF9EC0, 0xE2457A), (0xFFB340, 0xE8590C), (0xD07CFF, 0x8E2DC5), (0x7AD7C9, 0x1F8A7A),
    ]
}

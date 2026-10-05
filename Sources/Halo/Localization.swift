import Foundation
import SwiftUI

/// The languages Halo speaks.
enum Lang: String, CaseIterable, Sendable {
    case fr, en, he

    var isRTL: Bool { self == .he }
    var layoutDirection: LayoutDirection { isRTL ? .rightToLeft : .leftToRight }

    /// Its own name, as shown in the language picker.
    var nativeName: String {
        switch self {
        case .fr: return "Français"
        case .en: return "English"
        case .he: return "עברית"
        }
    }

    /// The Mac's first preferred language if Halo speaks it, English otherwise.
    static var system: Lang {
        for identifier in Locale.preferredLanguages {
            if identifier.hasPrefix("iw") { return .he }
            if let lang = Lang(rawValue: String(identifier.prefix(2))) { return lang }
        }
        return .en
    }
}

/// The choice in Settings: a fixed language, or the Mac's.
enum LanguageChoice: String, CaseIterable, Identifiable, Sendable {
    case automatic, fr, en, he

    var id: String { rawValue }

    var resolved: Lang {
        switch self {
        case .automatic: return Lang.system
        case .fr: return .fr
        case .en: return .en
        case .he: return .he
        }
    }
}

/// All of Halo's interface text, in French, English and Hebrew.
struct Strings: Sendable {
    let lang: Lang

    private func pick(_ fr: String, _ en: String, _ he: String) -> String {
        switch lang {
        case .fr: return fr
        case .en: return en
        case .he: return he
        }
    }

    // MARK: States

    func label(_ state: SessionState) -> String {
        switch state {
        case .needsYou(let reason): return pick("Attend ta réponse", "Waiting for you", "מחכה לך") + " · " + reasonLabel(reason)
        case .working: return pick("Travaille…", "Working…", "עובד…")
        case .done: return pick("Terminé, pas encore vu", "Done, not seen yet", "הסתיים, עוד לא נצפה")
        case .rest: return pick("Au repos", "Idle", "במנוחה")
        case .paused: return pick("En pause", "Paused", "מושהה")
        }
    }

    private func reasonLabel(_ reason: String) -> String {
        switch reason {
        case "permission prompt": return pick("autorisation", "permission", "הרשאה")
        case "dialog open": return pick("fenêtre ouverte", "dialog open", "חלון פתוח")
        case "sandbox request": return pick("accès réseau", "network access", "גישה לרשת")
        case "goal proposal": return pick("objectif proposé", "proposed goal", "יעד מוצע")
        default: return pick("question", "question", "שאלה")
        }
    }

    /// "à l'instant", "12 min", "3 h", "2 j"…
    func elapsed(sinceMs ms: Double) -> String {
        let seconds = max(0, Date().timeIntervalSince1970 - ms / 1_000)
        if seconds < 60 { return pick("à l'instant", "just now", "עכשיו") }
        if seconds < 3_600 { return "\(Int(seconds / 60)) " + pick("min", "min", "דק׳") }
        if seconds < 86_400 { return "\(Int(seconds / 3_600)) " + pick("h", "h", "שע׳") }
        return "\(Int(seconds / 86_400)) " + pick("j", "d", "ימ׳")
    }

    // MARK: Hover card

    var questionForYou: String { pick("Question pour toi", "A question for you", "שאלה בשבילך") }
    var planToApprove: String { pick("Plan à valider", "Plan to approve", "תוכנית לאישור") }
    var planWaiting: String {
        pick("Claude propose un plan et attend ton accord.", "Claude proposes a plan and waits for your go.",
             "Claude מציע תוכנית ומחכה לאישור שלך.")
    }
    var permissionRequested: String { pick("Autorisation demandée", "Permission requested", "בקשת הרשאה") }
    var waitingReply: String { pick("Attend ta réponse", "Waiting for your reply", "מחכה לתשובה שלך") }
    var rightNow: String { pick("En ce moment", "Right now", "כרגע") }
    var writingReply: String { pick("Rédige sa réponse", "Writing its reply", "כותב תשובה") }
    var lastReply: String { pick("Dernière réponse", "Last reply", "תשובה אחרונה") }
    var lastAction: String { pick("Dernière action", "Last action", "פעולה אחרונה") }

    var runCommand: String { pick("Lancer une commande", "Run a command", "הרצת פקודה") }
    var readFile: String { pick("Lire un fichier", "Read a file", "קריאת קובץ") }
    var editFile: String { pick("Modifier un fichier", "Edit a file", "עריכת קובץ") }
    var writeFile: String { pick("Écrire un fichier", "Write a file", "כתיבת קובץ") }
    var editNotebook: String { pick("Modifier un notebook", "Edit a notebook", "עריכת מחברת") }
    var searchCode: String { pick("Chercher dans le code", "Search the code", "חיפוש בקוד") }
    var openWebPage: String { pick("Ouvrir une page web", "Open a web page", "פתיחת דף אינטרנט") }
    var searchWeb: String { pick("Chercher sur le web", "Search the web", "חיפוש ברשת") }
    var startAgent: String { pick("Lancer un agent", "Start an agent", "הפעלת סוכן") }
    var connectedTool: String { pick("Utiliser un outil connecté", "Use a connected tool", "שימוש בכלי מחובר") }
    func useTool(_ name: String) -> String { pick("Utiliser \(name)", "Use \(name)", "שימוש ב־\(name)") }

    var hintNeedsYou: String {
        pick("Clic : aller répondre · ⌥-clic : ouvrir à côté", "Click: go answer · ⌥-click: open side by side",
             "לחיצה: לענות · ⌥-לחיצה: פתיחה לצד")
    }
    var hintPaused: String { pick("Clic : reprendre la session", "Click: resume the session", "לחיצה: חידוש הסשן") }
    var hintDefault: String {
        pick("Clic : ouvrir · ⌥-clic : ouvrir à côté", "Click: open · ⌥-click: open side by side",
             "לחיצה: פתיחה · ⌥-לחיצה: פתיחה לצד")
    }

    // MARK: Bar menus

    var openWaiting: String {
        pick("Ouvrir les sessions qui t'attendent", "Open the sessions waiting for you", "פתיחת הסשנים שמחכים לך")
    }
    func showRemoved(_ count: Int) -> String {
        pick("Réafficher les sessions retirées (\(count))", "Show removed sessions again (\(count))",
             "הצגה מחדש של סשנים שהוסרו (\(count))")
    }
    var barSize: String { pick("Taille de la barre", "Bar size", "גודל הסרגל") }
    var sizeSmall: String { pick("Petite", "Small", "קטן") }
    var sizeMedium: String { pick("Moyenne", "Medium", "בינוני") }
    var sizeLarge: String { pick("Grande", "Large", "גדול") }
    var pinchHint: String { pick("Ou pince la barre sur le trackpad", "Or pinch the bar on the trackpad", "או צבוט את הסרגל במשטח המגע") }
    var launchAtLogin: String { pick("Ouvrir Halo au démarrage du Mac", "Open Halo at login", "פתיחת Halo בהפעלת המק") }
    var settingsItem: String { pick("Réglages…", "Settings…", "הגדרות…") }
    var quit: String { pick("Quitter Halo", "Quit Halo", "יציאה מ־Halo") }
    var open: String { pick("Ouvrir", "Open", "פתיחה") }
    var openBeside: String { pick("Ouvrir à côté (⌥-clic)", "Open side by side (⌥-click)", "פתיחה לצד (⌥-לחיצה)") }
    var removeFromBar: String { pick("Retirer de la barre", "Remove from the bar", "הסרה מהסרגל") }
    /// After ⌥-click: the empty pane is open, the user picks the session in Claude's sidebar.
    func pickInSidebar(_ name: String) -> String {
        pick("Clique « \(name) » dans la barre latérale de Claude : elle s'ouvrira à droite.",
             "Click “\(name)” in Claude's sidebar: it opens on the right.",
             "לחץ על „\(name)” בסרגל הצד של Claude: הוא ייפתח מימין.")
    }
    var noSessions: String { pick("Aucune session Claude ouverte", "No Claude session open", "אין סשן Claude פתוח") }

    // MARK: Settings window

    var windowTitle: String { pick("Réglages de Halo", "Halo Settings", "הגדרות Halo") }
    var language: String { pick("Langue", "Language", "שפה") }
    var languageAutomatic: String { pick("Automatique (langue du Mac)", "Automatic (Mac language)", "אוטומטי (שפת המק)") }
    var appearance: String { pick("Apparence", "Appearance", "מראה") }
    var iconSize: String { pick("Taille des icônes", "Icon size", "גודל הסמלים") }
    var magnification: String { pick("Grossissement au survol", "Magnification on hover", "הגדלה במעבר עכבר") }
    var off: String { pick("désactivé", "off", "כבוי") }
    func notchIcons(_ count: Int) -> String {
        pick("Icônes visibles dans l'encoche : \(count)", "Icons shown in the notch: \(count)", "סמלים בחריץ: \(count)")
    }
    var sessions: String { pick("Sessions", "Sessions", "סשנים") }
    var showPaused: String { pick("Afficher les sessions en pause", "Show paused sessions", "הצגת סשנים מושהים") }
    var activeWithin: String { pick("Actives depuis moins de", "Active within", "פעילים בתוך") }
    func days(_ count: Int) -> String {
        switch lang {
        case .fr: return "\(count) jour\(count > 1 ? "s" : "")"
        case .en: return "\(count) day\(count > 1 ? "s" : "")"
        case .he: return count == 1 ? "יום אחד" : "\(count) ימים"
        }
    }
    func atMost(_ count: Int) -> String { pick("Au maximum : \(count)", "At most: \(count)", "לכל היותר: \(count)") }
    var detailCard: String { pick("Carte de détail au survol", "Detail card on hover", "כרטיס פרטים במעבר עכבר") }
    var removedSessions: String { pick("Sessions retirées de la barre", "Sessions removed from the bar", "סשנים שהוסרו מהסרגל") }
    var showAgain: String { pick("Réafficher", "Show again", "הצגה מחדש") }
    var detailFooter: String {
        pick("La carte de détail lit l'historique de la session sur ce Mac. Rien n'est envoyé ailleurs.",
             "The detail card reads the session's history on this Mac. Nothing is sent anywhere.",
             "כרטיס הפרטים קורא את היסטוריית הסשן במק הזה. שום דבר לא נשלח החוצה.")
    }
    var animations: String { pick("Animations", "Animations", "אנימציות") }
    var workingEffects: String {
        pick("Lueur, comète et respiration pendant le travail", "Glow, comet and breathing while working",
             "זוהר, שביט ונשימה בזמן עבודה")
    }
    var bounces: String { pick("Rebonds quand une session t'attend", "Bounces when a session needs you", "קפיצות כשסשן מחכה לך") }
    var sparks: String { pick("Étincelles quand une session a fini", "Sparks when a session is done", "ניצוצות כשסשן מסתיים") }
    var motionFooter: String {
        pick("Si « Réduire les animations » est activé dans macOS, Halo les coupe aussi.",
             "If “Reduce motion” is on in macOS, Halo turns them off too.",
             "אם „הפחתת תנועה” מופעלת ב־macOS, גם Halo מכבה אותן.")
    }
    var sounds: String { pick("Sons", "Sounds", "צלילים") }
    var soundWaiting: String { pick("Son quand une session t'attend", "Sound when a session needs you", "צליל כשסשן מחכה לך") }
    var soundDone: String { pick("Son quand une session a fini", "Sound when a session is done", "צליל כשסשן מסתיים") }
    var system: String { pick("Système", "System", "מערכת") }
    var sideBySide: String { pick("Ouverture côte à côte (⌥-clic)", "Side by side (⌥-click)", "פתיחה זה לצד זה (⌥-לחיצה)") }
    var allowed: String { pick("Autorisée", "Allowed", "מאושר") }
    var needsPermission: String { pick("À autoriser", "Needs permission", "דרוש אישור") }
    var openSystemSettings: String { pick("Ouvrir les réglages", "Open Settings", "פתיחת ההגדרות") }
    var resetPosition: String { pick("Remettre la barre en bas de l'écran", "Put the bar back at the bottom", "החזרת הסרגל לתחתית המסך") }
    var resetDefaults: String { pick("Réglages par défaut", "Restore defaults", "שחזור ברירות מחדל") }
}

private struct StringsKey: EnvironmentKey {
    static let defaultValue = Strings(lang: .en)
}

extension EnvironmentValues {
    /// The interface text in the language chosen in Settings.
    var strings: Strings {
        get { self[StringsKey.self] }
        set { self[StringsKey.self] = newValue }
    }
}

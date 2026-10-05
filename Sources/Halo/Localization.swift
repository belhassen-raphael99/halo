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
        pick("Animer les sessions au travail", "Animate sessions at work", "הנפשת סשנים בעבודה")
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
    var resetDefaults: String { pick("Réglages par défaut", "Restore defaults", "שחזור ברירות מחדל") }

    // MARK: Settings tabs

    var tabGeneral: String { pick("Général", "General", "כללי") }
    var tabAppearance: String { pick("Apparence", "Appearance", "מראה") }
    var tabSessions: String { pick("Sessions", "Sessions", "סשנים") }
    var tabAnimations: String { pick("Animations", "Animations", "אנימציות") }
    var tabIcons: String { pick("Icônes", "Icons", "סמלים") }

    // General
    var shortcut: String { pick("Afficher ou masquer la barre", "Show or hide the bar", "הצגה או הסתרה של הסרגל") }
    var shortcutRecord: String { pick("Cliquer pour enregistrer", "Click to record", "לחץ להקלטה") }
    var shortcutRecording: String { pick("Tape le raccourci…", "Type the shortcut…", "הקלד את הקיצור…") }
    var shortcutClear: String { pick("Effacer", "Clear", "ניקוי") }
    var shortcutFooter: String {
        pick("Fonctionne depuis n'importe quelle app. Barre masquée ? Ce raccourci, ou rouvrir Halo (qui ouvre aussi ces réglages), la fait revenir.",
             "Works from any app. Bar hidden? This shortcut, or opening Halo again (which also opens these settings), brings it back.",
             "עובד מכל אפליקציה. הסרגל מוסתר? הקיצור הזה, או פתיחה מחדש של Halo (שפותחת גם את ההגדרות האלה), יחזירו אותו.")
    }
    var sideBySideFooter: String {
        pick("Le ⌥-clic ouvre la session dans un panneau à droite de Claude : Halo ouvre le panneau, puis clique la session dans la barre latérale, comme tu le ferais.",
             "⌥-click opens the session in a pane on the right in Claude: Halo opens the pane, then clicks the session in the sidebar, as you would.",
             "⌥-לחיצה פותחת את הסשן בחלונית מימין ב־Claude: ‏Halo פותח את החלונית ולוחץ על הסשן בסרגל הצד, כמו שהיית עושה.")
    }
    var position: String { pick("Position", "Position", "מיקום") }
    var hideBar: String { pick("Masquer la barre", "Hide the bar", "הסתרת הסרגל") }

    // Appearance
    var preview: String { pick("Aperçu", "Preview", "תצוגה מקדימה") }
    var notchFooter: String {
        pick("Quand la barre est fondue dans l'encoche, en haut de l'écran : les autres défilent au survol.",
             "When the bar is melted into the notch, at the top of the screen: the others scroll on hover.",
             "כשהסרגל משולב בחריץ בראש המסך: השאר נגללים במעבר עכבר.")
    }

    // Sessions
    var pausedWithin: String { pick("Utilisées dans les derniers", "Used within the last", "בשימוש ב־") }
    func pausedShown(_ count: Int) -> String {
        switch lang {
        case .fr: return count == 0 ? "Aucune session en pause affichée" : "\(count) session\(count > 1 ? "s" : "") en pause affichée\(count > 1 ? "s" : "")"
        case .en: return count == 0 ? "No paused session shown" : "\(count) paused session\(count > 1 ? "s" : "") shown"
        case .he: return count == 0 ? "לא מוצגים סשנים מושהים" : "מוצגים \(count) סשנים מושהים"
        }
    }
    var pausedOffFooter: String {
        pick("Les sessions de Claude qui ne tournent pas restent cachées.",
             "Claude sessions that aren't running stay hidden.",
             "סשנים של Claude שלא רצים נשארים מוסתרים.")
    }
    var removedEmpty: String {
        pick("Aucune. Survole une icône et clique ✕ pour la retirer de la barre.",
             "None. Hover an icon and click ✕ to remove it from the bar.",
             "אין. העבר את העכבר על סמל ולחץ ✕ כדי להסיר אותו מהסרגל.")
    }
    var removedFooter: String {
        pick("Une session retirée revient d'elle-même quand tu lui envoies un nouveau message.",
             "A removed session comes back by itself when you send it a new message.",
             "סשן שהוסר חוזר מעצמו כששולחים לו הודעה חדשה.")
    }
    var showAllAgain: String { pick("Tout réafficher", "Show all again", "הצגת הכל מחדש") }

    // Animations
    var play: String { pick("Écouter", "Play", "השמעה") }
    var whileWorking: String { pick("Pendant que Claude travaille", "While Claude works", "בזמן ש־Claude עובד") }
    func styleName(_ style: WorkingStyle) -> String {
        switch style {
        case .aurora: return pick("Aurore", "Aurora", "זוהר")
        case .glow: return pick("Halo", "Glow", "הילה")
        case .orbit: return pick("Orbite", "Orbit", "מסלול")
        case .trace: return pick("Tracé", "Trace", "קו")
        case .sonar: return pick("Sonar", "Sonar", "סונאר")
        case .dots: return pick("Points", "Dots", "נקודות")
        }
    }
    func styleDescription(_ style: WorkingStyle) -> String {
        switch style {
        case .aurora: return pick("Un anneau arc-en-ciel qui tourne, avec une comète.",
                                  "A spinning rainbow ring, with a comet.", "טבעת בצבעי הקשת שמסתובבת, עם שביט.")
        case .glow: return pick("Une lueur colorée et douce tout autour de l'icône.",
                                "A soft colored glow all around the icon.", "זוהר צבעוני ורך מסביב לסמל.")
        case .orbit: return pick("Une comète fait le tour de l'icône, rien d'autre.",
                                 "A comet circles the icon, nothing else.", "שביט מקיף את הסמל, ותו לא.")
        case .trace: return pick("Un trait se dessine autour de l'icône, puis s'efface.",
                                 "A stroke draws itself around the icon, then fades.", "קו מצטייר סביב הסמל ואז נמחק.")
        case .sonar: return pick("Des ondes colorées partent de l'icône.",
                                 "Colored waves leave the icon.", "גלים צבעוניים יוצאים מהסמל.")
        case .dots: return pick("Trois points dans le coin, comme quand quelqu'un écrit un message.",
                                "Three dots in the corner, like someone typing a message.",
                                "שלוש נקודות בפינה, כמו כשמישהו מקליד הודעה.")
        }
    }

    // Icons
    var iconsIntro: String {
        pick("L'icône d'une session vient des mots de son nom ou de son dossier. Tes règles passent avant celles de Halo et restent sur ce Mac.",
             "A session's icon comes from the words in its name or folder. Your rules come before Halo's and stay on this Mac.",
             "הסמל של סשן נקבע לפי המילים בשם או בתיקייה שלו. הכללים שלך קודמים לכללים של Halo ונשארים במק הזה.")
    }
    var tryName: String { pick("Tester un nom", "Try a name", "בדיקת שם") }
    var tryPlaceholder: String { pick("ex. Refonte du site client", "e.g. Client website redesign", "למשל: עיצוב מחדש לאתר לקוח") }
    var sourceYours: String { pick("ta règle", "your rule", "הכלל שלך") }
    var sourceHalo: String { pick("règle de Halo", "Halo's rule", "כלל של Halo") }
    var sourceFallback: String { pick("icône par défaut", "default icon", "סמל ברירת מחדל") }
    var sourceGenerated: String { pick("créée d'après le nom", "made from the name", "נוצר לפי השם") }
    var sourceInitials: String { pick("initiales", "initials", "ראשי תיבות") }
    var autoIcons: String { pick("Sessions sans règle", "Sessions without a rule", "סשנים ללא כלל") }
    var autoSymbols: String { pick("Symbole deviné d'après le nom", "Symbol guessed from the name", "סמל שנבחר לפי השם") }
    var autoInitials: String { pick("Initiales", "Initials", "ראשי תיבות") }
    var autoSparkle: String { pick("Étincelle, la même pour toutes", "Sparkle, the same for all", "ניצוץ, אותו לכולם") }
    func autoFooter(_ count: Int) -> String {
        pick("Halo cherche parmi les \(count) symboles d'Apple ceux que décrivent les mots du nom, en français, en anglais ou en hébreu. Tout se fait sur ce Mac : ni IA, ni réseau.",
             "Halo looks through Apple's \(count) symbols for the ones the name's words describe, in English, French or Hebrew. It all happens on this Mac: no AI, no network.",
             "Halo מחפש בין \(count) הסמלים של Apple את אלה שמתאימים למילים בשם, בעברית, באנגלית או בצרפתית. הכל קורה במק הזה: בלי בינה מלאכותית ובלי רשת.")
    }
    var yourSessions: String { pick("Tes sessions", "Your sessions", "הסשנים שלך") }
    var yourSessionsFooter: String {
        pick("« Une autre » passe à l'icône suivante. « Garder » en fait une règle, que tu peux ensuite retoucher.",
             "“Another” moves to the next icon. “Keep” turns it into a rule you can then fine-tune.",
             "„אחר” עובר לסמל הבא. „שמירה” הופכת אותו לכלל שאפשר לערוך אחר כך.")
    }
    var another: String { pick("Une autre", "Another", "אחר") }
    var keep: String { pick("Garder", "Keep", "שמירה") }
    var anotherIcon: String { pick("Une autre icône", "Another icon", "סמל אחר") }
    var searchSymbols: String { pick("Chercher un symbole", "Search symbols", "חיפוש סמל") }
    var searchPrompt: String { pick("ex. gâteau, voiture, music", "e.g. cake, car, music", "למשל: עוגה, רכב, music") }
    func symbolCount(_ count: Int) -> String {
        pick("\(count) symbole\(count > 1 ? "s" : "")", "\(count) symbol\(count == 1 ? "" : "s")", "\(count) סמלים")
    }
    var noSymbol: String { pick("Aucun symbole trouvé", "No symbol found", "לא נמצא סמל") }

    // Zoom
    var zoomOnHover: String { pick("Zoom au survol", "Zoom on hover", "הגדלה במעבר עכבר") }
    var zoomStrength: String { pick("Intensité", "Strength", "עוצמה") }
    var zoomInNotch: String { pick("Aussi dans l'encoche", "In the notch too", "גם בחריץ") }

    // Position
    var barPlace: String { pick("Emplacement", "Position", "מיקום") }
    var placeBottom: String { pick("En bas", "Bottom", "למטה") }
    func placeTop(notch: Bool) -> String {
        notch ? pick("En haut, dans l'encoche", "Top, in the notch", "למעלה, בחריץ") : pick("En haut", "Top", "למעלה")
    }
    var placeLeft: String { pick("À gauche", "Left", "שמאל") }
    var placeRight: String { pick("À droite", "Right", "ימין") }
    var placeFree: String { pick("Libre", "Free-floating", "חופשי") }
    var screen: String { pick("Écran", "Display", "מסך") }
    var positionFooter: String {
        pick("Tu peux aussi glisser la barre où tu veux : près d'un bord, elle s'y colle.",
             "You can also drag the bar anywhere: near an edge, it snaps to it.",
             "אפשר גם לגרור את הסרגל לכל מקום: ליד קצה המסך הוא נצמד אליו.")
    }

    // Auto-hide
    var autoHide: String { pick("Masquer la barre automatiquement", "Hide the bar automatically", "הסתרה אוטומטית של הסרגל") }
    var hideWhenCalm: String { pick("Quand aucune session ne t'attend", "When no session needs you", "כשאף סשן לא מחכה לך") }
    var hideInFullScreen: String { pick("Quand une app est en plein écran", "When an app is full screen", "כשאפליקציה במסך מלא") }
    func autoHideFooter(_ shortcut: String?) -> String {
        let key = shortcut.map { pick(", ou avec \($0)", ", or with \($0)", ", או עם \($0)") } ?? ""
        return pick("Elle revient dès qu'une session t'attend ou quand tu passes la souris à sa place\(key).",
                    "It comes back as soon as a session needs you, or when you move the pointer to its place\(key).",
                    "הוא חוזר ברגע שסשן מחכה לך, או כשמעבירים את העכבר למקום שלו\(key).")
    }

    // Notifications
    var notifications: String { pick("Notifications", "Notifications", "התראות") }
    var notifyWaiting: String { pick("Quand une session t'attend", "When a session needs you", "כשסשן מחכה לך") }
    var notifyDone: String { pick("Quand une session a fini", "When a session is done", "כשסשן מסתיים") }
    var notificationsDenied: String { pick("Refusées dans macOS", "Turned off in macOS", "כבויות ב־macOS") }
    var notificationsFooter: String {
        pick("Clique la notification pour ouvrir la session. Elle s'efface d'elle-même une fois que tu as répondu.",
             "Click the notification to open the session. It clears itself once you've answered.",
             "לחיצה על ההתראה פותחת את הסשן. היא נמחקת מעצמה אחרי שענית.")
    }

    // Order, projects, pins
    var order: String { pick("Ordre des icônes", "Icon order", "סדר הסמלים") }
    func orderName(_ order: SessionOrder) -> String {
        switch order {
        case .opened: return pick("Dans l'ordre d'ouverture", "In the order opened", "לפי סדר הפתיחה")
        case .recent: return pick("Les plus récentes d'abord", "Most recent first", "האחרונים קודם")
        case .name: return pick("Par nom", "By name", "לפי שם")
        case .urgency: return pick("Celles qui t'attendent d'abord", "Those waiting for you first", "אלה שמחכים לך קודם")
        }
    }
    var orderFooter: String {
        pick("Les sessions épinglées passent toujours en premier : clic droit sur une icône pour en épingler une.",
             "Pinned sessions always come first: right-click an icon to pin one.",
             "סשנים מוצמדים תמיד ראשונים: לחיצה ימנית על סמל כדי להצמיד אותו.")
    }
    var projects: String { pick("Projets affichés", "Projects shown", "פרויקטים מוצגים") }
    var projectsFooter: String {
        pick("Décoche un projet pour garder ses sessions hors de la barre.",
             "Uncheck a project to keep its sessions off the bar.",
             "בטל סימון של פרויקט כדי להשאיר את הסשנים שלו מחוץ לסרגל.")
    }
    var noProjects: String { pick("Aucun projet pour l'instant.", "No project yet.", "אין עדיין פרויקטים.") }
    var pinFirst: String { pick("Épingler en premier", "Pin first", "הצמדה בהתחלה") }
    var unpin: String { pick("Désépingler", "Unpin", "ביטול הצמדה") }
    var pinned: String { pick("Épinglées", "Pinned", "מוצמדים") }
    var yourRules: String { pick("Tes règles", "Your rules", "הכללים שלך") }
    var addRule: String { pick("Ajouter une règle", "Add a rule", "הוספת כלל") }
    var noRules: String { pick("Aucune règle pour l'instant.", "No rule yet.", "אין עדיין כללים.") }
    var keywords: String { pick("Mots-clés, séparés par des virgules", "Keywords, separated by commas", "מילות מפתח, מופרדות בפסיקים") }
    var symbolName: String { pick("Symbole", "Symbol", "סמל") }
    var unknownSymbol: String { pick("symbole inconnu", "unknown symbol", "סמל לא מוכר") }
    var colorTop: String { pick("Haut", "Top", "למעלה") }
    var colorBottom: String { pick("Bas", "Bottom", "למטה") }
    var delete: String { pick("Supprimer", "Delete", "מחיקה") }
    var done: String { pick("OK", "Done", "סיום") }
    var edit: String { pick("Modifier", "Edit", "עריכה") }
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

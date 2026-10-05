import AppKit
import SwiftUI

/// Command-line helpers for checking Halo without looking at the screen.
///   Halo --dump             prints every session and its computed state
///   Halo --snapshot <dir>   renders the bar (bottom, right edge, notch) with sample sessions
///   Halo --readme <dir>     renders the README's artwork (see ReadmeArt.swift)
///   Halo --icons "name"…    the icons Halo would make for these session names
@MainActor
enum Debug {
    static func run(_ arguments: [String]) -> Bool {
        // Public images never use your own icon rules or picks.
        if ["--readme", "--appicon", "--snapshot"].contains(where: arguments.contains) {
            IconRulesStore.shared = IconRulesStore(persistent: false)
        }
        if let index = arguments.firstIndex(of: "--icons") {
            for name in arguments[(index + 1)...] {
                let match = AppIcon.match(name: name, cwd: "")
                let options = IconGenerator.symbols(for: name, limit: 5)
                print("\(name)\t→ \(match.icon.monogram ?? match.icon.symbol)  (\(match.source))\t\(options.joined(separator: " "))")
            }
            return true
        }
        if let index = arguments.firstIndex(of: "--dump") {
            dump(language: index + 1 < arguments.count ? arguments[index + 1] : nil)
            return true
        }
        if arguments.contains("--status") {
            // What the running Halo wrote (every 2 s).
            let file = FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent("Library/Application Support/Halo/status.json")
            print((try? String(contentsOf: file, encoding: .utf8)) ?? "no status: is Halo running?")
            return true
        }
        if let index = arguments.firstIndex(of: "--settings-tabs"), index + 1 < arguments.count {
            settingsTabs(into: URL(fileURLWithPath: arguments[index + 1], isDirectory: true))
            return true
        }
        if let index = arguments.firstIndex(of: "--readme"), index + 1 < arguments.count {
            ReadmeArt.render(into: URL(fileURLWithPath: arguments[index + 1], isDirectory: true))
            return true
        }
        if let index = arguments.firstIndex(of: "--appicon"), index + 1 < arguments.count {
            ReadmeArt.appIcon(to: URL(fileURLWithPath: arguments[index + 1]))
            return true
        }
        if let index = arguments.firstIndex(of: "--snapshot"), index + 1 < arguments.count {
            snapshot(into: URL(fileURLWithPath: arguments[index + 1], isDirectory: true))
            return true
        }
        return false
    }

    /// `--dump`, or `--dump en` / `fr` / `he` for another language than the one in Settings.
    private static func dump(language: String?) {
        let settings = HaloSettings()
        let strings = Strings(lang: language.flatMap(Lang.init(rawValue:)) ?? settings.lang)
        let store = SessionStore(settings: settings)
        store.loadHidden()
        for session in store.snapshot() {
            let kind = session.isLive ? "live  " : "paused"
            print("\(kind)\t\(session.icon.symbol)\t\(strings.label(session.state))\t\(session.name)")
            // What its hover card would say.
            guard let id = session.transcriptId, let url = SessionDetailStore.shared.transcript(id),
                  let detail = SessionDetailReader.read(transcript: url, state: session.state, strings: strings)
            else { continue }
            let parts: [String] = detail.lines + [detail.code].compactMap { $0 } + detail.options
            let body = parts.prefix(2).map { String($0.prefix(70)) }.joined(separator: " | ")
            print("      ↳ \(detail.title) : \(body)")
        }
    }

    private static func snapshot(into directory: URL) {
        let store = SessionStore(preview: Samples.sessions())
        let details = Samples.details()
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        render(store, details, edge: .bottom, notch: nil, hoverIndex: 1,
               to: directory.appendingPathComponent("halo-bottom.png"))
        render(store, details, edge: .right, notch: nil, hoverIndex: 0,
               to: directory.appendingPathComponent("halo-right.png"))
        render(store, details, edge: .top, notch: CGSize(width: 185, height: 32), hoverIndex: nil,
               to: directory.appendingPathComponent("halo-notch.png"))
        render(store, details, edge: .top, notch: CGSize(width: 185, height: 32), hoverIndex: 2, scroll: 60,
               to: directory.appendingPathComponent("halo-notch-scroll.png"))
        render(store, details, edge: .bottom, notch: nil, hoverIndex: 3, iconSize: 30,
               to: directory.appendingPathComponent("halo-small.png"))
        snapshotSettings(into: directory)
    }

    /// Each Settings tab, with this Mac's real settings, language and light or dark mode.
    private static func settingsTabs(into directory: URL) {
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let settings = HaloSettings()
        let store = SessionStore(settings: settings)
        store.loadHidden()
        _ = store.snapshot()
        let actions = SettingsActions(store: store, layout: DockLayout(settings: settings), place: { _ in },
                                      moveToScreen: { _ in }, launchAtLogin: .constant(false))
        let tabs: [(String, AnyView)] = [
            ("1-general", AnyView(GeneralTab(settings: settings, actions: actions))),
            ("2-apparence", AnyView(AppearanceTab(settings: settings))),
            ("3-sessions", AnyView(SessionsTab(settings: settings, store: store))),
            ("4-animations", AnyView(AnimationsTab(settings: settings))),
            ("5-icones", AnyView(IconsTab(store: store))),
        ]
        for (name, tab) in tabs {
            let view = tab
                .formStyle(.grouped)
                .frame(width: 560, height: 560)
                .environment(\.strings, settings.strings)
                .environment(\.layoutDirection, settings.lang.layoutDirection)
            let hosting = NSHostingView(rootView: view)
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 560, height: 560), styleMask: [.borderless],
                                  backing: .buffered, defer: false)
            window.appearance = NSApp.effectiveAppearance
            window.backgroundColor = NSColor.windowBackgroundColor
            window.contentView = hosting
            hosting.layoutSubtreeIfNeeded()
            guard let rep = hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds) else { continue }
            hosting.cacheDisplay(in: hosting.bounds, to: rep)
            try? rep.representation(using: .png, properties: [:])?.write(to: directory.appendingPathComponent("\(name).png"))
            print("tab → \(name).png")
        }
    }

    /// The Settings window in each language, and a hover card in Hebrew (right to left).
    private static func snapshotSettings(into directory: URL) {
        for language in [LanguageChoice.fr, .en, .he] {
            guard let image = ReadmeArt.settingsImage(language: language),
                  let tiff = image.tiffRepresentation,
                  let png = NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]) else { continue }
            let url = directory.appendingPathComponent("halo-settings-\(language.rawValue).png")
            try? png.write(to: url)
            print("snapshot → \(url.path)")
        }
        let strings = Strings(lang: .he)
        let session = Samples.sessions().first { $0.name == "API migration" }!
        let card = SessionCard(session: session, showDetails: true)
            .padding(30)
            .background(Color(hex: 0x1A1726))
            .environment(\.offscreen, true)
            .environment(\.strings, strings)
            .environment(\.previewDetails, Samples.details(strings))
        let renderer = ImageRenderer(content: card)
        renderer.scale = 2
        if let image = renderer.cgImage,
           let png = NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]) {
            try? png.write(to: directory.appendingPathComponent("halo-card-he.png"))
            print("snapshot → halo-card-he.png")
        }
    }

    private static func render(_ store: SessionStore, _ details: [String: SessionDetail], edge: DockEdge,
                               notch: CGSize?, hoverIndex: Int?, iconSize: CGFloat = DockMetrics.standardItem,
                               scroll: CGFloat = 0, to url: URL) {
        let settings = HaloSettings(persistent: false)
        settings.iconSize = Double(iconSize)
        let layout = DockLayout(settings: settings)
        layout.edge = edge
        layout.notch = notch
        let metrics = layout.metrics
        let size = metrics.windowSize(layout.shownStrip(store.strip), edge: edge, topInset: layout.topInset)
        let pointer = Pointer()
        let main = edge.isHorizontal ? size.width : size.height
        if let hoverIndex {
            pointer.hover = metrics.baseCenters(store.strip, mainLength: main)[hoverIndex] + 6
            pointer.hoveredIndex = hoverIndex
        }
        pointer.scroll = scroll

        let view = ZStack(alignment: .top) {
            LinearGradient(colors: [Color(red: 0.36, green: 0.42, blue: 0.62), Color(red: 0.78, green: 0.55, blue: 0.52)],
                           startPoint: .topLeading, endPoint: .bottomTrailing)
            if notch != nil {
                // A fake menu bar and notch, to see the island attach to them.
                Rectangle().fill(.white.opacity(0.25)).frame(height: notch!.height)
                UnevenRoundedRectangle(bottomLeadingRadius: 10, bottomTrailingRadius: 10)
                    .fill(.black).frame(width: notch!.width, height: notch!.height)
            }
            DockView(store: store, pointer: pointer, layout: layout, actions: .none)
                .environment(\.offscreen, true)
                .environment(\.previewDetails, details)
        }
        .frame(width: size.width, height: size.height)

        let renderer = ImageRenderer(content: view)
        renderer.scale = 2
        guard let image = renderer.cgImage,
              let png = NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]) else {
            print("snapshot failed: \(url.lastPathComponent)")
            return
        }
        try? png.write(to: url)
        print("snapshot → \(url.path)")
    }
}

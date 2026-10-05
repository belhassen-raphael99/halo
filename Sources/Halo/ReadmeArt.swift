import AppKit
import ImageIO
import SwiftUI
import UniformTypeIdentifiers

// The README's artwork, drawn by Halo's own views so it always matches the app.
//   Halo --readme <dir>       hero, animated states, cards, placements, anatomy, palette, architecture, settings
//   Halo --appicon <file>     the app icon (.icns)

/// Sample sessions and hover-card details, shared by snapshots and artwork.
@MainActor
enum Samples {
    static func sessions(now: Double = Date().timeIntervalSince1970 * 1_000) -> [Session] {
        func sample(_ name: String, _ state: SessionState, live: Bool = true, ago: Double = 40_000) -> Session {
            Session(id: name, pid: live ? 1 : nil, name: name, cwd: "", isDesktop: true,
                    hostSessionId: nil, state: state, stateSince: now - ago)
        }
        return [
            sample("Landing page redesign", .working),
            sample("API migration", .needsYou(reason: "permission prompt")),
            sample("Unit tests", .done, ago: 450),
            sample("Mobile app", .rest),
            sample("Podcast transcription", .paused, live: false, ago: 70_000_000),
            sample("Trip planning", .paused, live: false, ago: 400_000_000),
        ]
    }

    static let details: [String: SessionDetail] = [
        "API migration": SessionDetail(title: "Autorisation demandée", lines: ["Lancer la migration de la base"],
                                       code: "npm run db:migrate"),
        "Landing page redesign": SessionDetail(title: "En ce moment", lines: ["Modifier un fichier"],
                                               code: "Hero.tsx"),
        "Unit tests": SessionDetail(title: "Dernière réponse",
                                    lines: ["Les 128 tests passent.", "2 snapshots ont été mis à jour."]),
        "Mobile app": SessionDetail(
            title: "Question pour toi", lines: ["Quelle base de données pour les comptes ?"],
            options: ["PostgreSQL (Recommandé)", "SQLite", "Firebase"]),
    ]
}

@MainActor
enum ReadmeArt {
    static func render(into directory: URL) {
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        func url(_ name: String) -> URL { directory.appendingPathComponent(name) }

        save(Hero(), size: CGSize(width: 1280, height: 600), to: url("hero.png"))
        save(StatesBoard(time: 1.0), size: StatesBoard.size, scale: 1.5, to: url("states.png"))
        saveAnimation(size: StatesBoard.size, scale: 1, duration: StatePreview.loop, fps: 12,
                      to: url("states-animated.png")) {
            StatesBoard(time: $0, flat: true)
        }
        save(CardsBoard(), size: CardsBoard.size, scale: 1.5, to: url("cards.png"))
        save(PlacementsBoard(), size: PlacementsBoard.size, scale: 1.5, to: url("placements.png"))
        save(AnatomyBoard(), size: AnatomyBoard.size, scale: 1.5, to: url("anatomy.png"))
        save(PaletteBoard(), size: PaletteBoard.size, scale: 1.5, to: url("palette.png"))
        save(ArchitectureBoard(), size: ArchitectureBoard.size, scale: 1.5, to: url("architecture.png"))
        save(HaloMark(size: 200).shadow(color: Color(hex: 0x8D9FFF).opacity(0.35), radius: 24),
             size: CGSize(width: 256, height: 256), to: url("mark.png"))
        if let settings = settingsImage() {
            save(SettingsBoard(screenshot: settings), size: SettingsBoard.size(for: settings), scale: 1.5,
                 to: url("settings.png"))
        }
    }

    /// The app icon, every size macOS asks for, packed into an .icns.
    static func appIcon(to icns: URL) {
        let iconset = FileManager.default.temporaryDirectory.appendingPathComponent("Halo.iconset", isDirectory: true)
        try? FileManager.default.removeItem(at: iconset)
        try? FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)
        for points in [16, 32, 128, 256, 512] {
            for scale in [1, 2] {
                let name = "icon_\(points)x\(points)\(scale == 2 ? "@2x" : "").png"
                save(AppIconArt(), size: CGSize(width: 1024, height: 1024),
                     scale: CGFloat(points * scale) / 1024, to: iconset.appendingPathComponent(name), quiet: true)
            }
        }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
        process.arguments = ["-c", "icns", iconset.path, "-o", icns.path]
        try? process.run()
        process.waitUntilExit()
        print(process.terminationStatus == 0 ? "icon → \(icns.path)" : "iconutil failed")
    }

    /// The Settings window, drawn by AppKit itself (its controls are AppKit views).
    static func settingsImage() -> NSImage? {
        let actions = SettingsActions(hiddenCount: { 2 }, unhideAll: {}, resetPosition: {},
                                      launchAtLogin: .constant(true))
        let hosting = NSHostingView(rootView: SettingsView(settings: HaloSettings(persistent: false), actions: actions))
        let window = NSWindow(contentRect: NSRect(origin: .zero, size: hosting.fittingSize), styleMask: [.borderless],
                              backing: .buffered, defer: false)
        window.appearance = NSAppearance(named: .darkAqua)
        window.backgroundColor = .windowBackgroundColor
        window.contentView = hosting
        hosting.layoutSubtreeIfNeeded()
        let bounds = hosting.bounds
        guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(bounds.width * 2),
                                         pixelsHigh: Int(bounds.height * 2), bitsPerSample: 8, samplesPerPixel: 4,
                                         hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                                         bytesPerRow: 0, bitsPerPixel: 0) else { return nil }
        rep.size = bounds.size
        hosting.cacheDisplay(in: bounds, to: rep)
        let image = NSImage(size: bounds.size)
        image.addRepresentation(rep)
        return image
    }

    // MARK: - Output

    private static func save<V: View>(_ view: V, size: CGSize, scale: CGFloat = 2, to url: URL, quiet: Bool = false) {
        let renderer = ImageRenderer(content: framed(view, size))
        renderer.scale = scale
        guard let image = renderer.cgImage,
              let png = NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]) else {
            print("render failed: \(url.lastPathComponent)")
            return
        }
        try? png.write(to: url)
        if !quiet { print("art → \(url.lastPathComponent)") }
    }

    /// An animated PNG: plays in browsers and on GitHub, in full color (unlike a GIF).
    private static func saveAnimation<V: View>(size: CGSize, scale: CGFloat, duration: Double, fps: Double,
                                               to url: URL, content: (Double) -> V) {
        let count = Int((duration * fps).rounded())
        guard let destination = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString,
                                                                count, nil) else { return }
        CGImageDestinationSetProperties(destination, [
            kCGImagePropertyPNGDictionary as String: [kCGImagePropertyAPNGLoopCount as String: 0],
        ] as CFDictionary)
        for index in 0..<count {
            let renderer = ImageRenderer(content: framed(content(Double(index) / fps), size))
            renderer.scale = scale
            guard let image = renderer.cgImage else { continue }
            CGImageDestinationAddImage(destination, image, [
                kCGImagePropertyPNGDictionary as String: [kCGImagePropertyAPNGDelayTime as String: 1 / fps],
            ] as CFDictionary)
        }
        CGImageDestinationFinalize(destination)
        print("art → \(url.lastPathComponent) (\(count) frames)")
    }

    private static func framed<V: View>(_ view: V, _ size: CGSize) -> some View {
        view
            .frame(width: size.width, height: size.height)
            .environment(\.offscreen, true)
            .environment(\.previewDetails, Samples.details)
            .environment(\.colorScheme, .dark)
    }
}

// MARK: - Shared pieces

/// A night sky with soft aurora glows: the backdrop of every board.
private struct Backdrop: View {
    var cornerRadius: CGFloat = 28

    var body: some View {
        GeometryReader { geo in
            let w = geo.size.width, h = geo.size.height
            ZStack {
                LinearGradient(colors: [Color(hex: 0x0D0C17), Color(hex: 0x17132A)], startPoint: .top, endPoint: .bottom)
                glow(0x8D9FFF, diameter: w * 0.42, x: w * 0.14, y: h * 0.12, opacity: 0.32)
                glow(0xBC82F3, diameter: w * 0.38, x: w * 0.86, y: h * 0.2, opacity: 0.28)
                glow(0xFF6778, diameter: w * 0.3, x: w * 0.78, y: h * 0.95, opacity: 0.16)
                glow(0xFFBA71, diameter: w * 0.26, x: w * 0.22, y: h * 0.98, opacity: 0.12)
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
            .strokeBorder(.white.opacity(0.08), lineWidth: 1))
    }

    private func glow(_ hex: UInt32, diameter: CGFloat, x: CGFloat, y: CGFloat, opacity: Double) -> some View {
        Circle()
            .fill(Color(hex: hex))
            .frame(width: diameter, height: diameter)
            .blur(radius: diameter * 0.32)
            .opacity(opacity)
            .position(x: x, y: y)
    }
}

/// Small caps over a title, the voice of every board.
private struct BoardTitle: View {
    let eyebrow: String
    let title: String

    var body: some View {
        VStack(spacing: 8) {
            Text(eyebrow.uppercased())
                .font(.system(size: 13, weight: .bold))
                .kerning(2.4)
                .foregroundStyle(LinearGradient(colors: [Color(hex: 0x8D9FFF), Color(hex: 0xBC82F3)],
                                                startPoint: .leading, endPoint: .trailing))
            Text(title)
                .font(.system(size: 30, weight: .bold, design: .rounded))
                .foregroundStyle(.white)
        }
    }
}

/// Halo's mark: a dark tile holding an aurora ring, with its comet.
struct HaloMark: View {
    let size: CGFloat

    var body: some View {
        let shape = tile(size)
        let ring = size * 0.56
        let aurora = AngularGradient(colors: Palette.aurora, center: .center, angle: .degrees(210))
        let comet = CGPoint(x: cos(-.pi / 4) * ring / 2, y: sin(-.pi / 4) * ring / 2)
        ZStack {
            shape.fill(LinearGradient(colors: [Color(hex: 0x2B2645), Color(hex: 0x0E0D18)],
                                      startPoint: .top, endPoint: .bottom))
            shape.fill(LinearGradient(colors: [.white.opacity(0.16), .white.opacity(0)],
                                      startPoint: .top, endPoint: UnitPoint(x: 0.5, y: 0.5)))
            Circle().stroke(aurora, lineWidth: size * 0.09).frame(width: ring, height: ring)
                .blur(radius: size * 0.06).opacity(0.85)
            Circle().stroke(aurora, lineWidth: size * 0.05).frame(width: ring, height: ring)
            Circle().fill(.white).frame(width: size * 0.075, height: size * 0.075)
                .shadow(color: .white, radius: size * 0.035)
                .offset(x: comet.x, y: comet.y)
            shape.strokeBorder(.white.opacity(0.14), lineWidth: max(1, size * 0.004))
        }
        .frame(width: size, height: size)
    }
}

/// The app icon: the mark on Apple's icon grid (824 of 1024, with its shadow).
private struct AppIconArt: View {
    var body: some View {
        HaloMark(size: 824)
            .shadow(color: .black.opacity(0.35), radius: 22, y: 14)
            .frame(width: 1024, height: 1024)
    }
}

/// A bar of real Halo views at a given placement, scaled to fit an illustration.
private struct BarSnapshot: View {
    let edge: DockEdge
    var notch: CGSize?
    var hovered: Int?
    var scale: CGFloat = 1
    var sessions: [Session] = Samples.sessions()

    var body: some View {
        let settings = HaloSettings(persistent: false)
        let layout = DockLayout(settings: settings)
        layout.edge = edge
        layout.notch = notch
        let store = SessionStore(preview: sessions)
        let size = layout.metrics.windowSize(layout.shownStrip(store.strip), edge: edge, topInset: layout.topInset)
        let pointer = Pointer()
        if let hovered {
            let main = edge.isHorizontal ? size.width : size.height
            pointer.hover = layout.metrics.baseCenters(store.strip, mainLength: main)[hovered] + 6
            pointer.hoveredIndex = hovered
        }
        return DockView(store: store, pointer: pointer, layout: layout, actions: .none)
            .frame(width: size.width, height: size.height)
            .scaleEffect(scale)
            .frame(width: size.width * scale, height: size.height * scale)
    }
}

// MARK: - Hero

private struct Hero: View {
    var body: some View {
        ZStack(alignment: .top) {
            Backdrop(cornerRadius: 32)
            VStack(spacing: 16) {
                HStack(spacing: 24) {
                    HaloMark(size: 104)
                        .shadow(color: Color(hex: 0x8D9FFF).opacity(0.35), radius: 30)
                    Text("Halo")
                        .font(.system(size: 112, weight: .bold, design: .rounded))
                        .foregroundStyle(LinearGradient(colors: [.white, Color(hex: 0xD8D2FF)],
                                                        startPoint: .top, endPoint: .bottom))
                }
                Text("A Dock for your Claude Code sessions.")
                    .font(.system(size: 30, weight: .medium))
                    .foregroundStyle(.white.opacity(0.88))
                Text("NATIVE MACOS  ·  SWIFTUI + CORE ANIMATION  ·  ~1 % CPU  ·  100 % LOCAL")
                    .font(.system(size: 13, weight: .semibold))
                    .kerning(2.2)
                    .foregroundStyle(.white.opacity(0.45))
            }
            .padding(.top, 62)

            BarSnapshot(edge: .bottom, hovered: 1)
                .frame(maxHeight: .infinity, alignment: .bottom)
                .padding(.bottom, 30)
        }
    }
}

// MARK: - States

/// One icon of each state, with its own animation drawn at time `t` (seconds in a loop).
/// The app runs these as Core Animation layers; here they are redrawn frame by frame.
private struct StatePreview: View {
    let session: Session
    let size: CGFloat
    let time: Double

    static let loop = 2.8

    var body: some View {
        let ring = tile(size, grow: 4)
        let side = size + 8
        ZStack {
            switch session.state {
            case .working: working(ring: ring, side: side)
            case .needsYou: needsYou(ring: ring, side: side)
            case .done: done(ring: ring, side: side)
            case .rest, .paused: face
            }
        }
        .frame(width: size, height: size)
        .offset(y: session.state.isNeedsYou ? -bounce(time) : 0)
        .frame(width: size, height: size)
        .overlay(alignment: .bottom) {
            if session.isLive {
                Circle().fill(.white.opacity(0.8)).frame(width: 5, height: 5).offset(y: 12)
            }
        }
    }

    private var face: some View {
        ZStack {
            IconFace(icon: session.icon, size: size, state: session.state)
            badge
        }
    }

    @ViewBuilder
    private var badge: some View {
        let diameter = size * 0.36
        Group {
            switch session.state {
            case .needsYou: BadgeDot(symbol: "exclamationmark", color: Palette.alert, diameter: diameter)
            case .done:
                BadgeDot(symbol: "checkmark", color: Palette.done, diameter: diameter)
                    .scaleEffect(time < 0.35 ? Self.easeOutBack(time / 0.35) : 1)
            case .paused: BadgeDot(symbol: "moon.zzz.fill", color: Color(white: 0.42), diameter: diameter * 0.9)
            default: EmptyView()
            }
        }
        .offset(x: size * 0.4, y: -size * 0.4)
    }

    private func working(ring: RoundedRectangle, side: CGFloat) -> some View {
        let aurora = AngularGradient(colors: Palette.aurora, center: .center, angle: .degrees(time / Self.loop * 360))
        let breathe = 0.5 - 0.5 * cos(2 * .pi * time / 1.4)
        let path = ring.path(in: CGRect(x: 0, y: 0, width: side, height: side))
        let sweep = time.truncatingRemainder(dividingBy: Self.loop) / Self.loop
        return ZStack {
            ring.stroke(aurora, lineWidth: 11).blur(radius: 10).opacity(0.45 + 0.35 * breathe)
                .frame(width: side, height: side)
            ring.stroke(aurora, lineWidth: 2.5).frame(width: side, height: side)
            IconFace(icon: session.icon, size: size, state: session.state)
            tile(size).fill(.white.opacity(0.16 * breathe)).frame(width: size, height: size)
            if sweep < 0.5 {
                LinearGradient(colors: [.clear, .white.opacity(0.32), .clear], startPoint: .leading, endPoint: .trailing)
                    .frame(width: size * 0.45, height: size * 1.8)
                    .rotationEffect(.degrees(22))
                    .offset(x: (sweep / 0.5 * 2.4 - 1.2) * size)
                    .frame(width: size, height: size)
                    .mask(tile(size))
            }
            // The comet and its tail, orbiting twice per loop.
            ZStack {
                ForEach(0..<4, id: \.self) { index in
                    let fraction = (time / 1.4 - Double(index) * 0.045 / 1.4).truncatingRemainder(dividingBy: 1)
                    let point = path.trimmedPath(from: 0, to: max(0.001, fraction < 0 ? fraction + 1 : fraction))
                        .currentPoint ?? .zero
                    let radius = [5.0, 4.0, 3.2, 2.4][index]
                    Circle().fill(.white)
                        .frame(width: radius, height: radius)
                        .shadow(color: .white, radius: 4)
                        .opacity([1, 0.6, 0.4, 0.22][index])
                        .position(point)
                }
            }
            .frame(width: side, height: side)
        }
    }

    private func needsYou(ring: RoundedRectangle, side: CGFloat) -> some View {
        let phase = time.truncatingRemainder(dividingBy: 1.4) / 1.4
        let pulse = 0.5 + 0.5 * cos(2 * .pi * time / 1.4)
        return ZStack {
            ring.stroke(Palette.alert, lineWidth: 9).blur(radius: 9).opacity(0.3 + 0.6 * pulse)
                .frame(width: side, height: side)
            ring.stroke(Palette.alert.opacity(0.8 * (1 - phase)), lineWidth: 2)
                .frame(width: side, height: side)
                .scaleEffect(1 + 0.3 * phase)
            ring.stroke(Palette.alert, lineWidth: 2.5).frame(width: side, height: side)
            face
        }
    }

    private func done(ring: RoundedRectangle, side: CGFloat) -> some View {
        let drawn = 1 - pow(1 - min(1, time / 0.5), 3)
        return ZStack {
            ring.stroke(Palette.done, lineWidth: 9).blur(radius: 9).opacity(0.3 + 0.25 * drawn)
                .frame(width: side, height: side)
            ring.trim(from: 0, to: drawn)
                .stroke(Palette.done, style: StrokeStyle(lineWidth: 2.5, lineCap: .round))
                .frame(width: side, height: side)
            SparkBurst(size: size, progress: (time - 0.15) / 1.2)
            face
        }
    }

    /// The app's bounce keyframes: 11, 8 and 4 pt.
    private func bounce(_ t: Double) -> CGFloat {
        let legs: [(height: Double, duration: Double)] = [(11, 0.28), (8, 0.25), (4, 0.2)]
        var start = 0.0
        for leg in legs {
            let span = leg.duration * 2
            if t < start + span {
                return CGFloat(sin((t - start) / span * .pi) * leg.height)
            }
            start += span
        }
        return 0
    }

    private static func easeOutBack(_ x: Double) -> CGFloat {
        let c1 = 1.70158, c3 = c1 + 1
        return CGFloat(1 + c3 * pow(x - 1, 3) + c1 * pow(x - 1, 2))
    }
}

private struct StatesBoard: View {
    let time: Double
    var flat = false
    static let size = CGSize(width: 1180, height: 400)

    private static let states: [(SessionState, String, String)] = [
        (.working, "Working", "Aurora glow, an orbiting comet,\na breathing tile"),
        (.needsYou(reason: "input needed"), "Needs you", "Red pulse, ripple and\nDock-style bounces"),
        (.done, "Done", "A ring drawn in a burst\nof sparks, until you look"),
        (.rest, "Idle", "Quiet, with the Dock's\nrunning dot"),
        (.paused, "Paused", "Dimmed, a moon badge,\nno running dot"),
    ]

    var body: some View {
        let icons = ["Landing page redesign", "API migration", "Unit tests", "Mobile app", "Podcast transcription"]
        ZStack {
            if flat {
                RoundedRectangle(cornerRadius: 28, style: .continuous).fill(Color(hex: 0x12101D))
                    .overlay(RoundedRectangle(cornerRadius: 28, style: .continuous)
                        .strokeBorder(.white.opacity(0.08), lineWidth: 1))
            } else {
                Backdrop()
            }
            HStack(alignment: .top, spacing: 0) {
                ForEach(Array(Self.states.enumerated()), id: \.offset) { index, item in
                    let session = Session(id: icons[index], pid: item.0 == .paused ? nil : 1, name: icons[index],
                                          cwd: "", isDesktop: true, hostSessionId: nil, state: item.0,
                                          stateSince: 0)
                    VStack(spacing: 14) {
                        StatePreview(session: session, size: 88, time: time)
                            .frame(height: 170)
                        Text(item.1)
                            .font(.system(size: 21, weight: .semibold, design: .rounded))
                            .foregroundStyle(.white)
                        Text(item.2)
                            .font(.system(size: 14))
                            .multilineTextAlignment(.center)
                            .foregroundStyle(.white.opacity(0.6))
                    }
                    .frame(maxWidth: .infinity)
                }
            }
            .padding(.horizontal, 30)
            .padding(.top, 40)
        }
    }
}

// MARK: - Hover cards

private struct CardsBoard: View {
    static let size = CGSize(width: 1180, height: 450)

    var body: some View {
        let now = Date().timeIntervalSince1970 * 1_000
        let columns: [(String, SessionState, String)] = [
            ("Mobile app", .needsYou(reason: "input needed"), "A question, and its choices"),
            ("API migration", .needsYou(reason: "permission prompt"), "A permission, and the exact command"),
            ("Landing page redesign", .working, "What it is doing right now"),
        ]
        ZStack(alignment: .top) {
            Backdrop()
            VStack(spacing: 30) {
                BoardTitle(eyebrow: "Hover", title: "It tells you what it needs")
                HStack(alignment: .top, spacing: 34) {
                    ForEach(columns, id: \.0) { name, state, caption in
                        let session = Session(id: name, pid: 1, name: name, cwd: "", isDesktop: true,
                                              hostSessionId: nil, state: state, stateSince: now - 95_000)
                        VStack(spacing: 18) {
                            SessionCard(session: session, showDetails: true)
                                .frame(height: 150, alignment: .bottom)
                            StatePreview(session: session, size: 56, time: 1.0)
                                .frame(height: 76)
                            Text(caption)
                                .font(.system(size: 14, weight: .medium))
                                .foregroundStyle(.white.opacity(0.6))
                        }
                        .frame(width: 320, alignment: .top)
                    }
                }
            }
            .padding(.top, 44)
        }
    }
}

// MARK: - Placements

private struct MiniScreen<Content: View>: View {
    let wallpaper: [UInt32]
    let caption: String
    let detail: String
    @ViewBuilder let content: Content

    static var screen: CGSize { CGSize(width: 520, height: 325) }

    var body: some View {
        VStack(spacing: 14) {
            ZStack(alignment: .top) {
                LinearGradient(colors: wallpaper.map(Color.init(hex:)), startPoint: .topLeading, endPoint: .bottomTrailing)
                // Menu bar and notch.
                Rectangle().fill(.black.opacity(0.18)).frame(height: 15)
                UnevenRoundedRectangle(bottomLeadingRadius: 6, bottomTrailingRadius: 6)
                    .fill(.black).frame(width: 74, height: 15)
                content
            }
            .frame(width: Self.screen.width, height: Self.screen.height)
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            .padding(9)
            .background(RoundedRectangle(cornerRadius: 20, style: .continuous).fill(Color(hex: 0x050508)))
            .overlay(RoundedRectangle(cornerRadius: 20, style: .continuous).strokeBorder(.white.opacity(0.12), lineWidth: 1))
            .shadow(color: .black.opacity(0.45), radius: 24, y: 14)
            VStack(spacing: 4) {
                Text(caption).font(.system(size: 18, weight: .semibold, design: .rounded)).foregroundStyle(.white)
                Text(detail).font(.system(size: 13.5)).foregroundStyle(.white.opacity(0.6))
            }
        }
    }
}

private struct PlacementsBoard: View {
    static let size = CGSize(width: 1180, height: 1010)
    private let scale: CGFloat = 0.5

    var body: some View {
        ZStack(alignment: .top) {
            Backdrop()
            VStack(spacing: 34) {
                BoardTitle(eyebrow: "Placement", title: "Drop it anywhere. It adapts.")
                Grid(horizontalSpacing: 44, verticalSpacing: 34) {
                    GridRow {
                        MiniScreen(wallpaper: [0x5B6FB0, 0xC08A94], caption: "Bottom",
                                   detail: "Sits like the Dock") {
                            BarSnapshot(edge: .bottom, scale: scale)
                                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
                                .padding(.bottom, 4)
                        }
                        MiniScreen(wallpaper: [0x3F6E8C, 0x8E7BB5], caption: "Left or right",
                                   detail: "Turns vertical") {
                            BarSnapshot(edge: .right, scale: scale)
                                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .trailing)
                                .padding(.trailing, 4)
                        }
                    }
                    GridRow {
                        MiniScreen(wallpaper: [0x2C3550, 0x9A6B7E], caption: "Top",
                                   detail: "Melts into the notch, three icons, scrolls") {
                            BarSnapshot(edge: .top, notch: CGSize(width: 74 / scale, height: 15 / scale), scale: scale)
                                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                        }
                        MiniScreen(wallpaper: [0x6A5A9C, 0xD39A7A], caption: "Anywhere",
                                   detail: "Floats where you drop it") {
                            BarSnapshot(edge: .bottom, scale: scale)
                                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
                                .offset(y: 30)
                        }
                    }
                }
            }
            .padding(.top, 44)
        }
    }
}

// MARK: - Anatomy

private struct AnatomyBoard: View {
    static let size = CGSize(width: 1180, height: 640)

    private struct Callout {
        let title: String
        let value: String
        let label: CGPoint
        let target: CGPoint
        let leading: Bool
    }

    var body: some View {
        let icon = AppIcon.for(name: "Recipe app", cwd: "")
        let side: CGFloat = 300
        let center = CGPoint(x: Self.size.width / 2, y: 360)
        let left = center.x - side / 2, top = center.y - side / 2
        let callouts = [
            Callout(title: "Squircle", value: "Continuous corners · radius 22.37 %",
                    label: CGPoint(x: 40, y: 210), target: CGPoint(x: left + 14, y: top + 14), leading: true),
            Callout(title: "Gradient", value: "#FFB340 → #E8590C, top to bottom",
                    label: CGPoint(x: 40, y: 345), target: CGPoint(x: left + 4, y: center.y + 10), leading: true),
            Callout(title: "Shadow", value: "Black 32 % · radius 6 % · 3.5 % down",
                    label: CGPoint(x: 40, y: 480), target: CGPoint(x: left + 60, y: top + side + 14), leading: true),
            Callout(title: "Sheen", value: "White 34 % → 0 over the top 55 %",
                    label: CGPoint(x: 800, y: 210), target: CGPoint(x: left + side - 70, y: top + 40), leading: false),
            Callout(title: "SF Symbol", value: "White · 46 % · semibold · hierarchical",
                    label: CGPoint(x: 800, y: 345), target: CGPoint(x: center.x + 40, y: center.y), leading: false),
            Callout(title: "Inner stroke", value: "0.6 pt · white 22 %",
                    label: CGPoint(x: 800, y: 480), target: CGPoint(x: left + side - 1, y: top + side - 70), leading: false),
        ]
        ZStack(alignment: .topLeading) {
            Backdrop()
            BoardTitle(eyebrow: "Design", title: "Anatomy of an icon")
                .frame(width: Self.size.width)
                .padding(.top, 44)
            IconFace(icon: icon, size: side, state: .rest)
                .position(center)
            Canvas { context, _ in
                for callout in callouts {
                    let start = CGPoint(x: callout.leading ? callout.label.x + 350 : callout.label.x - 14,
                                        y: callout.label.y + 6)
                    var line = Path()
                    line.move(to: start)
                    line.addLine(to: callout.target)
                    context.stroke(line, with: .color(.white.opacity(0.35)), lineWidth: 1)
                    context.fill(Path(ellipseIn: CGRect(x: callout.target.x - 4, y: callout.target.y - 4,
                                                        width: 8, height: 8)), with: .color(.white))
                }
            }
            ForEach(callouts, id: \.title) { callout in
                VStack(alignment: callout.leading ? .trailing : .leading, spacing: 4) {
                    Text(callout.title).font(.system(size: 17, weight: .semibold, design: .rounded))
                        .foregroundStyle(.white)
                    Text(callout.value).font(.system(size: 12, design: .monospaced))
                        .foregroundStyle(.white.opacity(0.6))
                        .lineLimit(1)
                        .fixedSize()
                }
                .frame(width: 340, alignment: callout.leading ? .trailing : .leading)
                .position(x: callout.label.x + 170, y: callout.label.y + 14)
            }
        }
    }
}

// MARK: - Palette

private struct PaletteBoard: View {
    static let size = CGSize(width: 1180, height: 520)

    var body: some View {
        let aurora: [UInt32] = [0xBC82F3, 0xF5B9EA, 0x8D9FFF, 0xAA6EEE, 0xFF6778, 0xFFBA71, 0xC686FF]
        ZStack(alignment: .top) {
            Backdrop()
            VStack(spacing: 34) {
                BoardTitle(eyebrow: "Color", title: "A quiet palette, loud only when needed")
                VStack(alignment: .leading, spacing: 12) {
                    Text("Working · aurora").font(.system(size: 15, weight: .semibold)).foregroundStyle(.white)
                    Capsule()
                        .fill(LinearGradient(colors: aurora.map(Color.init(hex:)), startPoint: .leading, endPoint: .trailing))
                        .frame(height: 64)
                        .shadow(color: Color(hex: 0xAA6EEE).opacity(0.5), radius: 24)
                    HStack {
                        ForEach(aurora, id: \.self) { hex in
                            Text(String(format: "#%06X", hex))
                                .font(.system(size: 12, design: .monospaced))
                                .foregroundStyle(.white.opacity(0.6))
                                .frame(maxWidth: .infinity)
                        }
                    }
                }
                .frame(width: 1040)
                HStack(spacing: 26) {
                    swatch(name: "Needs you", value: "#FF453A · system red") {
                        RoundedRectangle(cornerRadius: 18, style: .continuous).fill(Palette.alert)
                            .shadow(color: Palette.alert.opacity(0.5), radius: 18)
                    }
                    swatch(name: "Done", value: "#32D74B · system green") {
                        RoundedRectangle(cornerRadius: 18, style: .continuous).fill(Palette.done)
                            .shadow(color: Palette.done.opacity(0.45), radius: 18)
                    }
                    swatch(name: "Glass", value: "HUD blur · 0.5 pt border") {
                        GlassBackground(cornerRadius: 18)
                    }
                    swatch(name: "Notch", value: "#000000 · one with the notch") {
                        RoundedRectangle(cornerRadius: 18, style: .continuous).fill(.black)
                            .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous)
                                .strokeBorder(.white.opacity(0.1), lineWidth: 1))
                    }
                }
            }
            .padding(.top, 44)
        }
    }

    private func swatch<S: View>(name: String, value: String, @ViewBuilder fill: () -> S) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            fill().frame(width: 240, height: 120)
            Text(name).font(.system(size: 15, weight: .semibold)).foregroundStyle(.white)
            Text(value).font(.system(size: 12, design: .monospaced)).foregroundStyle(.white.opacity(0.6))
        }
    }
}

// MARK: - Architecture

private struct ArchitectureBoard: View {
    static let size = CGSize(width: 1180, height: 500)

    var body: some View {
        let sources: [(String, String, String)] = [
            ("~/.claude/sessions/<pid>.json", "Live status: busy · idle · waiting", "every 0.5 s"),
            ("…/claude-code-sessions/…/local_*.json", "Titles, paused sessions, last focus", "every 1 s, first 8 KB"),
            ("~/.claude/projects/…/<id>.jsonl", "What it asks or does (hover card)", "on hover, last 384 KB"),
        ]
        ZStack(alignment: .top) {
            Backdrop()
            VStack(spacing: 30) {
                BoardTitle(eyebrow: "How it works", title: "Reads what Claude already writes. Nothing else.")
                HStack(alignment: .center, spacing: 0) {
                    VStack(spacing: 16) {
                        ForEach(sources, id: \.0) { path, what, when in
                            VStack(alignment: .leading, spacing: 5) {
                                Text(path).font(.system(size: 12.5, weight: .medium, design: .monospaced))
                                    .foregroundStyle(Color(hex: 0xC9C3FF))
                                Text(what).font(.system(size: 14, weight: .semibold)).foregroundStyle(.white)
                                Text(when).font(.system(size: 12)).foregroundStyle(.white.opacity(0.5))
                            }
                            .padding(14)
                            .frame(width: 310, alignment: .leading)
                            .background(GlassBackground(cornerRadius: 14))
                        }
                    }
                    arrow(label: "read-only")
                    VStack(spacing: 12) {
                        HaloMark(size: 74).shadow(color: Color(hex: 0x8D9FFF).opacity(0.35), radius: 20)
                        Text("State engine").font(.system(size: 17, weight: .semibold, design: .rounded))
                            .foregroundStyle(.white)
                        VStack(alignment: .leading, spacing: 6) {
                            rule("busy", "working", Palette.aurora[2])
                            rule("waiting", "needs you", Palette.alert)
                            rule("idle after a turn", "done", Palette.done)
                            rule("idle, seen", "idle", .white.opacity(0.7))
                            rule("not running", "paused", Color(white: 0.6))
                        }
                    }
                    .padding(20)
                    .frame(width: 260)
                    .background(GlassBackground(cornerRadius: 18))
                    arrow(label: "no network")
                    VStack(spacing: 16) {
                        BarSnapshot(edge: .bottom, scale: 0.58)
                            .frame(height: 100, alignment: .bottom)
                            .clipped()
                        VStack(alignment: .leading, spacing: 6) {
                            Label("Click: open the session", systemImage: "cursorarrow.click")
                            Label("⌥-click: open it side by side", systemImage: "rectangle.split.2x1")
                            Label("Hover: what it needs", systemImage: "text.bubble")
                        }
                        .font(.system(size: 13))
                        .foregroundStyle(.white.opacity(0.75))
                    }
                    .frame(width: 300)
                }
            }
            .padding(.top, 44)
        }
    }

    private func arrow(label: String) -> some View {
        VStack(spacing: 6) {
            Image(systemName: "arrow.right")
                .font(.system(size: 22, weight: .semibold))
                .foregroundStyle(LinearGradient(colors: [Color(hex: 0x8D9FFF), Color(hex: 0xBC82F3)],
                                                startPoint: .leading, endPoint: .trailing))
            Text(label.uppercased()).font(.system(size: 10, weight: .bold)).kerning(1.4)
                .foregroundStyle(.white.opacity(0.4))
        }
        .frame(width: 110)
    }

    private func rule(_ input: String, _ output: String, _ color: Color) -> some View {
        HStack(spacing: 8) {
            Text(input).font(.system(size: 12, design: .monospaced)).foregroundStyle(.white.opacity(0.6))
            Image(systemName: "arrow.right").font(.system(size: 9, weight: .bold)).foregroundStyle(.white.opacity(0.35))
            Circle().fill(color).frame(width: 7, height: 7)
            Text(output).font(.system(size: 12.5, weight: .semibold)).foregroundStyle(.white)
        }
    }
}

// MARK: - Settings

private struct SettingsBoard: View {
    let screenshot: NSImage

    static func size(for image: NSImage) -> CGSize {
        CGSize(width: image.size.width + 240, height: image.size.height + 34 + 120)
    }

    var body: some View {
        ZStack {
            Backdrop()
            VStack(spacing: 0) {
                // A window title bar, like the real one.
                ZStack {
                    HStack(spacing: 8) {
                        ForEach([0xFF5F57, 0xFEBC2E, 0x28C840] as [UInt32], id: \.self) {
                            Circle().fill(Color(hex: $0)).frame(width: 12, height: 12)
                        }
                        Spacer()
                    }
                    Text("Réglages de Halo").font(.system(size: 13, weight: .semibold)).foregroundStyle(.white.opacity(0.85))
                }
                .padding(.horizontal, 14)
                .frame(height: 34)
                .background(Color(hex: 0x2A2A2D))
                Image(nsImage: screenshot)
            }
            .frame(width: screenshot.size.width)
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(.white.opacity(0.14), lineWidth: 1))
            .shadow(color: .black.opacity(0.5), radius: 30, y: 18)
        }
    }
}

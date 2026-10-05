import AppKit
import SwiftUI

/// Pointer position along the bar, shared by the window controller (which tracks the
/// mouse) and the view.
@MainActor
@Observable
final class Pointer {
    /// Pointer coordinate along the bar's axis while it hovers the bar; nil otherwise.
    var hover: CGFloat?
    /// The icon under the pointer, chosen with a little stickiness (see AppController).
    var hoveredIndex: Int?
    /// How far the compact bar (in the notch) is scrolled.
    var scroll: CGFloat = 0
    /// A short message shown above the bar for a few seconds.
    var toast: String?
}

/// Where the bar lives. The controller decides; the view follows.
@MainActor
@Observable
final class DockLayout {
    let settings: HaloSettings
    var edge: DockEdge = .bottom
    /// Size of the screen's notch while the bar is docked into it.
    var notch: CGSize?
    /// Dropped away from the edges (Settings shows "Free-floating").
    var floating = false
    /// Which of the Mac's screens it is on.
    var screenIndex = 0

    init(settings: HaloSettings) {
        self.settings = settings
    }

    /// Icon size and magnification come from the settings (pinch, menu, Settings window).
    var metrics: DockMetrics {
        DockMetrics(item: settings.iconSize, maxScale: settings.zoomEnabled ? settings.magnification : 1)
    }

    /// Extra room at the top of the window, taken by the notch.
    var topInset: CGFloat { edge == .top ? (notch?.height ?? 0) : 0 }

    /// Docked at the top, the bar stays small so the notch stays small: a few icons
    /// (`compactVisible` in the settings), the most urgent first, and the rest scroll by.
    var isCompact: Bool { edge == .top }

    /// The icons the bar has room for: all of them, or `compactVisible` at the top.
    func shownStrip(_ strip: Strip, edge: DockEdge? = nil) -> Strip {
        guard (edge ?? self.edge) == .top else { return strip }
        return Strip(count: min(strip.count, settings.compactVisible), dividerBefore: nil)
    }
}

struct DockActions {
    let open: (Session) -> Void
    /// Opens it next to the session already showing in the Claude app (⌥-click).
    let openBeside: (Session) -> Void
    let close: (Session) -> Void
    let unhideAll: () -> Void
    let setIconSize: (CGFloat) -> Void
    let showSettings: () -> Void
    let hideBar: () -> Void
    let showWaiting: () -> Void
    let launchAtLogin: Binding<Bool>
    let quit: () -> Void

    static var none: DockActions {
        DockActions(open: { _ in }, openBeside: { _ in }, close: { _ in }, unhideAll: {}, setIconSize: { _ in },
                    showSettings: {}, hideBar: {}, showWaiting: {},
                    launchAtLogin: .constant(false), quit: {})
    }
}

/// Off-screen renders (snapshots) cannot draw AppKit views — the live blur, the Core
/// Animation effects — so they get static SwiftUI stand-ins instead.
private struct OffscreenKey: EnvironmentKey {
    static let defaultValue = false
}

/// Which effects are on: from the settings, and off when macOS asks to reduce motion.
struct DockEffects: Equatable {
    var motion = true
    var working = true
    var style = WorkingStyle.aurora
    var bounce = true
    var celebration = true
    var details = true
}

/// Marks drawn on the bar itself: white on the black notch island, the system's text color on glass.
private struct BarForegroundKey: EnvironmentKey {
    static let defaultValue = Color.primary
}

private struct DockEffectsKey: EnvironmentKey {
    static let defaultValue = DockEffects()
}

/// Details given directly, by session id (snapshots), instead of read from transcripts.
private struct PreviewDetailsKey: EnvironmentKey {
    static let defaultValue: [String: SessionDetail] = [:]
}

extension EnvironmentValues {
    var offscreen: Bool {
        get { self[OffscreenKey.self] }
        set { self[OffscreenKey.self] = newValue }
    }

    var barForeground: Color {
        get { self[BarForegroundKey.self] }
        set { self[BarForegroundKey.self] = newValue }
    }

    var dockEffects: DockEffects {
        get { self[DockEffectsKey.self] }
        set { self[DockEffectsKey.self] = newValue }
    }

    var previewDetails: [String: SessionDetail] {
        get { self[PreviewDetailsKey.self] }
        set { self[PreviewDetailsKey.self] = newValue }
    }
}

enum Palette {
    static let alert = Color(hex: 0xFF453A)
    static let done = Color(hex: 0x32D74B)
    /// Apple Intelligence-style glow, for a session at work.
    static let aurora: [Color] = [0xBC82F3, 0xF5B9EA, 0x8D9FFF, 0xAA6EEE, 0xFF6778, 0xFFBA71, 0xC686FF, 0xBC82F3]
        .map(Color.init(hex:))
}

/// Apple's icon tile: a continuous rounded square.
func tile(_ size: CGFloat, grow: CGFloat = 0) -> RoundedRectangle {
    RoundedRectangle(cornerRadius: size * 0.2237 + grow, style: .continuous)
}

// MARK: - Dock

struct DockView: View {
    let store: SessionStore
    let pointer: Pointer
    let layout: DockLayout
    let actions: DockActions
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        let settings = layout.settings
        let effects = DockEffects(motion: !reduceMotion, working: settings.workingEffects, style: settings.workingStyle,
                                  bounce: settings.bounce, celebration: settings.celebration,
                                  details: settings.showDetails)
        GeometryReader { geo in
            let edge = layout.edge
            let metrics = layout.metrics
            let sessions = store.sessions
            let strip = store.strip
            let mainLength = edge.isHorizontal ? geo.size.width : geo.size.height
            let centers = metrics.baseCenters(strip, mainLength: mainLength)

            ZStack(alignment: edge.alignment) {
                Color.clear
                bar(edge: edge, metrics: metrics, sessions: sessions, strip: strip, centers: centers,
                    hover: pointer.hover, hovered: pointer.hoveredIndex)
            }
            .frame(width: geo.size.width, height: geo.size.height)
        }
        .environment(\.dockEffects, effects)
        .environment(\.strings, settings.strings)
        .environment(\.barForeground, layout.edge == .top && layout.notch != nil ? .white : .primary)
    }

    private func bar(edge: DockEdge, metrics: DockMetrics, sessions: [Session], strip: Strip,
                     centers: [CGFloat], hover: CGFloat?, hovered: Int?) -> some View {
        let compact = layout.isCompact
        let shown = compact ? Self.byUrgency(sessions) : sessions
        let viewport = metrics.rowLength(count: layout.shownStrip(strip).count)
        let maxScroll = compact ? max(0, metrics.rowLength(count: shown.count) - viewport) : 0

        let outer = edge.isHorizontal
            ? AnyLayout(HStackLayout(alignment: edge == .top ? .top : .bottom, spacing: metrics.spacing))
            : AnyLayout(VStackLayout(alignment: edge == .left ? .leading : .trailing, spacing: metrics.spacing))

        return outer {
            if compact {
                compactRow(metrics: metrics, sessions: shown, hovered: hovered,
                           viewport: viewport, maxScroll: maxScroll)
            } else {
                fullRow(edge: edge, metrics: metrics, sessions: shown, strip: strip, centers: centers,
                        hover: hover, hovered: hovered)
            }
            // The settings, one click away at the end of the bar.
            GearButton(size: metrics.gearSize, action: actions.showSettings)
                .padding(edge.swiftUIEdge, (metrics.item - metrics.gearSize) / 2)
        }
        .padding(edge.isHorizontal ? .horizontal : .vertical, metrics.padding)
        .frame(minWidth: edge == .top ? layout.notch.map { $0.width + 48 } : nil)
        .padding(edge.swiftUIEdge, metrics.padding + layout.topInset)
        .background(alignment: edge.alignment) {
            barBackground(edge: edge, metrics: metrics)
        }
        .overlay(alignment: edge.awayAlignment) {
            if let toast = pointer.toast {
                Text(toast)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.primary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 300)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .background(GlassBackground(cornerRadius: 10, solid: true))
                    .fixedSize(horizontal: false, vertical: true)
                    .modifier(BubblePlacement(edge: edge))
                    .environment(\.layoutDirection, layout.settings.lang.layoutDirection)
                    .transition(.opacity.combined(with: .scale(scale: 0.95)))
                    .allowsHitTesting(false)
            }
        }
        .animation(.spring(response: 0.35, dampingFraction: 0.85), value: pointer.toast)
        .overlay(alignment: .top) {
            // Placed from the top: the row's height changes when an icon is hovered.
            if compact && maxScroll > 0 {
                ScrollIndicator(fraction: viewport / (viewport + maxScroll),
                                position: pointer.scroll / maxScroll)
                    .offset(y: layout.topInset + metrics.barThickness - 5)
            }
        }
        .overlay(alignment: .top) {
            if compact {
                let islandBottom = layout.topInset + metrics.barThickness
                // The name goes under the island: inside the row it would be cut off.
                if let hovered, shown.indices.contains(hovered) {
                    SessionCard(session: shown[hovered], showDetails: layout.settings.showDetails)
                        .fixedSize()
                        .offset(y: islandBottom + 10 + (compactZoom - 1) * metrics.item)
                        .transition(.opacity)
                        .allowsHitTesting(false)
                }
            }
        }
        .animation(.interactiveSpring(response: 0.26, dampingFraction: 0.8), value: hover)
        .animation(.spring(response: 0.45, dampingFraction: 0.78), value: shown.map(\.id))
        .animation(.spring(response: 0.38, dampingFraction: 0.6), value: shown.map(\.state))
        .animation(.spring(response: 0.5, dampingFraction: 0.82), value: edge)
        .contextMenu {
            let s = layout.settings.strings
            Button(s.openWaiting, action: actions.showWaiting)
            if store.hiddenCount > 0 {
                Button(s.showRemoved(store.hiddenCount), action: actions.unhideAll)
            }
            Divider()
            Menu(s.barSize) {
                Button(s.sizeSmall) { actions.setIconSize(32) }
                Button(s.sizeMedium) { actions.setIconSize(DockMetrics.standardItem) }
                Button(s.sizeLarge) { actions.setIconSize(62) }
                Divider()
                Text(s.pinchHint)
            }
            Toggle(s.launchAtLogin, isOn: actions.launchAtLogin)
            Button(s.settingsItem, action: actions.showSettings)
            Button(layout.settings.hotKeyEnabled ? "\(s.hideBar)  \(layout.settings.hotKeyLabel)" : s.hideBar,
                   action: actions.hideBar)
            Divider()
            Button(s.quit, action: actions.quit)
        }
    }

    /// Every icon, with the Dock's fish-eye magnification.
    private func fullRow(edge: DockEdge, metrics: DockMetrics, sessions: [Session], strip: Strip,
                         centers: [CGFloat], hover: CGFloat?, hovered: Int?) -> some View {
        let stack = edge.isHorizontal
            ? AnyLayout(HStackLayout(alignment: edge == .top ? .top : .bottom, spacing: metrics.spacing))
            : AnyLayout(VStackLayout(alignment: edge == .left ? .leading : .trailing, spacing: metrics.spacing))

        return stack {
            if sessions.isEmpty {
                EmptyIcon(edge: edge, metrics: metrics, showLabel: hover != nil)
            }
            ForEach(Array(sessions.enumerated()), id: \.element.id) { index, session in
                if index == strip.dividerBefore {
                    DockDivider(edge: edge, metrics: metrics)
                }
                icon(session, size: metrics.item * metrics.scale(center: centers[index], pointer: hover),
                     metrics: metrics, edge: edge, hovered: hovered == index, showName: true)
            }
        }
    }

    /// How much the hovered icon grows in the notch: a hint, or the full zoom if asked for.
    private var compactZoom: CGFloat {
        let settings = layout.settings
        return settings.zoomEnabled && settings.zoomInNotch ? CGFloat(min(settings.magnification, 1.6)) : 1.06
    }

    /// A few icons in a window that scrolls as the pointer slides along it.
    private func compactRow(metrics: DockMetrics, sessions: [Session], hovered: Int?,
                            viewport: CGFloat, maxScroll: CGFloat) -> some View {
        let scroll = min(pointer.scroll, maxScroll)
        return HStack(alignment: .top, spacing: metrics.spacing) {
            if sessions.isEmpty {
                EmptyIcon(edge: .top, metrics: metrics, showLabel: false)
            }
            ForEach(Array(sessions.enumerated()), id: \.element.id) { index, session in
                icon(session, size: metrics.item * (hovered == index ? compactZoom : 1),
                     metrics: metrics, edge: .top, hovered: hovered == index, showName: false)
            }
        }
        .offset(x: -scroll)
        .frame(width: viewport, alignment: .leading)
        .mask(EdgeFade(width: viewport, fadeLeading: scroll > 1, fadeTrailing: scroll < maxScroll - 1))
        .animation(.interactiveSpring(response: 0.3, dampingFraction: 0.85), value: scroll)
    }

    private func icon(_ session: Session, size: CGFloat, metrics: DockMetrics, edge: DockEdge,
                      hovered: Bool, showName: Bool) -> some View {
        IconView(session: session, size: size, metrics: metrics, edge: edge,
                 showName: showName && hovered, showClose: hovered,
                 close: { actions.close(session) })
            .zIndex(hovered ? 1 : 0)
            .onTapGesture { actions.open(session) }
            .contextMenu {
                let s = layout.settings.strings
                Button(s.open) { actions.open(session) }
                Button(s.openBeside) { actions.openBeside(session) }
                Button(store.isPinned(session) ? s.unpin : s.pinFirst) { store.togglePin(session) }
                Button(s.anotherIcon) { IconRulesStore.shared.nextIcon(for: session.name) }
                Divider()
                Button(s.removeFromBar) { actions.close(session) }
            }
            .transition(.scale(scale: 0.2).combined(with: .opacity))
    }

    /// Most urgent first; ties keep the bar's usual order.
    static func byUrgency(_ sessions: [Session]) -> [Session] {
        sessions.enumerated()
            .sorted { ($0.element.state.urgency, $0.offset) < ($1.element.state.urgency, $1.offset) }
            .map(\.element)
    }

    @ViewBuilder
    private func barBackground(edge: DockEdge, metrics: DockMetrics) -> some View {
        if edge == .top, let notch = layout.notch {
            // Docked into the notch: one black shape that the notch seems to pour into.
            NotchIsland()
                .fill(.black)
                .padding(.horizontal, -NotchIsland.ear)
                .frame(height: notch.height + metrics.barThickness)
        } else {
            GlassBackground(cornerRadius: metrics.cornerRadius)
                .frame(width: edge.isHorizontal ? nil : metrics.barThickness,
                       height: edge.isHorizontal ? metrics.barThickness : nil)
        }
    }
}

// MARK: - Icon

struct IconView: View {
    let session: Session
    /// Current size, magnification included.
    let size: CGFloat
    let metrics: DockMetrics
    let edge: DockEdge
    let showName: Bool
    let showClose: Bool
    let close: () -> Void
    @Environment(\.dockEffects) private var effects
    @Environment(\.strings) private var strings
    @Environment(\.barForeground) private var barForeground
    @Environment(\.offscreen) private var offscreen

    var body: some View {
        let dot = 7 * metrics.unit
        ZStack {
            StateEffect(state: session.state, size: size, since: session.stateSince)
            IconFace(icon: session.icon, size: size, state: session.state)
            badge(size: size)
        }
        .frame(width: size, height: size)
        .modifier(AttentionBounce(active: session.state.isNeedsYou && effects.bounce && effects.motion,
                                  since: session.stateSince, edge: edge))
        .frame(width: size, height: size)
        .overlay(alignment: edge.alignment) {
            // The Dock's "running" dot: live sessions have one, paused ones don't.
            if session.isLive {
                Circle()
                    .fill(barForeground.opacity(0.7))
                    .frame(width: 4, height: 4)
                    .offset(x: -edge.away.width * dot, y: -edge.away.height * dot)
            }
        }
        .overlay(alignment: .topLeading) {
            // Hover an icon to get its ✕, like a notification you dismiss.
            if showClose {
                let diameter = max(15, size * 0.32)
                CloseButton(diameter: diameter, action: close)
                    .offset(x: -diameter * 0.3, y: -diameter * 0.3)
                    .transition(.scale(scale: 0.3).combined(with: .opacity))
            }
        }
        .overlay(alignment: edge.awayAlignment) {
            if showName {
                SessionCard(session: session, showDetails: effects.details)
                    .fixedSize()
                    .modifier(BubblePlacement(edge: edge))
                    .transition(.opacity.combined(with: .scale(scale: 0.92)))
                    .allowsHitTesting(false)
            }
        }
        .contentShape(tile(size))
        .accessibilityElement()
        .accessibilityLabel("\(session.name), \(strings.label(session.state))")
        .accessibilityAddTraits(.isButton)
    }

    @ViewBuilder
    private func badge(size: CGFloat) -> some View {
        let diameter = max(15, size * 0.36)
        Group {
            switch session.state {
            case .needsYou:
                BadgeDot(symbol: "exclamationmark", color: Palette.alert, diameter: diameter)
            case .done:
                BadgeDot(symbol: "checkmark", color: Palette.done, diameter: diameter)
            case .paused:
                BadgeDot(symbol: "moon.zzz.fill", color: Color(white: 0.42), diameter: diameter * 0.9)
            case .working where effects.style == .dots:
                TypingBubble(height: max(13, size * 0.3), animated: !offscreen && effects.working && effects.motion)
                    .offset(x: -size * 0.08)
            case .working, .rest:
                EmptyView()
            }
        }
        .offset(x: size * 0.4, y: -size * 0.4)
        .transition(.scale(scale: 0.1).combined(with: .opacity))
    }
}

/// The tile itself: gradient, top sheen, white symbol — the Big Sur icon recipe.
struct IconFace: View {
    let icon: AppIcon
    let size: CGFloat
    let state: SessionState
    @Environment(\.offscreen) private var offscreen
    @Environment(\.dockEffects) private var effects

    var body: some View {
        let shape = tile(size)
        let paused = state == .paused
        ZStack {
            shape.fill(LinearGradient(colors: [icon.top, icon.bottom], startPoint: .top, endPoint: .bottom))
            shape.fill(LinearGradient(colors: [.white.opacity(0.34), .white.opacity(0)],
                                      startPoint: .top, endPoint: UnitPoint(x: 0.5, y: 0.55)))
            Group {
                if let monogram = icon.monogram {
                    Text(monogram)
                        .font(.system(size: size * (monogram.count > 1 ? 0.38 : 0.48), weight: .bold, design: .rounded))
                        .minimumScaleFactor(0.5)
                        .lineLimit(1)
                        .padding(.horizontal, size * 0.08)
                } else {
                    Image(systemName: icon.symbol)
                        .symbolRenderingMode(.hierarchical)
                        .font(.system(size: size * 0.46, weight: .semibold))
                }
            }
            .foregroundStyle(.white)
            .shadow(color: .black.opacity(0.22), radius: size * 0.025, y: size * 0.02)
            if state == .working && !offscreen && effects.working && effects.motion {
                ShimmerEffect(iconSize: size).frame(width: size, height: size)
            }
            shape.strokeBorder(.white.opacity(0.22), lineWidth: 0.6)
        }
        .frame(width: size, height: size)
        .shadow(color: .black.opacity(0.32), radius: size * 0.06, y: size * 0.035)
        .saturation(paused ? 0.1 : 1)
        .opacity(paused ? 0.5 : 1)
    }
}

private struct GearButton: View {
    let size: CGFloat
    let action: () -> Void
    @Environment(\.strings) private var strings
    @Environment(\.barForeground) private var foreground

    var body: some View {
        Image(systemName: "gearshape.fill")
            .font(.system(size: size * 0.6, weight: .semibold))
            .foregroundStyle(foreground.opacity(0.75))
            .frame(width: size, height: size)
            .background(Circle().fill(foreground.opacity(0.1)))
            .overlay(Circle().strokeBorder(foreground.opacity(0.2), lineWidth: 0.5))
            .contentShape(Circle())
            .onTapGesture(perform: action)
            .accessibilityLabel(strings.settingsItem)
            .accessibilityAddTraits(.isButton)
    }
}

private struct CloseButton: View {
    let diameter: CGFloat
    let action: () -> Void

    @Environment(\.strings) private var strings

    var body: some View {
        Circle()
            .fill(Color(white: 0.22))
            .overlay(Circle().strokeBorder(.white.opacity(0.35), lineWidth: 0.7))
            .overlay(Image(systemName: "xmark")
                .font(.system(size: diameter * 0.45, weight: .bold))
                .foregroundStyle(.white.opacity(0.9)))
            .frame(width: diameter, height: diameter)
            .shadow(color: .black.opacity(0.4), radius: 2, y: 1)
            .contentShape(Circle())
            .onTapGesture(perform: action)
            .accessibilityLabel(strings.removeFromBar)
            .accessibilityAddTraits(.isButton)
    }
}

struct BadgeDot: View {
    let symbol: String
    let color: Color
    let diameter: CGFloat

    var body: some View {
        Circle()
            .fill(color)
            .overlay(Image(systemName: symbol)
                .font(.system(size: diameter * 0.5, weight: .heavy))
                .foregroundStyle(.white))
            .frame(width: diameter, height: diameter)
            .shadow(color: .black.opacity(0.35), radius: 1.5, y: 1)
    }
}

// MARK: - State effects

/// What surrounds the tile: the working animation chosen in Settings, a red pulse while
/// it waits for you, a green ring (drawn with a burst of sparks) once it is done.
struct StateEffect: View {
    let state: SessionState
    let size: CGFloat
    let since: Double
    @Environment(\.offscreen) private var offscreen
    @Environment(\.dockEffects) private var effects

    /// Room around the ring for its glow.
    private static let bleed: CGFloat = 24

    var body: some View {
        switch state {
        case .working:
            if effects.style == .dots {
                // The dots sit in the tile's corner: see IconView's badge.
                EmptyView()
            } else if offscreen || !effects.working || !effects.motion {
                StaticWorking(style: effects.style, size: size)
            } else {
                // A new layer tree when the style changes.
                ring(.working(effects.style)).id(effects.style)
            }
        case .needsYou:
            if offscreen || !effects.motion { StaticRing(size: size, style: Palette.alert) }
            else { ring(.alert) }
        case .done:
            DoneRing(size: size, since: since, celebrate: effects.celebration && effects.motion)
        case .rest, .paused:
            EmptyView()
        }
    }

    private func ring(_ style: RingEffectView.Style) -> some View {
        RingEffect(style: style, iconSize: size)
            .frame(width: size + ringOutset * 2 + Self.bleed * 2, height: size + ringOutset * 2 + Self.bleed * 2)
    }
}

/// Snapshot stand-ins for each working style: one frozen frame of it.
private struct StaticWorking: View {
    let style: WorkingStyle
    let size: CGFloat

    var body: some View {
        let ring = tile(size, grow: ringOutset)
        let aurora = AngularGradient(colors: Palette.aurora, center: .center)
        let violet = Color(hex: Palette.violetHex)
        Group {
            switch style {
            case .aurora, .dots:
                StaticRing(size: size, style: aurora)
            case .glow:
                ring.stroke(aurora, lineWidth: 6).blur(radius: 4).opacity(0.85)
            case .orbit:
                ZStack {
                    ring.stroke(violet.opacity(0.35), lineWidth: 1.5)
                    Circle().fill(.white).frame(width: 5.5, height: 5.5)
                        .shadow(color: .white, radius: 3)
                        .offset(x: size * 0.36, y: -(size / 2 + ringOutset))
                }
            case .trace:
                ZStack {
                    ring.trim(from: 0.05, to: 0.55).stroke(aurora, style: StrokeStyle(lineWidth: 6, lineCap: .round))
                        .blur(radius: 5).opacity(0.6)
                    ring.trim(from: 0.05, to: 0.55).stroke(aurora, style: StrokeStyle(lineWidth: 3, lineCap: .round))
                }
            case .sonar:
                ZStack {
                    ring.stroke(violet.opacity(0.8), lineWidth: 1.5)
                    ring.stroke(Color(hex: 0xFF6778).opacity(0.45), lineWidth: 2).scaleEffect(1.1)
                    ring.stroke(Color(hex: 0x8D9FFF).opacity(0.2), lineWidth: 2).scaleEffect(1.18)
                }
            }
        }
        .frame(width: size + ringOutset * 2, height: size + ringOutset * 2)
    }
}

/// The "typing" bubble of the dots style: live, or frozen for snapshots.
private struct TypingBubble: View {
    let height: CGFloat
    let animated: Bool

    var body: some View {
        if animated {
            TypingDots(height: height).frame(width: height * 1.9 + 8, height: height + 8)
        } else {
            let diameter = height * 0.28
            Capsule()
                .fill(.white)
                .overlay(HStack(spacing: diameter * 0.6) {
                    ForEach([0.4, 1, 0.6], id: \.self) { opacity in
                        Circle().fill(Color(hex: 0x8E5CF7).opacity(opacity)).frame(width: diameter, height: diameter)
                    }
                })
                .frame(width: height * 1.9, height: height)
                .shadow(color: .black.opacity(0.3), radius: 2)
        }
    }
}

/// Snapshot stand-in for the animated rings: the same ring and glow, frozen.
private struct StaticRing<Style: ShapeStyle>: View {
    let size: CGFloat
    let style: Style

    var body: some View {
        let ring = tile(size, grow: ringOutset)
        ZStack {
            ring.stroke(style, lineWidth: 10).blur(radius: 9).opacity(0.6)
            ring.stroke(style, lineWidth: 2.5)
        }
        .frame(width: size + ringOutset * 2, height: size + ringOutset * 2)
    }
}

private struct DoneRing: View {
    let size: CGFloat
    /// When the turn ended (ms since epoch).
    let since: Double

    private static let celebration: Double = 1.8
    @State private var celebrating: Bool

    private let celebrate: Bool

    init(size: CGFloat, since: Double, celebrate: Bool) {
        self.size = size
        self.since = since
        self.celebrate = celebrate
        _celebrating = State(initialValue: celebrate && Date().timeIntervalSince1970 - since / 1_000 < Self.celebration)
    }

    var body: some View {
        let ring = tile(size, grow: 4)
        let side = size + 8
        Group {
            if celebrating {
                TimelineView(.animation(minimumInterval: 1 / 60)) { context in
                    let elapsed = context.date.timeIntervalSince1970 - since / 1_000
                    let drawn = 1 - pow(1 - min(1, max(0, elapsed / 0.5)), 3)
                    ZStack {
                        ring.stroke(Palette.done, lineWidth: 9).blur(radius: 9).opacity(0.55 * drawn)
                            .frame(width: side, height: side)
                        ring.trim(from: 0, to: drawn)
                            .stroke(Palette.done, style: StrokeStyle(lineWidth: 2.5, lineCap: .round))
                            .frame(width: side, height: side)
                        SparkBurst(size: size, progress: (elapsed - 0.15) / 1.2)
                    }
                }
            } else {
                ZStack {
                    ring.stroke(Palette.done, lineWidth: 8).blur(radius: 8).opacity(0.3)
                    ring.stroke(Palette.done, lineWidth: 2.5)
                }
            }
        }
        .frame(width: side, height: side)
        .task(id: since) {
            let left = Self.celebration - (Date().timeIntervalSince1970 - since / 1_000)
            guard celebrate, left > 0 else {
                celebrating = false
                return
            }
            celebrating = true
            try? await Task.sleep(for: .seconds(left))
            celebrating = false
        }
    }
}

/// Twelve sparks flying out of the tile when a turn ends.
struct SparkBurst: View {
    let size: CGFloat
    let progress: Double

    var body: some View {
        Canvas { context, canvas in
            guard progress > 0, progress < 1 else { return }
            let center = CGPoint(x: canvas.width / 2, y: canvas.height / 2)
            let eased = 1 - pow(1 - progress, 2)
            let colors = [Palette.done, .white, Color(hex: 0xFFE066)]
            context.opacity = 1 - progress
            for i in 0..<12 {
                let angle = Double(i) / 12 * 2 * .pi + 0.26
                let reach = i.isMultiple(of: 2) ? 1.0 : 0.7
                let distance = size * 0.55 + eased * size * 0.5 * reach
                let radius = (i.isMultiple(of: 2) ? 2.6 : 1.8) * (1 - progress * 0.6)
                let point = CGPoint(x: center.x + cos(angle) * distance, y: center.y + sin(angle) * distance)
                context.fill(Path(ellipseIn: CGRect(x: point.x - radius, y: point.y - radius,
                                                    width: radius * 2, height: radius * 2)),
                             with: .color(colors[i % 3]))
            }
        }
        .frame(width: size * 2.4, height: size * 2.4)
        .allowsHitTesting(false)
    }
}

/// The Dock's own "this app needs you" gesture: three bounces when Claude starts
/// waiting, then three more every 20 seconds until you answer. Always away from the edge.
private struct AttentionBounce: ViewModifier {
    let active: Bool
    /// When the session started waiting (ms since epoch).
    let since: Double
    let edge: DockEdge

    @State private var trigger = 0

    func body(content: Content) -> some View {
        content
            .keyframeAnimator(initialValue: CGFloat(0), trigger: trigger) { view, lift in
                view.offset(x: edge.away.width * lift, y: edge.away.height * lift)
            } keyframes: { _ in
                KeyframeTrack {
                    CubicKeyframe(11, duration: 0.28)
                    CubicKeyframe(0, duration: 0.28)
                    CubicKeyframe(8, duration: 0.25)
                    CubicKeyframe(0, duration: 0.25)
                    CubicKeyframe(4, duration: 0.2)
                    CubicKeyframe(0, duration: 0.2)
                }
            }
            .task(id: active ? since : -1) {
                guard active else { return }
                if Date().timeIntervalSince1970 - since / 1_000 < 3 { trigger += 1 }
                while !Task.isCancelled {
                    try? await Task.sleep(for: .seconds(20))
                    if Task.isCancelled { break }
                    trigger += 1
                }
            }
    }
}

// MARK: - Bubble, divider, empty state

/// Puts the name bubble just beyond the icon, on the side facing away from the edge.
struct BubblePlacement: ViewModifier {
    let edge: DockEdge
    private let gap: CGFloat = 14

    // A zero-size frame pinned to the icon's far side, with the bubble overflowing outward.
    func body(content: Content) -> some View {
        switch edge {
        case .bottom: content.frame(height: 0, alignment: .bottom).offset(y: -gap)
        case .top: content.frame(height: 0, alignment: .top).offset(y: gap)
        case .left: content.frame(width: 0, alignment: .leading).offset(x: gap)
        case .right: content.frame(width: 0, alignment: .trailing).offset(x: -gap)
        }
    }
}

/// Soft edges on the compact row, on the sides that have more icons to scroll to.
private struct EdgeFade: View {
    let width: CGFloat
    let fadeLeading: Bool
    let fadeTrailing: Bool

    var body: some View {
        HStack(spacing: 0) {
            LinearGradient(colors: [fadeLeading ? .clear : .black, .black], startPoint: .leading, endPoint: .trailing)
                .frame(width: 18)
            Rectangle()
            LinearGradient(colors: [.black, fadeTrailing ? .clear : .black], startPoint: .leading, endPoint: .trailing)
                .frame(width: 18)
        }
        // A little wider than the row so the rings' glow survives; tall enough for the ✕.
        .frame(width: width + 12, height: 2_000)
    }
}

/// A tiny scroll bar under the compact row: how much is shown, and where.
private struct ScrollIndicator: View {
    let fraction: CGFloat
    let position: CGFloat
    private let track: CGFloat = 34

    var body: some View {
        let thumb = max(8, track * fraction)
        Capsule()
            .fill(.white.opacity(0.18))
            .frame(width: track, height: 3)
            .overlay(alignment: .leading) {
                Capsule()
                    .fill(.white.opacity(0.75))
                    .frame(width: thumb, height: 3)
                    .offset(x: (track - thumb) * min(max(position, 0), 1))
            }
            .allowsHitTesting(false)
    }
}

private struct DockDivider: View {
    let edge: DockEdge
    let metrics: DockMetrics
    @Environment(\.barForeground) private var foreground

    var body: some View {
        let long = metrics.item * 0.7
        Capsule()
            .fill(foreground.opacity(0.3))
            .frame(width: edge.isHorizontal ? metrics.dividerThickness : long,
                   height: edge.isHorizontal ? long : metrics.dividerThickness)
            .padding(edge.swiftUIEdge, (metrics.item - long) / 2)
    }
}

private struct EmptyIcon: View {
    let edge: DockEdge
    let metrics: DockMetrics
    let showLabel: Bool
    @Environment(\.strings) private var strings
    @Environment(\.barForeground) private var foreground

    var body: some View {
        tile(metrics.item)
            .strokeBorder(foreground.opacity(0.35), style: StrokeStyle(lineWidth: 1.5, dash: [3, 4]))
            .frame(width: metrics.item, height: metrics.item)
            .overlay(alignment: edge.awayAlignment) {
                if showLabel {
                    Text(strings.noSessions)
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(.primary)
                        .padding(.horizontal, 11)
                        .padding(.vertical, 6)
                        .background(GlassBackground(cornerRadius: 9, solid: true))
                        .fixedSize()
                        .modifier(BubblePlacement(edge: edge))
                        .allowsHitTesting(false)
                }
            }
    }
}

// MARK: - Backgrounds

/// The notch, grown downward: square top flush with the screen edge, little outward
/// "ears" where it meets the menu bar (like the notch's own corners), rounded bottom.
struct NotchIsland: Shape {
    static let ear: CGFloat = 10
    private let radius: CGFloat = 22

    func path(in rect: CGRect) -> Path {
        let e = Self.ear
        var path = Path()
        path.move(to: CGPoint(x: rect.minX, y: rect.minY))
        path.addQuadCurve(to: CGPoint(x: rect.minX + e, y: rect.minY + e),
                          control: CGPoint(x: rect.minX + e, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.minX + e, y: rect.maxY - radius))
        path.addQuadCurve(to: CGPoint(x: rect.minX + e + radius, y: rect.maxY),
                          control: CGPoint(x: rect.minX + e, y: rect.maxY))
        path.addLine(to: CGPoint(x: rect.maxX - e - radius, y: rect.maxY))
        path.addQuadCurve(to: CGPoint(x: rect.maxX - e, y: rect.maxY - radius),
                          control: CGPoint(x: rect.maxX - e, y: rect.maxY))
        path.addLine(to: CGPoint(x: rect.maxX - e, y: rect.minY + e))
        path.addQuadCurve(to: CGPoint(x: rect.maxX, y: rect.minY),
                          control: CGPoint(x: rect.maxX - e, y: rect.minY))
        path.closeSubpath()
        return path
    }
}

/// Frosted glass that blurs whatever sits behind the window, like the Dock. It follows the
/// Mac's light or dark mode, and the text on it uses the matching colors (`.primary`…).
/// `solid` (cards, notes) is more opaque, so text stays readable over busy windows.
struct GlassBackground: View {
    let cornerRadius: CGFloat
    var solid = false
    @Environment(\.offscreen) private var offscreen
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        Group {
            if offscreen {
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .fill(colorScheme == .dark ? Color(white: 0.16).opacity(0.92) : Color(white: 0.93).opacity(0.96))
            } else {
                VisualEffect(cornerRadius: cornerRadius, material: solid ? .popover : .hudWindow)
            }
        }
        .overlay(
            RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.14), lineWidth: 0.5)
        )
    }
}

private struct VisualEffect: NSViewRepresentable {
    let cornerRadius: CGFloat
    let material: NSVisualEffectView.Material

    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = material
        view.blendingMode = .behindWindow
        view.state = .active
        view.wantsLayer = true
        view.layer?.cornerRadius = cornerRadius
        view.layer?.cornerCurve = .continuous
        view.layer?.masksToBounds = true
        return view
    }

    func updateNSView(_ view: NSVisualEffectView, context: Context) {}
}

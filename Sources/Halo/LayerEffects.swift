import AppKit
import CoreImage
import QuartzCore
import SwiftUI

// The effects that run for as long as a state lasts (working, alert pulse, shimmer) are
// Core Animation layers: the system's render server animates them, like the real
// Dock, so Halo itself does almost no work between state changes.

/// How a session at work shows it (Settings → Animations).
enum WorkingStyle: String, CaseIterable, Identifiable, Sendable {
    /// A rainbow ring that spins, with a comet.
    case aurora
    /// A soft colored glow all around, no ring.
    case glow
    /// A comet circling the tile, nothing else.
    case orbit
    /// A stroke that draws itself around the tile, then fades.
    case trace
    /// Colored waves leaving the tile.
    case sonar
    /// Three dots in the corner, like someone typing.
    case dots

    var id: String { rawValue }
}

extension Palette {
    static func cgColor(_ hex: UInt32, alpha: CGFloat = 1) -> CGColor {
        CGColor(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255,
                blue: CGFloat(hex & 0xFF) / 255, alpha: alpha)
    }

    static let auroraHex: [UInt32] = [0xBC82F3, 0xF5B9EA, 0x8D9FFF, 0xAA6EEE, 0xFF6778, 0xFFBA71, 0xC686FF, 0xBC82F3]
    static let alertHex: UInt32 = 0xFF453A
    static let violetHex: UInt32 = 0xAA6EEE
}

private func repeating(_ keyPath: String, from: Any, to: Any, duration: CFTimeInterval,
                       autoreverses: Bool = false) -> CABasicAnimation {
    let animation = CABasicAnimation(keyPath: keyPath)
    animation.fromValue = from
    animation.toValue = to
    animation.duration = duration
    animation.autoreverses = autoreverses
    animation.repeatCount = .infinity
    animation.timingFunction = CAMediaTimingFunction(name: autoreverses ? .easeInEaseOut : .linear)
    return animation
}

/// The ring hugs the tile with this much room on each side. `DockMetrics.spacing` keeps
/// two neighbours' rings apart.
let ringOutset: CGFloat = 4

private func ringPath(iconSize: CGFloat, in bounds: CGRect) -> CGPath {
    let side = iconSize + ringOutset * 2
    let rect = CGRect(x: bounds.midX - side / 2, y: bounds.midY - side / 2, width: side, height: side)
    return RoundedRectangle(cornerRadius: iconSize * 0.2237 + ringOutset, style: .continuous).path(in: rect).cgPath
}

/// What surrounds a tile while its session works (one of `WorkingStyle`), or waits for you.
final class RingEffectView: NSView {
    enum Style: Equatable {
        case working(WorkingStyle)
        case alert
    }

    var iconSize: CGFloat = DockMetrics.standardItem {
        didSet { if iconSize != oldValue { needsLayout = true } }
    }

    /// Casts the colored glow: the shadow of everything inside it.
    private let glow = CALayer()
    /// The ring: a gradient seen through a stroke-shaped mask.
    private let holder = CALayer()
    private let fill = CAGradientLayer()
    private let mask = CAShapeLayer()
    private var track: CAShapeLayer?
    private var ripples: [CAShapeLayer] = []
    private var rippleDuration: CFTimeInterval = 1.4
    /// Sparks orbiting the tile, each a little behind the previous one: a comet and its tail.
    private var comet: [CALayer] = []
    private var cometPeriod: CFTimeInterval = 1.8
    private var cometLag: CFTimeInterval = 0.045
    private var orbitSize: CGFloat = 0
    /// Geometry last applied: SwiftUI lays the view out often, the layers rarely need it.
    private var laidOut: (bounds: CGRect, iconSize: CGFloat)?

    init(style: Style) {
        super.init(frame: .zero)
        wantsLayer = true
        layerUsesCoreImageFilters = true
        let root = CALayer()
        layer = root
        root.addSublayer(glow)
        glow.shadowOffset = .zero
        glow.shadowOpacity = 1
        mask.fillColor = nil
        mask.strokeColor = NSColor.black.cgColor
        mask.lineWidth = 2.5

        switch style {
        case .alert: setUpAlert(root)
        case .working(.aurora): setUpAurora(root)
        case .working(.glow): setUpGlow()
        case .working(.orbit): setUpOrbit(root)
        case .working(.trace): setUpTrace()
        case .working(.sonar): setUpSonar(root)
        case .working(.dots): break
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    // MARK: Styles

    private func setUpAurora(_ root: CALayer) {
        addRing()
        spinAurora(seconds: 2.6)
        glow.add(hueCycle(seconds: 4.5), forKey: "hue")
        glow.add(repeating("shadowRadius", from: 3, to: 7, duration: 1.4, autoreverses: true), forKey: "breathe")
        addComet(to: root, sparks: [(5, 1, 0xFFFFFF), (4, 0.6, 0xFFFFFF), (3.2, 0.4, 0xFFFFFF), (2.4, 0.22, 0xFFFFFF)])
    }

    /// Apple Intelligence's glow: the aurora ring, wide and blurred, turning slowly.
    private func setUpGlow() {
        addRing()
        spinAurora(seconds: 5)
        mask.lineWidth = 6
        // Blur the whole ring (the container), not the masked layer, or the mask would cut the blur.
        if let blur = CIFilter(name: "CIGaussianBlur", parameters: [kCIInputRadiusKey: 4]) { glow.filters = [blur] }
        glow.shadowOpacity = 0
        holder.add(repeating("opacity", from: 0.55, to: 1, duration: 1.3, autoreverses: true), forKey: "breathe")
    }

    private func setUpOrbit(_ root: CALayer) {
        let track = CAShapeLayer()
        track.fillColor = nil
        track.strokeColor = Palette.cgColor(Palette.violetHex, alpha: 0.35)
        track.lineWidth = 1.5
        root.addSublayer(track)
        self.track = track
        cometPeriod = 1.5
        cometLag = 0.05
        addComet(to: root, sparks: [(5.5, 1, 0xFFFFFF), (4.8, 0.9, 0xF5B9EA), (4.1, 0.75, 0xBC82F3),
                                    (3.5, 0.6, 0xAA6EEE), (2.9, 0.45, 0x8D9FFF), (2.3, 0.3, 0x8D9FFF),
                                    (1.8, 0.16, 0x8D9FFF)])
    }

    /// A stroke draws itself around the tile, then is wiped from its start: a lap, again and again.
    private func setUpTrace() {
        addRing()
        spinAurora(seconds: 5)
        mask.lineWidth = 3
        mask.lineCap = .round
        glow.shadowRadius = 5
        glow.add(hueCycle(seconds: 4.5), forKey: "hue")
        let draw = CABasicAnimation(keyPath: "strokeEnd")
        draw.fromValue = 0
        draw.toValue = 1
        draw.duration = 1.1
        draw.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        // Stays drawn while the wipe catches up.
        draw.fillMode = .forwards
        let wipe = CABasicAnimation(keyPath: "strokeStart")
        wipe.fromValue = 0
        wipe.toValue = 1
        wipe.beginTime = 0.6
        wipe.duration = 1.1
        wipe.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        let lap = CAAnimationGroup()
        lap.animations = [draw, wipe]
        lap.duration = 1.9
        lap.repeatCount = .infinity
        mask.strokeEnd = 0
        mask.add(lap, forKey: "lap")
    }

    private func setUpSonar(_ root: CALayer) {
        addRing()
        fill.colors = [Palette.cgColor(0xBC82F3), Palette.cgColor(0x8D9FFF)]
        mask.lineWidth = 1.5
        holder.opacity = 0.8
        glow.shadowColor = Palette.cgColor(Palette.violetHex)
        glow.shadowRadius = 4
        addRipples(to: root, colors: [0xBC82F3, 0xFF6778, 0x8D9FFF], scale: 1.2, duration: 2.1)
    }

    private func setUpAlert(_ root: CALayer) {
        addRing()
        let red = Palette.cgColor(Palette.alertHex)
        fill.colors = [red, red]
        glow.shadowColor = red
        glow.shadowRadius = 6
        glow.add(repeating("shadowOpacity", from: 1, to: 0.3, duration: 0.7, autoreverses: true), forKey: "pulse")
        // A wave leaving the tile, every 1.4 s.
        addRipples(to: root, colors: [Palette.alertHex], scale: 1.2, duration: 1.4)
    }

    // MARK: Pieces

    private func addRing() {
        glow.addSublayer(holder)
        holder.addSublayer(fill)
        holder.mask = mask
    }

    private func spinAurora(seconds: CFTimeInterval) {
        fill.type = .conic
        fill.colors = Palette.auroraHex.map { Palette.cgColor($0) }
        fill.startPoint = CGPoint(x: 0.5, y: 0.5)
        fill.endPoint = CGPoint(x: 0.5, y: 0)
        fill.add(repeating("transform.rotation.z", from: 0, to: -2 * Double.pi, duration: seconds), forKey: "spin")
    }

    private func hueCycle(seconds: CFTimeInterval) -> CAKeyframeAnimation {
        let hue = CAKeyframeAnimation(keyPath: "shadowColor")
        hue.values = Palette.auroraHex.map { Palette.cgColor($0) }
        hue.duration = seconds
        hue.repeatCount = .infinity
        return hue
    }

    private func addComet(to root: CALayer, sparks: [(radius: CGFloat, opacity: Float, color: UInt32)]) {
        for spark in sparks {
            let layer = CALayer()
            layer.bounds = CGRect(x: 0, y: 0, width: spark.radius, height: spark.radius)
            layer.cornerRadius = spark.radius / 2
            layer.backgroundColor = Palette.cgColor(spark.color)
            layer.opacity = spark.opacity
            layer.shadowColor = Palette.cgColor(spark.color == 0xFFFFFF ? 0xFFFFFF : spark.color)
            layer.shadowRadius = 4
            layer.shadowOpacity = 0.9
            layer.shadowOffset = .zero
            layer.shadowPath = CGPath(ellipseIn: layer.bounds, transform: nil)
            root.addSublayer(layer)
            comet.append(layer)
        }
    }

    private func addRipples(to root: CALayer, colors: [UInt32], scale: CGFloat, duration: CFTimeInterval) {
        rippleDuration = duration
        for (index, hex) in colors.enumerated() {
            let ripple = CAShapeLayer()
            ripple.fillColor = nil
            ripple.strokeColor = Palette.cgColor(hex)
            ripple.lineWidth = 2
            ripple.opacity = 0
            root.addSublayer(ripple)
            let grow = CABasicAnimation(keyPath: "transform.scale")
            grow.fromValue = 1
            grow.toValue = scale
            let fade = CABasicAnimation(keyPath: "opacity")
            fade.fromValue = 0.8
            fade.toValue = 0
            let wave = CAAnimationGroup()
            wave.animations = [grow, fade]
            wave.duration = duration
            wave.timingFunction = CAMediaTimingFunction(name: .easeOut)
            wave.repeatCount = .infinity
            // Spread evenly: one wave leaves while the previous is halfway out.
            wave.timeOffset = duration * Double(index) / Double(colors.count)
            ripple.add(wave, forKey: "wave")
            ripples.append(ripple)
        }
    }

    // MARK: Layout

    override func layout() {
        super.layout()
        let bounds = self.bounds
        if let laidOut, laidOut.bounds == bounds, laidOut.iconSize == iconSize { return }
        laidOut = (bounds, iconSize)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for layer in [glow, holder, mask] + ripples + [track].compactMap({ $0 }) as [CALayer] { layer.frame = bounds }
        // The conic fill spins: make it cover the corners at any angle.
        let diagonal = hypot(bounds.width, bounds.height)
        fill.bounds = CGRect(x: 0, y: 0, width: diagonal, height: diagonal)
        fill.position = CGPoint(x: bounds.midX, y: bounds.midY)
        let path = ringPath(iconSize: iconSize, in: bounds)
        mask.path = path
        track?.path = path
        for ripple in ripples { ripple.path = path }
        CATransaction.commit()

        // The orbit follows the ring, so it is rebuilt when the icon changes size.
        guard !comet.isEmpty, iconSize != orbitSize else { return }
        orbitSize = iconSize
        for (index, spark) in comet.enumerated() {
            let orbit = CAKeyframeAnimation(keyPath: "position")
            orbit.path = path
            orbit.calculationMode = .paced
            orbit.duration = cometPeriod
            orbit.repeatCount = .infinity
            orbit.timeOffset = cometPeriod - Double(index) * cometLag
            spark.add(orbit, forKey: "orbit")
        }
    }

    // Purely decorative: clicks go through to the icon.
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

/// While Claude thinks, the tile breathes (a soft light swelling and fading) and a band
/// of light sweeps across it.
final class ShimmerView: NSView {
    var iconSize: CGFloat = DockMetrics.standardItem {
        didSet { if iconSize != oldValue { needsLayout = true } }
    }

    private let clip = CAShapeLayer()
    private let breath = CALayer()
    private let tilt = CALayer()
    private let band = CAGradientLayer()
    private var sweptSize: CGFloat = 0
    private var laidOut: (bounds: CGRect, iconSize: CGFloat)?

    init() {
        super.init(frame: .zero)
        wantsLayer = true
        let root = CALayer()
        layer = root
        root.mask = clip
        root.addSublayer(breath)
        breath.backgroundColor = NSColor.white.cgColor
        breath.opacity = 0
        breath.add(repeating("opacity", from: 0, to: 0.16, duration: 1.1, autoreverses: true), forKey: "breathe")
        root.addSublayer(tilt)
        tilt.addSublayer(band)
        tilt.setAffineTransform(CGAffineTransform(rotationAngle: 22 * .pi / 180))
        band.colors = [NSColor.white.withAlphaComponent(0).cgColor,
                       NSColor.white.withAlphaComponent(0.3).cgColor,
                       NSColor.white.withAlphaComponent(0).cgColor]
        band.startPoint = CGPoint(x: 0, y: 0.5)
        band.endPoint = CGPoint(x: 1, y: 0.5)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override func layout() {
        super.layout()
        let bounds = self.bounds
        if let laidOut, laidOut.bounds == bounds, laidOut.iconSize == iconSize { return }
        laidOut = (bounds, iconSize)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        clip.frame = bounds
        breath.frame = bounds
        clip.path = RoundedRectangle(cornerRadius: iconSize * 0.2237, style: .continuous)
            .path(in: CGRect(x: bounds.midX - iconSize / 2, y: bounds.midY - iconSize / 2,
                             width: iconSize, height: iconSize)).cgPath
        tilt.bounds = bounds
        tilt.position = CGPoint(x: bounds.midX, y: bounds.midY)
        band.bounds = CGRect(x: 0, y: 0, width: iconSize * 0.45, height: iconSize * 1.8)
        band.position = CGPoint(x: bounds.midX, y: bounds.midY)
        CATransaction.commit()

        guard iconSize != sweptSize else { return }
        sweptSize = iconSize
        // Sweep across in 1.2 s, rest 1.2 s.
        let sweep = CAKeyframeAnimation(keyPath: "position.x")
        sweep.values = [bounds.midX - iconSize * 1.2, bounds.midX + iconSize * 1.2, bounds.midX + iconSize * 1.2]
        sweep.keyTimes = [0, 0.5, 1]
        sweep.duration = 2.4
        sweep.repeatCount = .infinity
        band.add(sweep, forKey: "sweep")
    }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

/// The "someone is typing" bubble: three dots lighting up in turn, in the tile's corner.
final class TypingDotsView: NSView {
    var height: CGFloat = 14 {
        didSet { if height != oldValue { needsLayout = true } }
    }

    private let bubble = CALayer()
    private let row = CAReplicatorLayer()
    private let dot = CALayer()

    init() {
        super.init(frame: .zero)
        wantsLayer = true
        let root = CALayer()
        layer = root
        root.addSublayer(bubble)
        bubble.backgroundColor = NSColor.white.cgColor
        bubble.borderColor = NSColor.black.withAlphaComponent(0.08).cgColor
        bubble.borderWidth = 0.5
        bubble.shadowColor = NSColor.black.cgColor
        bubble.shadowOpacity = 0.3
        bubble.shadowRadius = 2
        bubble.shadowOffset = .zero
        bubble.addSublayer(row)
        row.addSublayer(dot)
        row.instanceCount = 3
        row.instanceDelay = 0.16
        dot.backgroundColor = Palette.cgColor(0x8E5CF7)

        let light = CAKeyframeAnimation(keyPath: "opacity")
        light.values = [0.3, 1, 0.3, 0.3]
        let swell = CAKeyframeAnimation(keyPath: "transform.scale")
        swell.values = [0.8, 1.2, 0.8, 0.8]
        let beat = CAAnimationGroup()
        beat.animations = [light, swell]
        for animation in [light, swell] { animation.keyTimes = [0, 0.22, 0.44, 1] }
        beat.duration = 1.1
        beat.repeatCount = .infinity
        dot.add(beat, forKey: "beat")
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        let width = height * 1.9
        bubble.frame = CGRect(x: bounds.midX - width / 2, y: bounds.midY - height / 2, width: width, height: height)
        bubble.cornerRadius = height / 2
        bubble.shadowPath = CGPath(roundedRect: bubble.bounds, cornerWidth: height / 2, cornerHeight: height / 2,
                                   transform: nil)
        row.frame = bubble.bounds
        let diameter = height * 0.28
        let step = diameter * 1.6
        row.instanceTransform = CATransform3DMakeTranslation(step, 0, 0)
        dot.frame = CGRect(x: (width - 2 * step - diameter) / 2, y: (height - diameter) / 2,
                           width: diameter, height: diameter)
        dot.cornerRadius = diameter / 2
        CATransaction.commit()
    }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

// MARK: - SwiftUI wrappers

struct RingEffect: NSViewRepresentable {
    let style: RingEffectView.Style
    let iconSize: CGFloat

    func makeNSView(context: Context) -> RingEffectView { RingEffectView(style: style) }

    func updateNSView(_ view: RingEffectView, context: Context) {
        view.iconSize = iconSize
    }
}

struct ShimmerEffect: NSViewRepresentable {
    let iconSize: CGFloat

    func makeNSView(context: Context) -> ShimmerView { ShimmerView() }

    func updateNSView(_ view: ShimmerView, context: Context) {
        view.iconSize = iconSize
    }
}

struct TypingDots: NSViewRepresentable {
    let height: CGFloat

    func makeNSView(context: Context) -> TypingDotsView { TypingDotsView() }

    func updateNSView(_ view: TypingDotsView, context: Context) {
        view.height = height
    }
}

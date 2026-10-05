import AppKit
import QuartzCore
import SwiftUI

// The effects that run for as long as a state lasts (aurora, alert pulse, shimmer) are
// Core Animation layers: the system's render server animates them, like the real
// Dock, so Halo itself does almost no work between state changes.

extension Palette {
    static func cgColor(_ hex: UInt32, alpha: CGFloat = 1) -> CGColor {
        CGColor(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255,
                blue: CGFloat(hex & 0xFF) / 255, alpha: alpha)
    }

    static let auroraHex: [UInt32] = [0xBC82F3, 0xF5B9EA, 0x8D9FFF, 0xAA6EEE, 0xFF6778, 0xFFBA71, 0xC686FF, 0xBC82F3]
    static let alertHex: UInt32 = 0xFF453A
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

private func ringPath(iconSize: CGFloat, in bounds: CGRect) -> CGPath {
    let side = iconSize + 8
    let rect = CGRect(x: bounds.midX - side / 2, y: bounds.midY - side / 2, width: side, height: side)
    return RoundedRectangle(cornerRadius: iconSize * 0.2237 + 4, style: .continuous).path(in: rect).cgPath
}

/// A ring around the tile, with a glow: rotating aurora colors, or a pulsing red alert.
final class RingEffectView: NSView {
    enum Style { case aurora, alert }

    var iconSize: CGFloat = DockMetrics.standardItem {
        didSet { if iconSize != oldValue { needsLayout = true } }
    }

    private let glow = CALayer()
    private let holder = CALayer()
    private let fill = CAGradientLayer()
    private let mask = CAShapeLayer()
    private let ripple = CAShapeLayer()
    /// A little comet with its tail, orbiting the tile while Claude works.
    private var comet: [CALayer] = []
    private var orbitSize: CGFloat = 0
    /// Geometry last applied: SwiftUI lays the view out often, the layers rarely need it.
    private var laidOut: (bounds: CGRect, iconSize: CGFloat)?

    init(style: Style) {
        super.init(frame: .zero)
        wantsLayer = true
        let root = CALayer()
        layer = root

        // The glow is the shadow of the ring, cast by its container.
        root.addSublayer(glow)
        glow.addSublayer(holder)
        holder.addSublayer(fill)
        holder.mask = mask
        mask.fillColor = nil
        mask.strokeColor = NSColor.black.cgColor
        mask.lineWidth = 2.5
        glow.shadowOffset = .zero
        glow.shadowOpacity = 1

        switch style {
        case .aurora:
            fill.type = .conic
            fill.colors = Palette.auroraHex.map { Palette.cgColor($0) }
            fill.startPoint = CGPoint(x: 0.5, y: 0.5)
            fill.endPoint = CGPoint(x: 0.5, y: 0)
            fill.add(repeating("transform.rotation.z", from: 0, to: -2 * Double.pi, duration: 2.6), forKey: "spin")
            let hue = CAKeyframeAnimation(keyPath: "shadowColor")
            hue.values = Palette.auroraHex.map { Palette.cgColor($0) }
            hue.duration = 4.5
            hue.repeatCount = .infinity
            glow.add(hue, forKey: "hue")
            glow.add(repeating("shadowRadius", from: 5, to: 11, duration: 1.4, autoreverses: true), forKey: "breathe")
            for (radius, opacity) in [(5.0, 1.0), (4.0, 0.6), (3.2, 0.4), (2.4, 0.22)] as [(CGFloat, Float)] {
                let spark = CALayer()
                spark.bounds = CGRect(x: 0, y: 0, width: radius, height: radius)
                spark.cornerRadius = radius / 2
                spark.backgroundColor = NSColor.white.cgColor
                spark.opacity = opacity
                spark.shadowColor = NSColor.white.cgColor
                spark.shadowRadius = 4
                spark.shadowOpacity = 0.9
                spark.shadowOffset = .zero
                spark.shadowPath = CGPath(ellipseIn: spark.bounds, transform: nil)
                root.addSublayer(spark)
                comet.append(spark)
            }
        case .alert:
            let red = Palette.cgColor(Palette.alertHex)
            fill.colors = [red, red]
            glow.shadowColor = red
            glow.shadowRadius = 8
            glow.add(repeating("shadowOpacity", from: 1, to: 0.3, duration: 0.7, autoreverses: true), forKey: "pulse")
            // A wave leaving the tile, every 1.4 s.
            ripple.fillColor = nil
            ripple.strokeColor = red
            ripple.lineWidth = 2
            ripple.opacity = 0
            root.addSublayer(ripple)
            let grow = CABasicAnimation(keyPath: "transform.scale")
            grow.fromValue = 1
            grow.toValue = 1.3
            let fade = CABasicAnimation(keyPath: "opacity")
            fade.fromValue = 0.8
            fade.toValue = 0
            let wave = CAAnimationGroup()
            wave.animations = [grow, fade]
            wave.duration = 1.4
            wave.timingFunction = CAMediaTimingFunction(name: .easeOut)
            wave.repeatCount = .infinity
            ripple.add(wave, forKey: "wave")
        }
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
        for layer in [glow, holder, mask, ripple] as [CALayer] { layer.frame = bounds }
        // The conic fill spins: make it cover the corners at any angle.
        let diagonal = hypot(bounds.width, bounds.height)
        fill.bounds = CGRect(x: 0, y: 0, width: diagonal, height: diagonal)
        fill.position = CGPoint(x: bounds.midX, y: bounds.midY)
        let path = ringPath(iconSize: iconSize, in: bounds)
        mask.path = path
        ripple.path = path
        CATransaction.commit()

        // The orbit follows the ring, so it is rebuilt when the icon changes size.
        guard !comet.isEmpty, iconSize != orbitSize else { return }
        orbitSize = iconSize
        let period: CFTimeInterval = 1.8
        for (index, spark) in comet.enumerated() {
            let orbit = CAKeyframeAnimation(keyPath: "position")
            orbit.path = path
            orbit.calculationMode = .paced
            orbit.duration = period
            orbit.repeatCount = .infinity
            // Each spark trails the previous one: the comet's tail.
            orbit.timeOffset = period - Double(index) * 0.045
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

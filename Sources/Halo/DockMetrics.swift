import CoreGraphics
import Foundation
import SwiftUI

/// The screen edge the bar is docked to. Left and right make it vertical, like the Dock.
enum DockEdge: String, CaseIterable {
    case bottom, top, left, right

    var isHorizontal: Bool { self == .bottom || self == .top }

    /// Where the bar sits inside its window.
    var alignment: Alignment {
        switch self {
        case .bottom: return .bottom
        case .top: return .top
        case .left: return .leading
        case .right: return .trailing
        }
    }

    /// The side facing away from the screen edge: where icons grow and bubbles appear.
    var awayAlignment: Alignment {
        switch self {
        case .bottom: return .top
        case .top: return .bottom
        case .left: return .trailing
        case .right: return .leading
        }
    }

    var swiftUIEdge: Edge.Set {
        switch self {
        case .bottom: return .bottom
        case .top: return .top
        case .left: return .leading
        case .right: return .trailing
        }
    }

    /// Unit vector pointing away from the screen edge, in SwiftUI coordinates (y down).
    var away: CGSize {
        switch self {
        case .bottom: return CGSize(width: 0, height: -1)
        case .top: return CGSize(width: 0, height: 1)
        case .left: return CGSize(width: 1, height: 0)
        case .right: return CGSize(width: -1, height: 0)
        }
    }
}

/// What the bar holds: icons, plus a divider between live and paused sessions.
struct Strip: Equatable {
    var count: Int
    /// Index of the first icon after the divider, if there is one.
    var dividerBefore: Int?
}

/// Geometry shared by the SwiftUI view and the window controller, so both agree on
/// where each icon sits without measuring the rendered layout. Everything scales with
/// the icon size, which you can change by pinching the bar.
struct DockMetrics: Equatable {
    var item: CGFloat
    /// Dock-style magnification under the pointer; 1 turns it off.
    var maxScale: CGFloat

    static let standardItem: CGFloat = 46
    static let itemRange: ClosedRange<CGFloat> = 26...76
    static let standard = DockMetrics(item: standardItem)

    init(item: CGFloat, maxScale: CGFloat = 1.55) {
        self.item = min(max(item, Self.itemRange.lowerBound), Self.itemRange.upperBound)
        self.maxScale = min(max(maxScale, 1), 2)
    }

    /// 1 at the standard size.
    var unit: CGFloat { item / Self.standardItem }
    /// Room between icons, plus the two rings around working icons (`ringOutset`), so that
    /// neighbours' rings never touch.
    var spacing: CGFloat { 8 * unit + ringOutset * 2 }
    var padding: CGFloat { 10 * unit }
    var dividerThickness: CGFloat { 1 }
    /// Width of the magnification bump around the pointer.
    var sigma: CGFloat { 48 * unit }
    /// Gap kept between the bar and the screen edge.
    var screenMargin: CGFloat { 6 }
    var cornerRadius: CGFloat { 22 * unit }

    var barThickness: CGFloat { item + padding * 2 }
    /// How far magnified icons stick out of the bar.
    var lift: CGFloat { item * (maxScale - 1) + 8 }
    /// Room beside the bar for magnified icons and the hover card.
    var horizontalHeadroom: CGFloat { lift + 190 }
    var verticalHeadroom: CGFloat { lift + 320 }
    /// Room along the bar for it to widen while magnified, and for the card at its ends.
    var alongHeadroom: CGFloat { max(150, 80 * unit) }

    /// A row of `count` icons, without the bar's padding.
    func rowLength(count: Int) -> CGFloat {
        let n = CGFloat(max(count, 1))
        return n * item + (n - 1) * spacing
    }

    /// The settings gear at the end of the bar, and the room it takes there.
    var gearSize: CGFloat { max(16, item * 0.46) }
    var gearSlot: CGFloat { gearSize + spacing }

    func barLength(_ strip: Strip) -> CGFloat {
        let n = CGFloat(max(strip.count, 1))
        var length = n * item + (n - 1) * spacing + padding * 2 + gearSlot
        if strip.dividerBefore != nil { length += dividerThickness + spacing }
        return length
    }

    /// `topInset`: room taken by the notch when the bar is docked into it.
    func windowSize(_ strip: Strip, edge: DockEdge, topInset: CGFloat = 0) -> CGSize {
        let along = barLength(strip) + alongHeadroom * 2
        if edge.isHorizontal {
            return CGSize(width: max(380, along), height: barThickness + horizontalHeadroom + topInset)
        }
        return CGSize(width: barThickness + verticalHeadroom, height: max(220, along))
    }

    /// Resting centers of the icons along the bar, from the window's leading/top side.
    func baseCenters(_ strip: Strip, mainLength: CGFloat) -> [CGFloat] {
        let start = (mainLength - barLength(strip)) / 2 + padding + item / 2
        return (0..<max(strip.count, 0)).map { index in
            var center = start + CGFloat(index) * (item + spacing)
            if let divider = strip.dividerBefore, index >= divider { center += dividerThickness + spacing }
            return center
        }
    }

    /// The bar's resting rectangle, in window coordinates (origin top-left).
    func barRect(_ strip: Strip, edge: DockEdge, windowSize: CGSize, topInset: CGFloat = 0) -> CGRect {
        let length = barLength(strip)
        switch edge {
        case .bottom:
            return CGRect(x: (windowSize.width - length) / 2, y: windowSize.height - barThickness,
                          width: length, height: barThickness)
        case .top:
            return CGRect(x: (windowSize.width - length) / 2, y: 0, width: length, height: barThickness + topInset)
        case .left:
            return CGRect(x: 0, y: (windowSize.height - length) / 2, width: barThickness, height: length)
        case .right:
            return CGRect(x: windowSize.width - barThickness, y: (windowSize.height - length) / 2,
                          width: barThickness, height: length)
        }
    }

    /// Dock-style fish-eye: full size under the pointer, easing back to 1 with distance.
    func scale(center: CGFloat, pointer: CGFloat?) -> CGFloat {
        guard let pointer else { return 1 }
        let d = pointer - center
        return 1 + (maxScale - 1) * exp(-(d * d) / (2 * sigma * sigma))
    }
}

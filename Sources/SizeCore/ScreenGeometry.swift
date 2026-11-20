import Foundation
import CoreGraphics

/// One physical display, expressed in NS coordinates.
public struct ScreenInfo: Equatable, Sendable {
    /// Full frame, including the area under the menu bar and Dock.
    public let frame: CGRect
    /// Frame minus menu bar and Dock.
    public let visibleFrame: CGRect
    /// Stable ordering index, left-to-right then top-to-bottom.
    public let index: Int

    public init(frame: CGRect, visibleFrame: CGRect, index: Int) {
        self.frame = frame
        self.visibleFrame = visibleFrame
        self.index = index
    }
}

public enum ScreenGeometry {
    /// Converts an NS-coordinate rectangle to global CoreGraphics coordinates.
    ///
    /// CoreGraphics puts the origin at the top-left of the *main* display with
    /// Y increasing downward, while NS puts it at the bottom-left with Y
    /// increasing upward. The two are mirrored through the main screen height.
    public static func cgRect(fromNS rect: CGRect, mainScreenFrame: CGRect) -> CGRect {
        CGRect(
            x: rect.minX,
            y: mainScreenFrame.maxY - rect.maxY,
            width: rect.width,
            height: rect.height
        )
    }

    /// Inverse of ``cgRect(fromNS:mainScreenFrame:)``. The transform is its own
    /// inverse because it only mirrors around a fixed horizontal axis.
    public static func nsRect(fromCG rect: CGRect, mainScreenFrame: CGRect) -> CGRect {
        CGRect(
            x: rect.minX,
            y: mainScreenFrame.maxY - rect.maxY,
            width: rect.width,
            height: rect.height
        )
    }

    /// Index of the screen containing the window's centre, falling back to the
    /// screen with the largest overlap, then to the first screen.
    public static func screenIndex(containing windowFrame: CGRect, screens: [ScreenInfo]) -> Int? {
        guard !screens.isEmpty else { return nil }
        let centre = CGPoint(x: windowFrame.midX, y: windowFrame.midY)
        if let hit = screens.first(where: { $0.frame.contains(centre) }) {
            return hit.index
        }
        let overlaps = screens.map { screen -> (Int, CGFloat) in
            let intersection = screen.frame.intersection(windowFrame)
            let area = intersection.isNull ? 0 : intersection.width * intersection.height
            return (screen.index, area)
        }
        if let best = overlaps.max(by: { $0.1 < $1.1 }), best.1 > 0 {
            return best.0
        }
        return screens.first?.index
    }

    /// Maps a window onto another display without distorting it: the relative
    /// position within the source screen is preserved, and the result is nudged
    /// back inside the destination's visible frame so it can never end up
    /// partly off-screen.
    /// Moves a window onto another display.
    ///
    /// Two behaviours matter here:
    ///
    /// 1. A window that fills its screen should still fill the next one, even
    ///    when the second display has a different resolution. Snapping to the
    ///    destination's usable area is what keeps "maximised" meaning
    ///    "maximised" across displays; scaling the old pixels would leave a
    ///    band of desktop showing.
    /// 2. Everything else keeps its *relative* geometry. Both origin and size
    ///    are expressed as fractions of the source's usable area and rebuilt on
    ///    the destination, so a left half stays a left half and a quarter stays
    ///    a quarter.
    public static func transferred(
        _ windowFrame: CGRect,
        from source: ScreenInfo,
        to destination: ScreenInfo,
        margin: EdgeInsets = .zero,
        gap: CGFloat = 0,
        fullBleedTolerance: CGFloat = 8
    ) -> CGRect {
        let destinationArea = usableArea(
            of: destination.visibleFrame,
            margin: margin,
            gap: gap
        )

        guard windowFrame.width > 0, windowFrame.height > 0 else {
            return destination.visibleFrame
        }

        let sourceArea = usableArea(
            of: source.visibleFrame,
            margin: margin,
            gap: gap
        )

        if isFullBleed(windowFrame, in: sourceArea, tolerance: fullBleedTolerance) {
            return destinationArea
        }

        // Fractions of the source's usable area, clamped so a window hanging off
        // the edge of the screen does not land outside the destination.
        func fraction(_ value: CGFloat, along origin: CGFloat, extent: CGFloat) -> CGFloat {
            guard extent > 0 else { return 0 }
            return min(max((value - origin) / extent, 0), 1)
        }

        let leftFraction = fraction(windowFrame.minX, along: sourceArea.minX, extent: sourceArea.width)
        let rightFraction = fraction(windowFrame.maxX, along: sourceArea.minX, extent: sourceArea.width)
        let bottomFraction = fraction(windowFrame.minY, along: sourceArea.minY, extent: sourceArea.height)
        let topFraction = fraction(windowFrame.maxY, along: sourceArea.minY, extent: sourceArea.height)

        let left = (destinationArea.minX + leftFraction * destinationArea.width).rounded()
        let right = (destinationArea.minX + rightFraction * destinationArea.width).rounded()
        let bottom = (destinationArea.minY + bottomFraction * destinationArea.height).rounded()
        let top = (destinationArea.minY + topFraction * destinationArea.height).rounded()

        // Rounding can collapse a sliver; keep everything at least a point wide.
        let width = max(1, right - left)
        let height = max(1, top - bottom)

        return CGRect(
            x: min(left, destinationArea.maxX - width),
            y: min(bottom, destinationArea.maxY - height),
            width: width,
            height: height
        )
    }

    /// Whether the window effectively covers the whole usable area.
    ///
    /// Checked against the usable (margin/gap-inset) area as well as the raw
    /// screen, because a maximised window under a margin setting fills the inset
    /// rectangle, not the screen itself.
    public static func isFullBleed(
        _ windowFrame: CGRect,
        in area: CGRect,
        tolerance: CGFloat = 8
    ) -> Bool {
        guard area.width > 0, area.height > 0 else { return false }
        let edgesMatch = abs(windowFrame.minX - area.minX) <= tolerance
            && abs(windowFrame.maxX - area.maxX) <= tolerance
            && abs(windowFrame.minY - area.minY) <= tolerance
            && abs(windowFrame.maxY - area.maxY) <= tolerance
        if edgesMatch { return true }

        // Some apps report an almost-full frame (a few points of rounding, or a
        // window that was maximised before a display change). Treat anything
        // covering ~97% or more of the area as full.
        let covered = (windowFrame.width * windowFrame.height) / (area.width * area.height)
        return covered >= 0.97
    }

    /// The rectangle layout actions treat as the screen: the visible frame minus
    /// the per-side margin, then inset by half the gap.
    public static func usableArea(
        of visibleFrame: CGRect,
        margin: EdgeInsets,
        gap: CGFloat
    ) -> CGRect {
        let inset = margin.clampedNonNegative()
        var area = CGRect(
            x: visibleFrame.minX + inset.left,
            y: visibleFrame.minY + inset.bottom,
            width: max(0, visibleFrame.width - inset.left - inset.right),
            height: max(0, visibleFrame.height - inset.top - inset.bottom)
        )
        if gap > 0 {
            let half = (gap / 2).rounded()
            area = CGRect(
                x: area.minX + half,
                y: area.minY + half,
                width: max(1, area.width - half * 2),
                height: max(1, area.height - half * 2)
            )
        }
        return area
    }

    /// Keeps `size` but slides `origin` so the window lies fully inside `bounds`.
    public static func clampedOrigin(for size: CGSize, inside bounds: CGRect, preferred origin: CGPoint) -> CGPoint {
        let width = min(size.width, bounds.width)
        let height = min(size.height, bounds.height)
        let x = min(max(origin.x, bounds.minX), bounds.maxX - width)
        let y = min(max(origin.y, bounds.minY), bounds.maxY - height)
        return CGPoint(x: x.rounded(), y: y.rounded())
    }
}

import Foundation
import CoreGraphics

/// A rectangle in a top-left-origin logical grid.
///
/// The grid is the single primitive behind every layout action: a 6x6 grid
/// accommodates halves (3/6), thirds (2/6) and quadrants (3x3) at once,
/// because 6 is the least common multiple of 2 and 3.
public struct GridRect: Equatable, Hashable, Sendable {
    public let x: Int
    public let y: Int
    public let width: Int
    public let height: Int

    public init(x: Int, y: Int, width: Int, height: Int) {
        self.x = x
        self.y = y
        self.width = width
        self.height = height
    }

    /// Clamps the rect into grid bounds, never producing a negative extent.
    /// Used instead of a precondition so malformed input degrades instead of
    /// crashing a long-running menu bar app.
    public func clamped(to grid: GridSize) -> GridRect {
        let x = min(max(0, self.x), max(0, grid.columns - 1))
        let y = min(max(0, self.y), max(0, grid.rows - 1))
        let width = min(max(1, self.width), max(1, grid.columns - x))
        let height = min(max(1, self.height), max(1, grid.rows - y))
        return GridRect(x: x, y: y, width: width, height: height)
    }
}

public struct GridSize: Equatable, Hashable, Sendable {
    public let columns: Int
    public let rows: Int

    public init(columns: Int = 6, rows: Int = 6) {
        self.columns = max(1, columns)
        self.rows = max(1, rows)
    }

    public static let standard = GridSize()
}

public struct EdgeInsets: Equatable, Hashable, Sendable {
    public let top: CGFloat
    public let left: CGFloat
    public let bottom: CGFloat
    public let right: CGFloat

    public init(top: CGFloat = 0, left: CGFloat = 0, bottom: CGFloat = 0, right: CGFloat = 0) {
        self.top = top
        self.left = left
        self.bottom = bottom
        self.right = right
    }

    public static let zero = EdgeInsets()

    public func clampedNonNegative() -> EdgeInsets {
        EdgeInsets(
            top: max(0, top),
            left: max(0, left),
            bottom: max(0, bottom),
            right: max(0, right)
        )
    }
}

/// Converts a top-left-origin grid rectangle into an NS-coordinate rectangle
/// laid over `screen` (normally `NSScreen.visibleFrame`).
///
/// `margin` insets the whole layout from the screen edges, matching SizeUp's
/// per-side margins (useful for the Dock or a menu bar overhang). `gap` instead
/// shrinks each tile individually so neighbouring windows leave a visible
/// channel between them.
///
/// Both axis boundaries are rounded independently and the extent is derived by
/// subtraction, so two adjacent regions share an exact edge and never leave a
/// one-pixel seam when tiled.
public func frame(
    for gridRect: GridRect,
    in gridSize: GridSize = .standard,
    screen: CGRect,
    margin: EdgeInsets = .zero,
    gap: CGFloat = 0
) -> CGRect {
    let rect = gridRect.clamped(to: gridSize)
    let inset = margin.clampedNonNegative()

    let available = CGRect(
        x: screen.minX + inset.left,
        y: screen.minY + inset.bottom,
        width: max(0, screen.width - inset.left - inset.right),
        height: max(0, screen.height - inset.top - inset.bottom)
    )

    func xEdge(_ index: Int) -> CGFloat {
        (available.minX + available.width * CGFloat(index) / CGFloat(gridSize.columns)).rounded()
    }
    func yEdge(_ index: Int) -> CGFloat {
        (available.minY + available.height * CGFloat(index) / CGFloat(gridSize.rows)).rounded()
    }

    // Grid origin is top-left; NS origin is bottom-left, hence the flip.
    let bottomIndex = gridSize.rows - rect.y - rect.height
    let x = xEdge(rect.x)
    let y = yEdge(bottomIndex)

    var result = CGRect(
        x: x,
        y: y,
        width: xEdge(rect.x + rect.width) - x,
        height: yEdge(bottomIndex + rect.height) - y
    )

    if gap > 0 {
        let half = (gap / 2).rounded()
        result = CGRect(
            x: result.minX + half,
            y: result.minY + half,
            width: max(1, result.width - half * 2),
            height: max(1, result.height - half * 2)
        )
    }

    return result
}

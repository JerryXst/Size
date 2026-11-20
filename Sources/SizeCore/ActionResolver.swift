import Foundation
import CoreGraphics

public enum SpaceDirection: String, Sendable {
    case previous, next, above, below
}

/// Outcome of resolving an action against a concrete window and screen setup.
public enum ActionResolution: Equatable, Sendable {
    /// Move and resize the window to this NS-coordinate frame.
    case frame(CGRect)
    /// Hand off to the Space mover.
    case space(SpaceDirection, CGRect)
    /// Nothing saved yet, so there is nothing to restore.
    case needsSnapshot
    /// Cannot be performed, with a reason suitable for showing the user.
    case unavailable(String)
}

public struct ResolveInput: Sendable {
    public let windowFrame: CGRect
    public let screens: [ScreenInfo]
    public let gridSize: GridSize
    public let margin: EdgeInsets
    /// Channel left between adjacent windows.
    public let gap: CGFloat
    /// Frame remembered before the first layout action, used by `snapBack`.
    public let savedFrame: CGRect?
    /// Per-app grid override for grid actions.
    public let gridRectOverride: GridRect?

    public init(
        windowFrame: CGRect,
        screens: [ScreenInfo],
        gridSize: GridSize = .standard,
        margin: EdgeInsets = .zero,
        gap: CGFloat = 0,
        savedFrame: CGRect? = nil,
        gridRectOverride: GridRect? = nil
    ) {
        self.windowFrame = windowFrame
        self.screens = screens
        self.gridSize = gridSize
        self.margin = margin
        self.gap = gap
        self.savedFrame = savedFrame
        self.gridRectOverride = gridRectOverride
    }
}

/// Pure resolution of an action into a target frame. No AppKit, no AX, no I/O,
/// so every branch here is unit-testable without touching a real window.
public enum ActionResolver {
    public static func resolve(_ action: WindowAction, input: ResolveInput) -> ActionResolution {
        guard !input.screens.isEmpty else {
            return .unavailable("No displays available")
        }

        let screenIndex = ScreenGeometry.screenIndex(
            containing: input.windowFrame,
            screens: input.screens
        ) ?? input.screens[0].index

        guard let screen = input.screens.first(where: { $0.index == screenIndex }) else {
            return .unavailable("Window is not on a known display")
        }

        switch action.category {
        case .grid:
            let rect = input.gridRectOverride ?? action.gridRect
            guard let rect else {
                return .unavailable(action.nonGridReason ?? "Unsupported action")
            }
            let target = frame(
                for: rect,
                in: input.gridSize,
                screen: screen.visibleFrame,
                margin: input.margin,
                gap: input.gap
            )
            return .frame(target)

        case .move:
            return .frame(moved(action, windowFrame: input.windowFrame, screen: screen, margin: input.margin))

        case .center:
            return .frame(centered(input.windowFrame, screen: screen))

        case .restore:
            guard let saved = input.savedFrame else { return .needsSnapshot }
            return .frame(saved)

        case .monitor:
            guard input.screens.count > 1 else {
                return .unavailable("Only one display is connected")
            }
            let ordered = input.screens.sorted { $0.index < $1.index }
            guard let position = ordered.firstIndex(where: { $0.index == screen.index }) else {
                return .unavailable("Window is not on a known display")
            }
            let delta = action == .nextMonitor ? 1 : -1
            let destination = ordered[(position + delta + ordered.count) % ordered.count]
            let target = ScreenGeometry.transferred(
                input.windowFrame,
                from: screen,
                to: destination,
                margin: input.margin,
                gap: input.gap
            )
            return .frame(target)

        case .space:
            guard let direction = spaceDirection(for: action) else {
                return .unavailable("Unsupported Space action")
            }
            return .space(direction, input.windowFrame)
        }
    }

    public static func spaceDirection(for action: WindowAction) -> SpaceDirection? {
        switch action {
        case .prevSpace: return .previous
        case .nextSpace: return .next
        case .spaceAbove: return .above
        case .spaceBelow: return .below
        default: return nil
        }
    }

    /// Size-preserving moves. The untouched axis keeps the window's current
    /// position so a user can nudge a window without it being resized.
    public static func moved(
        _ action: WindowAction,
        windowFrame: CGRect,
        screen: ScreenInfo,
        margin: EdgeInsets
    ) -> CGRect {
        let bounds = screen.visibleFrame
        let inset = margin.clampedNonNegative()
        var origin = windowFrame.origin

        switch action {
        case .moveLeft:
            origin.x = bounds.minX + inset.left
        case .moveRight:
            origin.x = bounds.maxX - inset.right - windowFrame.width
        case .moveUp:
            origin.y = bounds.maxY - inset.top - windowFrame.height
        case .moveDown:
            origin.y = bounds.minY + inset.bottom
        case .moveUpperLeft:
            origin.x = bounds.minX + inset.left
            origin.y = bounds.maxY - inset.top - windowFrame.height
        case .moveUpperRight:
            origin.x = bounds.maxX - inset.right - windowFrame.width
            origin.y = bounds.maxY - inset.top - windowFrame.height
        case .moveLowerLeft:
            origin.x = bounds.minX + inset.left
            origin.y = bounds.minY + inset.bottom
        case .moveLowerRight:
            origin.x = bounds.maxX - inset.right - windowFrame.width
            origin.y = bounds.minY + inset.bottom
        default:
            break
        }

        let clamped = ScreenGeometry.clampedOrigin(
            for: windowFrame.size,
            inside: bounds,
            preferred: origin
        )
        return CGRect(origin: clamped, size: windowFrame.size)
    }

    public static func centered(_ windowFrame: CGRect, screen: ScreenInfo) -> CGRect {
        let bounds = screen.visibleFrame
        let size = CGSize(
            width: min(windowFrame.width, bounds.width),
            height: min(windowFrame.height, bounds.height)
        )
        let origin = CGPoint(
            x: bounds.midX - size.width / 2,
            y: bounds.midY - size.height / 2
        )
        let clamped = ScreenGeometry.clampedOrigin(for: size, inside: bounds, preferred: origin)
        return CGRect(origin: clamped, size: size)
    }
}

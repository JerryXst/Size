import Foundation

/// How an action is carried out.
public enum ActionCategory: String, Sendable {
    /// Position and size come from the grid primitive.
    case grid
    /// Size is preserved, only the origin changes.
    case move
    /// Size is preserved and the window is centred.
    case center
    /// Restores a previously remembered frame.
    case restore
    /// Moves between physical displays.
    case monitor
    /// Moves between Spaces (needs private APIs).
    case space
}

/// Every layout action the app exposes.
///
/// Names mirror SizeUp's scripting vocabulary so existing mental models carry
/// over. `twoThirdsLeft` / `twoThirdsRight` are documented additions.
public enum WindowAction: String, CaseIterable, Sendable {
    // Grid: halves
    case left, right, up, down
    // Grid: quadrants
    case upperLeft, upperRight, lowerLeft, lowerRight
    // Grid: whole screen
    case fullScreen
    // Grid: thirds
    case thirdLeft, thirdCenter, thirdRight, thirdUpper, thirdMiddle, thirdLower
    // Grid: two thirds (extension)
    case twoThirdsLeft, twoThirdsRight

    // Size-preserving moves
    case moveLeft, moveRight, moveUp, moveDown
    case moveUpperLeft, moveUpperRight, moveLowerLeft, moveLowerRight
    // Centre
    case center, moveCenter

    // Restore
    case snapBack

    // Displays
    case prevMonitor, nextMonitor

    // Spaces
    case prevSpace, nextSpace, spaceAbove, spaceBelow

    public static let gridActions: [WindowAction] = [
        .left, .right, .up, .down,
        .upperLeft, .upperRight, .lowerLeft, .lowerRight,
        .fullScreen,
        .thirdLeft, .thirdCenter, .thirdRight,
        .thirdUpper, .thirdMiddle, .thirdLower,
        .twoThirdsLeft, .twoThirdsRight
    ]

    public static let moveActions: [WindowAction] = [
        .moveLeft, .moveRight, .moveUp, .moveDown,
        .moveUpperLeft, .moveUpperRight, .moveLowerLeft, .moveLowerRight
    ]

    public static let monitorActions: [WindowAction] = [.prevMonitor, .nextMonitor]
    public static let spaceActions: [WindowAction] = [.prevSpace, .nextSpace, .spaceAbove, .spaceBelow]

    public var category: ActionCategory {
        switch self {
        case .left, .right, .up, .down,
             .upperLeft, .upperRight, .lowerLeft, .lowerRight,
             .fullScreen,
             .thirdLeft, .thirdCenter, .thirdRight,
             .thirdUpper, .thirdMiddle, .thirdLower,
             .twoThirdsLeft, .twoThirdsRight:
            return .grid
        case .moveLeft, .moveRight, .moveUp, .moveDown,
             .moveUpperLeft, .moveUpperRight, .moveLowerLeft, .moveLowerRight:
            return .move
        case .center, .moveCenter:
            return .center
        case .snapBack:
            return .restore
        case .prevMonitor, .nextMonitor:
            return .monitor
        case .prevSpace, .nextSpace, .spaceAbove, .spaceBelow:
            return .space
        }
    }

    /// Grid rectangle for grid-based actions, `nil` otherwise.
    public var gridRect: GridRect? {
        Self.gridRects[self]
    }

    private static let gridRects: [WindowAction: GridRect] = [
        .left: GridRect(x: 0, y: 0, width: 3, height: 6),
        .right: GridRect(x: 3, y: 0, width: 3, height: 6),
        .up: GridRect(x: 0, y: 0, width: 6, height: 3),
        .down: GridRect(x: 0, y: 3, width: 6, height: 3),

        .upperLeft: GridRect(x: 0, y: 0, width: 3, height: 3),
        .upperRight: GridRect(x: 3, y: 0, width: 3, height: 3),
        .lowerLeft: GridRect(x: 0, y: 3, width: 3, height: 3),
        .lowerRight: GridRect(x: 3, y: 3, width: 3, height: 3),

        .fullScreen: GridRect(x: 0, y: 0, width: 6, height: 6),

        .thirdLeft: GridRect(x: 0, y: 0, width: 2, height: 6),
        .thirdCenter: GridRect(x: 2, y: 0, width: 2, height: 6),
        .thirdRight: GridRect(x: 4, y: 0, width: 2, height: 6),
        .thirdUpper: GridRect(x: 0, y: 0, width: 6, height: 2),
        .thirdMiddle: GridRect(x: 0, y: 2, width: 6, height: 2),
        .thirdLower: GridRect(x: 0, y: 4, width: 6, height: 2),

        .twoThirdsLeft: GridRect(x: 0, y: 0, width: 4, height: 6),
        .twoThirdsRight: GridRect(x: 2, y: 0, width: 4, height: 6)
    ]

    /// Human-readable reason for actions that do not map onto the grid.
    /// Kept so the UI can explain itself rather than showing a dead entry.
    public var nonGridReason: String? {
        guard gridRect == nil else { return nil }
        switch self {
        case .center, .moveCenter: return "keeps the current size and centres the window"
        case .snapBack: return "restores a remembered frame"
        case .prevMonitor, .nextMonitor: return "moves between displays"
        case .moveLeft, .moveRight, .moveUp, .moveDown,
             .moveUpperLeft, .moveUpperRight, .moveLowerLeft, .moveLowerRight:
            return "keeps the current size"
        case .prevSpace, .nextSpace, .spaceAbove, .spaceBelow:
            return "moves between Spaces"
        default: return nil
        }
    }

    /// Whether this action can carry a keyboard shortcut. Space moves cannot:
    /// they need private APIs and are off by default.
    public var isHotkeyable: Bool {
        category != .space
    }

    /// Short label for menus.
    public var displayName: String {
        switch self {
        case .left: return "Left Half"
        case .right: return "Right Half"
        case .up: return "Top Half"
        case .down: return "Bottom Half"
        case .upperLeft: return "Top Left"
        case .upperRight: return "Top Right"
        case .lowerLeft: return "Bottom Left"
        case .lowerRight: return "Bottom Right"
        case .fullScreen: return "Fill Screen"
        case .thirdLeft: return "Left Third"
        case .thirdCenter: return "Centre Third"
        case .thirdRight: return "Right Third"
        case .thirdUpper: return "Top Third"
        case .thirdMiddle: return "Middle Third"
        case .thirdLower: return "Bottom Third"
        case .twoThirdsLeft: return "Left Two Thirds"
        case .twoThirdsRight: return "Right Two Thirds"
        case .moveLeft: return "Move Left"
        case .moveRight: return "Move Right"
        case .moveUp: return "Move Up"
        case .moveDown: return "Move Down"
        case .moveUpperLeft: return "Move Top Left"
        case .moveUpperRight: return "Move Top Right"
        case .moveLowerLeft: return "Move Bottom Left"
        case .moveLowerRight: return "Move Bottom Right"
        case .center: return "Centre"
        case .moveCenter: return "Move to Centre"
        case .snapBack: return "Undo Layout"
        case .prevMonitor: return "Previous Display"
        case .nextMonitor: return "Next Display"
        case .prevSpace: return "Previous Space"
        case .nextSpace: return "Next Space"
        case .spaceAbove: return "Space Above"
        case .spaceBelow: return "Space Below"
        }
    }
}

import Foundation
import CoreGraphics

/// Per-side margin. A negative value means "inherit the global default",
/// which keeps the config file terse and avoids optional-nil plumbing.
public struct Margin: Codable, Equatable, Sendable {
    public var top: Double
    public var bottom: Double
    public var left: Double
    public var right: Double

    public init(top: Double = -1, bottom: Double = -1, left: Double = -1, right: Double = -1) {
        self.top = top
        self.bottom = bottom
        self.left = left
        self.right = right
    }

    public static let inherit = Margin()

    public func resolved(fallback: Margin) -> EdgeInsets {
        EdgeInsets(
            top: top >= 0 ? top : max(0, fallback.top),
            left: left >= 0 ? left : max(0, fallback.left),
            bottom: bottom >= 0 ? bottom : max(0, fallback.bottom),
            right: right >= 0 ? right : max(0, fallback.right)
        )
    }
}

/// Codable mirror of `GridRect` so user-editable JSON stays flat and readable.
public struct GridRectCodable: Codable, Equatable, Sendable {
    public var x: Int
    public var y: Int
    public var width: Int
    public var height: Int

    public init(x: Int, y: Int, width: Int, height: Int) {
        self.x = x
        self.y = y
        self.width = width
        self.height = height
    }

    public var gridRect: GridRect { GridRect(x: x, y: y, width: width, height: height) }
}

/// Per-application overrides, keyed by bundle identifier.
public struct AppOverride: Codable, Equatable, Sendable {
    /// Ignore every shortcut while this app is frontmost.
    public var disabled: Bool
    public var margin: Margin?
    /// Overrides a grid action's rectangle, e.g. a wider "left" for an IDE.
    public var actionParams: [String: GridRectCodable]?

    public init(
        disabled: Bool = false,
        margin: Margin? = nil,
        actionParams: [String: GridRectCodable]? = nil
    ) {
        self.disabled = disabled
        self.margin = margin
        self.actionParams = actionParams
    }
}

public struct SizeConfig: Codable, Equatable, Sendable {
    public var gridColumns: Int
    public var gridRows: Int
    public var defaultMargin: Margin
    /// Channel left between adjacent windows, in points.
    public var gap: Double
    /// Bundle identifiers that are never touched.
    public var ignoredBundleIDs: [String]
    public var overrides: [String: AppOverride]
    /// Cross-Space moves use private APIs and are opt-in.
    public var enableSpaceActions: Bool
    /// How long to wait for a full-screen transition, in seconds.
    public var fullScreenExitTimeout: Double
    /// User-recorded shortcuts, keyed by action raw value. A missing entry
    /// falls back to `DefaultHotkeys`.
    public var hotkeys: [String: HotkeyBinding]
    /// Actions whose shortcut the user explicitly removed.
    public var disabledHotkeyActions: [String]

    public init(
        gridColumns: Int = 6,
        gridRows: Int = 6,
        defaultMargin: Margin = Margin(top: 0, bottom: 0, left: 0, right: 0),
        gap: Double = 0,
        ignoredBundleIDs: [String] = [],
        overrides: [String: AppOverride] = [:],
        enableSpaceActions: Bool = false,
        fullScreenExitTimeout: Double = 0.6,
        hotkeys: [String: HotkeyBinding] = [:],
        disabledHotkeyActions: [String] = []
    ) {
        self.gridColumns = gridColumns
        self.gridRows = gridRows
        self.defaultMargin = defaultMargin
        self.gap = gap
        self.ignoredBundleIDs = ignoredBundleIDs
        self.overrides = overrides
        self.enableSpaceActions = enableSpaceActions
        self.fullScreenExitTimeout = fullScreenExitTimeout
        self.hotkeys = hotkeys
        self.disabledHotkeyActions = disabledHotkeyActions
    }

    public static let `default` = SizeConfig()

    public var gridSize: GridSize {
        GridSize(columns: gridColumns, rows: gridRows)
    }

    public func margin(for bundleID: String?) -> EdgeInsets {
        guard let bundleID,
              let override = overrides[bundleID],
              let margin = override.margin else {
            return defaultMargin.resolved(fallback: Margin(top: 0, bottom: 0, left: 0, right: 0))
        }
        return margin.resolved(fallback: defaultMargin)
    }

    public func isIgnored(bundleID: String?) -> Bool {
        guard let bundleID else { return false }
        return ignoredBundleIDs.contains(bundleID)
    }

    public func isDisabled(bundleID: String?) -> Bool {
        guard let bundleID else { return false }
        return overrides[bundleID]?.disabled ?? false
    }

    /// Grid rect for an action, honouring a per-app override when present.
    public func gridRect(for action: WindowAction, bundleID: String?) -> GridRect? {
        if let bundleID,
           let override = overrides[bundleID],
           let params = override.actionParams,
           let custom = params[action.rawValue] {
            return custom.gridRect
        }
        return action.gridRect
    }

    /// Effective shortcut for an action: user override, else the default.
    public func binding(for action: WindowAction) -> HotkeyBinding? {
        if disabledHotkeyActions.contains(action.rawValue) { return nil }
        if let custom = hotkeys[action.rawValue] { return custom }
        return action.isHotkeyable ? DefaultHotkeys.binding(for: action) : nil
    }

    public mutating func setBinding(_ binding: HotkeyBinding?, for action: WindowAction) {
        if let binding {
            hotkeys[action.rawValue] = binding
            disabledHotkeyActions.removeAll { $0 == action.rawValue }
        } else {
            hotkeys.removeValue(forKey: action.rawValue)
            if !disabledHotkeyActions.contains(action.rawValue) {
                disabledHotkeyActions.append(action.rawValue)
            }
        }
    }

    /// Removes the override so the shipped default applies again.
    public mutating func resetBinding(for action: WindowAction) {
        hotkeys.removeValue(forKey: action.rawValue)
        disabledHotkeyActions.removeAll { $0 == action.rawValue }
    }

    public func isCustomised(_ action: WindowAction) -> Bool {
        hotkeys[action.rawValue] != nil || disabledHotkeyActions.contains(action.rawValue)
    }

    /// Decoding is lenient on purpose: a config written by an older build, or
    /// hand-edited with a typo, should not brick the app.
    public static func decode(from data: Data) -> SizeConfig {
        guard let decoded = try? JSONDecoder().decode(SizeConfig.self, from: data) else {
            return .default
        }
        return decoded.sanitised()
    }

    public func sanitised() -> SizeConfig {
        var copy = self
        copy.gridColumns = min(max(1, copy.gridColumns), 24)
        copy.gridRows = min(max(1, copy.gridRows), 24)
        copy.fullScreenExitTimeout = min(max(0.1, copy.fullScreenExitTimeout), 3.0)
        copy.gap = min(max(0, copy.gap), 200)
        return copy
    }

    public func encoded() -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return (try? encoder.encode(self)) ?? Data()
    }
}

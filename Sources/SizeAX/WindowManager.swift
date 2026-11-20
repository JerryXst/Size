import AppKit
import CoreGraphics
import Foundation
import SizeCore

/// Cross-Space movement is isolated behind a protocol so the private-API
/// implementation can be disabled or removed without touching the rest.
@MainActor
public protocol WindowSpaceMoving: AnyObject {
    func move(_ direction: SpaceDirection, window: AXWindow) -> Bool
}

public enum PerformResult: Equatable, Sendable {
    case moved(CGRect)
    /// The app constrained the frame; this is where the window actually went.
    case adjusted(CGRect)
    case spaceMoved
    /// `snapBack` was pressed but nothing was recorded.
    case nothingToRestore
    case skipped(String)
    case failed(String)

    public var succeeded: Bool {
        switch self {
        case .moved, .adjusted, .spaceMoved: return true
        case .nothingToRestore, .skipped, .failed: return false
        }
    }

    public var message: String {
        switch self {
        case .moved(let frame): return "Moved to \(Self.describe(frame))"
        case .adjusted(let frame): return "App constrained the window to \(Self.describe(frame))"
        case .spaceMoved: return "Moved to another Space"
        case .nothingToRestore: return "Nothing to undo for this window"
        case .skipped(let reason): return reason
        case .failed(let reason): return reason
        }
    }

    private static func describe(_ frame: CGRect) -> String {
        let x = Int(frame.minX.rounded())
        let y = Int(frame.minY.rounded())
        let width = Int(frame.width.rounded())
        let height = Int(frame.height.rounded())
        return "\(width)x\(height) at \(x),\(y)"
    }
}

/// Coordinates config, snapshots, geometry resolution and window mutation.
@MainActor
public final class WindowManager {
    public private(set) var config: SizeConfig
    private var snapshots = SnapshotStore()
    private let mover: AXWindowMover
    private var spaceMover: WindowSpaceMoving?

    public init(
        config: SizeConfig = .default,
        mover: AXWindowMover = AXWindowMover(),
        spaceMover: WindowSpaceMoving? = nil
    ) {
        self.config = config
        self.mover = mover
        self.spaceMover = spaceMover
    }

    public func update(config: SizeConfig) {
        self.config = config.sanitised()
    }

    public func setSpaceMover(_ mover: WindowSpaceMoving?) {
        self.spaceMover = mover
    }

    /// Number of windows currently holding a snapshot; used by tests.
    public var snapshotCount: Int { snapshots.frames.count }

    /// Whether `snapBack` would do anything for this window.
    public func canRestore(window: AXWindow) -> Bool {
        snapshots.recall(key: window.snapshotKey) != nil
    }

    @discardableResult
    public func performOnFocusedWindow(_ action: WindowAction) -> PerformResult {
        guard AXPermission.isTrusted else {
            return .failed("Accessibility permission is required")
        }
        guard let window = AXAppEnumerator.focusedWindow() else {
            return .failed("No focused window")
        }
        return perform(action, on: window)
    }

    @discardableResult
    public func perform(_ action: WindowAction, on window: AXWindow) -> PerformResult {
        let bundleID = window.bundleID

        if config.isIgnored(bundleID: bundleID) {
            return .skipped("\(window.appName ?? "This app") is on the ignore list")
        }
        if config.isDisabled(bundleID: bundleID) {
            return .skipped("Shortcuts are disabled for \(window.appName ?? "this app")")
        }

        let mainScreenFrame = ScreenProvider.mainScreenFrame
        guard let windowFrame = window.frame(mainScreenFrame: mainScreenFrame) else {
            return .failed("Could not read the window frame")
        }

        let key = window.snapshotKey
        let saved = snapshots.recall(key: key)

        let resolution = ActionResolver.resolve(action, input: ResolveInput(
            windowFrame: windowFrame,
            screens: ScreenProvider.screens(),
            gridSize: config.gridSize,
            margin: config.margin(for: bundleID),
            gap: CGFloat(config.gap),
            savedFrame: saved,
            gridRectOverride: config.gridRect(for: action, bundleID: bundleID)
        ))

        switch resolution {
        case .frame(let target):
            // Remember the pre-move frame once, so a chain of actions still
            // undoes back to the original position.
            if action != .snapBack {
                snapshots.remember(key: key, frame: windowFrame)
            }
            let outcome = mover.setFrame(
                target,
                on: window,
                mainScreenFrame: mainScreenFrame,
                fullScreenTimeout: config.fullScreenExitTimeout
            )
            switch outcome {
            case .exact:
                return .moved(target)
            case .adjusted(let actual):
                return .adjusted(actual)
            case .failed(let reason):
                return .failed(reason)
            }

        case .space(let direction, _):
            guard config.enableSpaceActions else {
                return .skipped("Space moves are turned off in settings")
            }
            guard let spaceMover else {
                return .skipped("Space moves are unavailable on this system")
            }
            snapshots.remember(key: key, frame: windowFrame)
            return spaceMover.move(direction, window: window) ? .spaceMoved : .failed("The system refused the Space move")

        case .needsSnapshot:
            return .nothingToRestore

        case .unavailable(let reason):
            return .skipped(reason)
        }
    }

    /// Drops snapshots for windows that no longer exist.
    ///
    /// Only the apps we actually hold snapshots for are queried. Enumerating
    /// every running app would issue dozens of Accessibility round trips on the
    /// main thread — each able to block for the messaging timeout — which made
    /// the app unresponsive for seconds at a time.
    public func pruneSnapshots() {
        let keys = snapshots.frames.keys
        guard !keys.isEmpty else { return }

        var live = Set<String>()
        for pidText in Set(keys.compactMap { $0.split(separator: "-").first }) {
            guard let pid = pid_t(pidText) else { continue }
            guard NSRunningApplication(processIdentifier: pid) != nil else { continue }
            for window in AXAppEnumerator.windows(forPID: pid) {
                live.insert(window.snapshotKey)
            }
        }
        snapshots.retain(keys: live)
    }
}

import Foundation
import CoreGraphics

/// Remembers window frames so a layout can be undone.
///
/// One slot per window: the frame captured *before* the first layout action is
/// what `snapBack` restores. Recording again while a snapshot already exists
/// keeps the oldest one, so a chain of actions still undoes to the original
/// position rather than to the previous step.
public struct SnapshotStore: Sendable {
    public private(set) var frames: [String: CGRect]

    public init(frames: [String: CGRect] = [:]) {
        self.frames = frames
    }

    public mutating func remember(key: String, frame: CGRect, overwrite: Bool = false) {
        if !overwrite, frames[key] != nil { return }
        frames[key] = frame
    }

    public func recall(key: String) -> CGRect? {
        frames[key]
    }

    public mutating func forget(key: String) {
        frames.removeValue(forKey: key)
    }

    /// Drops entries whose windows are gone, so the map cannot grow unbounded
    /// in a long-running menu bar app.
    public mutating func retain(keys: Set<String>) {
        frames = frames.filter { keys.contains($0.key) }
    }
}

import AppKit
import CoreGraphics
import Foundation
import SizeCore

/// Bridges AppKit's screens into the pure `ScreenInfo` model.
@MainActor
public enum ScreenProvider {
    /// The main screen defines the origin of the CG coordinate space, so every
    /// NS to CG conversion is mirrored through this frame.
    public static var mainScreenFrame: CGRect {
        NSScreen.screens.first?.frame ?? .zero
    }

    /// Screens ordered left-to-right, then top-to-bottom, so that "next
    /// display" means the same thing on every launch.
    public static func screens() -> [ScreenInfo] {
        NSScreen.screens
            .sorted { lhs, rhs in
                if lhs.frame.minX != rhs.frame.minX { return lhs.frame.minX < rhs.frame.minX }
                return lhs.frame.maxY > rhs.frame.maxY
            }
            .enumerated()
            .map { index, screen in
                ScreenInfo(
                    frame: screen.frame,
                    visibleFrame: screen.visibleFrame,
                    index: index
                )
            }
    }

    public static func screen(for windowFrame: CGRect) -> ScreenInfo? {
        let all = screens()
        guard !all.isEmpty else { return nil }
        guard let index = ScreenGeometry.screenIndex(containing: windowFrame, screens: all) else {
            return all.first
        }
        return all.first { $0.index == index } ?? all.first
    }
}

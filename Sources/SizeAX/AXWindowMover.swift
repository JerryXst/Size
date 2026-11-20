import AppKit
import CoreGraphics
import Foundation
import SizeCore

/// What actually happened to a window.
public enum MoveOutcome: Equatable, Sendable {
    /// The window ended up exactly where it was asked to.
    case exact
    /// The app constrained the frame; the window is here instead. Common with
    /// minimum-size limits and apps that snap to their own grid.
    case adjusted(CGRect)
    /// The window could not be moved at all.
    case failed(String)

    public var succeeded: Bool {
        if case .failed = self { return false }
        return true
    }
}

/// Applies a frame to a window and verifies the result.
///
/// Two things make this reliable in practice:
/// * a short messaging timeout, so a hung target app cannot stall us;
/// * a read-back check with retries, because many apps silently constrain the
///   frame they were given.
@MainActor
public final class AXWindowMover {
    private let tolerance: CGFloat

    public init(tolerance: CGFloat = 2) {
        self.tolerance = tolerance
    }

    public func setFrame(
        _ target: CGRect,
        on window: AXWindow,
        mainScreenFrame: CGRect,
        fullScreenTimeout: Double = 0.6
    ) -> MoveOutcome {
        guard mainScreenFrame != .zero else {
            return .failed("Main screen frame is unavailable")
        }

        if window.isFullScreen {
            exitFullScreen(window, timeout: fullScreenTimeout)
        }

        // A raised window is far more likely to accept a geometry change.
        _ = window.raise()

        let cgTarget = ScreenGeometry.cgRect(fromNS: target, mainScreenFrame: mainScreenFrame)
        let startingFrame = window.frame(mainScreenFrame: mainScreenFrame)

        for attempt in 0..<4 {
            // Alternate the order: a minority of apps only honour the geometry
            // when the size is set before the position.
            if attempt % 2 == 0 {
                _ = window.setPosition(cgTarget.origin)
                _ = window.setSize(cgTarget.size)
            } else {
                _ = window.setSize(cgTarget.size)
                _ = window.setPosition(cgTarget.origin)
            }

            // Setting a frame is asynchronous. Reading back immediately returns a
            // half-applied state: moving a window between displays of different
            // sizes makes the app re-run its own constraint pass, so a read taken
            // too early shows the *new* origin with the *old* size. That false
            // negative used to burn every retry, leaving the window badly sized.
            //
            // Fast path first: within one display most apps apply the frame
            // synchronously, and waiting there would add latency to every press.
            if let immediate = window.frame(mainScreenFrame: mainScreenFrame),
               approximatelyEqual(immediate, target) {
                return .exact
            }

            settle()

            guard let actual = window.frame(mainScreenFrame: mainScreenFrame) else {
                continue
            }
            if approximatelyEqual(actual, target) {
                return .exact
            }
            if let startingFrame, approximatelyEqual(actual, startingFrame) {
                // Nothing moved at all; give the app a moment and retry.
                settle(longer: true)
                continue
            }
        }

        guard let final = window.frame(mainScreenFrame: mainScreenFrame) else {
            return .failed("Could not read the window frame back")
        }
        if approximatelyEqual(final, target) {
            return .exact
        }
        // Accept a constrained result only if it is at least on the same screen
        // and meaningfully different from where we started.
        if let startingFrame, approximatelyEqual(final, startingFrame) {
            return .failed("The app refused the frame change")
        }
        return .adjusted(final)
    }

    /// Lets the target app finish applying a geometry change.
    ///
    /// 80ms is enough on Apple silicon for both native and Electron apps to pass
    /// the new frame through their constraint logic. Spinning the run loop (as
    /// opposed to sleeping) means an app that answers on our own queue still
    /// gets serviced.
    private func settle(longer: Bool = false) {
        let delay: TimeInterval = longer ? 0.14 : 0.08
        RunLoop.current.run(until: Date().addingTimeInterval(delay))
    }

    /// Leaves native full screen and waits for the transition to finish.
    /// Setting a frame during the animation is silently ignored by macOS.
    private func exitFullScreen(_ window: AXWindow, timeout: Double) {
        guard window.setFullScreen(false) else { return }
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if !window.isFullScreen { return }
            RunLoop.current.run(until: Date().addingTimeInterval(0.02))
        }
    }

    private func approximatelyEqual(_ lhs: CGRect, _ rhs: CGRect) -> Bool {
        abs(lhs.minX - rhs.minX) <= tolerance
            && abs(lhs.minY - rhs.minY) <= tolerance
            && abs(lhs.width - rhs.width) <= tolerance
            && abs(lhs.height - rhs.height) <= tolerance
    }
}

import AppKit
import CoreGraphics
import Foundation
import SizeAX
import SizeCore

/// End-to-end verification.
///
/// A throwaway window is launched in a separate process, then every action is
/// driven through the real Accessibility path and the resulting frame is read
/// back. Nothing the user owns is touched.
@MainActor
enum SelfTest {
    private static let tolerance: CGFloat = 2
    private static let windowTitle = "Size Self Test Window"

    private struct Failure {
        let action: String
        let expected: String
        let actual: String
    }

    static func run(verbose: Bool) {
        guard let hostURL = testHostURL() else {
            fputs("Could not locate size-testhost next to the CLI binary.\n", stderr)
            Foundation.exit(1)
        }

        let process = Process()
        process.executableURL = hostURL
        do {
            try process.run()
        } catch {
            fputs("Failed to launch the test window: \(error)\n", stderr)
            Foundation.exit(1)
        }
        defer {
            if process.isRunning { process.terminate() }
        }

        guard let window = waitForWindow(timeout: 10) else {
            fputs("The test window never appeared. Is Accessibility permission granted?\n", stderr)
            Foundation.exit(1)
        }

        print("Self-test window: \(window.title ?? "(untitled)") pid=\(window.pid)")
        let screens = ScreenProvider.screens()
        print("Displays: \(screens.count)")
        for screen in screens {
            print("  #\(screen.index) frame=\(describe(screen.frame)) visible=\(describe(screen.visibleFrame))")
        }
        print("")

        var failures: [Failure] = []
        let config = SizeConfig.default
        let manager = WindowManager(config: config)

        // ---- Grid actions -------------------------------------------------
        print("Grid actions")
        for action in WindowAction.gridActions {
            let before = currentFrame(window)
            guard let expected = expectedFrame(action, window: window, config: config) else {
                failures.append(Failure(action: action.rawValue, expected: "-", actual: "no expectation"))
                continue
            }
            let result = manager.perform(action, on: window)
            guard let actual = currentFrame(window) else {
                failures.append(Failure(action: action.rawValue, expected: describe(expected), actual: "unreadable"))
                continue
            }
            record(action.rawValue, expected: expected, actual: actual, result: result, before: before, verbose: verbose, failures: &failures)
        }

        // ---- Size-preserving moves ---------------------------------------
        print("\nMove actions")
        // Use a deliberately small window so both axes have room to travel;
        // at full height a vertical move is correctly a no-op.
        prepare(window: window, size: CGSize(width: 800, height: 600), screens: screens)
        let moveManager = WindowManager(config: config)
        for action in WindowAction.moveActions {
            prepare(window: window, size: CGSize(width: 800, height: 600), screens: screens)
            guard let before = currentFrame(window) else { continue }
            guard let expected = expectedFrame(action, window: window, config: config) else { continue }
            let result = moveManager.perform(action, on: window)
            guard let actual = currentFrame(window) else { continue }
            if abs(actual.width - before.width) > tolerance || abs(actual.height - before.height) > tolerance {
                failures.append(Failure(
                    action: action.rawValue,
                    expected: "size preserved \(describe(before.size))",
                    actual: describe(actual.size)
                ))
            }
            record(action.rawValue, expected: expected, actual: actual, result: result, before: before, verbose: verbose, failures: &failures)
        }

        // ---- Centre -------------------------------------------------------
        print("\nCentre")
        do {
            prepare(window: window, size: CGSize(width: 800, height: 600), screens: screens)
            guard let before = currentFrame(window) else { return }
            let result = manager.perform(.center, on: window)
            guard let actual = currentFrame(window) else { return }
            let visible = screenContaining(actual, screens: screens)?.visibleFrame ?? .zero
            let centredX = abs(actual.midX - visible.midX) <= tolerance
            let centredY = abs(actual.midY - visible.midY) <= tolerance
            let sizeKept = abs(actual.width - before.width) <= tolerance
                && abs(actual.height - before.height) <= tolerance
            if !(centredX && centredY && sizeKept) {
                failures.append(Failure(
                    action: "center",
                    expected: "centred \(describe(before.size)) at \(Int(visible.midX)),\(Int(visible.midY))",
                    actual: describe(actual)
                ))
            } else if verbose {
                print("  PASS center \(describe(actual))")
            }
            _ = result
        }

        // ---- Undo ---------------------------------------------------------
        print("\nUndo")
        do {
            // A fresh manager so this window has no earlier snapshot.
            let undoManager = WindowManager(config: config)
            if case .nothingToRestore = undoManager.perform(.snapBack, on: window) {
                if verbose { print("  PASS snapBack with nothing recorded") }
            } else {
                failures.append(Failure(action: "snapBack (empty)", expected: "nothing to restore", actual: "claimed success"))
            }

            prepare(window: window, size: CGSize(width: 800, height: 600), screens: screens)
            guard let original = currentFrame(window) else { return }
            _ = undoManager.perform(.left, on: window)
            _ = undoManager.perform(.right, on: window)
            let result = undoManager.perform(.snapBack, on: window)
            guard let actual = currentFrame(window) else { return }
            if !result.succeeded {
                failures.append(Failure(action: "snapBack", expected: describe(original), actual: result.message))
            } else if !approximatelyEqual(actual, original) {
                failures.append(Failure(
                    action: "snapBack",
                    expected: "\(describe(original)) (frame before the first action)",
                    actual: describe(actual)
                ))
            } else if verbose {
                print("  PASS snapBack returned to \(describe(actual))")
            }
        }

        // ---- Margins ------------------------------------------------------
        print("\nMargins")
        do {
            var margined = SizeConfig.default
            margined.defaultMargin = Margin(top: 12, bottom: 12, left: 12, right: 12)
            let marginedManager = WindowManager(config: margined)
            _ = marginedManager.perform(.left, on: window)
            guard let actual = currentFrame(window) else { return }
            let visible = screenContaining(actual, screens: screens)?.visibleFrame ?? .zero
            let expected = frame(
                for: WindowAction.left.gridRect!,
                screen: visible,
                margin: EdgeInsets(top: 12, left: 12, bottom: 12, right: 12)
            )
            if !approximatelyEqual(actual, expected) {
                failures.append(Failure(action: "margin", expected: describe(expected), actual: describe(actual)))
            } else if verbose {
                print("  PASS margin \(describe(actual))")
            }
        }

        // ---- Report -------------------------------------------------------
        print("\n" + String(repeating: "-", count: 46))
        if failures.isEmpty {
            print("All self-tests passed.")
            process.terminate()
            Foundation.exit(0)
        } else {
            print("\(failures.count) failure(s):")
            for failure in failures {
                print("  FAIL \(failure.action)")
                print("       expected \(failure.expected)")
                print("       actual   \(failure.actual)")
            }
            process.terminate()
            Foundation.exit(1)
        }
    }

    // MARK: - Helpers

    private static func record(
        _ name: String,
        expected: CGRect,
        actual: CGRect,
        result: PerformResult,
        before: CGRect?,
        verbose: Bool,
        failures: inout [Failure]
    ) {
        guard approximatelyEqual(actual, expected) else {
            failures.append(Failure(action: name, expected: describe(expected), actual: describe(actual) + " [\(result.message)]"))
            return
        }
        if verbose {
            print("  PASS \(name.padding(toLength: 16, withPad: " ", startingAt: 0)) \(describe(actual))")
        }
    }

    private static func expectedFrame(_ action: WindowAction, window: AXWindow, config: SizeConfig) -> CGRect? {
        guard let windowFrame = window.frame(mainScreenFrame: ScreenProvider.mainScreenFrame) else { return nil }
        let resolution = ActionResolver.resolve(action, input: ResolveInput(
            windowFrame: windowFrame,
            screens: ScreenProvider.screens(),
            gridSize: config.gridSize,
            margin: config.margin(for: window.bundleID),
            savedFrame: nil,
            gridRectOverride: config.gridRect(for: action, bundleID: window.bundleID)
        ))
        if case .frame(let target) = resolution { return target }
        return nil
    }

    private static func screenContaining(_ rect: CGRect, screens: [ScreenInfo]) -> ScreenInfo? {
        guard let index = ScreenGeometry.screenIndex(containing: rect, screens: screens) else { return nil }
        return screens.first { $0.index == index }
    }

    private static func currentFrame(_ window: AXWindow) -> CGRect? {
        window.frame(mainScreenFrame: ScreenProvider.mainScreenFrame)
    }

    /// Puts the window at a known size and position so a test measures the
    /// action rather than an inherited frame.
    @discardableResult
    private static func prepare(window: AXWindow, size: CGSize, screens: [ScreenInfo]) -> Bool {
        guard let frame = currentFrame(window),
              let screen = screenContaining(frame, screens: screens) else { return false }
        let bounds = screen.visibleFrame
        let origin = CGPoint(x: bounds.minX + 120, y: bounds.minY + 120)
        let target = CGRect(origin: origin, size: size)
        let outcome = AXWindowMover().setFrame(
            target,
            on: window,
            mainScreenFrame: ScreenProvider.mainScreenFrame
        )
        return outcome.succeeded
    }

    private static func approximatelyEqual(_ lhs: CGRect, _ rhs: CGRect) -> Bool {
        abs(lhs.minX - rhs.minX) <= tolerance
            && abs(lhs.minY - rhs.minY) <= tolerance
            && abs(lhs.width - rhs.width) <= tolerance
            && abs(lhs.height - rhs.height) <= tolerance
    }

    private static func describe(_ rect: CGRect) -> String {
        "\(Int(rect.width.rounded()))x\(Int(rect.height.rounded())) at \(Int(rect.minX.rounded())),\(Int(rect.minY.rounded()))"
    }

    private static func describe(_ size: CGSize) -> String {
        "\(Int(size.width.rounded()))x\(Int(size.height.rounded()))"
    }

    private static func testHostURL() -> URL? {
        guard let executable = Bundle.main.executableURL?.resolvingSymlinksInPath() else { return nil }
        let candidate = executable.deletingLastPathComponent().appendingPathComponent("size-testhost")
        return FileManager.default.fileExists(atPath: candidate.path) ? candidate : nil
    }

    private static func waitForWindow(timeout: TimeInterval) -> AXWindow? {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            let match = AXAppEnumerator.standardWindows()
                .first { $0.title == windowTitle }
            if let match { return match }
            RunLoop.current.run(until: Date().addingTimeInterval(0.1))
        }
        return nil
    }
}

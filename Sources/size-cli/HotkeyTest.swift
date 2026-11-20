import AppKit
import CoreGraphics
import Foundation
import SizeAX
import SizeCore

/// Verifies the *running app*, not the library: a synthetic ⌃⌥← is posted to the
/// system event stream, and the test window must land on the left half because
/// the app's Carbon hotkey handler picked the key up.
///
/// This is the closest thing to pressing the shortcut by hand, while still
/// leaving the user's own windows alone.
@MainActor
enum HotkeyTest {
    private static let windowTitle = "Size Self Test Window"

    static func run() {
        guard let hostURL = testHostURL() else {
            fputs("Could not locate size-testhost next to the CLI binary.\n", stderr)
            Foundation.exit(1)
        }
        guard isSizeAppRunning() else {
            fputs("Size.app is not running. Start it with: open build/Size.app\n", stderr)
            Foundation.exit(1)
        }
        // Wait until the app has installed its menu bar item and hotkeys.
        guard waitForSizeReady(timeout: 15) else {
            fputs("Size.app is running but never became ready.\n", stderr)
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
            fputs("The test window never appeared.\n", stderr)
            Foundation.exit(1)
        }

        // The app acts on the focused window of the frontmost app, so the test
        // window must genuinely be frontmost before the key is injected.
        // `activate()` only requests it, hence the wait.
        NSRunningApplication(processIdentifier: window.pid)?.activate()
        guard waitUntilFrontmost(pid: window.pid, timeout: 5) else {
            fputs("The test window never became the frontmost app.\n", stderr)
            process.terminate()
            Foundation.exit(1)
        }
        RunLoop.current.run(until: Date().addingTimeInterval(0.3))

        let screens = ScreenProvider.screens()
        guard let startFrame = window.frame(mainScreenFrame: ScreenProvider.mainScreenFrame) else {
            fputs("Could not read the test window frame.\n", stderr)
            Foundation.exit(1)
        }
        print("Before:        \(describe(startFrame))")

        let expectedLeft = frame(
            for: WindowAction.left.gridRect!,
            screen: screenContaining(startFrame, screens: screens)?.visibleFrame ?? .zero
        )

        guard postHotkey(keyCode: 123) else {
            fputs("Could not inject the keyboard event (Automation permission for System Events?).\n", stderr)
            Foundation.exit(1)
        }

        let moved = waitUntil(timeout: 3) {
            guard let current = window.frame(mainScreenFrame: ScreenProvider.mainScreenFrame) else { return false }
            return approximatelyEqual(current, expectedLeft)
        }

        guard moved, let afterLeft = window.frame(mainScreenFrame: ScreenProvider.mainScreenFrame) else {
            let actual = window.frame(mainScreenFrame: ScreenProvider.mainScreenFrame).map(describe) ?? "unreadable"
            print("FAIL ⌃⌥←")
            print("  expected \(describe(expectedLeft))")
            print("  actual   \(actual)")
            print("  The app is running but did not move the window.")
            process.terminate()
            Foundation.exit(1)
        }
        print("PASS ⌃⌥←        \(describe(afterLeft))")

        // Undo should restore the frame captured before the first action.
        _ = postHotkey(keyCode: 51) // ⌃⌥⌫
        let restored = waitUntil(timeout: 3) {
            guard let current = window.frame(mainScreenFrame: ScreenProvider.mainScreenFrame) else { return false }
            return approximatelyEqual(current, startFrame)
        }
        if restored, let afterUndo = window.frame(mainScreenFrame: ScreenProvider.mainScreenFrame) {
            print("PASS ⌃⌥⌫        \(describe(afterUndo))")
        } else {
            let actual = window.frame(mainScreenFrame: ScreenProvider.mainScreenFrame).map(describe) ?? "unreadable"
            print("FAIL ⌃⌥⌫")
            print("  expected \(describe(startFrame))")
            print("  actual   \(actual)")
            process.terminate()
            Foundation.exit(1)
        }

        print("\nHotkey test passed: the app moved a window from a real key event.")
        process.terminate()
        Foundation.exit(0)
    }

    // MARK: - Helpers

    /// Injects the shortcut through System Events.
    ///
    /// A direct `CGEvent.post(.cghidEventTap)` is refused on this machine even
    /// for an accessibility-trusted process, because event *injection* needs its
    /// own grant. System Events is already authorised to synthesise keys, so it
    /// is the reliable path for an automated test.
    private static func postHotkey(keyCode: CGKeyCode) -> Bool {
        let script = "tell application \"System Events\" to key code \(keyCode) using {control down, option down}"
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        process.arguments = ["-e", script]
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
        } catch {
            return false
        }
        process.waitUntilExit()
        return process.terminationStatus == 0
    }

    private static func isSizeAppRunning() -> Bool {
        NSWorkspace.shared.runningApplications.contains {
            $0.bundleIdentifier == "com.jerryxst.size"
        }
    }

    /// Ready means the app has written its runtime status file, which happens
    /// once the menu bar item and hotkeys are in place. Accessibility is not used
    /// here on purpose: some systems do not expose the status item to AX.
    private static func waitForSizeReady(timeout: TimeInterval) -> Bool {
        guard let pid = sizePID() else { return false }
        let deadline = Date().addingTimeInterval(timeout)
        repeat {
            if let status = readRuntimeStatus(), status.pid == pid {
                return true
            }
            RunLoop.current.run(until: Date().addingTimeInterval(0.2))
        } while Date() < deadline
        return false
    }

    private struct RuntimeStatusFile: Decodable {
        let pid: Int32
    }

    private static func readRuntimeStatus() -> RuntimeStatusFile? {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let url = base.appendingPathComponent("Size/status.json")
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(RuntimeStatusFile.self, from: data)
    }

    private static func sizePID() -> pid_t? {
        NSWorkspace.shared.runningApplications
            .first { $0.bundleIdentifier == "com.jerryxst.size" }?
            .processIdentifier
    }

    private static func waitUntilFrontmost(pid: pid_t, timeout: TimeInterval) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        repeat {
            if NSWorkspace.shared.frontmostApplication?.processIdentifier == pid {
                return true
            }
            // Ask again; a single request is easily lost while another app is
            // in the middle of taking focus.
            NSRunningApplication(processIdentifier: pid)?.activate()
            RunLoop.current.run(until: Date().addingTimeInterval(0.2))
        } while Date() < deadline
        return NSWorkspace.shared.frontmostApplication?.processIdentifier == pid
    }

    private static func waitUntil(timeout: TimeInterval, condition: () -> Bool) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return true }
            RunLoop.current.run(until: Date().addingTimeInterval(0.05))
        }
        return condition()
    }

    private static func waitForWindow(timeout: TimeInterval) -> AXWindow? {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if let match = AXAppEnumerator.standardWindows().first(where: { $0.title == windowTitle }) {
                return match
            }
            RunLoop.current.run(until: Date().addingTimeInterval(0.1))
        }
        return nil
    }

    private static func screenContaining(_ rect: CGRect, screens: [ScreenInfo]) -> ScreenInfo? {
        guard let index = ScreenGeometry.screenIndex(containing: rect, screens: screens) else { return nil }
        return screens.first { $0.index == index }
    }

    private static func approximatelyEqual(_ lhs: CGRect, _ rhs: CGRect) -> Bool {
        abs(lhs.minX - rhs.minX) <= 2
            && abs(lhs.minY - rhs.minY) <= 2
            && abs(lhs.width - rhs.width) <= 2
            && abs(lhs.height - rhs.height) <= 2
    }

    private static func describe(_ rect: CGRect) -> String {
        "\(Int(rect.width.rounded()))x\(Int(rect.height.rounded())) at \(Int(rect.minX.rounded())),\(Int(rect.minY.rounded()))"
    }

    private static func testHostURL() -> URL? {
        guard let executable = Bundle.main.executableURL?.resolvingSymlinksInPath() else { return nil }
        let candidate = executable.deletingLastPathComponent().appendingPathComponent("size-testhost")
        return FileManager.default.fileExists(atPath: candidate.path) ? candidate : nil
    }
}

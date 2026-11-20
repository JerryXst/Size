import AppKit
import ApplicationServices
import Foundation

/// Drives the app's own UI through Accessibility: opens the status menu, presses
/// "Settings…", and confirms the preferences window came up. This catches
/// problems the pure logic tests cannot see, such as a SwiftUI view that throws
/// while building.
@MainActor
enum UITest {
    static func run(_ arguments: [String]) {
        guard let pid = sizePID() else {
            fputs("Size.app is not running. Start it with: open build/Size.app\n", stderr)
            Foundation.exit(1)
        }

        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, 2.0)

        // Ask the app to open Settings through a distributed notification. This
        // works even when Accessibility cannot see the status item.
        DistributedNotificationCenter.default().postNotificationName(
            Notification.Name("com.jerryxst.size.openSettings"),
            object: nil,
            userInfo: nil,
            deliverImmediately: true
        )

        if let window = waitForWindow(of: app, titleContaining: "Settings", timeout: 6) {
            report(window: window)
        }

        // Fall back to driving the menu, for systems where the status item is
        // reachable through Accessibility.
        guard let statusItem = waitForStatusItem(of: app, timeout: 5) else {
            print("FAIL the settings window never opened and no status item was reachable")
            Foundation.exit(1)
        }

        // Open the menu. A status item toggles, so a menu left open by a
        // previous run makes the first press close it; retry a couple of times.
        guard pressWithRetry(statusItem) else {
            print("FAIL could not open the status menu")
            Foundation.exit(1)
        }
        RunLoop.current.run(until: Date().addingTimeInterval(0.5))

        guard let settingsItem = menuItem(in: statusItem, titleContaining: "Settings", timeout: 2.5) else {
            print("FAIL no Settings item in the menu")
            Foundation.exit(1)
        }

        openSettings(settingsItem, app: app)
    }

    private static func pressWithRetry(_ element: AXUIElement, attempts: Int = 3) -> Bool {
        for attempt in 0..<attempts {
            if AXUIElementPerformAction(element, kAXPressAction as CFString) == .success {
                return true
            }
            RunLoop.current.run(until: Date().addingTimeInterval(0.3 + Double(attempt) * 0.2))
        }
        return false
    }

    private static func openSettings(_ item: AXUIElement, app: AXUIElement) {
        guard AXUIElementPerformAction(item, kAXPressAction as CFString) == .success else {
            print("FAIL could not press Settings…")
            Foundation.exit(1)
        }
        RunLoop.current.run(until: Date().addingTimeInterval(1.0))

        guard let window = window(of: app, titleContaining: "Settings") else {
            print("FAIL the settings window did not appear")
            Foundation.exit(1)
        }
        report(window: window)
    }

    private static func waitForWindow(
        of app: AXUIElement,
        titleContaining needle: String,
        timeout: TimeInterval
    ) -> AXUIElement? {
        let deadline = Date().addingTimeInterval(timeout)
        repeat {
            if let window = window(of: app, titleContaining: needle) { return window }
            RunLoop.current.run(until: Date().addingTimeInterval(0.2))
        } while Date() < deadline
        return nil
    }

    private static func report(window: AXUIElement) {
        print("PASS settings window opened")

        let controls = descendants(of: window, limit: 400)
        print("  window contains \(controls.count) accessibility elements")
        let hasTabs = controls.contains { ($0.role ?? "") == (kAXTabGroupRole as String) }
        let hasButtons = controls.contains { ($0.role ?? "") == (kAXButtonRole as String) }
        if controls.count < 5 || !hasButtons {
            print("FAIL the settings window looks empty")
            close(window)
            Foundation.exit(1)
        }
        print("  tab group: \(hasTabs ? "present" : "absent")")
        print("  buttons:   \(hasButtons ? "present" : "absent")")

        close(window)
        print("\nUI test passed.")
        Foundation.exit(0)
    }

    // MARK: - Accessibility helpers

    private struct Element {
        let element: AXUIElement
        let role: String?
        let title: String?
    }

    private static func sizePID() -> pid_t? {
        NSWorkspace.shared.runningApplications
            .first { $0.bundleIdentifier == "com.jerryxst.size" }?
            .processIdentifier
    }

    private static func waitForStatusItem(of app: AXUIElement, timeout: TimeInterval) -> AXUIElement? {
        let deadline = Date().addingTimeInterval(timeout)
        repeat {
            if let item = statusItem(of: app) { return item }
            RunLoop.current.run(until: Date().addingTimeInterval(0.2))
        } while Date() < deadline
        return nil
    }
    private static func statusItem(of app: AXUIElement) -> AXUIElement? {
        var raw: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
            app,
            kAXExtrasMenuBarAttribute as CFString,
            &raw
        ) == .success, let raw else { return nil }
        let bar = unsafeDowncast(raw, to: AXUIElement.self)
        return children(of: bar).first
    }

    private static func menuItem(
        in statusItem: AXUIElement,
        titleContaining needle: String,
        timeout: TimeInterval = 0
    ) -> AXUIElement? {
        let deadline = Date().addingTimeInterval(timeout)
        repeat {
            var found: AXUIElement?
            walk(statusItem, depth: 0) { element in
                guard found == nil else { return }
                let role = stringAttribute(element, kAXRoleAttribute)
                guard role == (kAXMenuItemRole as String) else { return }
                let title = stringAttribute(element, kAXTitleAttribute) ?? ""
                if title.contains(needle) { found = element }
            }
            if let found { return found }
            if Date() >= deadline { return nil }
            RunLoop.current.run(until: Date().addingTimeInterval(0.1))
        } while true
    }

    private static func window(of app: AXUIElement, titleContaining needle: String) -> AXUIElement? {
        var raw: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
            app,
            kAXWindowsAttribute as CFString,
            &raw
        ) == .success, let windows = raw as? [AXUIElement] else { return nil }
        return windows.first {
            (stringAttribute($0, kAXTitleAttribute) ?? "").contains(needle)
        }
    }

    private static func descendants(of element: AXUIElement, limit: Int) -> [Element] {
        var result: [Element] = []
        walk(element, depth: 0) { child in
            guard result.count < limit else { return }
            result.append(Element(
                element: child,
                role: stringAttribute(child, kAXRoleAttribute),
                title: stringAttribute(child, kAXTitleAttribute)
            ))
        }
        return result
    }

    private static func walk(_ element: AXUIElement, depth: Int, visit: (AXUIElement) -> Void) {
        guard depth < 12 else { return }
        for child in children(of: element) {
            visit(child)
            walk(child, depth: depth + 1, visit: visit)
        }
    }

    private static func children(of element: AXUIElement) -> [AXUIElement] {
        var raw: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
            element,
            kAXChildrenAttribute as CFString,
            &raw
        ) == .success, let values = raw as? [AXUIElement] else { return [] }
        return values
    }

    private static func stringAttribute(_ element: AXUIElement, _ attribute: String) -> String? {
        var raw: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
            element,
            attribute as CFString,
            &raw
        ) == .success else { return nil }
        return raw as? String
    }

    private static func close(_ window: AXUIElement) {
        var raw: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
            window,
            kAXCloseButtonAttribute as CFString,
            &raw
        ) == .success, let raw else { return }
        let button = unsafeDowncast(raw, to: AXUIElement.self)
        _ = AXUIElementPerformAction(button, kAXPressAction as CFString)
        RunLoop.current.run(until: Date().addingTimeInterval(0.3))
    }
}

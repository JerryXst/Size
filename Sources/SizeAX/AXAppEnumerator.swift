@preconcurrency import ApplicationServices
import AppKit
import Foundation
import SizeCore

/// Enumerates windows that are safe to manage.
@MainActor
public enum AXAppEnumerator {
    /// Every standard window of every regular app except ourselves.
    ///
    /// Dialogs, sheets, popovers and panels are excluded by subrole: moving
    /// them would be surprising and often breaks the host app.
    public static func standardWindows(excluding ignoredBundleIDs: Set<String> = []) -> [AXWindow] {
        let ownPID = ProcessInfo.processInfo.processIdentifier
        return NSWorkspace.shared.runningApplications
            .filter { $0.activationPolicy == .regular }
            .filter { $0.processIdentifier != ownPID }
            .filter { app in
                guard let bundleID = app.bundleIdentifier else { return true }
                return !ignoredBundleIDs.contains(bundleID)
            }
            .flatMap { windows(for: $0) }
    }

    public static func windows(for app: NSRunningApplication) -> [AXWindow] {
        windows(forPID: app.processIdentifier)
    }

    public static func windows(forPID pid: pid_t) -> [AXWindow] {
        let element = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(element, 0.5)

        var raw: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXWindowsAttribute as CFString, &raw) == .success,
              let values = raw as? [AXUIElement] else { return [] }

        return values
            .map { AXWindow(pid: pid, element: $0) }
            .filter { $0.subrole == kAXStandardWindowSubrole as String }
    }

    /// The focused window of the frontmost app, which is what a global hotkey
    /// should act on.
    public static func focusedWindow() -> AXWindow? {
        let systemWide = AXUIElementCreateSystemWide()
        AXUIElementSetMessagingTimeout(systemWide, 0.5)

        var focusedApp: CFTypeRef?
        if AXUIElementCopyAttributeValue(
            systemWide,
            kAXFocusedApplicationAttribute as CFString,
            &focusedApp
        ) == .success, let appElement = focusedApp {
            let app = unsafeDowncast(appElement, to: AXUIElement.self)
            if let window = focusedWindow(of: app) {
                return window
            }
        }

        // Fall back to the frontmost regular app; the system-wide element is
        // occasionally unavailable right after a Space or app switch.
        guard let frontmost = NSWorkspace.shared.frontmostApplication,
              frontmost.activationPolicy == .regular,
              frontmost.processIdentifier != ProcessInfo.processInfo.processIdentifier else {
            return nil
        }
        let appElement = AXUIElementCreateApplication(frontmost.processIdentifier)
        AXUIElementSetMessagingTimeout(appElement, 0.5)
        return focusedWindow(of: appElement)
    }

    private static func focusedWindow(of appElement: AXUIElement) -> AXWindow? {
        var pid: pid_t = 0
        AXUIElementGetPid(appElement, &pid)

        var raw: CFTypeRef?
        if AXUIElementCopyAttributeValue(
            appElement,
            kAXFocusedWindowAttribute as CFString,
            &raw
        ) == .success, let value = raw {
            let element = unsafeDowncast(value, to: AXUIElement.self)
            let window = AXWindow(pid: pid, element: element)
            if window.subrole == kAXStandardWindowSubrole as String {
                return window
            }
        }

        // Some apps report no focused window; fall back to the first standard one.
        return windows(forPID: pid).first
    }
}

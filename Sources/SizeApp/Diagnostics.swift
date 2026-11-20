import AppKit
import Foundation
import SizeAX
import SizeCore
import SizeSpaces

/// `Size --diagnose` prints everything needed to tell whether the app can do
/// its job, then exits. Useful after granting Accessibility permission, and for
/// bug reports.
@MainActor
enum Diagnostics {
    static func run() -> Int32 {
        print("Size — diagnostics")
        print("  bundle id:    \(Bundle.main.bundleIdentifier ?? "(none — running unbundled)")")
        print("  version:      \(Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "dev")")
        print("  executable:   \(Bundle.main.executableURL?.path ?? "?")")

        let trusted = AXPermission.isTrusted
        print("  accessibility: \(trusted ? "granted" : "NOT GRANTED")")
        if !trusted {
            print("                Open System Settings › Privacy & Security › Accessibility")
            print("                and enable Size. Then run this again.")
        }

        let screens = ScreenProvider.screens()
        print("  displays:     \(screens.count)")
        for screen in screens {
            let f = screen.frame
            let v = screen.visibleFrame
            print("    #\(screen.index) frame \(Int(f.width))x\(Int(f.height)) at \(Int(f.minX)),\(Int(f.minY))"
                + "  visible \(Int(v.width))x\(Int(v.height))")
        }

        let config = ConfigStore.Store.load(from: ConfigStore.defaultURL)
        print("  config:       \(ConfigStore.defaultURL.path)")
        print("    grid:       \(config.gridColumns)x\(config.gridRows)")
        print("    gap:        \(Int(config.gap))")
        print("    margin:     top \(Int(config.defaultMargin.top))"
            + " bottom \(Int(config.defaultMargin.bottom))"
            + " left \(Int(config.defaultMargin.left))"
            + " right \(Int(config.defaultMargin.right))")
        print("    ignored:    \(config.ignoredBundleIDs.isEmpty ? "none" : config.ignoredBundleIDs.joined(separator: ", "))")
        print("    spaces:     \(config.enableSpaceActions ? "enabled" : "disabled")")

        print("  cross-Space:  \(SkyLightSpaceMover.isAvailable ? "available" : "unavailable on this system")")

        print("  hotkeys:")
        for action in WindowAction.allCases where action.isHotkeyable {
            let label = config.binding(for: action)?.display ?? "—"
            let custom = config.isCustomised(action) ? "  (customised)" : ""
            print("    \(label.padding(toLength: 8, withPad: " ", startingAt: 0)) \(action.displayName)\(custom)")
        }

        if trusted {
            let windows = AXAppEnumerator.standardWindows()
            print("  windows:      \(windows.count) controllable")
            for window in windows.prefix(8) {
                let name = window.appName ?? "?"
                print("    \(name) — \(window.title ?? "(untitled)")")
            }
        }

        return trusted ? 0 : 3
    }

    /// Drops the login item if one is registered, so repeated test runs do not
    /// leave launchd respawning the app behind the user's back.
    static func unregisterLoginItem() -> Int32 {
        let login = SMAppServiceBox()
        guard login.isSupported else {
            print("login items are not supported on this system")
            return 1
        }
        if !login.isEnabled {
            print("no login item registered")
            return 0
        }
        do {
            try login.unregister()
            print("login item removed")
            return 0
        } catch {
            print("could not remove login item: \(error.localizedDescription)")
            return 1
        }
    }
}

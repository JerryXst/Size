import AppKit
import ApplicationServices
import CoreGraphics
import Foundation
import SizeAX
import SizeCore
import SizeSpaces

/// Command line front end: inspect windows, apply single actions, and run the
/// automated end-to-end self-test against a throwaway window.
@main
@MainActor
struct SizeCLI {
    static func main() {
        let arguments = Array(CommandLine.arguments.dropFirst())

        switch arguments.first {
        case "list":
            guard requirePermission() else { return }
            list()
        case "apply":
            guard requirePermission() else { return }
            apply(Array(arguments.dropFirst()))
        case "set":
            guard requirePermission() else { return }
            setFrame(Array(arguments.dropFirst()))
        case "selftest":
            guard requirePermission() else { return }
            SelfTest.run(verbose: arguments.contains("--verbose"))
        case "hotkeytest":
            guard requirePermission() else { return }
            HotkeyTest.run()
        case "uitest":
            guard requirePermission() else { return }
            UITest.run(Array(arguments.dropFirst()))
        case "spaces":
            reportSpaces()
        case "inspect":
            guard requirePermission() else { return }
            inspect(Array(arguments.dropFirst()))
        case "menu":
            guard requirePermission() else { return }
            dumpMenu(Array(arguments.dropFirst()))
        case "action":
            performActionViaApp(Array(arguments.dropFirst()))
        default:
            usage()
        }
    }

    private static func usage() {
        print("""
        Usage:
          size-cli list                          List controllable windows
          size-cli apply --pid <pid> --action <a> Apply one action to a window
          size-cli set --pid <pid> --frame x,y,w,h  Place a window exactly
          size-cli selftest [--verbose]          Run the end-to-end self-test
          size-cli hotkeytest                    Drive the app with a real key event
          size-cli uitest                        Open the settings window via AX
          size-cli spaces                        Report cross-Space availability
          size-cli inspect --pid <pid>           Dump an app's status item tree
          size-cli menu --pid <pid>              Open and dump a status item menu
          size-cli action <name>                 Run an action on the focused window
        """)
    }

    /// Asks the running app to perform an action on the focused window, then
    /// reports what it did.
    ///
    /// The CLI deliberately does not move windows itself. As a bare tool it holds
    /// no Accessibility grant, so AX hands it degraded data — an app element in
    /// place of every window — and `kAXSubrole` comes back unsupported. The app
    /// does hold the grant, so the work is delegated to it over a distributed
    /// notification and the outcome is read back from its action log.
    private static func performActionViaApp(_ arguments: [String]) {
        guard let name = arguments.first(where: { !$0.hasPrefix("--") }),
              let action = WindowAction(rawValue: name) else {
            fputs("Unknown or missing action. Known actions:\n", stderr)
            for known in WindowAction.allCases {
                fputs("  \(known.rawValue)\n", stderr)
            }
            Foundation.exit(2)
        }

        var request: [String: String] = ["action": action.rawValue]
        if let pidIndex = arguments.firstIndex(of: "--pid"),
           pidIndex + 1 < arguments.count,
           let pid = pid_t(arguments[pidIndex + 1]) {
            request["pid"] = String(pid)
        }

        let logURL = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Logs/Size/actions.log")
        let before = ((try? String(contentsOf: logURL, encoding: .utf8)) ?? "").count

        DistributedNotificationCenter.default().postNotificationName(
            Notification.Name("com.jerryxst.size.performAction"),
            object: nil,
            userInfo: request,
            deliverImmediately: true
        )

        let deadline = Date().addingTimeInterval(5)
        while Date() < deadline {
            Thread.sleep(forTimeInterval: 0.15)
            let text = (try? String(contentsOf: logURL, encoding: .utf8)) ?? ""
            guard text.count > before else { continue }
            let added = String(text.dropFirst(before))
            if added.contains("action=\(action.rawValue)") {
                for line in added.split(separator: "\n") where line.contains("action=") {
                    print(line)
                }
                return
            }
        }

        fputs("No response from the app within 5s. Is Size.app running?\n", stderr)
        Foundation.exit(1)
    }

    private static func requirePermission() -> Bool {
        guard AXPermission.isTrusted else {
            fputs("Accessibility permission is required.\n", stderr)
            fputs("Grant it to your terminal in System Settings > Privacy & Security > Accessibility.\n", stderr)
            _ = AXPermission.requestPrompt()
            Foundation.exit(2)
        }
        return true
    }

    private static func list() {
        let names = Dictionary(
            uniqueKeysWithValues: NSWorkspace.shared.runningApplications.map {
                (Int($0.processIdentifier), $0.localizedName ?? "(unknown)")
            }
        )
        let mainFrame = ScreenProvider.mainScreenFrame
        let windows = AXAppEnumerator.standardWindows()
        guard !windows.isEmpty else {
            print("No controllable windows found.")
            return
        }
        for window in windows {
            let frame = window.frame(mainScreenFrame: mainFrame)
                .map { "\(Int($0.width))x\(Int($0.height)) at \(Int($0.minX)),\(Int($0.minY))" }
                ?? "unavailable"
            let app = names[Int(window.pid)] ?? window.appName ?? "(unknown)"
            print("pid=\(window.pid) app=\(app) title=\(window.title ?? "") frame=\(frame)")
        }
    }

    private static func apply(_ arguments: [String]) {
        guard let pidIndex = arguments.firstIndex(of: "--pid"),
              pidIndex + 1 < arguments.count,
              let pid = pid_t(arguments[pidIndex + 1]),
              let actionIndex = arguments.firstIndex(of: "--action"),
              actionIndex + 1 < arguments.count,
              let action = WindowAction(rawValue: arguments[actionIndex + 1]) else {
            usage()
            Foundation.exit(2)
        }

        guard let window = AXAppEnumerator.windows(forPID: pid).first else {
            fputs("No controllable standard window found for pid \(pid).\n", stderr)
            Foundation.exit(1)
        }

        let manager = WindowManager(config: ConfigStore.load())
        let result = manager.perform(action, on: window)
        print(result.message)
        if !result.succeeded {
            Foundation.exit(1)
        }
    }

    /// Places a window at an exact frame. Mirrors SizeUp's "move and resize to"
    /// command and lets a test put a window back where it found it.
    private static func setFrame(_ arguments: [String]) {
        guard let pidIndex = arguments.firstIndex(of: "--pid"),
              pidIndex + 1 < arguments.count,
              let pid = pid_t(arguments[pidIndex + 1]),
              let frameIndex = arguments.firstIndex(of: "--frame"),
              frameIndex + 1 < arguments.count else {
            usage()
            Foundation.exit(2)
        }

        let parts = arguments[frameIndex + 1]
            .split(separator: ",")
            .compactMap { Double($0.trimmingCharacters(in: .whitespaces)) }
        guard parts.count == 4 else {
            fputs("Expected --frame x,y,w,h\n", stderr)
            Foundation.exit(2)
        }

        guard let window = AXAppEnumerator.windows(forPID: pid).first else {
            fputs("No controllable standard window found for pid \(pid).\n", stderr)
            Foundation.exit(1)
        }

        let mainFrame = ScreenProvider.mainScreenFrame
        let target = CGRect(x: parts[0], y: parts[1], width: parts[2], height: parts[3])
        // Position first, then size: several apps clamp a move to the current
        // size, so growing before moving would push the window off-screen.
        let cgRect = ScreenGeometry.cgRect(fromNS: target, mainScreenFrame: mainFrame)
        _ = window.setPosition(cgRect.origin)
        _ = window.setSize(target.size)
        let settled = window.frame(mainScreenFrame: mainFrame)
        let matched = settled.map { abs($0.minX - target.minX) <= 2
            && abs($0.minY - target.minY) <= 2
            && abs($0.width - target.width) <= 2
            && abs($0.height - target.height) <= 2 } ?? false
        print(matched ? "placed at \(target)" : "the window refused the new frame (got \(settled.map { "\($0)" } ?? "nothing"))")
        if !matched {
            Foundation.exit(1)
        }
    }

    /// Presses a status item and prints the menu it opened, which verifies that
    /// the menu builds without crashing.
    private static func dumpMenu(_ arguments: [String]) {
        guard let pidIndex = arguments.firstIndex(of: "--pid"),
              pidIndex + 1 < arguments.count,
              let pid = pid_t(arguments[pidIndex + 1]) else {
            usage()
            Foundation.exit(2)
        }

        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, 2.0)
        guard let item = statusItem(of: app) else {
            print("No status item found for pid \(pid).")
            return
        }

        guard AXUIElementPerformAction(item, kAXPressAction as CFString) == .success else {
            print("Could not press the status item.")
            return
        }
        RunLoop.current.run(until: Date().addingTimeInterval(0.5))

        var children: CFTypeRef?
        if AXUIElementCopyAttributeValue(item, kAXChildrenAttribute as CFString, &children) == .success,
           let menus = children as? [AXUIElement],
           let menu = menus.first {
            printMenu(menu, depth: 0)
        } else {
            print("The menu did not open.")
        }

        // Pressing again closes it so the user's screen is left as we found it.
        _ = AXUIElementPerformAction(item, kAXPressAction as CFString)
    }

    private static func printMenu(_ element: AXUIElement, depth: Int) {
        var kids: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXChildrenAttribute as CFString, &kids) == .success,
              let items = kids as? [AXUIElement] else { return }

        for item in items {
            var title: CFTypeRef?
            var enabled: CFTypeRef?
            var role: CFTypeRef?
            AXUIElementCopyAttributeValue(item, kAXTitleAttribute as CFString, &title)
            AXUIElementCopyAttributeValue(item, kAXEnabledAttribute as CFString, &enabled)
            AXUIElementCopyAttributeValue(item, kAXRoleAttribute as CFString, &role)

            let label = (title as? String) ?? ""
            let roleName = (role as? String) ?? ""
            if roleName == (kAXMenuItemRole as String) {
                let isOn = (enabled as? Bool) ?? true
                print(String(repeating: "  ", count: depth) + (isOn ? "•" : "×") + " " + label)
            }
            // Menus hold their items inside an AXMenu child.
            var grandchildren: CFTypeRef?
            if AXUIElementCopyAttributeValue(item, kAXChildrenAttribute as CFString, &grandchildren) == .success,
               let subItems = grandchildren as? [AXUIElement], !subItems.isEmpty {
                printMenu(item, depth: depth + 1)
            }
        }
    }

    private static func statusItem(of app: AXUIElement) -> AXUIElement? {
        var raw: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
            app,
            kAXExtrasMenuBarAttribute as CFString,
            &raw
        ) == .success, let raw else { return nil }
        let bar = unsafeDowncast(raw, to: AXUIElement.self)
        var children: CFTypeRef?
        guard AXUIElementCopyAttributeValue(bar, kAXChildrenAttribute as CFString, &children) == .success,
              let items = children as? [AXUIElement] else { return nil }
        return items.first
    }

    private static func reportSpaces() {
        let available = SkyLightSpaceMover.isAvailable
        print("Cross-Space support: \(available ? "available" : "unavailable on this system")")
        if !available {
            print("SkyLight symbols are missing; Space actions will be skipped.")
        }
    }

    /// Prints an app's extras menu bar (status item) tree, which confirms a
    /// menu bar app actually installed its item.
    private static func inspect(_ arguments: [String]) {
        guard let pidIndex = arguments.firstIndex(of: "--pid"),
              pidIndex + 1 < arguments.count,
              let pid = pid_t(arguments[pidIndex + 1]) else {
            usage()
            Foundation.exit(2)
        }

        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, 1.0)

        var raw: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
            app,
            kAXExtrasMenuBarAttribute as CFString,
            &raw
        ) == .success, let raw else {
            print("No status item (extras menu bar) found for pid \(pid).")
            return
        }

        let bar = unsafeDowncast(raw, to: AXUIElement.self)
        var children: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
            bar,
            kAXChildrenAttribute as CFString,
            &children
        ) == .success, let items = children as? [AXUIElement] else {
            print("Status item present but has no children.")
            return
        }

        print("Status items: \(items.count)")
        for (index, item) in items.enumerated() {
            var title: CFTypeRef?
            var itemDescription: CFTypeRef?
            var role: CFTypeRef?
            AXUIElementCopyAttributeValue(item, kAXTitleAttribute as CFString, &title)
            AXUIElementCopyAttributeValue(item, kAXDescriptionAttribute as CFString, &itemDescription)
            AXUIElementCopyAttributeValue(item, kAXRoleAttribute as CFString, &role)
            let label = (itemDescription as? String) ?? (title as? String) ?? "(no label)"
            print("  [\(index)] role=\((role as? String) ?? "?") label=\(label)")
        }
    }
}

/// Reads the same config file the app uses, so CLI results match the app's.
enum ConfigStore {
    static var url: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent("Size/config.json")
    }

    static func load() -> SizeConfig {
        guard let data = try? Data(contentsOf: url) else { return .default }
        return SizeConfig.decode(from: data)
    }
}

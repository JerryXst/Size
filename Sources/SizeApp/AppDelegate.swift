import AppKit
import Combine
import Foundation
import SizeAX
import SizeCore
import SizeSpaces
@preconcurrency import UserNotifications

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private let store = ConfigStore()
    private lazy var manager = WindowManager(config: store.config)
    private lazy var settings = SettingsWindowController(
        store: store,
        failedHotkeys: { [weak self] in self?.hotkeys.failedActions ?? [] }
    )
    private let hotkeys = HotkeyCenter()

    private var statusMenu: StatusMenuController?
    private var cancellables: Set<AnyCancellable> = []
    private var pruneTimer: Timer?
    private var spaceMover: SkyLightSpaceMover?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSLog("Size: didFinishLaunching")
        NSApp.setActivationPolicy(.accessory)

        // Automation hook: `size-cli action <name>` posts this notification so
        // scripts and the test harness drive real layouts through the app's own
        // Accessibility grant. A bare command line tool has no grant of its own
        // and AX hands it degraded data (the app element where a window should
        // be), so it must never try to move windows itself.
        DistributedNotificationCenter.default().addObserver(
            forName: Notification.Name("com.jerryxst.size.performAction"),
            object: nil,
            queue: .main
        ) { note in
            // Pull out Sendable values before hopping to the main actor; capturing
            // the Notification itself across the boundary is a data race.
            let raw = note.userInfo?["action"] as? String
            let pidString = note.userInfo?["pid"] as? String
            Task { @MainActor in
                guard let raw, let action = WindowAction(rawValue: raw),
                      let delegate = NSApp.delegate as? AppDelegate else {
                    ActionLog.write("ipc: rejected bad action request \(raw ?? "nil")")
                    return
                }
                ActionLog.write("ipc: perform \(raw) pid=\(pidString ?? "focused")")
                delegate.handle(action, targetPID: pidString.flatMap { pid_t($0) })
            }
        }

        // Without Accessibility the app looks alive but every shortcut does
        // nothing, which reads as "the app is broken". Say so up front and put
        // the user in front of the switch that fixes it.
        if !AXPermission.isTrusted {
            ActionLog.write("starting without Accessibility permission")
            notify(
                title: "Size needs Accessibility access",
                body: "Enable Size in System Settings › Privacy & Security › Accessibility, then relaunch."
            )
            _ = AXPermission.requestPrompt()
        }

        if SkyLightSpaceMover.isAvailable {
            spaceMover = SkyLightSpaceMover()
            manager.setSpaceMover(spaceMover)
        }

        // Keep the manager and the hotkey table in step with the UI.
        store.$config
            .sink { [weak self] config in
                guard let self else { return }
                self.manager.update(config: config)
                self.registerHotkeys()
            }
            .store(in: &cancellables)

        statusMenu = StatusMenuController(
            perform: { [weak self] action in self?.handle(action) },
            canUndo: { [weak self] in
                guard let self, let window = AXAppEnumerator.focusedWindow() else { return false }
                return self.manager.canRestore(window: window)
            },
            spaceAvailable: { SkyLightSpaceMover.isAvailable },
            spacesEnabled: { [weak self] in self?.store.config.enableSpaceActions ?? false },
            openSettingsHandler: { [weak self] in self?.settings.show() },
            quit: { NSApp.terminate(nil) },
            frontmostApp: {
                guard let app = NSWorkspace.shared.frontmostApplication,
                      app.activationPolicy == .regular,
                      app.processIdentifier != ProcessInfo.processInfo.processIdentifier,
                      let bundleID = app.bundleIdentifier else { return nil }
                return (app.localizedName ?? bundleID, bundleID)
            },
            isDisabledForApp: { [weak self] bundleID in
                self?.store.config.isDisabled(bundleID: bundleID) ?? false
            },
            setDisabledForApp: { [weak self] bundleID, disabled in
                self?.store.update { config in
                    var override = config.overrides[bundleID] ?? AppOverride()
                    override.disabled = disabled
                    config.overrides[bundleID] = override
                }
            },
            hotkeyLabel: { [weak self] action in
                self?.store.config.binding(for: action)?.display
            }
        )

        registerHotkeys()
        let itemVisible = statusMenu?.isItemVisible == true
        NSLog("Size: menu bar item ready (visible=\(itemVisible))")
        RuntimeStatus.write(menuBarItemVisible: itemVisible)
        if !itemVisible {
            NSLog("Size: the menu bar is full, so the icon is hidden. Layout shortcuts still work.")
        }

        // Lets a script or the test harness open Settings without the status item.
        DistributedNotificationCenter.default().addObserver(
            forName: RuntimeStatus.openSettingsNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.settings.show() }
        }

        // Snapshots for closed windows would otherwise accumulate forever.
        // Kept infrequent because it walks the Accessibility tree.
        pruneTimer = Timer.scheduledTimer(withTimeInterval: 300, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.manager.pruneSnapshots() }
        }

        if !AXPermission.isTrusted {
            // The prompt only appears once per app identity, so also surface a
            // notification the user can act on.
            _ = AXPermission.requestPrompt()
            notify(
                title: "Size needs Accessibility access",
                body: "Open System Settings › Privacy & Security › Accessibility and enable Size."
            )
        }

        if store.config.enableSpaceActions && !SkyLightSpaceMover.isAvailable {
            store.update { $0.enableSpaceActions = false }
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        hotkeys.unregisterAll()
        pruneTimer?.invalidate()
        RuntimeStatus.clear()
    }

    // MARK: - Actions

    func handle(_ action: WindowAction, targetPID: pid_t? = nil) {
        ActionLog.write("handle \(action.rawValue) trusted=\(AXPermission.isTrusted) pid=\(targetPID.map(String.init) ?? "focused")")
        guard AXPermission.isTrusted else {
            notify(
                title: "Accessibility permission required",
                body: "Enable Size in System Settings › Privacy & Security › Accessibility."
            )
            _ = AXPermission.requestPrompt()
            return
        }

        // A caller may name a target explicitly (scripts, tests). Without one the
        // action applies to whatever the user is looking at.
        let explicitWindow = targetPID.flatMap { AXAppEnumerator.windows(forPID: $0).first }
        let result: PerformResult
        if let targetPID, explicitWindow == nil {
            ActionLog.write("action=\(action.rawValue) target=pid \(targetPID) result=No controllable window")
            return
        } else if let explicitWindow {
            result = manager.perform(action, on: explicitWindow)
        } else {
            result = manager.performOnFocusedWindow(action)
        }

        let frontmost = NSWorkspace.shared.frontmostApplication?.localizedName ?? "?"
        let focused = explicitWindow ?? AXAppEnumerator.focusedWindow()
        let target = focused.map { "\($0.appName ?? "?")/\($0.title ?? "untitled")" } ?? "none"
        ActionLog.write("action=\(action.rawValue) frontmost=\(frontmost) target=\(target) result=\(result.message)")
        if !result.succeeded {
            NSLog("Size: \(action.rawValue) failed -> \(result.message)")
        }
    }

    private func registerHotkeys() {
        hotkeys.apply(config: store.config) { [weak self] action in
            Task { @MainActor in self?.handle(action) }
        }
    }

    private func notify(title: String, body: String) {
        // UserNotifications needs a real bundle; when running the bare binary
        // from `swift run` we just log instead of crashing.
        guard Bundle.main.bundleIdentifier != nil else {
            NSLog("Size: \(title) — \(body)")
            return
        }
        let center = UNUserNotificationCenter.current()
        center.requestAuthorization(options: [.alert]) { granted, _ in
            guard granted else { return }
            let content = UNMutableNotificationContent()
            content.title = title
            content.body = body
            let request = UNNotificationRequest(
                identifier: UUID().uuidString,
                content: content,
                trigger: nil
            )
            center.add(request, withCompletionHandler: nil)
        }
    }
}

import AppKit
import Foundation
import SizeAX
import SizeCore
import SizeSpaces

/// Owns the menu bar item and rebuilds its menu each time it opens, so the
/// entries always reflect the current permission and display state.
@MainActor
final class StatusMenuController: NSObject, NSMenuDelegate {
    private let statusItem: NSStatusItem
    private let menu = NSMenu()
    private let showSettings: () -> Void
    private let quit: () -> Void
    private let spaceAvailable: () -> Bool
    private let spacesEnabled: () -> Bool
    private let onAction: (WindowAction) -> Void
    private let canUndoAction: () -> Bool
    private let frontmostApp: () -> (name: String, bundleID: String)?
    private let isDisabledForApp: (String) -> Bool
    private let setDisabledForApp: (String, Bool) -> Void
    private let hotkeyLabel: (WindowAction) -> String?

    init(
        perform: @escaping (WindowAction) -> Void,
        canUndo: @escaping () -> Bool,
        spaceAvailable: @escaping () -> Bool,
        spacesEnabled: @escaping () -> Bool,
        openSettingsHandler: @escaping () -> Void,
        quit: @escaping () -> Void,
        frontmostApp: @escaping () -> (name: String, bundleID: String)?,
        isDisabledForApp: @escaping (String) -> Bool,
        setDisabledForApp: @escaping (String, Bool) -> Void,
        hotkeyLabel: @escaping (WindowAction) -> String?
    ) {
        self.onAction = perform
        self.canUndoAction = canUndo
        self.spaceAvailable = spaceAvailable
        self.spacesEnabled = spacesEnabled
        self.showSettings = openSettingsHandler
        self.quit = quit
        self.frontmostApp = frontmostApp
        self.isDisabledForApp = isDisabledForApp
        self.setDisabledForApp = setDisabledForApp
        self.hotkeyLabel = hotkeyLabel

        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        super.init()

        if let button = statusItem.button {
            button.image = NSImage(
                systemSymbolName: "rectangle.split.2x1",
                accessibilityDescription: "Size"
            )
            button.image?.isTemplate = true
            button.toolTip = "Size — window manager"
        }

        menu.delegate = self
        statusItem.menu = menu
    }

    /// Whether macOS is actually showing the item. A crowded menu bar can hide
    /// it, in which case the hotkeys still work but the icon is missing.
    var isItemVisible: Bool {
        statusItem.isVisible && (statusItem.button?.window?.isVisible ?? false)
    }

    // MARK: - Menu construction

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()

        let trusted = AXPermission.isTrusted
        if !trusted {
            let warning = NSMenuItem(
                title: "⚠︎ Grant Accessibility permission…",
                action: #selector(openAccessibility),
                keyEquivalent: ""
            )
            warning.target = self
            menu.addItem(warning)
            menu.addItem(.separator())
        }

        let displays = ScreenProvider.screens()
        let header = NSMenuItem(
            title: displays.count > 1 ? "\(displays.count) displays" : "1 display",
            action: nil,
            keyEquivalent: ""
        )
        header.isEnabled = false
        menu.addItem(header)
        menu.addItem(.separator())

        addItem(to: menu, action: .left)
        addItem(to: menu, action: .right)
        addItem(to: menu, action: .up)
        addItem(to: menu, action: .down)
        menu.addItem(.separator())

        addItem(to: menu, action: .upperLeft)
        addItem(to: menu, action: .upperRight)
        addItem(to: menu, action: .lowerLeft)
        addItem(to: menu, action: .lowerRight)
        menu.addItem(.separator())

        addItem(to: menu, action: .fullScreen)
        addItem(to: menu, action: .center)

        let thirds = NSMenu()
        for action in [WindowAction.thirdLeft, .thirdCenter, .thirdRight, .thirdUpper, .thirdMiddle, .thirdLower] {
            addItem(to: thirds, action: action, hotkeys: false)
        }
        let thirdsItem = NSMenuItem(title: "Thirds", action: nil, keyEquivalent: "")
        thirdsItem.submenu = thirds
        menu.addItem(thirdsItem)

        let moves = NSMenu()
        for action in WindowAction.moveActions {
            addItem(to: moves, action: action, hotkeys: false)
        }
        let movesItem = NSMenuItem(title: "Move Without Resizing", action: nil, keyEquivalent: "")
        movesItem.submenu = moves
        menu.addItem(movesItem)

        menu.addItem(.separator())

        let undoItem = addItem(to: menu, action: .snapBack)
        undoItem.isEnabled = canUndoAction()

        if displays.count > 1 {
            let displaysMenu = NSMenu()
            addItem(to: displaysMenu, action: .prevMonitor)
            addItem(to: displaysMenu, action: .nextMonitor)
            let displaysItem = NSMenuItem(title: "Displays", action: nil, keyEquivalent: "")
            displaysItem.submenu = displaysMenu
            menu.addItem(displaysItem)
        }

        let spacesMenu = NSMenu()
        for action in WindowAction.spaceActions {
            addItem(to: spacesMenu, action: action, hotkeys: false)
        }
        let spacesItem = NSMenuItem(title: "Spaces", action: nil, keyEquivalent: "")
        spacesItem.submenu = spacesMenu
        if !spaceAvailable() {
            spacesItem.isEnabled = false
            spacesItem.toolTip = "Not supported on this version of macOS"
        } else if !spacesEnabled() {
            spacesItem.isEnabled = false
            spacesItem.toolTip = "Enable Space moves in Settings"
        }
        menu.addItem(spacesItem)

        menu.addItem(.separator())

        if let app = frontmostApp() {
            let title = "Disable Shortcuts in \(app.name)"
            let toggle = NSMenuItem(title: title, action: #selector(toggleDisabledForCurrentApp), keyEquivalent: "")
            toggle.target = self
            toggle.state = isDisabledForApp(app.bundleID) ? .on : .off
            menu.addItem(toggle)
            menu.addItem(.separator())
        }

        let preferences = NSMenuItem(title: "Settings…", action: #selector(openSettingsWindow), keyEquivalent: ",")
        preferences.target = self
        menu.addItem(preferences)

        let quitItem = NSMenuItem(title: "Quit Size", action: #selector(quitApp), keyEquivalent: "q")
        quitItem.target = self
        menu.addItem(quitItem)
    }

    @discardableResult
    private func addItem(to menu: NSMenu, action: WindowAction, hotkeys: Bool = true) -> NSMenuItem {
        var title = action.displayName
        if hotkeys, let label = hotkeyLabel(action) {
            title += "\t\(label)"
        }
        let item = NSMenuItem(title: title, action: #selector(handleAction(_:)), keyEquivalent: "")
        item.target = self
        item.representedObject = action.rawValue
        menu.addItem(item)
        return item
    }

    // MARK: - Actions

    @objc private func handleAction(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String,
              let action = WindowAction(rawValue: raw) else { return }
        onAction(action)
    }

    @objc private func toggleDisabledForCurrentApp() {
        guard let app = frontmostApp() else { return }
        let currentlyDisabled = isDisabledForApp(app.bundleID)
        setDisabledForApp(app.bundleID, !currentlyDisabled)
    }

    @objc private func openSettingsWindow() {
        showSettings()
    }

    @objc private func quitApp() {
        quit()
    }

    @objc private func openAccessibility() {
        let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!
        NSWorkspace.shared.open(url)
    }
}

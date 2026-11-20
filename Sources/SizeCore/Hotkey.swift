import Foundation

/// Carbon modifier masks, spelled out here so the core library stays free of a
/// Carbon dependency. The values are the stable `controlKey` / `optionKey` / …
/// constants from `Carbon.HIToolbox`.
public enum HotkeyModifiers {
    public static let command: UInt32 = 1 << 8
    public static let shift: UInt32 = 1 << 9
    public static let option: UInt32 = 1 << 11
    public static let control: UInt32 = 1 << 12

    /// Order in which modifiers are printed, matching the macOS convention.
    static let displayOrder: [(UInt32, String)] = [
        (control, "⌃"),
        (option, "⌥"),
        (shift, "⇧"),
        (command, "⌘")
    ]

    public static func describe(_ modifiers: UInt32) -> String {
        displayOrder
            .filter { modifiers & $0.0 != 0 }
            .map(\.1)
            .joined()
    }
}

/// A keyboard shortcut: a virtual key code plus modifiers.
public struct HotkeyBinding: Codable, Equatable, Hashable, Sendable {
    public var keyCode: UInt32
    public var modifiers: UInt32

    public init(keyCode: UInt32, modifiers: UInt32) {
        self.keyCode = keyCode
        self.modifiers = modifiers
    }

    /// e.g. "⌃⌥←". Used in menus and the settings list.
    public var display: String {
        HotkeyModifiers.describe(modifiers) + KeyCodeLabels.name(for: keyCode)
    }

    /// A shortcut with no modifier would swallow ordinary typing.
    public var isValid: Bool {
        modifiers & (HotkeyModifiers.control | HotkeyModifiers.option
            | HotkeyModifiers.command | HotkeyModifiers.shift) != 0
    }
}

/// Names for the virtual key codes the app uses. Only codes that can appear in
/// a shortcut are listed; anything else falls back to a numbered label.
public enum KeyCodeLabels {
    public static func name(for keyCode: UInt32) -> String {
        labels[keyCode] ?? "key\(keyCode)"
    }

    private static let labels: [UInt32: String] = [
        0: "A", 1: "S", 2: "D", 3: "F", 4: "H", 5: "G", 6: "Z", 7: "X",
        8: "C", 9: "V", 11: "B", 12: "Q", 13: "W", 14: "E", 15: "R",
        16: "Y", 17: "T",
        18: "1", 19: "2", 20: "3", 21: "4", 22: "6", 23: "5",
        24: "=", 25: "9", 26: "7", 27: "-", 28: "8", 29: "0",
        30: "]", 31: "O", 32: "U", 33: "[", 34: "I", 35: "P",
        37: "L", 38: "J", 39: "'", 40: "K", 41: ";", 42: "\\",
        43: ",", 44: "/", 45: "N", 46: "M", 47: ".", 50: "`",
        36: "↩", 48: "⇥", 49: "Space", 51: "⌫", 53: "⎋",
        123: "←", 124: "→", 125: "↓", 126: "↑",
        115: "Home", 116: "Page Up", 119: "End", 121: "Page Down",
        122: "F1", 120: "F2", 99: "F3", 118: "F4", 96: "F5", 97: "F6",
        98: "F7", 100: "F8", 101: "F9", 109: "F10", 103: "F11", 111: "F12"
    ]
}

/// The shortcuts the app ships with, chosen to stay clear of common system
/// combinations.
public enum DefaultHotkeys {
    private static let arrows = HotkeyModifiers.control | HotkeyModifiers.option

    public static let bindings: [(WindowAction, HotkeyBinding)] = [
        (.left, HotkeyBinding(keyCode: 123, modifiers: arrows)),
        (.right, HotkeyBinding(keyCode: 124, modifiers: arrows)),
        (.up, HotkeyBinding(keyCode: 126, modifiers: arrows)),
        (.down, HotkeyBinding(keyCode: 125, modifiers: arrows)),

        (.upperLeft, HotkeyBinding(keyCode: 32, modifiers: arrows)),
        (.upperRight, HotkeyBinding(keyCode: 34, modifiers: arrows)),
        (.lowerLeft, HotkeyBinding(keyCode: 38, modifiers: arrows)),
        (.lowerRight, HotkeyBinding(keyCode: 40, modifiers: arrows)),

        (.fullScreen, HotkeyBinding(keyCode: 36, modifiers: arrows)),
        (.center, HotkeyBinding(keyCode: 8, modifiers: arrows)),

        (.thirdLeft, HotkeyBinding(keyCode: 2, modifiers: arrows)),
        (.thirdCenter, HotkeyBinding(keyCode: 3, modifiers: arrows)),
        (.thirdRight, HotkeyBinding(keyCode: 5, modifiers: arrows)),

        (.prevMonitor, HotkeyBinding(keyCode: 43, modifiers: arrows)),
        (.nextMonitor, HotkeyBinding(keyCode: 47, modifiers: arrows)),

        (.snapBack, HotkeyBinding(keyCode: 51, modifiers: arrows))
    ]

    public static func binding(for action: WindowAction) -> HotkeyBinding? {
        bindings.first { $0.0 == action }?.1
    }
}

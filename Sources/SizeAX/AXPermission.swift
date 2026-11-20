@preconcurrency import ApplicationServices
import Foundation

@MainActor
public enum AXPermission {
    public static var isTrusted: Bool {
        AXIsProcessTrusted()
    }

    /// Requests that macOS show its Accessibility authorization guidance.
    @discardableResult
    public static func requestPrompt() -> Bool {
        AXIsProcessTrustedWithOptions([kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary)
    }
}

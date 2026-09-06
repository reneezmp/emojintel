import AppKit
import ApplicationServices
import Carbon.HIToolbox

enum Permissions {

    static var isTrusted: Bool { AXIsProcessTrusted() }

    @discardableResult
    static func requestTrust() -> Bool {
        let opts = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        return AXIsProcessTrustedWithOptions(opts)
    }

    static func openAccessibilitySettings() {
        let url = URL(string:
            "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!
        NSWorkspace.shared.open(url)
    }

    /// 0 = Do Nothing (what we want), 1 = Change Input Source, 2 = Show Emoji & Symbols,
    /// 3 = Start Dictation.
    static var fnUsageType: Int {
        (CFPreferencesCopyAppValue("AppleFnUsageType" as CFString,
                                   "com.apple.HIToolbox" as CFString) as? Int) ?? -1
    }

    static var fnIsFree: Bool { fnUsageType == 0 }

    static var fnUsageDescription: String {
        switch fnUsageType {
        case 0: return "Do Nothing"
        case 1: return "Change Input Source"
        case 2: return "Show Emoji & Symbols"
        case 3: return "Start Dictation"
        default: return "unset"
        }
    }

    static func openKeyboardSettings() {
        let url = URL(string: "x-apple.systempreferences:com.apple.Keyboard-Settings.extension")!
        NSWorkspace.shared.open(url)
    }

    /// When any app turns on Secure Input (password fields, some terminals), event taps
    /// receive nothing and AX text reads are blocked. Surfacing it makes an otherwise
    /// baffling dead period diagnosable.
    static var secureInputActive: Bool { IsSecureEventInputEnabled() }
}

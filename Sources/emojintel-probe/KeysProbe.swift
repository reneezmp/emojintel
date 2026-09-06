import AppKit
import Carbon.HIToolbox
import CoreGraphics

/// Listen-only event tap that logs keyDown and flagsChanged, so we can verify on this
/// specific machine that:
///   1. a lone `fn` produces a clean flagsChanged pair on keycode 63 (set, then cleared)
///   2. that still happens while AppleFnUsageType != 0  <-- the project's biggest unknown
///   3. a lone Right-Command produces the same shape on keycode 54
///   4. plain arrow keys carry maskSecondaryFn on keyDown but emit no flagsChanged
///   5. fn+arrow correctly disarms the "tapped alone" state machine
enum KeysProbe {

    private static var lastFlags: CGEventFlags = []
    /// Mirror of the real KeyTrigger state machine, so the probe validates the logic
    /// and not just the raw events.
    private static var armed: Int64? = nil
    private static var tap: CFMachPort?

    static let kFn: Int64 = 63          // kVK_Function
    static let kRightCmd: Int64 = 54    // kVK_RightCommand

    static func run() {
        guard requireTrust() else { return }

        let mask = (1 << CGEventType.keyDown.rawValue)
                 | (1 << CGEventType.keyUp.rawValue)
                 | (1 << CGEventType.flagsChanged.rawValue)

        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .listenOnly,                 // Phase 0 never swallows anything.
            eventsOfInterest: CGEventMask(mask),
            callback: { _, type, event, _ in
                KeysProbe.handle(type: type, event: event)
                return Unmanaged.passUnretained(event)
            },
            userInfo: nil
        ) else {
            print("""
            ✗ CGEvent.tapCreate returned nil.
              The process running this probe lacks Accessibility permission.
              Grant it to the app you launched this from (Terminal / iTerm), then re-run.
            """)
            return
        }
        self.tap = tap

        let src = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetCurrent(), src, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)

        reportFnSetting()
        print("""

        Listening. Try each of these, then Ctrl-C:

          1. tap `fn` alone            → expect flagsChanged kc=63 fn:ON then kc=63 fn:OFF, and "FIRE fn"
          2. hold fn and press →       → expect NO "FIRE" (must disarm)
          3. tap Right ⌘ alone         → expect flagsChanged kc=54 cmd:ON/OFF, and "FIRE rightCmd"
          4. press Right ⌘ + C         → expect NO "FIRE"
          5. press ← and → on their own→ note whether fn appears in their keyDown flags
          6. type a few normal letters → expect keyDown only, no flagsChanged

        ────────────────────────────────────────────────────────────────────────────
        """)
        CFRunLoopRun()
    }

    private static func handle(type: CGEventType, event: CGEvent) {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            print("!! tap disabled (\(type == .tapDisabledByTimeout ? "timeout" : "userInput")) — re-enabling")
            if let t = tap { CGEvent.tapEnable(tap: t, enable: true) }
            return
        }

        let kc = event.getIntegerValueField(.keyboardEventKeycode)
        let flags = event.flags

        switch type {
        case .keyDown:
            print("keyDown       kc=\(pad(kc)) \(describe(flags))\(nameFor(kc))")
            armed = nil                                    // any real key disarms

        case .keyUp:
            print("keyUp         kc=\(pad(kc)) \(describe(flags))\(nameFor(kc))")

        case .flagsChanged:
            let changed = flags.rawValue ^ lastFlags.rawValue
            let isDown = (flags.rawValue & changed) != 0   // a bit went 0 -> 1
            print("flagsChanged  kc=\(pad(kc)) \(describe(flags))\(nameFor(kc))  [\(isDown ? "DOWN" : "UP")]")

            if isDown {
                armed = (kc == kFn || kc == kRightCmd) ? kc : nil
            } else {
                if let a = armed, a == kc {
                    print("              ┗━ FIRE  \(kc == kFn ? "fn" : "rightCmd") tapped alone ✅")
                }
                armed = nil
            }
            lastFlags = flags

        default:
            break
        }
    }

    // MARK: - Helpers

    private static func pad(_ n: Int64) -> String {
        let s = String(n)
        return s.count >= 3 ? s : String(repeating: " ", count: 3 - s.count) + s
    }

    private static func nameFor(_ kc: Int64) -> String {
        switch kc {
        case kFn:       return "  (fn)"
        case kRightCmd: return "  (right ⌘)"
        case 55:        return "  (left ⌘)"
        case 56, 60:    return "  (shift)"
        case 58, 61:    return "  (option)"
        case 59, 62:    return "  (control)"
        case 57:        return "  (caps lock)"
        case 123:       return "  (←)"
        case 124:       return "  (→)"
        case 125:       return "  (↓)"
        case 126:       return "  (↑)"
        case 36:        return "  (return)"
        case 53:        return "  (esc)"
        default:        return ""
        }
    }

    private static func describe(_ f: CGEventFlags) -> String {
        var parts: [String] = []
        if f.contains(.maskSecondaryFn) { parts.append("fn") }
        if f.contains(.maskCommand)     { parts.append("cmd") }
        if f.contains(.maskShift)       { parts.append("shift") }
        if f.contains(.maskAlternate)   { parts.append("opt") }
        if f.contains(.maskControl)     { parts.append("ctrl") }
        if f.contains(.maskNumericPad)  { parts.append("numpad") }
        let s = parts.isEmpty ? "-" : parts.joined(separator: "+")
        return s.padding(toLength: max(22, s.count), withPad: " ", startingAt: 0)
    }

    static func reportFnSetting() {
        let raw = CFPreferencesCopyAppValue(
            "AppleFnUsageType" as CFString,
            "com.apple.HIToolbox" as CFString)
        let value = (raw as? Int) ?? -1
        let meaning: String
        switch value {
        case 0:  meaning = "Do Nothing  ← what Emojintel wants"
        case 1:  meaning = "Change Input Source"
        case 2:  meaning = "Show Emoji & Symbols"
        case 3:  meaning = "Start Dictation"
        default: meaning = "unset / unknown"
        }
        print("AppleFnUsageType = \(value)  (\(meaning))")
        if value != 0 {
            print("  → This probe run tells us whether fn still reaches an event tap")
            print("    while the system claims it. Run once now, then set")
            print("    System Settings → Keyboard → 'Press fn key to' → Do Nothing and re-run.")
        }
        if IsSecureEventInputEnabled() {
            print("⚠︎ Secure Input is currently ENABLED by some app — taps will see nothing.")
        }
    }

    static func requireTrust() -> Bool {
        if AXIsProcessTrusted() { return true }
        let opts = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(opts)
        print("""
        ✗ Accessibility permission not granted to the process running this probe.
          A system prompt should have appeared. Grant it, then re-run.
          (When run from a terminal, the permission belongs to the terminal app.)
        """)
        return false
    }
}

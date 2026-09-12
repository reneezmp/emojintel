import AppKit
import ApplicationServices

/// Replaces the word at `range` with an emoji.
///
/// The hard-won lesson here: several apps (Safari's fields, Electron text areas) return
/// `.success` from setting AXSelectedTextRange **without actually applying it**. Trusting
/// that return code means we then type the emoji at an unselected caret, so the word is
/// never removed. So we always SET, then READ BACK, and only treat the selection as real
/// if the read-back matches.
enum WordReplacer {

    /// - Parameter caret: absolute UTF-16 caret offset at trigger time. Needed because a
    ///   mid-word caret means we can't just backspace — we have to walk to the word's end
    ///   first, or we'd delete the characters before the caret instead of the word.
    @discardableResult
    static func replace(element: AXUIElement, range: CFRange, caret: Int, with emoji: String) -> String {

        // Terminals report a selection inside their scrollback and then send typed
        // characters to the tty instead, so the AX path "succeeds" and changes nothing —
        // the emoji lands beside the word rather than replacing it.
        if !frontmostIsTerminal(), selectRangeVerified(element, range) {
            // Tier 1 — direct AX write into the verified selection.
            if AXUIElementSetAttributeValue(element, AXAttr.selectedText, emoji as CFString) == .success,
               verifyGone(element, range: range, emoji: emoji) {
                return "tier1-ax"
            }
            // Tier 2 — the selection is real, so typing over it replaces exactly the word.
            postUnicode(emoji)
            return "tier2-unicode-over-selection"
        }

        // Tier 3 — the field would not take a selection. Walk the caret to the end of the
        // word, delete it a character at a time, then type the emoji.
        let wordEnd = range.location + range.length
        let forward = max(0, wordEnd - caret)
        for _ in 0..<forward { postKey(kRightArrow) }
        for _ in 0..<range.length { postKey(kBackspace) }
        postUnicode(emoji)
        return "tier3-backspace"
    }

    /// Sets the selection and confirms it actually took.
    private static func selectRangeVerified(_ element: AXUIElement, _ range: CFRange) -> Bool {
        var r = range
        guard let rv = AXValueCreate(.cfRange, &r) else { return false }
        guard AXUIElementSetAttributeValue(element, AXAttr.selectedRange, rv) == .success else {
            return false
        }
        guard let readBack = axRange(element, AXAttr.selectedRange) else { return false }
        return readBack.location == range.location && readBack.length == range.length
    }

    /// Confirms the AX write actually changed the text, rather than reporting success and
    /// doing nothing.
    private static func verifyGone(_ element: AXUIElement, range: CFRange, emoji: String) -> Bool {
        guard let now = axRange(element, AXAttr.selectedRange) else { return true }
        // After a successful replacement the selection collapses or moves off the old word.
        return !(now.location == range.location && now.length == range.length)
    }

    /// Keystroke-only replacement, for targets with no writable range (WebKit text
    /// markers). AXLeftWord gives the word *ending at* the caret, so backspaces land
    /// exactly on it.
    @discardableResult
    static func replaceByTyping(deleting length: Int, with emoji: String) -> String {
        for _ in 0..<length { postKey(kBackspace) }
        postUnicode(emoji)
        return "marker-backspace"
    }

    /// Opens the system emoji picker **in the frontmost app**.
    ///
    /// Not `NSApp.orderFrontCharacterPalette`: that opens the Character Viewer owned by
    /// Emojintel, and Emojintel is an accessory app with no focused text field — so the
    /// palette appears, and every emoji picked from it has nowhere to go. (It works fine
    /// from the custom-words editor, because there we genuinely are the active app with a
    /// text field focused. Same call, opposite outcome, depending on who's frontmost.)
    ///
    /// Synthesizing the system-wide "Show Emoji & Symbols" shortcut instead makes the app
    /// you're actually typing in open its own picker, so the insertion lands at the caret.
    /// That shortcut can be switched off in System Settings, which would make this do
    /// nothing — `Permissions.emojiHotkeyEnabled` detects it and the ☀️ menu says so.
    static func openEmojiPicker() {
        postKey(kSpace, flags: [.maskControl, .maskCommand])
    }

    // MARK: - Synthesized input

    private static let kRightArrow: CGKeyCode = 0x7C
    private static let kBackspace: CGKeyCode = 0x33
    private static let kSpace: CGKeyCode = 0x31

    private static func postUnicode(_ s: String) {
        guard let src = CGEventSource(stateID: .combinedSessionState),
              let down = CGEvent(keyboardEventSource: src, virtualKey: 0, keyDown: true),
              let up = CGEvent(keyboardEventSource: src, virtualKey: 0, keyDown: false)
        else { return }
        let utf16 = Array(s.utf16)
        down.keyboardSetUnicodeString(stringLength: utf16.count, unicodeString: utf16)
        up.keyboardSetUnicodeString(stringLength: utf16.count, unicodeString: utf16)
        down.post(tap: .cgAnnotatedSessionEventTap)
        up.post(tap: .cgAnnotatedSessionEventTap)
    }

    private static func postKey(_ keycode: CGKeyCode, flags: CGEventFlags = []) {
        guard let src = CGEventSource(stateID: .combinedSessionState),
              let down = CGEvent(keyboardEventSource: src, virtualKey: keycode, keyDown: true),
              let up = CGEvent(keyboardEventSource: src, virtualKey: keycode, keyDown: false)
        else { return }
        down.flags = flags
        up.flags = flags
        down.post(tap: .cgAnnotatedSessionEventTap)
        up.post(tap: .cgAnnotatedSessionEventTap)
    }
}

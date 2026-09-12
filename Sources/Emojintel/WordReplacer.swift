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
            postSequence(thenInsert: emoji)
            return "tier2-unicode-over-selection"
        }

        // FINDING: a failed read-back does NOT mean the selection failed to APPLY. Electron
        // reports a stale range and then honours the selection anyway, so tier 3 would
        // start backspacing into a field where the word is still selected — the first
        // backspace deletes the whole selection and every later one eats a character that
        // should have survived. "im completely shocked" became "im compl🤯": seven
        // backspaces removed thirteen characters, 7 + 6. So put the caret back before
        // falling through. This is the same lesson as the original one, one layer deeper:
        // the return code lies, and so does the read-back that was meant to catch it.
        if !frontmostIsTerminal() { collapseSelection(element, at: caret) }

        // Tier 3 — the field would not take a selection. Walk the caret to the end of the
        // word, delete it a character at a time, then type the emoji.
        //
        // The sequence is handed off to be posted at a survivable pace, so this returns the
        // tier it chose, not the tier having finished. See `postSequence`.
        let wordEnd = range.location + range.length
        let forward = max(0, wordEnd - caret)
        postSequence(keys: Array(repeating: kRightArrow, count: forward)
                         + Array(repeating: kBackspace, count: range.length),
                     thenInsert: emoji)
        return "tier3-backspace (right×\(forward), delete×\(range.length))"
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

    /// Collapses the selection to a bare caret, undoing a selection that may have been
    /// applied despite the read-back saying otherwise. Writing a zero-length range goes
    /// through the identical API that just set the selection, so if that one took silently,
    /// this one does too.
    @discardableResult
    private static func collapseSelection(_ element: AXUIElement, at caret: Int) -> Bool {
        var r = CFRange(location: caret, length: 0)
        guard let rv = AXValueCreate(.cfRange, &r) else { return false }
        AXUIElementSetAttributeValue(element, AXAttr.selectedRange, rv)
        guard let back = axRange(element, AXAttr.selectedRange) else { return false }
        return back.length == 0
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
        postSequence(keys: Array(repeating: kBackspace, count: length), thenInsert: emoji)
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
        postSequence(keys: [kSpace], flags: [.maskControl, .maskCommand])
    }

    // MARK: - Synthesized input

    private static let kRightArrow: CGKeyCode = 0x7C
    private static let kBackspace: CGKeyCode = 0x33
    private static let kSpace: CGKeyCode = 0x31

    /// Synthesized input is posted here, never on the main queue.
    ///
    /// The event tap's callback runs on the main run loop, so pacing keystrokes with sleeps
    /// on the main queue would stall the tap and trip kCGEventTapDisabledByTimeout — the
    /// exact failure the callback is written to avoid. A serial queue also stops two
    /// overlapping triggers from interleaving their keystrokes.
    private static let inputQueue = DispatchQueue(label: "dev.renee.emojintel.synthetic-input")

    /// Gap between synthesized keystrokes.
    ///
    /// FINDING: posted back-to-back with no gap, keystrokes are silently DROPPED by
    /// Chromium/Electron text areas. "shocked" lost four characters instead of seven and
    /// left "sho" sitting in front of the emoji — while the same path had worked for
    /// "wow", "nails" and "heart" minutes earlier. Identical code, different outcome, which
    /// is the signature of a race and not a miscount. Rich-text editors (Claude, Slack,
    /// Notion) apply each keystroke through an async state update, so deletions have to be
    /// paced to the editor rather than fired at CPU speed.
    private static let keystrokeGap: useconds_t = 8_000          // 8 ms

    /// Longer pause before the emoji goes in, so the editor has finished applying the
    /// deletions. Without it the insert lands mid-flush and can take neighbouring
    /// characters with it — the "replaced more than it should have" half of the same bug.
    private static let settleBeforeInsert: useconds_t = 25_000   // 25 ms

    /// Posts a paced key sequence, then optionally inserts text.
    ///
    /// One CGEventSource is built for the whole sequence rather than one per keystroke:
    /// cheaper, and it keeps every event in the sequence attributable to the same source.
    private static func postSequence(keys: [CGKeyCode] = [],
                                     flags: CGEventFlags = [],
                                     thenInsert text: String? = nil) {
        inputQueue.async {
            guard let src = CGEventSource(stateID: .combinedSessionState) else { return }
            for key in keys {
                post(src, key: key, flags: flags)
                usleep(keystrokeGap)
            }
            guard let text else { return }
            if !keys.isEmpty { usleep(settleBeforeInsert) }
            postUnicode(src, text)
        }
    }

    private static func post(_ src: CGEventSource, key: CGKeyCode, flags: CGEventFlags) {
        guard let down = CGEvent(keyboardEventSource: src, virtualKey: key, keyDown: true),
              let up = CGEvent(keyboardEventSource: src, virtualKey: key, keyDown: false)
        else { return }
        down.flags = flags
        up.flags = flags
        down.post(tap: .cgAnnotatedSessionEventTap)
        up.post(tap: .cgAnnotatedSessionEventTap)
    }

    private static func postUnicode(_ src: CGEventSource, _ s: String) {
        guard let down = CGEvent(keyboardEventSource: src, virtualKey: 0, keyDown: true),
              let up = CGEvent(keyboardEventSource: src, virtualKey: 0, keyDown: false)
        else { return }
        let utf16 = Array(s.utf16)
        down.keyboardSetUnicodeString(stringLength: utf16.count, unicodeString: utf16)
        up.keyboardSetUnicodeString(stringLength: utf16.count, unicodeString: utf16)
        down.post(tap: .cgAnnotatedSessionEventTap)
        up.post(tap: .cgAnnotatedSessionEventTap)
    }
}

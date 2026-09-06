import AppKit
import ApplicationServices

/// Replaces the word at `range` with an emoji, walking a three-tier ladder.
///
/// The original spec had only two tiers and clobbered the clipboard permanently. Phase 0
/// showed why a middle tier is needed: several apps expose a readable AXValue but reject
/// AX writes, and pasting is both slower and destructive.
enum WordReplacer {

    @discardableResult
    static func replace(element: AXUIElement, range: CFRange, with emoji: String) -> String {
        var r = range
        let rangeValue = AXValueCreate(.cfRange, &r)

        // Tier 1 — direct AX write. Instant, no synthesized input, no side effects.
        if let rv = rangeValue,
           AXUIElementSetAttributeValue(element, AXAttr.selectedRange, rv) == .success {
            if AXUIElementSetAttributeValue(element, AXAttr.selectedText, emoji as CFString) == .success {
                return "tier1-ax"
            }
            // The selection is now the word, so typing over it replaces exactly it.
            postUnicode(emoji)
            return "tier2-unicode"
        }

        // Tier 2b — the field refused the range too: delete the word by hand, then type.
        // Only safe because we know the caret sits at the word's end.
        for _ in 0..<range.length { postKey(0x33) }          // kVK_Delete (backspace)
        postUnicode(emoji)
        return "tier2-backspace"
    }

    /// Tier 3 — clipboard paste. Last resort, and it SAVES AND RESTORES the previous
    /// pasteboard contents; silently eating whatever the user had copied is not acceptable.
    static func replaceViaPaste(element: AXUIElement, range: CFRange, with emoji: String) -> String {
        var r = range
        if let rv = AXValueCreate(.cfRange, &r) {
            AXUIElementSetAttributeValue(element, AXAttr.selectedRange, rv)
        }
        let pb = NSPasteboard.general
        let saved = pb.pasteboardItems?.compactMap { item -> [NSPasteboard.PasteboardType: Data] in
            var d: [NSPasteboard.PasteboardType: Data] = [:]
            for type in item.types { if let v = item.data(forType: type) { d[type] = v } }
            return d
        } ?? []

        pb.clearContents()
        pb.setString(emoji, forType: .string)
        postKey(0x09, flags: .maskCommand)                    // kVK_ANSI_V

        // Restore after the paste has had time to land.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
            pb.clearContents()
            let items: [NSPasteboardItem] = saved.map { dict in
                let item = NSPasteboardItem()
                for (t, d) in dict { item.setData(d, forType: t) }
                return item
            }
            if !items.isEmpty { pb.writeObjects(items) }
        }
        return "tier3-paste"
    }

    // MARK: - Synthesized input

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

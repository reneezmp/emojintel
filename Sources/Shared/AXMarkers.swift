import AppKit
import ApplicationServices

/// WebKit text-marker support, for elements that expose no AXSelectedTextRange.
///
/// Mail's compose area (and Safari's rich-text/contenteditable areas) focus an AXWebArea.
/// It has no AXSelectedTextRange at all — WebKit represents positions as opaque "text
/// markers" instead. Probing Mail on Ventura showed the full chain is available and works:
///
///     AXSelectedTextMarkerRange              -> the caret, as a marker range
///     AXStartTextMarkerForTextMarkerRange    -> its start marker
///     AXLeftWordTextMarkerRangeForTextMarker -> the word ending at that marker
///     AXStringForTextMarkerRange             -> "hello"
///     AXBoundsForTextMarkerRange             -> (156,266 33x14)
///
/// Markers are opaque and can't be written to, so replacement here is always by
/// synthesized keystrokes. That's fine: AXLeftWord gives the word *ending at* the caret,
/// so the caret is already where backspaces need it.
enum AXMarkers {

    static func isMarkerBased(_ el: AXUIElement) -> Bool {
        axCopy(el, "AXSelectedTextMarkerRange" as CFString) != nil
            && axRange(el, AXAttr.selectedRange) == nil
    }

    private static func param(_ el: AXUIElement, _ attr: String, _ p: CFTypeRef) -> CFTypeRef? {
        var out: CFTypeRef?
        guard AXUIElementCopyParameterizedAttributeValue(el, attr as CFString, p, &out) == .success
        else { return nil }
        return out
    }

    /// The word ending at the caret, and its rect in Cocoa coordinates.
    static func wordAtCaret(_ el: AXUIElement) -> (word: String, rect: CGRect?)? {
        guard let selection = axCopy(el, "AXSelectedTextMarkerRange" as CFString) else { return nil }

        // A non-empty selection means the user highlighted something; use it as the word.
        if let selected = param(el, "AXStringForTextMarkerRange", selection) as? String,
           !selected.isEmpty {
            return (selected, rect(el, forMarkerRange: selection))
        }

        guard let start = param(el, "AXStartTextMarkerForTextMarkerRange", selection),
              let wordRange = param(el, "AXLeftWordTextMarkerRangeForTextMarker", start),
              let raw = param(el, "AXStringForTextMarkerRange", wordRange) as? String
        else { return nil }

        // If the "word" ends in whitespace, the caret is past a word boundary rather than
        // at a word's end — backspacing would eat the space and part of the word.
        guard raw == raw.trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty else {
            return nil
        }
        guard raw.rangeOfCharacter(from: .alphanumerics) != nil else { return nil }

        return (raw, rect(el, forMarkerRange: wordRange))
    }

    private static func rect(_ el: AXUIElement, forMarkerRange range: CFTypeRef) -> CGRect? {
        guard let v = param(el, "AXBoundsForTextMarkerRange", range),
              CFGetTypeID(v) == AXValueGetTypeID() else { return nil }
        var r = CGRect.zero
        guard AXValueGetValue((v as! AXValue), .cgRect, &r), isUsableCaretRect(r),
              let primary = NSScreen.screens.first else { return nil }
        let H = primary.frame.height
        return CGRect(x: r.origin.x, y: H - r.origin.y - r.height, width: r.width, height: r.height)
    }
}

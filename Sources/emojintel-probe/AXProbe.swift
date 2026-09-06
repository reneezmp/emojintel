import AppKit
import ApplicationServices

/// Polls the focused text element and reports everything Emojintel needs from it:
/// route, role, read path, the parsed word, the word's screen rect, and how long the
/// whole read took.
///
/// Timing matters: this work happens inside the event-tap callback, and a slow callback
/// trips kCGEventTapDisabledByTimeout, which silently kills the tap. Anything
/// consistently over ~10ms is a problem.
enum AXProbe {

    static func run(attemptWrite: Bool) {
        guard KeysProbe.requireTrust() else { return }

        print("""
        Polling every 1.5s. Click into an app, type a word, leave the caret in or just
        after it. Prints only on change. Ctrl-C to stop.
        \(attemptWrite ? "\n⚠︎  --write is ON: each poll will try to REPLACE the word with 🎉.\n" : "")
        ────────────────────────────────────────────────────────────────────────────────
        """)

        var last = ""
        Timer.scheduledTimer(withTimeInterval: 1.5, repeats: true) { _ in
            let line = sample(attemptWrite: attemptWrite)
            if line != last { print(line); last = line }
        }
        RunLoop.current.run()
    }

    private static func sample(attemptWrite: Bool) -> String {
        let t0 = DispatchTime.now()
        let appName = NSWorkspace.shared.frontmostApplication?.localizedName ?? "?"

        guard let (element, role, route) = focusedTextElement() else {
            return "[\(appName)] no focused element  → silent no-op (correct)"
        }
        var out = "[\(appName)] \(role) via \(route)"

        guard let ctx = readTextContext(element) else {
            return out + "  ✗ no readable text (no AXSelectedTextRange, or buffer too large)"
        }
        out += "  read=\(ctx.readPath) chars=\(ctx.totalChars) win=\(ctx.window.length)"

        guard let (word, range) = wordAtCaret(ctx) else {
            return out + "  · no word at caret"
        }
        out += "  ✓ \"\(word)\" @(\(range.location),\(range.length))"

        if let raw = axBounds(element, range: range) {
            if isUsableCaretRect(raw) {
                out += String(format: "  ✓ rect=(%.0f,%.0f %.0fx%.0f)",
                              raw.origin.x, raw.origin.y, raw.width, raw.height)
            } else {
                out += String(format: "  ✗ DEGENERATE rect=(%.0f,%.0f %.0fx%.0f) → mouse fallback",
                              raw.origin.x, raw.origin.y, raw.width, raw.height)
            }
        } else {
            out += "  ✗ no rect (AXBoundsForRange unsupported) → mouse fallback"
        }

        if attemptWrite { out += "  write:" + tryWrite(element: element, range: range) }

        let ms = Double(DispatchTime.now().uptimeNanoseconds - t0.uptimeNanoseconds) / 1_000_000
        out += String(format: "  [%.1fms%@]", ms, ms > 10 ? " ⚠️ SLOW" : "")
        return out
    }

    /// Tier 1 of the replacement ladder (direct AX write). Tiers 2 and 3 synthesize
    /// input, so they're exercised by the real app rather than a polling probe.
    private static func tryWrite(element: AXUIElement, range: CFRange) -> String {
        var r = range
        guard let rv = AXValueCreate(.cfRange, &r) else { return " ✗(range alloc)" }
        let a = AXUIElementSetAttributeValue(element, AXAttr.selectedRange, rv)
        guard a == .success else { return " ✗ set-range \(FocusProbe.describe(a))" }
        let b = AXUIElementSetAttributeValue(element, AXAttr.selectedText, "🎉" as CFString)
        guard b == .success else { return " ✗ set-text \(FocusProbe.describe(b)) → needs tier 2" }
        return " ✓ tier1"
    }
}

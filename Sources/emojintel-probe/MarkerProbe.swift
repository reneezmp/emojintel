import AppKit
import ApplicationServices

/// Dumps everything the focused element exposes — plain attributes AND parameterized
/// ones — so WebKit support can be written against what Mail actually offers rather than
/// against a remembered API.
///
/// Mail and Safari rich-text areas focus an AXWebArea, which has no AXSelectedTextRange.
/// WebKit instead uses opaque "text markers". This prints which of those are present.
enum MarkerProbe {

    static func run() {
        guard KeysProbe.requireTrust() else { return }
        print("""
        Click into Mail's compose window (or any rich text area) and type a word.
        Samples once every 3s, printing only on change. Ctrl-C to stop.
        ────────────────────────────────────────────────────────────────────────────────
        """)
        var last = ""
        Timer.scheduledTimer(withTimeInterval: 3.0, repeats: true) { _ in
            let s = sample()
            if s != last { print(s); last = s }
        }
        RunLoop.current.run()
    }

    private static func sample() -> String {
        let app = NSWorkspace.shared.frontmostApplication?.localizedName ?? "?"
        guard let (el, role, route) = focusedTextElement() else { return "[\(app)] no focused element" }

        var out = "── [\(app)] role=\(role) via \(route)\n"

        var names: CFArray?
        if AXUIElementCopyAttributeNames(el, &names) == .success, let list = names as? [String] {
            out += "   attributes:\n"
            for chunk in stride(from: 0, to: list.sorted().count, by: 4) {
                let row = Array(list.sorted()[chunk..<min(chunk + 4, list.count)])
                out += "     " + row.joined(separator: "  ") + "\n"
            }
        } else {
            out += "   attributes: <none>\n"
        }

        var pnames: CFArray?
        if AXUIElementCopyParameterizedAttributeNames(el, &pnames) == .success,
           let list = pnames as? [String], !list.isEmpty {
            out += "   parameterized:\n"
            for chunk in stride(from: 0, to: list.sorted().count, by: 3) {
                let row = Array(list.sorted()[chunk..<min(chunk + 3, list.count)])
                out += "     " + row.joined(separator: "  ") + "\n"
            }
        } else {
            out += "   parameterized: <none>\n"
        }

        // Walk the WebKit text-marker chain, if it's there.
        out += "   ── marker chain ──\n"
        guard let selRange = axCopy(el, "AXSelectedTextMarkerRange" as CFString) else {
            return out + "     AXSelectedTextMarkerRange: absent → markers not available here\n"
        }
        out += "     AXSelectedTextMarkerRange: present\n"

        func param(_ attr: String, _ p: CFTypeRef) -> CFTypeRef? {
            var o: CFTypeRef?
            let e = AXUIElementCopyParameterizedAttributeValue(el, attr as CFString, p, &o)
            if e != .success { out += "     \(attr) → \(FocusProbe.describe(e))\n"; return nil }
            return o
        }

        if let s = param("AXStringForTextMarkerRange", selRange) as? String {
            out += "     AXStringForTextMarkerRange → \"\(s)\" (selection)\n"
        }
        guard let start = param("AXStartTextMarkerForTextMarkerRange", selRange) else { return out }
        out += "     AXStartTextMarkerForTextMarkerRange: ok\n"

        if let wordRange = param("AXLeftWordTextMarkerRangeForTextMarker", start) {
            out += "     AXLeftWordTextMarkerRangeForTextMarker: ok\n"
            if let w = param("AXStringForTextMarkerRange", wordRange) as? String {
                out += "     ✓ WORD = \"\(w)\"\n"
            }
            if let b = param("AXBoundsForTextMarkerRange", wordRange),
               CFGetTypeID(b) == AXValueGetTypeID() {
                var r = CGRect.zero
                if AXValueGetValue((b as! AXValue), .cgRect, &r) {
                    out += String(format: "     ✓ RECT = (%.0f,%.0f %.0fx%.0f)\n",
                                  r.origin.x, r.origin.y, r.width, r.height)
                }
            }
        }
        return out
    }
}

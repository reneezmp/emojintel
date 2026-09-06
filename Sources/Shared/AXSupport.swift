import AppKit
import ApplicationServices

/// AX attribute names.
///
/// NOTE: `AXAttributeConstants.h` in the Command Line Tools SDK is documentation-only —
/// it contains zero `#define`s, and `kAXBoundsForRangeParameterizedAttribute` appears
/// nowhere in the SDK at all. The AX API is string-keyed, so we declare our own.
enum AXAttr {
    static let focusedUIElement = "AXFocusedUIElement"   as CFString
    static let focusedApp       = "AXFocusedApplication" as CFString
    static let role             = "AXRole"               as CFString
    static let value            = "AXValue"              as CFString
    static let selectedText     = "AXSelectedText"       as CFString
    static let selectedRange    = "AXSelectedTextRange"  as CFString
    static let numberOfChars    = "AXNumberOfCharacters" as CFString
    static let children         = "AXChildren"           as CFString
    static let boundsForRange   = "AXBoundsForRange"     as CFString  // parameterized
    static let stringForRange   = "AXStringForRange"     as CFString  // parameterized
    static let manualAccess     = "AXManualAccessibility" as CFString
}

enum AXRole {
    static let textLike: Set<String> = ["AXTextField", "AXTextArea", "AXComboBox", "AXSearchField"]
}

/// How much text around the caret we read when the element supports a windowed read.
/// Words are short; this is generous. See `readTextContext` for why it matters.
let kContextRadius = 96

// MARK: - Generic attribute access

func axCopy(_ element: AXUIElement, _ attr: CFString) -> CFTypeRef? {
    var out: CFTypeRef?
    return AXUIElementCopyAttributeValue(element, attr, &out) == .success ? out : nil
}

func axString(_ element: AXUIElement, _ attr: CFString) -> String? {
    guard let v = axCopy(element, attr), CFGetTypeID(v) == CFStringGetTypeID() else { return nil }
    return (v as! CFString) as String
}

func axElement(_ element: AXUIElement, _ attr: CFString) -> AXUIElement? {
    guard let v = axCopy(element, attr), CFGetTypeID(v) == AXUIElementGetTypeID() else { return nil }
    return (v as! AXUIElement)
}

func axInt(_ element: AXUIElement, _ attr: CFString) -> Int? {
    guard let v = axCopy(element, attr), CFGetTypeID(v) == CFNumberGetTypeID() else { return nil }
    var n = 0
    CFNumberGetValue((v as! CFNumber), .nsIntegerType, &n)
    return n
}

func axChildren(_ element: AXUIElement) -> [AXUIElement] {
    guard let v = axCopy(element, AXAttr.children), CFGetTypeID(v) == CFArrayGetTypeID() else { return [] }
    return (v as! CFArray) as? [AXUIElement] ?? []
}

func axRange(_ element: AXUIElement, _ attr: CFString) -> CFRange? {
    guard let v = axCopy(element, attr), CFGetTypeID(v) == AXValueGetTypeID() else { return nil }
    let axv = v as! AXValue
    guard AXValueGetType(axv) == .cfRange else { return nil }
    var range = CFRange()
    guard AXValueGetValue(axv, .cfRange, &range) else { return nil }
    return range
}

private func axParameterized(_ el: AXUIElement, _ attr: CFString, range: CFRange) -> CFTypeRef? {
    var r = range
    guard let param = AXValueCreate(.cfRange, &r) else { return nil }
    var out: CFTypeRef?
    guard AXUIElementCopyParameterizedAttributeValue(el, attr, param, &out) == .success else { return nil }
    return out
}

/// Screen rect (top-left origin, Quartz coordinates) for a text range.
///
/// We always ask for a *non-empty* range — the word — which sidesteps rdar://14285519
/// (AXBoundsForRange returns kAXErrorNoValue for an empty selection).
func axBounds(_ element: AXUIElement, range: CFRange) -> CGRect? {
    guard let v = axParameterized(element, AXAttr.boundsForRange, range: range),
          CFGetTypeID(v) == AXValueGetTypeID() else { return nil }
    let axv = v as! AXValue
    guard AXValueGetType(axv) == .cgRect else { return nil }
    var rect = CGRect.zero
    guard AXValueGetValue(axv, .cgRect, &rect) else { return nil }
    return rect
}

func axStringForRange(_ element: AXUIElement, range: CFRange) -> String? {
    guard let v = axParameterized(element, AXAttr.stringForRange, range: range),
          CFGetTypeID(v) == CFStringGetTypeID() else { return nil }
    return (v as! CFString) as String
}

// MARK: - Focused element discovery

/// Chromium/Electron expose nothing over AX until this is set. Native apps don't need it,
/// and we deliberately never set AXEnhancedUserInterface — that's the flag VoiceOver
/// sets, and it causes window-resize glitches in AppKit apps.
private var manualAccessDone = Set<pid_t>()

func enableManualAccessibility(for pid: pid_t, bundleID: String?) {
    guard let id = bundleID, !manualAccessDone.contains(pid) else { return }
    let electronish = ["com.google.Chrome", "com.microsoft.VSCode", "com.microsoft.Edge",
                       "com.brave.Browser", "com.tinyspeck.slackmacgap", "com.hnc.Discord",
                       "com.spotify.client", "com.figma.Desktop", "notion.id"]
    guard electronish.contains(id) || id.hasPrefix("com.electron") else { return }
    manualAccessDone.insert(pid)
    AXUIElementSetAttributeValue(AXUIElementCreateApplication(pid), AXAttr.manualAccess, kCFBooleanTrue)
}

/// Finds the focused text element.
///
/// PHASE 0 FINDING: `AXUIElementCreateSystemWide()` returns `cannotComplete` for
/// AXFocusedUIElement in every app on this machine, so the per-application element is the
/// PRIMARY route, not the fallback. (The original spec had this the other way around.)
func focusedTextElement(descendLimit: Int = 3) -> (element: AXUIElement, role: String, route: String)? {
    let front = NSWorkspace.shared.frontmostApplication
    if let front { enableManualAccessibility(for: front.processIdentifier,
                                             bundleID: front.bundleIdentifier) }

    var focused: AXUIElement?
    var route = ""
    if let pid = front?.processIdentifier {
        focused = axElement(AXUIElementCreateApplication(pid), AXAttr.focusedUIElement)
        route = "app(pid)"
    }
    if focused == nil {                                   // kept as a fallback for other Macs
        let system = AXUIElementCreateSystemWide()
        focused = axElement(system, AXAttr.focusedUIElement)
        route = "systemwide"
        if focused == nil, let app = axElement(system, AXAttr.focusedApp) {
            focused = axElement(app, AXAttr.focusedUIElement)
            route = "focusedApp"
        }
    }
    guard let el = focused else { return nil }

    let role = axString(el, AXAttr.role) ?? "(no role)"
    if AXRole.textLike.contains(role) { return (el, role, route) }

    // Some apps focus a container; look a couple of levels down for a text element.
    var frontier = [el]
    for _ in 0..<descendLimit {
        var next: [AXUIElement] = []
        for e in frontier {
            for child in axChildren(e) {
                let r = axString(child, AXAttr.role) ?? ""
                if AXRole.textLike.contains(r) { return (child, r, route + "+descend") }
                next.append(child)
            }
        }
        if next.isEmpty { break }
        frontier = Array(next.prefix(40))
    }
    return (el, role, route)
}

// MARK: - Reading text around the caret

struct TextContext {
    let window: NSString      // a slice of the field's text
    let windowStart: Int      // absolute UTF-16 offset of `window` within the field
    let caretInWindow: Int    // caret offset relative to `window`
    let selectionLength: Int
    let readPath: String      // "AXStringForRange" or "AXValue(full)"
    let totalChars: Int
}

/// Reads only the text *around* the caret, not the whole field.
///
/// PHASE 0 FINDING: Terminal's AXValue is the entire scrollback — 758 KB in testing.
/// Copying and scanning that on every trigger is slow enough to risk tripping
/// kCGEventTapDisabledByTimeout, which silently kills the event tap. So we prefer the
/// parameterized AXStringForRange to read a small window, and only fall back to the full
/// AXValue when that isn't supported (with a hard size guard).
func readTextContext(_ element: AXUIElement, maxFullRead: Int = 200_000) -> TextContext? {
    guard let sel = axRange(element, AXAttr.selectedRange) else { return nil }

    let total = axInt(element, AXAttr.numberOfChars) ?? -1

    if total >= 0 {
        let lo = max(0, sel.location - kContextRadius)
        let hi = min(total, sel.location + sel.length + kContextRadius)
        if hi > lo, let slice = axStringForRange(element, range: CFRange(location: lo, length: hi - lo)) {
            return TextContext(window: slice as NSString,
                               windowStart: lo,
                               caretInWindow: sel.location - lo,
                               selectionLength: sel.length,
                               readPath: "AXStringForRange",
                               totalChars: total)
        }
    }

    // Fallback: whole-value read.
    guard let v = axCopy(element, AXAttr.value), CFGetTypeID(v) == CFStringGetTypeID() else { return nil }
    let full = ((v as! CFString) as String) as NSString
    guard full.length <= maxFullRead else { return nil }   // refuse to scan a huge buffer
    return TextContext(window: full,
                       windowStart: 0,
                       caretInWindow: sel.location,
                       selectionLength: sel.length,
                       readPath: "AXValue(full)",
                       totalChars: full.length)
}

// MARK: - Word extraction

func isWordChar(_ c: unichar) -> Bool {
    if let s = UnicodeScalar(c), CharacterSet.alphanumerics.contains(s) { return true }
    return c == 0x5F /* _ */ || c == 0x2D /* - */ || c == 0x27 /* ' */
}

/// The word containing or ending at the caret, with its range in ABSOLUTE field
/// coordinates (so it can be handed straight to AXBoundsForRange / AXSelectedTextRange).
///
/// All indexing is UTF-16 via NSString: AX ranges are UTF-16 based, and Swift String
/// indices would desync on any emoji or accented character already in the buffer.
func wordAtCaret(_ ctx: TextContext) -> (word: String, range: CFRange)? {
    let text = ctx.window
    let len = text.length
    guard len > 0 else { return nil }

    if ctx.selectionLength > 0 {
        let loc = ctx.caretInWindow
        guard loc >= 0, loc + ctx.selectionLength <= len else { return nil }
        let w = text.substring(with: NSRange(location: loc, length: ctx.selectionLength))
        guard !w.isEmpty else { return nil }
        return (w, CFRange(location: ctx.windowStart + loc, length: ctx.selectionLength))
    }

    let caret = min(max(ctx.caretInWindow, 0), len)

    // Extend forward too, so a mid-word caret takes the whole word (as Sonoma does).
    var end = caret
    while end < len, isWordChar(text.character(at: end)) { end += 1 }
    var start = caret
    while start > 0, isWordChar(text.character(at: start - 1)) { start -= 1 }

    guard end > start else { return nil }
    let word = text.substring(with: NSRange(location: start, length: end - start))
    guard !word.isEmpty else { return nil }
    return (word, CFRange(location: ctx.windowStart + start, length: end - start))
}

// MARK: - Rect validation

/// PHASE 0 FINDING: Electron apps do not *fail* AXBoundsForRange — they return a
/// degenerate rect, e.g. (0, 800, 0x0). A plain nil-check therefore isn't enough; a
/// zero-size or off-screen rect must be rejected so the pill falls back to the mouse
/// instead of flying to the corner of the display.
func isUsableCaretRect(_ rect: CGRect) -> Bool {
    guard rect.width > 1, rect.height > 1 else { return false }
    guard rect.origin.x.isFinite, rect.origin.y.isFinite else { return false }
    guard rect.width < 10_000, rect.height < 10_000 else { return false }
    // Must intersect some screen, in Quartz (top-left origin) coordinates.
    guard let primary = NSScreen.screens.first else { return false }
    let H = primary.frame.height
    let cocoa = CGRect(x: rect.origin.x, y: H - rect.origin.y - rect.height,
                       width: rect.width, height: rect.height)
    return NSScreen.screens.contains { $0.frame.intersects(cocoa) }
}

/// Word rect in Cocoa (bottom-left origin) screen coordinates, or nil if unusable.
///
/// The flip must use the PRIMARY screen's height (NSScreen.screens[0]), not the screen
/// the window happens to be on — otherwise the pill lands on the wrong monitor.
func wordRectInCocoaSpace(_ element: AXUIElement, range: CFRange) -> CGRect? {
    guard let quartz = axBounds(element, range: range), isUsableCaretRect(quartz),
          let primary = NSScreen.screens.first else { return nil }
    let H = primary.frame.height
    return CGRect(x: quartz.origin.x, y: H - quartz.origin.y - quartz.height,
                  width: quartz.width, height: quartz.height)
}

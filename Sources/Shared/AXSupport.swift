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
private var manualAccessChecked = Set<pid_t>()

/// True when we enabled Chromium AX on the most recent lookup — meaning the tree was only
/// just asked for and may not have been built yet. Purely diagnostic; see Coordinator.
private(set) var chromiumAXJustEnabled = false

/// Whether the app bundle is Chromium-based: Chrome/Edge proper, Electron, or CEF.
///
/// FINDING: this used to be a hardcoded bundle-ID allowlist, which silently failed for
/// every app not on it — and the failure is indistinguishable from "there is no text
/// field here". Claude for Desktop (com.anthropic.claudefordesktop) logged 35 consecutive
/// "no focused element" before this was tracked down. Chromium is detected structurally
/// instead, by what the bundle actually ships. Probed across this machine's apps:
///
///     app                          renderer helper          Chromium GL libs
///     Claude, Obsidian (Electron)  top of Frameworks/       ✓
///     Microsoft Edge (Chromium)    nested in .framework     ✓
///     ChatGPT (Chromium)           — (named differently)    ✓
///     zoom.us (CEF)                top of Frameworks/       —
///     Safari, Notes (native)       —                        —
///
/// Neither marker alone covers every Chromium app; the union covers all of them and still
/// rejects the native ones. Same lesson as the role whitelist: ask what the thing *is*,
/// not whether it's on a list we remembered to update.
func isChromiumBased(_ app: NSRunningApplication) -> Bool {
    let fm = FileManager.default
    guard let frameworks = app.bundleURL?.appendingPathComponent("Contents/Frameworks"),
          let entries = try? fm.contentsOfDirectory(atPath: frameworks.path)
    else { return false }

    // Electron and CEF put the renderer helper straight into Frameworks/.
    if entries.contains(where: { $0.hasSuffix("Helper (Renderer).app") }) { return true }

    // Chrome, Edge and ChatGPT bury their helpers inside "<Name> Framework.framework",
    // under a version directory, and name them inconsistently. That framework always
    // carries Chromium's ANGLE/SwiftShader dylibs, which is the dependable marker.
    for entry in entries where entry.hasSuffix(".framework") {
        let versions = frameworks.appendingPathComponent("\(entry)/Versions")
        guard let vs = try? fm.contentsOfDirectory(atPath: versions.path) else { continue }
        for v in vs {
            let libs = versions.appendingPathComponent("\(v)/Libraries")
            guard let names = try? fm.contentsOfDirectory(atPath: libs.path) else { continue }
            if names.contains("libGLESv2.dylib") || names.contains("libvk_swiftshader.dylib") {
                return true
            }
        }
    }
    return false
}

/// Sets AXManualAccessibility on Chromium-based apps, at most once per pid.
///
/// The bundle probe touches the filesystem, so it is memoized for misses as well as hits —
/// and like every other AX call here it runs off the event-tap callback, where the latency
/// would risk kCGEventTapDisabledByTimeout.
func enableManualAccessibility(for app: NSRunningApplication) {
    let pid = app.processIdentifier
    chromiumAXJustEnabled = false
    guard !manualAccessChecked.contains(pid) else { return }
    manualAccessChecked.insert(pid)          // remember the miss too, not just the hit
    guard isChromiumBased(app) else { return }
    AXUIElementSetAttributeValue(AXUIElementCreateApplication(pid), AXAttr.manualAccess, kCFBooleanTrue)
    chromiumAXJustEnabled = true
}

/// Finds the focused text element.
///
/// PHASE 0 FINDING: `AXUIElementCreateSystemWide()` returns `cannotComplete` for
/// AXFocusedUIElement in every app on this machine, so the per-application element is the
/// PRIMARY route, not the fallback. (The original spec had this the other way around.)
func focusedTextElement(descendLimit: Int = 5) -> (element: AXUIElement, role: String, route: String)? {
    let front = NSWorkspace.shared.frontmostApplication
    if let front { enableManualAccessibility(for: front) }

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

    // Prefer CAPABILITY over role. An element we can actually read a selection range from
    // is usable whatever it calls itself, and role whitelists miss custom controls.
    if canReadSelection(el) { return (el, role, route) }

    // Otherwise look downward for something that can. Some apps focus a container, and
    // web content nests the real field several levels deep.
    var frontier = [el]
    var seen = 0
    for depth in 0..<descendLimit {
        var next: [AXUIElement] = []
        for e in frontier {
            for child in axChildren(e) {
                seen += 1
                if seen > 400 { break }                   // bounded: this runs off the tap,
                if canReadSelection(child) {              // but must still never hang
                    let r = axString(child, AXAttr.role) ?? "?"
                    return (child, r, "\(route)+descend\(depth + 1)")
                }
                next.append(child)
            }
        }
        if next.isEmpty || seen > 400 { break }
        frontier = Array(next.prefix(60))
    }
    return (el, role, route)
}

/// True when the element exposes a selection range we can act on. This is the real
/// requirement; the role string is only a hint.
func canReadSelection(_ el: AXUIElement) -> Bool {
    axRange(el, AXAttr.selectedRange) != nil
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

// MARK: - Element frame (fallback anchor)

func axPoint(_ el: AXUIElement, _ attr: CFString) -> CGPoint? {
    guard let v = axCopy(el, attr), CFGetTypeID(v) == AXValueGetTypeID() else { return nil }
    let axv = v as! AXValue
    guard AXValueGetType(axv) == .cgPoint else { return nil }
    var p = CGPoint.zero
    guard AXValueGetValue(axv, .cgPoint, &p) else { return nil }
    return p
}

func axSize(_ el: AXUIElement, _ attr: CFString) -> CGSize? {
    guard let v = axCopy(el, attr), CFGetTypeID(v) == AXValueGetTypeID() else { return nil }
    let axv = v as! AXValue
    guard AXValueGetType(axv) == .cgSize else { return nil }
    var sz = CGSize.zero
    guard AXValueGetValue(axv, .cgSize, &sz) else { return nil }
    return sz
}

/// The text field's own frame in Cocoa coordinates. Used to anchor the pill when the app
/// gives no usable caret rect (Electron), which is far better than falling back to
/// wherever the mouse happens to be sitting.
func elementRectInCocoaSpace(_ el: AXUIElement) -> CGRect? {
    guard let p = axPoint(el, "AXPosition" as CFString),
          let sz = axSize(el, "AXSize" as CFString),
          sz.width > 1, sz.height > 1,
          let primary = NSScreen.screens.first else { return nil }
    let quartz = CGRect(origin: p, size: sz)
    guard isUsableCaretRect(quartz) else { return nil }
    let H = primary.frame.height
    return CGRect(x: quartz.origin.x, y: H - quartz.origin.y - quartz.height,
                  width: quartz.width, height: quartz.height)
}

/// Apps whose visible text area is a transcript, not the input line: AX reports a
/// selection inside the scrollback, but typed characters go to the tty instead. Setting a
/// selection there "succeeds" and then does nothing, so these must skip the AX write path
/// entirely and replace by synthesized keystrokes.
let terminalBundleIDs: Set<String> = [
    "com.apple.Terminal", "com.googlecode.iterm2", "co.zeit.hyper",
    "net.kovidgoyal.kitty", "com.github.wez.wezterm", "dev.warp.Warp-Stable",
    "io.alacritty", "org.tabby",
]

func frontmostIsTerminal() -> Bool {
    guard let id = NSWorkspace.shared.frontmostApplication?.bundleIdentifier else { return false }
    return terminalBundleIDs.contains(id)
}

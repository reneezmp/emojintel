import AppKit
import ApplicationServices
import Carbon.HIToolbox

// AXError is a plain C enum; Result needs it to be an Error.
extension AXError: Error {}

/// Diagnoses *why* focused-element lookup fails, instead of collapsing every distinct
/// AXError into nil. Tries four independent routes to the focused text element and
/// prints the exact error for each.
enum FocusProbe {

    static func run() {
        print("""
        Focused-element diagnosis. Click into a text field in another app; this samples
        every 2s and prints the exact AXError for each lookup route. Ctrl-C to stop.
        ────────────────────────────────────────────────────────────────────────────────
        """)
        print("AXIsProcessTrusted() = \(AXIsProcessTrusted())")
        print("running as pid \(ProcessInfo.processInfo.processIdentifier), "
            + "euid \(geteuid())")
        if IsSecureEventInputEnabled() {
            print("⚠︎ Secure Input is ENABLED — this alone can block AX text reads.")
        }
        print("")

        Timer.scheduledTimer(withTimeInterval: 2.0, repeats: true) { _ in sample() }
        RunLoop.current.run()
    }

    private static func sample() {
        guard let front = NSWorkspace.shared.frontmostApplication else {
            print("· no frontmost application"); return
        }
        let name = front.localizedName ?? "?"
        let pid = front.processIdentifier
        print("── [\(name)] pid \(pid) ──────────────────────────────")

        // Chromium-based apps expose nothing over AX until AXManualAccessibility is set, so
        // the probe must do exactly what the app does or it reports a failure that isn't real.
        if isChromiumBased(front) {
            enableManualAccessibility(for: front)
            print("   Chromium-based bundle → AXManualAccessibility set"
                + (chromiumAXJustEnabled ? " (just now; tree may still be building)" : " (already)"))
        }

        // Route 1: system-wide element → AXFocusedUIElement
        let system = AXUIElementCreateSystemWide()
        report("systemwide.AXFocusedUIElement", copyRaw(system, "AXFocusedUIElement"))

        // What does the systemwide element expose at all?
        var names: CFArray?
        let nameErr = AXUIElementCopyAttributeNames(system, &names)
        if nameErr == .success, let list = names as? [String] {
            print("   systemwide attributes: \(list.sorted().joined(separator: ", "))")
        } else {
            print("   systemwide attribute names → \(describe(nameErr))")
        }

        // Route 2: system-wide → AXFocusedApplication → AXFocusedUIElement
        switch copyRaw(system, "AXFocusedApplication") {
        case .success(let v) where CFGetTypeID(v) == AXUIElementGetTypeID():
            let app = v as! AXUIElement
            report("focusedApp.AXFocusedUIElement", copyRaw(app, "AXFocusedUIElement"))
        case .success:
            print("   systemwide.AXFocusedApplication → wrong type")
        case .failure(let e):
            print("   systemwide.AXFocusedApplication → \(describe(e))")
        }

        // Route 3: application element built from the frontmost pid
        let appEl = AXUIElementCreateApplication(pid)
        report("app(pid).AXFocusedUIElement", copyRaw(appEl, "AXFocusedUIElement"))

        // Route 4: frontmost app's focused window, then its focused element
        switch copyRaw(appEl, "AXFocusedWindow") {
        case .success(let v) where CFGetTypeID(v) == AXUIElementGetTypeID():
            let win = v as! AXUIElement
            let role = (try? copyRaw(win, "AXRole").get()).flatMap { $0 as? String } ?? "?"
            print("   app(pid).AXFocusedWindow → ok (role \(role))")
        case .success:
            print("   app(pid).AXFocusedWindow → wrong type")
        case .failure(let e):
            print("   app(pid).AXFocusedWindow → \(describe(e))")
        }
        print("")
    }

    private static func report(_ label: String, _ r: Result<CFTypeRef, AXError>) {
        switch r {
        case .success(let v):
            guard CFGetTypeID(v) == AXUIElementGetTypeID() else {
                print("   \(label) → unexpected type"); return
            }
            let el = v as! AXUIElement
            let role = (try? copyRaw(el, "AXRole").get()).flatMap { $0 as? String } ?? "?"
            let sub  = (try? copyRaw(el, "AXSubrole").get()).flatMap { $0 as? String } ?? "-"
            var extras: [String] = []
            if case .success(let val) = copyRaw(el, "AXValue"),
               CFGetTypeID(val) == CFStringGetTypeID() {
                extras.append("AXValue len \(((val as! CFString) as String).count)")
            }
            if case .failure(let e) = copyRaw(el, "AXValue") {
                extras.append("AXValue → \(describe(e))")
            }
            if case .failure(let e) = copyRaw(el, "AXSelectedTextRange") {
                extras.append("AXSelectedTextRange → \(describe(e))")
            } else {
                extras.append("AXSelectedTextRange ok")
            }
            print("   ✓ \(label) → role \(role) / subrole \(sub)   [\(extras.joined(separator: "; "))]")
        case .failure(let e):
            print("   ✗ \(label) → \(describe(e))")
        }
    }

    private static func copyRaw(_ el: AXUIElement, _ attr: String) -> Result<CFTypeRef, AXError> {
        var out: CFTypeRef?
        let err = AXUIElementCopyAttributeValue(el, attr as CFString, &out)
        if err == .success, let v = out { return .success(v) }
        return .failure(err)
    }

    static func describe(_ e: AXError) -> String {
        switch e {
        case .success:                    return "success"
        case .failure:                    return "kAXErrorFailure"
        case .illegalArgument:            return "illegalArgument"
        case .invalidUIElement:           return "invalidUIElement"
        case .invalidUIElementObserver:   return "invalidUIElementObserver"
        case .cannotComplete:             return "cannotComplete (app not responding / not AX-reachable)"
        case .attributeUnsupported:       return "attributeUnsupported (element has no such attribute)"
        case .actionUnsupported:          return "actionUnsupported"
        case .notificationUnsupported:    return "notificationUnsupported"
        case .notImplemented:             return "notImplemented"
        case .notificationAlreadyRegistered:   return "notificationAlreadyRegistered"
        case .notificationNotRegistered:  return "notificationNotRegistered"
        case .apiDisabled:                return "‼️ apiDisabled — Accessibility NOT granted to this process"
        case .noValue:                    return "noValue (attribute exists but is empty)"
        case .parameterizedAttributeUnsupported: return "parameterizedAttributeUnsupported"
        case .notEnoughPrecision:         return "notEnoughPrecision"
        @unknown default:                 return "unknown(\(e.rawValue))"
        }
    }
}

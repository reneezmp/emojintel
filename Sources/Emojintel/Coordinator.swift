import AppKit
import ApplicationServices

/// Orchestrates: trigger → read word → look up → show pill → replace.
///
/// Everything here runs on the main queue. KeyTrigger's tap callback only ever posts
/// into this class asynchronously, so no AX call can ever stall the event tap.
final class Coordinator {

    private let index: EmojiIndex
    private let trigger = KeyTrigger()
    private let panel = SuggestionPanel()

    /// The target captured at trigger time. The user may move focus while the pill is up;
    /// we always replace into the element we actually read from.
    /// Marker-based targets (Mail, Safari rich text) have no writable range, so they
    /// always replace by keystrokes.
    private enum Target {
        case ranged(AXUIElement, CFRange, caret: Int)
        case markers(AXUIElement, wordLength: Int)
    }
    private var target: Target?
    private var hits: [EmojiHit] = []

    var onStateChange: (() -> Void)?

    init(index: EmojiIndex) {
        self.index = index

        trigger.onTrigger    = { [weak self] _ in self?.fire() }
        trigger.onNavigate   = { [weak self] d in self?.navigate(by: d) }
        trigger.onCommit     = { [weak self] in self?.commit() }
        trigger.onDismiss    = { [weak self] in self?.dismiss() }
        trigger.onSelectIndex = { [weak self] i in self?.select(i) }

        panel.onPick = { [weak self] i in self?.select(i) }
        panel.onChevron = { [weak self] in
            self?.dismiss()
            NSApp.orderFrontCharacterPalette(nil)   // the chevron opens the full picker
        }
    }

    @discardableResult
    func start() -> Bool { trigger.install() }

    var isPaused: Bool { trigger.isPaused }
    func setPaused(_ p: Bool) {
        if p { dismiss() }
        trigger.setPaused(p)
        onStateChange?()
    }

    // MARK: - Flow

    /// Invoked on the main queue after a lone fn / Right-⌘ tap.
    func fire() {
        dismiss()

        let appName = NSWorkspace.shared.frontmostApplication?.localizedName ?? "?"

        guard let (element, role, route) = focusedTextElement() else {
            // Chromium builds its AX tree asynchronously once AXManualAccessibility is set,
            // so the tap that switches it on can still land before the tree exists.
            let hint = chromiumAXJustEnabled ? "  (Chromium AX just enabled — tap again)" : ""
            Diagnostics.log("[\(appName)] no focused element\(hint)"); return
        }

        let word: String
        let rect: CGRect?
        let newTarget: Target
        let path: String

        if let (w, r) = AXMarkers.wordAtCaret(element), AXMarkers.isMarkerBased(element) {
            // WebKit text markers: Mail's compose area, Safari rich text.
            word = w
            rect = r
            newTarget = .markers(element, wordLength: w.utf16.count)
            path = "markers"
        } else {
            guard let ctx = readTextContext(element) else {
                Diagnostics.log("[\(appName)] \(role) via \(route) — no readable text"); return
            }
            guard let (w, r) = wordAtCaret(ctx) else {
                Diagnostics.log("[\(appName)] \(role) — no word at caret"); return
            }
            word = w
            rect = wordRectInCocoaSpace(element, range: r)
            newTarget = .ranged(element, r, caret: ctx.windowStart + ctx.caretInWindow)
            path = ctx.readPath
        }

        let suggestions = index.suggestions(for: word, limit: 3)
        guard !suggestions.isEmpty else {
            Diagnostics.log("[\(appName)] \(role) — \"\(word)\" → no suggestions"); return
        }

        Diagnostics.log("[\(appName)] \(role) via \(route)/\(path) — \"\(word)\" → "
            + suggestions.map(\.emoji).joined(separator: " ")
            + (rect == nil ? "  (no rect: field/mouse fallback)" : ""))

        hits = suggestions
        target = newTarget
        panel.present(hits: suggestions, anchor: rect,
                      field: rect == nil ? elementRectInCocoaSpace(element) : nil)
        trigger.pillIsOpen = true
    }

    private func navigate(by delta: Int) {
        guard trigger.pillIsOpen, !hits.isEmpty else { return }
        let n = hits.count
        panel.selectedIndex = ((panel.selectedIndex + delta) % n + n) % n
    }

    private func select(_ index: Int) {
        guard trigger.pillIsOpen, hits.indices.contains(index) else { return }
        panel.selectedIndex = index
        commit()
    }

    private func commit() {
        guard trigger.pillIsOpen, let t = target,
              hits.indices.contains(panel.selectedIndex)
        else { dismiss(); return }

        let emoji = hits[panel.selectedIndex].emoji
        dismiss()
        let tier: String
        switch t {
        case let .ranged(element, range, caret):
            tier = WordReplacer.replace(element: element, range: range, caret: caret, with: emoji)
        case let .markers(_, wordLength):
            tier = WordReplacer.replaceByTyping(deleting: wordLength, with: emoji)
        }
        Diagnostics.log("    → replaced with \(emoji) via \(tier)")
    }

    func dismiss() {
        trigger.pillIsOpen = false
        target = nil
        hits = []
        panel.orderOut(nil)
    }
}

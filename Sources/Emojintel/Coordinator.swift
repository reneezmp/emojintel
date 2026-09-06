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
    private var target: (element: AXUIElement, range: CFRange)?
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

        guard let (element, _, _) = focusedTextElement(),
              let ctx = readTextContext(element),
              let (word, range) = wordAtCaret(ctx)
        else { return }                                   // silent no-op, by design

        let suggestions = index.suggestions(for: word, limit: 3)
        guard !suggestions.isEmpty else { return }

        hits = suggestions
        target = (element, range)
        panel.present(hits: suggestions, anchor: wordRectInCocoaSpace(element, range: range))
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
        guard trigger.pillIsOpen,
              let (element, range) = target,
              hits.indices.contains(panel.selectedIndex)
        else { dismiss(); return }

        let emoji = hits[panel.selectedIndex].emoji
        dismiss()
        WordReplacer.replace(element: element, range: range, with: emoji)
    }

    func dismiss() {
        trigger.pillIsOpen = false
        target = nil
        hits = []
        panel.orderOut(nil)
    }
}

import AppKit

/// The suggestion pill.
///
/// Mirrors the macOS Sonoma bar: a translucent rounded container holding three emoji,
/// the selected one wearing an inset accent-coloured capsule, a single separator before
/// a chevron, anchored below the word being replaced.
///
/// MUST be an NSPanel, not an NSWindow: `.nonactivatingPanel` is documented in
/// NSWindow.h as "Only applicable for NSPanel (or a subclass thereof)". On a plain
/// NSWindow the flag is ignored and the pill steals focus from the app you're typing in,
/// which breaks the single most important behaviour of the whole tool.
final class SuggestionPanel: NSPanel {

    // The only numbers to touch if this wants tuning; everything else lays out from
    // them. History: 40pt (2.5x the 16pt text line — enormous), then 26pt, now 18pt.
    static let cellSize = NSSize(width: 22, height: 18)
    static let chevronWidth: CGFloat = 15
    static let cornerRadius: CGFloat = 5

    private let vibrancy = NSVisualEffectView()
    private let content = SuggestionView()
    var onPick: ((Int) -> Void)?
    var onChevron: (() -> Void)?

    init() {
        super.init(contentRect: NSRect(x: 0, y: 0, width: 200, height: SuggestionPanel.cellSize.height),
                   styleMask: [.borderless, .nonactivatingPanel],
                   backing: .buffered,
                   defer: false)

        isFloatingPanel = true
        level = .popUpMenu                      // above .floating, so utility windows can't bury it
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient, .ignoresCycle]
        backgroundColor = .clear
        isOpaque = false
        hasShadow = true
        hidesOnDeactivate = false
        isMovable = false
        animationBehavior = .utilityWindow
        acceptsMouseMovedEvents = true

        // Vibrancy behind everything, clipped to the pill's rounded shape. `.menu`
        // is the material Apple uses for exactly this kind of floating strip, and it
        // tracks light/dark on its own.
        vibrancy.material = .menu
        vibrancy.blendingMode = .behindWindow
        vibrancy.state = .active
        vibrancy.wantsLayer = true
        vibrancy.layer?.cornerRadius = SuggestionPanel.cornerRadius
        vibrancy.layer?.masksToBounds = true

        content.onPick = { [weak self] i in self?.onPick?(i) }
        content.onChevron = { [weak self] in self?.onChevron?() }
        content.autoresizingMask = [.width, .height]

        vibrancy.addSubview(content)
        contentView = vibrancy
    }

    // Never take focus. This is what keeps the caret blinking in the source app.
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }

    var itemCount: Int { content.hits.count }
    var selectedIndex: Int {
        get { content.selected }
        set { content.selected = newValue; content.needsDisplay = true }
    }

    /// Shows the pill anchored under `wordRect` (Cocoa coords), falling back to the text
    /// field's own frame, then to the mouse.
    func present(hits: [EmojiHit], anchor wordRect: CGRect?, field fieldRect: CGRect? = nil) {
        guard !hits.isEmpty else { close(); return }
        content.hits = hits
        content.selected = 0

        let width = CGFloat(hits.count) * SuggestionPanel.cellSize.width + SuggestionPanel.chevronWidth
        let size = NSSize(width: width, height: SuggestionPanel.cellSize.height)

        // Anchor preference: the word itself → the bottom-left of the text field →
        // the mouse. Electron returns a degenerate caret rect, and falling straight to
        // the mouse put the pill in the middle of the window, far from what you typed.
        var origin: NSPoint
        if let r = wordRect {
            origin = NSPoint(x: r.minX, y: r.minY - size.height - 4)
        } else if let f = fieldRect {
            origin = NSPoint(x: f.minX + 6, y: f.minY + 4)
        } else {
            let m = NSEvent.mouseLocation
            origin = NSPoint(x: m.x, y: m.y - size.height - 18)
        }
        origin = clamp(origin: origin, size: size)

        setFrame(NSRect(origin: origin, size: size), display: true)
        content.frame = vibrancy.bounds
        content.needsDisplay = true
        orderFrontRegardless()          // show without activating the app
    }

    /// Keeps the pill fully on whichever screen it lands on; flips above the word if
    /// there isn't room below.
    private func clamp(origin: NSPoint, size: NSSize) -> NSPoint {
        let screen = NSScreen.screens.first {
            $0.frame.contains(NSPoint(x: origin.x, y: origin.y + size.height))
        } ?? NSScreen.main ?? NSScreen.screens[0]
        let v = screen.visibleFrame
        var p = origin
        p.x = min(max(p.x, v.minX + 4), v.maxX - size.width - 4)
        if p.y < v.minY + 4 { p.y = origin.y + size.height + 6 + size.height }   // flip above
        p.y = min(max(p.y, v.minY + 4), v.maxY - size.height - 4)
        return p
    }
}

// MARK: - Content

private final class SuggestionView: NSView {

    var hits: [EmojiHit] = []
    var selected = 0
    var onPick: ((Int) -> Void)?
    var onChevron: (() -> Void)?

    /// Inset of the selection capsule inside its cell. This is what distinguishes the
    /// Sonoma look from a plain highlighted table row: the accent colour is a floating
    /// pill around the glyph, not a full-bleed block filling the cell.
    private let selectionInset = NSSize(width: 1.5, height: 1.5)

    override var isFlipped: Bool { false }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: bounds,
                                       options: [.mouseMoved, .activeAlways, .inVisibleRect],
                                       owner: self))
    }

    override func draw(_ dirty: NSRect) {
        let cw = SuggestionPanel.cellSize.width

        // Selection: an inset capsule, not a full-height block.
        if hits.indices.contains(selected) {
            let cell = NSRect(x: CGFloat(selected) * cw, y: 0, width: cw, height: bounds.height)
            let pill = cell.insetBy(dx: selectionInset.width, dy: selectionInset.height)
            let r = pill.height / 2.6
            NSColor.controlAccentColor.setFill()
            NSBezierPath(roundedRect: pill, xRadius: r, yRadius: r).fill()
        }

        // A single separator, before the chevron. The reference has none between the
        // emoji themselves — cells are separated by spacing, not by rules.
        let chevX = CGFloat(hits.count) * cw
        NSColor.separatorColor.setStroke()
        let rule = NSBezierPath()
        rule.move(to: NSPoint(x: chevX, y: 4))
        rule.line(to: NSPoint(x: chevX, y: bounds.height - 4))
        rule.lineWidth = 1
        rule.stroke()

        // Emoji
        let font = NSFont.systemFont(ofSize: 12)
        for (i, hit) in hits.enumerated() {
            let s = NSAttributedString(string: hit.emoji, attributes: [.font: font])
            let sz = s.size()
            s.draw(at: NSPoint(x: CGFloat(i) * cw + (cw - sz.width) / 2,
                               y: (bounds.height - sz.height) / 2))
        }

        // Chevron
        let chev = NSAttributedString(string: "⌄", attributes: [
            .font: NSFont.systemFont(ofSize: 9, weight: .medium),
            .foregroundColor: NSColor.secondaryLabelColor,
        ])
        let cs = chev.size()
        chev.draw(at: NSPoint(x: chevX + (SuggestionPanel.chevronWidth - cs.width) / 2,
                              y: (bounds.height - cs.height) / 2 + 1.5))
    }

    override func mouseDown(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        let idx = Int(p.x / SuggestionPanel.cellSize.width)
        if idx >= 0, idx < hits.count { onPick?(idx) } else { onChevron?() }
    }

    override func mouseMoved(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        let idx = Int(p.x / SuggestionPanel.cellSize.width)
        if idx >= 0, idx < hits.count, idx != selected { selected = idx; needsDisplay = true }
    }
}

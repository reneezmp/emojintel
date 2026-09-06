import AppKit

/// The suggestion pill.
///
/// Mirrors the macOS Sonoma bar: a rounded light container holding three emoji cells
/// plus a chevron, first cell selected with the system accent colour, anchored below the
/// word being replaced.
///
/// MUST be an NSPanel, not an NSWindow: `.nonactivatingPanel` is documented in
/// NSWindow.h as "Only applicable for NSPanel (or a subclass thereof)". On a plain
/// NSWindow the flag is ignored and the pill steals focus from the app you're typing in,
/// which breaks the single most important behaviour of the whole tool.
final class SuggestionPanel: NSPanel {

    static let cellSize = NSSize(width: 46, height: 40)
    static let chevronWidth: CGFloat = 32
    static let cornerRadius: CGFloat = 9

    private let contentContainer = SuggestionView()
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

        contentContainer.onPick = { [weak self] i in self?.onPick?(i) }
        contentContainer.onChevron = { [weak self] in self?.onChevron?() }
        contentView = contentContainer
    }

    // Never take focus. This is what keeps the caret blinking in the source app.
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }

    var itemCount: Int { contentContainer.hits.count }
    var selectedIndex: Int {
        get { contentContainer.selected }
        set { contentContainer.selected = newValue; contentContainer.needsDisplay = true }
    }

    /// Shows the pill anchored under `wordRect` (Cocoa coords), or under the mouse when
    /// the app gave us no usable rect.
    func present(hits: [EmojiHit], anchor wordRect: CGRect?) {
        guard !hits.isEmpty else { close(); return }
        contentContainer.hits = hits
        contentContainer.selected = 0

        let width = CGFloat(hits.count) * SuggestionPanel.cellSize.width + SuggestionPanel.chevronWidth
        let size = NSSize(width: width, height: SuggestionPanel.cellSize.height)

        var origin: NSPoint
        if let r = wordRect {
            origin = NSPoint(x: r.minX, y: r.minY - size.height - 6)
        } else {
            let m = NSEvent.mouseLocation
            origin = NSPoint(x: m.x, y: m.y - size.height - 18)
        }
        origin = clamp(origin: origin, size: size)

        setFrame(NSRect(origin: origin, size: size), display: true)
        contentContainer.needsDisplay = true
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

    override var isFlipped: Bool { false }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func draw(_ dirty: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        let radius = SuggestionPanel.cornerRadius
        let body = NSBezierPath(roundedRect: bounds, xRadius: radius, yRadius: radius)

        // Container
        ctx.saveGState()
        body.addClip()
        (NSColor.windowBackgroundColor).setFill()
        bounds.fill()

        let cw = SuggestionPanel.cellSize.width
        // Selection
        if hits.indices.contains(selected) {
            let r = NSRect(x: CGFloat(selected) * cw, y: 0, width: cw, height: bounds.height)
            NSColor.controlAccentColor.setFill()
            r.fill()
        }
        ctx.restoreGState()

        // Separators between unselected cells
        NSColor.separatorColor.withAlphaComponent(0.5).setStroke()
        for i in 1..<max(1, hits.count) where i != selected && i - 1 != selected {
            let x = CGFloat(i) * cw
            let line = NSBezierPath()
            line.move(to: NSPoint(x: x, y: 7))
            line.line(to: NSPoint(x: x, y: bounds.height - 7))
            line.lineWidth = 1
            line.stroke()
        }
        let chevX = CGFloat(hits.count) * cw
        if hits.count - 1 != selected {
            let line = NSBezierPath()
            line.move(to: NSPoint(x: chevX, y: 7))
            line.line(to: NSPoint(x: chevX, y: bounds.height - 7))
            line.lineWidth = 1
            line.stroke()
        }

        // Emoji
        let font = NSFont.systemFont(ofSize: 23)
        for (i, hit) in hits.enumerated() {
            let s = NSAttributedString(string: hit.emoji, attributes: [.font: font])
            let sz = s.size()
            s.draw(at: NSPoint(x: CGFloat(i) * cw + (cw - sz.width) / 2,
                               y: (bounds.height - sz.height) / 2))
        }

        // Chevron
        let chev = NSAttributedString(string: "⌄", attributes: [
            .font: NSFont.systemFont(ofSize: 15, weight: .medium),
            .foregroundColor: NSColor.secondaryLabelColor,
        ])
        let cs = chev.size()
        chev.draw(at: NSPoint(x: chevX + (SuggestionPanel.chevronWidth - cs.width) / 2,
                              y: (bounds.height - cs.height) / 2 + 2))

        // Hairline border
        NSColor.separatorColor.setStroke()
        body.lineWidth = 1
        body.stroke()
    }

    override func mouseDown(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        let cw = SuggestionPanel.cellSize.width
        let idx = Int(p.x / cw)
        if idx >= 0, idx < hits.count { onPick?(idx) } else { onChevron?() }
    }

    override func mouseMoved(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        let idx = Int(p.x / SuggestionPanel.cellSize.width)
        if idx >= 0, idx < hits.count, idx != selected { selected = idx; needsDisplay = true }
    }
}

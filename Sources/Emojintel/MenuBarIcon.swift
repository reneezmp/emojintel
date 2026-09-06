import AppKit

/// The menu bar glyph: a silhouette of ☀️, drawn rather than shipped as an asset.
///
/// Drawn at runtime for two reasons: it stays crisp at any menu bar size without
/// shipping @1x/@2x files, and marking it a template image lets macOS invert it
/// automatically for light and dark menu bars — a coloured emoji can't do that.
enum MenuBarIcon {

    static func image(size: CGFloat = 16) -> NSImage {
        let image = NSImage(size: NSSize(width: size, height: size), flipped: false) { rect in
            let c = CGPoint(x: rect.midX, y: rect.midY)
            let unit = size / 16.0

            NSColor.black.setFill()
            NSColor.black.setStroke()

            // Core disc.
            let r = 3.5 * unit
            NSBezierPath(ovalIn: CGRect(x: c.x - r, y: c.y - r, width: r * 2, height: r * 2)).fill()

            // Eight rays, rounded, sitting just outside the disc.
            let inner = 5.1 * unit
            let outer = 7.2 * unit
            let ray = NSBezierPath()
            ray.lineWidth = 1.5 * unit
            ray.lineCapStyle = .round
            for i in 0..<8 {
                let a = CGFloat(i) * .pi / 4
                ray.move(to: CGPoint(x: c.x + cos(a) * inner, y: c.y + sin(a) * inner))
                ray.line(to: CGPoint(x: c.x + cos(a) * outer, y: c.y + sin(a) * outer))
            }
            ray.stroke()
            return true
        }
        image.isTemplate = true      // macOS handles light/dark and the selected state
        return image
    }
}

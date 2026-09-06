#!/usr/bin/env swift
// Generates Resources/Emojintel.icns — ☀️ on rose gold, for Rosy.
//
// Run:  make icons     (or: swift Tools/make-icons.swift)
// No dependencies: renders with AppKit, packs with iconutil.

import AppKit
import Foundation

let cwd = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
let resources = cwd.appendingPathComponent("Resources")
let iconset = resources.appendingPathComponent("Emojintel.iconset")

// Rose gold: pale blush falling to a deeper copper-pink, with a soft top-left
// highlight so the face doesn't read flat at small sizes.
let blush = NSColor(srgbRed: 0.965, green: 0.847, blue: 0.824, alpha: 1)  // #F6D8D2
let mid   = NSColor(srgbRed: 0.874, green: 0.655, blue: 0.620, alpha: 1)  // #DFA79E
let deep  = NSColor(srgbRed: 0.639, green: 0.373, blue: 0.416, alpha: 1)  // #A35F6A rose gold

func renderPNG(size px: Int) -> Data {
    let rep = NSBitmapImageRep(
        bitmapDataPlanes: nil, pixelsWide: px, pixelsHigh: px,
        bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
        colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!

    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    let ctx = NSGraphicsContext.current!.cgContext
    let S = CGFloat(px)

    // macOS icon geometry: content occupies 824/1024 of the canvas, with a corner
    // radius of 185.4/824 of the content. Matching this is what makes an icon sit
    // correctly next to Apple's in the Dock.
    let inset = S * (100.0 / 1024.0)
    let body = CGRect(x: inset, y: inset, width: S - inset * 2, height: S - inset * 2)
    let radius = body.width * (185.4 / 824.0)
    let squircle = NSBezierPath(roundedRect: body, xRadius: radius, yRadius: radius)

    ctx.saveGState()
    squircle.addClip()
    let stops: [CGFloat] = [0.0, 0.45, 1.0]
    let base = stops.withUnsafeBufferPointer { buf in
        NSGradient(colors: [blush, mid, deep], atLocations: buf.baseAddress, colorSpace: .sRGB)!
    }
    base.draw(in: body, angle: -55)

    // Soft specular sweep across the upper third.
    let gloss = NSGradient(starting: NSColor(white: 1, alpha: 0.20),
                           ending: NSColor(white: 1, alpha: 0.0))!
    gloss.draw(in: CGRect(x: body.minX, y: body.midY, width: body.width, height: body.height / 2),
               angle: -90)
    ctx.restoreGState()

    // ☀️ centred, sized to about 58% of the icon face.
    let glyphSize = body.width * 0.58
    if let font = NSFont(name: "Apple Color Emoji", size: glyphSize) {
        let s = NSAttributedString(string: "☀️", attributes: [.font: font])
        let m = s.size()
        // Optical centring: emoji glyphs sit high in their line box.
        s.draw(at: NSPoint(x: body.midX - m.width / 2,
                           y: body.midY - m.height / 2 + body.height * 0.012))
    }

    // Hairline inner edge, so the icon keeps definition on a light background.
    NSColor(white: 0, alpha: 0.10).setStroke()
    squircle.lineWidth = max(1, S / 512)
    squircle.stroke()

    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])!
}

// The sizes iconutil expects, by exact filename.
let variants: [(name: String, px: Int)] = [
    ("icon_16x16.png", 16),      ("icon_16x16@2x.png", 32),
    ("icon_32x32.png", 32),      ("icon_32x32@2x.png", 64),
    ("icon_128x128.png", 128),   ("icon_128x128@2x.png", 256),
    ("icon_256x256.png", 256),   ("icon_256x256@2x.png", 512),
    ("icon_512x512.png", 512),   ("icon_512x512@2x.png", 1024),
]

try? FileManager.default.removeItem(at: iconset)
try! FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)
for v in variants {
    try! renderPNG(size: v.px).write(to: iconset.appendingPathComponent(v.name))
}
print("rendered \(variants.count) sizes into \(iconset.lastPathComponent)")

let task = Process()
task.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
task.arguments = ["-c", "icns", iconset.path,
                  "-o", resources.appendingPathComponent("Emojintel.icns").path]
try! task.run()
task.waitUntilExit()
guard task.terminationStatus == 0 else { print("iconutil failed"); exit(1) }
try? FileManager.default.removeItem(at: iconset)

let size = (try! FileManager.default.attributesOfItem(
    atPath: resources.appendingPathComponent("Emojintel.icns").path)[.size] as! Int)
print("✓ Resources/Emojintel.icns (\(size / 1024) KB)")

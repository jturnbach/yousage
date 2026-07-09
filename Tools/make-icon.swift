// Draws YouSage's app icon and writes Resources/AppIcon.iconset/.
// Run from the repo root:  swift Tools/make-icon.swift
// Then pack it:            iconutil -c icns Resources/AppIcon.iconset -o Resources/AppIcon.icns
//
// The tile echoes the menu bar's gauge SF Symbol so the two read as one app.
// The needle angle is fixed here; only the menu bar symbol tracks real usage.

import AppKit
import Foundation

let colorSpace = CGColorSpace(name: CGColorSpace.sRGB)!

func rgb(_ hex: UInt32) -> CGColor {
    CGColor(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255,
            green: CGFloat((hex >> 8) & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255,
            alpha: 1)
}

/// Fraction of the gauge sweep that reads as consumed.
let fraction = 0.67
/// The arc runs from 210° counter-clockwise-of-east, clockwise over the top to
/// -30°, leaving a 120° gap at the bottom. 240° of sweep in total.
let sweepStart = 210.0
let sweepDegrees = 240.0

func angle(atFraction t: Double) -> CGFloat {
    CGFloat((sweepStart - sweepDegrees * t) * .pi / 180)
}

func draw(_ c: CGContext, _ s: CGFloat) {
    // Tile: warm cream squircle with a hairline border.
    let inset = s * 0.045
    let tile = CGRect(x: inset, y: inset, width: s - inset * 2, height: s - inset * 2)
    let corner = tile.width * 0.2237
    let tilePath = CGPath(roundedRect: tile, cornerWidth: corner, cornerHeight: corner, transform: nil)

    c.saveGState()
    c.addPath(tilePath)
    c.clip()
    let cream = CGGradient(colorsSpace: colorSpace,
                           colors: [rgb(0xFAF7F2), rgb(0xEDE7DE)] as CFArray,
                           locations: [0, 1])!
    c.drawLinearGradient(cream, start: CGPoint(x: 0, y: s), end: .zero, options: [])
    c.restoreGState()

    c.addPath(tilePath)
    c.setStrokeColor(rgb(0xE0D8CC))
    c.setLineWidth(max(1, s * 0.006))
    c.strokePath()

    let center = CGPoint(x: s * 0.5, y: s * 0.44)
    let radius = s * 0.30
    let arcWidth = s * 0.085
    let start = angle(atFraction: 0)
    let end = angle(atFraction: 1)
    let needleAngle = angle(atFraction: fraction)

    // Unconsumed track.
    c.setLineCap(.round)
    c.setLineWidth(arcWidth)
    c.setStrokeColor(rgb(0xD8D0C6))
    c.addArc(center: center, radius: radius, startAngle: start, endAngle: end, clockwise: true)
    c.strokePath()

    // Consumed portion, gradient-filled through a clip of its own stroked path.
    c.saveGState()
    c.setLineCap(.round)
    c.setLineWidth(arcWidth)
    c.addArc(center: center, radius: radius, startAngle: start, endAngle: needleAngle, clockwise: true)
    c.replacePathWithStrokedPath()
    c.clip()
    let terracotta = CGGradient(colorsSpace: colorSpace,
                                colors: [rgb(0xD97757), rgb(0xC4603F)] as CFArray,
                                locations: [0, 1])!
    c.drawLinearGradient(terracotta, start: CGPoint(x: 0, y: s), end: .zero, options: [])
    c.restoreGState()

    // Ticks echo `gauge.with.dots`. Below 128px they collapse into noise.
    if s >= 128 {
        let dot = s * 0.013
        for i in 0...8 {
            let t = Double(i) / 8.0
            let a = angle(atFraction: t)
            let p = CGPoint(x: center.x + cos(a) * radius, y: center.y + sin(a) * radius)
            c.setFillColor(t <= fraction ? rgb(0xFAF7F2) : rgb(0xBFB5A6))
            c.fillEllipse(in: CGRect(x: p.x - dot, y: p.y - dot, width: dot * 2, height: dot * 2))
        }
    }

    // Tapered needle.
    let length = radius * 0.85
    let halfBase = s * 0.022
    let tip = CGPoint(x: center.x + cos(needleAngle) * length,
                      y: center.y + sin(needleAngle) * length)
    let perp = CGPoint(x: -sin(needleAngle), y: cos(needleAngle))
    let needle = CGMutablePath()
    needle.move(to: CGPoint(x: center.x + perp.x * halfBase, y: center.y + perp.y * halfBase))
    needle.addLine(to: tip)
    needle.addLine(to: CGPoint(x: center.x - perp.x * halfBase, y: center.y - perp.y * halfBase))
    needle.closeSubpath()
    c.addPath(needle)
    c.setFillColor(rgb(0x2A2622))
    c.fillPath()

    // Hub.
    let hub = s * 0.055
    c.setFillColor(rgb(0x2A2622))
    c.fillEllipse(in: CGRect(x: center.x - hub, y: center.y - hub, width: hub * 2, height: hub * 2))
    let inner = s * 0.021
    c.setFillColor(rgb(0xFAF7F2))
    c.fillEllipse(in: CGRect(x: center.x - inner, y: center.y - inner, width: inner * 2, height: inner * 2))
}

func render(px: Int) -> Data {
    guard let c = CGContext(data: nil, width: px, height: px,
                            bitsPerComponent: 8, bytesPerRow: 0, space: colorSpace,
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
        fatalError("could not create a \(px)px context")
    }
    c.setAllowsAntialiasing(true)
    draw(c, CGFloat(px))
    let rep = NSBitmapImageRep(cgImage: c.makeImage()!)
    rep.size = NSSize(width: px, height: px)
    guard let data = rep.representation(using: .png, properties: [:]) else {
        fatalError("could not encode a \(px)px PNG")
    }
    return data
}

let sizes: [(px: Int, name: String)] = [
    (16, "icon_16x16.png"),     (32, "icon_16x16@2x.png"),
    (32, "icon_32x32.png"),     (64, "icon_32x32@2x.png"),
    (128, "icon_128x128.png"),  (256, "icon_128x128@2x.png"),
    (256, "icon_256x256.png"),  (512, "icon_256x256@2x.png"),
    (512, "icon_512x512.png"),  (1024, "icon_512x512@2x.png"),
]

let iconset = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
    .appendingPathComponent("Resources/AppIcon.iconset")

do {
    try? FileManager.default.removeItem(at: iconset)
    try FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)
    for (px, name) in sizes {
        try render(px: px).write(to: iconset.appendingPathComponent(name))
        print("  \(name) — \(px)px")
    }
    print("wrote \(sizes.count) images to \(iconset.path)")
} catch {
    fatalError("icon generation failed: \(error)")
}

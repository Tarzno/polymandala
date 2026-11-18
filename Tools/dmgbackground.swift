#!/usr/bin/swift
// Draws the backdrop of the installer disk image.
// Usage: swift Tools/dmgbackground.swift <output.png> [scale]
// Scripts/build-dmg.sh renders it at 1x and 2x and packs both into one TIFF.
//
// All coordinates are Finder's: points, origin top-left. The icon positions
// below must match the ones Scripts/build-dmg.sh hands to Finder.
//
// The backdrop is deliberately mid-toned: Finder draws icon labels black in
// light mode and white in dark mode whatever the picture behind them, and
// only a middle brightness keeps both readable.

import AppKit
import CoreText

let output = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "dmg-background.png"
let scale = CommandLine.arguments.count > 2 ? CGFloat(Double(CommandLine.arguments[2]) ?? 1) : 1

// The window shows 680 x 460; the picture is larger so a slightly bigger
// window never runs out of backdrop.
let width: CGFloat = 760
let height: CGFloat = 520

let appIcon = CGPoint(x: 180, y: 150)
let applicationsIcon = CGPoint(x: 500, y: 150)
let saverIcon = CGPoint(x: 180, y: 330)
let iconSize: CGFloat = 112

guard let space = CGColorSpace(name: CGColorSpace.sRGB),
      let ctx = CGContext(data: nil, width: Int(width * scale), height: Int(height * scale),
                          bitsPerComponent: 8, bytesPerRow: 0, space: space,
                          bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
else {
    print("dmgbackground: cannot create context")
    exit(1)
}
// Work in Finder coordinates: y grows downward.
ctx.scaleBy(x: scale, y: scale)
ctx.translateBy(x: 0, y: height)
ctx.scaleBy(x: 1, y: -1)

func srgb(_ r: CGFloat, _ g: CGFloat, _ b: CGFloat, _ a: CGFloat = 1) -> CGColor {
    CGColor(srgbRed: r, green: g, blue: b, alpha: a)
}
let white = { (alpha: CGFloat) in srgb(1, 1, 1, alpha) }

// Periwinkle ground, a little lighter toward the top left.
if let gradient = CGGradient(colorsSpace: space,
                             colors: [srgb(0.46, 0.48, 0.86), srgb(0.38, 0.38, 0.76)] as CFArray,
                             locations: [0, 1]) {
    ctx.drawLinearGradient(gradient, start: .zero, end: CGPoint(x: width, y: height),
                           options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])
}

/// Runs `body` once per rotation step around `center`.
func rosette(_ count: Int, around center: CGPoint, offset: CGFloat = 0, _ body: () -> Void) {
    for k in 0..<count {
        ctx.saveGState()
        ctx.translateBy(x: center.x, y: center.y)
        ctx.rotate(by: 2 * .pi * (CGFloat(k) + offset) / CGFloat(count))
        body()
        ctx.restoreGState()
    }
}

/// A faint line-art mandala; only ever decoration behind the icons.
func mandala(at center: CGPoint, radius r: CGFloat, folds: Int, strength: CGFloat) {
    ctx.setLineWidth(1.4)
    ctx.setStrokeColor(white(0.16 * strength))
    for ring in [1.0, 0.93, 0.62, 0.30] as [CGFloat] {
        ctx.strokeEllipse(in: CGRect(x: center.x - r * ring, y: center.y - r * ring,
                                     width: 2 * r * ring, height: 2 * r * ring))
    }
    rosette(folds, around: center) { // outer petals
        ctx.setFillColor(white(0.05 * strength))
        let petal = CGRect(x: r * 0.64, y: -r * 0.085, width: r * 0.27, height: r * 0.17)
        ctx.fillEllipse(in: petal)
        ctx.strokeEllipse(in: petal)
    }
    rosette(folds, around: center, offset: 0.5) { // inner petals and spokes
        ctx.setFillColor(white(0.07 * strength))
        let petal = CGRect(x: r * 0.33, y: -r * 0.06, width: r * 0.26, height: r * 0.12)
        ctx.fillEllipse(in: petal)
        ctx.strokeEllipse(in: petal)
        ctx.move(to: CGPoint(x: r * 0.62, y: 0))
        ctx.addLine(to: CGPoint(x: r * 0.93, y: 0))
        ctx.strokePath()
        ctx.setFillColor(white(0.18 * strength))
        ctx.fillEllipse(in: CGRect(x: r * 0.965 - 2.5, y: -2.5, width: 5, height: 5))
    }
    rosette(folds, around: center) { // small petals around the middle
        ctx.setFillColor(white(0.09 * strength))
        ctx.fillEllipse(in: CGRect(x: r * 0.12, y: -r * 0.035, width: r * 0.15, height: r * 0.07))
    }
    ctx.setFillColor(white(0.10 * strength))
    ctx.fillEllipse(in: CGRect(x: center.x - r * 0.08, y: center.y - r * 0.08,
                               width: r * 0.16, height: r * 0.16))
}

mandala(at: CGPoint(x: 610, y: 400), radius: 250, folds: 16, strength: 1)
mandala(at: CGPoint(x: 40, y: 20), radius: 150, folds: 12, strength: 0.8)

/// Draws one line of text; `x` is its left edge, or its center with `centered`.
func text(_ string: String, x: CGFloat, baseline y: CGFloat, size: CGFloat, bold: Bool = false,
          alpha: CGFloat = 1, centered: Bool = false) {
    let font = bold ? NSFont.systemFont(ofSize: size, weight: .semibold) : NSFont.systemFont(ofSize: size)
    let line = CTLineCreateWithAttributedString(NSAttributedString(string: string, attributes: [
        .font: font, .foregroundColor: NSColor(srgbRed: 1, green: 1, blue: 1, alpha: alpha),
    ]))
    let lineWidth = CGFloat(CTLineGetTypographicBounds(line, nil, nil, nil))
    ctx.saveGState()
    // Core Text draws y-up: undo the flip around the baseline.
    ctx.translateBy(x: centered ? x - lineWidth / 2 : x, y: y)
    ctx.scaleBy(x: 1, y: -1)
    ctx.textPosition = .zero
    CTLineDraw(line, ctx)
    ctx.restoreGState()
}

// "Drag the app onto Applications": an arrow between the two icons.
do {
    let from = appIcon.x + iconSize / 2 + 34
    let to = applicationsIcon.x - iconSize / 2 - 34
    let y = appIcon.y - 6
    ctx.setStrokeColor(white(0.92))
    ctx.setLineWidth(5)
    ctx.setLineCap(.round)
    ctx.setLineJoin(.round)
    ctx.move(to: CGPoint(x: from, y: y))
    ctx.addLine(to: CGPoint(x: to, y: y))
    ctx.move(to: CGPoint(x: to - 15, y: y - 13))
    ctx.addLine(to: CGPoint(x: to, y: y))
    ctx.addLine(to: CGPoint(x: to - 15, y: y + 13))
    ctx.strokePath()
    text("drag to install", x: (from + to) / 2, baseline: y + 30, size: 12.5, alpha: 0.9, centered: true)
}

// The screensaver sits below the app, with its instructions beside it.
do {
    let x = saverIcon.x + iconSize / 2 + 34
    text("The screensaver", x: x, baseline: saverIcon.y - 12, size: 15, bold: true)
    text("Double-click to install it.", x: x, baseline: saverIcon.y + 9, size: 12.5, alpha: 0.92)
    text("Every display builds its own mandala.", x: x, baseline: saverIcon.y + 27, size: 12.5, alpha: 0.92)
}

guard let image = ctx.makeImage(),
      let data = NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:])
else {
    print("dmgbackground: cannot render")
    exit(1)
}
do {
    try data.write(to: URL(fileURLWithPath: output))
    print("dmgbackground: wrote \(output) (\(image.width) x \(image.height))")
} catch {
    print("dmgbackground: \(error.localizedDescription)")
    exit(1)
}

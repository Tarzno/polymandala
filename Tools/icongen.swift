#!/usr/bin/swift
// Generates the 1024px master app icon PNG (rounded-rect mandala motif).
// Usage: swift Tools/icongen.swift <output.png>
// Scripts/build-icon.sh resizes it into an .iconset and packs AppIcon.icns.

import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

let output = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "AppIcon-1024.png"
let size = 1024

guard let space = CGColorSpace(name: CGColorSpace.sRGB),
      let ctx = CGContext(data: nil, width: size, height: size,
                          bitsPerComponent: 8, bytesPerRow: size * 4,
                          space: space,
                          bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
else {
    print("icongen: cannot create context")
    exit(1)
}

func srgb(_ r: CGFloat, _ g: CGFloat, _ b: CGFloat, _ a: CGFloat = 1) -> CGColor {
    CGColor(srgbRed: r, green: g, blue: b, alpha: a)
}

let mid = CGPoint(x: 512, y: 512)

// macOS icon grid: squircle content ~824pt centered in the 1024 canvas.
let iconRect = CGRect(x: 100, y: 100, width: 824, height: 824)
let rounded = CGPath(roundedRect: iconRect, cornerWidth: 185, cornerHeight: 185, transform: nil)
ctx.addPath(rounded)
ctx.clip()

// Background: deep indigo with a subtle radial lightening toward the center.
ctx.setFillColor(srgb(0.20, 0.16, 0.42))
ctx.fill(iconRect)
if let gradient = CGGradient(colorsSpace: space,
                             colors: [srgb(0.33, 0.27, 0.60, 0.9), srgb(0.20, 0.16, 0.42, 0)] as CFArray,
                             locations: [0, 1]) {
    ctx.drawRadialGradient(gradient, startCenter: mid, startRadius: 0,
                           endCenter: mid, endRadius: 430, options: [])
}

func withRotations(_ count: Int, _ body: (CGContext) -> Void) {
    for k in 0..<count {
        ctx.saveGState()
        ctx.translateBy(x: mid.x, y: mid.y)
        ctx.rotate(by: 2 * .pi * CGFloat(k) / CGFloat(count))
        ctx.translateBy(x: -mid.x, y: -mid.y)
        body(ctx)
        ctx.restoreGState()
    }
}

// Outer ring
ctx.setStrokeColor(srgb(0.96, 0.92, 0.80))
ctx.setLineWidth(10)
ctx.strokeEllipse(in: CGRect(x: mid.x - 340, y: mid.y - 340, width: 680, height: 680))

// Outer petals (12-fold, teal with cream outline)
withRotations(12) { c in
    let petal = CGRect(x: mid.x + 155, y: mid.y - 46, width: 172, height: 92)
    c.setFillColor(srgb(0.36, 0.74, 0.71))
    c.fillEllipse(in: petal)
    c.setStrokeColor(srgb(0.96, 0.92, 0.80))
    c.setLineWidth(7)
    c.strokeEllipse(in: petal)
}

// Inner petals (12-fold, gold)
withRotations(12) { c in
    c.saveGState()
    c.translateBy(x: mid.x, y: mid.y)
    c.rotate(by: .pi / 12)
    c.translateBy(x: -mid.x, y: -mid.y)
    let petal = CGRect(x: mid.x + 62, y: mid.y - 30, width: 112, height: 60)
    c.setFillColor(srgb(0.94, 0.74, 0.30))
    c.fillEllipse(in: petal)
    c.restoreGState()
}

// Accent dots between outer petals
withRotations(12) { c in
    c.saveGState()
    c.translateBy(x: mid.x, y: mid.y)
    c.rotate(by: .pi / 12)
    c.translateBy(x: -mid.x, y: -mid.y)
    c.setFillColor(srgb(0.82, 0.25, 0.35))
    c.fillEllipse(in: CGRect(x: mid.x + 282, y: mid.y - 14, width: 28, height: 28))
    c.restoreGState()
}

// Center disk
ctx.setFillColor(srgb(0.90, 0.55, 0.60))
ctx.fillEllipse(in: CGRect(x: mid.x - 62, y: mid.y - 62, width: 124, height: 124))
ctx.setStrokeColor(srgb(0.96, 0.92, 0.80))
ctx.setLineWidth(8)
ctx.strokeEllipse(in: CGRect(x: mid.x - 62, y: mid.y - 62, width: 124, height: 124))

guard let image = ctx.makeImage(),
      let dest = CGImageDestinationCreateWithURL(URL(fileURLWithPath: output) as CFURL,
                                                 UTType.png.identifier as CFString, 1, nil)
else {
    print("icongen: cannot write \(output)")
    exit(1)
}
CGImageDestinationAddImage(dest, image, nil)
guard CGImageDestinationFinalize(dest) else {
    print("icongen: finalize failed")
    exit(1)
}
print("icongen: wrote \(output)")

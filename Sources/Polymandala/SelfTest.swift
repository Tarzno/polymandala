import AppKit
import CoreGraphics
import Foundation
import UniformTypeIdentifiers

// Headless verification: `Polymandala --selftest` and `Polymandala --snapshot <png>`.
// Screen recording is blocked on this machine, so the binary proves its own
// rendering behavior via direct pixel checks.

private func rotate(_ p: CGPoint, around c: CGPoint, by angle: CGFloat) -> CGPoint {
    let dx = p.x - c.x
    let dy = p.y - c.y
    return CGPoint(x: c.x + dx * cos(angle) - dy * sin(angle),
                   y: c.y + dx * sin(angle) + dy * cos(angle))
}

private func dot(at p: CGPoint, width: Double, color: RGBAColor, symmetry: SymmetryCenter) -> DrawOp {
    .stroke(StrokeOp(tool: .brush, color: color, width: width, points: [p], symmetries: [symmetry]))
}

private func circleOp(center: CGPoint, radius: CGFloat, width: Double, color: RGBAColor,
                      symmetry: SymmetryCenter) -> DrawOp {
    .stroke(StrokeOp(tool: .ellipse, color: color, width: width,
                     points: [CGPoint(x: center.x - radius, y: center.y - radius),
                              CGPoint(x: center.x + radius, y: center.y + radius)],
                     symmetries: [symmetry]))
}

private func matches(_ pixel: (r: UInt8, g: UInt8, b: UInt8, a: UInt8)?,
                     _ expected: (r: Int, g: Int, b: Int, a: Int), tolerance: Int = 6) -> Bool {
    guard let p = pixel else { return false }
    return abs(Int(p.r) - expected.r) <= tolerance
        && abs(Int(p.g) - expected.g) <= tolerance
        && abs(Int(p.b) - expected.b) <= tolerance
        && abs(Int(p.a) - expected.a) <= tolerance
}

// MARK: - SVG export verification helpers

private func bitmapContext(width: Int, height: Int) -> CGContext? {
    guard let space = CGColorSpace(name: CGColorSpace.sRGB) else { return nil }
    return CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
                     bytesPerRow: width * 4, space: space,
                     bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
}

private func bytes(of context: CGContext) -> [UInt8] {
    let pointer = context.data!.assumingMemoryBound(to: UInt8.self)
    return Array(UnsafeBufferPointer(start: pointer, count: context.bytesPerRow * context.height))
}

/// The document as the app shows and PNG-exports it (RGBA, row 0 on top).
private func rasterPixels(ops: [DrawOp], config: CanvasConfig) -> [UInt8]? {
    guard let renderer = CanvasRenderer(width: config.width, height: config.height),
          let context = bitmapContext(width: config.width, height: config.height) else { return nil }
    renderer.layer.fallbackBackground = config.background
    renderer.rebuildAll(ops: ops)
    guard let image = renderer.layer.compositedImage(background: config.background) else { return nil }
    context.draw(image, in: CGRect(x: 0, y: 0, width: config.width, height: config.height))
    return bytes(of: context)
}

/// SVG text rasterized by AppKit at `scale` × its nominal size (RGBA, row 0 on top).
private func svgPixels(_ svg: String, width: Int, height: Int, scale: Int = 1) -> [UInt8]? {
    guard let image = NSImage(data: Data(svg.utf8)),
          let context = bitmapContext(width: width * scale, height: height * scale) else { return nil }
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: false)
    image.draw(in: NSRect(x: 0, y: 0, width: width * scale, height: height * scale))
    NSGraphicsContext.restoreGraphicsState()
    return bytes(of: context)
}

private struct SVGComparison {
    /// Share of pixels differing from the raster by more than 64 in a channel.
    var mismatch = 1.0
    /// Share of pixels showing bare background in the SVG where the raster
    /// has paint — what a seam between a fill and its outline looks like.
    var holes = 1.0
}

/// A one-page PDF rasterized by Core Graphics at `scale` × its page size
/// (RGBA, row 0 on top). Nil unless it is exactly one page of that size.
private func pdfPixels(_ pdf: Data, width: Int, height: Int, scale: Int = 1) -> [UInt8]? {
    guard let provider = CGDataProvider(data: pdf as CFData),
          let document = CGPDFDocument(provider), document.numberOfPages == 1,
          let page = document.page(at: 1),
          page.getBoxRect(.mediaBox) == CGRect(x: 0, y: 0, width: width, height: height),
          let context = bitmapContext(width: width * scale, height: height * scale) else { return nil }
    context.scaleBy(x: CGFloat(scale), y: CGFloat(scale))
    context.drawPDFPage(page)
    return bytes(of: context)
}

/// Exports the ops as SVG, rasterizes it, and compares with the raster render.
private func compareSVG(ops: [DrawOp], config: CanvasConfig) -> SVGComparison {
    guard let svg = VectorExporter.svg(ops: ops, config: config) else { return SVGComparison() }
    return compareWithRaster(svgPixels(svg, width: config.width, height: config.height),
                             ops: ops, config: config)
}

/// The same for the PDF export.
private func comparePDF(ops: [DrawOp], config: CanvasConfig) -> SVGComparison {
    guard let pdf = VectorExporter.pdf(ops: ops, config: config) else { return SVGComparison() }
    return compareWithRaster(pdfPixels(pdf, width: config.width, height: config.height),
                             ops: ops, config: config)
}

private func compareWithRaster(_ vector: [UInt8]?, ops: [DrawOp], config: CanvasConfig) -> SVGComparison {
    guard let vector, let raster = rasterPixels(ops: ops, config: config) else { return SVGComparison() }
    let bg = config.background.premultipliedBytes
    let background = [Int(bg.r), Int(bg.g), Int(bg.b)]
    var mismatched = 0
    var holes = 0
    let count = config.width * config.height
    for i in 0..<count {
        var difference = 0
        var vectorFromBackground = 0
        var rasterFromBackground = 0
        for c in 0..<3 {
            let v = Int(vector[i * 4 + c])
            let r = Int(raster[i * 4 + c])
            difference = max(difference, abs(v - r))
            vectorFromBackground = max(vectorFromBackground, abs(v - background[c]))
            rasterFromBackground = max(rasterFromBackground, abs(r - background[c]))
        }
        if difference > 64 { mismatched += 1 }
        if vectorFromBackground <= 12 && rasterFromBackground > 96 { holes += 1 }
    }
    return SVGComparison(mismatch: Double(mismatched) / Double(count),
                         holes: Double(holes) / Double(count))
}

/// Position of the first SVG element painted in `hex` (as fill or stroke).
private func position(of attribute: String, _ hex: String, in svg: String) -> Int? {
    guard let range = svg.range(of: "\(attribute)=\"\(hex)\"") else { return nil }
    return svg.distance(from: svg.startIndex, to: range.lowerBound)
}

func runSelfTest() -> Int32 {
    var failures = 0
    // POLYMANDALA_SELFTEST_VERBOSE=1 also prints the measured values of passing checks.
    let verbose = ProcessInfo.processInfo.environment["POLYMANDALA_SELFTEST_VERBOSE"] != nil
    func check(_ name: String, _ condition: Bool, _ detail: String = "") {
        if condition {
            print(verbose && !detail.isEmpty ? "PASS \(name) [\(detail)]" : "PASS \(name)")
        } else {
            print("FAIL \(name) \(detail)")
            failures += 1
        }
    }

    let red = RGBAColor(r: 1, g: 0, b: 0, a: 1)
    let blue = RGBAColor(r: 0, g: 0, b: 1, a: 1)
    let green = RGBAColor(r: 0, g: 1, b: 0, a: 1)
    let black = RGBAColor.black
    let mid = CGPoint(x: 256, y: 256)

    // 1. Six-fold rotational symmetry: one dot appears at all six rotations.
    do {
        let layer = RasterLayer(width: 512, height: 512)!
        let symmetry = SymmetryCenter(position: mid, foldCount: 6, mirror: false)
        let p = CGPoint(x: 336, y: 256) // radius 80
        layer.render(dot(at: p, width: 24, color: red, symmetry: symmetry))
        for k in 0..<6 {
            let q = rotate(p, around: mid, by: 2 * .pi * CGFloat(k) / 6)
            let px = layer.pixel(atX: Int(q.x.rounded()), y: Int(q.y.rounded()))
            check("rotation copy \(k)", matches(px, (255, 0, 0, 255)), "at \(q) got \(String(describing: px))")
        }
        let between = rotate(p, around: mid, by: .pi / 6) // 30°: between copies
        let px = layer.pixel(atX: Int(between.x.rounded()), y: Int(between.y.rounded()))
        check("no paint between copies", matches(px, (0, 0, 0, 0)), "got \(String(describing: px))")
    }

    // 2. Mirror doubles the copies across the vertical axis through the center.
    do {
        let layer = RasterLayer(width: 512, height: 512)!
        let symmetry = SymmetryCenter(position: mid, foldCount: 1, mirror: true)
        layer.render(dot(at: CGPoint(x: 336, y: 300), width: 24, color: red, symmetry: symmetry))
        check("mirror original", matches(layer.pixel(atX: 336, y: 300), (255, 0, 0, 255)))
        check("mirror reflection", matches(layer.pixel(atX: 176, y: 300), (255, 0, 0, 255)))
    }

    // 3. Flood fill stays inside a stroked circle.
    do {
        let layer = RasterLayer(width: 512, height: 512)!
        let symmetry = SymmetryCenter(position: mid, foldCount: 1, mirror: false)
        layer.render(circleOp(center: mid, radius: 100, width: 6, color: black, symmetry: symmetry))
        layer.render(.fill(FillOp(color: blue, seed: mid, tolerance: 0.08, symmetries: [symmetry])))
        check("fill inside", matches(layer.pixel(atX: 256, y: 256), (0, 0, 255, 255)))
        check("fill stays inside boundary", matches(layer.pixel(atX: 400, y: 256), (0, 0, 0, 0)))
        let ring = layer.pixel(atX: 356, y: 256)
        check("boundary stroke intact", ring != nil && ring!.a == 255 && ring!.r <= 10 && ring!.g <= 10,
              "got \(String(describing: ring))")
    }

    // 4. Symmetric fill: one click fills all six rotated petals.
    do {
        let layer = RasterLayer(width: 512, height: 512)!
        let symmetry = SymmetryCenter(position: mid, foldCount: 6, mirror: false)
        let petalCenter = CGPoint(x: 356, y: 256)
        layer.render(circleOp(center: petalCenter, radius: 30, width: 4, color: black, symmetry: symmetry))
        layer.render(.fill(FillOp(color: green, seed: petalCenter, tolerance: 0.08, symmetries: [symmetry])))
        for k in 0..<6 {
            let q = rotate(petalCenter, around: mid, by: 2 * .pi * CGFloat(k) / 6)
            let px = layer.pixel(atX: Int(q.x.rounded()), y: Int(q.y.rounded()))
            check("symmetric fill petal \(k)", matches(px, (0, 255, 0, 255)), "at \(q) got \(String(describing: px))")
        }
    }

    // 5. Save/load round-trip is byte-stable and renders identically.
    do {
        let document = DrawingDocument.makeDefault(width: 128, height: 128)
        let symmetry = document.centers[0]
        document.ops = [
            dot(at: CGPoint(x: 80, y: 64), width: 10, color: red, symmetry: symmetry),
            .stroke(StrokeOp(tool: .line, color: blue, width: 3,
                             points: [CGPoint(x: 20, y: 20), CGPoint(x: 100, y: 40)], symmetries: [symmetry])),
            circleOp(center: CGPoint(x: 64, y: 64), radius: 30, width: 3, color: black, symmetry: symmetry),
            .fill(FillOp(color: green, seed: CGPoint(x: 64, y: 64), tolerance: 0.08, symmetries: [symmetry])),
        ]
        do {
            let data1 = try document.snapshotData()
            let loaded = try DrawingDocument.fromData(data1)
            let data2 = try loaded.snapshotData()
            check("save/load byte round-trip", data1 == data2)
            let r1 = CanvasRenderer(width: 128, height: 128)!
            r1.rebuildAll(ops: document.ops)
            let r2 = CanvasRenderer(width: 128, height: 128)!
            r2.rebuildAll(ops: loaded.ops)
            check("save/load renders identically", r1.layer.snapshotData() == r2.layer.snapshotData())
        } catch {
            check("save/load round-trip", false, "\(error)")
        }
    }

    // 6. Undo/redo rewind matches a fresh render of the same prefix.
    do {
        let symmetry = SymmetryCenter(position: mid, foldCount: 4, mirror: true)
        let ops: [DrawOp] = [
            dot(at: CGPoint(x: 336, y: 256), width: 20, color: red, symmetry: symmetry),
            .stroke(StrokeOp(tool: .line, color: blue, width: 6,
                             points: [CGPoint(x: 300, y: 300), CGPoint(x: 400, y: 380)], symmetries: [symmetry])),
            dot(at: CGPoint(x: 256, y: 356), width: 20, color: green, symmetry: symmetry),
        ]
        let renderer = CanvasRenderer(width: 512, height: 512)!
        renderer.rebuildAll(ops: ops)
        renderer.rewind(to: 2, ops: ops)
        let fresh2 = CanvasRenderer(width: 512, height: 512)!
        fresh2.rebuildAll(ops: Array(ops.prefix(2)))
        check("undo matches fresh render", renderer.layer.snapshotData() == fresh2.layer.snapshotData())
        renderer.append(ops[2])
        let fresh3 = CanvasRenderer(width: 512, height: 512)!
        fresh3.rebuildAll(ops: ops)
        check("redo matches fresh render", renderer.layer.snapshotData() == fresh3.layer.snapshotData())
    }

    // 7. Rewind across a bitmap checkpoint (interval 20) stays correct.
    do {
        let symmetry = SymmetryCenter(position: mid, foldCount: 3, mirror: false)
        var ops: [DrawOp] = []
        for i in 0..<25 {
            let angle = CGFloat(i) * 0.25
            let p = CGPoint(x: 256 + 150 * cos(angle), y: 256 + 150 * sin(angle))
            ops.append(dot(at: p, width: 12, color: i % 2 == 0 ? red : blue, symmetry: symmetry))
        }
        let renderer = CanvasRenderer(width: 512, height: 512)!
        renderer.rebuildAll(ops: ops)
        renderer.rewind(to: 23, ops: ops)
        let fresh = CanvasRenderer(width: 512, height: 512)!
        fresh.rebuildAll(ops: Array(ops.prefix(23)))
        check("checkpoint rewind matches fresh render", renderer.layer.snapshotData() == fresh.layer.snapshotData())
    }

    // 8. One stroke drawn with two active centers replicates around both.
    do {
        let layer = RasterLayer(width: 512, height: 512)!
        let centerA = SymmetryCenter(position: CGPoint(x: 200, y: 256), foldCount: 2, mirror: false)
        let centerB = SymmetryCenter(position: CGPoint(x: 312, y: 256), foldCount: 2, mirror: false)
        let p = CGPoint(x: 256, y: 306)
        layer.render(.stroke(StrokeOp(tool: .brush, color: red, width: 20,
                                      points: [p], symmetries: [centerA, centerB])))
        let expectations: [(String, CGPoint)] = [
            ("original point", p),
            ("180° about center A", rotate(p, around: centerA.position, by: .pi)),
            ("180° about center B", rotate(p, around: centerB.position, by: .pi)),
        ]
        for (name, q) in expectations {
            let px = layer.pixel(atX: Int(q.x.rounded()), y: Int(q.y.rounded()))
            check("multi-center \(name)", matches(px, (255, 0, 0, 255)), "at \(q) got \(String(describing: px))")
        }
    }

    // 9. Legacy v1 formats (single `symmetry` key, `activeCenterIndex`) still load.
    do {
        let legacyOp = """
        {"color":{"a":1,"b":0,"g":0,"r":1},"points":[[256,306]],"symmetry":{"foldCount":2,\
        "id":"00000000-0000-0000-0000-000000000001","mirror":false,"position":[200,256]},\
        "tool":"brush","width":10}
        """
        do {
            let stroke = try JSONDecoder().decode(StrokeOp.self, from: Data(legacyOp.utf8))
            check("legacy op decodes to one symmetry center",
                  stroke.symmetries.count == 1
                  && stroke.symmetries[0].foldCount == 2
                  && stroke.symmetries[0].position == CGPoint(x: 200, y: 256))
        } catch {
            check("legacy op decodes to one symmetry center", false, "\(error)")
        }

        let legacyDoc = """
        {"version":1,"config":{"width":128,"height":128,"background":{"a":1,"b":1,"g":1,"r":1}},\
        "centers":[{"foldCount":6,"id":"00000000-0000-0000-0000-000000000002","mirror":true,\
        "position":[64,64]}],"activeCenterIndex":0,"ops":[]}
        """
        do {
            let document = try DrawingDocument.fromData(Data(legacyDoc.utf8))
            check("legacy document activates its center",
                  document.activeCenterIDs == [document.centers[0].id]
                  && document.primaryCenterID == document.centers[0].id)
        } catch {
            check("legacy document activates its center", false, "\(error)")
        }
    }

    // 10. Linked mode: the master's exact motif is stamped (translated) at the
    // secondary center — not replicated around it independently.
    do {
        let layer = RasterLayer(width: 512, height: 512)!
        let master = SymmetryCenter(position: CGPoint(x: 200, y: 256), foldCount: 2, mirror: false)
        let secondary = SymmetryCenter(position: CGPoint(x: 312, y: 306), foldCount: 2, mirror: false)
        let delta = CGPoint(x: 112, y: 50)
        let p = CGPoint(x: 256, y: 306)
        layer.render(.stroke(StrokeOp(tool: .brush, color: red, width: 20,
                                      points: [p], symmetries: [master, secondary], linked: true)))
        let rotated = rotate(p, around: master.position, by: .pi)
        let expectations: [(String, CGPoint)] = [
            ("master original", p),
            ("master 180°", rotated),
            ("stamped original", CGPoint(x: p.x + delta.x, y: p.y + delta.y)),
            ("stamped 180°", CGPoint(x: rotated.x + delta.x, y: rotated.y + delta.y)),
        ]
        for (name, q) in expectations {
            let px = layer.pixel(atX: Int(q.x.rounded()), y: Int(q.y.rounded()))
            check("linked \(name)", matches(px, (255, 0, 0, 255)), "at \(q) got \(String(describing: px))")
        }
        // Where independent mode would have painted (180° about the secondary):
        let independent = rotate(p, around: secondary.position, by: .pi)
        let px = layer.pixel(atX: Int(independent.x.rounded()), y: Int(independent.y.rounded()))
        check("linked skips independent replication", matches(px, (0, 0, 0, 0)),
              "at \(independent) got \(String(describing: px))")
    }

    // 11. Rectangle and triangle primitives outline their bounding geometry.
    do {
        let layer = RasterLayer(width: 512, height: 512)!
        let none = SymmetryCenter(position: mid, foldCount: 1, mirror: false)
        layer.render(.stroke(StrokeOp(tool: .rectangle, color: black, width: 4,
                                      points: [CGPoint(x: 100, y: 100), CGPoint(x: 200, y: 160)],
                                      symmetries: [none])))
        check("rectangle bottom edge", matches(layer.pixel(atX: 150, y: 100), (0, 0, 0, 255)))
        check("rectangle left edge", matches(layer.pixel(atX: 100, y: 130), (0, 0, 0, 255)))
        check("rectangle interior empty", matches(layer.pixel(atX: 150, y: 130), (0, 0, 0, 0)))

        layer.render(.stroke(StrokeOp(tool: .triangle, color: black, width: 4,
                                      points: [CGPoint(x: 300, y: 100), CGPoint(x: 400, y: 200)],
                                      symmetries: [none])))
        check("triangle apex", matches(layer.pixel(atX: 350, y: 200), (0, 0, 0, 255)))
        check("triangle base", matches(layer.pixel(atX: 350, y: 100), (0, 0, 0, 255)))
        check("triangle side", matches(layer.pixel(atX: 325, y: 150), (0, 0, 0, 255)))
        check("triangle interior empty", matches(layer.pixel(atX: 350, y: 130), (0, 0, 0, 0)))
    }

    // 12. Linked mode anchors the pattern at the active center nearest the stroke.
    do {
        let document = DrawingDocument.makeDefault(width: 128, height: 128)
        let centerA = SymmetryCenter(position: CGPoint(x: 30, y: 64), foldCount: 4, mirror: false)
        let centerB = SymmetryCenter(position: CGPoint(x: 98, y: 64), foldCount: 4, mirror: false)
        document.centers = [centerA, centerB]
        document.activeCenterIDs = [centerA.id, centerB.id]
        document.primaryCenterID = centerA.id
        document.linkedCenters = true
        if let controller = DrawingController(document: document) {
            check("nearest anchor picks center B",
                  controller.strokeSymmetries(near: CGPoint(x: 90, y: 60)).first?.id == centerB.id)
            check("nearest anchor picks center A",
                  controller.strokeSymmetries(near: CGPoint(x: 35, y: 70)).first?.id == centerA.id)
            controller.linkedCenters = false
            check("unlinked anchor stays primary",
                  controller.strokeSymmetries(near: CGPoint(x: 90, y: 60)).first?.id == centerA.id)
        } else {
            check("nearest anchor controller setup", false)
        }
    }

    // 13. Shift constraints: circle/square, equilateral triangle, 45° line snap.
    do {
        let origin = CGPoint(x: 100, y: 20)
        func closeEnough(_ a: CGPoint, _ b: CGPoint) -> Bool {
            abs(a.x - b.x) < 0.01 && abs(a.y - b.y) < 0.01
        }
        let square = CanvasView.constrainedEnd(CGPoint(x: 140, y: 30), from: origin, tool: .rectangle)
        check("shift square uses dominant axis", closeEnough(square, CGPoint(x: 140, y: 60)),
              "got \(square)")
        let circle = CanvasView.constrainedEnd(CGPoint(x: 90, y: 60), from: origin, tool: .ellipse)
        check("shift circle keeps drag direction", closeEnough(circle, CGPoint(x: 60, y: 60)),
              "got \(circle)")
        let tri = CanvasView.constrainedEnd(CGPoint(x: 140, y: 30), from: origin, tool: .triangle)
        let w = tri.x - origin.x
        let h = tri.y - origin.y
        let base = w
        let slant = hypot(w / 2, h)
        check("shift triangle is equilateral", abs(slant - base) < 0.01,
              "base \(base) slant \(slant)")
        let line = CanvasView.constrainedEnd(CGPoint(x: 140, y: 28), from: origin, tool: .line)
        check("shift line snaps to 45° step", abs(line.y - origin.y) < 0.01 && line.x > origin.x,
              "got \(line)")
        let diag = CanvasView.constrainedEnd(CGPoint(x: 200, y: 130), from: origin, tool: .line)
        let angle = atan2(diag.y - origin.y, diag.x - origin.x)
        check("shift line snaps to diagonal", abs(angle - .pi / 4) < 0.001, "angle \(angle)")
    }

    // 14. Fill reaches symmetry copies clipped by the canvas boundary, whose
    // transformed seed lands off-canvas (regression: right-edge fragments).
    do {
        let layer = RasterLayer(width: 256, height: 256)!
        let symmetry = SymmetryCenter(position: CGPoint(x: 240, y: 128), foldCount: 2, mirror: false)
        // Circle at (200,128) r=30; its 180° copy is centered off-canvas at
        // (280,128) — only a sliver of it (x ≥ 250) is on the canvas.
        layer.render(circleOp(center: CGPoint(x: 200, y: 128), radius: 30, width: 4,
                              color: black, symmetry: symmetry))
        layer.render(.fill(FillOp(color: blue, seed: CGPoint(x: 200, y: 128),
                                  tolerance: 0.08, symmetries: [symmetry])))
        check("fill original circle", matches(layer.pixel(atX: 200, y: 128), (0, 0, 255, 255)))
        check("fill clipped edge fragment", matches(layer.pixel(atX: 254, y: 128), (0, 0, 255, 255)),
              "got \(String(describing: layer.pixel(atX: 254, y: 128)))")
        check("fill does not leak past fragment", matches(layer.pixel(atX: 254, y: 180), (0, 0, 0, 0)),
              "got \(String(describing: layer.pixel(atX: 254, y: 180)))")
    }

    // 15. Brush smoothing damps jitter while preserving the intended path.
    do {
        var jittery: [CGPoint] = []
        for i in 0...20 {
            jittery.append(CGPoint(x: 100 + CGFloat(i) * 10, y: i % 2 == 0 ? 104 : 96))
        }
        let smooth = StrokeGeometry.smoothedBrushPoints(jittery)
        let maxDeviation = smooth.dropFirst().dropLast().map { abs($0.y - 100) }.max() ?? 0
        check("smoothing damps jitter", maxDeviation < 2.0, "max deviation \(maxDeviation)")
        check("smoothing keeps endpoints",
              smooth.first == jittery.first && smooth.last == jittery.last)
        check("smoothing keeps point count", smooth.count == jittery.count)

        // A deliberate straight diagonal must pass through unchanged.
        let straight = (0...10).map { CGPoint(x: CGFloat($0) * 10, y: CGFloat($0) * 10) }
        let smoothStraight = StrokeGeometry.smoothedBrushPoints(straight)
        let straightDeviation = zip(straight, smoothStraight)
            .map { hypot($0.x - $1.x, $0.y - $1.y) }.max() ?? 0
        check("smoothing preserves straight strokes", straightDeviation < 0.001,
              "deviation \(straightDeviation)")
    }

    // 16. Zoom keeps the anchored canvas point fixed and clamps sensibly.
    do {
        let document = DrawingDocument.makeDefault(width: 512, height: 512)
        if let controller = DrawingController(document: document) {
            let view = CanvasView(frame: NSRect(x: 0, y: 0, width: 800, height: 600))
            view.controller = controller
            let anchor = CGPoint(x: 500, y: 400)
            let before = view.canvasPoint(at: anchor)
            view.setZoom(3, anchor: anchor)
            let after = view.canvasPoint(at: anchor)
            check("zoom keeps anchor fixed", hypot(after.x - before.x, after.y - before.y) < 0.01,
                  "before \(before) after \(after)")
            check("zoom value applied", abs(view.zoom - 3) < 0.001)
            view.setZoom(100)
            check("zoom clamps to 16x", abs(view.zoom - 16) < 0.001)
            view.zoomToFit()
            check("zoom to fit resets", abs(view.zoom - 1) < 0.001)
            let corner = view.canvasPoint(at: CGPoint(x: 400, y: 300))
            check("fit view centers canvas",
                  abs(corner.x - 256) < 1 && abs(corner.y - 256) < 1, "center maps to \(corner)")
        } else {
            check("zoom controller setup", false)
        }
    }

    // 17. Clear Canvas wipes the layer, undoes by replay, and round-trips.
    do {
        let symmetry = SymmetryCenter(position: mid, foldCount: 6, mirror: false)
        let ops: [DrawOp] = [
            dot(at: CGPoint(x: 336, y: 256), width: 24, color: red, symmetry: symmetry),
            .clear,
        ]
        let renderer = CanvasRenderer(width: 512, height: 512)!
        renderer.rebuildAll(ops: ops)
        check("clear wipes the canvas", matches(renderer.layer.pixel(atX: 336, y: 256), (0, 0, 0, 0)))
        renderer.rewind(to: 1, ops: ops)
        check("undo restores cleared artwork",
              matches(renderer.layer.pixel(atX: 336, y: 256), (255, 0, 0, 255)))
        renderer.append(ops[1])
        check("redo clears again", matches(renderer.layer.pixel(atX: 336, y: 256), (0, 0, 0, 0)))

        let document = DrawingDocument.makeDefault(width: 128, height: 128)
        document.ops = [dot(at: CGPoint(x: 64, y: 64), width: 10, color: red,
                            symmetry: document.centers[0]), .clear]
        do {
            let data = try document.snapshotData()
            let loaded = try DrawingDocument.fromData(data)
            check("clear op round-trips through save/load", loaded.ops == document.ops)
        } catch {
            check("clear op round-trips through save/load", false, "\(error)")
        }

        if let controller = DrawingController(document: DrawingDocument.makeDefault(width: 64, height: 64)) {
            check("clear disabled on empty canvas", !controller.canClear)
            controller.commit(dot(at: CGPoint(x: 32, y: 32), width: 6, color: red,
                                  symmetry: controller.primaryCenter))
            check("clear enabled after drawing", controller.canClear)
            controller.clearCanvas()
            check("clear disabled right after clearing", !controller.canClear)
            check("clear is undoable", controller.canUndo)
        } else {
            check("clear controller setup", false)
        }
    }

    // 18. The open panel must accept .polymandala files. Regression: a dynamic
    // type built with `conformingTo: .json` differs from the extension-derived
    // type Launch Services assigns the files, greying them all out.
    do {
        let fileType = UTType(filenameExtension: "polymandala") ?? .data
        check("open panel accepts .polymandala files",
              polymandalaContentTypes().contains { fileType.conforms(to: $0) },
              "file type \(fileType.identifier) matches none of "
                  + polymandalaContentTypes().map(\.identifier).joined(separator: ", "))
    }

    // 19. Fill matching compares *visible* colors. Regression: matching raw
    // layer bytes made opaque paint in the background color an invisible wall
    // (alpha delta 255) that no tolerance could cross, so symmetric copies
    // containing such paint never filled.
    do {
        let center = SymmetryCenter(position: CGPoint(x: 64, y: 64), foldCount: 2, mirror: false)
        // White box at (20,20)-(50,50); its 2-fold copy lands at (78,78)-(108,108).
        let box = DrawOp.stroke(StrokeOp(tool: .rectangle, color: .white, width: 3,
                                         points: [CGPoint(x: 20, y: 20), CGPoint(x: 50, y: 50)],
                                         symmetries: [center]))
        // Opaque black blob inside the copy box: invisible on a black background.
        let blob = dot(at: CGPoint(x: 93, y: 93), width: 20, color: black,
                       symmetry: SymmetryCenter(position: CGPoint(x: 93, y: 93),
                                                foldCount: 1, mirror: false))
        let fill = DrawOp.fill(FillOp(color: red, seed: CGPoint(x: 35, y: 35), tolerance: 0.08,
                                      symmetries: [center], linked: false, background: .black))
        let layer = RasterLayer(width: 128, height: 128)!
        layer.render(box)
        layer.render(blob)
        layer.render(fill)
        check("visible fill covers clicked box", matches(layer.pixel(atX: 35, y: 35), (255, 0, 0, 255)))
        check("visible fill reaches symmetric copy", matches(layer.pixel(atX: 81, y: 81), (255, 0, 0, 255)))
        check("visible fill crosses invisible paint", matches(layer.pixel(atX: 93, y: 93), (255, 0, 0, 255)))
        check("visible fill respects visible boundaries", matches(layer.pixel(atX: 64, y: 110), (0, 0, 0, 0)))

        // Legacy ops carry no background snapshot: the layer's fallback applies.
        let legacy = RasterLayer(width: 128, height: 128)!
        legacy.fallbackBackground = .black
        legacy.render(box)
        legacy.render(blob)
        legacy.render(.fill(FillOp(color: red, seed: CGPoint(x: 35, y: 35), tolerance: 0.08,
                                   symmetries: [center])))
        check("legacy fill uses fallback background", matches(legacy.pixel(atX: 93, y: 93), (255, 0, 0, 255)))
    }

    // 20. Random-demo generator: deterministic per seed, varied across seeds,
    // geometry stays on canvas, and the ops actually paint when replayed.
    do {
        let a = PolymandalaGenerator.generate(width: 512, height: 512, seed: 7)
        let b = PolymandalaGenerator.generate(width: 512, height: 512, seed: 7)
        check("demo generator is deterministic",
              a.ops == b.ops && a.background == b.background
                  && a.centers == b.centers && a.linked == b.linked)
        let c = PolymandalaGenerator.generate(width: 512, height: 512, seed: 8)
        check("demo generator varies by seed", a.ops != c.ops)

        var allOnCanvas = true
        var opCountOK = true
        for seed in UInt64(1)...12 {
            let g = PolymandalaGenerator.generate(width: 512, height: 512, seed: seed)
            if g.ops.count < 6 { opCountOK = false }
            for op in g.ops {
                let points: [CGPoint]
                switch op {
                case .stroke(let s): points = s.points
                case .fill(let f): points = [f.seed]
                case .clear: points = []
                }
                for p in points where p.x < 0 || p.x > 512 || p.y < 0 || p.y > 512 {
                    allOnCanvas = false
                }
            }
        }
        check("demo builds are substantial", opCountOK)
        check("demo geometry stays on canvas", allOnCanvas)

        let renderer = CanvasRenderer(width: 512, height: 512)!
        renderer.layer.fallbackBackground = a.background
        renderer.rebuildAll(ops: a.ops)
        var painted = 0
        renderer.layer.snapshotData().withUnsafeBytes { raw in
            var i = 3
            while i < raw.count {
                if raw[i] > 0 { painted += 1 }
                i += 4
            }
        }
        check("demo replay paints the canvas", painted > 512 * 512 / 60,
              "painted \(painted) px")

        if let controller = DrawingController(document: .makeDefault(width: 128, height: 128)) {
            controller.startDemo()
            check("demo toggle starts", controller.isDemoRunning)
            controller.toggleDemo()
            check("demo toggle stops", !controller.isDemoRunning)
        } else {
            check("demo controller setup", false)
        }

        // Screensaver style: pure black background, vibrant foreground colors.
        var saverStyleOK = true
        for seed in UInt64(1)...8 {
            let g = PolymandalaGenerator.generate(width: 512, height: 512, seed: seed,
                                              vibrantOnBlack: true)
            if g.background != .black { saverStyleOK = false }
            for op in g.ops {
                switch op {
                case .stroke(let s):
                    if max(s.color.r, s.color.g, s.color.b) < 0.84 { saverStyleOK = false }
                case .fill(let f):
                    if max(f.color.r, f.color.g, f.color.b) < 0.84 { saverStyleOK = false }
                    if f.background != .black { saverStyleOK = false }
                case .clear:
                    break
                }
            }
        }
        check("saver style is vibrant on black", saverStyleOK)
    }

    // 21. Contour tracer: outlines, holes, islands, and smoothing.
    do {
        // A square ring (hole inside) with an island in the hole.
        let size = 12
        var mask = [Bool](repeating: false, count: size * size)
        var pixels = 0
        for y in 0..<size {
            for x in 0..<size {
                let inOuter = (1...10).contains(x) && (1...10).contains(y)
                let inHole = (3...8).contains(x) && (3...8).contains(y)
                let inIsland = (5...6).contains(x) && (5...6).contains(y)
                if (inOuter && !inHole) || inIsland {
                    mask[y * size + x] = true
                    pixels += 1
                }
            }
        }
        let loops = ContourTracer.loops(mask: mask, width: size, height: size)
        check("tracer finds outline, hole and island", loops.count == 3, "got \(loops.count) loops")
        // Holes wind the other way, so the signed areas add up to the pixel count.
        var doubledArea = 0
        for loop in loops {
            for i in 0..<loop.count {
                let a = loop[i]
                let b = loop[(i + 1) % loop.count]
                doubledArea += Int(a.x) * Int(b.y) - Int(b.x) * Int(a.y)
            }
        }
        check("traced area equals pixel count", abs(doubledArea) == 2 * pixels,
              "area \(abs(doubledArea) / 2) vs \(pixels) px")

        // Pixels touching only at a corner are separate (4-connected) regions.
        var diagonal = [Bool](repeating: false, count: 16)
        diagonal[1 * 4 + 1] = true
        diagonal[2 * 4 + 2] = true
        let diagonalLoops = ContourTracer.loops(mask: diagonal, width: 4, height: 4)
        check("corner-touching pixels trace separately",
              diagonalLoops.count == 2 && diagonalLoops.allSatisfy { $0.count == 4 },
              "got \(diagonalLoops.map(\.count))")
        check("empty mask traces to nothing",
              ContourTracer.loops(mask: [Bool](repeating: false, count: 16), width: 4, height: 4).isEmpty)

        // A pixel disk smooths to a near-circle with far fewer vertices.
        let side = 100
        let radius = 40.0
        var disk = [Bool](repeating: false, count: side * side)
        for y in 0..<side {
            for x in 0..<side
            where hypot(Double(x) + 0.5 - 50, Double(y) + 0.5 - 50) <= radius {
                disk[y * side + x] = true
            }
        }
        let diskLoops = ContourTracer.loops(mask: disk, width: side, height: side)
        if diskLoops.count == 1 {
            let dense = ContourTracer.smoothedOutline(diskLoops[0])
            let outline = ContourTracer.simplifyClosed(dense, epsilon: 0.3)
            let deviation = outline.map { abs(hypot(Double($0.x) - 50, Double($0.y) - 50) - radius) }.max() ?? 99
            check("smoothed disk outline stays on the circle", deviation < 0.75, "max deviation \(deviation)")
            check("simplification thins the outline", outline.count >= 12 && outline.count * 3 < dense.count,
                  "\(dense.count) → \(outline.count) vertices")
        } else {
            check("disk traces to one loop", false, "got \(diskLoops.count)")
        }
    }

    // 22. SVG export: structure, paint order, and agreement with the raster.
    do {
        check("svg number formatting",
              VectorExporter.number(12.5, decimals: 1) == "12.5"
                  && VectorExporter.number(-0.07, decimals: 2) == "-0.07"
                  && VectorExporter.number(3, decimals: 2) == "3"
                  && VectorExporter.number(0.004, decimals: 2) == "0"
                  && VectorExporter.number(-1234.5678, decimals: 3) == "-1234.568")

        let config = CanvasConfig(width: 256, height: 256, background: .white)
        let center = CGPoint(x: 128, y: 128)
        let plain = SymmetryCenter(position: center, foldCount: 1, mirror: false)
        let sixfold = SymmetryCenter(position: center, foldCount: 6, mirror: false)
        let orange = RGBAColor(r: 1, g: 0.5, b: 0, a: 1)

        // A filled disk: the fill must be written *before* (under) its outline.
        let disk: [DrawOp] = [
            circleOp(center: center, radius: 90, width: 6, color: black, symmetry: plain),
            .fill(FillOp(color: blue, seed: center, tolerance: 0.08, symmetries: [plain],
                         background: .white)),
        ]
        if let svg = VectorExporter.svg(ops: disk, config: config) {
            check("svg is well-formed XML", (try? XMLDocument(xmlString: svg)) != nil)
            let fillAt = position(of: "fill", "#0000ff", in: svg)
            let strokeAt = position(of: "stroke", "#000000", in: svg)
            check("svg writes a fill under its outline stroke",
                  fillAt != nil && strokeAt != nil && fillAt! < strokeAt!,
                  "fill at \(String(describing: fillAt)), stroke at \(String(describing: strokeAt))")

            // No white may show between fill and outline — at 1× and magnified.
            for scale in [1, 4] {
                var worstRed = 0
                if let pixels = svgPixels(svg, width: 256, height: 256, scale: scale) {
                    let side = 256 * scale
                    for y in 0..<side {
                        for x in 0..<side
                        where hypot(Double(x) + 0.5 - Double(side) / 2,
                                    Double(y) + 0.5 - Double(side) / 2) < Double(90 * scale) {
                            worstRed = max(worstRed, Int(pixels[(y * side + x) * 4]))
                        }
                    }
                } else {
                    worstRed = 255
                }
                check("svg fill meets its outline without a seam at \(scale)×", worstRed < 24,
                      "background red leaks up to \(worstRed)")
            }
        } else {
            check("svg export of a filled disk", false)
        }
        let diskResult = compareSVG(ops: disk, config: config)
        check("svg filled disk matches raster", diskResult.mismatch < 0.002 && diskResult.holes == 0,
              "mismatch \(diskResult.mismatch) holes \(diskResult.holes)")

        // Symmetric petals with fills, a line across, an eraser cut, and a
        // recolor of an already-filled region.
        let petal = CGPoint(x: 198, y: 128)
        let scene: [DrawOp] = [
            circleOp(center: petal, radius: 26, width: 4, color: black, symmetry: sixfold),
            .fill(FillOp(color: green, seed: petal, tolerance: 0.08, symmetries: [sixfold],
                         background: .white)),
            circleOp(center: center, radius: 30, width: 5, color: blue, symmetry: plain),
            .fill(FillOp(color: orange, seed: center, tolerance: 0.08, symmetries: [plain],
                         background: .white)),
            .stroke(StrokeOp(tool: .line, color: red, width: 5,
                             points: [CGPoint(x: 20, y: 40), CGPoint(x: 236, y: 60)],
                             symmetries: [plain])),
            .stroke(StrokeOp(tool: .eraser, color: black, width: 14,
                             points: (0...12).map { CGPoint(x: 60 + CGFloat($0) * 10, y: 228 - CGFloat($0) * 4) },
                             symmetries: [plain])),
            .fill(FillOp(color: red, seed: center, tolerance: 0.08, symmetries: [plain],
                         background: .white)),
        ]
        let sceneResult = compareSVG(ops: scene, config: config)
        check("svg scene matches raster", sceneResult.mismatch < 0.004 && sceneResult.holes < 0.0005,
              "mismatch \(sceneResult.mismatch) holes \(sceneResult.holes)")
        if let svg = VectorExporter.svg(ops: scene, config: config) {
            // The recolor covers the orange fill, so it must come after it —
            // yet both stay under the blue ring that borders them.
            let orangeAt = position(of: "fill", "#ff8000", in: svg)
            let recolorAt = position(of: "fill", "#ff0000", in: svg)
            let ringAt = position(of: "stroke", "#0000ff", in: svg)
            check("svg keeps a recolor above the fill it replaces, under the outline",
                  orangeAt != nil && recolorAt != nil && ringAt != nil
                      && orangeAt! < recolorAt! && recolorAt! < ringAt!)
            check("svg eraser paints the background color", svg.contains("stroke=\"#ffffff\""))
        }

        // Clear Canvas hides everything before it.
        let cleared: [DrawOp] = [
            dot(at: CGPoint(x: 60, y: 60), width: 20, color: red, symmetry: plain),
            .clear,
            dot(at: CGPoint(x: 160, y: 160), width: 20, color: blue, symmetry: plain),
        ]
        if let svg = VectorExporter.svg(ops: cleared, config: config) {
            check("svg drops ops before a clear",
                  !svg.contains("#ff0000") && svg.contains("#0000ff"))
        }
        check("svg cleared canvas matches raster", compareSVG(ops: cleared, config: config).mismatch == 0)

        // A translucent fill replaces pixels, so it shows the background
        // through: exported as the pre-blended opaque color.
        let translucent: [DrawOp] = [
            circleOp(center: center, radius: 60, width: 6, color: black, symmetry: plain),
            .fill(FillOp(color: blue, seed: center, tolerance: 0.08, symmetries: [plain],
                         background: .white)),
            .fill(FillOp(color: RGBAColor(r: 1, g: 0, b: 0, a: 0.5), seed: center, tolerance: 0.08,
                         symmetries: [plain], background: .white)),
        ]
        if let svg = VectorExporter.svg(ops: translucent, config: config) {
            check("svg pre-blends translucent fills", svg.contains("fill=\"#ff8080\""))
        }
        // The raster keeps a blue fringe around the recolored disk (a flood
        // stops at the outline's anti-aliased pixels, which stay blended with
        // the old color); the SVG has none — hence the looser bound.
        let translucentResult = compareSVG(ops: translucent, config: config)
        check("svg translucent recolor matches raster",
              translucentResult.mismatch < 0.006 && translucentResult.holes == 0,
              "mismatch \(translucentResult.mismatch) holes \(translucentResult.holes)")

        // Whole generated mandalas, including linked multi-center lattices.
        var worst = SVGComparison(mismatch: 0, holes: 0)
        var worstSeed: UInt64 = 0
        for seed in UInt64(1)...6 {
            let g = PolymandalaGenerator.generate(width: 384, height: 384, seed: seed,
                                              vibrantOnBlack: seed % 2 == 0)
            let result = compareSVG(ops: g.ops,
                                    config: CanvasConfig(width: 384, height: 384, background: g.background))
            if result.mismatch > worst.mismatch { worst.mismatch = result.mismatch; worstSeed = seed }
            worst.holes = max(worst.holes, result.holes)
        }
        check("svg generated mandalas match raster", worst.mismatch < 0.002 && worst.holes < 0.0002,
              "worst mismatch \(worst.mismatch) (seed \(worstSeed)), worst holes \(worst.holes)")

        // 22b. PDF export: the same artwork through the PDF writer, held to
        // the same bounds as the SVG.
        if let pdf = VectorExporter.pdf(ops: disk, config: config),
           let provider = CGDataProvider(data: pdf as CFData),
           let document = CGPDFDocument(provider) {
            let page = document.page(at: 1)
            check("pdf is one page of the canvas size",
                  document.numberOfPages == 1
                      && page?.getBoxRect(.mediaBox) == CGRect(x: 0, y: 0, width: 256, height: 256))
            var creator: CGPDFStringRef?
            var author: CGPDFStringRef?
            let hasCreator = document.info.map { CGPDFDictionaryGetString($0, "Creator", &creator) } ?? false
            let hasAuthor = document.info.map { CGPDFDictionaryGetString($0, "Author", &author) } ?? false
            check("pdf names its creator but no author", hasCreator && !hasAuthor)
            for scale in [1, 4] {
                var worstRed = 0
                if let pixels = pdfPixels(pdf, width: 256, height: 256, scale: scale) {
                    let side = 256 * scale
                    for y in 0..<side {
                        for x in 0..<side
                        where hypot(Double(x) + 0.5 - Double(side) / 2,
                                    Double(y) + 0.5 - Double(side) / 2) < Double(90 * scale) {
                            worstRed = max(worstRed, Int(pixels[(y * side + x) * 4]))
                        }
                    }
                } else {
                    worstRed = 255
                }
                check("pdf fill meets its outline without a seam at \(scale)×", worstRed < 24,
                      "background red leaks up to \(worstRed)")
            }
        } else {
            check("pdf export of a filled disk", false)
        }
        let pdfDisk = comparePDF(ops: disk, config: config)
        check("pdf filled disk matches raster", pdfDisk.mismatch < 0.002 && pdfDisk.holes == 0,
              "mismatch \(pdfDisk.mismatch) holes \(pdfDisk.holes)")
        let pdfScene = comparePDF(ops: scene, config: config)
        check("pdf scene matches raster", pdfScene.mismatch < 0.004 && pdfScene.holes < 0.0005,
              "mismatch \(pdfScene.mismatch) holes \(pdfScene.holes)")
        check("pdf cleared canvas matches raster", comparePDF(ops: cleared, config: config).mismatch == 0)
        let pdfTranslucent = comparePDF(ops: translucent, config: config)
        check("pdf translucent recolor matches raster",
              pdfTranslucent.mismatch < 0.006 && pdfTranslucent.holes == 0,
              "mismatch \(pdfTranslucent.mismatch) holes \(pdfTranslucent.holes)")
        var worstPDF = SVGComparison(mismatch: 0, holes: 0)
        var worstPDFSeed: UInt64 = 0
        for seed in UInt64(1)...6 {
            let g = PolymandalaGenerator.generate(width: 384, height: 384, seed: seed,
                                              vibrantOnBlack: seed % 2 == 0)
            let result = comparePDF(ops: g.ops,
                                    config: CanvasConfig(width: 384, height: 384, background: g.background))
            if result.mismatch > worstPDF.mismatch { worstPDF.mismatch = result.mismatch; worstPDFSeed = seed }
            worstPDF.holes = max(worstPDF.holes, result.holes)
        }
        check("pdf generated mandalas match raster", worstPDF.mismatch < 0.002 && worstPDF.holes < 0.0002,
              "worst mismatch \(worstPDF.mismatch) (seed \(worstPDFSeed)), worst holes \(worstPDF.holes)")
    }

    // 23. The built-in license text is the complete MIT license, and laying
    // it out for the License window loses none of it.
    do {
        let words = License.text.split(whereSeparator: \.isWhitespace)
        check("license text is the MIT license",
              License.text.hasPrefix("MIT License\n\nCopyright (c) ")
                  && License.text.contains("Permission is hereby granted, free of charge")
                  && License.text.contains("The above copyright notice and this permission notice shall be included")
                  && License.text.contains("THE SOFTWARE IS PROVIDED \"AS IS\"")
                  && License.text.hasSuffix("SOFTWARE."))
        let shown = LicenseWindowController.licenseText().string
        check("license window shows the whole text",
              License.paragraphs.count == 5
                  && shown.split(whereSeparator: \.isWhitespace) == words,
              "\(License.paragraphs.count) paragraphs")
    }

    print(failures == 0 ? "ALL TESTS PASSED" : "\(failures) TEST(S) FAILED")
    return failures == 0 ? 0 : 1
}

// MARK: - Demo snapshot

func runSnapshot(path: String) -> Int32 {
    let size = 1024
    let cream = RGBAColor(r: 0.97, g: 0.95, b: 0.90, a: 1)
    let document = DrawingDocument.makeDefault(width: size, height: size, background: cream)
    let mid = CGPoint(x: 512, y: 512)

    let ring = SymmetryCenter(position: mid, foldCount: 1, mirror: false)
    let fold12 = SymmetryCenter(position: mid, foldCount: 12, mirror: false)
    let fold24 = SymmetryCenter(position: mid, foldCount: 24, mirror: false)

    let indigo = RGBAColor(r: 0.25, g: 0.20, b: 0.50, a: 1)
    let plum = RGBAColor(r: 0.45, g: 0.15, b: 0.40, a: 1)
    let teal = RGBAColor(r: 0.35, g: 0.75, b: 0.72, a: 1)
    let gold = RGBAColor(r: 0.95, g: 0.75, b: 0.30, a: 1)
    let crimson = RGBAColor(r: 0.80, g: 0.20, b: 0.30, a: 1)
    let rose = RGBAColor(r: 0.90, g: 0.55, b: 0.60, a: 1)

    var ops: [DrawOp] = []
    // Concentric rings
    ops.append(circleOp(center: mid, radius: 470, width: 6, color: indigo, symmetry: ring))
    ops.append(circleOp(center: mid, radius: 345, width: 5, color: indigo, symmetry: ring))
    ops.append(circleOp(center: mid, radius: 62, width: 4, color: plum, symmetry: ring))
    // Outer petals (12-fold) + fill
    ops.append(.stroke(StrokeOp(tool: .ellipse, color: indigo, width: 4,
                                points: [CGPoint(x: 512 + 185, y: 512 - 58), CGPoint(x: 512 + 335, y: 512 + 58)],
                                symmetries: [fold12])))
    ops.append(.fill(FillOp(color: teal, seed: CGPoint(x: 512 + 260, y: 512), tolerance: 0.08, symmetries: [fold12])))
    // Inner petals (12-fold) + fill
    ops.append(.stroke(StrokeOp(tool: .ellipse, color: plum, width: 4,
                                points: [CGPoint(x: 512 + 72, y: 512 - 38), CGPoint(x: 512 + 178, y: 512 + 38)],
                                symmetries: [fold12])))
    ops.append(.fill(FillOp(color: gold, seed: CGPoint(x: 512 + 125, y: 512), tolerance: 0.08, symmetries: [fold12])))
    // Center disk fill
    ops.append(.fill(FillOp(color: rose, seed: mid, tolerance: 0.08, symmetries: [ring])))
    // Spokes (24-fold) and dots (12-fold, offset by 15°)
    ops.append(.stroke(StrokeOp(tool: .line, color: plum, width: 3,
                                points: [CGPoint(x: 512 + 350, y: 512), CGPoint(x: 512 + 464, y: 512)],
                                symmetries: [fold24])))
    let dotAngle = CGFloat.pi / 12
    ops.append(dot(at: CGPoint(x: 512 + 405 * cos(dotAngle), y: 512 + 405 * sin(dotAngle)),
                   width: 18, color: crimson, symmetry: fold12))

    // Pentagonal corner motif, stamped identically at two corners (linked mode:
    // the first center is the master, the second receives a translated copy).
    let cornerMid = CGPoint(x: 160, y: 862)
    let fold5 = SymmetryCenter(position: cornerMid, foldCount: 5, mirror: false)
    let fold5Stamp = SymmetryCenter(position: CGPoint(x: 864, y: 862), foldCount: 5, mirror: false)
    let cornerRing = SymmetryCenter(position: cornerMid, foldCount: 1, mirror: false)
    let cornerRingStamp = SymmetryCenter(position: fold5Stamp.position, foldCount: 1, mirror: false)
    ops.append(.stroke(StrokeOp(tool: .ellipse, color: teal, width: 3,
                                points: [CGPoint(x: cornerMid.x - 98, y: cornerMid.y - 98),
                                         CGPoint(x: cornerMid.x + 98, y: cornerMid.y + 98)],
                                symmetries: [cornerRing, cornerRingStamp], linked: true)))
    ops.append(.stroke(StrokeOp(tool: .ellipse, color: crimson, width: 3,
                                points: [CGPoint(x: 160 + 24, y: 862 - 14), CGPoint(x: 160 + 78, y: 862 + 14)],
                                symmetries: [fold5, fold5Stamp], linked: true)))
    ops.append(.fill(FillOp(color: rose, seed: CGPoint(x: 160 + 51, y: 862), tolerance: 0.08,
                            symmetries: [fold5, fold5Stamp], linked: true)))
    ops.append(.stroke(StrokeOp(tool: .triangle, color: gold, width: 3,
                                points: [CGPoint(x: cornerMid.x - 13, y: cornerMid.y + 30),
                                         CGPoint(x: cornerMid.x + 13, y: cornerMid.y + 58)],
                                symmetries: [fold5, fold5Stamp], linked: true)))

    document.ops = ops
    document.centers = [SymmetryCenter(position: mid, foldCount: 12, mirror: true), fold5]
    document.normalizeActiveSet()

    guard let renderer = CanvasRenderer(width: size, height: size) else {
        print("snapshot: could not create renderer")
        return 1
    }
    renderer.rebuildAll(ops: document.ops)
    guard let image = renderer.layer.compositedImage(background: document.config.background) else {
        print("snapshot: could not composite image")
        return 1
    }
    do {
        try writePNG(image, to: URL(fileURLWithPath: path))
        print("snapshot written to \(path)")
        return 0
    } catch {
        print("snapshot failed: \(error)")
        return 1
    }
}

// MARK: - Headless vector export

/// `Polymandala --export-svg|--export-pdf <in.polymandala> <out>`: converts a
/// saved document without opening a window, and reports how long it took.
func runExportVector(format: String, documentPath: String, outputPath: String) -> Int32 {
    do {
        let data = try Data(contentsOf: URL(fileURLWithPath: documentPath))
        let document = try DrawingDocument.fromData(data)
        let started = Date()
        guard let artwork = VectorExporter.artwork(ops: document.ops, config: document.config) else {
            print("export-\(format): could not allocate a \(document.config.width)×\(document.config.height) canvas")
            return 1
        }
        guard let output = format == "pdf" ? artwork.pdf() : Data(artwork.svg().utf8) else {
            print("export-\(format): could not create the file")
            return 1
        }
        try output.write(to: URL(fileURLWithPath: outputPath), options: .atomic)
        print(String(format: "%@ written to %@ (%d ops, %d bytes, %.2fs)",
                     format, outputPath, document.ops.count, output.count,
                     Date().timeIntervalSince(started)))
        return 0
    } catch {
        print("export-\(format) failed: \(error.localizedDescription)")
        return 1
    }
}

/// `Polymandala --export-png <in.polymandala> <out.png>`: the raster counterpart, for
/// comparing an SVG export against the pixels it was traced from.
func runExportPNG(documentPath: String, pngPath: String) -> Int32 {
    do {
        let data = try Data(contentsOf: URL(fileURLWithPath: documentPath))
        let document = try DrawingDocument.fromData(data)
        guard let controller = DrawingController(document: document),
              let image = controller.compositeImage else {
            print("export-png: could not render the document")
            return 1
        }
        try writePNG(image, to: URL(fileURLWithPath: pngPath))
        print("png written to \(pngPath)")
        return 0
    } catch {
        print("export-png failed: \(error.localizedDescription)")
        return 1
    }
}

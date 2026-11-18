import CoreGraphics
import Foundation

/// Vector export (SVG and PDF): the document's ops as resolution-independent
/// vector art. The analysis below produces a `VectorArtwork` — an ordered list
/// of paint items — and each format is just a writer for that list.
///
/// Strokes are exact — the same Bézier geometry the raster layer strokes,
/// written once per op and instanced through its symmetry transforms. Erasers
/// become strokes in the background color (an export bakes the background).
///
/// Flood fills have no geometry, so the ops are replayed on a raster layer and
/// each fill's pixel mask is traced into polygons (ContourTracer). A traced
/// outline is only pixel-accurate, so it must not end up *visible*: a fill is
/// therefore written **underneath** the strokes that bound it and grown a
/// little so it reaches under them. The strokes' true edges then define what
/// you see at any zoom, and there is no background seam between the two.
///
/// "Underneath" means reordering. While replaying, two per-pixel maps record
/// which op last painted each pixel solidly (`owner`) and which one last
/// touched it at all (`touch`). They yield a dependency graph over the ops:
///   - hard edge A → B: B solidly covers pixels A owns, so B must be drawn
///     after A. Any order respecting the hard edges reproduces the picture.
///   - soft edge F → S: stroke S borders fill F, so F should be drawn first.
///     A soft edge is dropped when it would contradict the hard ones (a
///     cycle) — e.g. the fill also covers something drawn over that stroke.
///     The fill then sits on top of the stroke there and is not grown.
/// The output is the topological order of that graph, closest to document
/// order.
enum VectorExporter {
    /// Coverage (0–255) from which an op owns a pixel / counts as touching it.
    private static let ownerCoverage: UInt8 = 160
    private static let touchCoverage: UInt8 = 24
    /// Every fill polygon is outlined in its own color, which grows it by
    /// half the outline width. Under a bordering stroke the growth only has
    /// to be generous enough to absorb the tracing error. A fill that lies on
    /// top of everything around it has a *visible* edge, though: there the
    /// growth just makes up for the mask stopping about 0.4 px short of the
    /// neighboring paint's true edge (its anti-aliased fringe never floods).
    private static let hiddenFillGrowth = 0.75
    private static let exposedFillGrowth = 0.45
    private static let maxUnderlapDepth = 3
    /// Upper bound for an overlap that may be dismissed as edge noise.
    private static let incidentalPixels = 64
    private static let simplifyEpsilon: CGFloat = 0.3

    /// How many pixels a fill may additionally grow under an op that borders
    /// it and is drawn over it (the mask itself stops at the op's
    /// anti-aliased fringe). Bounded by the stroke width so the fill never
    /// pokes out the far side; hairlines get no underlap at all.
    private static func underlapDepth(of op: DrawOp) -> Int {
        guard case .stroke(let s) = op else { return 1 } // a neighboring fill
        if s.width < 2 { return 0 }
        // Worst case the fill ends up depth + ~1.1 px inside the stroke.
        return max(1, min(maxUnderlapDepth, Int(s.width - 2.1)))
    }

    /// The traced, ordered artwork. Returns nil when the working bitmaps
    /// cannot be allocated.
    static func artwork(ops allOps: [DrawOp], config: CanvasConfig) -> VectorArtwork? {
        // Nothing drawn before the last Clear Canvas is visible.
        var ops = allOps[...]
        if let lastClear = allOps.lastIndex(of: .clear) {
            ops = allOps[(lastClear + 1)...]
        }
        guard let session = Session(ops: Array(ops), config: config) else { return nil }
        return session.run()
    }

    static func svg(ops: [DrawOp], config: CanvasConfig) -> String? {
        artwork(ops: ops, config: config)?.svg()
    }

    static func pdf(ops: [DrawOp], config: CanvasConfig) -> Data? {
        artwork(ops: ops, config: config)?.pdf()
    }

    // MARK: - Session

    private final class Session {
        let ops: [DrawOp]
        let config: CanvasConfig
        let width: Int
        let height: Int
        let layer: RasterLayer
        /// Scratch 8-bit coverage bitmap: one stroke op at a time.
        let coverage: CGContext
        let owner: UnsafeMutablePointer<Int32>
        let touch: UnsafeMutablePointer<Int32>
        /// successors[a] contains b when a must be written before b.
        var successors: [[Int]]
        var items: [VectorArtwork.Item?]
        /// How many pixels each op painted solidly when it was replayed.
        var claimed: [Int]
        private var visitStamp: [Int]
        private var stamp = 0

        init?(ops: [DrawOp], config: CanvasConfig) {
            guard let layer = RasterLayer(width: config.width, height: config.height),
                  let coverage = CGContext(data: nil, width: config.width, height: config.height,
                                           bitsPerComponent: 8, bytesPerRow: config.width,
                                           space: CGColorSpaceCreateDeviceGray(),
                                           bitmapInfo: CGImageAlphaInfo.none.rawValue),
                  let data = coverage.data
            else { return nil }
            self.ops = ops
            self.config = config
            width = config.width
            height = config.height
            self.layer = layer
            layer.fallbackBackground = config.background
            self.coverage = coverage
            memset(data, 0, coverage.bytesPerRow * config.height)
            coverage.setLineCap(.round)
            coverage.setLineJoin(.round)
            owner = .allocate(capacity: width * height)
            owner.initialize(repeating: -1, count: width * height)
            touch = .allocate(capacity: width * height)
            touch.initialize(repeating: -1, count: width * height)
            successors = Array(repeating: [], count: ops.count)
            items = Array(repeating: nil, count: ops.count)
            claimed = Array(repeating: 0, count: ops.count)
            visitStamp = Array(repeating: 0, count: ops.count)
        }

        deinit {
            owner.deallocate()
            touch.deallocate()
        }

        func run() -> VectorArtwork {
            for (index, op) in ops.enumerated() {
                switch op {
                case .stroke(let stroke):
                    layer.render(op)
                    addStroke(stroke, index: index)
                case .fill(let fill):
                    if let mask = layer.render(op) {
                        addFill(fill, mask: mask, index: index)
                    }
                case .clear:
                    break // removed by artwork(ops:config:)
                }
            }
            return VectorArtwork(width: width, height: height, background: config.background,
                                 items: outputOrder().compactMap { items[$0] })
        }

        // MARK: Strokes

        private func addStroke(_ s: StrokeOp, index: Int) {
            guard let base = StrokeGeometry.path(for: s.tool, points: s.points, width: s.width)
            else { return }
            let transforms = SymmetryEngine.transforms(for: s.symmetries, linked: s.linked)
            guard !transforms.isEmpty else { return }

            // Rasterize this op alone to learn which pixels it covers
            // (geometrically — a translucent stroke still has its place in
            // the paint order).
            coverage.setStrokeColor(gray: 1, alpha: 1)
            coverage.setLineWidth(CGFloat(s.width))
            let pad = CGFloat(s.width) / 2 + 2
            var regions: [CGRect] = []
            for transform in transforms {
                var t = transform
                guard let path = base.copy(using: &t) else { continue }
                coverage.addPath(path)
                coverage.strokePath()
                regions.append(path.boundingBoxOfPath.insetBy(dx: -pad, dy: -pad))
            }
            var covered = Set<Int32>()
            for region in regions {
                claimCoverage(in: region, index: Int32(index), covered: &covered)
            }
            for earlier in covered { successors[Int(earlier)].append(index) }

            let color = s.tool == .eraser
                ? RGBAColor(r: config.background.r, g: config.background.g, b: config.background.b, a: 1)
                : s.color
            items[index] = .stroke(path: base, transforms: transforms, color: color,
                                   width: CGFloat(s.width))
        }

        /// Reads the scratch coverage inside `region` (canvas coordinates),
        /// updates the owner/touch maps, collects the ops whose pixels got
        /// covered, and zeroes the region again for the next op.
        private func claimCoverage(in region: CGRect, index: Int32, covered: inout Set<Int32>) {
            guard !region.isNull, !region.isInfinite,
                  region.minX.isFinite, region.maxX.isFinite,
                  region.minY.isFinite, region.maxY.isFinite else { return }
            let clipped = region.intersection(CGRect(x: 0, y: 0, width: width, height: height))
            guard !clipped.isNull, !clipped.isEmpty else { return }
            let x0 = max(0, Int(clipped.minX.rounded(.down)))
            let x1 = min(width - 1, Int(clipped.maxX.rounded(.up)))
            // Canvas y is bottom-up; bitmap row 0 is the top scanline.
            let row0 = max(0, height - 1 - Int(clipped.maxY.rounded(.up)))
            let row1 = min(height - 1, height - 1 - Int(clipped.minY.rounded(.down)))
            guard x0 <= x1, row0 <= row1 else { return }

            let bytes = coverage.data!.assumingMemoryBound(to: UInt8.self)
            let bytesPerRow = coverage.bytesPerRow
            for row in row0...row1 {
                let line = bytes + row * bytesPerRow
                let base = row * width
                for x in x0...x1 {
                    let value = line[x]
                    guard value >= VectorExporter.touchCoverage else { continue }
                    touch[base + x] = index
                    guard value >= VectorExporter.ownerCoverage else { continue }
                    claimed[Int(index)] += 1
                    let previous = owner[base + x]
                    if previous != index {
                        if previous >= 0 { covered.insert(previous) }
                        owner[base + x] = index
                    }
                }
                memset(line + x0, 0, x1 - x0 + 1)
            }
        }

        // MARK: Fills

        private func addFill(_ f: FillOp, mask: [Bool], index: Int) {
            var grown = mask
            var boundary: [Int] = []
            // Pixels of the mask that each earlier op owned. Owners come in
            // long runs, so the dictionary is only touched when one changes.
            var overlap: [Int32: Int] = [:]
            var total = 0
            let id = Int32(index)
            mask.withUnsafeBufferPointer { m in
                var runOwner: Int32 = -1
                var runLength = 0
                for y in 0..<height {
                    let row = y * width
                    for x in 0..<width where m[row + x] {
                        let i = row + x
                        total += 1
                        let previous = owner[i]
                        if previous != runOwner {
                            if runOwner >= 0 { overlap[runOwner, default: 0] += runLength }
                            runOwner = previous
                            runLength = 0
                        }
                        runLength += 1
                        owner[i] = id
                        touch[i] = id
                        if x == 0 || x == width - 1 || y == 0 || y == height - 1
                            || !m[i - 1] || !m[i + 1] || !m[i - width] || !m[i + width] {
                            boundary.append(i)
                        }
                    }
                }
                if runOwner >= 0 { overlap[runOwner, default: 0] += runLength }
            }
            claimed[index] = total
            for (earlier, count) in overlap where earlier != id {
                // A flood stops at anti-aliased edges, whose pixels sit right
                // at the tolerance: it routinely swallows a few that a
                // bordering stroke owns. Such a handful — negligible for the
                // fill and for the stroke — must not force the whole fill on
                // top of that stroke.
                let incidental = count <= VectorExporter.incidentalPixels
                    && count * 100 < total && count * 100 < claimed[Int(earlier)]
                if !incidental { successors[Int(earlier)].append(index) }
            }

            // Look at the ring of pixels just outside the mask. Whatever
            // painted them borders this fill and should be drawn over it;
            // where that works out (and the border is not a hairline), the
            // fill also grows into the ring.
            var drawnOver: [Int32: Bool] = [:]
            func isDrawnOver(_ op: Int32) -> Bool {
                guard op >= 0, op != id else { return false }
                if let known = drawnOver[op] { return known }
                // The grown fill would show through a translucent stroke.
                if case .stroke(let s) = ops[Int(op)], s.tool != .eraser, s.color.a < 1 {
                    drawnOver[op] = false
                    return false
                }
                // If the bordering op already has to come before this fill,
                // putting the fill first would be a cycle.
                let possible = !reaches(from: Int(op), to: index)
                if possible { successors[index].append(Int(op)) }
                drawnOver[op] = possible
                return possible
            }
            /// How many pixels the fill may grow under a bordering op.
            func underlapDepth(_ op: Int32) -> Int {
                guard isDrawnOver(op) else { return 0 }
                return VectorExporter.underlapDepth(of: ops[Int(op)])
            }
            var frontier: [Int] = []
            mask.withUnsafeBufferPointer { m in
                for i in boundary {
                    let x = i % width
                    let y = i / width
                    for dy in -1...1 {
                        let ny = y + dy
                        guard ny >= 0, ny < height else { continue }
                        for dx in -1...1 where dx != 0 || dy != 0 {
                            let nx = x + dx
                            guard nx >= 0, nx < width else { continue }
                            let j = ny * width + nx
                            guard !m[j] else { continue }
                            // Evaluate both: each records its own soft edge.
                            let underOwner = underlapDepth(owner[j])
                            let underTouch = underlapDepth(touch[j])
                            if (dx == 0 || dy == 0) && max(underOwner, underTouch) >= 1 && !grown[j] {
                                grown[j] = true
                                frontier.append(j)
                            }
                        }
                    }
                }
            }
            // Keep growing under wide strokes, but only through pixels they
            // cover solidly. Where two strokes meet at a sharp angle the mask
            // ends well short of the tip of the cell they enclose, and
            // whatever lies below the fill would peek out there.
            var depth = 2
            while !frontier.isEmpty && depth <= VectorExporter.maxUnderlapDepth {
                var next: [Int] = []
                for i in frontier {
                    let x = i % width
                    let y = i / width
                    for (dx, dy) in [(-1, 0), (1, 0), (0, -1), (0, 1)] {
                        let nx = x + dx
                        let ny = y + dy
                        guard nx >= 0, nx < width, ny >= 0, ny < height else { continue }
                        let j = ny * width + nx
                        guard !grown[j] else { continue }
                        let over = owner[j]
                        // Only ops already known to border the fill: going
                        // deeper must not invent new ordering constraints.
                        guard over >= 0, drawnOver[over] == true,
                              VectorExporter.underlapDepth(of: ops[Int(over)]) >= depth
                        else { continue }
                        grown[j] = true
                        next.append(j)
                    }
                }
                frontier = next
                depth += 1
            }

            // Buffer space: y down, row 0 at the top (as in SVG).
            let polygons = ContourTracer.loops(mask: grown, width: width, height: height)
                .map { ContourTracer.simplifyClosed(ContourTracer.smoothedOutline($0),
                                                    epsilon: VectorExporter.simplifyEpsilon) }
                .filter { !$0.isEmpty }
            guard !polygons.isEmpty else { return }
            // A flood fill *replaces* the pixels it floods, so a translucent
            // fill color shows the background through — never the paint it
            // replaced. Blending it with the background up front gives the
            // same result as an opaque shape (the background's own alpha, if
            // any, is ignored here as it is for erasers).
            let a = f.color.a
            let bg = config.background
            let color = RGBAColor(r: f.color.r * a + bg.r * (1 - a),
                                  g: f.color.g * a + bg.g * (1 - a),
                                  b: f.color.b * a + bg.b * (1 - a), a: 1)
            let growth = drawnOver.values.contains(true)
                ? VectorExporter.hiddenFillGrowth : VectorExporter.exposedFillGrowth
            items[index] = .fill(polygons: polygons, color: color, outlineWidth: CGFloat(growth * 2))
        }

        // MARK: Ordering

        private func reaches(from start: Int, to target: Int) -> Bool {
            if start == target { return true }
            stamp += 1
            var stack = [start]
            visitStamp[start] = stamp
            while let node = stack.popLast() {
                for next in successors[node] where visitStamp[next] != stamp {
                    if next == target { return true }
                    visitStamp[next] = stamp
                    stack.append(next)
                }
            }
            return false
        }

        /// Topological order of the dependency graph; among the ops that are
        /// ready, the earliest in the document goes first.
        private func outputOrder() -> [Int] {
            var pending = [Int](repeating: 0, count: ops.count)
            for list in successors {
                for next in list { pending[next] += 1 }
            }
            var ready = (0..<ops.count).filter { pending[$0] == 0 } // ascending
            var order: [Int] = []
            order.reserveCapacity(ops.count)
            while !ready.isEmpty {
                let node = ready.removeFirst()
                order.append(node)
                for next in successors[node] {
                    pending[next] -= 1
                    if pending[next] == 0 {
                        let at = ready.firstIndex { $0 > next } ?? ready.count
                        ready.insert(next, at: at)
                    }
                }
            }
            // Soft edges are only ever added when they close no cycle, so every
            // op gets emitted; if that invariant were ever broken, plain
            // document order still draws the whole picture.
            assert(order.count == ops.count, "dependency cycle")
            return order.count == ops.count ? order : Array(0..<ops.count)
        }
    }

    // MARK: - Number formatting

    /// Fixed-point decimal without trailing zeros ("12.5", "-0.07", "3").
    /// Hand-rolled: String(format:) is far too slow for a million coordinates.
    static func number(_ value: CGFloat, decimals: Int) -> String {
        guard value.isFinite else { return "0" }
        var scale = 1.0
        for _ in 0..<decimals { scale *= 10 }
        let scaled = (Double(value) * scale).rounded()
        guard abs(scaled) < 9e15 else { return "0" }
        var magnitude = Int64(abs(scaled))
        if magnitude == 0 { return "0" }
        var digits: [UInt8] = []
        var position = 0
        var significant = false // becomes true once a nonzero fraction digit appeared
        while magnitude > 0 || position <= decimals {
            let digit = UInt8(magnitude % 10)
            magnitude /= 10
            if position < decimals {
                if digit != 0 || significant {
                    significant = true
                    digits.append(48 + digit)
                }
            } else {
                if position == decimals && significant { digits.append(46) } // "."
                digits.append(48 + digit)
            }
            position += 1
        }
        if scaled < 0 { digits.append(45) } // "-"
        digits.reverse()
        return String(decoding: digits, as: UTF8.self)
    }
}

// MARK: - Artwork and its writers

/// The export as an ordered list of paint items, background first. The
/// writers below only translate it; all decisions (order, growth, colors)
/// are made by `VectorExporter`, so SVG and PDF show the same picture.
struct VectorArtwork {
    enum Item {
        /// `path` in canvas coordinates (y up), stroked once per transform
        /// with round caps and joins.
        case stroke(path: CGPath, transforms: [CGAffineTransform], color: RGBAColor, width: CGFloat)
        /// Closed polygons in buffer coordinates (y down, row 0 on top),
        /// filled even-odd and outlined in the same color at `outlineWidth`.
        case fill(polygons: [[CGPoint]], color: RGBAColor, outlineWidth: CGFloat)
    }

    let width: Int
    let height: Int
    let background: RGBAColor
    let items: [Item]

    // MARK: SVG

    func svg() -> String {
        func number(_ value: CGFloat, _ decimals: Int) -> String {
            VectorExporter.number(value, decimals: decimals)
        }
        var out = "<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n"
        out += "<svg xmlns=\"http://www.w3.org/2000/svg\""
            + " xmlns:xlink=\"http://www.w3.org/1999/xlink\""
            + " width=\"\(width)\" height=\"\(height)\" viewBox=\"0 0 \(width) \(height)\">\n"
        // Symmetry copies and grown fills may extend past the canvas.
        out += "<clipPath id=\"canvas\"><rect width=\"\(width)\" height=\"\(height)\"/></clipPath>\n"
        out += "<g clip-path=\"url(#canvas)\">\n"
        out += "<rect width=\"\(width)\" height=\"\(height)\"\(Self.paint("fill", background))/>\n"
        // The flip from canvas space (y up) into SVG's y-down space.
        let flip = CGAffineTransform(a: 1, b: 0, c: 0, d: -1, tx: 0, ty: CGFloat(height))
        for (index, item) in items.enumerated() {
            switch item {
            case let .stroke(path, transforms, color, width):
                // The path is defined once; each instance's matrix carries
                // its symmetry transform plus the flip.
                out += "<g fill=\"none\"\(Self.paint("stroke", color))"
                    + " stroke-width=\"\(number(width, 3))\""
                    + " stroke-linecap=\"round\" stroke-linejoin=\"round\">\n"
                out += "<defs><path id=\"s\(index)\" d=\"\(Self.pathData(path))\"/></defs>\n"
                for transform in transforms {
                    let m = transform.concatenating(flip)
                    out += "<use xlink:href=\"#s\(index)\" transform=\"matrix("
                        + "\(number(m.a, 7)) \(number(m.b, 7)) "
                        + "\(number(m.c, 7)) \(number(m.d, 7)) "
                        + "\(number(m.tx, 3)) \(number(m.ty, 3)))\"/>\n"
                }
                out += "</g>\n"
            case let .fill(polygons, color, outlineWidth):
                // After the moveto, further coordinate pairs are implicit linetos.
                var d = ""
                for polygon in polygons {
                    d += "M\(number(polygon[0].x, 1)) \(number(polygon[0].y, 1))"
                    for p in polygon.dropFirst() {
                        d += " \(number(p.x, 1)) \(number(p.y, 1))"
                    }
                    d += "Z"
                }
                out += "<path\(Self.paint("fill", color))\(Self.paint("stroke", color))"
                    + " stroke-width=\"\(number(outlineWidth, 2))\""
                    + " stroke-linejoin=\"round\" fill-rule=\"evenodd\" d=\"\(d)\"/>\n"
            }
        }
        out += "</g>\n</svg>\n"
        return out
    }

    /// ` fill="#rrggbb"` (plus ` fill-opacity` when translucent) for `attribute`.
    private static func paint(_ attribute: String, _ color: RGBAColor) -> String {
        func byte(_ v: Double) -> Int { Int(max(0, min(255, (v * 255).rounded()))) }
        var text = String(format: " %@=\"#%02x%02x%02x\"", attribute,
                          byte(color.r), byte(color.g), byte(color.b))
        if color.a < 1 {
            text += " \(attribute)-opacity=\"\(VectorExporter.number(CGFloat(color.a), decimals: 3))\""
        }
        return text
    }

    private static func pathData(_ path: CGPath) -> String {
        var d = ""
        func xy(_ p: CGPoint) -> String {
            "\(VectorExporter.number(p.x, decimals: 2)) \(VectorExporter.number(p.y, decimals: 2))"
        }
        path.applyWithBlock { element in
            let p = element.pointee.points
            switch element.pointee.type {
            case .moveToPoint: d += "M\(xy(p[0]))"
            case .addLineToPoint: d += "L\(xy(p[0]))"
            case .addQuadCurveToPoint: d += "Q\(xy(p[0])) \(xy(p[1]))"
            case .addCurveToPoint: d += "C\(xy(p[0])) \(xy(p[1])) \(xy(p[2]))"
            case .closeSubpath: d += "Z"
            @unknown default: break
            }
        }
        return d
    }

    // MARK: PDF

    /// A single page, one point per canvas pixel (like the SVG's nominal
    /// size). PDF space is y-up like the canvas, so strokes go in as they
    /// are and only the traced fills need flipping. Colors are sRGB, as on
    /// the canvas. The document info carries no author — only the creator.
    func pdf() -> Data? {
        let data = NSMutableData()
        var mediaBox = CGRect(x: 0, y: 0, width: width, height: height)
        let info = [kCGPDFContextCreator as String: "Polymandala"] as CFDictionary
        guard let consumer = CGDataConsumer(data: data as CFMutableData),
              let context = CGContext(consumer: consumer, mediaBox: &mediaBox, info)
        else { return nil }
        context.beginPDFPage(nil)
        // Symmetry copies and grown fills may extend past the canvas.
        context.clip(to: mediaBox)
        context.setFillColor(background.cgColor)
        context.fill(mediaBox)
        context.setLineCap(.round)
        context.setLineJoin(.round)
        let flipY = CGFloat(height)
        for item in items {
            switch item {
            case let .stroke(path, transforms, color, width):
                context.setStrokeColor(color.cgColor)
                context.setLineWidth(width)
                // Each instance is stroked on its own, as each SVG <use> is
                // (translucent copies that overlap compound the same way).
                for transform in transforms {
                    var t = transform
                    guard let instance = path.copy(using: &t) else { continue }
                    context.addPath(instance)
                    context.strokePath()
                }
            case let .fill(polygons, color, outlineWidth):
                let path = CGMutablePath()
                for polygon in polygons {
                    path.addLines(between: polygon.map { CGPoint(x: $0.x, y: flipY - $0.y) })
                    path.closeSubpath()
                }
                context.setFillColor(color.cgColor)
                context.setStrokeColor(color.cgColor)
                context.setLineWidth(outlineWidth)
                context.addPath(path)
                context.drawPath(using: .eoFillStroke)
            }
        }
        context.endPDFPage()
        context.closePDF()
        return data as Data
    }
}

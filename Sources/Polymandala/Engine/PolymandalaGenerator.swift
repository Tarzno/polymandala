import CoreGraphics
import Foundation

/// Seeded RNG (SplitMix64) so generated mandalas are reproducible: the same
/// seed yields byte-identical ops, which the self-test relies on.
struct SplitMix64: RandomNumberGenerator {
    private var state: UInt64
    init(seed: UInt64) { state = seed }
    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}

/// A generated demo mandala: canvas setup plus ops in build order (center
/// rosette outward), so committing them one at a time shows the construction.
struct GeneratedPolymandala {
    var background: RGBAColor
    var centers: [SymmetryCenter]
    var linked: Bool
    var ops: [DrawOp]
}

/// Random mandala construction for the demo mode. Randomness is constrained
/// to a grammar, not sampled freely: one harmony-derived palette and one fold
/// count per mandala, concentric rings built center-outward from a small
/// element vocabulary, and fills seeded only inside enclosures the generator
/// itself just drew (so they can never leak).
enum PolymandalaGenerator {

    /// `vibrantOnBlack` (the screensaver style) forces a pure black background
    /// with high-saturation, high-brightness foreground colors.
    static func generate(width: Int, height: Int, seed: UInt64,
                         vibrantOnBlack: Bool = false) -> GeneratedPolymandala {
        var rng = SplitMix64(seed: seed)
        let palette = makePalette(vibrantOnBlack: vibrantOnBlack, using: &rng)
        let mid = CGPoint(x: Double(width) / 2, y: Double(height) / 2)
        let halfMin = Double(min(width, height)) / 2
        let scale = halfMin / 1024

        if Double.random(in: 0..<1, using: &rng) < 0.22 {
            // Multi-center lattice: identical motifs stamped (linked mode) at
            // the canvas center and around a regular polygon of centers.
            let k = Int.random(in: 4...6, using: &rng)
            let folds = [6, 8, 8, 10].randomElement(using: &rng)!
            let mirror = Double.random(in: 0..<1, using: &rng) < 0.8
            let ringRadius = halfMin * 0.54
            var centers = [SymmetryCenter(id: uuid(using: &rng), position: mid,
                                          foldCount: folds, mirror: mirror)]
            for i in 0..<k {
                let angle = 2 * .pi * Double(i) / Double(k) + .pi / 2
                centers.append(SymmetryCenter(
                    id: uuid(using: &rng),
                    position: CGPoint(x: mid.x + ringRadius * CGFloat(cos(angle)),
                                      y: mid.y + ringRadius * CGFloat(sin(angle))),
                    foldCount: folds, mirror: mirror))
            }
            let spacing = 2 * ringRadius * sin(.pi / Double(k))
            let motifRadius = min(spacing, ringRadius) * Double.random(in: 0.52...0.62, using: &rng)
            let ops = buildRings(center: mid, maxRadius: motifRadius,
                                 symmetries: centers, linked: true,
                                 palette: palette, scale: scale, using: &rng)
            return GeneratedPolymandala(background: palette.background, centers: centers,
                                    linked: true, ops: ops)
        }

        // Classic single-center mandala.
        let folds = [6, 8, 8, 10, 12, 12, 16].randomElement(using: &rng)!
        let mirror = Double.random(in: 0..<1, using: &rng) < 0.8
        let center = SymmetryCenter(id: uuid(using: &rng), position: mid,
                                    foldCount: folds, mirror: mirror)
        let ops = buildRings(center: mid, maxRadius: halfMin * 0.92,
                             symmetries: [center], linked: false,
                             palette: palette, scale: scale, using: &rng)
        return GeneratedPolymandala(background: palette.background, centers: [center],
                                linked: false, ops: ops)
    }

    // MARK: - Palette

    private struct Palette {
        var background: RGBAColor
        var colors: [RGBAColor]
        var accent: RGBAColor
    }

    /// One base hue plus a harmony rule (analogous / complementary / triadic)
    /// per mandala — the single strongest defense against random-color garishness.
    private static func makePalette(vibrantOnBlack: Bool, using rng: inout SplitMix64) -> Palette {
        let base = Double.random(in: 0..<1, using: &rng)
        var hues: [Double]
        switch Int.random(in: 0..<3, using: &rng) {
        case 0: hues = [base, base + 0.055, base - 0.055, base + 0.11, base - 0.11]
        case 1: hues = [base, base + 0.04, base - 0.04, base + 0.5, base + 0.55]
        default: hues = [base, base + 1.0 / 3, base + 2.0 / 3, base + 0.04, base + 1.0 / 3 + 0.04]
        }
        hues.shuffle(using: &rng)

        if vibrantOnBlack {
            let colors = hues.map { h in
                hsb(h, Double.random(in: 0.7...1, using: &rng),
                    Double.random(in: 0.85...1, using: &rng))
            }
            return Palette(background: .black, colors: colors,
                           accent: hsb(base + 0.5, 0.9, 1))
        }

        let dark = Double.random(in: 0..<1, using: &rng) < 0.7
        let background = dark
            ? hsb(base + 0.5, Double.random(in: 0.15...0.45, using: &rng),
                  Double.random(in: 0.05...0.13, using: &rng))
            : hsb(base, Double.random(in: 0.02...0.08, using: &rng),
                  Double.random(in: 0.95...1, using: &rng))
        let colors = hues.map { h in
            hsb(h, Double.random(in: 0.55...0.95, using: &rng),
                dark ? Double.random(in: 0.75...1, using: &rng)
                     : Double.random(in: 0.40...0.75, using: &rng))
        }
        let accent = hsb(base + 0.5, 0.85, dark ? 1 : 0.5)
        return Palette(background: background, colors: colors, accent: accent)
    }

    private static func hsb(_ hue: Double, _ s: Double, _ v: Double) -> RGBAColor {
        let h = (hue.truncatingRemainder(dividingBy: 1) + 1).truncatingRemainder(dividingBy: 1)
        let s = min(1, max(0, s))
        let v = min(1, max(0, v))
        let f = h * 6 - (h * 6).rounded(.down)
        let p = v * (1 - s)
        let q = v * (1 - f * s)
        let t = v * (1 - (1 - f) * s)
        switch Int(h * 6) % 6 {
        case 0: return RGBAColor(r: v, g: t, b: p, a: 1)
        case 1: return RGBAColor(r: q, g: v, b: p, a: 1)
        case 2: return RGBAColor(r: p, g: v, b: t, a: 1)
        case 3: return RGBAColor(r: p, g: q, b: v, a: 1)
        case 4: return RGBAColor(r: t, g: p, b: v, a: 1)
        default: return RGBAColor(r: v, g: p, b: q, a: 1)
        }
    }

    private static func uuid(using rng: inout SplitMix64) -> UUID {
        let a = rng.next().littleEndianBytes
        let b = rng.next().littleEndianBytes
        return UUID(uuid: (a[0], a[1], a[2], a[3], a[4], a[5], a[6], a[7],
                           b[0], b[1], b[2], b[3], b[4], b[5], b[6], b[7]))
    }

    // MARK: - Ring grammar

    private static func buildRings(center mid: CGPoint, maxRadius: Double,
                                   symmetries: [SymmetryCenter], linked: Bool,
                                   palette: Palette, scale: Double,
                                   using rng: inout SplitMix64) -> [DrawOp] {
        var ops: [DrawOp] = []
        let cx = Double(mid.x)
        let cy = Double(mid.y)
        let folds = symmetries[0].foldCount

        // Angle 0 = straight up, so elements sit on the vertical mirror axis
        // and stay symmetric under reflection; rotation copies do the rest.
        func pt(_ angle: Double, _ r: Double) -> CGPoint {
            CGPoint(x: cx + r * sin(angle), y: cy + r * cos(angle))
        }
        func stroke(_ tool: ToolKind, _ points: [CGPoint], _ color: RGBAColor, _ w: Double) -> DrawOp {
            .stroke(StrokeOp(tool: tool, color: color, width: w, points: points,
                             symmetries: symmetries, linked: linked))
        }
        func fillOp(_ seed: CGPoint, _ color: RGBAColor) -> DrawOp {
            .fill(FillOp(color: color, seed: seed, tolerance: 0.08,
                         symmetries: symmetries, linked: linked, background: palette.background))
        }
        // Full circles replicate onto themselves at every fold; unlinked ops
        // can use a 1-fold snapshot to skip the redundant copies.
        let circleSym = linked ? symmetries
            : [SymmetryCenter(id: symmetries[0].id, position: mid, foldCount: 1, mirror: false)]
        func circle(_ r: Double, _ color: RGBAColor, _ w: Double) -> DrawOp {
            .stroke(StrokeOp(tool: .ellipse, color: color, width: w,
                             points: [CGPoint(x: cx - r, y: cy - r), CGPoint(x: cx + r, y: cy + r)],
                             symmetries: circleSym, linked: linked))
        }

        var colorIndex = Int.random(in: 0..<palette.colors.count, using: &rng)
        func nextColor() -> RGBAColor {
            colorIndex = (colorIndex + 1) % palette.colors.count
            return palette.colors[colorIndex]
        }
        func fillColor() -> RGBAColor {
            Double.random(in: 0..<1, using: &rng) < 0.25
                ? palette.accent
                : palette.colors[(colorIndex + 2) % palette.colors.count]
        }

        // Sub-pixel strokes anti-alias so faintly that flood fills can cross
        // them — every drawn width gets an absolute floor.
        func minWidth(_ w: Double) -> Double { max(2.2, w) }

        // Center rosette: a small filled disc anchors the composition.
        let rosetteR = maxRadius * Double.random(in: 0.06...0.11, using: &rng)
        let rosetteWidth = minWidth(Double.random(in: 2.5...4.5, using: &rng) * scale)
        ops.append(circle(rosetteR, nextColor(), rosetteWidth))
        if rosetteR > rosetteWidth * 1.5 + 3 {
            ops.append(fillOp(mid, fillColor()))
        }

        // Concentric rings with randomized band thicknesses and small gaps.
        // Ring count follows the available radius so small motifs stay bold.
        let ringCount = max(4, min(8, Int(maxRadius / (55 * scale))
                                        + Int.random(in: -1...1, using: &rng)))
        var weights: [Double] = []
        for _ in 0..<ringCount { weights.append(Double.random(in: 0.55...1.45, using: &rng)) }
        let totalWeight = weights.reduce(0, +)
        let innerRadius = rosetteR + maxRadius * 0.04
        let span = maxRadius * 0.98 - innerRadius
        let gap = span * 0.02

        var r0 = innerRadius
        for weight in weights {
            let r1 = r0 + span * weight / totalWeight
            defer { r0 = r1 }
            let inner = r0 + gap / 2
            let outer = r1 - gap / 2
            let thickness = outer - inner
            let rMid = (inner + outer) / 2
            guard thickness > 4 * scale else { continue }

            let arc = 2 * .pi * rMid / Double(folds)
            let lineWidth = minWidth(Double.random(in: 2.5...5.5, using: &rng) * scale)
            let color = nextColor()

            enum Element { case petals, dots, lace, spokes, triangles, band }
            var element: Element
            let roll = Double.random(in: 0..<1, using: &rng)
            if roll < 0.30 { element = .petals }
            else if roll < 0.45 { element = .dots }
            else if roll < 0.60 { element = .lace }
            else if roll < 0.72 { element = .spokes }
            else if roll < 0.84 { element = .triangles }
            else { element = .band }
            // Tight sectors can't fit wide shapes — fall back to slim elements.
            if arc < 6 * lineWidth && (element == .petals || element == .triangles) {
                element = Double.random(in: 0..<1, using: &rng) < 0.5 ? .dots : .lace
            }

            switch element {
            case .petals:
                let length = thickness * Double.random(in: 0.78...0.95, using: &rng)
                let width = min(arc * Double.random(in: 0.55...0.8, using: &rng),
                                length * Double.random(in: 0.45...0.75, using: &rng))
                guard width > 4 * scale else { break }
                let y0 = cy + inner + thickness * 0.03
                ops.append(stroke(.ellipse,
                                  [CGPoint(x: cx - width / 2, y: y0),
                                   CGPoint(x: cx + width / 2, y: y0 + length)],
                                  color, lineWidth))
                if width > 2 * lineWidth + 4,
                   Double.random(in: 0..<1, using: &rng) < 0.85 {
                    ops.append(fillOp(CGPoint(x: cx, y: y0 + length / 2), fillColor()))
                }

            case .dots:
                let diameter = max(3, min(arc * 0.6, thickness * 0.6))
                ops.append(stroke(.brush, [pt(0, rMid)], color, diameter))
                if Double.random(in: 0..<1, using: &rng) < 0.55 {
                    // Staggered smaller companions at the half-sector angle.
                    let d2 = max(3, diameter * 0.5)
                    let r2 = rMid + thickness * Double.random(in: -0.18...0.18, using: &rng)
                    ops.append(stroke(.brush, [pt(.pi / Double(folds), r2)], nextColor(), d2))
                }

            case .lace:
                // A wavy brush arc spanning exactly one sector, so the copies
                // join end-to-end into a continuous ornamental ring.
                let halfSector = .pi / Double(folds)
                let periods = Double(Int.random(in: 1...2, using: &rng))
                let amplitude = thickness * Double.random(in: 0.22...0.38, using: &rng)
                let steps = 12
                var points: [CGPoint] = []
                for i in 0...steps {
                    let u = Double(i) / Double(steps)
                    let radius = rMid + amplitude * sin(periods * 2 * .pi * u)
                    points.append(pt(-halfSector + 2 * halfSector * u, radius))
                }
                ops.append(stroke(.brush, points, color, minWidth(lineWidth * 0.9)))

            case .spokes:
                let tilt = Double.random(in: 0..<1, using: &rng) < 0.35
                    ? arc * Double.random(in: 0.15...0.35, using: &rng) : 0
                let start = pt(0, inner + thickness * 0.05)
                let end = CGPoint(x: cx + tilt, y: cy + outer - thickness * 0.05)
                ops.append(stroke(.line, [start, end], color, lineWidth))
                if Double.random(in: 0..<1, using: &rng) < 0.5 {
                    // A dot at the spoke tip reads as a classic ray ending.
                    ops.append(stroke(.brush, [pt(0, outer - thickness * 0.05)],
                                      nextColor(), max(4, lineWidth * 2.2)))
                }

            case .triangles:
                let width = min(arc * Double.random(in: 0.5...0.75, using: &rng), thickness)
                guard width > 5 * scale else { break }
                let y0 = cy + inner + thickness * 0.05
                let height = thickness * 0.85
                ops.append(stroke(.triangle,
                                  [CGPoint(x: cx - width / 2, y: y0),
                                   CGPoint(x: cx + width / 2, y: y0 + height)],
                                  color, lineWidth))
                if width > 2 * lineWidth + 5,
                   Double.random(in: 0..<1, using: &rng) < 0.7 {
                    ops.append(fillOp(CGPoint(x: cx, y: y0 + height / 3), fillColor()))
                }

            case .band:
                // Two concentric circles; the annulus between them is a clean
                // enclosure this ring just built, so filling it is safe.
                ops.append(circle(inner + lineWidth / 2, color, lineWidth))
                ops.append(circle(outer - lineWidth / 2, color, lineWidth))
                let filled = thickness > 2.5 * lineWidth + 5
                    && Double.random(in: 0..<1, using: &rng) < 0.85
                if filled {
                    ops.append(fillOp(pt(0, rMid), fillColor()))
                }
                if filled, thickness > 14, Double.random(in: 0..<1, using: &rng) < 0.5 {
                    // Dots riding on the filled band add a second layer.
                    ops.append(stroke(.brush, [pt(0, rMid)], nextColor(),
                                      max(3, min(arc * 0.35, thickness * 0.4))))
                }
            }
        }

        // Enclosing outline finishes most compositions.
        if Double.random(in: 0..<1, using: &rng) < 0.65 {
            ops.append(circle(maxRadius, nextColor(),
                              minWidth(Double.random(in: 3.5...6.5, using: &rng) * scale)))
        }
        return ops
    }
}

private extension UInt64 {
    var littleEndianBytes: [UInt8] {
        (0..<8).map { UInt8(truncatingIfNeeded: self >> ($0 * 8)) }
    }
}

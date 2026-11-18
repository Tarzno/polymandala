import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// The stroke layer: a premultiplied-RGBA8 sRGB bitmap, transparent where
/// unpainted, composited over the document background color for display/export.
/// Coordinates passed in are canvas coordinates (origin bottom-left, CG default).
final class RasterLayer {
    let width: Int
    let height: Int
    let bytesPerRow: Int
    private let ctx: CGContext

    init?(width: Int, height: Int) {
        guard width > 0, height > 0,
              let space = CGColorSpace(name: CGColorSpace.sRGB),
              let ctx = CGContext(data: nil, width: width, height: height,
                                  bitsPerComponent: 8, bytesPerRow: width * 4,
                                  space: space,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return nil }
        self.width = width
        self.height = height
        self.ctx = ctx
        self.bytesPerRow = ctx.bytesPerRow
    }

    private var buffer: UnsafeMutablePointer<UInt8> {
        ctx.data!.assumingMemoryBound(to: UInt8.self)
    }

    private var bounds: CGRect {
        CGRect(x: 0, y: 0, width: CGFloat(width), height: CGFloat(height))
    }

    func clear() {
        ctx.clear(bounds)
    }

    // MARK: - Rendering ops

    /// Fill ops return the mask of every pixel they flooded (row-major, row 0 =
    /// top scanline) — the vector exporter traces it; everyone else ignores it.
    @discardableResult
    func render(_ op: DrawOp) -> [Bool]? {
        switch op {
        case .stroke(let s): renderStroke(s)
        case .fill(let f): return renderFill(f)
        case .clear: clear()
        }
        return nil
    }

    private func renderStroke(_ s: StrokeOp) {
        guard let base = StrokeGeometry.path(for: s.tool, points: s.points, width: s.width) else { return }
        for transform in SymmetryEngine.transforms(for: s.symmetries, linked: s.linked) {
            var t = transform
            guard let path = base.copy(using: &t) else { continue }
            ctx.saveGState()
            ctx.setBlendMode(s.tool == .eraser ? .clear : .normal)
            ctx.setStrokeColor(s.color.cgColor)
            ctx.setLineWidth(CGFloat(s.width))
            ctx.setLineCap(.round)
            ctx.setLineJoin(.round)
            ctx.addPath(path)
            ctx.strokePath()
            ctx.restoreGState()
        }
    }

    /// Background used for fill matching when a FillOp predates the stored
    /// background snapshot (legacy documents). Kept in sync with the document.
    var fallbackBackground: RGBAColor = .white

    private func renderFill(_ f: FillOp) -> [Bool]? {
        let sx = Int(f.seed.x.rounded())
        let syCanvas = Int(f.seed.y.rounded())
        guard sx >= 0, sx < width, syCanvas >= 0, syCanvas < height else { return nil }
        let sy = height - 1 - syCanvas // canvas -> buffer row
        let tolerance = Int((f.tolerance * 255).rounded())
        let color = f.color.premultipliedBytes
        let bg = (f.background ?? fallbackBackground).premultipliedBytes

        // All matching decisions use *visible* colors — the layer composited
        // over the background — never raw layer bytes: bare canvas and opaque
        // paint in the background color look identical on screen and must
        // behave as one region, or fills hit invisible walls that no
        // tolerance can cross (alpha differs by 255).
        var visible = [UInt8](repeating: 255, count: width * height * 4)
        var painted = [Bool](repeating: false, count: width * height)
        var didPaint = false
        let buf = buffer
        visible.withUnsafeMutableBufferPointer { vis in
            let v = vis.baseAddress!
            for y in 0..<height {
                let rowIn = y * bytesPerRow
                let rowOut = y * width * 4
                for x in 0..<width {
                    let o = rowIn + x * 4
                    let inv = 255 - Int(buf[o + 3])
                    let vo = rowOut + x * 4
                    v[vo] = UInt8(min(255, Int(buf[o]) + Int(bg.r) * inv / 255))
                    v[vo + 1] = UInt8(min(255, Int(buf[o + 1]) + Int(bg.g) * inv / 255))
                    v[vo + 2] = UInt8(min(255, Int(buf[o + 2]) + Int(bg.b) * inv / 255))
                }
            }

            let seedVO = sy * width * 4 + sx * 4
            let target = (v[seedVO], v[seedVO + 1], v[seedVO + 2])

            guard let originalMask = paintRegion(seedX: sx, seedY: sy, color: color,
                                                 tolerance: tolerance, visible: v, bg: bg)
            else { return }
            didPaint = true
            for i in 0..<painted.count where originalMask[i] { painted[i] = true }

            // Copies clipped by the canvas boundary may have their transformed
            // seed land off-canvas, and the boundary can split a copy into
            // several islands. Transformed samples of the original region's
            // interior reach every on-canvas fragment, so flood from any
            // sample that still shows the target color and isn't painted yet.
            var samples: [CGPoint] = []
            let step = 2
            var by = 0
            while by < height {
                let rowBase = by * width
                var x = 0
                while x < width {
                    if originalMask[rowBase + x] {
                        samples.append(CGPoint(x: CGFloat(x), y: CGFloat(height - 1 - by)))
                    }
                    x += step
                }
                by += step
            }

            func matchesTarget(_ vo: Int) -> Bool {
                abs(Int(v[vo]) - Int(target.0)) <= tolerance
                    && abs(Int(v[vo + 1]) - Int(target.1)) <= tolerance
                    && abs(Int(v[vo + 2]) - Int(target.2)) <= tolerance
            }

            for transform in SymmetryEngine.transforms(for: f.symmetries, linked: f.linked) {
                if transform.isIdentity { continue }
                for sample in samples {
                    let q = sample.applying(transform)
                    let qx = Int(q.x.rounded())
                    let qyCanvas = Int(q.y.rounded())
                    guard qx >= 0, qx < width, qyCanvas >= 0, qyCanvas < height else { continue }
                    let qy = height - 1 - qyCanvas
                    if painted[qy * width + qx] { continue }
                    guard matchesTarget(qy * width * 4 + qx * 4) else { continue }
                    if let mask = paintRegion(seedX: qx, seedY: qy, color: color,
                                              tolerance: tolerance, visible: v, bg: bg) {
                        for i in 0..<painted.count where mask[i] { painted[i] = true }
                    }
                }
            }
        }
        return didPaint ? painted : nil
    }

    /// Flood fill from a buffer-space seed, matching on the visible-color
    /// buffer: paints the region solid, then blends the fill color *under* the
    /// 1px ring of anti-aliased boundary pixels (premultiplied dst-over) so
    /// fills meet strokes without a background seam, and re-derives the
    /// touched area's visible colors so later floods in the same op see the
    /// updated state. Returns the filled mask (buffer-space indexing).
    private func paintRegion(seedX: Int, seedY: Int,
                             color c: (r: UInt8, g: UInt8, b: UInt8, a: UInt8),
                             tolerance: Int,
                             visible: UnsafeMutablePointer<UInt8>,
                             bg: (r: UInt8, g: UInt8, b: UInt8, a: UInt8)) -> [Bool]? {
        guard let mask = FloodFill.computeMask(buffer: visible, width: width, height: height,
                                               bytesPerRow: width * 4,
                                               seedX: seedX, seedY: seedY, tolerance: tolerance)
        else { return nil }

        let buf = buffer
        var minX = width, maxX = -1, minY = height, maxY = -1
        for y in 0..<height {
            let rowBase = y * bytesPerRow
            let maskBase = y * width
            for x in 0..<width where mask[maskBase + x] {
                let o = rowBase + x * 4
                buf[o] = c.r
                buf[o + 1] = c.g
                buf[o + 2] = c.b
                buf[o + 3] = c.a
                if x < minX { minX = x }
                if x > maxX { maxX = x }
                if y < minY { minY = y }
                if y > maxY { maxY = y }
            }
        }
        guard maxX >= 0 else { return mask }

        for y in max(0, minY - 1)...min(height - 1, maxY + 1) {
            let maskBase = y * width
            for x in max(0, minX - 1)...min(width - 1, maxX + 1) where !mask[maskBase + x] {
                var touchesMask = false
                for dy in -1...1 {
                    let ny = y + dy
                    guard ny >= 0, ny < height else { continue }
                    for dx in -1...1 where dx != 0 || dy != 0 {
                        let nx = x + dx
                        guard nx >= 0, nx < width else { continue }
                        if mask[ny * width + nx] { touchesMask = true; break }
                    }
                    if touchesMask { break }
                }
                guard touchesMask else { continue }
                let o = y * bytesPerRow + x * 4
                let inv = 255 - Int(buf[o + 3])
                guard inv > 0 else { continue }
                buf[o] = UInt8(min(255, Int(buf[o]) + Int(c.r) * inv / 255))
                buf[o + 1] = UInt8(min(255, Int(buf[o + 1]) + Int(c.g) * inv / 255))
                buf[o + 2] = UInt8(min(255, Int(buf[o + 2]) + Int(c.b) * inv / 255))
                buf[o + 3] = UInt8(min(255, Int(buf[o + 3]) + Int(c.a) * inv / 255))
            }
        }

        for y in max(0, minY - 1)...min(height - 1, maxY + 1) {
            let rowIn = y * bytesPerRow
            let rowOut = y * width * 4
            for x in max(0, minX - 1)...min(width - 1, maxX + 1) {
                let o = rowIn + x * 4
                let inv = 255 - Int(buf[o + 3])
                let vo = rowOut + x * 4
                visible[vo] = UInt8(min(255, Int(buf[o]) + Int(bg.r) * inv / 255))
                visible[vo + 1] = UInt8(min(255, Int(buf[o + 1]) + Int(bg.g) * inv / 255))
                visible[vo + 2] = UInt8(min(255, Int(buf[o + 2]) + Int(bg.b) * inv / 255))
            }
        }
        return mask
    }

    // MARK: - Output

    /// The stroke layer alone (transparent background).
    func makeImage() -> CGImage? {
        ctx.makeImage()
    }

    /// Stroke layer composited over the solid background color.
    func compositedImage(background: RGBAColor) -> CGImage? {
        guard let strokes = ctx.makeImage(),
              let space = CGColorSpace(name: CGColorSpace.sRGB),
              let out = CGContext(data: nil, width: width, height: height,
                                  bitsPerComponent: 8, bytesPerRow: width * 4,
                                  space: space,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return nil }
        out.setFillColor(background.cgColor)
        out.fill(bounds)
        out.draw(strokes, in: bounds)
        return out.makeImage()
    }

    // MARK: - Snapshots (undo checkpoints)

    func snapshotData() -> Data {
        Data(bytes: ctx.data!, count: bytesPerRow * height)
    }

    func restore(_ data: Data) {
        let count = min(data.count, bytesPerRow * height)
        data.withUnsafeBytes { raw in
            guard let base = raw.baseAddress else { return }
            memcpy(ctx.data!, base, count)
        }
    }

    // MARK: - Pixel access (verification)

    /// Premultiplied RGBA at canvas coordinates (origin bottom-left).
    func pixel(atX x: Int, y: Int) -> (r: UInt8, g: UInt8, b: UInt8, a: UInt8)? {
        guard x >= 0, x < width, y >= 0, y < height else { return nil }
        let o = (height - 1 - y) * bytesPerRow + x * 4
        return (buffer[o], buffer[o + 1], buffer[o + 2], buffer[o + 3])
    }
}

func writePNG(_ image: CGImage, to url: URL) throws {
    guard let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil)
    else {
        throw NSError(domain: "Polymandala", code: 1,
                      userInfo: [NSLocalizedDescriptionKey: "Cannot create PNG at \(url.path)"])
    }
    CGImageDestinationAddImage(dest, image, nil)
    guard CGImageDestinationFinalize(dest) else {
        throw NSError(domain: "Polymandala", code: 2,
                      userInfo: [NSLocalizedDescriptionKey: "Failed to write PNG at \(url.path)"])
    }
}

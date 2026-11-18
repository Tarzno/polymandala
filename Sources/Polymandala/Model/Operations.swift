import AppKit
import CoreGraphics
import Foundation

/// sRGB color with straight (non-premultiplied) components in 0...1.
struct RGBAColor: Codable, Equatable {
    var r: Double
    var g: Double
    var b: Double
    var a: Double

    static let black = RGBAColor(r: 0, g: 0, b: 0, a: 1)
    static let white = RGBAColor(r: 1, g: 1, b: 1, a: 1)
    static let clear = RGBAColor(r: 0, g: 0, b: 0, a: 0)

    var cgColor: CGColor {
        CGColor(srgbRed: CGFloat(r), green: CGFloat(g), blue: CGFloat(b), alpha: CGFloat(a))
    }

    var nsColor: NSColor {
        NSColor(srgbRed: CGFloat(r), green: CGFloat(g), blue: CGFloat(b), alpha: CGFloat(a))
    }

    init(r: Double, g: Double, b: Double, a: Double) {
        self.r = r
        self.g = g
        self.b = b
        self.a = a
    }

    init(_ color: NSColor) {
        let c = color.usingColorSpace(.sRGB) ?? .black
        self.init(r: c.redComponent, g: c.greenComponent, b: c.blueComponent, a: c.alphaComponent)
    }

    /// Premultiplied RGBA bytes as stored in the raster layer.
    var premultipliedBytes: (r: UInt8, g: UInt8, b: UInt8, a: UInt8) {
        func byte(_ v: Double) -> UInt8 { UInt8(max(0, min(255, (v * 255).rounded()))) }
        return (byte(r * a), byte(g * a), byte(b * a), byte(a))
    }
}

enum ToolKind: String, Codable, CaseIterable {
    case brush
    case line
    case ellipse
    case triangle
    case rectangle
    case eraser
    case fill
    case center

    var displayName: String {
        switch self {
        case .brush: return "Brush"
        case .line: return "Line"
        case .ellipse: return "Ellipse"
        case .triangle: return "Triangle"
        case .rectangle: return "Rectangle"
        case .eraser: return "Eraser"
        case .fill: return "Fill"
        case .center: return "Center"
        }
    }

    /// Tools whose geometry is two dragged corner points of a bounding rect.
    var isTwoCornerShape: Bool { self == .ellipse || self == .triangle || self == .rectangle }
    var usesColor: Bool { self != .eraser && self != .center }
    var usesWidth: Bool { self != .fill && self != .center }
}

struct SymmetryCenter: Codable, Equatable {
    var id: UUID
    var position: CGPoint
    /// Number of rotational copies (1 = no rotation symmetry). Clamped to 1...36.
    var foldCount: Int
    /// When true, each rotational copy is paired with its mirror image (dihedral symmetry).
    var mirror: Bool

    init(id: UUID = UUID(), position: CGPoint, foldCount: Int = 8, mirror: Bool = true) {
        self.id = id
        self.position = position
        self.foldCount = max(1, min(36, foldCount))
        self.mirror = mirror
    }
}

struct StrokeOp: Equatable {
    var tool: ToolKind
    var color: RGBAColor
    var width: Double
    /// brush/eraser: polyline; line: [start, end]; ellipse: two corners of the bounding rect.
    var points: [CGPoint]
    /// Snapshot of every active symmetry center at draw time; the stroke is
    /// replicated through the transform set of each one. In linked mode the
    /// first entry is the master whose pattern is stamped at the others.
    var symmetries: [SymmetryCenter]
    /// See SymmetryEngine.transforms(for:linked:).
    var linked: Bool = false
}

extension StrokeOp: Codable {
    private enum CodingKeys: String, CodingKey {
        case tool, color, width, points, symmetries, linked
        case symmetry // legacy single-center documents (v1)
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        tool = try c.decode(ToolKind.self, forKey: .tool)
        color = try c.decode(RGBAColor.self, forKey: .color)
        width = try c.decode(Double.self, forKey: .width)
        points = try c.decode([CGPoint].self, forKey: .points)
        if let list = try c.decodeIfPresent([SymmetryCenter].self, forKey: .symmetries) {
            symmetries = list
        } else {
            symmetries = [try c.decode(SymmetryCenter.self, forKey: .symmetry)]
        }
        linked = try c.decodeIfPresent(Bool.self, forKey: .linked) ?? false
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(tool, forKey: .tool)
        try c.encode(color, forKey: .color)
        try c.encode(width, forKey: .width)
        try c.encode(points, forKey: .points)
        try c.encode(symmetries, forKey: .symmetries)
        try c.encode(linked, forKey: .linked)
    }
}

struct FillOp: Equatable {
    var color: RGBAColor
    var seed: CGPoint
    var tolerance: Double
    var symmetries: [SymmetryCenter]
    /// See SymmetryEngine.transforms(for:linked:).
    var linked: Bool = false
    /// Document background at fill time. Fill matching compares *visible*
    /// colors (layer composited over this), so the snapshot keeps replays
    /// stable if the background changes later. nil in pre-v3 documents —
    /// renderers fall back to the current document background.
    var background: RGBAColor?
}

extension FillOp: Codable {
    private enum CodingKeys: String, CodingKey {
        case color, seed, tolerance, symmetries, linked, background
        case symmetry // legacy single-center documents (v1)
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        color = try c.decode(RGBAColor.self, forKey: .color)
        seed = try c.decode(CGPoint.self, forKey: .seed)
        tolerance = try c.decode(Double.self, forKey: .tolerance)
        if let list = try c.decodeIfPresent([SymmetryCenter].self, forKey: .symmetries) {
            symmetries = list
        } else {
            symmetries = [try c.decode(SymmetryCenter.self, forKey: .symmetry)]
        }
        linked = try c.decodeIfPresent(Bool.self, forKey: .linked) ?? false
        background = try c.decodeIfPresent(RGBAColor.self, forKey: .background)
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(color, forKey: .color)
        try c.encode(seed, forKey: .seed)
        try c.encode(tolerance, forKey: .tolerance)
        try c.encode(symmetries, forKey: .symmetries)
        try c.encode(linked, forKey: .linked)
        try c.encodeIfPresent(background, forKey: .background)
    }
}

enum DrawOp: Codable, Equatable {
    case stroke(StrokeOp)
    case fill(FillOp)
    /// Wipes the stroke layer back to the bare background. Being an op keeps
    /// Clear Canvas fully undoable via the normal replay machinery.
    case clear
}

/// Shared path construction for committed rendering and live preview.
enum StrokeGeometry {
    /// Damps mouse/trackpad jitter: two passes of a centered 3-point moving
    /// average over the interior points (endpoints stay fixed). Exposed for
    /// the self-test.
    static func smoothedBrushPoints(_ points: [CGPoint]) -> [CGPoint] {
        guard points.count >= 5 else { return points }
        var result = points
        for _ in 0..<2 {
            var pass = result
            for i in 1..<(result.count - 1) {
                pass[i] = CGPoint(x: (result[i - 1].x + result[i].x + result[i + 1].x) / 3,
                                  y: (result[i - 1].y + result[i].y + result[i + 1].y) / 3)
            }
            result = pass
        }
        return result
    }

    /// Catmull-Rom spline through the points (as cubic Béziers), so brush
    /// strokes curve smoothly instead of showing polyline corners.
    private static func splinePath(through points: [CGPoint]) -> CGMutablePath {
        let path = CGMutablePath()
        path.move(to: points[0])
        guard points.count > 2 else {
            if points.count == 2 { path.addLine(to: points[1]) }
            return path
        }
        for i in 0..<(points.count - 1) {
            let p0 = points[max(0, i - 1)]
            let p1 = points[i]
            let p2 = points[i + 1]
            let p3 = points[min(points.count - 1, i + 2)]
            path.addCurve(to: p2,
                          control1: CGPoint(x: p1.x + (p2.x - p0.x) / 6, y: p1.y + (p2.y - p0.y) / 6),
                          control2: CGPoint(x: p2.x - (p3.x - p1.x) / 6, y: p2.y - (p3.y - p1.y) / 6))
        }
        return path
    }

    static func path(for tool: ToolKind, points: [CGPoint], width: Double) -> CGPath? {
        guard let first = points.first else { return nil }
        let path = CGMutablePath()
        switch tool {
        case .brush, .eraser:
            if points.count == 1 {
                // A zero-length segment draws nothing; nudge so round caps produce a dot.
                path.move(to: first)
                path.addLine(to: CGPoint(x: first.x + 0.01, y: first.y))
            } else {
                return splinePath(through: smoothedBrushPoints(points))
            }
        case .line:
            guard points.count >= 2 else { return nil }
            path.move(to: first)
            path.addLine(to: points[points.count - 1])
        case .ellipse, .triangle, .rectangle:
            guard points.count >= 2 else { return nil }
            let p2 = points[points.count - 1]
            let rect = CGRect(x: min(first.x, p2.x), y: min(first.y, p2.y),
                              width: abs(p2.x - first.x), height: abs(p2.y - first.y))
            guard rect.width > 0.5 || rect.height > 0.5 else { return nil }
            switch tool {
            case .ellipse:
                path.addEllipse(in: rect)
            case .rectangle:
                path.addRect(rect)
            default: // triangle: isosceles, apex at the top edge's midpoint
                path.move(to: CGPoint(x: rect.midX, y: rect.maxY))
                path.addLine(to: CGPoint(x: rect.minX, y: rect.minY))
                path.addLine(to: CGPoint(x: rect.maxX, y: rect.minY))
                path.closeSubpath()
            }
        case .fill, .center:
            return nil
        }
        return path
    }
}

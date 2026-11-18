import CoreGraphics

/// Turns a pixel mask (a flood-fill region) into vector outlines for the SVG
/// exporter. All coordinates are buffer space: x right, y down, pixel (x, y)
/// covers the unit square from (x, y) to (x+1, y+1) — which is also SVG space.
enum ContourTracer {
    struct Vertex: Equatable {
        var x: Int32
        var y: Int32
    }

    /// The boundary of `mask` (row-major, row 0 = top scanline) as closed
    /// rectilinear loops along pixel edges, listing only the corners.
    ///
    /// Every loop runs with the mask on its right-hand side, so outlines and
    /// the holes inside them wind in opposite directions and the set fills
    /// correctly under either SVG fill rule. Regions that merely touch at a
    /// pixel corner stay separate loops (flood fills are 4-connected).
    static func loops(mask: [Bool], width: Int, height: Int) -> [[Vertex]] {
        precondition(mask.count == width * height)
        return mask.withUnsafeBufferPointer { m -> [[Vertex]] in
            var minX = width, maxX = -1, minY = height, maxY = -1
            for y in 0..<height {
                let row = y * width
                var first = -1, last = -1
                for x in 0..<width where m[row + x] {
                    if first < 0 { first = x }
                    last = x
                }
                guard first >= 0 else { continue }
                if first < minX { minX = first }
                if last > maxX { maxX = last }
                if y < minY { minY = y }
                maxY = y
            }
            guard maxX >= 0 else { return [] }

            // One byte per lattice vertex of the bounding box: bit d is set
            // when a boundary edge leaves the vertex in direction d
            // (0 = right, 1 = down, 2 = left, 3 = up). Each mask pixel
            // contributes its exposed sides, walked clockwise on screen.
            let gridW = maxX - minX + 2
            let gridH = maxY - minY + 2
            var edges = [UInt8](repeating: 0, count: gridW * gridH)
            for y in minY...maxY {
                let row = y * width
                let gy = y - minY
                for x in minX...maxX where m[row + x] {
                    let gx = x - minX
                    if y == 0 || !m[row - width + x] { edges[gy * gridW + gx] |= 1 }
                    if x == width - 1 || !m[row + x + 1] { edges[gy * gridW + gx + 1] |= 2 }
                    if y == height - 1 || !m[row + width + x] { edges[(gy + 1) * gridW + gx + 1] |= 4 }
                    if x == 0 || !m[row + x - 1] { edges[(gy + 1) * gridW + gx] |= 8 }
                }
            }

            let step = [1, gridW, -1, -gridW]
            var result: [[Vertex]] = []
            for start in 0..<edges.count {
                while edges[start] != 0 {
                    let firstDir = edges[start].trailingZeroBitCount
                    edges[start] &= ~(UInt8(1) << UInt8(firstDir))
                    var loop: [Vertex] = []
                    var current = start
                    var dir = firstDir
                    while true {
                        current += step[dir]
                        // Back at the start, the edge the loop began with
                        // counts as available again: taking it closes the loop.
                        var available = edges[current]
                        if current == start { available |= UInt8(1) << UInt8(firstDir) }
                        // Where two regions touch at a corner, four edges
                        // meet; turning right first keeps each loop hugging
                        // its own pixel so the regions stay separate.
                        let rightTurn = (dir + 1) & 3
                        let leftTurn = (dir + 3) & 3
                        let next: Int
                        if available & (UInt8(1) << UInt8(rightTurn)) != 0 {
                            next = rightTurn
                        } else if available & (UInt8(1) << UInt8(dir)) != 0 {
                            next = dir
                        } else {
                            precondition(available & (UInt8(1) << UInt8(leftTurn)) != 0,
                                         "open contour")
                            next = leftTurn
                        }
                        if next != dir {
                            loop.append(Vertex(x: Int32(current % gridW + minX),
                                               y: Int32(current / gridW + minY)))
                        }
                        if current == start && next == firstDir { break }
                        edges[current] &= ~(UInt8(1) << UInt8(next))
                        dir = next
                    }
                    result.append(loop)
                }
            }
            return result
        }
    }

    /// Smooths a rectilinear loop into the outline it approximates: one point
    /// at the middle of every unit edge, low-pass filtered along the loop
    /// (two passes of a ¼-½-¼ kernel). Pixel staircases collapse onto the
    /// straight or curved edge they came from, straight runs stay put, and
    /// real corners are rounded by about ⅔ px.
    static func smoothedOutline(_ loop: [Vertex]) -> [CGPoint] {
        var points: [CGPoint] = []
        for i in 0..<loop.count {
            let a = loop[i]
            let b = loop[(i + 1) % loop.count]
            let dx = Int(b.x - a.x)
            let dy = Int(b.y - a.y)
            let stepX = CGFloat(dx.signum())
            let stepY = CGFloat(dy.signum())
            for k in 0..<(abs(dx) + abs(dy)) {
                let t = CGFloat(k) + 0.5
                points.append(CGPoint(x: CGFloat(a.x) + stepX * t, y: CGFloat(a.y) + stepY * t))
            }
        }
        // Filtering would shrink a speck of a few pixels to nothing.
        let n = points.count
        guard n >= 8 else { return points }
        for _ in 0..<2 {
            var pass = points
            for i in 0..<n {
                let before = points[i == 0 ? n - 1 : i - 1]
                let after = points[i == n - 1 ? 0 : i + 1]
                pass[i] = CGPoint(x: (before.x + 2 * points[i].x + after.x) / 4,
                                  y: (before.y + 2 * points[i].y + after.y) / 4)
            }
            points = pass
        }
        return points
    }

    /// Ramer–Douglas–Peucker on a closed polygon: drops vertices while every
    /// dropped one stays within `epsilon` of the simplified outline.
    static func simplifyClosed(_ points: [CGPoint], epsilon: CGFloat) -> [CGPoint] {
        let n = points.count
        guard n > 4 else { return points }

        // A closed polygon has no natural endpoints: anchor the first vertex
        // and the one farthest from it, then simplify the two halves.
        var far = 1
        var farDistance: CGFloat = -1
        for i in 1..<n {
            let d = hypot(points[i].x - points[0].x, points[i].y - points[0].y)
            if d > farDistance { farDistance = d; far = i }
        }
        func point(_ i: Int) -> CGPoint { points[i == n ? 0 : i] }

        var keep = [Bool](repeating: false, count: n)
        keep[0] = true
        keep[far] = true
        var stack = [(0, far), (far, n)]
        while let (a, b) = stack.popLast() {
            guard b > a + 1 else { continue }
            let p = point(a)
            let q = point(b)
            let sx = q.x - p.x
            let sy = q.y - p.y
            let lengthSquared = sx * sx + sy * sy
            var worst = a
            var worstDistance: CGFloat = -1
            for i in (a + 1)..<b {
                let v = points[i]
                var t = lengthSquared > 0 ? ((v.x - p.x) * sx + (v.y - p.y) * sy) / lengthSquared : 0
                t = max(0, min(1, t))
                let d = hypot(v.x - (p.x + t * sx), v.y - (p.y + t * sy))
                if d > worstDistance { worstDistance = d; worst = i }
            }
            if worstDistance > epsilon {
                keep[worst] = true
                stack.append((a, worst))
                stack.append((worst, b))
            }
        }
        var result: [CGPoint] = []
        for i in 0..<n where keep[i] { result.append(points[i]) }
        return result
    }
}

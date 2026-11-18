import Foundation

/// Scanline flood fill over a premultiplied RGBA8 buffer (buffer coordinates:
/// row 0 = top scanline). Produces a mask; painting is done by the caller.
enum FloodFill {
    static func computeMask(buffer: UnsafeMutablePointer<UInt8>,
                            width: Int, height: Int, bytesPerRow: Int,
                            seedX: Int, seedY: Int, tolerance: Int) -> [Bool]? {
        guard seedX >= 0, seedX < width, seedY >= 0, seedY < height else { return nil }

        let seedOffset = seedY * bytesPerRow + seedX * 4
        let t0 = Int(buffer[seedOffset])
        let t1 = Int(buffer[seedOffset + 1])
        let t2 = Int(buffer[seedOffset + 2])
        let t3 = Int(buffer[seedOffset + 3])

        func matches(_ x: Int, _ y: Int) -> Bool {
            let o = y * bytesPerRow + x * 4
            return abs(Int(buffer[o]) - t0) <= tolerance
                && abs(Int(buffer[o + 1]) - t1) <= tolerance
                && abs(Int(buffer[o + 2]) - t2) <= tolerance
                && abs(Int(buffer[o + 3]) - t3) <= tolerance
        }

        var mask = [Bool](repeating: false, count: width * height)
        var stack: [(x: Int, y: Int)] = [(seedX, seedY)]

        while let (sx, sy) = stack.popLast() {
            if mask[sy * width + sx] || !matches(sx, sy) { continue }
            var left = sx
            while left > 0 && !mask[sy * width + left - 1] && matches(left - 1, sy) { left -= 1 }
            var right = sx
            while right < width - 1 && !mask[sy * width + right + 1] && matches(right + 1, sy) { right += 1 }
            for x in left...right { mask[sy * width + x] = true }
            for ny in [sy - 1, sy + 1] where ny >= 0 && ny < height {
                var x = left
                while x <= right {
                    if !mask[ny * width + x] && matches(x, ny) {
                        stack.append((x, ny))
                        while x <= right && matches(x, ny) { x += 1 }
                    } else {
                        x += 1
                    }
                }
            }
        }
        return mask
    }
}

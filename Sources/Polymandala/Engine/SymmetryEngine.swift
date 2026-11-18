import CoreGraphics

enum SymmetryEngine {
    /// The combined transform set for a stroke drawn with several active centers.
    ///
    /// Independent mode (`linked == false`): each center replicates the stroke
    /// through its own rotations/mirrors — the result depends on how far the
    /// stroke is from each center.
    ///
    /// Linked mode (`linked == true`): the first center is the master. Its
    /// symmetry copies are computed once, and every other center receives that
    /// exact motif translated by the offset between the centers — an identical
    /// stamped pattern regardless of distance (their own fold settings are
    /// ignored; the master defines the pattern).
    static func transforms(for symmetries: [SymmetryCenter], linked: Bool) -> [CGAffineTransform] {
        guard linked, let master = symmetries.first else {
            return symmetries.flatMap { transforms(for: $0) }
        }
        let base = transforms(for: master)
        var all: [CGAffineTransform] = []
        all.reserveCapacity(base.count * symmetries.count)
        for center in symmetries {
            let shift = CGAffineTransform(translationX: center.position.x - master.position.x,
                                          y: center.position.y - master.position.y)
            // Master transform first, then the translation to this center.
            all.append(contentsOf: base.map { $0.concatenating(shift) })
        }
        return all
    }

    /// The full transform set for a symmetry center: n rotations about the center,
    /// each optionally paired with its reflection (mirror across the vertical axis
    /// through the center, then rotated). foldCount 1 + mirror off = [identity].
    static func transforms(for center: SymmetryCenter) -> [CGAffineTransform] {
        let n = max(1, min(36, center.foldCount))
        let cx = center.position.x
        let cy = center.position.y
        var result: [CGAffineTransform] = []
        result.reserveCapacity(center.mirror ? 2 * n : n)
        for k in 0..<n {
            let angle = 2 * .pi * CGFloat(k) / CGFloat(n)
            // Ops chained with rotated/scaled/translatedBy are applied to points in
            // reverse declaration order: translate(-c), [scale], rotate, translate(+c).
            let rotation = CGAffineTransform(translationX: cx, y: cy)
                .rotated(by: angle)
                .translatedBy(x: -cx, y: -cy)
            result.append(rotation)
            if center.mirror {
                let reflection = CGAffineTransform(translationX: cx, y: cy)
                    .rotated(by: angle)
                    .scaledBy(x: -1, y: 1)
                    .translatedBy(x: -cx, y: -cy)
                result.append(reflection)
            }
        }
        return result
    }
}

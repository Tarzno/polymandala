import Foundation

/// Owns the raster layer and keeps periodic bitmap checkpoints so undo does not
/// replay the whole op history.
final class CanvasRenderer {
    let layer: RasterLayer
    private let checkpointInterval = 20
    private let maxCheckpoints = 6
    private var checkpoints: [(count: Int, data: Data)] = []
    private(set) var renderedCount = 0

    init?(width: Int, height: Int) {
        guard let layer = RasterLayer(width: width, height: height) else { return nil }
        self.layer = layer
    }

    func rebuildAll(ops: [DrawOp]) {
        layer.clear()
        checkpoints.removeAll()
        renderedCount = 0
        for op in ops { append(op) }
    }

    func append(_ op: DrawOp) {
        layer.render(op)
        renderedCount += 1
        if renderedCount % checkpointInterval == 0 {
            checkpoints.append((renderedCount, layer.snapshotData()))
            if checkpoints.count > maxCheckpoints {
                checkpoints.removeFirst()
            }
        }
    }

    /// Rewind to the first `count` ops of `ops` (checkpoint restore + replay).
    func rewind(to count: Int, ops: [DrawOp]) {
        checkpoints.removeAll { $0.count > count }
        if let checkpoint = checkpoints.last {
            layer.restore(checkpoint.data)
            renderedCount = checkpoint.count
        } else {
            layer.clear()
            renderedCount = 0
        }
        while renderedCount < count {
            layer.render(ops[renderedCount])
            renderedCount += 1
        }
    }
}

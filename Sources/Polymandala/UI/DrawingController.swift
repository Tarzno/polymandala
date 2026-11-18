import CoreGraphics
import Foundation

/// Central hub: owns the document and renderer, holds tool state, and notifies
/// the canvas view and sidebar when anything changes.
final class DrawingController {
    private(set) var document: DrawingDocument
    private(set) var renderer: CanvasRenderer

    struct ToolSettings {
        var color: RGBAColor
        var width: Double
    }

    var settings: [ToolKind: ToolSettings] = [
        .brush: ToolSettings(color: RGBAColor(r: 0.20, g: 0.32, b: 0.75, a: 1), width: 8),
        .line: ToolSettings(color: RGBAColor(r: 0.55, g: 0.15, b: 0.55, a: 1), width: 4),
        .ellipse: ToolSettings(color: RGBAColor(r: 0.85, g: 0.35, b: 0.10, a: 1), width: 4),
        .triangle: ToolSettings(color: RGBAColor(r: 0.10, g: 0.55, b: 0.35, a: 1), width: 4),
        .rectangle: ToolSettings(color: RGBAColor(r: 0.75, g: 0.20, b: 0.25, a: 1), width: 4),
        .eraser: ToolSettings(color: .black, width: 24),
        .fill: ToolSettings(color: RGBAColor(r: 0.95, g: 0.75, b: 0.20, a: 1), width: 0),
        .center: ToolSettings(color: .black, width: 0),
    ]

    var activeTool: ToolKind = .brush {
        didSet { notifyState() }
    }

    var showGuides = true {
        didSet { notifyCanvas() }
    }

    var fillTolerance = 0.08

    var onCanvasChanged: (() -> Void)?
    var onStateChanged: (() -> Void)?

    private var cachedComposite: CGImage?

    init?(document: DrawingDocument) {
        guard let renderer = CanvasRenderer(width: document.config.width,
                                            height: document.config.height) else { return nil }
        self.document = document
        self.renderer = renderer
        renderer.layer.fallbackBackground = document.config.background
        renderer.rebuildAll(ops: document.ops)
    }

    var compositeImage: CGImage? {
        if cachedComposite == nil {
            cachedComposite = renderer.layer.compositedImage(background: document.config.background)
        }
        return cachedComposite
    }

    private func invalidateComposite() {
        cachedComposite = nil
    }

    private func notifyCanvas() {
        onCanvasChanged?()
    }

    private func notifyState() {
        onStateChanged?()
        onCanvasChanged?()
    }

    // MARK: - Ops

    func commit(_ op: DrawOp) {
        document.ops.append(op)
        document.redoStack.removeAll()
        document.isDirty = true
        renderer.append(op)
        invalidateComposite()
        notifyState()
    }

    var canUndo: Bool { !document.ops.isEmpty }
    var canRedo: Bool { !document.redoStack.isEmpty }

    /// Something is on the canvas that Clear Canvas would remove.
    var canClear: Bool {
        guard let last = document.ops.last else { return false }
        if case .clear = last { return false }
        return true
    }

    func clearCanvas() {
        guard canClear else { return }
        commit(.clear)
    }

    func undo() {
        guard canUndo else { return }
        document.redoStack.append(document.ops.removeLast())
        renderer.rewind(to: document.ops.count, ops: document.ops)
        document.isDirty = true
        invalidateComposite()
        notifyState()
    }

    func redo() {
        guard canRedo else { return }
        let op = document.redoStack.removeLast()
        document.ops.append(op)
        renderer.append(op)
        document.isDirty = true
        invalidateComposite()
        notifyState()
    }

    // MARK: - Symmetry centers

    /// Centers that receive new strokes, in document order.
    var activeCenters: [SymmetryCenter] {
        document.centers.filter { document.activeCenterIDs.contains($0.id) }
    }

    /// Active centers ordered for ops: the anchor (master in linked mode) first.
    /// In linked mode the anchor is the active center nearest to where the
    /// stroke starts, so the motif forms around the center the user draws at
    /// and is stamped at the others; without a reference point (or unlinked)
    /// it falls back to the primary center.
    func strokeSymmetries(near point: CGPoint? = nil) -> [SymmetryCenter] {
        var result = activeCenters
        var anchorID = document.primaryCenterID
        if linkedCenters, let point,
           let nearest = result.min(by: {
               hypot($0.position.x - point.x, $0.position.y - point.y)
                   < hypot($1.position.x - point.x, $1.position.y - point.y)
           }) {
            anchorID = nearest.id
        }
        if let index = result.firstIndex(where: { $0.id == anchorID }), index > 0 {
            result.insert(result.remove(at: index), at: 0)
        }
        return result
    }

    /// Stamp the primary's exact pattern at every active center (translated
    /// copies) instead of replicating independently around each one.
    var linkedCenters: Bool {
        get { document.linkedCenters }
        set {
            document.linkedCenters = newValue
            document.isDirty = true
            notifyState()
        }
    }

    var primaryCenter: SymmetryCenter {
        document.centers.first { $0.id == document.primaryCenterID } ?? document.centers[0]
    }

    func isActive(_ index: Int) -> Bool {
        document.activeCenterIDs.contains(document.centers[index].id)
    }

    func isPrimary(_ index: Int) -> Bool {
        document.centers[index].id == document.primaryCenterID
    }

    /// Applies fold/mirror changes to every active center.
    func updateActiveCenters(foldCount: Int? = nil, mirror: Bool? = nil) {
        for index in document.centers.indices
        where document.activeCenterIDs.contains(document.centers[index].id) {
            if let foldCount { document.centers[index].foldCount = max(1, min(36, foldCount)) }
            if let mirror { document.centers[index].mirror = mirror }
        }
        document.isDirty = true
        notifyState()
    }

    func addCenter(at point: CGPoint, extendSelection: Bool = false) {
        let template = primaryCenter
        let center = SymmetryCenter(position: point,
                                    foldCount: template.foldCount,
                                    mirror: template.mirror)
        document.centers.append(center)
        if extendSelection {
            document.activeCenterIDs.insert(center.id)
        } else {
            document.activeCenterIDs = [center.id]
        }
        document.primaryCenterID = center.id
        document.isDirty = true
        notifyState()
    }

    /// Plain click: this center becomes the only active one (and primary).
    func selectCenterExclusive(_ index: Int) {
        guard index >= 0, index < document.centers.count else { return }
        let id = document.centers[index].id
        document.activeCenterIDs = [id]
        document.primaryCenterID = id
        notifyState()
    }

    /// Shift-click: toggle membership in the active set (never empties it).
    func toggleCenterActive(_ index: Int) {
        guard index >= 0, index < document.centers.count else { return }
        let id = document.centers[index].id
        if document.activeCenterIDs.contains(id) {
            guard document.activeCenterIDs.count > 1 else {
                notifyState() // rejected: re-sync the sidebar checkbox
                return
            }
            document.activeCenterIDs.remove(id)
        } else {
            document.activeCenterIDs.insert(id)
            document.primaryCenterID = id
        }
        document.normalizeActiveSet()
        notifyState()
    }

    /// Index of the center within hitRadius of the point, preferring the closest.
    func centerIndex(at point: CGPoint, hitRadius: CGFloat) -> Int? {
        var best: (index: Int, distance: CGFloat)?
        for (index, center) in document.centers.enumerated() {
            let d = hypot(center.position.x - point.x, center.position.y - point.y)
            if d <= hitRadius && (best == nil || d < best!.distance) {
                best = (index, d)
            }
        }
        return best?.index
    }

    func movePrimaryCenter(to point: CGPoint) {
        guard let index = document.centers.firstIndex(where: { $0.id == document.primaryCenterID })
        else { return }
        document.centers[index].position = point
        document.isDirty = true
        notifyCanvas() // titles in the sidebar don't change; skip the full refresh
    }

    func removePrimaryCenter() {
        guard document.centers.count > 1,
              let index = document.centers.firstIndex(where: { $0.id == document.primaryCenterID })
        else { return }
        document.centers.remove(at: index)
        document.normalizeActiveSet()
        document.isDirty = true
        notifyState()
    }

    // MARK: - Random demo

    private var demoTimer: Timer?
    private var demoQueue: [DrawOp] = []
    private var demoIdleTicks = 0

    var isDemoRunning: Bool { demoTimer != nil }

    func toggleDemo() {
        if isDemoRunning { stopDemo() } else { startDemo() }
    }

    func startDemo() {
        guard demoTimer == nil else { return }
        beginDemoPolymandala()
        demoTimer = Timer.scheduledTimer(withTimeInterval: 0.4, repeats: true) { [weak self] _ in
            self?.stepDemo()
        }
        notifyState()
    }

    func stopDemo() {
        demoTimer?.invalidate()
        demoTimer = nil
        demoQueue = []
        notifyState()
    }

    /// Roll a fresh mandala: wipe the canvas (an undoable .clear, so earlier
    /// artwork survives via ⌘Z), adopt the generated palette and centers, and
    /// queue the build ops for the timer to commit one by one.
    private func beginDemoPolymandala() {
        let generated = PolymandalaGenerator.generate(width: document.config.width,
                                                  height: document.config.height,
                                                  seed: UInt64.random(in: .min ... .max))
        if canClear { commit(.clear) }
        document.centers = generated.centers
        document.activeCenterIDs = Set(generated.centers.map(\.id))
        document.primaryCenterID = generated.centers[0].id
        document.linkedCenters = generated.linked
        setBackground(generated.background)
        demoQueue = generated.ops
        demoIdleTicks = 0
    }

    private func stepDemo() {
        guard !demoQueue.isEmpty else {
            demoIdleTicks += 1
            if demoIdleTicks >= 7 { beginDemoPolymandala() } // admire pause, then reroll
            return
        }
        commit(demoQueue.removeFirst())
    }

    // MARK: - Canvas / document lifecycle

    func setBackground(_ color: RGBAColor) {
        document.config.background = color
        renderer.layer.fallbackBackground = color
        document.isDirty = true
        invalidateComposite()
        notifyState()
    }

    func save(to url: URL) throws {
        let data = try document.snapshotData()
        try data.write(to: url, options: .atomic)
        document.fileURL = url
        document.isDirty = false
        document.removeAutosaveStash()
        notifyState()
    }

    func exportPNG(to url: URL) throws {
        guard let image = compositeImage else {
            throw NSError(domain: "Polymandala", code: 4,
                          userInfo: [NSLocalizedDescriptionKey: "Nothing to export"])
        }
        try writePNG(image, to: url)
    }
}

import CoreGraphics
import Foundation

struct CanvasConfig: Codable, Equatable {
    var width: Int
    var height: Int
    var background: RGBAColor
}

final class DrawingDocument {
    var config: CanvasConfig
    var centers: [SymmetryCenter]
    /// Centers that receive new strokes (drawing replicates at each of them).
    var activeCenterIDs: Set<UUID>
    /// The center whose settings the sidebar edits first and that the center
    /// tool drags; always a member of activeCenterIDs.
    var primaryCenterID: UUID
    var ops: [DrawOp] = []
    var redoStack: [DrawOp] = []
    /// Names this document's crash-recovery stash file (untitled documents only).
    var autosaveID = UUID()
    /// When true, new strokes stamp the primary center's exact pattern at
    /// every active center (translated copies) instead of replicating
    /// independently around each center.
    var linkedCenters = false
    var fileURL: URL?
    var isDirty = false

    init(config: CanvasConfig, centers: [SymmetryCenter],
         activeCenterIDs: Set<UUID> = [], primaryCenterID: UUID? = nil) {
        self.config = config
        self.centers = centers.isEmpty
            ? [SymmetryCenter(position: CGPoint(x: config.width / 2, y: config.height / 2))]
            : centers
        self.activeCenterIDs = activeCenterIDs
        self.primaryCenterID = primaryCenterID ?? self.centers[0].id
        normalizeActiveSet()
    }

    /// Restores the invariants: active IDs all exist, at least one is active,
    /// and the primary is a member of the active set.
    func normalizeActiveSet() {
        let existing = Set(centers.map(\.id))
        activeCenterIDs.formIntersection(existing)
        if activeCenterIDs.isEmpty {
            activeCenterIDs = [centers[0].id]
        }
        if !activeCenterIDs.contains(primaryCenterID) {
            // Prefer document order over Set order for determinism.
            primaryCenterID = centers.first { activeCenterIDs.contains($0.id) }!.id
        }
    }

    static func makeDefault(width: Int = 2048, height: Int = 2048,
                            background: RGBAColor = .white) -> DrawingDocument {
        let config = CanvasConfig(width: width, height: height, background: background)
        let center = SymmetryCenter(position: CGPoint(x: width / 2, y: height / 2),
                                    foldCount: 8, mirror: true)
        return DrawingDocument(config: config, centers: [center])
    }

    // MARK: - Persistence (.polymandala = JSON)

    struct Snapshot: Codable {
        var version: Int
        var config: CanvasConfig
        var centers: [SymmetryCenter]
        var activeCenterIDs: [UUID]?
        var primaryCenterID: UUID?
        var activeCenterIndex: Int? // legacy v1 documents
        var linkedCenters: Bool?
        var ops: [DrawOp]
    }

    func snapshotData() throws -> Data {
        let snapshot = Snapshot(version: 3, config: config, centers: centers,
                                activeCenterIDs: activeCenterIDs.sorted { $0.uuidString < $1.uuidString },
                                primaryCenterID: primaryCenterID,
                                activeCenterIndex: nil,
                                linkedCenters: linkedCenters, ops: ops)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return try encoder.encode(snapshot)
    }

    static func fromData(_ data: Data) throws -> DrawingDocument {
        let snapshot = try JSONDecoder().decode(Snapshot.self, from: data)
        var activeIDs = Set(snapshot.activeCenterIDs ?? [])
        if activeIDs.isEmpty, let index = snapshot.activeCenterIndex,
           index >= 0, index < snapshot.centers.count {
            activeIDs = [snapshot.centers[index].id]
        }
        let document = DrawingDocument(config: snapshot.config, centers: snapshot.centers,
                                       activeCenterIDs: activeIDs,
                                       primaryCenterID: snapshot.primaryCenterID)
        document.linkedCenters = snapshot.linkedCenters ?? false
        document.ops = snapshot.ops
        return document
    }
}

// MARK: - Autosave stash (crash recovery for untitled documents)

extension DrawingDocument {
    static var autosaveDirectory: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Polymandala/Autosave", isDirectory: true)
    }

    var autosaveStashURL: URL {
        Self.autosaveDirectory.appendingPathComponent(autosaveID.uuidString + ".polymandala")
    }

    func writeAutosaveStash() {
        guard let data = try? snapshotData() else { return }
        try? FileManager.default.createDirectory(at: Self.autosaveDirectory,
                                                 withIntermediateDirectories: true)
        try? data.write(to: autosaveStashURL, options: .atomic)
    }

    func removeAutosaveStash() {
        try? FileManager.default.removeItem(at: autosaveStashURL)
    }
}

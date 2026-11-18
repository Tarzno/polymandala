import AppKit

/// Displays the composited canvas aspect-fit, handles tool mouse input, and
/// draws the live symmetric stroke preview plus symmetry guides.
/// View and canvas both use bottom-left origin (view is not flipped).
final class CanvasView: NSView {
    weak var controller: DrawingController? {
        didSet { needsDisplay = true }
    }

    private var dragPoints: [CGPoint] = []
    private var draggingStroke = false
    private var draggingCenter = false

    override var acceptsFirstResponder: Bool { true }
    override var isOpaque: Bool { true }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        if #available(macOS 14.0, *) {
            clipsToBounds = true
        }
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not used")
    }

    // MARK: - Coordinate mapping (aspect-fit)

    private var canvasSize: CGSize {
        guard let c = controller else { return CGSize(width: 1, height: 1) }
        return CGSize(width: c.document.config.width, height: c.document.config.height)
    }

    private var fitScale: CGFloat {
        let s = canvasSize
        let margin: CGFloat = 16
        let availW = max(50, bounds.width - 2 * margin)
        let availH = max(50, bounds.height - 2 * margin)
        return min(availW / s.width, availH / s.height)
    }

    // MARK: - Zoom & pan

    private(set) var zoom: CGFloat = 1 // 1 = aspect-fit
    private var panOffset = CGPoint.zero
    var onZoomChanged: (() -> Void)?

    private var displayScale: CGFloat { fitScale * zoom }

    private var canvasToView: CGAffineTransform {
        let s = canvasSize
        let scale = displayScale
        let offsetX = (bounds.width - s.width * scale) / 2 + panOffset.x
        let offsetY = (bounds.height - s.height * scale) / 2 + panOffset.y
        return CGAffineTransform(translationX: offsetX, y: offsetY).scaledBy(x: scale, y: scale)
    }

    /// View point → canvas coordinates (exposed for the self-test).
    func canvasPoint(at viewPoint: CGPoint) -> CGPoint {
        viewPoint.applying(canvasToView.inverted())
    }

    private func canvasPoint(from event: NSEvent) -> CGPoint {
        canvasPoint(at: convert(event.locationInWindow, from: nil))
    }

    /// Sets the zoom (clamped to 1…16), keeping the canvas point under
    /// `anchor` (view coordinates; default: view center) fixed on screen.
    func setZoom(_ value: CGFloat, anchor: CGPoint? = nil) {
        let clamped = max(1, min(16, value))
        guard clamped != zoom else { return }
        let anchorPoint = anchor ?? CGPoint(x: bounds.midX, y: bounds.midY)
        let canvasAnchor = canvasPoint(at: anchorPoint)
        zoom = clamped
        let moved = canvasAnchor.applying(canvasToView)
        panOffset.x += anchorPoint.x - moved.x
        panOffset.y += anchorPoint.y - moved.y
        clampPan()
        needsDisplay = true
        onZoomChanged?()
    }

    func zoomIn() { setZoom(zoom * 1.25) }
    func zoomOut() { setZoom(zoom / 1.25) }

    func zoomToFit() {
        zoom = 1
        panOffset = .zero
        needsDisplay = true
        onZoomChanged?()
    }

    /// Keeps the canvas covering the view while zoomed in; centers it otherwise.
    private func clampPan() {
        let s = canvasSize
        let scale = displayScale
        let margin: CGFloat = 16
        let displayW = s.width * scale
        let displayH = s.height * scale
        if displayW <= bounds.width - 2 * margin {
            panOffset.x = 0
        } else {
            let base = (bounds.width - displayW) / 2
            panOffset.x = max(bounds.width - margin - displayW - base, min(margin - base, panOffset.x))
        }
        if displayH <= bounds.height - 2 * margin {
            panOffset.y = 0
        } else {
            let base = (bounds.height - displayH) / 2
            panOffset.y = max(bounds.height - margin - displayH - base, min(margin - base, panOffset.y))
        }
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        clampPan()
    }

    override func magnify(with event: NSEvent) {
        let anchor = convert(event.locationInWindow, from: nil)
        setZoom(zoom * (1 + event.magnification), anchor: anchor)
    }

    override func scrollWheel(with event: NSEvent) {
        guard zoom > 1 else { return }
        panOffset.x += event.scrollingDeltaX
        panOffset.y -= event.scrollingDeltaY
        clampPan()
        needsDisplay = true
    }

    // MARK: - Drawing

    override func draw(_ dirtyRect: NSRect) {
        guard let g = NSGraphicsContext.current?.cgContext else { return }
        g.setFillColor(CGColor(gray: 0.17, alpha: 1))
        g.fill(bounds)
        guard let c = controller else { return }

        let t = canvasToView
        let canvasRect = CGRect(origin: .zero, size: canvasSize).applying(t)

        if let image = c.compositeImage {
            g.saveGState()
            g.interpolationQuality = .high
            g.draw(image, in: canvasRect)
            g.restoreGState()
        }
        g.setStrokeColor(CGColor(gray: 0.45, alpha: 1))
        g.setLineWidth(1)
        g.stroke(canvasRect.insetBy(dx: -0.5, dy: -0.5))

        g.saveGState()
        g.clip(to: canvasRect)
        g.concatenate(t)
        drawLivePreview(in: g, controller: c)
        g.restoreGState()

        if c.showGuides {
            g.saveGState()
            // On modern SDKs NSView no longer clips drawing to its bounds, so
            // unclipped guide lines would spill over the sidebar.
            g.clip(to: canvasRect)
            g.concatenate(t)
            drawGuides(in: g, controller: c)
            g.restoreGState()
        }
    }

    private func drawLivePreview(in g: CGContext, controller c: DrawingController) {
        guard draggingStroke, !dragPoints.isEmpty else { return }
        let tool = c.activeTool
        guard let settings = c.settings[tool],
              let base = StrokeGeometry.path(for: tool, points: dragPoints, width: settings.width)
        else { return }
        let color: CGColor = tool == .eraser
            ? CGColor(gray: 1, alpha: 0.7)
            : settings.color.cgColor
        for transform in SymmetryEngine.transforms(for: c.strokeSymmetries(near: dragPoints.first),
                                                   linked: c.linkedCenters) {
            var t = transform
            guard let path = base.copy(using: &t) else { continue }
            g.saveGState()
            g.setStrokeColor(color)
            g.setLineWidth(CGFloat(settings.width))
            g.setLineCap(.round)
            g.setLineJoin(.round)
            g.addPath(path)
            g.strokePath()
            g.restoreGState()
        }
    }

    private func drawGuides(in g: CGContext, controller c: DrawingController) {
        let scale = displayScale
        let spokeLength = hypot(canvasSize.width, canvasSize.height)
        for (index, var center) in c.document.centers.enumerated() {
            let isActive = c.isActive(index)
            let isPrimary = c.isPrimary(index)
            if c.linkedCenters && isActive && !isPrimary {
                // Linked mode ignores their own fold settings; show the master's.
                center.foldCount = c.primaryCenter.foldCount
                center.mirror = c.primaryCenter.mirror
            }
            let color: CGColor = isActive
                ? CGColor(srgbRed: 0.25, green: 0.55, blue: 1.0, alpha: 0.55)
                : CGColor(gray: 0.5, alpha: 0.30)
            g.saveGState()
            g.setStrokeColor(color)
            g.setLineWidth(1 / scale)

            let n = center.foldCount
            for k in 0..<n {
                let angle = 2 * .pi * CGFloat(k) / CGFloat(n) + .pi / 2
                g.move(to: center.position)
                g.addLine(to: CGPoint(x: center.position.x + spokeLength * cos(angle),
                                      y: center.position.y + spokeLength * sin(angle)))
            }
            g.strokePath()

            if center.mirror && n >= 1 {
                g.setLineDash(phase: 0, lengths: [6 / scale, 6 / scale])
                for k in 0..<n {
                    let angle = 2 * .pi * (CGFloat(k) + 0.5) / CGFloat(n) + .pi / 2
                    g.move(to: center.position)
                    g.addLine(to: CGPoint(x: center.position.x + spokeLength * cos(angle),
                                          y: center.position.y + spokeLength * sin(angle)))
                }
                g.strokePath()
                g.setLineDash(phase: 0, lengths: [])
            }

            // Center marker (primary gets an extra halo ring)
            let r = 7 / scale
            let markerRect = CGRect(x: center.position.x - r, y: center.position.y - r,
                                    width: 2 * r, height: 2 * r)
            g.setFillColor(isActive
                ? CGColor(srgbRed: 0.25, green: 0.55, blue: 1.0, alpha: 0.9)
                : CGColor(gray: 0.55, alpha: 0.8))
            g.fillEllipse(in: markerRect)
            g.setStrokeColor(CGColor(gray: 1, alpha: 0.9))
            g.setLineWidth(1.5 / scale)
            g.strokeEllipse(in: markerRect)
            if isPrimary {
                g.setStrokeColor(CGColor(srgbRed: 0.25, green: 0.55, blue: 1.0, alpha: 0.9))
                g.setLineWidth(1.5 / scale)
                g.strokeEllipse(in: markerRect.insetBy(dx: -4 / scale, dy: -4 / scale))
            }
            g.restoreGState()
        }
    }

    // MARK: - Mouse input

    override func mouseDown(with event: NSEvent) {
        guard let c = controller else { return }
        window?.makeFirstResponder(self)
        let p = canvasPoint(from: event)

        let shiftHeld = event.modifierFlags.contains(.shift)
        switch c.activeTool {
        case .fill:
            guard pointInCanvas(p), let s = c.settings[.fill] else { return }
            c.commit(.fill(FillOp(color: s.color, seed: p, tolerance: c.fillTolerance,
                                  symmetries: c.strokeSymmetries(near: p), linked: c.linkedCenters,
                                  background: c.document.config.background)))
        case .center:
            if let index = c.centerIndex(at: p, hitRadius: 14 / displayScale) {
                if shiftHeld {
                    c.toggleCenterActive(index) // no drag: toggling shouldn't nudge the marker
                } else {
                    c.selectCenterExclusive(index)
                    draggingCenter = true
                }
            } else if pointInCanvas(p) {
                c.addCenter(at: p, extendSelection: shiftHeld)
                draggingCenter = true
            } else {
                return
            }
        case .brush, .line, .ellipse, .triangle, .rectangle, .eraser:
            draggingStroke = true
            dragPoints = [p]
        }
        needsDisplay = true
    }

    override func mouseDragged(with event: NSEvent) {
        guard let c = controller else { return }
        let p = canvasPoint(from: event)
        if draggingCenter {
            c.movePrimaryCenter(to: clampToCanvas(p))
        } else if draggingStroke {
            switch c.activeTool {
            case .brush, .eraser:
                if let last = dragPoints.last, hypot(p.x - last.x, p.y - last.y) >= 1.5 / displayScale {
                    dragPoints.append(p)
                }
            case .line, .ellipse, .triangle, .rectangle:
                let end = event.modifierFlags.contains(.shift)
                    ? CanvasView.constrainedEnd(p, from: dragPoints[0], tool: c.activeTool)
                    : p
                dragPoints = [dragPoints[0], end]
            default:
                break
            }
        }
        needsDisplay = true
    }

    override func mouseUp(with event: NSEvent) {
        guard let c = controller else { return }
        defer {
            draggingStroke = false
            draggingCenter = false
            dragPoints = []
            needsDisplay = true
        }
        guard draggingStroke, let settings = c.settings[c.activeTool] else { return }
        let tool = c.activeTool
        switch tool {
        case .brush, .eraser:
            guard !dragPoints.isEmpty else { return }
        case .line, .ellipse, .triangle, .rectangle:
            guard dragPoints.count >= 2 else { return } // click without drag: nothing to draw
        default:
            return
        }
        c.commit(.stroke(StrokeOp(tool: tool, color: settings.color, width: settings.width,
                                  points: dragPoints, symmetries: c.strokeSymmetries(near: dragPoints.first),
                                  linked: c.linkedCenters)))
    }

    /// Shift-constrained drag endpoint: ellipse → circle, rectangle → square,
    /// triangle → equilateral (bounding height = width·√3/2), line → snapped
    /// to 45° increments. Static and pure so the self-test can verify it.
    static func constrainedEnd(_ p: CGPoint, from origin: CGPoint, tool: ToolKind) -> CGPoint {
        let dx = p.x - origin.x
        let dy = p.y - origin.y
        switch tool {
        case .ellipse, .rectangle:
            let side = max(abs(dx), abs(dy))
            return CGPoint(x: origin.x + (dx < 0 ? -side : side),
                           y: origin.y + (dy < 0 ? -side : side))
        case .triangle:
            let ratio = sqrt(3.0) / 2
            let width = max(abs(dx), abs(dy) / ratio)
            return CGPoint(x: origin.x + (dx < 0 ? -width : width),
                           y: origin.y + (dy < 0 ? -width * ratio : width * ratio))
        case .line:
            let step = CGFloat.pi / 4
            let angle = (atan2(dy, dx) / step).rounded() * step
            let length = hypot(dx, dy)
            return CGPoint(x: origin.x + length * cos(angle),
                           y: origin.y + length * sin(angle))
        default:
            return p
        }
    }

    private func pointInCanvas(_ p: CGPoint) -> Bool {
        p.x >= 0 && p.y >= 0 && p.x < canvasSize.width && p.y < canvasSize.height
    }

    private func clampToCanvas(_ p: CGPoint) -> CGPoint {
        CGPoint(x: max(0, min(canvasSize.width - 1, p.x)),
                y: max(0, min(canvasSize.height - 1, p.y)))
    }

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: .crosshair)
    }
}

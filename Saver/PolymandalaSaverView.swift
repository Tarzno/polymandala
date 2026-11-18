import AppKit
import ScreenSaver

/// The Polymandala screensaver: builds random vibrant-on-black mandalas stage by
/// stage using the app's generator and raster engine, pausing to admire each
/// before rolling the next. macOS creates one instance per screen, and every
/// instance seeds its own RNG, so each monitor shows a different mandala.
@objc(PolymandalaSaverView)
public final class PolymandalaSaverView: ScreenSaverView {
    private var raster: RasterLayer?
    private var canvasSide = 0
    private var pending: [DrawOp] = []
    private var idleTicks = 0
    private var background = RGBAColor.black
    private var composite: CGImage?

    public override init?(frame: NSRect, isPreview: Bool) {
        super.init(frame: frame, isPreview: isPreview)
        animationTimeInterval = 0.4
    }

    public required init?(coder: NSCoder) {
        super.init(coder: coder)
        animationTimeInterval = 0.4
    }

    /// Lazily sized on first use so the backing scale of the actual screen is
    /// known. Capped: fills scale with pixel count and 2048² animates smoothly.
    private func setupIfNeeded() {
        guard raster == nil else { return }
        let scale = window?.backingScaleFactor ?? 2
        canvasSide = max(512, min(2048, Int(min(bounds.width, bounds.height) * scale)))
        raster = RasterLayer(width: canvasSide, height: canvasSide)
        beginPolymandala()
    }

    private func beginPolymandala() {
        guard let raster else { return }
        let generated = PolymandalaGenerator.generate(width: canvasSide, height: canvasSide,
                                                  seed: UInt64.random(in: .min ... .max),
                                                  vibrantOnBlack: true)
        background = generated.background
        raster.fallbackBackground = generated.background
        raster.clear()
        pending = generated.ops
        idleTicks = 0
        composite = nil
    }

    public override func animateOneFrame() {
        setupIfNeeded()
        guard let raster else { return }
        if pending.isEmpty {
            idleTicks += 1
            if idleTicks >= 10 { // ~4s to admire the finished mandala
                beginPolymandala()
                needsDisplay = true
            }
            return
        }
        raster.render(pending.removeFirst())
        composite = nil
        needsDisplay = true
    }

    public override func draw(_ rect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        ctx.setFillColor(CGColor(red: 0, green: 0, blue: 0, alpha: 1))
        ctx.fill(bounds)
        setupIfNeeded()
        guard let raster else { return }
        if composite == nil {
            composite = raster.compositedImage(background: background)
        }
        guard let image = composite else { return }
        let side = min(bounds.width, bounds.height)
        ctx.interpolationQuality = .high
        ctx.draw(image, in: CGRect(x: bounds.midX - side / 2, y: bounds.midY - side / 2,
                                   width: side, height: side))
    }
}

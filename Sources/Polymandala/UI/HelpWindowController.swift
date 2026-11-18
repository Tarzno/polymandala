import AppKit

/// Help → Polymandala Help: a scrollable window explaining how to use the app.
final class HelpWindowController: TextWindowController {
    convenience init() {
        self.init(title: "Polymandala Help", size: NSSize(width: 560, height: 660),
                  text: Self.helpText())
    }

    private static func helpText() -> NSAttributedString {
        let text = NSMutableAttributedString()
        let bodyStyle = NSMutableParagraphStyle()
        bodyStyle.paragraphSpacing = 6
        bodyStyle.lineSpacing = 2
        let body: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 13),
            .foregroundColor: NSColor.labelColor,
            .paragraphStyle: bodyStyle,
        ]
        let headingStyle = NSMutableParagraphStyle()
        headingStyle.paragraphSpacingBefore = 14
        headingStyle.paragraphSpacing = 6

        func title(_ s: String) {
            text.append(NSAttributedString(string: s + "\n", attributes: [
                .font: NSFont.boldSystemFont(ofSize: 20),
                .foregroundColor: NSColor.labelColor,
            ]))
        }
        func heading(_ s: String) {
            text.append(NSAttributedString(string: s + "\n", attributes: [
                .font: NSFont.boldSystemFont(ofSize: 15),
                .foregroundColor: NSColor.labelColor,
                .paragraphStyle: headingStyle,
            ]))
        }
        func para(_ s: String) {
            text.append(NSAttributedString(string: s + "\n", attributes: body))
        }
        func item(_ name: String, _ s: String) {
            let itemStyle = NSMutableParagraphStyle()
            itemStyle.paragraphSpacing = 4
            itemStyle.headIndent = 16
            itemStyle.firstLineHeadIndent = 0
            text.append(NSAttributedString(string: name, attributes: [
                .font: NSFont.boldSystemFont(ofSize: 13),
                .foregroundColor: NSColor.labelColor,
                .paragraphStyle: itemStyle,
            ]))
            text.append(NSAttributedString(string: " — " + s + "\n", attributes: [
                .font: NSFont.systemFont(ofSize: 13),
                .foregroundColor: NSColor.labelColor,
                .paragraphStyle: itemStyle,
            ]))
        }

        title("Polymandala")
        para("Draw symmetric mandalas: every stroke is replicated live around one or more centers of symmetry. Start drawing on the canvas — the default center sits in the middle with 8-fold mirrored symmetry.")

        heading("Tools")
        item("Brush", "freehand drawing; strokes are automatically smoothed to compensate for mouse/trackpad jitter. A click without dragging paints a dot.")
        item("Line", "drag from start to end. Hold ⇧ to snap the angle to 45° steps.")
        item("Ellipse", "drag the bounding box. Hold ⇧ for a perfect circle.")
        item("Triangle", "drag the bounding box; the apex is at the top-center. Hold ⇧ for an equilateral triangle.")
        item("Rectangle", "drag the bounding box. Hold ⇧ for a square.")
        item("Eraser", "freehand erasing back to the background color.")
        item("Fill", "click a bounded region to flood-fill it with solid color. The fill is applied symmetrically in every sector and at every active center, and compares the colors you actually see on screen: paint that looks like the background behaves like empty canvas. The Tolerance slider sets how much on-screen color variation the fill may cross — raise it if fills stop at faint edges or skip similar-looking areas, lower it if they leak. Symmetric copies that show a genuinely different color (for example where overlapping patterns cover them) are left alone — click those directly to fill them.")
        item("Center", "manage the centers of symmetry (see below).")
        para("Each tool remembers its own color; brush-like tools also remember their stroke width. Change both in the sidebar while the tool is selected.")

        heading("Symmetry")
        para("Folds (1–36) sets how many rotational copies are drawn around a center — 5 = pentagonal, 6 = hexagonal, and so on. Mirror (kaleidoscope) additionally reflects every copy, doubling them. The controls apply to all currently active centers.")

        heading("Centers of symmetry")
        para("With the Center tool: click an empty spot to add a center there, drag a marker to move it, click a marker to make it the only active one. Shift-click a marker (or use the checkboxes in the sidebar) to activate several centers at once — drawing then happens at all of them simultaneously. The ◆ center is the primary. Remove Center deletes the primary (at least one center always remains).")

        heading("Linked mode")
        para("Normally each active center replicates your stroke independently, so the pattern depends on how far the stroke is from each center. With “Linked: stamp ◆ pattern at all” enabled, the motif is computed once around the active center nearest to your stroke and then stamped as an exact translated copy at every other active center — ideal for repetitive, overlapping patterns. Fills stamp the same way.")

        heading("Random Demo")
        para("The Random Demo button in the sidebar (or View → Random Demo, ⌘D) builds random mandalas before your eyes, stage by stage — each one with a fresh color palette, symmetry, and layout, occasionally as a linked multi-center lattice. Click again to stop; the current mandala stays on the canvas as a normal, editable drawing, so you can continue on it, save it, or export it. Starting the demo clears the canvas as an ordinary undoable step (⌘Z brings your artwork back).")

        heading("Zoom & pan")
        para("Pinch on the trackpad to zoom in and out around the cursor (up to 16×), or use View → Zoom In / Zoom Out (⌘+ / ⌘−). While zoomed in, scroll with two fingers to pan around the canvas; the current zoom is shown in the window title. Zoom to Fit (⌘0) returns to the full view.")

        heading("Canvas & files")
        para("File → New Canvas… (⌘N) opens a new drawing in its own window — several documents can be open side by side, and menu commands apply to the frontmost one. The background color can be changed any time in the sidebar without affecting your artwork. Save/Open (⌘S/⌘O) use the .polymandala document format; saved drawings also open by double-clicking them in Finder or dropping them onto the app icon or any Polymandala window. File → Export → PNG… (⌘E) writes the finished image at the canvas resolution; Export → SVG… (⇧⌘E) and Export → PDF… (⌥⌘E) write it as vector artwork that stays sharp at any size (see below). Print (⌘P) prints it fitted to the page. Undo/Redo: ⌘Z / ⇧⌘Z. Edit → Clear Canvas (⌘⌫) wipes the drawing — it's a normal undoable step, so ⌘Z brings everything back. View → Show Guides (⌘G) toggles the center markers and sector lines — guides are never exported or printed.")
        heading("SVG and PDF export")
        para("File → Export → SVG… (⇧⌘E) and File → Export → PDF… (⌥⌘E) save the drawing as a scalable vector file for large prints or for further editing in a vector app. Both formats contain the same artwork; the PDF is a single page with one point per canvas pixel. Strokes and shapes are exported as exact curves. Flood fills have no outline of their own, so each one is traced from the canvas and tucked underneath the lines that enclose it — the lines stay perfectly crisp, and only where a fill is not bordered by a line (or covers one) does its traced, pixel-accurate edge show. The current background color is part of the export, and erased areas are painted in it. Very thin outlines (under 2 px) can leave hairline gaps next to fills. Large canvases take a few seconds to trace.")

        para("Documents autosave every 30 seconds: drawings already saved to a file are updated in place, and untitled drawings are kept in a recovery stash that reopens automatically after a crash or force-quit. Closing a window with unsaved changes always asks first.")

        return text
    }
}

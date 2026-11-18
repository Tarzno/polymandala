import AppKit
import UniformTypeIdentifiers

/// Types for the open/save panels. The exported UTI (declared in Info.plist)
/// comes first; the plain extension lookup is what Launch Services actually
/// assigns to .polymandala files when the app bundle isn't registered (swift run),
/// so it must be listed too or the open panel greys the files out. Never build
/// this with `conformingTo: .json` — that mints a *different* dynamic type
/// than the files carry, which was exactly that bug.
func polymandalaContentTypes() -> [UTType] {
    var types = [UTType(exportedAs: "io.github.tarzno.polymandala.document", conformingTo: .json)]
    if let byExtension = UTType(filenameExtension: "polymandala"), !types.contains(byExtension) {
        types.append(byExtension)
    }
    return types
}

/// One document window: owns its DrawingController, handles saving, printing,
/// PNG export, and the save-changes prompt when closing.
final class MainWindowController: NSWindowController, NSWindowDelegate {
    let controller: DrawingController
    let canvasView = CanvasView()
    let sidebar = ToolsSidebar()
    var onClose: ((MainWindowController) -> Void)?

    init?(document: DrawingDocument) {
        guard let controller = DrawingController(document: document) else { return nil }
        self.controller = controller
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1240, height: 920),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable],
                              backing: .buffered, defer: false)
        window.minSize = NSSize(width: 800, height: 600)
        window.isReleasedWhenClosed = false
        window.center()
        super.init(window: window)
        window.delegate = self
        // Accept .polymandala files dropped anywhere on the window; the window
        // forwards NSDraggingDestination calls to its delegate (see extension).
        window.registerForDraggedTypes([.fileURL])

        canvasView.controller = controller
        sidebar.controller = controller

        let content = NSView()
        canvasView.translatesAutoresizingMaskIntoConstraints = false
        sidebar.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(sidebar)
        content.addSubview(canvasView)
        NSLayoutConstraint.activate([
            sidebar.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            sidebar.topAnchor.constraint(equalTo: content.topAnchor),
            sidebar.bottomAnchor.constraint(equalTo: content.bottomAnchor),
            sidebar.widthAnchor.constraint(equalToConstant: 236),
            canvasView.leadingAnchor.constraint(equalTo: sidebar.trailingAnchor),
            canvasView.topAnchor.constraint(equalTo: content.topAnchor),
            canvasView.bottomAnchor.constraint(equalTo: content.bottomAnchor),
            canvasView.trailingAnchor.constraint(equalTo: content.trailingAnchor),
        ])
        window.contentView = content

        controller.onCanvasChanged = { [weak self] in
            self?.canvasView.needsDisplay = true
            self?.updateTitle()
        }
        controller.onStateChanged = { [weak self] in
            self?.sidebar.refresh()
            self?.updateTitle()
        }
        canvasView.onZoomChanged = { [weak self] in
            self?.updateTitle()
        }
        updateTitle()
        window.makeFirstResponder(canvasView)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not used")
    }

    var displayName: String {
        controller.document.fileURL?.lastPathComponent ?? "Untitled"
    }

    func updateTitle() {
        let document = controller.document
        let size = "\(document.config.width)×\(document.config.height)"
        var title = "Polymandala — \(displayName) (\(size))"
        if canvasView.zoom != 1 {
            title += " — \(Int((canvasView.zoom * 100).rounded()))%"
        }
        window?.title = title
        window?.isDocumentEdited = document.isDirty
    }

    // MARK: - Saving / export / print (invoked from the menu via AppDelegate)

    @discardableResult
    func saveDocument() -> Bool {
        guard let url = controller.document.fileURL else { return saveDocumentAs() }
        do {
            try controller.save(to: url)
            return true
        } catch {
            presentError("Could not save: \(error.localizedDescription)")
            return false
        }
    }

    @discardableResult
    func saveDocumentAs() -> Bool {
        let panel = NSSavePanel()
        panel.allowedContentTypes = polymandalaContentTypes()
        panel.nameFieldStringValue = controller.document.fileURL?.lastPathComponent ?? "Untitled.polymandala"
        guard panel.runModal() == .OK, let url = panel.url else { return false }
        do {
            try controller.save(to: url)
            return true
        } catch {
            presentError("Could not save: \(error.localizedDescription)")
            return false
        }
    }

    func exportPNG() {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.png]
        let base = controller.document.fileURL?.deletingPathExtension().lastPathComponent ?? "Polymandala"
        panel.nameFieldStringValue = base + ".png"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try controller.exportPNG(to: url)
        } catch {
            presentError("Could not export PNG: \(error.localizedDescription)")
        }
    }

    /// Vector export replays the whole document to trace its flood fills,
    /// which takes a moment on large canvases: the work runs on a background
    /// queue over a snapshot of the ops while a sheet keeps the window busy.
    func exportSVG() {
        exportVector(name: "SVG", type: .svg, fileExtension: "svg") { artwork in
            Data(artwork.svg().utf8)
        }
    }

    func exportPDF() {
        exportVector(name: "PDF", type: .pdf, fileExtension: "pdf") { artwork in
            artwork.pdf()
        }
    }

    private func exportVector(name: String, type: UTType, fileExtension: String,
                              write: @escaping (VectorArtwork) -> Data?) {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [type]
        let base = controller.document.fileURL?.deletingPathExtension().lastPathComponent ?? "Polymandala"
        panel.nameFieldStringValue = base + "." + fileExtension
        guard panel.runModal() == .OK, let url = panel.url else { return }

        let ops = controller.document.ops
        let config = controller.document.config
        let sheet = Self.makeProgressSheet(message: "Exporting \(name)…")
        window?.beginSheet(sheet)
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            var failure: String?
            if let artwork = VectorExporter.artwork(ops: ops, config: config) {
                if let data = write(artwork) {
                    do {
                        try data.write(to: url, options: .atomic)
                    } catch {
                        failure = error.localizedDescription
                    }
                } else {
                    failure = "The \(name) file could not be created."
                }
            } else {
                failure = "Not enough memory to trace a \(config.width)×\(config.height) canvas."
            }
            DispatchQueue.main.async {
                self?.window?.endSheet(sheet)
                if let failure {
                    self?.presentError("Could not export \(name): \(failure)")
                }
            }
        }
    }

    private static func makeProgressSheet(message: String) -> NSWindow {
        let sheet = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 280, height: 72),
                             styleMask: [.titled], backing: .buffered, defer: false)
        let spinner = NSProgressIndicator(frame: NSRect(x: 24, y: 24, width: 24, height: 24))
        spinner.style = .spinning
        spinner.startAnimation(nil)
        let label = NSTextField(labelWithString: message)
        label.frame = NSRect(x: 60, y: 26, width: 200, height: 20)
        sheet.contentView?.addSubview(spinner)
        sheet.contentView?.addSubview(label)
        return sheet
    }

    func printCanvas() {
        guard let cgImage = controller.compositeImage,
              let printInfo = NSPrintInfo.shared.copy() as? NSPrintInfo else { return }
        printInfo.horizontalPagination = .fit
        printInfo.verticalPagination = .fit
        printInfo.isHorizontallyCentered = true
        printInfo.isVerticallyCentered = true
        printInfo.orientation = cgImage.width > cgImage.height ? .landscape : .portrait

        let image = NSImage(cgImage: cgImage,
                            size: NSSize(width: cgImage.width, height: cgImage.height))
        let printable = printInfo.imageablePageBounds
        let imageView = NSImageView(frame: NSRect(origin: .zero, size: printable.size))
        imageView.image = image
        imageView.imageScaling = .scaleProportionallyUpOrDown

        let operation = NSPrintOperation(view: imageView, printInfo: printInfo)
        operation.jobTitle = controller.document.fileURL?.deletingPathExtension().lastPathComponent ?? "Polymandala"
        operation.showsPrintPanel = true
        operation.showsProgressPanel = true
        if let window {
            operation.runModal(for: window, delegate: nil, didRun: nil, contextInfo: nil)
        } else {
            operation.run()
        }
    }

    // MARK: - Closing

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        resolveUnsavedChanges()
    }

    func windowWillClose(_ notification: Notification) {
        controller.stopDemo()
        onClose?(self)
    }

    /// Prompts Save / Don't Save / Cancel for a dirty document. Returns true
    /// when the window may close (saved or explicitly discarded).
    func resolveUnsavedChanges() -> Bool {
        guard controller.document.isDirty else { return true }
        window?.makeKeyAndOrderFront(nil)
        let alert = NSAlert()
        alert.messageText = "Save changes to \(displayName)?"
        alert.informativeText = "Your changes will be lost if you don't save them."
        alert.addButton(withTitle: "Save")
        alert.addButton(withTitle: "Don't Save")
        alert.addButton(withTitle: "Cancel")
        switch alert.runModal() {
        case .alertFirstButtonReturn:
            return saveDocument()
        case .alertSecondButtonReturn:
            controller.document.removeAutosaveStash()
            return true
        default:
            return false
        }
    }

    func presentError(_ message: String) {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "Polymandala"
        alert.informativeText = message
        alert.runModal()
    }
}

// MARK: - Drag & drop of .polymandala files onto the window

/// A registered NSWindow forwards NSDraggingDestination messages to its
/// delegate, so dropping a .polymandala file anywhere on a document window opens
/// it (in its own window, like File → Open).
extension MainWindowController: NSDraggingDestination {
    private func droppedPolymandalaURLs(_ info: NSDraggingInfo) -> [URL] {
        let urls = info.draggingPasteboard.readObjects(
            forClasses: [NSURL.self],
            options: [.urlReadingFileURLsOnly: true]) as? [URL] ?? []
        return urls.filter { $0.pathExtension.lowercased() == "polymandala" }
    }

    func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        droppedPolymandalaURLs(sender).isEmpty ? [] : .copy
    }

    func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        let urls = droppedPolymandalaURLs(sender)
        guard !urls.isEmpty, let delegate = NSApp.delegate as? AppDelegate else { return false }
        delegate.openDocuments(at: urls)
        return true
    }
}

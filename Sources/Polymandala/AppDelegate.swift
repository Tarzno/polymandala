import AppKit
import UniformTypeIdentifiers

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuItemValidation {
    private(set) var windowControllers: [MainWindowController] = []
    private lazy var helpWindowController = HelpWindowController()
    private lazy var licenseWindowController = LicenseWindowController()
    private var autosaveTimer: Timer?
    private var cascadePoint = NSPoint.zero

    /// The document window menu actions apply to.
    var activeWindowController: MainWindowController? {
        (NSApp.keyWindow?.windowController as? MainWindowController)
            ?? (NSApp.mainWindow?.windowController as? MainWindowController)
            ?? windowControllers.last
    }

    private var activeController: DrawingController? {
        activeWindowController?.controller
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        buildMenu()
        restoreAutosavedDocuments()
        if windowControllers.isEmpty {
            addWindow(for: .makeDefault())
        }
        autosaveTimer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in
            self?.autosaveAll()
        }
        NSApp.activate(ignoringOtherApps: true)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        for windowController in windowControllers
        where !windowController.resolveUnsavedChanges() {
            return .terminateCancel
        }
        return .terminateNow
    }

    // MARK: - Window management

    @discardableResult
    private func addWindow(for document: DrawingDocument) -> MainWindowController? {
        guard let windowController = MainWindowController(document: document) else {
            presentError("Could not create a \(document.config.width)×\(document.config.height) canvas.")
            return nil
        }
        windowController.onClose = { [weak self] closed in
            self?.windowControllers.removeAll { $0 === closed }
        }
        windowControllers.append(windowController)
        if let window = windowController.window {
            cascadePoint = window.cascadeTopLeft(from: windowControllers.count > 1 ? cascadePoint : .zero)
        }
        windowController.showWindow(nil)
        return windowController
    }

    // MARK: - Autosave

    /// Every 30s: documents with a file are saved in place; untitled documents
    /// are stashed for crash recovery and restored on the next launch.
    private func autosaveAll() {
        for windowController in windowControllers {
            let document = windowController.controller.document
            guard document.isDirty else { continue }
            if let url = document.fileURL {
                try? windowController.controller.save(to: url)
            } else {
                document.writeAutosaveStash()
            }
        }
    }

    private func restoreAutosavedDocuments() {
        let directory = DrawingDocument.autosaveDirectory
        guard let files = try? FileManager.default.contentsOfDirectory(at: directory,
                                                                       includingPropertiesForKeys: nil)
        else { return }
        for url in files where url.pathExtension == "polymandala" {
            guard let data = try? Data(contentsOf: url),
                  let document = try? DrawingDocument.fromData(data),
                  !document.ops.isEmpty
            else {
                try? FileManager.default.removeItem(at: url)
                continue
            }
            if let id = UUID(uuidString: url.deletingPathExtension().lastPathComponent) {
                document.autosaveID = id
            }
            document.isDirty = true
            addWindow(for: document)
        }
    }

    // MARK: - Menu

    /// All items get an explicit target: several of our actions would otherwise
    /// collide with standard responder-chain selectors (undo:, openDocument:, …)
    /// that AppKit routes elsewhere — e.g. the window's empty NSUndoManager
    /// claims undo: and leaves the menu item permanently disabled.
    private func menuItem(_ title: String, action: Selector, key: String) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
        item.target = self
        return item
    }

    private func buildMenu() {
        let mainMenu = NSMenu()

        let appItem = NSMenuItem()
        mainMenu.addItem(appItem)
        let appMenu = NSMenu()
        appItem.submenu = appMenu
        appMenu.addItem(menuItem("About Polymandala", action: #selector(showAbout(_:)), key: ""))
        appMenu.addItem(menuItem("License", action: #selector(showLicense(_:)), key: ""))
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Quit Polymandala", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")

        let fileItem = NSMenuItem()
        mainMenu.addItem(fileItem)
        let fileMenu = NSMenu(title: "File")
        fileItem.submenu = fileMenu
        fileMenu.addItem(menuItem("New Canvas…", action: #selector(newCanvas(_:)), key: "n"))
        fileMenu.addItem(menuItem("Open…", action: #selector(openPolymandala(_:)), key: "o"))
        fileMenu.addItem(.separator())
        fileMenu.addItem(menuItem("Save", action: #selector(savePolymandala(_:)), key: "s"))
        fileMenu.addItem(menuItem("Save As…", action: #selector(savePolymandalaAs(_:)), key: "S"))
        fileMenu.addItem(.separator())
        let exportItem = NSMenuItem(title: "Export", action: nil, keyEquivalent: "")
        let exportMenu = NSMenu(title: "Export")
        exportItem.submenu = exportMenu
        exportMenu.addItem(menuItem("PNG…", action: #selector(exportPNG(_:)), key: "e"))
        exportMenu.addItem(menuItem("SVG…", action: #selector(exportSVG(_:)), key: "E"))
        let pdfItem = menuItem("PDF…", action: #selector(exportPDF(_:)), key: "e")
        pdfItem.keyEquivalentModifierMask = [.command, .option]
        exportMenu.addItem(pdfItem)
        fileMenu.addItem(exportItem)
        fileMenu.addItem(menuItem("Print…", action: #selector(printCanvas(_:)), key: "p"))

        let editItem = NSMenuItem()
        mainMenu.addItem(editItem)
        let editMenu = NSMenu(title: "Edit")
        editItem.submenu = editMenu
        editMenu.addItem(menuItem("Undo", action: #selector(performUndo(_:)), key: "z"))
        editMenu.addItem(menuItem("Redo", action: #selector(performRedo(_:)), key: "Z"))
        editMenu.addItem(.separator())
        editMenu.addItem(menuItem("Clear Canvas", action: #selector(clearCanvas(_:)), key: "\u{08}"))

        let viewItem = NSMenuItem()
        mainMenu.addItem(viewItem)
        let viewMenu = NSMenu(title: "View")
        viewItem.submenu = viewMenu
        viewMenu.addItem(menuItem("Show Guides", action: #selector(toggleGuides(_:)), key: "g"))
        viewMenu.addItem(.separator())
        viewMenu.addItem(menuItem("Zoom In", action: #selector(zoomIn(_:)), key: "+"))
        viewMenu.addItem(menuItem("Zoom Out", action: #selector(zoomOut(_:)), key: "-"))
        viewMenu.addItem(menuItem("Zoom to Fit", action: #selector(zoomToFit(_:)), key: "0"))
        viewMenu.addItem(.separator())
        viewMenu.addItem(menuItem("Random Demo", action: #selector(toggleDemo(_:)), key: "d"))

        let windowItem = NSMenuItem()
        mainMenu.addItem(windowItem)
        let windowMenu = NSMenu(title: "Window")
        windowItem.submenu = windowMenu
        windowMenu.addItem(withTitle: "Minimize", action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m")
        NSApp.windowsMenu = windowMenu

        let helpItem = NSMenuItem()
        mainMenu.addItem(helpItem)
        let helpMenu = NSMenu(title: "Help")
        helpItem.submenu = helpMenu
        helpMenu.addItem(menuItem("Polymandala Help", action: #selector(showPolymandalaHelp(_:)), key: "?"))
        NSApp.helpMenu = helpMenu

        NSApp.mainMenu = mainMenu
    }

    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        switch menuItem.action {
        case #selector(newCanvas(_:)), #selector(openPolymandala(_:)),
             #selector(showAbout(_:)), #selector(showLicense(_:)),
             #selector(showPolymandalaHelp(_:)):
            return true
        case #selector(performUndo(_:)):
            return activeController?.canUndo ?? false
        case #selector(performRedo(_:)):
            return activeController?.canRedo ?? false
        case #selector(clearCanvas(_:)):
            return activeController?.canClear ?? false
        case #selector(toggleGuides(_:)):
            menuItem.state = (activeController?.showGuides ?? false) ? .on : .off
            return activeController != nil
        case #selector(toggleDemo(_:)):
            menuItem.state = (activeController?.isDemoRunning ?? false) ? .on : .off
            return activeController != nil
        default:
            return activeWindowController != nil
        }
    }

    // MARK: - Actions

    @objc func showAbout(_ sender: Any?) {
        let centered = NSMutableParagraphStyle()
        centered.alignment = .center
        let credits = NSAttributedString(
            string: "Concept by Hanno Teeling\nInitial implementation by Claude Fable 5\nRefinement by Claude Opus 5.5 and Fable 5.2",
            attributes: [.font: NSFont.systemFont(ofSize: 11),
                         .foregroundColor: NSColor.labelColor,
                         .paragraphStyle: centered])
        NSApp.orderFrontStandardAboutPanel(options: [
            .applicationName: "Polymandala",
            .credits: credits,
            // An empty build number makes the panel show "Version 1.0"
            // instead of "Version 1.0 (1.0)".
            .version: "",
        ])
    }

    @objc func performUndo(_ sender: Any?) { activeController?.undo() }
    @objc func performRedo(_ sender: Any?) { activeController?.redo() }
    @objc func clearCanvas(_ sender: Any?) { activeController?.clearCanvas() }
    @objc func toggleGuides(_ sender: Any?) { activeController?.showGuides.toggle() }
    @objc func toggleDemo(_ sender: Any?) { activeController?.toggleDemo() }

    @objc func zoomIn(_ sender: Any?) { activeWindowController?.canvasView.zoomIn() }
    @objc func zoomOut(_ sender: Any?) { activeWindowController?.canvasView.zoomOut() }
    @objc func zoomToFit(_ sender: Any?) { activeWindowController?.canvasView.zoomToFit() }

    @objc func showLicense(_ sender: Any?) {
        licenseWindowController.showWindow(nil)
        licenseWindowController.window?.makeKeyAndOrderFront(nil)
    }

    @objc func showPolymandalaHelp(_ sender: Any?) {
        helpWindowController.showWindow(nil)
        helpWindowController.window?.makeKeyAndOrderFront(nil)
    }

    @objc func newCanvas(_ sender: Any?) {
        let template = activeController?.document.config
            ?? CanvasConfig(width: 2048, height: 2048, background: .white)

        let alert = NSAlert()
        alert.messageText = "New Canvas"
        alert.informativeText = "Choose the canvas size and background color. The new drawing opens in its own window."
        alert.addButton(withTitle: "Create")
        alert.addButton(withTitle: "Cancel")

        let accessory = NSView(frame: NSRect(x: 0, y: 0, width: 260, height: 92))
        let widthField = NSTextField(frame: NSRect(x: 90, y: 60, width: 70, height: 24))
        widthField.stringValue = "\(template.width)"
        let heightField = NSTextField(frame: NSRect(x: 90, y: 32, width: 70, height: 24))
        heightField.stringValue = "\(template.height)"
        let backgroundWell = NSColorWell(frame: NSRect(x: 90, y: 2, width: 52, height: 24))
        backgroundWell.color = template.background.nsColor
        func label(_ text: String, y: CGFloat) -> NSTextField {
            let l = NSTextField(labelWithString: text)
            l.frame = NSRect(x: 0, y: y, width: 86, height: 20)
            l.alignment = .right
            return l
        }
        accessory.addSubview(label("Width:", y: 62))
        accessory.addSubview(label("Height:", y: 34))
        accessory.addSubview(label("Background:", y: 4))
        accessory.addSubview(widthField)
        accessory.addSubview(heightField)
        accessory.addSubview(backgroundWell)
        alert.accessoryView = accessory
        alert.window.initialFirstResponder = widthField

        guard alert.runModal() == .alertFirstButtonReturn else { return }
        let width = max(64, min(8192, Int(widthField.stringValue) ?? 2048))
        let height = max(64, min(8192, Int(heightField.stringValue) ?? 2048))
        addWindow(for: .makeDefault(width: width, height: height,
                                    background: RGBAColor(backgroundWell.color)))
    }

    @objc func openPolymandala(_ sender: Any?) {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = polymandalaContentTypes()
        panel.allowsMultipleSelection = true
        guard panel.runModal() == .OK else { return }
        openDocuments(at: panel.urls)
    }

    /// Finder: double-clicked .polymandala files and drops on the app/Dock icon.
    /// May arrive before applicationDidFinishLaunching, whose isEmpty check
    /// then skips the default untitled window.
    func application(_ application: NSApplication, open urls: [URL]) {
        openDocuments(at: urls)
    }

    /// Shared by the open panel, Finder opens, and window drag & drop.
    /// A document that is already open is brought to the front instead.
    func openDocuments(at urls: [URL]) {
        for url in urls {
            let path = url.standardizedFileURL.path
            if let existing = windowControllers.first(where: {
                $0.controller.document.fileURL?.standardizedFileURL.path == path
            }) {
                existing.window?.makeKeyAndOrderFront(nil)
                continue
            }
            do {
                let data = try Data(contentsOf: url)
                let document = try DrawingDocument.fromData(data)
                document.fileURL = url
                addWindow(for: document)
            } catch {
                presentError("Could not open \(url.lastPathComponent): \(error.localizedDescription)")
            }
        }
    }

    @objc func savePolymandala(_ sender: Any?) { activeWindowController?.saveDocument() }
    @objc func savePolymandalaAs(_ sender: Any?) { activeWindowController?.saveDocumentAs() }
    @objc func exportPNG(_ sender: Any?) { activeWindowController?.exportPNG() }
    @objc func exportSVG(_ sender: Any?) { activeWindowController?.exportSVG() }
    @objc func exportPDF(_ sender: Any?) { activeWindowController?.exportPDF() }
    @objc func printCanvas(_ sender: Any?) { activeWindowController?.printCanvas() }

    private func presentError(_ message: String) {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "Polymandala"
        alert.informativeText = message
        alert.runModal()
    }
}

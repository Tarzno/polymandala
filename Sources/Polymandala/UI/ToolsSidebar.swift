import AppKit

/// The tools palette: tool buttons, per-tool color and width, symmetry controls
/// for the active center, the centers list, guides toggle, and background color.
final class ToolsSidebar: NSView {
    weak var controller: DrawingController? {
        didSet { refresh() }
    }

    private var toolButtons: [ToolKind: NSButton] = [:]
    private let colorWell = NSColorWell()
    private let widthSlider = NSSlider(value: 8, minValue: 1, maxValue: 64, target: nil, action: nil)
    private let widthValueLabel = NSTextField(labelWithString: "8 px")
    private let toleranceSlider = NSSlider(value: 8, minValue: 0, maxValue: 50, target: nil, action: nil)
    private let toleranceValueLabel = NSTextField(labelWithString: "8 %")
    private let foldStepper = NSStepper()
    private let foldField = NSTextField(string: "8")
    private let mirrorCheck = NSButton(checkboxWithTitle: "Mirror (kaleidoscope)", target: nil, action: nil)
    private let centersStack = NSStackView()
    private let linkedCheck = NSButton(checkboxWithTitle: "Linked: stamp ◆ pattern at all", target: nil, action: nil)
    private let removeCenterButton = NSButton(title: "Remove Center", target: nil, action: nil)
    private let guidesCheck = NSButton(checkboxWithTitle: "Show guides", target: nil, action: nil)
    private let backgroundWell = NSColorWell()
    private let demoButton = NSButton(title: "Random Demo", target: nil, action: nil)
    private var refreshing = false

    private let toolOrder: [ToolKind] = [.brush, .line, .ellipse, .triangle,
                                         .rectangle, .eraser, .fill, .center]

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        buildUI()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not used")
    }

    private func sectionLabel(_ text: String) -> NSTextField {
        let label = NSTextField(labelWithString: text)
        label.font = .boldSystemFont(ofSize: 12)
        label.textColor = .secondaryLabelColor
        return label
    }

    private func buildUI() {
        translatesAutoresizingMaskIntoConstraints = false

        // Tool button grid (2 columns x 3 rows)
        var gridRows: [[NSView]] = []
        for pair in stride(from: 0, to: toolOrder.count, by: 2) {
            var row: [NSView] = []
            for tool in toolOrder[pair..<min(pair + 2, toolOrder.count)] {
                let button = NSButton(title: tool.displayName, target: self, action: #selector(toolClicked(_:)))
                button.setButtonType(.pushOnPushOff)
                button.bezelStyle = .rounded
                button.identifier = NSUserInterfaceItemIdentifier(tool.rawValue)
                button.translatesAutoresizingMaskIntoConstraints = false
                button.widthAnchor.constraint(greaterThanOrEqualToConstant: 92).isActive = true
                toolButtons[tool] = button
                row.append(button)
            }
            gridRows.append(row)
        }
        let toolGrid = NSGridView(views: gridRows)
        toolGrid.rowSpacing = 6
        toolGrid.columnSpacing = 6

        colorWell.target = self
        colorWell.action = #selector(colorChanged(_:))
        colorWell.translatesAutoresizingMaskIntoConstraints = false
        colorWell.widthAnchor.constraint(equalToConstant: 44).isActive = true
        colorWell.heightAnchor.constraint(equalToConstant: 24).isActive = true
        let colorRow = NSStackView(views: [NSTextField(labelWithString: "Color"), colorWell])
        colorRow.orientation = .horizontal

        widthSlider.target = self
        widthSlider.action = #selector(widthChanged(_:))
        widthSlider.translatesAutoresizingMaskIntoConstraints = false
        widthSlider.widthAnchor.constraint(equalToConstant: 130).isActive = true
        let widthRow = NSStackView(views: [NSTextField(labelWithString: "Width"), widthSlider, widthValueLabel])
        widthRow.orientation = .horizontal

        toleranceSlider.target = self
        toleranceSlider.action = #selector(toleranceChanged(_:))
        toleranceSlider.translatesAutoresizingMaskIntoConstraints = false
        toleranceSlider.widthAnchor.constraint(equalToConstant: 115).isActive = true
        toleranceSlider.toolTip = "Fill tolerance: how much color variation the fill may cross"
        let toleranceRow = NSStackView(views: [NSTextField(labelWithString: "Tolerance"),
                                               toleranceSlider, toleranceValueLabel])
        toleranceRow.orientation = .horizontal

        // Symmetry controls
        foldField.alignment = .center
        foldField.translatesAutoresizingMaskIntoConstraints = false
        foldField.widthAnchor.constraint(equalToConstant: 40).isActive = true
        foldField.target = self
        foldField.action = #selector(foldFieldChanged(_:))
        foldStepper.minValue = 1
        foldStepper.maxValue = 36
        foldStepper.increment = 1
        foldStepper.valueWraps = false
        foldStepper.target = self
        foldStepper.action = #selector(foldStepperChanged(_:))
        let foldRow = NSStackView(views: [NSTextField(labelWithString: "Folds"), foldField, foldStepper])
        foldRow.orientation = .horizontal

        mirrorCheck.target = self
        mirrorCheck.action = #selector(mirrorChanged(_:))

        // Centers
        centersStack.orientation = .vertical
        centersStack.alignment = .leading
        centersStack.spacing = 4
        linkedCheck.target = self
        linkedCheck.action = #selector(linkedChanged(_:))
        linkedCheck.font = .systemFont(ofSize: 11)
        removeCenterButton.target = self
        removeCenterButton.action = #selector(removeCenterClicked(_:))
        removeCenterButton.bezelStyle = .rounded
        let centerHint = NSTextField(wrappingLabelWithString: "Center tool: click the canvas to add a center, drag a marker to move it. Shift-click markers or the checkboxes to activate several centers and draw at all of them at once. Linked mode repeats the primary (◆) center's exact pattern at every active center — great for repetitive, overlapping mandalas.")
        centerHint.font = .systemFont(ofSize: 10)
        centerHint.textColor = .tertiaryLabelColor
        centerHint.translatesAutoresizingMaskIntoConstraints = false
        centerHint.widthAnchor.constraint(lessThanOrEqualToConstant: 200).isActive = true

        guidesCheck.target = self
        guidesCheck.action = #selector(guidesChanged(_:))

        backgroundWell.target = self
        backgroundWell.action = #selector(backgroundChanged(_:))
        backgroundWell.translatesAutoresizingMaskIntoConstraints = false
        backgroundWell.widthAnchor.constraint(equalToConstant: 44).isActive = true
        backgroundWell.heightAnchor.constraint(equalToConstant: 24).isActive = true
        let backgroundRow = NSStackView(views: [NSTextField(labelWithString: "Background"), backgroundWell])
        backgroundRow.orientation = .horizontal

        demoButton.target = self
        demoButton.action = #selector(demoClicked(_:))
        demoButton.bezelStyle = .rounded
        demoButton.toolTip = "Watch random mandalas being built, stage by stage. Click again to stop."

        let stack = NSStackView(views: [
            sectionLabel("TOOLS"),
            toolGrid,
            colorRow,
            widthRow,
            toleranceRow,
            separator(),
            sectionLabel("SYMMETRY (ACTIVE CENTERS)"),
            foldRow,
            mirrorCheck,
            separator(),
            sectionLabel("CENTERS (CHECKED = ACTIVE)"),
            centersStack,
            linkedCheck,
            removeCenterButton,
            centerHint,
            separator(),
            sectionLabel("CANVAS"),
            guidesCheck,
            backgroundRow,
            demoButton,
        ])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 10
        stack.edgeInsets = NSEdgeInsets(top: 14, left: 14, bottom: 14, right: 14)
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: topAnchor),
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor),
        ])
    }

    private func separator() -> NSBox {
        let box = NSBox()
        box.boxType = .separator
        box.translatesAutoresizingMaskIntoConstraints = false
        box.widthAnchor.constraint(equalToConstant: 200).isActive = true
        return box
    }

    // MARK: - Refresh from controller state

    func refresh() {
        guard let c = controller else { return }
        refreshing = true
        defer { refreshing = false }

        for (tool, button) in toolButtons {
            button.state = tool == c.activeTool ? .on : .off
        }

        let tool = c.activeTool
        let settings = c.settings[tool]
        colorWell.isEnabled = tool.usesColor
        if let settings, tool.usesColor {
            colorWell.color = settings.color.nsColor
        }
        widthSlider.isEnabled = tool.usesWidth
        if let settings, tool.usesWidth {
            widthSlider.doubleValue = settings.width
            widthValueLabel.stringValue = "\(Int(settings.width)) px"
        } else {
            widthValueLabel.stringValue = "—"
        }
        toleranceSlider.isEnabled = tool == .fill
        toleranceSlider.doubleValue = c.fillTolerance * 100
        toleranceValueLabel.stringValue = "\(Int((c.fillTolerance * 100).rounded())) %"

        let center = c.primaryCenter
        foldField.stringValue = "\(center.foldCount)"
        foldStepper.integerValue = center.foldCount
        mirrorCheck.state = center.mirror ? .on : .off

        for view in centersStack.arrangedSubviews {
            centersStack.removeArrangedSubview(view)
            view.removeFromSuperview()
        }
        for (index, item) in c.document.centers.enumerated() {
            let mirrorMark = item.mirror ? ", mirror" : ""
            let primaryMark = c.isPrimary(index) && c.document.centers.count > 1 ? " ◆" : ""
            let row = NSButton(checkboxWithTitle: "Center \(index + 1) (\(item.foldCount)×\(mirrorMark))\(primaryMark)",
                               target: self, action: #selector(centerToggled(_:)))
            row.state = c.isActive(index) ? .on : .off
            row.tag = index
            row.font = .systemFont(ofSize: 11)
            centersStack.addArrangedSubview(row)
        }
        removeCenterButton.isEnabled = c.document.centers.count > 1
        linkedCheck.state = c.linkedCenters ? .on : .off

        guidesCheck.state = c.showGuides ? .on : .off
        backgroundWell.color = c.document.config.background.nsColor
        demoButton.title = c.isDemoRunning ? "Stop Demo" : "Random Demo"
    }

    // MARK: - Actions

    @objc private func toolClicked(_ sender: NSButton) {
        guard !refreshing, let c = controller,
              let id = sender.identifier?.rawValue, let tool = ToolKind(rawValue: id) else { return }
        c.activeTool = tool
    }

    @objc private func colorChanged(_ sender: NSColorWell) {
        guard !refreshing, let c = controller, c.activeTool.usesColor else { return }
        c.settings[c.activeTool]?.color = RGBAColor(sender.color)
    }

    @objc private func widthChanged(_ sender: NSSlider) {
        guard !refreshing, let c = controller, c.activeTool.usesWidth else { return }
        c.settings[c.activeTool]?.width = sender.doubleValue.rounded()
        widthValueLabel.stringValue = "\(Int(sender.doubleValue.rounded())) px"
    }

    @objc private func demoClicked(_ sender: NSButton) {
        guard !refreshing, let c = controller else { return }
        c.toggleDemo()
    }

    @objc private func toleranceChanged(_ sender: NSSlider) {
        guard !refreshing, let c = controller else { return }
        c.fillTolerance = sender.doubleValue / 100
        toleranceValueLabel.stringValue = "\(Int(sender.doubleValue.rounded())) %"
    }

    @objc private func foldFieldChanged(_ sender: NSTextField) {
        guard !refreshing, let c = controller else { return }
        c.updateActiveCenters(foldCount: Int(sender.stringValue) ?? c.primaryCenter.foldCount)
    }

    @objc private func foldStepperChanged(_ sender: NSStepper) {
        guard !refreshing, let c = controller else { return }
        c.updateActiveCenters(foldCount: sender.integerValue)
    }

    @objc private func mirrorChanged(_ sender: NSButton) {
        guard !refreshing, let c = controller else { return }
        c.updateActiveCenters(mirror: sender.state == .on)
    }

    @objc private func centerToggled(_ sender: NSButton) {
        guard !refreshing, let c = controller else { return }
        c.toggleCenterActive(sender.tag) // refresh() re-syncs if the toggle was rejected
    }

    @objc private func removeCenterClicked(_ sender: NSButton) {
        guard !refreshing else { return }
        controller?.removePrimaryCenter()
    }

    @objc private func linkedChanged(_ sender: NSButton) {
        guard !refreshing else { return }
        controller?.linkedCenters = sender.state == .on
    }

    @objc private func guidesChanged(_ sender: NSButton) {
        guard !refreshing else { return }
        controller?.showGuides = sender.state == .on
    }

    @objc private func backgroundChanged(_ sender: NSColorWell) {
        guard !refreshing else { return }
        controller?.setBackground(RGBAColor(sender.color))
    }
}

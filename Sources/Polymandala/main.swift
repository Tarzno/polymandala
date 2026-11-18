import AppKit

let arguments = CommandLine.arguments
if let flagIndex = arguments.firstIndex(of: "--snapshot"), flagIndex + 1 < arguments.count {
    exit(runSnapshot(path: arguments[flagIndex + 1]))
}
if let flagIndex = arguments.firstIndex(of: "--export-svg"), flagIndex + 2 < arguments.count {
    exit(runExportVector(format: "svg", documentPath: arguments[flagIndex + 1], outputPath: arguments[flagIndex + 2]))
}
if let flagIndex = arguments.firstIndex(of: "--export-pdf"), flagIndex + 2 < arguments.count {
    exit(runExportVector(format: "pdf", documentPath: arguments[flagIndex + 1], outputPath: arguments[flagIndex + 2]))
}
if let flagIndex = arguments.firstIndex(of: "--export-png"), flagIndex + 2 < arguments.count {
    exit(runExportPNG(documentPath: arguments[flagIndex + 1], pngPath: arguments[flagIndex + 2]))
}
if arguments.contains("--license") {
    print(License.text)
    exit(0)
}
if arguments.contains("--selftest") {
    exit(runSelfTest())
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.run()

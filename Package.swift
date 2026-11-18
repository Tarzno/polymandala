// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "Polymandala",
    platforms: [.macOS(.v13)],
    targets: [
        .executableTarget(
            name: "Polymandala",
            path: "Sources/Polymandala"
        )
    ]
)

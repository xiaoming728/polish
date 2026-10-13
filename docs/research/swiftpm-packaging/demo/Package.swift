// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "Demo",
    platforms: [.macOS(.v14)],
    dependencies: [.package(path: "../KeyboardShortcuts")],
    targets: [.executableTarget(name: "Demo", dependencies: ["KeyboardShortcuts"], path: "Sources/Demo")]
)

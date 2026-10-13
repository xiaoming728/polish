// swift-tools-version:6.0
import PackageDescription

let v5: [SwiftSetting] = [.swiftLanguageMode(.v5)]

let package = Package(
    name: "Polish",
    platforms: [.macOS(.v14)],
    targets: [
        // 纯逻辑：协议解析、请求构造、握手帧、预设
        .target(name: "PolishCore", swiftSettings: v5),
        // 菜单栏 app；argv[0] 为 polish-edit 时作为终端编辑器入口
        .executableTarget(name: "Polish", dependencies: ["PolishCore"], swiftSettings: v5),
        // 只有 CLT 时 XCTest / swift-testing 不可用，用断言自检代替：swift run core-checks
        .executableTarget(name: "core-checks", dependencies: ["PolishCore"], path: "Checks", swiftSettings: v5),
    ]
)

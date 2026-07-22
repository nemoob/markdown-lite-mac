// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "MarkdownLiteMac",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "MarkdownLiteMac", targets: ["MarkdownLiteMac"])
    ],
    targets: [
        .executableTarget(name: "MarkdownLiteMac"),
        // 标准测试目标让本地与 GitHub Actions 使用相同发现和报告路径。
        .testTarget(
            name: "MarkdownLiteMacTests",
            dependencies: ["MarkdownLiteMac"]
        ),
    ],
    swiftLanguageModes: [.v5]
)

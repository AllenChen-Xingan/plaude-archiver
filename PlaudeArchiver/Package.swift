// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "PlaudeArchiver",
    platforms: [.macOS(.v13)],
    targets: [
        .executableTarget(
            name: "PlaudeArchiver",
            path: "Sources/PlaudeArchiver",
            swiftSettings: [.swiftLanguageMode(.v5)]
        )
    ]
)

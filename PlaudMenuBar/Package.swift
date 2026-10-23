// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "PlaudMenuBar",
    platforms: [.macOS(.v13)],
    targets: [
        .executableTarget(
            name: "PlaudMenuBar",
            path: "Sources/PlaudMenuBar",
            swiftSettings: [.swiftLanguageMode(.v5)]
        )
    ]
)

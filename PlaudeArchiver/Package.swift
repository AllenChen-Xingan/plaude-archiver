// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "PlaudeArchiver",
    platforms: [.macOS(.v13)],
    targets: [
        .executableTarget(
            name: "PlaudeArchiver",
            path: "Sources/PlaudeArchiver",
            sources: ["Entry.swift", "AppDelegate.swift", "LibraryView.swift", "BluetoothLogin.swift", "LoginWindow.swift", "Store.swift"],
            swiftSettings: [.swiftLanguageMode(.v5)]
        )
    ]
)

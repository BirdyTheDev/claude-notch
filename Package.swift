// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Notchpad",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(
            name: "Notchpad",
            path: "Sources/Notchpad",
            swiftSettings: [.swiftLanguageMode(.v5)]
        )
    ]
)

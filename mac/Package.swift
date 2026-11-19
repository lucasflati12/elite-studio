// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "EliteStudio",
    platforms: [.macOS("26.0")],
    targets: [
        .executableTarget(
            name: "EliteStudio",
            path: "Sources/EliteStudio",
            swiftSettings: [.swiftLanguageMode(.v5)]
        )
    ]
)

// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "DesktopSwitcher",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(
            name: "DesktopSwitcher",
            path: "Sources/DesktopSwitcher"
        )
    ]
)

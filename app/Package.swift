// swift-tools-version: 5.10
import PackageDescription

let package = Package(
    name: "Maclator",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(name: "Maclator", path: "Sources/Maclator"),
    ]
)

// swift-tools-version:5.10
import PackageDescription

let package = Package(
    name: "Magpie",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(name: "Magpie", path: "Sources/Magpie")
    ]
)

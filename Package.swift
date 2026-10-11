// swift-tools-version:5.10
import PackageDescription

let package = Package(
    name: "OpenView",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(name: "OpenView", path: "Sources/OpenView")
    ]
)

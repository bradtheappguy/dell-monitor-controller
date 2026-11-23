// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "dellmon",
    platforms: [.macOS(.v12)],
    targets: [
        .executableTarget(name: "dellmon", path: "Sources/dellmon")
    ]
)

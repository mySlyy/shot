// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "SlyyShot",
    platforms: [.macOS(.v13)],
    targets: [
        .executableTarget(name: "SlyyShot", path: "Sources/SlyyShot"),
    ]
)

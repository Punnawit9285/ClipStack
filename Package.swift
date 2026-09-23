// swift-tools-version:5.10
import PackageDescription

let package = Package(
    name: "clipstack",
    platforms: [.macOS(.v13)],
    targets: [
        .executableTarget(name: "clipstack", path: "Sources/ClipStack")
    ],
    swiftLanguageVersions: [.v5]
)

// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Damon",
    platforms: [.macOS(.v15)],
    products: [.executable(name: "Damon", targets: ["Damon"])],
    targets: [
        .target(name: "DamonPolicy"),
        .target(name: "DamonPlatform", dependencies: ["DamonPolicy"]),
        .executableTarget(name: "Damon", dependencies: ["DamonPolicy", "DamonPlatform"]),
        .testTarget(name: "DamonTests", dependencies: ["DamonPolicy", "DamonPlatform"])
    ]
)

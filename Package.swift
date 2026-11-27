// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Damon",
    platforms: [.macOS(.v15)],
    products: [
        .executable(name: "RateCue", targets: ["Damon"]),
        .executable(name: "RateCueMCP", targets: ["RateCueMCP"])
    ],
    targets: [
        .target(name: "DamonPolicy"),
        .target(name: "DamonPlatform", dependencies: ["DamonPolicy"]),
        .executableTarget(name: "Damon", dependencies: ["DamonPolicy", "DamonPlatform"]),
        .target(name: "RateCueMCPCore", dependencies: ["DamonPlatform"]),
        .executableTarget(name: "RateCueMCP", dependencies: ["RateCueMCPCore"]),
        .testTarget(name: "DamonTests", dependencies: ["DamonPolicy", "DamonPlatform", "RateCueMCPCore"])
    ]
)

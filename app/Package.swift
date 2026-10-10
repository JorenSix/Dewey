// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "ConnectomeFly",
    platforms: [.macOS(.v14)],
    products: [.executable(name: "FlyApp", targets: ["FlyApp"])],
    targets: [
        .target(name: "FlyCore"),
        .target(name: "FlyBrain", dependencies: ["FlyCore"]),
        .target(name: "FlyBehavior", dependencies: ["FlyCore"]),
        .target(name: "FlyBody", dependencies: ["FlyCore"]),
        .executableTarget(
            name: "FlyApp",
            dependencies: ["FlyCore", "FlyBrain", "FlyBehavior", "FlyBody"],
            resources: [.copy("Resources")]
        ),
        .testTarget(name: "FlyBrainTests", dependencies: ["FlyBrain"]),
        .testTarget(name: "FlyBehaviorTests", dependencies: ["FlyBehavior"]),
        .testTarget(name: "FlyBodyTests", dependencies: ["FlyBody"]),
        .testTarget(name: "IntegrationTests", dependencies: ["FlyBrain", "FlyBehavior"]),
    ],
    swiftLanguageModes: [.v5]
)

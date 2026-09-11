// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "nebelkern-metal",
    platforms: [
        .macOS(.v13)
    ],
    products: [
        .executable(name: "nebelkern-metal", targets: ["nebelkern-metal"])
    ],
    dependencies: [],
    targets: [
        .executableTarget(
            name: "nebelkern-metal",
            dependencies: [],
            resources: [
                .copy("Shaders.metal")
            ]
        )
    ]
)

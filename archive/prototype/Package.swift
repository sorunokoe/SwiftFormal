// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "FormalSpecPrototype",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "FormalSpec", targets: ["FormalSpec"]),
        .executable(name: "formal-demo", targets: ["Demo"]),
    ],
    targets: [
        .target(name: "FormalSpec"),
        .executableTarget(name: "Demo", dependencies: ["FormalSpec"]),
        .testTarget(name: "FormalSpecTests", dependencies: ["FormalSpec"]),
    ]
)

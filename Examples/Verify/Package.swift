// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "VerifyExample",
    platforms: [.macOS(.v13)],
    dependencies: [.package(name: "SwiftFormal", path: "../..")],
    targets: [
        .target(
            name: "Shop",
            dependencies: [.product(name: "SwiftFormal", package: "SwiftFormal")]
        ),
        .testTarget(name: "ShopTests", dependencies: ["Shop"]),
    ]
)

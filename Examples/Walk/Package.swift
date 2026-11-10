// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "WalkExample",
    platforms: [.macOS(.v13)],
    dependencies: [.package(name: "SwiftFormal", path: "../..")],
    targets: [
        .target(name: "Shipping"),
        .testTarget(
            name: "ShippingTests",
            dependencies: [
                "Shipping",
                .product(name: "SwiftFormal", package: "SwiftFormal"),
                .product(name: "SwiftFormalTesting", package: "SwiftFormal"),
            ]
        ),
    ]
)

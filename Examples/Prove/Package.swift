// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "ProveExample",
    platforms: [.macOS(.v13)],
    dependencies: [.package(name: "SwiftFormal", path: "../..")],
    targets: [
        // A test target with the one test product: SwiftFormalTesting brings the symbolic integer proofs too.
        .testTarget(
            name: "DiscountProofTests",
            dependencies: [.product(name: "SwiftFormalTesting", package: "SwiftFormal")]
        )
    ]
)

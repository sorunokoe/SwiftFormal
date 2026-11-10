// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "LeanProof",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "LeanProof", targets: ["LeanProof"]),
        .executable(name: "proof-emitter", targets: ["ProofEmitter"]),
    ],
    dependencies: [.package(path: "../scalar-extraction")],
    targets: [
        .target(
            name: "LeanProof",
            dependencies: [.product(name: "ScalarExtraction", package: "scalar-extraction")]
        ),
        .executableTarget(
            name: "ProofEmitter",
            dependencies: [
                "LeanProof", .product(name: "ScalarExtraction", package: "scalar-extraction"),
            ]
        ),
        .testTarget(
            name: "LeanProofTests",
            dependencies: [
                "LeanProof", .product(name: "ScalarExtraction", package: "scalar-extraction"),
            ]
        ),
    ]
)

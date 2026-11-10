// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "TranslationValidation",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "TranslationValidation", targets: ["TranslationValidation"]),
        .executable(name: "translation-emitter", targets: ["TranslationEmitter"]),
    ],
    dependencies: [
        .package(path: "../lean-proof"),
        .package(path: "../scalar-extraction"),
    ],
    targets: [
        .target(
            name: "TranslationValidation",
            dependencies: [
                .product(name: "LeanProof", package: "lean-proof"),
                .product(name: "ScalarExtraction", package: "scalar-extraction"),
            ],
            resources: [.copy("Resources/ReferenceIR.lean")]
        ),
        .executableTarget(
            name: "TranslationEmitter",
            dependencies: [
                "TranslationValidation",
                .product(name: "LeanProof", package: "lean-proof"),
                .product(name: "ScalarExtraction", package: "scalar-extraction"),
            ]
        ),
        .testTarget(
            name: "TranslationValidationTests",
            dependencies: [
                "TranslationValidation",
                .product(name: "LeanProof", package: "lean-proof"),
                .product(name: "ScalarExtraction", package: "scalar-extraction"),
            ]
        ),
    ]
)

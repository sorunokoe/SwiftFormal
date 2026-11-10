// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "ScalarExtraction",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "ScalarExtraction", targets: ["ScalarExtraction"]),
        .executable(name: "scalar-probe", targets: ["ScalarProbe"]),
    ],
    targets: [
        .target(name: "ScalarExtraction"),
        .executableTarget(name: "ScalarProbe", dependencies: ["ScalarExtraction"]),
        .testTarget(name: "ScalarExtractionTests", dependencies: ["ScalarExtraction"]),
    ]
)

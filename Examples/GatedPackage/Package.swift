// swift-tools-version: 6.0
import PackageDescription

// The build gate on a real package: `swiftformal check --gate --package . --target Kernels` (Scripts/check-examples.sh)
// proves every `@Verify` function of Kernels, also from a build log (`--build-log`).
let package = Package(
    name: "GatedPackage",
    platforms: [.macOS(.v13)],
    products: [.library(name: "Kernels", targets: ["Kernels"])],
    dependencies: [.package(name: "SwiftFormal", path: "../..")],
    targets: [
        .target(
            name: "Kernels",
            dependencies: [.product(name: "SwiftFormal", package: "SwiftFormal")]
        )
    ]
)

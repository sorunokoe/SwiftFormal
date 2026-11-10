// swift-tools-version: 6.0
// Wall-time benchmarks, reported and never compared (docs/PERFORMANCE.md). A package of its own, so nobody who depends
// on SwiftFormal fetches or builds it. Run: swift run -c release --package-path Benchmarks
import PackageDescription

let package = Package(
    name: "SwiftFormalBenchmarks",
    platforms: [.macOS(.v13)],
    dependencies: [.package(name: "SwiftFormal", path: "..")],
    targets: [
        .executableTarget(
            name: "benchmarks",
            dependencies: [
                .product(name: "SwiftFormal", package: "SwiftFormal"),
                // SFProve comes with SwiftFormalTesting (no product of its own), which links Testing.framework: run with
                // `-Xlinker -rpath` to it (see main.swift).
                .product(name: "SwiftFormalTesting", package: "SwiftFormal"),
            ]
        )
    ]
)

// swift-tools-version: 6.1
import CompilerPluginSupport
import Foundation
import PackageDescription

// Stricter compiler checks, adopted one module at a time (Task Q.3). Language mode stays Swift 6.
let strictSettings: [SwiftSetting] = [
    .enableUpcomingFeature("ExistentialAny"),
    .enableUpcomingFeature("InternalImportsByDefault"),
    .enableUpcomingFeature("MemberImportVisibility"),
]

let package = Package(
    name: "SwiftFormal",
    platforms: [.macOS(.v13), .iOS(.v16)],
    // Three products, one way to use SwiftFormal: `import SwiftFormal` in app code, `import SwiftFormalTesting` in tests,
    // and the `swiftformal` command. Every other target is internal: SwiftPM builds it for these, and a checkout can still
    // build `sfverify` and `sfgen` (`swift build --product sfverify`) for the maintainers' scripts, but no package that
    // depends on SwiftFormal can name them.
    products: [
        // App code: domains, properties, runtime contracts, and `@Verify`, `#requires`, `#ensures`. The macros are a
        // compiler plugin built with swift-syntax; nothing of it is linked into an app.
        .library(name: "SwiftFormal", targets: ["SwiftFormal"]),
        // Tests: `Prove(it: ..., over: ...) { ... }`, the one way to walk; it re-exports the symbolic integer proofs
        // (`proveSigned`, `SymbolicInt`) of SFProve.
        .library(name: "SwiftFormalTesting", targets: ["SwiftFormalTesting"]),
        // `swiftformal check` (logic first, then only the walks logic could not replace; `--gate` is the build check),
        // `swiftformal doctor` and `swiftformal lsp`.
        .executable(name: "swiftformal", targets: ["SwiftFormalCLI"]),
    ],
    // `Generator` (on by default) builds swift-syntax for `sfgen`. Contributors' lanes that do not need sfgen pass
    // `--disable-default-traits`: a cold debug build then skips swift-syntax (92.8 s to 31.0 s of CPU, measured).
    traits: [
        .trait(name: "Generator", description: "Build sfgen's source reader with swift-syntax"),
        .default(enabledTraits: ["Generator"]),
    ],
    dependencies: [
        .package(url: "https://github.com/swiftlang/swift-syntax.git", "600.0.0"..<"700.0.0")
    ],
    targets: [
        .target(name: "SwiftFormal", dependencies: ["SwiftFormalMacros"], swiftSettings: strictSettings),
        .testTarget(name: "SwiftFormalTests", dependencies: ["SwiftFormal"]),

        .target(name: "SwiftFormalTesting", dependencies: ["SwiftFormal", "SFProve"], swiftSettings: strictSettings),
        .testTarget(name: "SwiftFormalTestingTests", dependencies: ["SwiftFormalTesting", "SFTestSupport"]),

        .macro(
            name: "SwiftFormalMacros",
            dependencies: [
                .product(name: "SwiftSyntax", package: "swift-syntax"),
                .product(name: "SwiftSyntaxBuilder", package: "swift-syntax"),
                .product(name: "SwiftSyntaxMacros", package: "swift-syntax"),
                .product(name: "SwiftCompilerPlugin", package: "swift-syntax"),
                .product(name: "SwiftDiagnostics", package: "swift-syntax"),
            ]
        ),
        // A compile test shaped like an app file: SwiftUI and friends next to `import SwiftFormal`, with the strict settings.
        .testTarget(name: "SwiftFormalAppImportTests", dependencies: ["SwiftFormal"], swiftSettings: strictSettings),
        .testTarget(
            name: "SwiftFormalMacrosTests",
            dependencies: [
                "SwiftFormalMacros",
                .product(name: "SwiftSyntaxMacrosGenericTestSupport", package: "swift-syntax"),
            ]
        ),

        .target(name: "SFCNF", swiftSettings: strictSettings),
        .target(name: "SFSAT", dependencies: ["SFCNF"], swiftSettings: strictSettings),
        .target(name: "SFCheck", dependencies: ["SFCNF"], swiftSettings: strictSettings),
        .target(name: "SFBV", dependencies: ["SFCNF"], swiftSettings: strictSettings),
        .target(name: "SFProve", dependencies: ["SFCNF", "SFSAT", "SFCheck", "SFBV"], swiftSettings: strictSettings),
        .target(name: "SFSemantics", dependencies: ["SFCNF", "SFBV"], swiftSettings: strictSettings),
        .target(name: "SFSIL", dependencies: ["SFCNF", "SFBV", "SFSemantics", "SFProve"], swiftSettings: strictSettings),
        .target(name: "SFLLVM", dependencies: ["SFCNF", "SFBV", "SFProve", "SFSIL"], swiftSettings: strictSettings),
        .target(
            name: "SFVerifyKit", dependencies: ["SFCNF", "SFBV", "SFProve", "SFSemantics", "SFSIL", "SFLLVM"], swiftSettings: strictSettings
        ),
        .executableTarget(name: "sfverify", dependencies: ["SFVerifyKit"], swiftSettings: strictSettings),
        .executableTarget(name: "SwiftFormalCLI", dependencies: ["SFVerifyKit"], swiftSettings: strictSettings),
        .target(
            name: "SFGenKit",
            dependencies: [
                .product(name: "SwiftSyntax", package: "swift-syntax", condition: .when(traits: ["Generator"])),
                .product(name: "SwiftParser", package: "swift-syntax", condition: .when(traits: ["Generator"])),
            ],
            swiftSettings: strictSettings
        ),
        .executableTarget(name: "sfgen", dependencies: ["SFGenKit"], swiftSettings: strictSettings),
        .testTarget(name: "SFGenKitTests", dependencies: ["SFGenKit", "SFTestSupport"]),
        // Test tags (`.slow`, `.oracle`) shared by the test targets below. See docs/decisions/0004-test-lanes.md.
        .target(name: "SFTestSupport", path: "Tests/Support"),
        .testTarget(name: "SFSATTests", dependencies: ["SFCNF", "SFSAT", "SFCheck", "SFBV", "SFProve", "SFTestSupport"]),
        .testTarget(name: "SFBVTests", dependencies: ["SFCNF", "SFSAT", "SFBV", "SFProve", "SFSIL", "SFLLVM", "SFTestSupport"]),
        .testTarget(name: "SFProveTests", dependencies: ["SFCNF", "SFSAT", "SFBV", "SFProve", "SwiftFormal", "SFTestSupport"]),
        .testTarget(name: "SFSemanticsTests", dependencies: ["SFCNF", "SFSAT", "SFBV", "SFSemantics", "SFTestSupport"]),
        .testTarget(
            name: "SFSILTests", dependencies: ["SFCNF", "SFBV", "SFProve", "SFSIL", "SFTestSupport"], exclude: ["Baselines"]),
        // Spawn the compiler and native binaries: the oracle lane.
        .testTarget(
            name: "SFOracleTests",
            dependencies: ["SFCNF", "SFBV", "SFProve", "SFSemantics", "SFSIL", "SFLLVM", "SFVerifyKit", "SFTestSupport"]),
        .testTarget(name: "SFVerifyKitTests", dependencies: ["SFVerifyKit", "SFSIL"], exclude: ["Fixtures"]),
        // The package verifies itself with its own tools (Task Q.1). `CANDIDATES.md` lists what is checked and why.
        .testTarget(
            name: "SelfVerificationTests",
            dependencies: ["SwiftFormal", "SwiftFormalTesting", "SFCNF", "SFSAT", "SFCheck", "SFBV", "SFProve", "SFTestSupport"],
            exclude: ["CANDIDATES.md"]
        ),
        // Deliberately wrong claims that no tool may call proved, the SAT solver against brute force, and parser fuzzing (Task Q.2).
        .testTarget(
            name: "SoundnessZooTests",
            dependencies: [
                "SwiftFormal", "SwiftFormalTesting", "SFCNF", "SFSAT", "SFCheck", "SFBV", "SFProve", "SFSIL", "SFLLVM", "SFTestSupport",
            ],
            // Parser fuzz seeds: compiler output of this repository's examples (Scripts/make-fuzz-seeds.py).
            exclude: ["FuzzSeeds"]
        ),
    ]
)

// Documentation only: `SWIFTFORMAL_DOCS=1 swift package generate-documentation --target SwiftFormal`.
// Without the variable the package has no extra dependency, so nobody else fetches the plugin.
if ProcessInfo.processInfo.environment["SWIFTFORMAL_DOCS"] != nil {
    package.dependencies.append(.package(url: "https://github.com/swiftlang/swift-docc-plugin", from: "1.4.0"))
}

// Contributors only: `Scripts/test-lane.sh slow-dev` optimizes the engine modules in a debug build, so their tests take
// seconds instead of minutes (unoptimized generic code in the bit-blaster and solver is 10 to 300 times slower).
// SwiftPM refuses a dependency with unsafe flags, so they exist only while this variable is set;
// Scripts/check-portability.py fails if the manifest a consumer sees has any.
if ProcessInfo.processInfo.environment["SWIFTFORMAL_DEV_OPTIMIZE"] != nil {
    let engines: Set = ["SFCNF", "SFSAT", "SFCheck", "SFBV", "SFProve", "SFSemantics", "SFSIL", "SFLLVM"]
    for target in package.targets where engines.contains(target.name) {
        target.swiftSettings = (target.swiftSettings ?? []) + [SwiftSetting.unsafeFlags(["-O"], .when(configuration: .debug))]
    }
}

// Scaling curves (docs/PERFORMANCE.md): `SWIFTFORMAL_BENCH=1 swift run -c release -Xswiftc -enable-testing SwiftFormalScaling run …`.
// Developer-only like SWIFTFORMAL_DOCS: with the variable unset nobody fetches swift-collections-benchmark or builds this target.
// The target sits in this package because the engine modules use `package` access (docs/decisions/0003).
// swift-collections-benchmark 0.0.4 declares macOS 15, so the package floor is raised here only, under the variable.
if ProcessInfo.processInfo.environment["SWIFTFORMAL_BENCH"] != nil {
    package.platforms = [.macOS(.v15), .iOS(.v18)]
    package.dependencies.append(.package(url: "https://github.com/apple/swift-collections-benchmark", exact: "0.0.4"))
    package.targets.append(
        .executableTarget(
            name: "SwiftFormalScaling",
            dependencies: [
                "SwiftFormal", "SwiftFormalTesting", "SFCNF", "SFSAT", "SFCheck", "SFBV", "SFProve", "SFSIL", "SFVerifyKit",
                .product(name: "CollectionsBenchmark", package: "swift-collections-benchmark"),
            ],
            path: "Benchmarks/Scaling",
            exclude: ["gen.py", "run-groups.sh", "analyze.py"]
        ))
}

// `swiftformal lsp`, the language server (docs/guides/editor.md), uses Darwin's process and file APIs, so it is built on
// macOS only; elsewhere `swiftformal` has no `lsp` command.
#if os(macOS)
    package.targets.append(contentsOf: [
        .target(name: "SFLanguageServer", dependencies: ["SFVerifyKit"], swiftSettings: strictSettings),
        .testTarget(name: "SFLanguageServerTests", dependencies: ["SFLanguageServer", "SFVerifyKit"]),
    ])
    package.targets.first { $0.name == "SwiftFormalCLI" }?.dependencies.append("SFLanguageServer")
#endif

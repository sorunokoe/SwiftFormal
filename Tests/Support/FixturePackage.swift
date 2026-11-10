import Foundation

// `Process` exists only where a package can be built: macOS and Linux.
#if os(macOS) || os(Linux)

    /// A SwiftPM package that depends on this checkout by path, as an app does, so it sees only the public API: `package`
    /// declarations are not visible to it. A check writes its targets, builds one, and asserts what compiles and what
    /// the compiler says. It lives in `.build/fixtures/<name>` of the checkout, so a second build is incremental.
    package struct FixturePackage {
        /// The root of this checkout (the folder of SwiftFormal's `Package.swift`).
        package static let checkout = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().path

        /// The package's folder.
        package let root: String

        /// What one `swift build` printed, and how it ended.
        package struct Build {
            /// Standard output and standard error together.
            package let output: String
            /// The exit status: zero when every target built.
            package let status: Int32

            /// The errors the compiler reported in `file`, by line.
            package func errors(in file: String) -> [Int: [String]] {
                var found: [Int: [String]] = [:]
                for line in output.split(separator: "\n") where line.contains("/" + file + ":") && line.contains(": error: ") {
                    let parts = line.split(separator: ":", maxSplits: 4, omittingEmptySubsequences: false)
                    guard parts.count == 5, let number = Int(parts[1]) else { continue }
                    found[number, default: []].append(String(parts[4]).trimmingCharacters(in: .whitespaces))
                }
                return found
            }
        }

        /// Writes the package: `targets` is the text inside `targets: [...]` of its manifest, `files` maps a path in the
        /// package to its text. A file is written only when its text changed, so the build stays incremental. The
        /// checkout's `Package.resolved` is copied, so the fixture resolves the same swift-syntax without a network.
        package init(name: String, targets: String, files: [String: String]) throws {
            root = Self.checkout + "/.build/fixtures/" + name
            let manifest = """
                // swift-tools-version: 6.1
                // Written by a SwiftFormal test (Tests/Support/FixturePackage.swift). Do not edit.
                import PackageDescription

                let package = Package(
                    name: "\(name)",
                    platforms: [.macOS(.v14)],
                    dependencies: [.package(name: "SwiftFormal", path: "\(Self.checkout)")],
                    targets: [
                \(targets)
                    ]
                )

                """
            var all = files
            all["Package.swift"] = manifest
            if let resolved = try? String(contentsOfFile: Self.checkout + "/Package.resolved", encoding: .utf8) {
                all["Package.resolved"] = resolved
            }
            for (path, text) in all {
                let url = URL(fileURLWithPath: root + "/" + path)
                if (try? String(contentsOf: url, encoding: .utf8)) == text { continue }
                try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
                try text.write(to: url, atomically: true, encoding: .utf8)
            }
        }

        /// `swift build --target <target>` in the package (with `--build-tests` for a test target).
        package func build(target: String) throws -> Build {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
            process.arguments = ["swift", "build", "--package-path", root, "--target", target]
            var environment = ProcessInfo.processInfo.environment
            // The test process's own SwiftPM settings are not the fixture's.
            for key in environment.keys where key.hasPrefix("SWIFTPM_") || key.hasPrefix("SWIFT_TESTING_") { environment[key] = nil }
            process.environment = environment
            let pipe = Pipe()
            process.standardOutput = pipe
            process.standardError = pipe
            try process.run()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            return Build(output: String(bytes: data, encoding: .utf8) ?? "", status: process.terminationStatus)
        }
    }
#endif

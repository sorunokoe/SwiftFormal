import CryptoKit
import Foundation

public struct CollectedSIL {
    public let text: String
    public let reportSHA256: String
    public let silSHA256: String
    private let fileDigests: [URL: String]

    public static func load(reportURL: URL, fixturesURL: URL) throws -> CollectedSIL {
        do {
            return try loadChecked(reportURL: reportURL, fixturesURL: fixturesURL)
        } catch let error as ExtractionError {
            throw error
        } catch {
            throw ExtractionError.invalidArtifact("Cannot read collection: \(error)")
        }
    }

    public func validateUnchanged() throws {
        for (url, expected) in fileDigests {
            guard let data = try? Data(contentsOf: url), digest(data) == expected else {
                throw ExtractionError.invalidArtifact(
                    "Input changed during interpretation: \(url.lastPathComponent)")
            }
        }
    }

    private static func loadChecked(reportURL: URL, fixturesURL: URL) throws -> CollectedSIL {
        let reportURL = reportURL.standardizedFileURL.resolvingSymlinksInPath()
        let fixturesURL = fixturesURL.standardizedFileURL.resolvingSymlinksInPath()
        let directory = reportURL.deletingLastPathComponent()
        let data = try Data(contentsOf: reportURL)
        let report = try JSONDecoder().decode(CollectionReport.self, from: data)
        let compilerVersion = "Apple Swift version 6.4 (swiftlang-6.4.0.34.1 clang-2100.3.34.1)"
        let triple = "arm64-apple-macosx27.0.0"
        guard report.schemaVersion == 1, report.experimentVersion == "0.0.1",
            report.status == "passed"
        else {
            throw ExtractionError.invalidArtifact("Collection is not a passed 0.0.1 report")
        }
        guard report.compilerVersion == "\(compilerVersion)\nTarget: \(triple)",
            report.targetInfo.compilerVersion == compilerVersion,
            report.targetInfo.swiftCompilerTag == "swiftlang-6.4.0.34.1",
            report.targetInfo.target.triple == triple,
            report.targetInfo.target.arch == "arm64",
            report.targetInfo.target.pointerWidthInBits == 64,
            report.sdkVersion == "27.0",
            report.targetInfo.paths.sdkPath == report.sdkPath
        else {
            throw ExtractionError.invalidArtifact(
                "Unrecognized compiler, SDK, or target configuration")
        }
        guard
            report.collectorSHA256
                == "82f66382a900b346b46a1a40d1dc5624911cf7d55047cbbf391ee492af08f510",
            Set(report.sourceSHA256.keys) == ["Fixture.swift", "main.swift"],
            Set(report.artifacts.keys) == [
                "silgen.sil", "sil-onone.sil", "sil-optimized.sil", "oracle-debug",
                "oracle-release",
            ]
        else {
            throw ExtractionError.invalidArtifact("Unexpected collector or file inventory")
        }

        var fileDigests = [reportURL: digest(data)]
        for (name, expected) in report.sourceSHA256 {
            let url = fixturesURL.appendingPathComponent(name)
            guard digest(try Data(contentsOf: url)) == expected else {
                throw ExtractionError.invalidArtifact("Source digest mismatch: \(name)")
            }
            fileDigests[url] = expected
        }
        var sil: String?
        for (name, expected) in report.artifacts {
            let url = directory.appendingPathComponent(name)
            let contents = try Data(contentsOf: url)
            guard digest(contents) == expected else {
                throw ExtractionError.invalidArtifact("Artifact digest mismatch: \(name)")
            }
            fileDigests[url] = expected
            if name == "sil-onone.sil" { sil = String(data: contents, encoding: .utf8) }
        }
        guard let sil, let silSHA256 = report.artifacts["sil-onone.sil"] else {
            throw ExtractionError.invalidArtifact("Missing or non-UTF8 canonical SIL")
        }
        let prefix = [report.compiler, "-sdk", report.sdkPath]
        let expectedCommands = [
            (
                "sil-onone.sil",
                prefix + [
                    "-parse-as-library", "-module-name", "BridgeFixture", "-g",
                    "-emit-sil", "-Onone", "Fixture.swift", "-o",
                    directory.appendingPathComponent("sil-onone.sil").path,
                ]
            ),
            (
                "oracle-debug",
                prefix + [
                    "-g", "-Onone", "Fixture.swift", "main.swift", "-o",
                    directory.appendingPathComponent("oracle-debug").path,
                ]
            ),
            (
                "oracle-release",
                prefix + [
                    "-g", "-O", "Fixture.swift", "main.swift", "-o",
                    directory.appendingPathComponent("oracle-release").path,
                ]
            ),
        ]
        for (name, arguments) in expectedCommands {
            let commands = report.commands.filter {
                $0.argv.contains("-o")
                    && $0.argv.contains(directory.appendingPathComponent(name).path)
            }
            guard commands.count == 1, let command = commands.first,
                command.argv == arguments, command.cwd == fixturesURL.path, command.returncode == 0
            else {
                throw ExtractionError.invalidArtifact("Unexpected compiler command for \(name)")
            }
        }
        return CollectedSIL(
            text: sil, reportSHA256: digest(data), silSHA256: silSHA256,
            fileDigests: fileDigests
        )
    }
}

private func digest(_ data: Data) -> String {
    SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
}

private struct CollectionReport: Decodable {
    let schemaVersion: Int
    let experimentVersion: String
    let status: String
    let compiler: String
    let compilerVersion: String
    let collectorSHA256: String
    let sdkPath: String
    let sdkVersion: String
    let sourceSHA256: [String: String]
    let artifacts: [String: String]
    let targetInfo: TargetInfo
    let commands: [Command]

    enum CodingKeys: String, CodingKey {
        case status, compiler, artifacts, commands
        case schemaVersion = "schema_version"
        case experimentVersion = "experiment_version"
        case compilerVersion = "compiler_version"
        case collectorSHA256 = "collector_sha256"
        case sdkPath = "sdk_path"
        case sdkVersion = "sdk_version"
        case sourceSHA256 = "source_sha256"
        case targetInfo = "target_info"
    }

    struct TargetInfo: Decodable {
        let compilerVersion: String
        let swiftCompilerTag: String
        let target: Target
        let paths: Paths
        struct Target: Decodable {
            let triple: String
            let arch: String
            let pointerWidthInBits: Int
        }
        struct Paths: Decodable {
            let sdkPath: String
        }
    }

    struct Command: Decodable {
        let argv: [String]
        let cwd: String
        let returncode: Int
    }
}

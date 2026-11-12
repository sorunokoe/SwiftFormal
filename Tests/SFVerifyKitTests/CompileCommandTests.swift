import Foundation
import Testing

@testable import SFVerifyKit

/// `swift build -v` runs tasks in parallel, and another task can print into the middle of the compile command line.
/// On a real app (app study round 5) actool's `/* com.apple.actool.compilation-results */` and a
/// newline landed inside a `-load-plugin-executable` path, so the saved command was cut short, the scan failed with
/// "invalid value … in '-load-plugin-executable'", and every later scan reused the broken saved command.
@Suite struct CompileCommandTests {
    private struct Fixture {
        let dir: String
        let plugin: String
        let list: String
    }

    private static func fixture() throws -> Fixture {
        let dir = NSTemporaryDirectory() + "sfv-cmd-\(UUID().uuidString)"
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        let plugin = dir + "/SwiftNavigationMacros"
        let list = dir + "/M.SwiftFileList"
        FileManager.default.createFile(atPath: plugin, contents: Data())
        FileManager.default.createFile(atPath: list, contents: Data((dir + "/a.swift\n").utf8))
        return Fixture(dir: dir, plugin: plugin, list: list)
    }

    @Test func aWholeCommandIsAccepted() throws {
        let f = try Self.fixture()
        defer { try? FileManager.default.removeItem(atPath: f.dir) }
        let command = [
            "-module-name", "M", "-Xfrontend", "-load-plugin-executable", "-Xfrontend", f.plugin + "#SwiftNavigationMacros",
            "@" + f.list,
        ]
        #expect(SwiftPMBuild.isWhole(command))
    }

    @Test func anotherToolsOutputInsideTheCommandIsDetected() throws {
        let f = try Self.fixture()
        defer { try? FileManager.default.removeItem(atPath: f.dir) }
        let cut = f.plugin.dropLast("igationMacros".count)
        let log =
            "/x/swiftc -module-name M -Xfrontend -load-plugin-executable -Xfrontend \(cut)/* com.apple.actool.compilation-results */\n"
            + "igationMacros#SwiftNavigationMacros @\(f.list)\n"
        let command = try #require(SwiftPMBuild.compileCommand(in: log, module: "M"))
        #expect(!SwiftPMBuild.isWhole(command), "\(command)")
    }

    @Test func aCommandWithoutSourcesOrWithAMissingPluginIsNotWhole() throws {
        let f = try Self.fixture()
        defer { try? FileManager.default.removeItem(atPath: f.dir) }
        #expect(!SwiftPMBuild.isWhole(["-module-name", "M", "-package-name", "pkg"]))
        #expect(!SwiftPMBuild.isWhole(["-module-name", "M", "-load-plugin-executable", f.dir + "/Missing#Missing", "@" + f.list]))
        #expect(!SwiftPMBuild.isWhole(["-module-name", "M", "-load-plugin-executable", f.plugin, "@" + f.list]))
        #expect(!SwiftPMBuild.isWhole(["-module-name", "M", "@" + f.dir + "/gone.SwiftFileList"]))
    }

    /// Swift Build prints the same driver arguments for the module's driver, requirements and compilation tasks. When
    /// another task printed into the compilation line (here codesign, as on the real app), a whole one is used.
    @Test func anotherTaskLineOfTheSameModuleReplacesAGarbledOne() throws {
        let f = try Self.fixture()
        defer { try? FileManager.default.removeItem(atPath: f.dir) }
        let cut = f.plugin.dropLast("igationMacros".count)
        let flags = "-parse-as-library -module-name M -Onone @\(f.list) -Xfrontend -load-plugin-executable -Xfrontend"
        let log = """
                builtin-SwiftDriver -- /x/swiftc \(flags) \(f.plugin)\\#SwiftNavigationMacros -DFOO
                builtin-Swift-Compilation-Requirements -- /x/swiftc \(flags) \(f.plugin)\\#SwiftNavigationMacros -DFOO
                builtin-Swift-Compilation -- /x/swiftc \(flags) \(cut)/x/M.bundle: replacing existing signature
            igationMacros\\#SwiftNavigationMacros -DFOO

            """
        let command = try #require(SwiftPMBuild.compileCommand(in: log, module: "M"))
        #expect(SwiftPMBuild.isWhole(command), "\(command)")
        #expect(command.contains(f.plugin + "#SwiftNavigationMacros") && command.contains("-DFOO"))
    }

    /// CoreGraphics prints its PDF warning to stderr, which `swift build -v` shares with the command line: its words
    /// once became input files of the saved command.
    @Test func aCoreGraphicsWarningInsideTheCommandIsRemoved() throws {
        let f = try Self.fixture()
        defer { try? FileManager.default.removeItem(atPath: f.dir) }
        let log =
            "/x/swiftc -module-name M -DFOO CoreGraphics PDF has logged an error. Set environment variable "
            + "\"CG_PDF_VERBOSE\" to learn more.\n@\(f.list) -DBAR\n"
        let command = try #require(SwiftPMBuild.compileCommand(in: log, module: "M"))
        #expect(command == ["-module-name", "M", "-DFOO", "@" + f.list, "-DBAR"])
    }
}

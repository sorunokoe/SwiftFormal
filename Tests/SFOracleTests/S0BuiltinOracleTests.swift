import Foundation
import Testing
import SFSemantics
import SFTestSupport

/// Compares the S0 reference interpreter with the compiler's own `Builtin.*` operations, executed natively.
/// `tools/builtin-oracle/oracle.swift` calls the builtins directly (`swiftc -parse-stdlib`), so this does not
/// route through the standard library's wrappers.
@Suite(.tags(.oracle, .slow), .requiresPinnedCompiler) struct S0BuiltinOracleTests {
    private static let oracleSource = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("tools/builtin-oracle/oracle.swift")

    private func run(_ executable: String, _ arguments: [String]) throws -> (status: Int32, output: Data) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        let pipe = Pipe()
        process.standardOutput = pipe
        try process.run()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return (process.terminationStatus, data)
    }

    @Test
    func interpreterMatchesCompilerBuiltins() throws {
        for optimization in ["-Onone", "-O"] {
            let binary = NSTemporaryDirectory() + "sf-oracle-\(UUID().uuidString)"
            defer { try? FileManager.default.removeItem(atPath: binary) }
            let compile = try run("/usr/bin/xcrun", ["swiftc", "-parse-stdlib", optimization, Self.oracleSource.path, "-o", binary])
            try #require(compile.status == 0, "oracle failed to compile")
            let result = try run(binary, [])
            try #require(result.status == 0)

            var checked = 0
            var names = Set<String>()
            var mismatches: [String] = []
            for line in String(decoding: result.output, as: UTF8.self).split(separator: "\n") {
                let fields = line.split(separator: " ")
                guard fields.count == 4, let a = UInt64(fields[1]), let b = UInt64(fields[2]) else {
                    Issue.record("malformed oracle line: \(line)"); return
                }
                guard let inst = S0Instance(builtinName: String(fields[0])) else {
                    Issue.record("oracle emitted a builtin the table rejects: \(fields[0])"); return
                }
                let want = fields[3].split(separator: ",").map { UInt64($0)! }
                let call: [UInt64] = inst.arity == 1 ? [a] : (inst.arity == 3 ? [a, b, 0] : [a, b])
                let got = inst.evaluate(call)
                names.insert(inst.builtinName)
                checked += 1
                if got != .values(want) && mismatches.count < 5 {
                    mismatches.append("\(line): interpreter says \(got)")
                }
            }
            #expect(mismatches.isEmpty, "\(optimization): \(mismatches)")
            #expect(checked > 1_000_000, "\(optimization): only \(checked) cases")
            // Every table entry the oracle can express at 8 bits is covered.
            #expect(names.count >= 40, "\(optimization): only \(names.count) distinct builtins")
        }
    }
}

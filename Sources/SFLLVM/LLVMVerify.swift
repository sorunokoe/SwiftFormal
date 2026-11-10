import Foundation
package import SFBV
import SFCNF
package import SFProve
package import SFSIL

/// Compiles Swift source to LLVM IR with the installed `swiftc`.
package enum LLVMCompiler {
    package static func emit(source: String, module: String = "Fixture", optimization: Optimization) throws -> String {
        let directory = NSTemporaryDirectory() + "sf-llvm-\(UUID().uuidString)"
        try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: directory) }
        let input = directory + "/\(module).swift"
        try source.write(toFile: input, atomically: true, encoding: .utf8)

        let output = directory + "/\(module).ll"
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/xcrun")
        process.arguments = [
            "swiftc", "-frontend", "-emit-ir", optimization.rawValue, "-parse-as-library",
            "-module-name", module, "-sdk", try sdkPath(), input, "-o", output,
        ]
        let err = Pipe()
        process.standardError = err
        try process.run()
        let errData = err.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw LLVMError.compilerFailed(String(decoding: errData, as: UTF8.self))
        }
        return try String(contentsOfFile: output, encoding: .utf8)
    }

    private static func sdkPath() throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/xcrun")
        process.arguments = ["--show-sdk-path"]
        let pipe = Pipe()
        process.standardOutput = pipe
        try process.run()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    package static func module(source: String, name: String = "Fixture", optimization: Optimization) throws -> LLVMModule {
        try LLVMModule(text: try emit(source: source, module: name, optimization: optimization))
    }
}

package enum LLVMVerifier {
    /// How the optimized-IR meaning of a function may relate to its SIL meaning.
    package enum Relation: Sendable {
        /// Same trap set, same undefined set, same value wherever neither traps nor is undefined.
        case equal
    }

    /// Proves `requires(inputs) ⇒ ¬trap ∧ ¬undefined ∧ ensures(inputs, result)` for the LLVM IR of `symbol`.
    package static func prove(
        _ symbol: String,
        in module: LLVMModule,
        inputSignedBits: [Int?]? = nil,
        conflictBudget: Int = 1_000_000,
        refining: Bool = false,
        requires: (CNFBuilder, [BV]) -> Int32 = { c, _ in c.trueLit },
        ensures: (CNFBuilder, [BV], BV) -> Int32 = { c, _, _ in c.trueLit }
    ) throws -> ProofVerdict {
        let function = try module.function(symbol)
        let claim: (CNFBuilder, [BV]) throws -> Int32 = { c, inputs in
            let encoded = try LLVMEncoder(module: module, builder: c).encode(symbol: symbol, arguments: inputs)
            let safe = c.and(-encoded.trap, -encoded.undefined)
            return c.or(-requires(c, inputs), c.and(safe, ensures(c, inputs, encoded.result)))
        }
        return try proveMaybeRefining(
            inputWidths: function.parameterWidths, inputSignedBits: inputSignedBits,
            conflictBudget: conflictBudget, refining: refining, claim: claim
        )
    }

}

import Foundation
import SFLLVM
import SFProve
import SFSIL

/// Plan item V4 (owner decision 9): the second, independently written encoder (SFLLVM reads the LLVM IR of the same
/// compilation) as an opt-in check of Scan's proofs. The two encoders share no code, so a `safe` the cross-check
/// agrees with would need both to be wrong in the same way.
public enum CrossCheck: String, Sendable, CaseIterable {
    /// Scan alone (the default).
    case off
    /// Each `safe` or `contractHolds` is compared with the IR's meaning; the report says whether they agree.
    case llvm
    /// The same, and a verdict the IR does not confirm becomes `undecided`.
    case llvmStrict = "llvm-strict"
}

extension SFVerify {
    /// Solver conflicts per equivalence proof. Small on purpose: the check is extra assurance, and a proof it cannot
    /// finish is reported as `undecided`, never counted as agreement.
    static let crossCheckBudget = 20_000

    /// Proves, for each proved function, that the SIL encoding and the LLVM IR encoding of the same compilation mean the
    /// same thing (same traps, same undefined behaviour, same result): `agrees`, `disagrees` (the two readers or the
    /// compiler's lowering differ), `unread` (the IR reader does not support the function) or `undecided` (the
    /// equivalence needs more than `crossCheckBudget` conflicts: proving two multiplier circuits equal is hard).
    static func crossChecked(
        _ reports: [FunctionReport], compiled: CompiledModule, compile: CompileOptions, options: VerifyOptions
    ) -> [FunctionReport] {
        let proved: Set<ScanStatus> = [.safe, .contractHolds]
        guard reports.contains(where: { proved.contains($0.status) }) else { return reports }
        let ir: Result<LLVMModule, any Error> = Result { try LLVMModule(text: try ModuleCompiler.emitIR(compile)) }
        return reports.map { report in
            guard proved.contains(report.status) else { return report }
            var checked = report
            let outcome: String
            do {
                let verdict = try LLVMVerifier.proveEquivalentToSIL(
                    symbol: report.symbol, silModule: compiled.module, llvmModule: try ir.get(), conflictBudget: crossCheckBudget)
                outcome = verdict == .proved ? "agrees" : (verdict == .unknown ? "undecided" : "disagrees")
            } catch {
                outcome = "unread"
                checked.crossCheckReason = String(String(describing: error).prefix(300))
            }
            checked.crossCheck = outcome
            if options.crossCheck == .llvmStrict, outcome != "agrees" {
                checked.status = .undecided
                checked.category = "cross-check"
                checked.detail =
                    "--cross-check llvm-strict: the LLVM IR encoding \(outcome == "disagrees" ? "disagrees with the SIL encoding" : outcome == "unread" ? "could not read this function" : "was not shown equal in budget")"
            }
            return checked
        }
    }
}

extension ModuleCompiler {
    /// The LLVM IR of the module, compiled with the same flags as its SIL (`frontendArguments`, without debug info).
    static func emitIR(_ options: CompileOptions) throws -> String {
        var arguments = frontendArguments(options).filter { !["-g", "-Xllvm", "-sil-print-debuginfo"].contains($0) }
        arguments = arguments.map { $0 == "-emit-sil" ? "-emit-ir" : $0 }
        let sdk = try sdkArguments(options.extraArguments)
        arguments += sdk.arguments + (try macroPluginArguments(sdk: sdk.path))
        arguments += try withModuleCache(options.extraArguments) + options.files
        return try output(of: arguments, dependencies: options.dependencies, kind: "LLVM IR")
    }
}

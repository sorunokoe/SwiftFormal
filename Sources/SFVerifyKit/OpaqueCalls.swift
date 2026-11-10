import SFSIL

// Calls with no body (`SILOpaqueCalls.swift`): how the options choose to read them, and how the assumptions each
// verdict took on trust reach its report (`FunctionReport.assumptions`).
extension CompiledModule {
    /// The module as `options` read it: whether calls with no body may return any value (`VerifyOptions.opaqueCalls`).
    func reading(_ options: VerifyOptions) -> CompiledModule {
        var copy = self
        copy.module.opaqueCalls = options.opaqueCalls ? .all : .none
        return copy
    }
}

extension Verifier {
    /// `make`'s report with the assumptions its encodings recorded (`Assumptions`); none for a function that was not
    /// decided (the encodings that refused it may have recorded some before they stopped).
    static func withAssumptions(_ make: () -> FunctionReport) -> FunctionReport {
        let assumptions = Assumptions()
        var report = Assumptions.$current.withValue(assumptions) { make() }
        let all = assumptions.all
        report.assumptions = all.isEmpty || [.unsupported, .internalError].contains(report.status) ? nil : all
        return report
    }
}

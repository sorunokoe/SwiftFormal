import Foundation

/// Every function of a module parsed once (plan item S7): a scan used to parse each body about four times (the
/// verifier, the loop planner, the closure walk, the counterexample replay). The result of a parse, an error
/// included, depends only on the module's stored properties, so `SILModule` drops this cache whenever one changes
/// (`didSet`); a copy of a module shares it until then. Two threads may parse the same function at once; both get
/// the same result and the first one stays.
final class ParsedBodies: @unchecked Sendable {
    private let lock = NSLock()
    private var functions: [String: Result<SILFunction, SILError>] = [:]

    func function(_ symbol: String, parse: () throws(SILError) -> SILFunction) throws(SILError) -> SILFunction {
        lock.lock()
        let cached = functions[symbol]
        lock.unlock()
        if let cached { return try cached.get() }
        let result = Result { () throws(SILError) in try parse() }
        lock.lock()
        let kept = functions[symbol] ?? result
        functions[symbol] = kept
        lock.unlock()
        return try kept.get()
    }
}

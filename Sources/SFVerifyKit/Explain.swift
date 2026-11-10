import Foundation
import SFBV
import SFCNF
import SFSIL

/// A refusal of the SIL reader or encoder, with where the encoder was when it is known.
protocol Refusal: Error {
    var refused: SILError { get }
    /// The functions the encoder was inlining, outermost first, each at an instruction; empty when unknown.
    var trail: [SILTrailFrame] { get }
}

/// An encoder refusal together with where the encoder was.
struct LocatedSILError: Refusal {
    let refused: SILError
    let trail: [SILTrailFrame]
}

extension SILError: Refusal {
    var refused: SILError { self }
    var trail: [SILTrailFrame] { [] }
}

extension Verifier {
    // MARK: where (plan item U7)

    /// `SILEncoder.encode`, with a refusal carrying the encoder's trail.
    static func encodeLocated(
        _ module: SILModule, _ c: CNFBuilder, symbol: String, arguments: [BV], summaries: [String: ContractSummary] = [:]
    ) throws -> EncodedFunction {
        let encoder = SILEncoder(module: module, builder: c)
        encoder.contractSummaries = summaries
        do {
            return try encoder.encode(symbol: symbol, arguments: arguments)
        } catch let error as SILError {
            throw LocatedSILError(refused: error, trail: encoder.trail)
        }
    }

    /// The source position of the refused construct (the innermost frame the debug info places), and the calls that
    /// lead to it from the scanned function, innermost first ("called from here", as the compiler's
    /// `PerformanceDiagnostics` does for `@_noLocks`).
    static func locate(_ trail: [SILTrailFrame], functions: [String: FunctionInfo]) -> (at: SourceLocation?, calledFrom: [SourceLocation]) {
        let places = trail.map { frame in frame.value.flatMap { functions[frame.function]?.valueLocations[$0] } }
        guard let inner = places.lastIndex(where: { $0 != nil }) else { return (nil, []) }
        return (places[inner], places[..<inner].reversed().compactMap { $0 })
    }

    /// Fills `category`, `detail`, `at`, `calledFrom` and `hint` of an unsupported function.
    static func explainUnsupported(
        _ report: inout FunctionReport, _ error: SILError, trail: [SILTrailFrame], functions: [String: FunctionInfo]
    ) {
        report.status = .unsupported
        report.category = category(of: error)
        report.detail = error.description.replacingOccurrences(of: SILError.supportedTypesNote, with: "")
        let (at, calledFrom) = locate(trail, functions: functions)
        report.at = at
        if !calledFrom.isEmpty { report.calledFrom = calledFrom }
        report.hint = hint(forCategory: report.category ?? "other", detail: report.detail ?? "")
    }

    /// Fills `detail`, `category` and `hint` of an undecided function; `why` is nil when the budget ran out.
    static func explainUndecided(_ report: inout FunctionReport, why: String?, budget: Int) {
        report.status = .undecided
        report.detail = why ?? "no answer within \(budget) solver conflicts"
        report.category = why == nil ? budgetCategory : unmodelledCategory
        report.hint = hint(forCategory: report.category ?? budgetCategory)
    }

    // MARK: what to do

    /// `FunctionReport.category` of an undecided function that ran out of solver conflicts.
    package static let budgetCategory = "budget"
    /// `FunctionReport.category` of an undecided function whose answer depends on results logic does not model.
    package static let unmodelledCategory = "unmodelled results"
    /// `FunctionReport.category` of an unsupported function whose `_requires` / `_ensures` logic could not read or
    /// pair: the contract is not checked, whatever logic says about the function alone.
    package static let contractNotReadCategory = "contract not read"

    /// What a user can change, for each category `category(of:)` gives and the two undecided ones.
    package static let categoryHints: [String: String] = [
        "ambiguous type names": "two types share this name; rename one so Scan can tell them apart",
        "optionals": "unwrap first and verify the function that takes the wrapped value",
        "strings": "Scan does not read text; pass what the arithmetic needs as integers (`s.utf8.count`) and verify that function",
        "dictionaries and sets": "move the arithmetic into a function over the values (integers) and verify that",
        "arrays": "pass the elements or the count as integers, or check this function with a walk (`Prove`)",
        "for-in over ranges and sequences": "write the loop as `while` over an integer index, or check it with a walk (`Prove`)",
        "for-in loops": "write the loop as `while` over an integer index, or check it with a walk (`Prove`)",
        "ranges of non-integer bounds": "use a range of a standard integer type, or check the function with a walk (`Prove`)",
        "exclusivity":
            "a function that takes an object is proved only where the object is created: verify a function that makes it",
        "Objective-C objects":
            "Scan reads Objective-C and Kotlin objects as references whose getters return any value; move what the detail names out of the function, or check it with a walk",
        "macro-generated types": "nothing to change: code a macro wrote is not yours to prove; check its users with a walk if needed",
        "floating point":
            "Scan reads `Double`, `Float` and `Float16`, not `CGFloat` or `Float80`: convert to `Double` and verify the function over that",
        "existentials / protocols": "call the concrete type, or make the function take the concrete type instead of `any P`",
        "opaque result types (some …)": "return the concrete type instead of `some P`",
        "closures": "pass a value instead of a closure, or verify the closure's body as a named function",
        "bounded":
            "bound the array's length with a `#requires` (`xs.count <= 64`) for a proof over every input, or check the function with a walk",
        "classes and objects": "use a struct, or move the arithmetic into a function over the stored integers",
        "enums": "Scan reads non-generic enums without `indirect`; move the arithmetic into a function over the payload",
        "loops (need an invariant)": "rewrite without the loop, or check it with a walk (`Prove`)",
        "recursion": "rewrite without recursion, or check it with a walk (`Prove`)",
        "deep call chain": "calls nest more than 8 deep; verify the inner functions on their own and flatten the chain",
        "calls a function without a body":
            "the callee is compiled in another module; scan with --package and --build, or make the callee `@inlinable`",
        "generics":
            "Scan reads concrete code only; call a non-generic version (for `numericCast(x)` write the conversion, such as `Int32(x)`)",
        "protocol dispatch": "call the concrete type's method instead of going through a protocol",
        "closures and indirect calls": "call the function directly instead of through a closure or a function value",
        "mutable globals": "pass the value as a parameter instead of reading a mutable global",
        "globals": "pass the value as a parameter instead of reading a global",
        "concurrency": "move the arithmetic into a synchronous function and verify that",
        "unrecognised SIL": "the SIL reader does not know this instruction; please report it with the function",
        "spec shape": "the `f_requires` / `f_ensures` `@Verify` wrote do not fit `f`: please report it with the function",
        budgetCategory:
            "raise --budget, narrow the types (Int8 or Int16 instead of Int), or add a `#requires` that bounds the inputs",
        unmodelledCategory:
            "the answer depends on what these calls return, which logic does not model; check it with a walk (`Prove`) or a test",
    ]

    /// The fix hint of an unsupported construct: `abs` on a floating-point value gets its own (`x.magnitude` is not
    /// read either), anything else the hint of its category. `detail` names the callee by its symbol (`$ss3abs…`,
    /// demangled later) or by its readable name.
    package static func hint(forCategory category: String, detail: String) -> String {
        let floatingPoint = ["<Double>", "<Float>", "<CGFloat>", "<Float16>", "<Float80>"]
        let callsAbs = detail.contains("$ss3abs") || detail.contains("abs<")
        if category == "generics", callsAbs, floatingPoint.contains(where: detail.contains) {
            return "Scan reads concrete code only; for `abs(x)` on floating point write `x < 0 ? -x : x`"
        }
        return hint(forCategory: category)
    }

    /// The fix hint of `category`; a `type …` category and an unknown one get a general hint.
    package static func hint(forCategory category: String) -> String {
        if let hint = categoryHints[category] { return hint }
        // A type no read module declares (a type of another module, or a generic parameter): no field of it can be
        // read. The hint names no arithmetic: the function may only carry the value along (app study round 6, L10).
        if category.hasPrefix("type ") {
            let type = category.dropFirst("type ".count)
            return "Scan cannot read \(type): no module it reads declares its layout (a Foundation, SwiftUI or SDK type, one "
                + "of a binary framework, or a generic parameter). Keep it out of what this function reads (move the logic "
                + "into a function over the values Scan reads), or check the logic around it with a walk (`Prove`)"
        }
        return "see the detail; if it is plain integer code, please report it"
    }
}

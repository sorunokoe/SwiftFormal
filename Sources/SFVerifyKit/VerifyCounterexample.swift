import Foundation
import SFBV
import SFCNF
import SFProve
import SFSIL

extension Verifier {
    // MARK: counterexamples

    /// A counterexample found with summarized calls (`approximations`) may rest on a result the real call never
    /// returns. It is kept only when, on its inputs, the claim fails for every result those calls could give;
    /// otherwise the verdict becomes `.unknown`, with the reason.
    static func honest(
        _ verdict: ProofVerdict, approximations: Set<String>, widths: [Int], budget: Int, claim: Claim
    ) throws -> (verdict: ProofVerdict, reason: String?) {
        guard case .counterexample(var values) = verdict, !approximations.isEmpty else { return (verdict, nil) }
        // A localization call is a function of its key: a counterexample that needs two keys to give one text is not
        // kept, but another input may fail with any text (two cases with the same key). A few more are tried.
        var excluded: [[UInt64]] = []
        let retries = approximations.isDisjoint(with: Localization.approximations) ? 0 : 16
        while true {
            let found = values
            let fixed = try proveReporting(inputWidths: [], conflictBudget: budget) { c, _ in
                -(try claim(c, zip(widths, found).map { c.constant($1, width: $0) }).literal)
            }
            if fixed.verdict == .proved { return (.counterexample(values), nil) }
            excluded.append(values)
            guard excluded.count <= retries else { break }
            let other = try proveReporting(inputWidths: widths, conflictBudget: budget) { c, inputs in
                var holds = try claim(c, inputs).literal
                for earlier in excluded {
                    let same = zip(inputs, zip(widths, earlier)).reduce(c.trueLit) {
                        c.and($0, c.eq($1.0, c.constant($1.1.1, width: $1.1.0)))
                    }
                    holds = c.or(holds, same)
                }
                return holds
            }
            guard case .counterexample(let next) = other.verdict else { break }
            values = next
        }
        let names = approximations.sorted().joined(separator: ", ")
        // A floating-point result is exact except when it is NaN: then its sign and payload are left open.
        let examples =
            (approximations.contains("floating point") ? "the sign and payload of a NaN, " : "") + "string contents, hashes, array elements"
        return (.unknown, "can fail only for some results of \(names); logic does not model what these return (\(examples))")
    }

    /// Runs the encoder on constant inputs: every gate folds to a constant, so this is an interpreter for the model.
    static func explain(
        _ values: [UInt64], info: FunctionInfo, function: SILFunction, module: SILModule, specs: Contract,
        functions: [String: FunctionInfo] = [:], skipping: Set<String> = [], replaysMethods: Bool = true
    ) -> ScanCounterexample {
        let subject = RefutedFunction(info: info, function: function, module: module, specs: specs, functions: functions)
        var (example, result) = trace(values, subject, skipping: skipping)
        // Rendered after the trace, which has met every string literal these values can be (`StringIdentity`).
        let types = leafTypes(info, function)
        ValueRenderer.StandIns.$current.withValue(ValueRenderer.StandIns(module: module)) {
            example.inputs = renderInputs(values, info: info, function: function, types: types)
            example.replay = replay(values, info: info, types: types)
            if example.replay == nil, info.isMethod, replaysMethods {
                if specs.requires != nil || specs.ensures != nil {
                    example.noReplay = "a method with a contract (playback replays the traps of methods, not their contracts)"
                } else if result != nil || !isTrapFailure(example.failure) {
                    example.noReplay = "not a trap a test can replay"
                } else {
                    switch methodReplay(values, info: info, function: function, module: module) {
                    case .call(let call): example.replay = call
                    case .none(let why): example.noReplay = why
                    }
                }
            }
            if let result { example.result = renderResult(result, info: info, function: function) }
            if let spec = specs.ensures, example.failure.hasPrefix("ensures is false") {
                example.ensuresCall = ensuresCall(values, spec: spec, types: types, call: example.replay)
            }
            example.addForeignResults()
        }
        return example
    }

    /// Whether `failure` is a trap of the function itself, which an exit test replays (not undefined behaviour, a spec's
    /// own trap, or a counterexample that could not be replayed).
    static func isTrapFailure(_ failure: String) -> Bool {
        let notTraps = ["undefined behaviour", "could not replay", "the requires function", "the ensures function", "the claim fails"]
        let release = "in a release build (-assert-config Release): "
        let text = failure.hasPrefix(release) ? String(failure.dropFirst(release.count)) : failure
        return !notTraps.contains { text.hasPrefix($0) }
    }

    private static func trace(
        _ values: [UInt64], _ subject: RefutedFunction, skipping: Set<String>
    ) -> (ScanCounterexample, result: [UInt64]?) {
        let (info, function, module, specs, functions) =
            (subject.info, subject.function, subject.module, subject.specs, subject.functions)
        var example = ScanCounterexample(inputs: [], result: nil, failure: "the claim fails", at: nil, replay: nil)
        let c = CNFBuilder()
        let args = zip(function.parameterWidths, values).map { c.constant($1, width: $0) }
        func isTrue(_ lit: Int32) -> Bool { c.constantValue(BV(bits: [lit])) == 1 }
        do {
            if let spec = specs.requires, let problem = try requiresProblem(spec, c, args, module: module) {
                example.failure = problem
                return (example, nil)
            }
            let f = try SILEncoder(module: module, builder: c).encode(symbol: info.symbol, arguments: args)
            if isTrue(f.trap) {
                let site = f.trapSites.first { isTrue($0.condition) && !skipping.contains($0.kind.key) }
                (example.failure, example.at) =
                    site.map { describeTrap($0.kind, info: info, functions: functions, isTrue: isTrue) }
                    ?? ("the function traps", nil)
                return (example, nil)
            }
            if isTrue(f.undefined) {
                example.failure = "undefined behaviour in a primitive operation (for example a shift amount out of range)"
                return (example, nil)
            }
            if c.constantValue(BV(bits: [f.trap])) == nil {
                // The trap depends on summarized calls (string contents, hashes); it happens for every outcome of them.
                example.failure = "the function traps, whatever \(f.approximations.sorted().joined(separator: ", ")) return"
                return (example, nil)
            }
            // An address-only result (a `UUID`) comes back first among the written-back values.
            let returned = function.indirectResult.map { Array(f.writtenBack.prefix($0.leafWidths.count)) } ?? f.results
            let resultValues = returned.compactMap { c.constantValue($0) }
            let result = resultValues.count == returned.count ? resultValues : nil
            if let spec = specs.ensures {
                let e = try SILEncoder(module: module, builder: c).encode(
                    symbol: spec.symbol,
                    arguments: Contract.ensuresArguments(args, f.results, writtenBack: f.writtenBack, of: function, info))
                if isTrue(e.trap) || isTrue(e.undefined) {
                    example.failure = "the ensures function \(spec.displayName) itself traps on this input (a bug in the spec)"
                } else {
                    example.failure = "ensures is false: \(spec.displayName) returns false for this input and result"
                }
            }
            return (example, result)
        } catch {
            example.failure = "could not replay the counterexample symbolically: \(error)"
            return (example, nil)
        }
    }

    /// Why a counterexample fails before the function runs: `requires` traps on it, or is false (which would be a bug).
    private static func requiresProblem(_ spec: FunctionInfo, _ c: CNFBuilder, _ args: [BV], module: SILModule) throws -> String? {
        let e = try SILEncoder(module: module, builder: c).encode(symbol: spec.symbol, arguments: args)
        if c.constantValue(BV(bits: [e.trap])) == 1 || c.constantValue(BV(bits: [e.undefined])) == 1 {
            return "the requires function \(spec.displayName) itself traps on this input (a bug in the spec)"
        }
        if e.result.bits.count == 1, c.constantValue(e.result) == 0 {
            return "the requires function is false here, yet the claim fails (please report this)"
        }
        return nil
    }

    /// The key (`TrapKind.key`) of the first trap site, not in `skipping`, that fires on `values`; nil if none does.
    static func firedSite(_ values: [UInt64], symbol: String, function: SILFunction, module: SILModule, skipping: Set<String>) -> String? {
        let c = CNFBuilder()
        let args = zip(function.parameterWidths, values).map { c.constant($1, width: $0) }
        guard let f = try? SILEncoder(module: module, builder: c).encode(symbol: symbol, arguments: args) else { return nil }
        return f.trapSites.first { c.constantValue(BV(bits: [$0.condition])) == 1 && !skipping.contains($0.kind.key) }?.kind.key
    }

    /// What went wrong at `kind`, and where. A trap inside a callee of this module is reported at its own position,
    /// named after the callee, when the callee's debug info is known (plan item H2).
    static func describeTrap(
        _ kind: TrapKind, info: FunctionInfo, functions: [String: FunctionInfo] = [:], isTrue: (Int32) -> Bool = { _ in false }
    ) -> (String, SourceLocation?) {
        switch kind {
        case .condFail(let operand):
            guard let hit = info.condFails[operand] else { return ("the function traps", nil) }
            return (hit.message.isEmpty ? "the function traps" : "traps: \(hit.message)", hit.location)
        case .call(let id, let callee, let inner):
            let at = id.flatMap { info.calls[$0] }
            if let (what, location) = trapInside(callee, inner, functions: functions, isTrue: isTrue) { return (what, location) }
            return ("calls \(functions[callee]?.displayName ?? callee), which traps", at)
        case .stdlib(let id, let message):
            return ("traps: \(message)", info.calls[id])
        case .unreachable(let block):
            let hit = info.failureBlocks[block]
            let message = hit?.message ?? ""
            if ContractFailureCall.kinds.values.contains(where: { message.hasPrefix($0) }) {
                // A `@Verify` check: its location is inside the macro expansion, which no one can open.
                let inExpansion = hit?.location?.file.hasPrefix("@__swiftmacro_") ?? true
                return (message, inExpansion ? info.location : hit?.location)
            }
            return (message.isEmpty ? "the function traps" : "traps: \(message)", hit?.location)
        }
    }

    /// The trap inside `callee` that fires, described in the innermost function whose debug info is known. Thunks
    /// (protocol witnesses, which have none) are stepped through.
    private static func trapInside(
        _ callee: String, _ inner: [TrapSite], functions: [String: FunctionInfo], isTrue: (Int32) -> Bool
    ) -> (String, SourceLocation)? {
        guard let hit = inner.first(where: { isTrue($0.condition) }) else { return nil }
        if let calleeInfo = functions[callee] {
            let (what, location) = describeTrap(hit.kind, info: calleeInfo, functions: functions, isTrue: isTrue)
            return location.map { ("in \(calleeInfo.displayName): \(what)", $0) }
        }
        if case .call(_, let next, let deeper) = hit.kind { return trapInside(next, deeper, functions: functions, isTrue: isTrue) }
        return nil
    }

    // MARK: rendering values

    static func leafTypes(_ info: FunctionInfo, _ function: SILFunction) -> [String?] {
        let known = [
            "Int", "Int8", "Int16", "Int32", "Int64", "UInt", "UInt8", "UInt16", "UInt32", "UInt64", "Bool", "Double", "Float", "String",
        ]
        let names = info.parameterTypes.map { $0.split(separator: " ").last.map(String.init) ?? $0 }
        if names.count == function.parameterWidths.count, names.allSatisfy({ known.contains($0) }) { return names }
        return Array(repeating: nil, count: function.parameterWidths.count)
    }

    static func render(_ value: UInt64, type: String?, width: Int) -> String {
        guard let type else { return "0x" + String(value, radix: 16) }
        if type == "String" { return ValueRenderer.text(value) }
        if type == "Bool" { return value & 1 == 1 ? "true" : "false" }
        if type == "Double" || type == "Float" { return floatLiteral(bits: value, type: type) }
        if type.hasPrefix("UInt") { return String(value) }
        let shift = UInt64(64 - width)
        return String(Int64(bitPattern: value << shift) >> Int64(shift))
    }

    static func renderInputs(_ values: [UInt64], info: FunctionInfo, function: SILFunction, types: [String?]) -> [String] {
        let labels = info.argumentLabels
        if types.contains(where: { $0 == nil }) {
            // Structs, tuples and enums: one entry per parameter, rendered from its layout.
            var out: [String] = []
            var offset = 0
            for (i, type) in function.parameterTypes.enumerated() {
                let n = type.leafWidths.count
                defer { offset += n }
                if n == 0 { continue }  // a metatype (`self` of a static method)
                let name = i < info.parameterTypes.count ? info.parameterTypes[i].split(separator: " ").last.map(String.init) : nil
                out.append(
                    "\(parameterName(i, info: info, labels: labels)) = \(ValueRenderer.render(type, values[offset..<(offset + n)], scalarName: name))"
                )
            }
            return out
        }
        return values.enumerated().map { i, v in
            let width = types[i].map(bitWidth) ?? 64
            return "\(parameterName(i, info: info, labels: labels)) = \(render(v, type: types[i], width: width))"
        }
    }

    static func parameterName(_ i: Int, info: FunctionInfo, labels: [String]) -> String {
        if let name = info.parameterNames[i + 1] { return name }
        return i < labels.count && labels[i] != "_" ? labels[i] : "arg\(i)"
    }

    /// A Swift expression for the `Double` or `Float` with these bits. The default NaN is `Double.nan`; a NaN of
    /// another sign or payload is `Double(bitPattern: 0x…)`, so that a replay passes the very bits the model chose.
    package static func floatLiteral(bits: UInt64, type: String) -> String {
        if type == "Float" {
            let f = Float(bitPattern: UInt32(truncatingIfNeeded: bits))
            if f.isNaN, f.bitPattern != Float.nan.bitPattern { return "Float(bitPattern: 0x\(String(f.bitPattern, radix: 16)))" }
            return floatLiteral(Double(f), type: type)
        }
        let d = Double(bitPattern: bits)
        if d.isNaN, d.bitPattern != Double.nan.bitPattern { return "Double(bitPattern: 0x\(String(d.bitPattern, radix: 16)))" }
        return floatLiteral(d, type: type)
    }

    /// A Swift expression for a floating-point value, also for infinities and NaN (`Double.nan`).
    static func floatLiteral(_ x: Double, type: String) -> String {
        if x.isNaN { return "\(type).nan" }
        if x.isInfinite { return x < 0 ? "-\(type).infinity" : "\(type).infinity" }
        return type == "Float" ? "\(Float(x))" : "\(x)"
    }

    static func bitWidth(_ type: String) -> Int {
        switch type {
        case "Bool": 1
        case "Float": 32
        case "Int8", "UInt8": 8
        case "Int16", "UInt16": 16
        case "Int32", "UInt32": 32
        default: 64
        }
    }

    static func renderResult(_ values: [UInt64], info: FunctionInfo, function: SILFunction) -> String {
        let known = [
            "Int", "Int8", "Int16", "Int32", "Int64", "UInt", "UInt8", "UInt16", "UInt32", "UInt64", "Bool", "Double", "Float", "String",
        ]
        if values.count == 1, known.contains(info.resultType) {
            return render(values[0], type: info.resultType, width: bitWidth(info.resultType))
        }
        let type = function.indirectResult ?? function.resultType
        if values.count == type.leafWidths.count {
            return ValueRenderer.render(type, values[...], scalarName: info.resultType)
        }
        return values.map { "0x" + String($0, radix: 16) }.joined(separator: ", ")
    }

    static func replay(_ values: [UInt64], info: FunctionInfo, types: [String?]) -> String? {
        guard !info.isMethod, !info.baseName.contains("."), types.allSatisfy({ $0 != nil }), values.count == types.count else { return nil }
        let labels = info.argumentLabels
        let args = values.enumerated().map { i, v -> String in
            let text = render(v, type: types[i], width: bitWidth(types[i]!))
            return i < labels.count && labels[i] != "_" ? "\(labels[i]): \(text)" : text
        }
        return "\(info.baseName)(\(args.joined(separator: ", ")))"
    }
}

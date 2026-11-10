import Foundation
import SFBV
import SFCNF
import SFProve
import SFSIL

// Reading guide
// Relational claims (mapper verification, Phase 2): what a walk's `Injective()`, `RoundTrip(through:)` and
// `Agrees(with:)` / `Matches` say, proved by Scan for every value of the input type instead of the walked ones. Each
// is one query over two runs of the same code (self-composition): `Injective` encodes the rule on two independent
// inputs `a`, `b` and claims `rule(a) == rule(b) ⇒ a == b`; `RoundTrip` claims `inverse(rule(x)) == x`; `Agrees`
// claims `rule(x) == other(x)`. A closure is a chain of calls that each take the previous value as their only
// argument (`T(input: $0).body`, `f($0)`, `$0.code`), read by `RelationalWalks.swift`.
//
// Soundness. A claim is proved only when every step of every chain is read in full; then the chain is first proved
// to never trap, throw or hit undefined behaviour on a valid input (otherwise the claim is unknown, and the walk's
// verdict stands). `==` is the derived one, on the leaves (`ValueType.equal`): a type with a hand-written `==`, or a
// floating-point value anywhere in a compared type (`-0.0 == 0.0`, `nan != nan`), or an array, set, dictionary or
// opaque value other than `String`, is refused. The two runs share one encoder, so a `let` global is read once. A
// counterexample is kept only when it does not rest on what a summarized call returned (`Verifier.honest`): two
// localization keys may give the same text, so `Injective` over localized text is never refuted from the keys alone,
// and never proved from them either (a different key gives an unknown text). A counterexample that needs a foreign
// result or an assumption is not kept. The assumptions a proof relied on are listed.
// Tests: Tests/SFVerifyKitTests/RelationalProofTests.swift.

/// One call of a walk's closure: it takes the previous value (the walk's input, for the first) as its only argument.
public struct RelationalStep: Codable, Sendable, Hashable {
    public enum Kind: String, Codable, Sendable {
        /// `f($0)`, `T.f(x: $0)` (a static function).
        case function
        /// `T(input: $0)`.
        case initializer
        /// `$0.m()`, `T(…).m()`.
        case method
        /// `$0.p`, `\.p`, `T(…).p`.
        case getter
    }

    public var kind: Kind
    /// The type that declares the function: the `T` of `T.f(x:)` and `T(input:)`; nil for a free function or a member
    /// of the previous value.
    public var type: String?
    public var name: String
    /// The argument labels, `_` for none (`["_"]` for `f($0)`); empty for a getter or a method without arguments.
    public var labels: [String]

    public init(_ kind: Kind, type: String? = nil, name: String, labels: [String] = []) {
        self.kind = kind
        self.type = type
        self.name = name
        self.labels = labels
    }

    /// `f(_:)`, `T.init(input:)`, `m()`, `p.getter`: the display name the compiler prints, without the type.
    var displayName: String {
        switch kind {
        case .function, .initializer, .method: "\(kind == .initializer ? "init" : name)(\(labels.map { $0 + ":" }.joined()))"
        case .getter: "\(name).getter"
        }
    }
}

/// A walk's relational property that `check` asks logic to prove for every input.
public struct RelationalRequest: Codable, Sendable, Equatable {
    public enum Claim: String, Codable, Sendable {
        case injective
        case roundTrip = "round trip"
        case agrees
    }

    public var claim: Claim
    /// Where the walk is (`Prove(…)`), as `WalkRecord.file` and `line` say.
    public var file: String
    public var line: Int
    /// The property's name in the walk's report (`injective`, `round trip`, `agrees with other rule`).
    public var property: String
    /// The rule: the walk's closure.
    public var forward: [RelationalStep]
    /// The inverse (`RoundTrip`) or the other rule (`Agrees`); empty for `Injective`.
    public var other: [RelationalStep] = []
    /// The inverse ends in `!`: it returns an `Optional`, and `nil` is a failure.
    public var unwrapsOther = false

    public init(
        claim: Claim, file: String, line: Int, property: String, forward: [RelationalStep], other: [RelationalStep] = [],
        unwrapsOther: Bool = false
    ) {
        self.claim = claim
        self.file = file
        self.line = line
        self.property = property
        self.forward = forward
        self.other = other
        self.unwrapsOther = unwrapsOther
    }
}

extension Verifier {
    /// `options.relational`, each proved by `proveRelational(_:first:second:unoptimized:options:)`; nil without requests.
    static func proveRelational(
        _ options: VerifyOptions, first: CompiledModule, second: CompiledModule?, compile: CompileOptions
    ) -> [RelationalResult]? {
        guard !options.relational.isEmpty else { return nil }
        return proveRelational(
            options.relational, first: first, second: second, unoptimized: compile.optimization == .none, options: options)
    }

    /// Proves each request over `compiled` (see the top of this file); with `second`, also over the module's other
    /// configuration, keeping the worse result of each. `unoptimized`: the modules were compiled at `-Onone`, where
    /// every function written is emitted, so a missing `T.init(x:)` is the memberwise one the compiler did not need.
    static func proveRelational(
        _ requests: [RelationalRequest], first: CompiledModule, second: CompiledModule?, unoptimized: Bool, options: VerifyOptions
    ) -> [RelationalResult] {
        let prove = { (request: RelationalRequest, compiled: CompiledModule) in
            proveRelational(request, compiled: compiled, memberwise: unoptimized, options: options)
        }
        var results = requests.map { prove($0, first) }
        if let second {
            results = zip(results, requests).map { first, request in
                guard first.result.verdict != .refuted else { return first }
                let other = prove(request, second)
                return (RelationalResult.worse(first.result, other.result), first.source == other.source ? first.source : nil)
            }
        }
        let symbols = Set(results.compactMap(\.source?.symbol))
        let names = symbols.isEmpty ? [:] : Demangler.demangle(Array(symbols).sorted(), simplified: false) ?? [:]
        return results.map { result, source in
            var result = result
            result.inputType = source.flatMap { source in names[source.symbol].flatMap { source.typeName(in: $0) } }
            return result
        }
    }

    /// The result of `request` over `compiled`, and where the name of the type the rule takes is read.
    static func proveRelational(
        _ request: RelationalRequest, compiled: CompiledModule, memberwise: Bool, options: VerifyOptions
    ) -> (result: RelationalResult, source: RelationalTypeSource?) {
        let reading = compiled.reading(options)
        do {
            let pair = try RelationalPair(request, module: reading.module, functions: reading.functions, memberwise: memberwise)
            let assumptions = Assumptions()
            let result = try Assumptions.$current.withValue(assumptions) {
                try CollectionBounds.$current.withValue(CollectionBounds(.exact)) {
                    try pair.prove(budget: options.conflictBudget)
                }
            }
            var final = RelationalResult(request: request, verdict: result.verdict, inputs: result.inputs, detail: result.detail)
            let all = assumptions.all
            if final.verdict == .refuted, !all.isEmpty {
                let detail = "a counterexample that rests on an assumption (\(all.joined(separator: "; "))) is not kept"
                return (RelationalResult(request: request, verdict: .unknown, detail: detail), nil)
            }
            if final.verdict == .proved, !all.isEmpty { final.assumptions = all }
            return (final, pair.forward[0].typeSource)
        } catch let refusal as RelationalRefusal {
            var result = RelationalResult(request: request, verdict: .unknown, detail: refusal.reason)
            if refusal.unresolved { result.unresolved = .noMatchingFunction }
            return (result, nil)
        } catch {
            return (RelationalResult(request: request, verdict: .unknown, detail: "not read: \(error)"), nil)
        }
    }
}

/// A function of a chain, read: its symbol, which parameter takes the value, and what it returns. Without a function,
/// the memberwise initializer of a struct with one stored property: the value itself.
struct ChainStep {
    let symbol: String
    let display: String
    let function: SILFunction?
    /// The parameter that takes the previous value; the others carry no data (a metatype).
    let parameter: Int
    let input: ValueType
    let output: ValueType
    let inputText: String
    let outputText: String
    /// The parameter is an `Optional` of the previous value, which Swift wraps in `.some` to pass it.
    var promotes = false
    /// Where the full name of the type this step takes is read; nil when it is not known.
    var typeSource: RelationalTypeSource?

    /// Whether this step takes `value`: as it is, or wrapped in `.some` when it takes an `Optional` of it.
    func takes(_ value: ValueType) -> (Bool, promotes: Bool) {
        if input == value { return (true, false) }
        return (input.optionalWrapped == value && input.payloadLeafRange(ofCase: 1) == 1..<(1 + value.leafWidths.count), true)
    }
}

/// The rule and the other chain of one request, read, with the types they compare.
struct RelationalPair {
    let request: RelationalRequest
    let module: SILModule
    let forward: [ChainStep]
    let other: [ChainStep]

    var inputType: ValueType { forward[0].input }
    /// The rule's last step: what it returns. `init` reads at least one step of each chain.
    var rule: ChainStep { forward[forward.count - 1] }

    init(_ request: RelationalRequest, module: SILModule, functions: [FunctionInfo], memberwise: Bool) throws {
        self.request = request
        self.module = module
        guard !request.forward.isEmpty else { throw RelationalRefusal(reason: "the walk's closure is not a chain of calls logic reads") }
        let read = { (steps: [RelationalStep], previous: ChainStep?) in
            try Self.read(steps, from: previous, module: module, functions: functions, memberwise: memberwise)
        }
        forward = try read(request.forward, nil)
        switch request.claim {
        case .injective:
            other = []
        case .roundTrip:
            guard !request.other.isEmpty else { throw RelationalRefusal(reason: "the inverse is not a chain of calls logic reads") }
            other = try read(request.other, forward.last)
        case .agrees:
            guard !request.other.isEmpty else { throw RelationalRefusal(reason: "the other rule is not a chain of calls logic reads") }
            other = try read(request.other, nil)
            guard other[0].input == inputType else { throw RelationalRefusal(reason: "the two rules take different inputs") }
        }
        try checkCompared(functions: functions)
    }

    /// The types `==` is decided on must have the derived `==`, and no floating-point value.
    private func checkCompared(functions: [FunctionInfo]) throws {
        var compared: [(type: ValueType, text: String)] = []
        switch request.claim {
        case .injective: compared = [(inputType, forward[0].inputText), (rule.output, rule.outputText)]
        case .roundTrip: compared = [(inputType, forward[0].inputText)]
        case .agrees: compared = [(rule.output, rule.outputText)]
        }
        for (type, text) in compared {
            guard module.holdsNoFloatingPoint(text) else {
                throw RelationalRefusal(
                    reason: "\(text) can hold a floating-point value, whose == is not equality of bits (-0.0 == 0.0, nan != nan)")
            }
            guard module.definesEquality(mentioning: type.nominalNames) == false else {
                throw RelationalRefusal(reason: "\(text) has a hand-written ==, which logic does not compare by")
            }
        }
    }

    // MARK: reading

    /// Reads `steps`, the first taking a value of the type `previous` returns (any type when nil).
    private static func read(
        _ steps: [RelationalStep], from previous: ChainStep?, module: SILModule, functions: [FunctionInfo], memberwise: Bool
    ) throws -> [ChainStep] {
        var chain: [ChainStep] = []
        for step in steps {
            let before = chain.last ?? previous
            let candidates = functions.filter { matches($0, step) }
            if candidates.isEmpty, memberwise, let implicit = memberwiseInit(step, after: before, module: module, functions: functions) {
                chain.append(implicit)
                continue
            }
            var exact: [ChainStep] = []
            var promoted: [ChainStep] = []
            var problems: [String] = []
            for info in candidates {
                do {
                    var one = try readStep(info, module: module)
                    one.typeSource =
                        step.kind == .method || step.kind == .getter
                        ? .context(symbol: info.symbol) : .parameter(symbol: info.symbol, index: one.parameter)
                    guard let before else {
                        exact.append(one)
                        continue
                    }
                    let (takes, promotes) = one.takes(before.output)
                    guard takes else { continue }
                    one.promotes = promotes
                    if promotes { promoted.append(one) } else { exact.append(one) }
                } catch {
                    problems.append("\(info.displayName): \(error)")
                }
            }
            guard problems.isEmpty else { throw RelationalRefusal(reason: "not read: \(problems.joined(separator: "; "))") }
            // Swift picks a function that takes the value itself over one that takes an `Optional` of it.
            let read = exact.isEmpty ? promoted : exact
            guard read.count == 1 else {
                let name = (step.type.map { $0 + "." } ?? "") + step.displayName
                throw RelationalRefusal(
                    reason: read.isEmpty ? "no scanned function \(name) takes the value" : "\(read.count) scanned functions match \(name)",
                    unresolved: read.isEmpty)
            }
            chain.append(read[0])
        }
        return chain
    }

    /// `T(input: $0)` when the compiler emitted no `T.init(input:)`: `T` is a struct whose one stored property is
    /// `input`, so its memberwise initializer stores the value as it is (wrapped in `.some` for an `Optional` property).
    private static func memberwiseInit(
        _ step: RelationalStep, after before: ChainStep?, module: SILModule, functions: [FunctionInfo]
    ) -> ChainStep? {
        guard step.kind == .initializer, let type = step.type, step.labels.count == 1,
            let stored = module.storedProperties(of: type), stored.count == 1, stored[0].name == step.labels[0],
            let whole = try? module.resolve(type), let field = try? module.resolve(stored[0].type),
            whole.leafWidths == field.leafWidths
        else { return nil }
        var implicit = ChainStep(
            symbol: "", display: "\(type).init(\(step.labels[0]):)", function: nil, parameter: 0, input: field, output: whole,
            inputText: stored[0].type, outputText: type)
        let getter = "\(type).\(stored[0].name).getter"
        let getters = functions.filter { info in
            let (isStatic, name) = normalized(info.displayName)
            return !isStatic && (name == getter || name.hasSuffix("." + getter))
        }
        if getters.count == 1 { implicit.typeSource = .result(symbol: getters[0].symbol) }
        if let before {
            let (takes, promotes) = implicit.takes(before.output)
            guard takes else { return nil }
            implicit.promotes = promotes
        }
        return implicit
    }

    /// `static T.f(x:), scope 3` → (true, `T.f(x:)`).
    private static func normalized(_ displayName: String) -> (isStatic: Bool, name: String) {
        var name = Substring(displayName)
        let isStatic = name.hasPrefix("static ")
        if isStatic { name = name.dropFirst("static ".count) }
        if let scope = name.range(of: ", scope ") { name = name[..<scope.lowerBound] }
        return (isStatic, String(name))
    }

    private static func matches(_ info: FunctionInfo, _ step: RelationalStep) -> Bool {
        let (isStatic, name) = normalized(info.displayName)
        switch step.kind {
        case .function:
            guard let type = step.type else { return !isStatic && !info.isMethod && name == step.displayName }
            return isStatic && (name == "\(type).\(step.displayName)" || name.hasSuffix(".\(type).\(step.displayName)"))
        case .initializer:
            guard let type = step.type, !isStatic else { return false }
            return name == "\(type).\(step.displayName)" || name.hasSuffix(".\(type).\(step.displayName)")
        case .method, .getter:
            guard !isStatic, name.hasSuffix(".\(step.displayName)") else { return false }
            guard let type = step.type else { return true }
            return name == "\(type).\(step.displayName)" || name.hasSuffix(".\(type).\(step.displayName)")
        }
    }

    private static func readStep(_ info: FunctionInfo, module: SILModule) throws -> ChainStep {
        let function = try module.function(info.symbol)
        guard function.objectParameter == nil, !function.returnsObject else {
            throw RelationalRefusal(reason: "\(info.displayName) takes or returns an object")
        }
        guard !function.conventions.contains(.inout) else { throw RelationalRefusal(reason: "\(info.displayName) has an inout parameter") }
        let carrying = function.parameterTypes.indices.filter { !function.parameterTypes[$0].leafWidths.isEmpty }
        guard carrying.count == 1, let types = module.signatureTypes(info.symbol), types.parameters.count == function.parameterTypes.count
        else {
            throw RelationalRefusal(reason: "\(info.displayName) does not take exactly one value")
        }
        let output = function.indirectResult ?? function.resultType
        return ChainStep(
            symbol: info.symbol, display: info.displayName, function: function, parameter: carrying[0],
            input: function.parameterTypes[carrying[0]], output: output, inputText: types.parameters[carrying[0]],
            outputText: types.result)
    }
}

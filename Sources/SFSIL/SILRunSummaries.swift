import SFBV
import SFCNF
import SFSemantics

// Reading guide
// Calls into the standard library that logic does not read (`StdlibSummary`), and the user code that comparing,
// hashing and printing a value runs.
// Part of `FunctionRun` (`SILFunctionRun.swift`).

extension FunctionRun {
    /// Runs the user code that comparing `type` values with `==` may run, on unknown values, when `condition`
    /// and an unknown choice hold (the standard library may skip the comparison, for example for the same buffer).
    func equate(_ type: String, when condition: Int32, site: String) throws {
        if module.hasLibraryConformance(type) { return }
        let gate = c.and(condition, c.input(width: 1).bits[0])
        if let wrapped = StdlibSummary.optionalWrapped(type) { return try equate(wrapped, when: gate, site: site) }
        if let element = TypeContext.arrayElement(type) { return try equate(element, when: gate, site: site) }
        if let collection = HashedCollection.parse(type) {
            try hash(collection.key, fresh(try module.resolve(collection.key)), when: gate)
            return try collection.components.forEach { try equate($0, when: gate, site: site) }
        }
        guard let witness = module.witness(type: type, requirement: "#Equatable.\"==\"") else {
            throw SILError.unsupported("comparing \(type) values: no Equatable witness in this module")
        }
        let layout = try module.resolve(type)
        _ = try call(witness, fresh(layout) + fresh(layout), at: site, when: gate)
        out.approximations.insert("\(type).==")
    }

    /// The encoder's side of a summary written outside this file (`SummaryCall`).
    func summaryCall(_ entry: StdlibSummary.Entry, _ request: SummarizedCall) -> SummaryCall {
        SummaryCall(
            name: entry.name, request: request, function: function.symbol,
            read: { [self] name, convention in convention == .value ? try flat(name) : try slotValue(name).leaves },
            slotType: { [self] in try slot($0).type },
            write: { [self] name, leaves in
                let reference = try slot(name)
                guard leaves.map(\.width) == reference.type.leafWidths else {
                    throw SILError.invalid("\(entry.name): written value does not match \(name) at \(request.id)")
                }
                for (i, leaf) in leaves.enumerated() { cells["\(reference.id)#\(reference.leaf + i)"] = leaf }
            },
            value: { [self] in env[$0].flatMap(self.leaves) },
            trap: { [self] in trap($0, site: .stdlib(id: request.id, message: $1)) },
            hash: { [self] type, value, condition in
                try requireDefaultRawHash(type)
                try hash(type, try value ?? self.fresh(try self.module.resolve(type)), when: condition)
            },
            equate: { [self] in try equate($0, when: $1, site: request.id) },
            call: { [self] in try call($0, $1, at: request.id, when: $2) },
            approximate: { [self] in out.approximations.insert($0) })
    }

    /// A call into the standard library that logic does not read (see `StdlibSummary`).
    func applySummary(_ entry: StdlibSummary.Entry, _ request: SummarizedCall) throws {
        if case .hashed(let kind, let operation) = entry.summary {
            let result = try encoder.applyHashed(kind, operation, summaryCall(entry, request))
            guard result.map(\.width) == request.type.leafWidths else {
                throw SILError.invalid("\(entry.name): result type at \(request.id)")
            }
            env[request.id] = make(request.type, result)
            return
        }
        if let operation = try entry.arrayOperation(for: request.substitutions) { return try applyArray(operation, entry, request) }
        if entry.summary == .recordsAccess { return try recordAccess(entry, request) }
        if case .computed(let computed) = entry.summary { return try applyComputed(computed, entry, request) }
        if case .range(let operation) = entry.summary { return try applyRange(operation, entry, request) }
        // A switch over case texts or an integer printed as text (`SILStringFacts.swift`); nil: the row's summary.
        if entry.isTextFact, let result = try encoder.textFact(entry, summaryCall(entry, request)) {
            guard result.map(\.width) == request.type.leafWidths else {
                throw SILError.invalid("\(entry.name): result type at \(request.id)")
            }
            env[request.id] = make(request.type, result)
            return
        }
        if case .text(let operation) = entry.summary { return try applyText(operation, entry, request) }
        try applyValueSummary(entry, request)
    }

    /// A summary logic computes (`ComputedSummary`): operands in, traps, result and written-back values out.
    func applyComputed(_ computed: ComputedSummary, _ entry: StdlibSummary.Entry, _ request: SummarizedCall) throws {
        var inputs: [[BV]] = [], written: [ValueType] = []
        for (name, convention) in zip(request.names, request.conventions) {
            inputs.append(convention == .value ? try flat(name) : convention == .out ? [] : try slotValue(name).leaves)
            if convention == .out || convention == .inout { written.append(try slot(name).type) }
        }
        let effect = try computed.encode(
            ComputedCall(
                name: entry.name, inputs: inputs, conventions: request.conventions, substitutions: request.substitutions,
                writtenTypes: written, resultType: request.type), in: c, module: module, fresh: fresh)
        for t in effect.traps { trap(t.condition, site: .stdlib(id: request.id, message: t.message)) }
        out.approximations.formUnion(effect.approximations)
        try writeBack(effect.writtenBack, names: request.names, conventions: request.conventions)
        env[request.id] = make(request.type, effect.result)
    }

    /// A summary that does not change counts or record reads: the call's results are unknown or exact.
    func applyValueSummary(_ entry: StdlibSummary.Entry, _ request: SummarizedCall) throws {
        let subject = try entry.subject(of: request.substitutions)
        /// The values of the address arguments that are read, in order.
        func readValues() throws -> [[BV]] {
            try zip(request.names, request.conventions).filter { $0.1 == .indirect }.map { try slotValue($0.0).leaves }
        }
        func subjectValue() throws -> [BV] {
            guard let first = try readValues().first else {
                throw SILError.invalid("\(entry.name) without its value argument")
            }
            return first
        }
        var exact: [BV]?
        switch entry.summary {
        case .unknown: break
        case .array, .recordsAccess, .hashed, .computed, .range, .text:
            throw SILError.invalid("summary of \(entry.name) applied as a value summary")
        case .minimum, .maximum: exact = [try entry.extremum(of: readValues(), subject: subject, in: c)]
        case .hashCombine, .rawValueHash, .describe, .hashValue:
            if let subject { try runSubjectCode(entry.summary, subject, try subjectValue(), site: request.id) }
        case .interpolationCapacity, .floatClass: if try computedSummary(entry, request) { return }
        }
        try summaryResults(entry, request, exact: exact)
    }

    /// The user code a hashing or printing summary runs on a value of `subject`.
    func runSubjectCode(_ summary: StdlibSummary, _ subject: String, _ value: [BV], site: String) throws {
        switch summary {
        case .hashCombine: try hash(subject, value, when: c.trueLit)
        case .hashValue:
            try requireDefaultRawHash(subject)
            try hash(subject, value, when: c.trueLit)
        case .rawValueHash: try hashRawValue(subject, value, site: site)
        default: try describe(subject, value, when: c.trueLit)
        }
    }

    /// `_rawHashValue(seed:)` of `type` must be the standard library's default (which hashes with `hash(into:)`):
    /// its witness thunk calls `Hashable._rawHashValue(seed:)` and nothing else of the module.
    func requireDefaultRawHash(_ type: String) throws {
        if module.hasLibraryConformance(type) || StdlibSummary.optionalWrapped(type) != nil || TypeContext.arrayElement(type) != nil {
            return
        }
        guard let witness = module.witness(type: type, requirement: "#Hashable._rawHashValue"),
            let body = module.bodyLines(of: witness),
            body.contains(where: { $0.contains("function_ref @$sSHsE13_rawHashValue4seedS2i_tF ") })
        else { throw SILError.unsupported("hashValue of \(type): its _rawHashValue is not the standard default") }
    }

    /// Summaries whose effect logic computes. Returns true when the result is bound here (an exact
    /// classification), false when the call's results are still to be made unknown.
    func computedSummary(_ entry: StdlibSummary.Entry, _ request: SummarizedCall) throws -> Bool {
        guard case .floatClass(let kind) = entry.summary else {
            try interpolationCapacity(entry, request)
            // An interpolation is the handle of its text so far (`TextOperation.appendLiteral`): it starts empty.
            guard let empty = StdlibSummary.Text(c: c).empty, request.type.leafWidths == [64] else { return false }
            env[request.id] = make(request.type, [empty])
            return true
        }
        guard let name = request.names.first, let v = leaves(try lookup(name)), v.count == 1, request.type.leafWidths == [1]
        else { throw SILError.invalid("\(entry.name) at \(request.id)") }
        env[request.id] = make(request.type, [BV(bits: [kind.encode(c, v[0])])])
        return true
    }

    /// `literalCapacity + interpolationCount * 2`, checked, then an allocation of that many bytes.
    func interpolationCapacity(_ entry: StdlibSummary.Entry, _ request: SummarizedCall) throws {
        let words = try zip(request.names, request.conventions).filter { $0.1 == .value }.prefix(2).map { name, _ in
            guard let l = leaves(try lookup(name)), l.count == 1, l[0].width == 64 else {
                throw SILError.invalid("\(entry.name): an argument is not a 64-bit integer at \(request.id)")
            }
            return l[0]
        }
        guard words.count == 2 else { throw SILError.invalid("\(entry.name) without its two counts at \(request.id)") }
        let (literal, count) = (words[0], words[1])
        let two = c.constant(2, width: 64)
        trap(c.signedMulOverflows(count, two), site: .stdlib(id: request.id, message: "arithmetic overflow"))
        let doubled = c.mul(count, two)
        trap(c.signedAddOverflows(literal, doubled), site: .stdlib(id: request.id, message: "arithmetic overflow"))
        let capacity = c.add(literal, doubled).sum
        // Trusted bound, as for arrays: no allocation of 2^48 bytes succeeds (TRUST.md).
        let tooLarge = c.and(-c.slt(capacity, c.constant(0, width: 64)), -c.ult(capacity, c.constant(1 << 48, width: 64)))
        trap(tooLarge, site: .stdlib(id: request.id, message: "string storage too large: allocation fails"))
    }

    /// The `String` handles a text call reads, in call order.
    func textOperands(_ entry: StdlibSummary.Entry, _ request: SummarizedCall) throws -> [BV] {
        try zip(request.names, request.conventions).flatMap { name, convention -> [BV] in
            switch convention {
            case .value: return try flat(name)
            case .inout, .indirect: return try slotValue(name).leaves
            case .out: throw SILError.invalid("\(entry.name) with a result address at \(request.id)")
            }
        }
    }

    /// `StdlibSummary.text`: a `String` call on handles (`SILStrings.swift`).
    func applyText(_ operation: StdlibSummary.TextOperation, _ entry: StdlibSummary.Entry, _ request: SummarizedCall) throws {
        var literal: (text: String, utf8Count: UInt64?)?
        if operation == .literal {
            guard request.names.count == 4 else { throw SILError.invalid("\(entry.name) of unexpected shape at \(request.id)") }
            if let text = stringTexts[request.names[0]] { literal = (text, c.constantValue(try scalar(request.names[1]))) }
        }
        let handles = operation == .literal ? [] : try textOperands(entry, request)
        let (value, exact) = try StdlibSummary.textResult(operation, name: entry.name, handles: handles, literal: literal, in: c)
        if operation == .append || operation == .appendLiteral {
            guard request.type.leafWidths.isEmpty else { throw SILError.invalid("\(entry.name) with a result at \(request.id)") }
            try writeBack([value], names: request.names, conventions: request.conventions)
            env[request.id] = make(request.type, [])
        } else {
            guard request.type.leafWidths == [value.width] else {
                throw SILError.invalid("\(entry.name): result type at \(request.id)")
            }
            env[request.id] = make(request.type, [value])
        }
        if !exact { out.approximations.insert(entry.name) }
    }

    /// `StdlibSummary.range`: a test gives an exact Boolean, a partial-range initializer an exact bound.
    func applyRange(_ operation: StdlibSummary.RangeOperation, _ entry: StdlibSummary.Entry, _ request: SummarizedCall) throws {
        let read = try zip(request.names, request.conventions).filter { $0.1 == .indirect }.map { try slotValue($0.0).leaves }
        if case .make(let shape) = operation {
            let bound = try StdlibSummary.partialRange(
                shape, name: entry.name, subject: entry.subject(of: request.substitutions), read: read)
            // Written straight into the `@out` address: no placeholder values, so the circuit stays a function of its inputs.
            guard request.conventions.first == .out, request.type.leafWidths.isEmpty else {
                throw SILError.invalid("\(entry.name) without its result address at \(request.id)")
            }
            try writeBack(bound, names: request.names, conventions: request.conventions)
            return env[request.id] = make(request.type, [])
        }
        let test = try StdlibSummary.rangeTest(operation, name: entry.name, substitutions: request.substitutions, read: read, in: c)
        guard request.type.leafWidths == [1] else { throw SILError.invalid("\(entry.name) of unexpected shape at \(request.id)") }
        env[request.id] = make(request.type, [BV(bits: [test])])
    }

    /// `StdlibSummary.recordsAccess`: the call changes nothing logic models and returns nothing.
    func recordAccess(_ entry: StdlibSummary.Entry, _ request: SummarizedCall) throws {
        guard module.trustsRecordedAccess else {
            throw SILError.unsupported(
                "\(entry.name): a read module refers to IssueReporting's reporters, and a fatal-error reporter makes it trap")
        }
        guard request.type.leafWidths.isEmpty, request.conventions.allSatisfy({ $0 == .value || $0 == .indirect }) else {
            throw SILError.invalid("\(entry.name) with a result or a written argument")
        }
        // `access(subject, keyPath:)` on `self`. Observation hashes the key path, which runs the `hash(into:)` of
        // any value it captured.
        guard request.names.count == 3, literalKeyPaths.contains(request.names[1]) else {
            throw SILError.unsupported("\(entry.name) with a key path that is not a key path literal of this function")
        }
        env[request.id] = make(request.type, [])
    }

    /// Binds the results of a summarized call: `exact` for the `@out` result when known, fresh values otherwise.
    func summaryResults(_ entry: StdlibSummary.Entry, _ request: SummarizedCall, exact: [BV]?) throws {
        let result = unknown(request.type)
        var back: [BV] = []
        for (name, convention) in zip(request.names, request.conventions) where convention == .out || convention == .inout {
            back += unknown(try slot(name).type)
        }
        if let exact {
            guard request.conventions.first == .out, back.count == exact.count else {
                throw SILError.invalid("\(entry.name) without its result address")
            }
            back = exact
        }
        try writeBack(back, names: request.names, conventions: request.conventions)
        env[request.id] = make(request.type, result)
        if exact == nil { out.approximations.insert(entry.name) }
    }

    /// The `RawRepresentable` default `hash(into:)` is `hasher.combine(rawValue)` (`CompilerProtocols.swift`):
    /// runs the type's rawValue getter, then hashes what it returned, which runs the raw value's own `hash(into:)`.
    func hashRawValue(_ type: String, _ value: [BV], site: String) throws {
        guard let getter = module.witness(type: type, requirement: "#RawRepresentable.rawValue!getter") else {
            throw SILError.unsupported("hashing \(type): no rawValue witness in this module")
        }
        let raw = try call(getter, value, at: site)
        // A witness thunk returns the associated type through its `@out` address, which comes back first.
        let getterFunction = try module.function(getter)
        if let indirect = getterFunction.indirectResult {
            try hashValue(of: indirect, Array(raw.writtenBack.prefix(indirect.leafWidths.count)), when: c.trueLit)
        } else {
            try hashValue(of: getterFunction.resultType, raw.results, when: c.trueLit)
        }
    }

    /// Runs the user code that hashing a value of layout `type` runs. Scalars and standard opaque values run none.
    func hashValue(of type: ValueType, _ value: [BV], when condition: Int32) throws {
        switch type {
        case .scalar: return
        case .opaque(let name):
            guard module.hasLibraryConformance(name) else { throw SILError.unsupported("hashing \(name)") }
        case .array(let element): try hash("Array<\(element.text)>", value, when: condition)
        case .hashed(let collection): try hash(collection.description, value, when: condition)
        case .aggregate(let name, let fields) where name.isEmpty:
            guard fields.isEmpty else { throw SILError.unsupported("hashing a tuple") }
        case .aggregate(let name, _), .enumeration(let name, _):
            try hash(name, value, when: condition)
        }
    }

    /// Runs the user code that hashing a `type` value runs: its `hash(into:)` witness, through Optionals.
    func hash(_ type: String, _ value: [BV], when condition: Int32) throws {
        if module.hasLibraryConformance(type) { return }
        if let wrapped = StdlibSummary.optionalWrapped(type) {
            let layout = try module.resolve(type)
            let some = c.eq(value[0], c.constant(1, width: value[0].width))
            return try hash(wrapped, Array(value[layout.payloadLeafRange(ofCase: 1)]), when: c.and(condition, some))
        }
        if let contents = HashedCollection.contents(of: type) {
            // Each element (key, value) is hashed: run its code on an unknown one, if there is one.
            let nonEmpty = c.and(condition, -c.eq(value[0], c.constant(0, width: 64)))
            out.approximations.insert(contents.name)
            return try contents.types.forEach {
                try hash($0, fresh(try module.resolve($0)), when: c.and(nonEmpty, c.input(width: 1).bits[0]))
            }
        }
        guard let witness = module.witness(type: type, requirement: "#Hashable.hash") else {
            throw SILError.unsupported("hashing \(type): no Hashable witness in this module")
        }
        let thunk = try module.function(witness)
        guard thunk.parameterTypes.count == 2, thunk.parameterTypes[0] == .opaque(name: "Hasher") else {
            throw SILError.unsupported("Hashable witness \(witness) of unexpected shape")
        }
        _ = try call(witness, [c.input(width: 64)] + value, at: nil, when: condition)
    }

    /// Runs the user code that printing a `type` value may run: its `description` and `debugDescription`.
    func describe(_ type: String, _ value: [BV], when condition: Int32) throws {
        if module.hasLibraryConformance(type) { return }
        if let wrapped = StdlibSummary.optionalWrapped(type) {
            let layout = try module.resolve(type)
            let some = c.eq(value[0], c.constant(1, width: value[0].width))
            return try describe(wrapped, Array(value[layout.payloadLeafRange(ofCase: 1)]), when: c.and(condition, some))
        }
        if let contents = HashedCollection.contents(of: type) {
            // Each element (key, value) is printed: run its code on an unknown one, if there is one.
            let nonEmpty = c.and(condition, -c.eq(value[0], c.constant(0, width: 64)))
            out.approximations.insert(contents.name)
            return try contents.types.forEach {
                try describe($0, fresh(try module.resolve($0)), when: c.and(nonEmpty, c.input(width: 1).bits[0]))
            }
        }
        guard module.witness(type: type, requirement: "#TextOutputStreamable.write") == nil else {
            throw SILError.unsupported("printing \(type), which writes itself to a stream")
        }
        guard !SILModule.printingRequirements.contains(where: { module.mayHaveUnknownWitness(type: type, requirement: $0) }) else {
            throw SILError.unsupported("printing \(type), whose generic conformance logic does not call")
        }
        var described = false
        for requirement in ["#CustomStringConvertible.description!getter", "#CustomDebugStringConvertible.debugDescription!getter"] {
            guard let witness = module.witness(type: type, requirement: requirement) else { continue }
            described = true
            _ = try call(witness, value, at: nil, when: condition)
        }
        if described { return }
        guard module.witness(type: type, requirement: "#CustomReflectable.customMirror!getter") == nil else {
            throw SILError.unsupported("printing \(type), which has a custom mirror")
        }
        for part in try module.resolve(type).printedParts() {
            let active = part.cases.reduce(condition) {
                c.and($0, c.eq(value[$1.tag], c.constant(UInt64($1.index), width: value[$1.tag].width)))
            }
            try describe(part.type, Array(value[part.leaves]), when: active)
        }
    }
}

import Foundation

// Mutants for `sfverify --mutate` (is a proved contract strong enough?). Each mutant is one small edit of the SIL text
// of the scanned function, or of a closure it calls directly (`@Verify` runs the body in one): skip a call that
// changes `self`, drop a write to a field of an `inout` parameter, return another value of the result type, negate a
// branch, change an operator or a constant. The edit keeps the SIL well-formed; a mutant the reader still refuses is
// dropped by the caller. Mutants never change a verdict: they only ask whether the contract also holds for code that
// does something else.
//
// The checks `@Verify` writes into a function are not edited: a `#requires` condition, an `#ensures` closure and the
// call of it change the contract, not what the function does. They are found by their shape, so also after `-O`
// inlined the closures: a value is a check when every use of it is a branch into a `Contract.requiresFailed` /
// `ensuresFailed` call, or makes another value that is a check.

/// One small edit of a function's SIL body.
package struct SILMutant: Sendable, Equatable {
    /// What the edit does.
    package enum Kind: String, Sendable, Equatable {
        /// A call that changes an `inout` parameter (a `mutating` method of `self`) is skipped.
        case skippedCall
        /// A write to (a field of) an `inout` parameter is dropped.
        case droppedWrite
        /// The function returns another value of its result type: a parameter or a constant.
        case returnedValue
        /// The two targets of a conditional branch are swapped.
        case negatedBranch
        /// Two cases of a `switch` go to each other's code.
        case swappedCases
        /// An arithmetic or comparison operator is replaced by a neighbour (`<` by `<=`, `+` by `-`).
        case changedOperator
        /// An integer constant is changed by one.
        case changedConstant
    }

    /// The function whose body is edited: the scanned function or a closure it calls.
    package let symbol: String
    /// The edited line, an index into `SILModule.bodyLines(of: symbol)`.
    package let line: Int
    /// The lines that replace it (one line, or a few for a returned constant).
    package let replacement: [String]
    package let kind: Kind
    /// What the edit does, for a person: `the call to State.show(_:) is skipped`.
    package let description: String
    /// The original line.
    package let original: String
    /// A value defined on the edited source line (the call's result, the written address, the returned value, the
    /// branch condition), for placing the edit with the debug info; nil when there is none.
    package var anchor: String?

    /// `module` with this edit applied, nil when the body is not there or has changed.
    package func applied(to module: SILModule) -> SILModule? {
        guard var lines = module.bodyLines(of: symbol), line < lines.count, lines[line] == original else { return nil }
        lines.replaceSubrange(line...line, with: replacement)
        return module.replacingBody(of: symbol, with: lines)
    }
}

extension SILModule {
    /// The mutants of `symbol` and of the closures its body references (`...fU_`), most telling kinds first, at most
    /// `limit`. Empty for a generic function or one without a body.
    package func mutants(of symbol: String, limit: Int = 16) -> [SILMutant] {
        guard let body = bodyLines(of: symbol) else { return [] }
        let checks = header(of: symbol).flatMap { MutationSite(symbol: symbol, header: $0, lines: body) }?.checkValues ?? []
        var targets = [symbol]
        for line in body {
            guard let r = line.range(of: "function_ref @") else { continue }
            let callee = String(line[r.upperBound...].prefix { $0 != " " })
            // A closure whose result is only checked (an `#ensures` closure `@Verify` calls on the result) is the contract.
            let reference = MutationText.definedValue(line)
            if let reference, MutationChecks.calls(of: reference, in: body).allSatisfy({ checks.contains($0) }),
                !MutationChecks.calls(of: reference, in: body).isEmpty
            {
                continue
            }
            if callee.firstMatch(of: /fU[0-9]*_/) != nil, !targets.contains(callee), bodyLines(of: callee) != nil {
                targets.append(callee)
            }
        }
        var all: [SILMutant] = []
        for target in targets {
            guard let lines = bodyLines(of: target), let header = header(of: target) else { continue }
            all += MutationSite(symbol: target, header: header, lines: lines)?.mutants() ?? []
        }
        let order: [SILMutant.Kind] = [
            .skippedCall, .droppedWrite, .returnedValue, .negatedBranch, .swappedCases, .changedOperator, .changedConstant,
        ]
        let sorted = order.flatMap { kind in all.filter { $0.kind == kind } }
        return Array(sorted.prefix(limit))
    }
}

/// One body read for mutation: its entry parameters, address chains and blocks.
struct MutationSite {
    let symbol: String
    let lines: [String]
    /// Entry-block parameters (`%0`) that are `inout` (or captured `inout_aliasable`) addresses.
    let inoutParameters: Set<String>
    /// Entry-block parameters passed by value, with their type as printed (`Int8`).
    let valueParameters: [(name: String, type: String)]
    /// The direct result type as printed in the header (`Int8`, `()`).
    let resultType: String
    /// Debug names of values: `%0` -> `self`.
    let names: [String: String]
    /// For each address made by `begin_access`, `struct_element_addr` or `tuple_element_addr`: its base and the field.
    let bases: [String: (base: String, field: String?)]
    /// The block each line is in, and the lines of each block.
    let blockOfLine: [String]
    let blockLines: [String: [Int]]
    /// The parameter types of each block (a payload case's target takes the payload).
    let blockParameterTypes: [String: [String]]
    /// The values that only feed a `@Verify` check (see the top of the file): their lines are not edited.
    private(set) var checkValues: Set<String> = []

    init?(symbol: String, header: String, lines: [String]) {
        guard let signature = MutationText.signature(header) else { return nil }
        self.symbol = symbol
        self.lines = lines
        resultType = signature.result
        var names: [String: String] = [:]
        var bases: [String: (base: String, field: String?)] = [:]
        var blockOfLine: [String] = []
        var blockLines: [String: [Int]] = [:]
        var blockParameterTypes: [String: [String]] = [:]
        var entry: [(name: String, type: String)] = []
        var current = ""
        for (index, line) in lines.enumerated() {
            if let named = MutationText.debugName(line) { names[named.value] = named.name }
            if let label = MutationText.blockLabel(line) {
                current = label
                blockParameterTypes[label] = MutationText.blockParameters(line).map(\.type)
                if label == "bb0" { entry = MutationText.blockParameters(line) }
            }
            blockOfLine.append(current)
            blockLines[current, default: []].append(index)
            if let address = Self.address(MutationText.code(line)) { bases[address.result] = address.step }
        }
        guard let (addresses, values) = Self.parameters(entry, signature.parameters) else { return nil }
        inoutParameters = addresses
        valueParameters = values
        self.names = names
        self.bases = bases
        self.blockOfLine = blockOfLine
        self.blockLines = blockLines
        self.blockParameterTypes = blockParameterTypes
        checkValues = MutationChecks(lines: lines, blockLines: blockLines).values(
            failing: { [self] label in callsContractFailure(label) || callsContractFailure(destination(label)) })
    }

    /// `%3 = struct_element_addr %2, #State.data` gives (`%3`, (`%2`, `data`)); `begin_access` gives no field.
    private static func address(_ code: String) -> (result: String, step: (base: String, field: String?))? {
        guard let eq = code.range(of: " = ") else { return nil }
        let result = String(code[..<eq.lowerBound]).trimmingCharacters(in: .whitespaces)
        let rhs = code[eq.upperBound...]
        if rhs.hasPrefix("begin_access "), let source = rhs.split(separator: " ").last { return (result, (String(source), nil)) }
        guard rhs.hasPrefix("struct_element_addr ") || rhs.hasPrefix("tuple_element_addr ") else { return nil }
        let operands = splitTopLevel(String(rhs.drop { $0 != " " }))
        guard operands.count == 2 else { return nil }
        return (result, (operands[0], operands[1].split(separator: ".").last.map(String.init) ?? operands[1]))
    }

    /// The `inout` entry parameters and the by-value ones (with their types). The header's parameters are the last
    /// entry parameters; any before them are `@out` result addresses.
    private static func parameters(
        _ entry: [(name: String, type: String)], _ header: [String]
    ) -> (addresses: Set<String>, values: [(name: String, type: String)])? {
        let offset = entry.count - header.count
        guard offset >= 0 else { return nil }
        var addresses: Set<String> = []
        var values: [(name: String, type: String)] = []
        for (position, parameter) in header.enumerated() {
            let (name, type) = entry[offset + position]
            if parameter.hasPrefix("@inout ") || parameter.hasPrefix("@inout_aliasable ") {
                addresses.insert(name)
            } else if !type.hasPrefix("*") {
                values.append((name, type))
            }
        }
        return (addresses, values)
    }

    func mutants() -> [SILMutant] {
        var result: [SILMutant] = []
        for (index, line) in lines.enumerated() where !definesCheck(index) {
            let code = MutationText.code(line).trimmingCharacters(in: .whitespaces)
            if let m = skippedCall(index, line, code) { result.append(m) }
            if let m = droppedWrite(index, line, code) { result.append(m) }
            result += returnedValues(index, line, code)
            if let m = negatedBranch(index, line, code) { result.append(m) }
            result += swappedCases(index, line, code)
        }
        for spec in SILVerifier.mutations(of: lines) where !spec.description.hasPrefix("swap branch") {
            guard !inContractCheck(spec.line), !definesCheck(spec.line) else { continue }
            let kind: SILMutant.Kind = spec.description.hasPrefix("literal") ? .changedConstant : .changedOperator
            result.append(
                SILMutant(
                    symbol: symbol, line: spec.line, replacement: [spec.replacementLine], kind: kind,
                    description: MutationText.describe(spec.description), original: lines[spec.line],
                    anchor: Self.definedValue(lines[spec.line])))
        }
        return result
    }

    // MARK: operators

    /// `%11 = apply %10(%7, %9) : $... (Values, @inout State) -> ()` with `%9` an access to an `inout` parameter
    /// becomes `%11 = tuple ()`.
    private func skippedCall(_ index: Int, _ line: String, _ code: String) -> SILMutant? {
        guard let eq = code.range(of: " = apply "), code.hasSuffix("-> ()"), code.contains("@inout"),
            let open = code.firstIndex(of: "("), open > eq.upperBound
        else { return nil }
        let callee = String(code[eq.upperBound..<open]).split(separator: " ").last.map(String.init) ?? ""
        guard let close = MutationText.matchingParen(code, from: open) else { return nil }
        let arguments = splitTopLevel(String(code[code.index(after: open)..<close]))
        guard arguments.contains(where: { inoutParameters.contains(root($0)) }), !inContractCheck(index) else { return nil }
        let result = String(code[..<eq.lowerBound])
        let indent = String(line.prefix { $0 == " " })
        let name = calleeName(callee, before: index)
        // `@Verify` runs the body as `let __sf_result = { … }()`: skipping that closure skips the whole body.
        let description =
            name.hasPrefix("closure #")
            ? "\(name) is skipped (under @Verify, the whole body)" : "the call to \(name) is skipped"
        return SILMutant(
            symbol: symbol, line: index, replacement: [indent + result + " = tuple ()" + MutationText.location(line)], kind: .skippedCall,
            description: description, original: line, anchor: result)
    }

    /// `store %4 to %6` (or `copy_addr %a to %6`) where `%6` is (a field of) an `inout` parameter: the line is dropped.
    /// A `[init]` store is kept: memory it initializes would be read uninitialized.
    private func droppedWrite(_ index: Int, _ line: String, _ code: String) -> SILMutant? {
        guard code.hasPrefix("store ") || code.hasPrefix("copy_addr "), !code.contains("[init]"),
            let to = code.range(of: " to ", options: .backwards)
        else { return nil }
        let destination = code[to.upperBound...].split(separator: " ").last.map(String.init) ?? ""
        let base = root(destination)
        guard inoutParameters.contains(base), !inContractCheck(index) else { return nil }
        let path = fieldPath(destination)
        let target = ([names[base] ?? "the inout parameter"] + path).joined(separator: ".")
        let indent = String(line.prefix { $0 == " " })
        // A comment line keeps the line count, so the other mutants' line numbers stay valid.
        return SILMutant(
            symbol: symbol, line: index, replacement: [indent + "// sfverify --mutate: dropped " + code], kind: .droppedWrite,
            description: "the write to \(target) is dropped", original: line, anchor: destination)
    }

    /// `return %7` becomes `return %0` for each parameter `%0` of the result type, and `return <constant>` for an
    /// integer or `Bool` result.
    private func returnedValues(_ index: Int, _ line: String, _ code: String) -> [SILMutant] {
        guard code.hasPrefix("return "), resultType != "()" else { return [] }
        let returned = code.dropFirst("return ".count).prefix { $0 != " " && $0 != "," }
        let indent = String(line.prefix { $0 == " " })
        let loc = MutationText.location(line)
        var result: [SILMutant] = []
        for parameter in valueParameters where parameter.type == resultType && parameter.name != returned {
            result.append(
                SILMutant(
                    symbol: symbol, line: index, replacement: [indent + "return " + parameter.name + loc], kind: .returnedValue,
                    description: "it returns \(names[parameter.name] ?? parameter.name) instead", original: line,
                    anchor: String(returned)))
        }
        guard let width = MutationText.integerWidths[resultType] else { return result }
        let constants: [(UInt64, String)] = resultType == "Bool" ? [(0, "false"), (1, "true")] : [(0, "0")]
        let fresh = nextValueNumber()
        for (value, text) in constants {
            let literal = "%\(fresh)", wrapped = "%\(fresh + 1)"
            result.append(
                SILMutant(
                    symbol: symbol, line: index,
                    replacement: [
                        indent + "\(literal) = integer_literal $Builtin.Int\(width), \(value)" + loc,
                        indent + "\(wrapped) = struct $\(resultType) (\(literal))" + loc,
                        indent + "return \(wrapped)" + loc,
                    ],
                    kind: .returnedValue, description: "it returns \(text) instead", original: line, anchor: String(returned)))
        }
        return result
    }

    /// `cond_br %c, bb1, bb2` becomes `cond_br %c, bb2, bb1`. Branches into a `@Verify` check are left alone.
    private func negatedBranch(_ index: Int, _ line: String, _ code: String) -> SILMutant? {
        guard code.hasPrefix("cond_br ") else { return nil }
        let parts = splitTopLevel(String(code.dropFirst("cond_br ".count)))
        guard parts.count == 3, parts[1].hasPrefix("bb"), parts[2].hasPrefix("bb") else { return nil }
        let targets = [parts[1], parts[2]].map { String($0.prefix { $0 != "(" }) }
        guard !targets.contains(where: callsContractFailure), !inContractCheck(index),
            parts[1].contains("(") || parts[2].contains("(") || destination(targets[0]) != destination(targets[1])
        else { return nil }
        let indent = String(line.prefix { $0 == " " })
        return SILMutant(
            symbol: symbol, line: index,
            replacement: [indent + "cond_br \(parts[0]), \(parts[2]), \(parts[1])" + MutationText.location(line)],
            kind: .negatedBranch, description: "the condition of this branch is negated", original: line, anchor: parts[0])
    }

    // MARK: helpers

    /// The parameter an address is derived from, through `begin_access` and element addresses.
    private func root(_ value: String) -> String {
        var current = value
        var steps = 0
        while let next = bases[current], steps < 64 {
            current = next.base
            steps += 1
        }
        return current
    }

    /// The fields from the root to `value`: `["altitudeText"]`.
    private func fieldPath(_ value: String) -> [String] {
        var path: [String] = []
        var current = value
        while let next = bases[current], path.count < 64 {
            if let field = next.field { path.insert(field, at: 0) }
            current = next.base
        }
        return path
    }

    /// `State.show(_:)` from the `// function_ref State.show(_:)` comment before the callee's `function_ref`.
    private func calleeName(_ callee: String, before index: Int) -> String {
        for i in stride(from: index - 1, through: 0, by: -1) {
            let code = MutationText.code(lines[i]).trimmingCharacters(in: .whitespaces)
            guard code.hasPrefix(callee + " = function_ref @") else { continue }
            if i > 0, let r = lines[i - 1].range(of: "// function_ref ") { return String(lines[i - 1][r.upperBound...]) }
            return String(code.dropFirst((callee + " = function_ref @").count).prefix { $0 != " " })
        }
        return callee
    }

    /// Where control goes from block `label` after blocks that only branch on (`bb2: br bb4`): two targets with the
    /// same destination do the same thing, so swapping them is no edit.
    func destination(_ label: String) -> String {
        var current = label
        var seen: Set<String> = []
        while seen.insert(current).inserted, blockParameterTypes[current]?.isEmpty ?? false {
            let code = (blockLines[current] ?? []).map { MutationText.code(lines[$0]) }
                .filter { !$0.isEmpty && MutationText.blockLabel($0) == nil }
            guard code.count == 1, code[0].hasPrefix("br bb"), !code[0].contains("(") else { break }
            current = String(code[0].dropFirst("br ".count))
        }
        return current
    }

    /// Whether the block `label` calls `Contract.requiresFailed` / `ensuresFailed` (a `@Verify` check failing).
    func callsContractFailure(_ label: String) -> Bool {
        (blockLines[label] ?? []).contains { ContractFailureCall.kind(of: lines[$0]) != nil }
    }

    /// Whether line `index` makes a value that only feeds a `@Verify` check, or branches on one.
    func definesCheck(_ index: Int) -> Bool {
        guard index < lines.count else { return false }
        if let value = MutationText.definedValue(lines[index]) { return checkValues.contains(value) }
        let code = MutationText.code(lines[index])
        guard code.hasPrefix("cond_br ") else { return false }
        let condition = splitTopLevel(String(code.dropFirst("cond_br ".count))).first ?? ""
        return checkValues.contains(condition)
    }

    /// Whether line `index` is in a block that fails a `@Verify` check or ends in `unreachable`: editing it only
    /// changes how a failure is reported.
    func inContractCheck(_ index: Int) -> Bool {
        guard index < blockOfLine.count else { return false }
        let block = blockOfLine[index]
        return callsContractFailure(block)
            || (blockLines[block] ?? []).contains { MutationText.code(lines[$0]).trimmingCharacters(in: .whitespaces) == "unreachable" }
    }

    /// `%5` for `%5 = builtin …`.
    private static func definedValue(_ line: String) -> String? {
        let code = MutationText.code(line)
        guard code.hasPrefix("%"), let eq = code.range(of: " = ") else { return nil }
        return String(code[..<eq.lowerBound])
    }

    /// One more than the largest `%N` in the body.
    private func nextValueNumber() -> Int {
        var largest = 0
        for line in lines {
            for match in line.matches(of: /%([0-9]+)/) { largest = max(largest, Int(match.1) ?? 0) }
        }
        return largest + 1
    }

}

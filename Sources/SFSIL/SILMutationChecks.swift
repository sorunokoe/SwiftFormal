import Foundation

/// The values of one body that only feed a `@Verify` check, which `SILModule.mutants(of:limit:)` leaves alone: an edit
/// of a `#requires` condition, of an `#ensures` closure or of the call of it changes the contract, not what the function
/// does.
///
/// A value is a check when every use of it is a branch into a `Contract.requiresFailed` / `ensuresFailed` call, or an
/// instruction that only computes another check value from it (an operator, a field, a literal, a call that writes
/// nothing through `inout`, a branch that passes it to a block whose parameter is a check value). The blocks of an `&&`
/// or `||` in a condition count when they only compute check values. The shape is found from the uses back, so it is
/// found also after `-O` inlined the closures.
struct MutationChecks {
    let lines: [String]
    let blockLines: [String: [Int]]

    /// The lines that use each value.
    private var users: [String: [Int]] = [:]
    /// The line that defines each value; for a block parameter, the block's label line.
    private var definer: [String: Int] = [:]
    /// The parameter values of each block.
    private var parameters: [String: [String]] = [:]

    init(lines: [String], blockLines: [String: [Int]]) {
        self.lines = lines
        self.blockLines = blockLines
        for (index, line) in lines.enumerated() {
            if let label = MutationText.blockLabel(line) {
                let names = MutationText.blockParameters(line).map(\.name)
                parameters[label] = names
                for name in names { definer[name] = index }
                continue
            }
            let defined = MutationText.definedValue(line)
            if let defined { definer[defined] = index }
            for match in MutationText.code(line).matches(of: /%[0-9]+/) where String(match.output) != defined {
                users[String(match.output), default: []].append(index)
            }
        }
    }

    /// The check values; `failing` says whether a block (or where it leads) calls a contract failure.
    func values(failing: (String) -> Bool) -> Set<String> {
        var checks: Set<String> = []
        var changed = true
        while changed {
            changed = false
            for (value, uses) in users where !checks.contains(value) && canBeCheck(value) {
                if uses.allSatisfy({ isCheckUse($0, of: value, checks: checks, failing: failing) }) {
                    checks.insert(value)
                    changed = true
                }
            }
        }
        return checks
    }

    /// A value made by an instruction that only computes, or a block parameter other than the function's inputs.
    private func canBeCheck(_ value: String) -> Bool {
        guard let line = definer[value] else { return false }
        if let label = MutationText.blockLabel(lines[line]) { return label != "bb0" }
        return Self.passesThrough(MutationText.code(lines[line]))
    }

    private func isCheckUse(_ index: Int, of value: String, checks: Set<String>, failing: (String) -> Bool) -> Bool {
        let code = MutationText.code(lines[index])
        if code.hasPrefix("debug_value ") { return true }
        if code.hasPrefix("cond_br ") {
            let parts = splitTopLevel(String(code.dropFirst("cond_br ".count)))
            guard parts.count == 3, parts[0] == value else { return false }
            let targets = [parts[1], parts[2]].map { String($0.prefix { $0 != "(" }) }
            if !parts[1].contains("("), !parts[2].contains("("), targets.contains(where: failing) { return true }
            return targets.allSatisfy { isCheckBlock($0, checks: checks) }
        }
        if code.hasPrefix("br "), let arguments = Self.branchArguments(code) {
            let names = parameters[String(code.dropFirst("br ".count).prefix { $0 != "(" })] ?? []
            return arguments.indices.allSatisfy { arguments[$0] != value || ($0 < names.count && checks.contains(names[$0])) }
        }
        return MutationText.definedValue(lines[index]).map { checks.contains($0) } ?? false
    }

    /// A block that only computes a check and passes it on: each of its instructions makes a check value, and it ends
    /// in a branch that passes only check values (`br bb5(%20)`) or that branches on one.
    private func isCheckBlock(_ label: String, checks: Set<String>) -> Bool {
        let body = (blockLines[label] ?? []).filter { MutationText.blockLabel(lines[$0]) == nil && !MutationText.code(lines[$0]).isEmpty }
        guard let last = body.last else { return false }
        for index in body.dropLast() {
            let code = MutationText.code(lines[index])
            if code.hasPrefix("debug_value ") || code == "debug_step" { continue }
            guard let value = MutationText.definedValue(lines[index]), checks.contains(value) else { return false }
        }
        let end = MutationText.code(lines[last])
        if end.hasPrefix("cond_br ") { return checks.contains(splitTopLevel(String(end.dropFirst("cond_br ".count))).first ?? "") }
        guard end.hasPrefix("br "), let arguments = Self.branchArguments(end) else { return false }
        return !arguments.isEmpty && arguments.allSatisfy { checks.contains($0) }
    }

    /// `[%11]` for `br bb3(%11)`; nil for a branch that passes nothing.
    private static func branchArguments(_ code: String) -> [String]? {
        guard let open = code.firstIndex(of: "("), let close = MutationText.matchingParen(code, from: open) else { return nil }
        return splitTopLevel(String(code[code.index(after: open)..<close]))
    }

    /// Instructions that only compute a value from their operands: what a condition is made of. A call counts unless it
    /// takes an `inout` argument; a closure's capture of `self` (`@inout_aliasable`, how a `mutating` method's
    /// `#ensures` closure reads `self`) counts.
    private static func passesThrough(_ code: String) -> Bool {
        guard let eq = code.range(of: " = ") else { return false }
        let rhs = code[eq.upperBound...]
        if rhs.hasPrefix("apply ") || rhs.hasPrefix("try_apply ") { return !rhs.contains("@inout ") }
        let pure = [
            "builtin ", "struct_extract ", "struct ", "tuple_extract ", "tuple ", "integer_literal ", "enum ", "select_enum ",
            "unchecked_enum_data ", "function_ref ", "thin_to_thick_function ", "metatype ", "load ",
        ]
        return pure.contains { rhs.hasPrefix($0) }
    }

    /// The values defined by the lines of `body` that call the function value `reference` (`%31 = apply %30(…)`).
    static func calls(of reference: String, in body: [String]) -> [String] {
        body.compactMap { line in
            let code = MutationText.code(line)
            guard code.contains(" = apply \(reference)(") || code.contains(" = apply \(reference)<") else { return nil }
            return MutationText.definedValue(line)
        }
    }
}

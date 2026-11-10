import Foundation

// Reading guide
// Classes, narrow (plan item L5). A `final class` of a read module, with no superclass, no protocol conformance, no
// `deinit` and stored properties of types logic reads, is modelled as its stored properties: the object is a stack
// slot of its own (an `alloc_ref` allocates one, uninitialized), a reference is the address of that slot, and
// `ref_element_addr` is the address of one field, as `struct_element_addr` is for a struct.
//
// That is exact only while each object has one reference in the code logic reads, so every other way to get a second
// reference is refused: a class type anywhere but directly as a parameter, a result or a local value (inside a
// struct, tuple, enum, Optional, array or existential it does not resolve), two class parameters, class-typed fields,
// globals of class type, `upcast`, `class_method`, `weak`/`unowned` (Optional of a class), and storing a reference.
//
// - A class parameter is passed like an `inout` parameter of its fields: the callee gets their values and gives
//   back the final ones (`SILFunction.objectParameter`).
// - A class result is either the callee's own parameter (an initializer returns its `self`), which the caller binds
//   to the object it passed, or an object the callee created, which the caller gets as a new slot
//   (`EncodedFunction.objectResult`). Anything else is refused.
// - At -Onone every field access is `begin_access [dynamic]`: a runtime exclusivity check. It is accepted only on a
//   class field address, and only where it cannot fail: not while another access to a class field is open (unless
//   both read), not across blocks, and not around a call that passes an object (`checkDynamicAccesses`). Whether a
//   caller holds an access to a parameter's object is unknown, so a function with a class parameter is never proved
//   `safe` (decision 6; `SFVerifyKit`).
// - Releases are ignored: no `deinit` of the read modules runs code (`deinitsMayRunCode`; SIL prints `@objc deinit` for
//   every class, so the bodies decide), and the fields destroy without code of the read modules.
// - `alloc_ref` makes a slot whose fields hold unknown values until the initializer stores them.
//
// Tests: Tests/SFSILTests/SILClassTests.swift; zoo cases in Tests/SFOracleTests/ScanZooTests.swift.

extension TypeContext {
    /// Records the declaration of class `name` (`line` is its first line). Every class is also `rejected`, so a class
    /// type that is not directly a parameter, result or local value never resolves.
    mutating func declareClass(_ name: String, line: String, generic: Bool, hasDeinit: Bool, fields: [(name: String, type: String)]) {
        let header = line.trimmingCharacters(in: .whitespaces)
        let shortName = name.split(separator: ".").last.map(String.init) ?? name
        let afterName = header.range(of: "class " + shortName).map { header[$0.upperBound...] }
        let plain = afterName.map { $0.trimmingCharacters(in: .whitespaces) == "{" } ?? false
        let eligible = header.split(separator: " ").contains("final") && plain && !generic && !hasDeinit
        declare(name) {
            $0.rejected[name] = generic ? "generic class" : "class"
            if eligible { $0.classes[name] = fields }
        }
    }

    /// The layout of a reference to an eligible class: its stored properties. Nil for any other type.
    func objectLayout(_ text: String) -> ValueType? {
        var t = text.trimmingCharacters(in: .whitespaces)
        if t.hasPrefix("$") { t.removeFirst() }
        for convention in ["@owned ", "@guaranteed "] where t.hasPrefix(convention) { t.removeFirst(convention.count) }
        guard let fields = classes[t], !ambiguous.contains(t), !deinitsMayRunCode,
            fields.allSatisfy({ destroysWithoutModuleCode($0.type) }),
            let resolved = try? fields.map({ ValueType.Field(name: $0.name, type: try resolve($0.type, depth: 1)) })
        else { return nil }
        return .aggregate(name: t, fields: resolved)
    }

    /// `objectLayout` when `text` is an eligible class, otherwise `resolve`.
    func resolveObjectOrValue(_ text: String) throws(SILError) -> ValueType {
        if let object = objectLayout(text) { return object }
        return try resolve(text)
    }

    /// The signature's conventions with each class parameter passed like `inout`, and the index of that parameter.
    /// Throws for two class parameters: they could be the same object.
    func objectConventions(_ signature: FunctionSignature) throws(SILError) -> (conventions: [ParameterConvention], object: Int?) {
        var conventions = signature.parameters.map(\.convention)
        let objects = signature.parameters.indices.filter {
            conventions[$0] == .value && objectLayout(signature.parameters[$0].type) != nil
        }
        guard objects.count <= 1 else { throw SILError.unsupported("two class parameters (they may be the same object)") }
        for k in objects { conventions[k] = .inout }
        return (conventions, objects.first)
    }

    /// The class named in `#Counter.count`, when it is an eligible class: its layout and the field's index.
    func objectField(_ reference: String) -> (layout: ValueType, field: Int)? {
        guard reference.hasPrefix("#"), let dot = reference.lastIndex(of: ".") else { return nil }
        let name = String(reference[reference.index(after: reference.startIndex)..<dot])
        guard let layout = objectLayout(name), case .aggregate(_, let fields) = layout,
            let index = fields.firstIndex(where: { $0.name == String(reference[reference.index(after: dot)...]) })
        else { return nil }
        return (layout, index)
    }
}

extension SILEncoder {
    /// For a function that returns an object, whether every return gives back its class parameter's object (true) or
    /// every one a new object (false); mixed returns are refused. False for any other function.
    func objectResultIsParameter(_ function: SILFunction, _ out: RunOutput) throws -> Bool {
        guard function.returnsObject else { return false }
        let kinds = Set(out.returns.map(\.objectIsParameter))
        guard kinds.count <= 1 else {
            throw SILError.unsupported("\(function.symbol) returns its parameter's object on some paths only")
        }
        return kinds.first ?? false
    }
}

/// The instructions that make and use objects of eligible classes; nil for any other instruction.
func parseObjectInstruction(_ line: String, types: TypeContext, dynamicAccesses: Set<String>) throws(SILError) -> Instruction? {
    guard let d = Definition(line) else { return nil }
    switch d.head {
    case "ref_element_addr":
        guard isValue(d.operand), let (layout, field) = types.objectField(line.components(separatedBy: ", ").last ?? "") else {
            return nil
        }
        return .elementAddress(result: d.result, base: d.operand, field: field, expected: .type(layout))
    case "alloc_ref":
        return types.objectLayout(d.operand).map { .allocObject(result: d.result, type: $0) }
    case "end_init_let_ref":
        return isValue(d.operand) ? .alias(result: d.result, source: d.operand) : nil
    case "begin_access":
        return dynamicAccesses.contains(d.result) ? .alias(result: d.result, source: d.operand) : nil
    default:
        return nil
    }
}

/// One `%r = head operand, …` line: its result, instruction and first operand.
private struct Definition {
    let result: String
    let head: String
    let operand: String

    init?(_ line: String) {
        guard let eq = line.range(of: " = ") else { return nil }
        let text = line[eq.upperBound...]
        guard isValue(String(line[..<eq.lowerBound])), let space = text.firstIndex(of: " ") else { return nil }
        result = String(line[..<eq.lowerBound])
        head = String(text[..<space])
        operand = splitTopLevel(dropBracket(String(text[text.index(after: space)...]))).first ?? ""
    }
}

/// The addresses of class fields in `lines`, and their projections.
private func fieldAddresses(_ lines: [String], types: TypeContext) -> Set<String> {
    var addresses: Set<String> = []
    var changed = true
    while changed {
        changed = false
        for line in lines {
            guard let d = Definition(line), !addresses.contains(d.result) else { continue }
            let isField = d.head == "ref_element_addr" && types.objectField(line.components(separatedBy: ", ").last ?? "") != nil
            let projections = ["struct_element_addr", "tuple_element_addr", "begin_access"]
            if isField || (projections.contains(d.head) && addresses.contains(d.operand)) {
                addresses.insert(d.result)
                changed = true
            }
        }
    }
    return addresses
}

/// The `begin_access [dynamic]` results of a function that cannot fail at run time, given that no caller holds an
/// access (see the reading guide). Throws for any other dynamic access: logic does not model the check.
func checkDynamicAccesses(_ groups: [(header: String, lines: [String])], types: TypeContext) throws(SILError) -> Set<String> {
    let lines = groups.flatMap(\.lines)
    guard lines.contains(where: { $0.contains(" = begin_access ") && $0.contains("[dynamic]") }) else { return [] }
    let addresses = fieldAddresses(lines, types: types)
    let classNames = Set(types.classes.keys)
    var allowed: Set<String> = []
    for group in groups {
        var open: [String: Bool] = [:]  // access result -> is a modify
        for line in group.lines {
            if line.hasPrefix("end_access ") {
                open[String(line.dropFirst("end_access ".count))] = nil
            } else if let d = Definition(line), d.head == "begin_access", line.contains("[dynamic]") {
                try openAccess(d, line, addresses: addresses, open: &open)
                allowed.insert(d.result)
            } else if !open.isEmpty, passesAnObject(line, classNames) {
                throw SILError.unsupported("a call that passes an object while one of its fields is accessed: \(line)")
            }
        }
        guard open.isEmpty else { throw SILError.unsupported("an access to a class field open across blocks in \(group.header)") }
    }
    return allowed
}

/// Records the dynamic access `d` in `open`, or throws when it is not on a class field or may conflict with one
/// already open.
private func openAccess(_ d: Definition, _ line: String, addresses: Set<String>, open: inout [String: Bool]) throws(SILError) {
    guard addresses.contains(d.operand) else {
        throw SILError.unsupported("begin_access that is not statically enforced: \(line)")
    }
    let modify = !line.contains("[read]")
    guard open.isEmpty || (!modify && !open.values.contains(true)) else {
        throw SILError.unsupported("overlapping accesses to class fields: \(line)")
    }
    open[d.result] = modify
}

/// Whether `line` is a call whose type mentions one of `classNames` (it may pass an object).
private func passesAnObject(_ line: String, _ classNames: Set<String>) -> Bool {
    let calls = line.contains(" apply ") || line.hasPrefix("try_apply ") || line.contains("= begin_apply ")
    guard calls, let type = line.range(of: " : $") else { return false }
    return classNames.contains { line[type.upperBound...].contains($0) }
}

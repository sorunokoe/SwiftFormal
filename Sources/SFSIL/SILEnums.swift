// Reading guide
// Enums and optionals in the SIL frontend: parsing of the enum instructions and of `switch_enum`, the layout of an
// enum value as leaves (`ValueType.enumeration`: tag first, then every case's payload), and the input assumption
// that a free enum input is a real value (valid tag, zero payload in the cases that are not active).
// The encoder cases themselves live in `SILEncoder.run`; they use the helpers at the end of this file.
// Tests: Tests/SFSILTests/SILEnumTests.swift (differential against native execution).

import Foundation
package import SFBV

// MARK: - layout

extension ValueType {
    /// The index and payload type of case `name`.
    func enumCase(named name: String) throws -> (index: Int, payload: ValueType?) {
        guard case .enumeration(let enumName, let cases) = self else {
            throw SILError.invalid("case \(name) of non-enum type \(self)")
        }
        guard let index = cases.firstIndex(where: { $0.name == name }) else {
            throw SILError.invalid("enum \(enumName) has no case \(name)")
        }
        return (index, cases[index].payload)
    }

    /// The leaf positions of the payload of case `index` (empty for a case without payload).
    package func payloadLeafRange(ofCase index: Int) -> Range<Int> {
        guard case .enumeration(_, let cases) = self else { return 0..<0 }
        let start = 1 + cases[..<index].reduce(0) { $0 + ($1.payload?.leafWidths.count ?? 0) }
        return start..<(start + (cases[index].payload?.leafWidths.count ?? 0))
    }

    /// True when `leaves` (laid out as `leafWidths`) is a value of this type: every enum inside has a tag below
    /// its case count and zero payload leaves in the cases that are not active, and every array count is below 2^48.
    func validity(_ c: CNFBuilder, _ leaves: ArraySlice<BV>) -> Int32 {
        switch self {
        case .scalar, .opaque: return c.trueLit
        // Trusted: no array, dictionary or set holds 2^48 elements or more (TRUST.md); it keeps `count + 1` from overflowing.
        case .array, .hashed: return c.ult(leaves[leaves.startIndex], c.constant(1 << 48, width: 64))
        case .aggregate(_, let fields):
            var ok = c.trueLit
            var offset = leaves.startIndex
            for field in fields {
                let n = field.type.leafWidths.count
                ok = c.and(ok, field.type.validity(c, leaves[offset..<(offset + n)]))
                offset += n
            }
            return c.and(ok, rangeInvariant(c, leaves))
        case .enumeration(_, let cases):
            let tag = leaves[leaves.startIndex]
            var ok = cases.count == 1 << tag.width ? c.trueLit : c.ult(tag, c.constant(UInt64(cases.count), width: tag.width))
            for (k, enumCase) in cases.enumerated() {
                guard let payload = enumCase.payload else { continue }
                let range = payloadLeafRange(ofCase: k)
                let slice = leaves[(leaves.startIndex + range.lowerBound)..<(leaves.startIndex + range.upperBound)]
                let active = c.eq(tag, c.constant(UInt64(k), width: tag.width))
                let zero = slice.reduce(c.trueLit) { c.and($0, c.eq($1, c.constant(0, width: $1.width))) }
                ok = c.and(ok, c.mux(active, payload.validity(c, slice), zero))
            }
            return ok
        }
    }
}

extension SILFunction {
    /// True when the flattened `inputs` are real values of the parameter types. Only enums constrain their leaves;
    /// a proof over all bit patterns would also be sound, but would report counterexamples that cannot happen.
    package func inputAssumption(_ c: CNFBuilder, _ inputs: [BV]) -> Int32 {
        var ok = c.trueLit
        var offset = 0
        for type in parameterTypes {
            let n = type.leafWidths.count
            ok = c.and(ok, type.validity(c, inputs[offset..<(offset + n)]))
            offset += n
        }
        return ok
    }
}

extension SILEncoder {
    /// The leaves of case `index` of `type` with `payload`; the other cases' payload leaves are zero.
    func enumLeaves(_ type: ValueType, case index: Int, payload: [BV]) -> [BV] {
        let widths = type.leafWidths
        var leaves = widths.map { c.constant(0, width: $0) }
        leaves[0] = c.constant(UInt64(index), width: widths[0])
        for (i, bv) in zip(type.payloadLeafRange(ofCase: index), payload) { leaves[i] = bv }
        return leaves
    }

    /// One condition per listed case, then one for `default` if there is one. The conditions are disjoint and
    /// cover every tag: without a default the last listed case also takes the tags no case has (they only occur
    /// in over-approximated loop states), so no path is lost.
    func caseConditions(tag: BV, type: ValueType, listed: [EnumTarget], hasDefault: Bool) throws -> [Int32] {
        guard case .enumeration(let name, let cases) = type else { throw SILError.invalid("switch over non-enum \(type)") }
        let indices = try listed.map { try type.enumCase(named: $0.caseName).index }
        guard Set(indices).count == indices.count else { throw SILError.invalid("duplicate case in a switch over \(name)") }
        guard hasDefault || indices.count == cases.count else {
            throw SILError.invalid("switch over \(name) is not exhaustive and has no default")
        }
        var taken = c.falseLit
        var conditions: [Int32] = []
        for (position, k) in indices.enumerated() {
            let isLast = position == indices.count - 1 && !hasDefault
            let condition = isLast ? -taken : c.and(-taken, c.eq(tag, c.constant(UInt64(k), width: tag.width)))
            conditions.append(condition)
            taken = c.or(taken, condition)
        }
        if hasDefault { conditions.append(-taken) }
        return conditions
    }
}

// MARK: - parsing

/// `#Optional.some!enumelt` gives `some`.
private func caseName(_ reference: String) throws(SILError) -> String {
    let r = reference.trimmingCharacters(in: .whitespaces)
    guard r.hasPrefix("#"), let bang = r.range(of: "!enumelt"), let dot = r[..<bang.lowerBound].lastIndex(of: ".") else {
        throw SILError.invalid("bad enum case reference: \(reference)")
    }
    return String(r[r.index(after: dot)..<bang.lowerBound]).replacingOccurrences(of: "`", with: "")
}

/// `%0` from `%0` or `%0 : $T`.
private func operand(_ text: String) throws(SILError) -> String {
    let value = String(text.trimmingCharacters(in: .whitespaces).prefix { $0 != " " })
    guard isValue(value) else { throw SILError.unsupported("operand: \(text)") }
    return value
}

/// `case #E.a!enumelt: x, ..., default y` (after the subject) gives the cases and the default.
private func enumTargets(_ parts: some Collection<String>) throws(SILError) -> ([EnumTarget], String?) {
    var cases: [EnumTarget] = []
    var fallback: String?
    for part in parts {
        if part.hasPrefix("default ") {
            fallback = String(part.dropFirst("default ".count)).trimmingCharacters(in: .whitespaces)
        } else if part.hasPrefix("case "), let colon = part.range(of: ": ", options: .backwards) {
            let target = String(part[colon.upperBound...]).trimmingCharacters(in: .whitespaces)
            cases.append(EnumTarget(caseName: try caseName(String(part.dropFirst(5)[..<colon.lowerBound])), target: target))
        } else {
            throw SILError.unsupported("enum case list entry: \(part)")
        }
    }
    return (cases, fallback)
}

/// `switch_enum` and `switch_enum_addr`, or nil for any other terminator.
func parseSwitchEnum(_ line: String) throws(SILError) -> Terminator? {
    let isAddress = line.hasPrefix("switch_enum_addr ")
    guard isAddress || line.hasPrefix("switch_enum ") else { return nil }
    let parts = splitTopLevel(String(line.drop { $0 != " " }))
    guard let first = parts.first else { throw SILError.invalid("bad switch_enum: \(line)") }
    let (cases, fallback) = try enumTargets(parts.dropFirst())
    guard (cases.map(\.target) + (fallback.map { [$0] } ?? [])).allSatisfy({ $0.hasPrefix("bb") && !$0.contains("(") }) else {
        throw SILError.unsupported("switch_enum: \(line)")
    }
    return .switchEnum(subject: try operand(first), isAddress: isAddress, cases: cases, default: fallback)
}

/// The enum instructions without a result (`inject_enum_addr`, `copy_addr`), or nil.
func parseEnumStatement(_ line: String) throws(SILError) -> Instruction? {
    if line.hasPrefix("inject_enum_addr ") {
        let parts = splitTopLevel(String(line.dropFirst("inject_enum_addr ".count)))
        guard parts.count == 2 else { throw SILError.invalid("bad inject_enum_addr: \(line)") }
        return .injectEnum(address: try operand(parts[0]), caseName: try caseName(parts[1]))
    }
    if line.hasPrefix("copy_addr ") {
        let body = String(line.dropFirst("copy_addr ".count))
        guard let to = body.range(of: " to ") else { throw SILError.invalid("bad copy_addr: \(line)") }
        var source = String(body[..<to.lowerBound])
        if source.hasPrefix("[take] ") { source = String(source.dropFirst("[take] ".count)) }
        var destination = String(body[to.upperBound...])
        if destination.hasPrefix("[init] ") { destination = String(destination.dropFirst("[init] ".count)) }
        guard isValue(source), isValue(destination) else { throw SILError.unsupported("copy_addr: \(line)") }
        return .copyAddress(source: source, destination: destination)
    }
    return nil
}

/// The enum instructions with a result, or nil for any other instruction.
func parseEnumInstruction(head: String, result: String, rest: String, types: TypeContext) throws(SILError) -> Instruction? {
    switch head {
    case "enum":
        let parts = splitTopLevel(rest)
        guard parts.count == 2 || parts.count == 3 else { throw SILError.invalid("bad enum: \(rest)") }
        let type = try types.resolve(parts[0])
        let payload = parts.count == 3 ? try operand(parts[2]) : nil
        return .makeEnum(result: result, type: type, caseName: try caseName(parts[1]), payload: payload)
    case "unchecked_enum_data":
        let parts = splitTopLevel(rest)
        guard parts.count == 2 else { throw SILError.invalid("bad unchecked_enum_data: \(rest)") }
        return .enumPayload(result: result, source: try operand(parts[0]), caseName: try caseName(parts[1]))
    case "init_enum_data_addr", "unchecked_take_enum_data_addr", "unchecked_inplace_enum_data_addr":
        let parts = splitTopLevel(rest)
        guard parts.count == 2 else { throw SILError.invalid("bad \(head): \(rest)") }
        return .enumPayloadAddress(
            result: result, base: try operand(parts[0]), caseName: try caseName(parts[1]),
            checksCase: head != "init_enum_data_addr")
    case "select_enum", "select_enum_addr":
        return try parseSelectEnum(head: head, result: result, rest: rest)
    default:
        return nil
    }
}

/// `select_enum[_addr] %e : $E, case #E.a!enumelt: %1, default %2 : $T`.
private func parseSelectEnum(head: String, result: String, rest: String) throws(SILError) -> Instruction {
    guard let colon = rest.range(of: " : $", options: .backwards) else { throw SILError.invalid("bad \(head): \(rest)") }
    let parts = splitTopLevel(String(rest[..<colon.lowerBound]))
    guard let first = parts.first else { throw SILError.invalid("bad \(head): \(rest)") }
    let (cases, fallback) = try enumTargets(parts.dropFirst())
    guard cases.allSatisfy({ isValue($0.target) }), fallback.map(isValue) ?? true else {
        throw SILError.unsupported("\(head): \(rest)")
    }
    return .selectEnum(
        result: result, source: try operand(first), isAddress: head == "select_enum_addr", cases: cases, default: fallback)
}

// Reading guide
// `==`, `!=` and `~=` on an enum with raw values (`enum Club: String`, app study round 6, L4). The compiler writes them,
// at `-Onone`, as two stack slots, `builtin "getEnumTag"<Club>` on each, and `cmp_eq_Int32` of the two results.
// The builtin returns the runtime case index of the value. For an enum without payload cases that is the index of
// its case in declaration order (the Swift ABI numbers payload cases first, then the others, each in declaration
// order), which is the tag leaf logic keeps for every enum (`ValueType.enumeration`). So the builtin is read only for
// an enum without payload cases (every raw-value enum), and not for an `@objc` enum, whose values are their raw values
// in memory. Anything else stays `unsupported`.
// Tests: Tests/SFSILTests/SILEnumTagTests.swift.

import Foundation
import SFBV
import SFSemantics

/// A builtin with generic arguments: only `builtin "getEnumTag"<E>(%x) : $Builtin.Int32` is read.
func readGenericBuiltin(_ name: String, result: String, _ after: String, line: String) throws(SILError) -> Instruction {
    guard name == "getEnumTag", let close = matchingClose(Substring(after), open: "<", close: ">") else {
        throw SILError.unsupported("generic builtin \(name)")
    }
    let call = after[after.index(after: close)...]
    guard call.hasPrefix("("), let end = call.range(of: ") : ") else { throw SILError.invalid("bad getEnumTag: \(line)") }
    let operands = try parseValueList(String(call[call.index(after: call.startIndex)..<end.lowerBound]))
    guard operands.count == 1, scalarWidth(String(call[end.upperBound...])) == 32 else {
        throw SILError.invalid("bad getEnumTag: \(line)")
    }
    return .enumTag(result: result, operand: operands[0])
}

extension TypeContext {
    /// Records the enum `name` declared on `line` (an `@objc` enum also goes into `objcEnums`).
    mutating func declareEnum(_ name: String, cases: [(name: String, payload: String?)], line: String) {
        let objc = line.split(separator: " ").contains { $0.hasPrefix("@objc") }
        declare(name) {
            $0.enums[name] = cases
            if objc { $0.objcEnums.insert(name) }
        }
    }
}

extension SILEncoder {
    /// The runtime case index of an enum value of `type` with these leaves, as a 32-bit word (see the top of this file).
    func runtimeEnumTag(_ type: ValueType, _ leaves: [BV]) throws(SILError) -> BV {
        guard case .enumeration(let name, let cases) = type, let tag = leaves.first, tag.width <= 32 else {
            throw SILError.invalid("getEnumTag of a value that is not an enum")
        }
        guard cases.allSatisfy({ $0.payload == nil }) else {
            throw SILError.unsupported("getEnumTag of \(name), which has payload cases (only an enum without payloads is read)")
        }
        guard !module.types.objcEnums.contains(name) else {
            throw SILError.unsupported("getEnumTag of the @objc enum \(name), whose values are their raw values")
        }
        return c.zeroExtend(tag, to: 32)
    }
}

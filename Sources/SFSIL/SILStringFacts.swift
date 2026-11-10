import Foundation
import SFBV
import SFCNF

// String facts: what logic knows about a text result without knowing the operand's text.
//
// A string is the handle of its value (`SILStrings.swift`): the hash of its bytes for an ASCII literal, a free value
// otherwise. A call on a string whose text is not known gets a fresh handle, and a *rule* relates that handle to every
// text the run records (`CNFBuilder.textHandles`), those recorded before the call and those recorded after it. The
// encoder meets the texts of a function in order, so `switch input?.lowercased() { case "home": … }` records "home"
// only after the call, and the contract that compares `input` with "home" later still. Every rule is a fact true of
// every string, so it can be added anywhere in the formula:
//
// - `s.lowercased()`, `s.uppercased()`: if `s` is the recorded text `t`, the result is `t` converted (ASCII only, as
//   every recorded text is). Two ASCII texts are equal in Swift exactly when their bytes are, and the non-ASCII strings
//   Swift calls equal to an ASCII text (U+212A KELVIN SIGN is "K") convert to a string equal to the converted text.
// - The decimal text of a standard integer `n` (interpolation, `String(n)`, `String(describing: n)`,
//   `n.description`): equal to the recorded text `t` exactly when `t` is the canonical decimal form of a value of the
//   type (an optional `-`, then digits without a leading zero; never "-0") and `n` is that value.
// - `_findStringSwitchCase(cases:string:)`, behind a `String` raw-value `init(rawValue:)`: the index of the first case
//   equal to the string, or -1. The case texts are read from the array literal the function builds for the call.
//
// A rule is applied only to the texts the builder records (at most `Text.recorded`); a handle is then less constrained,
// never wrongly constrained, so a proof stays sound. A result that rests on a rule is an approximation unless the
// operand is a known text, so a counterexample is checked again on its own inputs (`Verifier.honest`).

extension StdlibSummary {
    /// How a summarized call prints a standard integer: its decimal text, appended or returned.
    package enum IntegerText: Sendable, Hashable {
        /// `DefaultStringInterpolation.appendInterpolation(_:)`: appended to the interpolation (argument 1).
        case appended
        /// `String(n)`, `String(describing: n)`, `n.description`: the result.
        case returned
    }

    /// Marks the rows whose call prints a standard integer as its decimal text. For any other subject the row keeps
    /// its own summary (a module type's `description` runs).
    static func addIntegerTexts(to table: inout [String: Entry]) {
        let printers: [(String, IntegerText)] = [
            ("$ss26DefaultStringInterpolationV06appendC0yyxlF", .appended),
            ("$ss26DefaultStringInterpolationV06appendC0yyxs06CustomB11ConvertibleRzlF", .appended),
            ("$ss26DefaultStringInterpolationV06appendC0yyxs06CustomB11ConvertibleRzs20TextOutputStreamableRzlF", .appended),
            ("$sSS10describingSSx_tclufC", .returned),
            ("$sSS10describingSSx_tcs23CustomStringConvertibleRzlufC", .returned),
            ("$sSSySSxcs25LosslessStringConvertibleRzlufC", .returned),
            ("$sSzsE11descriptionSSvg", .returned),
        ]
        for (symbol, use) in printers { table[symbol]?.integerText = use }
    }

    /// The canonical decimal text of the `width`-bit pattern `bits`, as Swift prints it.
    static func decimalText(_ bits: UInt64, width: Int, signed: Bool) -> String {
        let shift = UInt64(64 - width)
        return signed ? String(Int64(bitPattern: bits << shift) >> Int64(shift)) : String((bits << shift) >> shift)
    }

    /// The `width`-bit pattern whose decimal text is `text`; nil when `text` is not the canonical decimal form of a
    /// value of that type (a sign other than a leading `-`, a leading zero, "-0", the empty text, out of range).
    static func decimalValue(_ text: String, width: Int, signed: Bool) -> UInt64? {
        let digits = text.hasPrefix("-") ? text.utf8.dropFirst() : text.utf8[...]
        guard !digits.isEmpty, digits.allSatisfy({ $0 >= UInt8(ascii: "0") && $0 <= UInt8(ascii: "9") }) else { return nil }
        guard digits.first != UInt8(ascii: "0") || digits.count == 1, text != "-0" else { return nil }
        let mask: UInt64 = width == 64 ? ~0 : (1 << UInt64(width)) - 1
        if signed {
            guard let value = Int64(text), width == 64 || (value >= -(1 << (width - 1)) && value < 1 << (width - 1)) else { return nil }
            return UInt64(bitPattern: value) & mask
        }
        guard !text.hasPrefix("-"), let value = UInt64(text), value <= mask else { return nil }
        return value
    }
}

extension StdlibSummary.Text {
    /// Adds `rule` for every text this run records: those recorded so far, now, and each later one as it is recorded.
    /// A rule gets the builder as its argument and must not capture it (the builder keeps its rules).
    func forEveryText(_ rule: @escaping (CNFBuilder, UInt64) -> Void) {
        c.textRules.append(rule)
        for id in c.textHandles { rule(c, id) }
    }

    /// Applies the rules to a text recorded just now.
    static func applyRules(to id: UInt64, in c: CNFBuilder) {
        for rule in c.textRules { rule(c, id) }
    }

    /// `s.lowercased()` or `s.uppercased()` where `s` is not a known text: empty exactly when `s` is, and the converted
    /// text whenever `s` turns out to be a recorded text.
    func changedCase(of s: BV, lower: Bool) -> BV {
        guard let empty else { return c.input(width: 64) }
        let r = c.select(c.eq(s, empty), empty, nonEmpty(empty))
        forEveryText { c, id in
            guard let t = StringIdentity.text(of: id), let converted = Self(c: c).handle(lower ? t.lowercased() : t.uppercased())
            else { return }
            c.addClause([-c.eq(s, c.constant(id, width: 64)), c.eq(r, converted)])
        }
        return r
    }

    /// The decimal text of the standard integer `n`: exact when `n` is a constant, otherwise a handle that equals a
    /// recorded text exactly when that text is `n` printed.
    func decimal(_ n: BV, signed: Bool) -> (value: BV, exact: Bool) {
        if let bits = c.constantValue(n), let h = handle(StdlibSummary.decimalText(bits, width: n.width, signed: signed)) {
            return (h, true)
        }
        guard let empty else { return (c.input(width: 64), false) }
        let r = nonEmpty(empty)
        forEveryText { c, id in
            guard let t = StringIdentity.text(of: id) else { return }
            let isText = c.eq(r, c.constant(id, width: 64))
            guard let value = StdlibSummary.decimalValue(t, width: n.width, signed: signed) else { return c.addClause([-isText]) }
            let isValue = c.eq(n, c.constant(value, width: n.width))
            c.addClause([-isText, isValue])
            c.addClause([isText, -isValue])
        }
        return (r, false)
    }

    /// `appendLiteral(_:)` and `String(stringInterpolation:)`: an interpolation is the handle of its text so far.
    func interpolation(_ operation: StdlibSummary.TextOperation, name: String, handles: [BV]) throws -> (value: BV, exact: Bool) {
        switch operation {
        case .appendLiteral: return concatenate(handles[1], handles[0])
        case .interpolated: return (handles[0], true)
        default: throw SILError.invalid("\(name) is answered by the encoder's text facts")
        }
    }

    /// An interpolation `buffer` with the decimal text of `n` appended.
    func appendingDecimal(_ buffer: BV, _ n: BV, signed: Bool) -> (value: BV, exact: Bool) {
        let number = decimal(n, signed: signed)
        if let empty, let bits = c.constantValue(buffer), bits == c.constantValue(empty) { return number }
        let joined = concatenate(buffer, number.value)
        return (joined.value, joined.exact && number.exact)
    }

    /// `_findStringSwitchCase(cases:string:)` on known case texts: the index of the first case equal to `s`, or -1.
    /// Whether `s` equals a case without a fixed handle (a non-ASCII text, `nil`) is unknown, and so is the result.
    func switchCase(_ s: BV, cases: [String?]) -> (value: BV, exact: Bool) {
        var (value, exact) = (c.constant(UInt64.max, width: 64), true)
        for (k, text) in cases.enumerated().reversed() {
            let hit: Int32
            if let text, let h = handle(text) {
                hit = c.eq(s, h)
            } else {
                (hit, exact) = (c.input(width: 1).bits[0], false)
            }
            value = c.select(hit, c.constant(UInt64(k), width: 64), value)
        }
        return (value, exact)
    }

    /// `_findStringSwitchCase(cases:string:)` when the cases are not known: some index in `-1 ..< count`.
    func someCase(count: BV) -> BV {
        let (f, minusOne) = (c.input(width: 64), c.constant(UInt64.max, width: 64))
        return c.select(c.and(-c.slt(f, minusOne), c.slt(f, count)), f, minusOne)
    }
}

extension StdlibSummary.Entry {
    /// A call `SILEncoder.textFact` answers: `_findStringSwitchCase`, or a call that may print an integer.
    var isTextFact: Bool { summary == .text(.switchCase) || integerText != nil }
}

extension SILEncoder {
    /// The result of a call `StdlibSummary.Entry.isTextFact` marks; nil when its row's own summary applies (an
    /// integer printer called on a type that is not a standard integer).
    func textFact(_ entry: StdlibSummary.Entry, _ call: SummaryCall) throws -> [BV]? {
        let text = StdlibSummary.Text(c: c)
        if entry.summary == .text(.switchCase) {
            let (count, s) = (try call.word(0), try call.word(1))
            guard let cases = switchCaseTexts(of: try call.argument(0).name, count: count, in: call) else {
                call.approximate(entry.name)
                return [text.someCase(count: count)]
            }
            let (value, exact) = text.switchCase(s, cases: cases)
            if !exact { call.approximate(entry.name) }
            return [value]
        }
        let substitutions = call.request.substitutions
        guard let use = entry.integerText, substitutions.count == 1, let kind = StdlibSummary.integerKind(substitutions[0]) else {
            return nil
        }
        let n = try call.leaves(0)
        guard n.count == 1 else { throw SILError.invalid("\(entry.name): \(substitutions[0]) is not one integer at \(call.request.id)") }
        switch use {
        case .appended:
            let (value, exact) = text.appendingDecimal(try call.word(1), n[0], signed: kind == .signed)
            try call.set(1, [value])
            if !exact { call.approximate(entry.name) }
            return []
        case .returned:
            let (value, exact) = text.decimal(n[0], signed: kind == .signed)
            if !exact { call.approximate(entry.name) }
            return [value]
        }
    }

    /// The texts of the `[StaticString]` array literal `array` that this function builds for `_findStringSwitchCase`:
    /// `_allocateUninitializedArray`, one `store` per element of `struct $StaticString (ptrtoint_Word(string_literal),
    /// length, flags)`, `_finalizeUninitializedArray`. An element whose literal is not decoded, or whose declared length
    /// is not its UTF-8 length, is nil. Nil when the array is built any other way.
    func switchCaseTexts(of array: String, count: BV, in call: SummaryCall) -> [String?]? {
        guard let n = knownCount(count), n <= 4096, let function = try? module.function(call.function),
            let lines = module.bodyLines(of: call.function)
        else { return nil }
        let index = FunctionIndex(function)
        guard let (name, allocation) = index.allocation(of: array), let base = index.elementBase(of: name),
            let elements = index.elementAddresses(base: base, count: n)
        else { return nil }
        // Every element address is the base or a literal offset from it, so no other store can reach an element.
        for case .indexAddress(_, base, let offset) in index.defined.values {
            guard case .literal = index.defined[offset] else { return nil }
        }
        let definitions = Self.staticStringDefinitions(lines)
        var texts: [String?] = []
        for element in elements {
            guard let stores = index.stores[element], stores.count == 1, stores[0].block == index.block[allocation],
                let parts = definitions.structs[stores[0].value], let literal = definitions.pointers[parts.pointer]
            else { return nil }
            guard case .stringLiteral(_, let decoded) = index.defined[literal] else { return nil }
            if let decoded, case .literal(_, _, let length) = index.defined[parts.length], length == UInt64(decoded.utf8.count) {
                texts.append(decoded)
            } else {
                texts.append(nil)
            }
        }
        return texts
    }

    /// The `struct $StaticString (pointer, length, flags)` and `builtin "ptrtoint_Word"(literal)` definitions of a
    /// body, which the parser drops (`Instruction.ignored`).
    private static func staticStringDefinitions(_ lines: [String]) -> (
        structs: [String: (pointer: String, length: String)], pointers: [String: String]
    ) {
        var structs: [String: (pointer: String, length: String)] = [:]
        var pointers: [String: String] = [:]
        for line in lines {
            let words = line.split(separator: " ", omittingEmptySubsequences: true)
            guard words.count >= 4, words[1] == "=", words[0].hasPrefix("%") else { continue }
            let name = String(words[0])
            if words[2] == "struct", words[3] == "$StaticString", words.count >= 7 {
                let fields = words[4...6].map { $0.trimmingCharacters(in: CharacterSet(charactersIn: "(),")) }
                guard words[4].hasPrefix("("), words[6].hasSuffix(")"), fields.allSatisfy({ $0.hasPrefix("%") }) else { continue }
                structs[name] = (fields[0], fields[1])
            } else if words[2] == "builtin", words[3].hasPrefix("\"ptrtoint_Word\"(%"), words[3].hasSuffix(")") {
                pointers[name] = String(words[3].dropFirst("\"ptrtoint_Word\"(".count).dropLast())
            }
        }
        return (structs, pointers)
    }
}

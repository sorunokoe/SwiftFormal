import Foundation
import SFBV
import SFCNF

/// Strings as identities.
///
/// Logic keeps a `String` as one 64-bit handle (`ValueType.opaque`). The handle stands for the string's value up to
/// Swift's `==` (canonical equivalence): two strings are equal exactly when their handles are equal. That makes
/// `==` and `isEmpty` exact, whatever the strings are.
///
/// An ASCII literal's handle is fixed: a hash of its bytes (`StringIdentity`). Two ASCII strings are equal in Swift
/// exactly when their bytes are, so different ASCII literals always get different handles; a hash collision between
/// two texts this process has seen turns both back into unknown handles. A non-ASCII literal gets an unknown handle,
/// because two different byte sequences can be equal strings (`"é"` written precomposed or decomposed).
///
/// Why this is sound: in any one run of the code finitely many strings occur. Give each class of equal strings the
/// handle of the ASCII literal it equals, if any, and a distinct unused handle otherwise. Every operation below
/// returns, for that assignment, a value the model allows, so a proof over all handles covers the real run.
package enum StringIdentity {
    /// The handle of `text`, nil when it is not ASCII or its hash collides with another text's.
    package static func id(of text: String) -> UInt64? { registry.register(text) }

    /// The literal text a handle stands for, if it is the handle of an ASCII text this process has seen.
    package static func text(of id: UInt64) -> String? { registry.text(of: id) }

    /// Whether `text`, or a text whose hash collides with it, has been given a handle.
    package static func isSeen(_ text: String) -> Bool { registry.isSeen(text) }

    /// `text` as a Swift string literal, for reports: `"Fairway"`, `"a\"b"`.
    package static func swiftLiteral(_ text: String) -> String {
        var out = "\""
        for scalar in text.unicodeScalars {
            switch scalar {
            case "\"": out += "\\\""
            case "\\": out += "\\\\"
            case "\n": out += "\\n"
            case "\r": out += "\\r"
            case "\t": out += "\\t"
            case "\0": out += "\\0"
            default:
                if scalar.value < 0x20 || scalar.value == 0x7F {
                    out += "\\u{" + String(scalar.value, radix: 16) + "}"
                } else {
                    out.unicodeScalars.append(scalar)
                }
            }
        }
        return out + "\""
    }

    private static let simpleEscapes: [Unicode.Scalar: Unicode.Scalar] = [
        "\\": "\\", "\"": "\"", "'": "'", "n": "\n", "r": "\r", "t": "\t", "0": "\0",
    ]

    /// The text of a SIL `string_literal utf8 "…"` body (the part between the quotes), nil for an escape this
    /// decoder does not know.
    package static func unescapeSIL(_ body: Substring) -> String? {
        var out = String.UnicodeScalarView()
        var scalars = body.unicodeScalars.makeIterator()
        while let scalar = scalars.next() {
            guard scalar == "\\" else {
                out.append(scalar)
                continue
            }
            let next = scalars.next()
            if let next, let simple = Self.simpleEscapes[next] {
                out.append(simple)
                continue
            }
            guard next == "u", scalars.next() == "{" else { return nil }
            var hex = ""
            while let digit = scalars.next(), digit != "}" { hex.unicodeScalars.append(digit) }
            guard let value = UInt32(hex, radix: 16), let decoded = Unicode.Scalar(value) else { return nil }
            out.append(decoded)
        }
        return String(out)
    }

    private static let registry = Registry()

    private final class Registry: @unchecked Sendable {
        private let lock = NSLock()
        private var texts: [UInt64: String] = [:]
        private var collided: Set<UInt64> = []

        func register(_ text: String) -> UInt64? {
            guard text.utf8.allSatisfy({ $0 < 0x80 }) else { return nil }
            let id = Self.hash(text)
            lock.lock()
            defer { lock.unlock() }
            if collided.contains(id) { return nil }
            if let seen = texts[id], seen.utf8.elementsEqual(text.utf8) == false {
                collided.insert(id)
                texts[id] = nil
                return nil
            }
            texts[id] = text
            return id
        }

        func isSeen(_ text: String) -> Bool {
            let id = Self.hash(text)
            lock.lock()
            defer { lock.unlock() }
            return texts[id] != nil || collided.contains(id)
        }

        func text(of id: UInt64) -> String? {
            lock.lock()
            defer { lock.unlock() }
            return texts[id]
        }

        /// FNV-1a, 64 bits.
        private static func hash(_ text: String) -> UInt64 {
            var h: UInt64 = 0xcbf2_9ce4_8422_2325
            for byte in text.utf8 { h = (h ^ UInt64(byte)) &* 0x0000_0100_0000_01b3 }
            return h
        }
    }
}

extension StdlibSummary {
    /// What a `String` call computes on handles (`StdlibSummary.text`, see `StringIdentity`).
    package enum TextOperation: Sendable, Hashable {
        /// `String(_builtinStringLiteral:utf8CodeUnitCount:isASCII:)`: the literal's handle.
        case literal
        /// `String()`: the handle of `""`.
        case empty
        /// `==`: exact. `<`: exact on known texts, and for equal or empty operands.
        case equals, less
        /// `isEmpty`: exact (`== ""`). `count`: exact on a known text; 0 for `""`, at least 1 otherwise.
        case isEmpty, count
        /// `+` and `+=`: exact on known texts and when one side is `""`; empty exactly when both sides are.
        case concatenate, append
        /// `hasPrefix(_:)`, `hasSuffix(_:)`: exact on known texts; true for `""` or the string itself.
        case hasPrefix, hasSuffix
        /// `lowercased()`, `uppercased()`: exact on a known text; empty exactly when the string is.
        case lowercased, uppercased
        /// `DefaultStringInterpolation.appendLiteral(_:)` (an interpolation is the handle of its text so far) and
        /// `String(stringInterpolation:)`.
        case appendLiteral, interpolated
        /// `_findStringSwitchCase(cases:string:)`, answered by `SILEncoder.textFact` (`SILStringFacts.swift`).
        case switchCase

        /// How many `String` operands the call takes.
        var operandCount: Int {
            switch self {
            case .literal, .empty: 0
            case .isEmpty, .count, .lowercased, .uppercased, .interpolated: 1
            case .equals, .less, .concatenate, .append, .hasPrefix, .hasSuffix, .appendLiteral, .switchCase: 2
            }
        }
    }

    static func addStrings(to table: inout [String: Entry]) {
        func add(_ symbol: String, _ name: String, _ operation: TextOperation, tag: String? = nil) {
            table[symbol] = Entry(name: name, summary: .text(operation), isGeneric: false)
            table[symbol]?.semantics = Set([tag].compactMap { $0 })
        }
        add("$sSS21_builtinStringLiteral17utf8CodeUnitCount7isASCIISSBp_BwBi1_tcfC", "a string literal", .literal, tag: "string.makeUTF8")
        add("$sS2SycfC", "String()", .empty, tag: "string.init_empty")
        add("$sSS2eeoiySbSS_SStFZ", "String.==", .equals, tag: "string.equals")
        add("$sSS1loiySbSS_SStFZ", "String.<", .less)
        add("$sSS1poiyS2S_SStFZ", "String.+", .concatenate, tag: "string.concat")
        add("$sSS2peoiyySSz_SStFZ", "String.+=", .append, tag: "string.plusequals")
        add("$sSS5countSivg", "String.count", .count)
        add("$sSS7isEmptySbvg", "String.isEmpty", .isEmpty)
        add("$sSS10lowercasedSSyF", "String.lowercased()", .lowercased)
        add("$sSS10uppercasedSSyF", "String.uppercased()", .uppercased)
        add("$sSS9hasPrefixySbSSF", "String.hasPrefix(_:)", .hasPrefix)
        add("$sSS9hasSuffixySbSSF", "String.hasSuffix(_:)", .hasSuffix)
        add(
            "$ss21_findStringSwitchCase5cases6stringSiSays06StaticB0VG_SStF", "_findStringSwitchCase(cases:string:)", .switchCase,
            tag: "findStringSwitchCase")
        addIntegerTexts(to: &table)
    }

    /// The result of a string call and whether it is exact. `handles` are the `String` operands in call order
    /// (`self` last, as SIL passes it); `literal` is the decoded text of a literal and its declared UTF-8 length.
    static func textResult(
        _ operation: TextOperation, name: String, handles: [BV], literal: (text: String, utf8Count: UInt64?)?, in c: CNFBuilder
    ) throws -> (value: BV, exact: Bool) {
        guard handles.count == operation.operandCount, handles.allSatisfy({ $0.width == 64 }) else {
            throw SILError.invalid("\(name) of unexpected shape")
        }
        let text = Text(c: c)
        switch operation {
        case .literal, .empty:
            return text.literal(operation == .empty ? ("", 0) : literal)
        case .equals, .isEmpty:
            guard let other = handles.count == 2 ? handles[1] : text.empty else { return (c.input(width: 1), false) }
            return (BV(bits: [c.eq(handles[0], other)]), true)
        case .count:
            return text.count(handles[0])
        case .concatenate, .append:
            return text.concatenate(handles[0], handles[1])
        case .less:
            return text.less(handles[0], handles[1])
        case .hasPrefix, .hasSuffix:
            // SIL passes the argument first and `self` last.
            return text.affix(of: handles[1], handles[0], prefix: operation == .hasPrefix)
        case .lowercased, .uppercased:
            return text.changeCase(handles[0], lower: operation == .lowercased)
        case .appendLiteral, .interpolated, .switchCase:
            return try text.interpolation(operation, name: name, handles: handles)
        }
    }

    /// Helpers over one circuit builder. A result is exact when the branch that returns a fresh value is never taken.
    struct Text {
        let c: CNFBuilder
        /// How many texts one handle is split over, and how many pairs two handles are: past these, results are fresh.
        static let (textLimit, pairLimit, recorded) = (128, 1024, 512)

        var empty: BV? { handle("") }

        func handle(_ text: String) -> BV? {
            guard let id = StringIdentity.id(of: text) else { return nil }
            if c.textHandles.count < Self.recorded, !c.textHandles.contains(id) {
                c.textHandles.append(id)
                Self.applyRules(to: id, in: c)
            }
            return c.constant(id, width: 64)
        }

        /// A literal's handle: exact when it is ASCII and its declared UTF-8 length matches the decoded text.
        func literal(_ literal: (text: String, utf8Count: UInt64?)?) -> (value: BV, exact: Bool) {
            guard let literal, literal.utf8Count == UInt64(literal.text.utf8.count), let h = handle(literal.text) else {
                return (c.input(width: 64), false)
            }
            return (h, true)
        }

        func count(_ s: BV) -> (value: BV, exact: Bool) {
            map(s) {
                c.constant(UInt64($0.count), width: 64)
            } fallback: {
                guard let empty else { return nonNegative() }
                return c.select(c.eq(s, empty), c.constant(0, width: 64), positive())
            }
        }

        func known(_ h: BV) -> String? { c.constantValue(h).flatMap(StringIdentity.text(of:)) }

        /// The texts met so far that `h` may be, each with the condition that it is that text.
        func split(_ h: BV) -> [(when: Int32, text: String)] {
            if let x = known(h) { return [(c.trueLit, x)] }
            if c.constantValue(h) != nil { return [] }
            return c.textHandles.prefix(Self.textLimit).compactMap { id in
                guard let x = StringIdentity.text(of: id) else { return nil }
                let when = c.eq(h, c.constant(id, width: 64))
                return when == c.falseLit ? nil : (when, x)
            }
        }

        /// `f` of the text `h` is when it is a text met so far, else `fallback`: exact when it always is one.
        func map(_ h: BV, _ f: (String) -> BV?, fallback: () -> BV) -> (value: BV, exact: Bool) {
            var (value, known) = (fallback(), c.falseLit)
            for (when, x) in split(h).reversed() {
                guard let v = f(x) else { continue }
                (value, known) = (c.select(when, v, value), c.or(known, when))
            }
            return (value, known == c.trueLit)
        }

        /// Whether `f` holds of the texts `a` and `b` are, when both are texts met so far, and the condition that they are.
        func relate(_ a: BV, _ b: BV, _ f: (String, String) -> Bool) -> (holds: Int32, known: Int32) {
            let (sa, sb) = (split(a), split(b))
            guard sa.count * sb.count <= Self.pairLimit else { return (c.falseLit, c.falseLit) }
            var (holds, known) = (c.falseLit, c.falseLit)
            for (wa, x) in sa {
                for (wb, y) in sb {
                    let when = c.and(wa, wb)
                    known = c.or(known, when)
                    if f(x, y) { holds = c.or(holds, when) }
                }
            }
            return (holds, known)
        }

        /// An unknown `Int` in `0...Int.max`.
        func nonNegative() -> BV {
            let f = c.input(width: 64)
            return BV(bits: Array(f.bits.dropLast()) + [c.falseLit])
        }

        /// An unknown `Int` in `1...Int.max`.
        func positive() -> BV {
            let f = nonNegative()
            return c.select(c.eq(f, c.constant(0, width: 64)), c.constant(1, width: 64), f)
        }

        /// An unknown handle other than `""`'s.
        func nonEmpty(_ empty: BV) -> BV {
            let f = c.input(width: 64)
            let other = BV(bits: [-empty.bits[0]] + empty.bits.dropFirst())
            return c.select(c.eq(f, empty), other, f)
        }

        func concatenate(_ a: BV, _ b: BV) -> (value: BV, exact: Bool) {
            guard let empty else { return (c.input(width: 64), false) }
            let (aEmpty, bEmpty) = (c.eq(a, empty), c.eq(b, empty))
            var value = c.select(aEmpty, b, c.select(bEmpty, a, nonEmpty(empty)))
            var exact = c.or(aEmpty, bEmpty)
            let (sa, sb) = (split(a), split(b))
            if sa.count * sb.count <= Self.pairLimit {
                for (wa, x) in sa {
                    for (wb, y) in sb {
                        guard let h = handle(x + y) else { continue }
                        let when = c.and(wa, wb)
                        (value, exact) = (c.select(when, h, value), c.or(exact, when))
                    }
                }
            }
            if exact != c.trueLit { relateParts(value, a, b) }
            return (value, exact == c.trueLit)
        }

        func less(_ a: BV, _ b: BV) -> (value: BV, exact: Bool) {
            guard let empty else { return (c.input(width: 1), false) }
            let texts = relate(a, b, <)
            // Nothing is below itself or below "", and "" is below every other string.
            let (same, bEmpty, aEmpty) = (c.eq(a, b), c.eq(b, empty), c.eq(a, empty))
            let falseCase = c.or(same, bEmpty)
            let rule = c.and(-falseCase, c.or(aEmpty, c.input(width: 1).bits[0]))
            let value = c.or(c.and(texts.known, texts.holds), c.and(-texts.known, rule))
            return (BV(bits: [value]), c.or(texts.known, c.or(falseCase, aEmpty)) == c.trueLit)
        }

        func affix(of s: BV, _ part: BV, prefix: Bool) -> (value: BV, exact: Bool) {
            guard let empty else { return (c.input(width: 1), false) }
            let texts = relate(s, part) { prefix ? $0.hasPrefix($1) : $0.hasSuffix($1) }
            // Every string starts and ends with "" and with itself; "" starts with nothing else.
            let (trueCase, sEmpty) = (c.or(c.eq(part, empty), c.eq(s, part)), c.eq(s, empty))
            let rule = c.or(trueCase, c.and(-sEmpty, c.input(width: 1).bits[0]))
            var value = BV(bits: [c.or(c.and(texts.known, texts.holds), c.and(-texts.known, rule))])
            var exact = c.or(texts.known, c.or(trueCase, sEmpty))
            if prefix, exact != c.trueLit { (value, exact) = knownPrefix(of: s, part, otherwise: value, exact: exact) }
            return (value, exact == c.trueLit)
        }

        func changeCase(_ s: BV, lower: Bool) -> (value: BV, exact: Bool) {
            map(s) {
                handle(lower ? $0.lowercased() : $0.uppercased())
            } fallback: {
                changedCase(of: s, lower: lower)
            }
        }
    }
}

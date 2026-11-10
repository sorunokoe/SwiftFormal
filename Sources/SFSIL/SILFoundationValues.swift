import Foundation
import SFBV
import SFCNF
import SFSemantics

// Reading guide
// More Foundation and SwiftUI values for `OpaqueValues` (`SILOpaqueValues.swift`), and what logic reads of them:
//
// - `Date` is the `Double` it wraps (`timeIntervalSinceReferenceDate`, Foundation's `_time`): its handle is that
//   `Double`'s bits. `==`, `<` and `>` are Foundation's, which compare the `Double`s; `<=` and `>=` are `Comparable`'s
//   defaults (`!(b < a)`, `!(a < b)`), so with a NaN they are true while `<` and `==` are false. Adding an interval,
//   the interval since 1970 or since another date are the IEEE additions and subtractions Foundation does
//   (`SILFoundationValueTests` checks them against Foundation itself). `Date()` and `Date.now` are unknown dates.
// - `Decimal`, `Calendar`, `TimeZone`, `DateComponents`, `URLComponents`, `CharacterSet`, SwiftUI's `Image` and
//   `Font` are held like `URL`: stored, passed and compared with themselves, nothing more. A `Calendar` is never read as
//   any particular calendar: its time zone and locale are whatever the device has unless the code says otherwise, so
//   what it computes is unknown.
// - Any other call on these types (`URL.path`, `Calendar.date(byAdding:value:to:)`) is, with `OpaqueCallMode.all`, an
//   opaque call (`SILOpaqueCalls.swift`): it returns any value of its result type, changes any `inout` argument it has
//   to any value, and is assumed not to trap; the report lists it. Only calls whose arguments are plain data or such
//   values are read this way: a closure, an existential, a generic or a value of the app could run the app's code.
// - `Decimal` arithmetic (`+`, `/`, `add(_:)`, …) is refused: it is decimal floating point, with its own rounding, and
//   reading it as `Double`'s would prove what is false (`1 / 3 * 3` is 1 in `Double`, 0.99…9 in `Decimal`).

extension OpaqueValues {
    /// What a read call on a `Date` does to the `Double` a `Date` handle is.
    package enum DateOperation: Sendable, Hashable {
        /// `Date(timeIntervalSince1970: t)` (`t - 978307200`) or `Date(timeIntervalSinceReferenceDate: t)` (`t`).
        case make(since1970: Bool)
        /// `timeIntervalSince1970` (`date + 978307200`) or `timeIntervalSinceReferenceDate` (`date`).
        case interval(since1970: Bool)
        /// `date + interval` or `date - interval`, where operand `date` is the date and the other the interval.
        case shift(date: Int, subtract: Bool)
        /// `+=`, `-=`, `addTimeInterval(_:)`: as `shift`, written back to the `inout` date.
        case shiftInPlace(date: Int, subtract: Bool)
        /// `a.timeIntervalSince(b)`, called as `(b, a)`: `a - b`.
        case since
        /// `==`, `<`, `>`, and `Comparable`'s `<=` and `>=`.
        case compare(String)
        /// `distantPast`, `distantFuture`.
        case constant(Double)

        /// How many `Double` operands the call passes.
        var arity: Int {
            switch self {
            case .make, .interval: 1
            case .shift, .shiftInPlace, .since, .compare: 2
            case .constant: 0
            }
        }
    }

    /// Seconds from 1970 to 2001, Foundation's `timeIntervalBetween1970AndReferenceDate`.
    static let referenceOffset = 978_307_200.0

    /// The types this file adds to `types`.
    static let moreTypes: [String: Kind] = [
        "Decimal": Kind(module: "Foundation", prefix: "$sSo9NSDecimala", identity: .copy, holdsAppObjects: false),
        "Calendar": Kind(module: "Foundation", prefix: "$s10Foundation8CalendarV", identity: .copy, holdsAppObjects: false),
        "TimeZone": Kind(module: "Foundation", prefix: "$s10Foundation8TimeZoneV", identity: .copy, holdsAppObjects: false),
        "DateComponents": Kind(module: "Foundation", prefix: "$s10Foundation14DateComponentsV", identity: .copy, holdsAppObjects: false),
        "URLComponents": Kind(module: "Foundation", prefix: "$s10Foundation13URLComponentsV", identity: .copy, holdsAppObjects: false),
        "CharacterSet": Kind(module: "Foundation", prefix: "$s10Foundation12CharacterSetV", identity: .copy, holdsAppObjects: false),
        "Image": Kind(module: "SwiftUI", prefix: "$s7SwiftUI5ImageV", identity: .none, holdsAppObjects: true),
        "Font": Kind(module: "SwiftUI", prefix: "$s7SwiftUI4FontV", identity: .none, holdsAppObjects: true),
    ]

    /// `<=` and `>=` of `Date`: `Comparable`'s defaults, reached only through `witness_method`. These keys name no
    /// function (Foundation declares neither); they only let the witness find its entry.
    package static let witnessOnly: Set<String> = ["$s10Foundation4DateV2leoiySbAC_ACtFZ", "$s10Foundation4DateV2geoiySbAC_ACtFZ"]

    /// The calls this file adds to `table` (`add(type, suffix, member, operation)`).
    static func addMoreCalls(_ add: (String, String, String, Operation) -> Void) {
        add("Date", "026timeIntervalSinceReferenceB0ACSd_tcfC", "(timeIntervalSinceReferenceDate:)", .date(.make(since1970: false)))
        add("Date", "026timeIntervalSinceReferenceB0Sdvg", "timeIntervalSinceReferenceDate", .date(.interval(since1970: false)))
        add("Date", "11distantPastACvgZ", "distantPast", .date(.constant(-63_114_076_800)))
        add("Date", "13distantFutureACvgZ", "distantFuture", .date(.constant(63_113_904_000)))
        add("Date", "12timeInterval5sinceACSd_ACtcfC", "(timeInterval:since:)", .date(.shift(date: 1, subtract: false)))
        add("Date", "18addingTimeIntervalyACSdF", "addingTimeInterval(_:)", .date(.shift(date: 1, subtract: false)))
        add("Date", "1poiyA2C_SdtFZ", "+", .date(.shift(date: 0, subtract: false)))
        add("Date", "1soiyA2C_SdtFZ", "-", .date(.shift(date: 0, subtract: true)))
        add("Date", "2peoiyyACz_SdtFZ", "+=", .date(.shiftInPlace(date: 0, subtract: false)))
        add("Date", "2seoiyyACz_SdtFZ", "-=", .date(.shiftInPlace(date: 0, subtract: true)))
        add("Date", "15addTimeIntervalyySdF", "addTimeInterval(_:)", .date(.shiftInPlace(date: 1, subtract: false)))
        add("Date", "17timeIntervalSinceySdACF", "timeIntervalSince(_:)", .date(.since))
        add("Date", "1goiySbAC_ACtFZ", ">", .date(.compare("ogt")))
        add("Date", "2leoiySbAC_ACtFZ", "<=", .date(.compare("le")))
        add("Date", "2geoiySbAC_ACtFZ", ">=", .date(.compare("ge")))
        for type in ["Calendar", "TimeZone", "DateComponents", "URLComponents", "CharacterSet"] {
            add(type, "2eeoiySbAC_ACtFZ", "==", .equals)
            add(type, "4hash4intoys6HasherVz_tF", "hash(into:)", .unknown)
            add(type, "9hashValueSivg", "hashValue", .derived)
        }
        add("Decimal", "10FoundationE2eeoiySbAB_ABtFZ", "==", .equals)
        add("Decimal", "10FoundationE14integerLiteralABSi_tcfC", "(integerLiteral:)", .make)
        add("Calendar", "7currentACvgZ", "current", .make)
        add("TimeZone", "7currentACvgZ", "current", .make)
    }

    /// The operators and methods of `Decimal` that compute: refused (see the reading guide).
    static func isDecimalArithmetic(_ symbol: String) -> Bool {
        guard let rest = symbol.split(separator: "$sSo9NSDecimala10FoundationE", omittingEmptySubsequences: false).dropFirst().first
        else { return false }
        let arithmetic = ["1poiy", "1soiy", "1moiy", "1doiy", "2peoiy", "2seoiy", "2meoiy", "2deoiy", "1soiyA", "1poiyA"]
        let methods = ["3add", "8subtract", "8multiply", "6divide", "6negate", "7rounded", "5round"]
        return (arithmetic + methods).contains { rest.hasPrefix($0) }
    }

    /// The type of `OpaqueValues` whose member `symbol` is, if any.
    static func owner(of symbol: String) -> String? {
        types.first { symbol.hasPrefix($0.value.prefix) }?.key
    }
}

extension ComputedSummary {
    /// `OpaqueValues.DateOperation` on the `Double`s `Date` handles are.
    func encodeDate(_ operation: OpaqueValues.DateOperation, _ call: ComputedCall, in c: CNFBuilder) throws -> ComputedEffect {
        let operands = zip(call.inputs, call.conventions).filter { $1 != .out && !$0.isEmpty }.map(\.0)
        let values = operands.compactMap { $0.count == 1 && $0[0].width == 64 ? $0[0] : nil }
        guard values.count == operands.count, values.count == operation.arity, let format = FloatFormat(width: 64) else {
            throw SILError.invalid("\(call.name): operands of unexpected shape")
        }
        let (value, nan) = try Self.dateValue(operation, values, FloatCircuit(c, format), call: call)
        let approximations: Set<String> = nan == c.falseLit ? [] : ["floating point"]
        let returnsThroughAddress = call.conventions.first == .out
        let written = call.writtenTypes.map(\.leafWidths)
        let shapeIsRight: Bool
        let effect: ComputedEffect
        if case .shiftInPlace = operation {
            shapeIsRight = written == [[64]] && call.resultType.leafWidths.isEmpty
            effect = ComputedEffect(writtenBack: [value], approximations: approximations)
        } else if returnsThroughAddress {
            shapeIsRight = written == [[value.width]] && call.resultType.leafWidths.isEmpty
            effect = ComputedEffect(writtenBack: [value], approximations: approximations)
        } else {
            shapeIsRight = call.resultType.leafWidths == [value.width] && written.isEmpty
            effect = ComputedEffect(result: [value], approximations: approximations)
        }
        guard shapeIsRight else { throw SILError.invalid("\(call.name): result of unexpected shape") }
        return effect
    }

    /// The value of `operation` on `values` and when it is a NaN Foundation's rounding would not produce bit for bit
    /// (`FloatCircuit.add`).
    private static func dateValue(
        _ operation: OpaqueValues.DateOperation, _ values: [BV], _ circuit: FloatCircuit, call: ComputedCall
    ) throws -> (value: BV, nan: Int32) {
        let c = circuit.c
        let offset = c.constant(OpaqueValues.referenceOffset.bitPattern, width: 64)
        switch operation {
        case .make(let since1970):
            return since1970 ? circuit.add(values[0], offset, subtract: true) : (values[0], c.falseLit)
        case .interval(let since1970):
            return since1970 ? circuit.add(values[0], offset) : (values[0], c.falseLit)
        case .shift(let date, let subtract), .shiftInPlace(let date, let subtract):
            return circuit.add(values[date], values[1 - date], subtract: subtract)
        case .since:
            return circuit.add(values[1], values[0], subtract: true)
        case .compare(let predicate):
            return (BV(bits: [try dateComparison(predicate, values[0], values[1], in: c, call: call)]), c.falseLit)
        case .constant(let seconds):
            return (c.constant(seconds.bitPattern, width: 64), c.falseLit)
        }
    }

    /// `a predicate b` on two dates; `le` and `ge` as `Comparable`'s defaults, `!(b < a)` and `!(a < b)`.
    private static func dateComparison(_ predicate: String, _ a: BV, _ b: BV, in c: CNFBuilder, call: ComputedCall) throws -> Int32 {
        let (name, operands, negated) =
            switch predicate {
            case "le": ("olt", [b, a], true)
            case "ge": ("olt", [a, b], true)
            default: (predicate, [a, b], false)
            }
        guard let compare = S0FloatInstance(builtinName: "fcmp_\(name)_FPIEEE64") else {
            throw SILError.invalid("\(call.name): no comparison \(name)")
        }
        let holds = compare.encode(c, operands).value.bits[0]
        return negated ? -holds : holds
    }

    /// `OpaqueValues.Operation.assumed`: any value of the result, any value for every `inout` argument, no trap; an
    /// assumption the report lists.
    func encodeAssumed(_ call: ComputedCall, _ value: OpaqueValues.Call, fresh: (ValueType) -> [BV]) -> ComputedEffect {
        let module = OpaqueValues.types[value.type]?.module ?? "a library"
        Assumptions.note("`\(value.member)` may return any value and is assumed not to trap (\(module), no body)")
        return ComputedEffect(result: fresh(call.resultType), writtenBack: call.writtenTypes.flatMap(fresh), approximations: [value.member])
    }
}

extension SILModule {
    /// The entry of a call on an `OpaqueValues` type that `OpaqueValues.table` does not read: an assumed call
    /// (`OpaqueValues.Operation.assumed`) with `OpaqueCallMode.all`, a refusal with the reason otherwise; nil for a
    /// symbol of no such type, or of a type this build did not confirm.
    func assumedOpaqueValueCall(_ symbol: String) throws -> StdlibSummary.Entry? {
        guard let type = OpaqueValues.owner(of: symbol), isOpaqueValue(type),
            let declaration = externalDeclaration(of: symbol)
        else { return nil }
        let label = (binary.externalNames[symbol] ?? symbol).replacingOccurrences(of: "NSDecimal.", with: "Decimal.")
        if OpaqueValues.isDecimalArithmetic(symbol) {
            throw SILError.unsupported(
                "Decimal arithmetic (`\(label)`): Decimal is decimal floating point with its own rounding; logic does not read it as Double"
            )
        }
        switch opaqueCalls {
        case .objectiveC: return nil
        case .none:
            throw SILError.unsupported(
                "no body for `\(label)` (\(OpaqueValues.unreadCall(symbol) ?? type)) \(OpaqueCallMode.strictNote)")
        case .all: break
        }
        if let reason = notInert(declaration) {
            throw SILError.unsupported("call to `\(label)` with \(reason): the callee, which has no body, could call back through it")
        }
        let call = OpaqueValues.Call(type: type, member: label, operation: .assumed)
        return StdlibSummary.Entry(name: label, summary: .computed(.opaqueValue(call)), isGeneric: false)
    }

    /// Why a call with `declaration` could run code of the read modules, nil when every parameter and the result are
    /// plain data or confirmed `OpaqueValues` that hold no app object.
    private func notInert(_ declaration: String) -> String? {
        guard let colon = declaration.range(of: " : $") else { return "an unreadable declaration" }
        var signature = Substring(declaration[colon.upperBound...])
        for refused in ["@async", "@error", "τ_", "@callee", "@block", "@yield"] where signature.contains(refused) {
            return "a \(refused) signature"
        }
        signature = Self.droppingAttributes(signature)
        guard signature.hasPrefix("("), let end = matchingClose(signature, open: "(", close: ")"),
            signature[signature.index(after: end)...].hasPrefix(" -> ")
        else { return "an unreadable declaration" }
        let parameters = splitTopLevel(String(signature[signature.index(after: signature.startIndex)..<end]))
        let result = String(signature[signature.index(end, offsetBy: 5)...])
        for text in parameters + [result] {
            var plain = Substring(text.trimmingCharacters(in: .whitespaces))
            while plain.hasPrefix("@"), let space = plain.firstIndex(of: " ") { plain = plain[plain.index(after: space)...] }
            if plain.hasSuffix(".Type"), OpaqueValues.types[String(plain.dropLast(".Type".count))] != nil { continue }
            if plain == "()" { continue }
            let name = String(plain)
            guard !name.contains("->"), !name.contains("any "), !name.contains(/\bAny(Object|Hashable)?\b/),
                types.packageType(name) == nil, let type = try? types.resolve(name), isInertValue(type)
            else { return "a \(plain)" }
        }
        return nil
    }

    /// `signature` without its leading attributes (`@convention(…)`, `@pseudogeneric`, …).
    private static func droppingAttributes(_ signature: Substring) -> Substring {
        var signature = signature
        while signature.hasPrefix("@"), let space = signature.firstIndex(of: " ") {
            if signature.hasPrefix("@convention("), let close = signature.firstIndex(of: ")") {
                signature = signature[signature.index(after: close)...].drop { $0 == " " }
            } else {
                signature = signature[signature.index(after: space)...]
            }
        }
        return signature
    }

    /// Scalars, strings and `OpaqueValues` that hold no app object, and structs, tuples and enums of them.
    private func isInertValue(_ type: ValueType) -> Bool {
        switch type {
        case .scalar: return true
        case .opaque(let name):
            return ["String", "Substring", "Character"].contains(name) || OpaqueValues.types[name].map { !$0.holdsAppObjects } == true
        case .aggregate(_, let fields): return fields.allSatisfy { isInertValue($0.type) }
        case .enumeration(_, let cases): return cases.allSatisfy { $0.payload.map(isInertValue) ?? true }
        case .array, .hashed: return false
        }
    }
}

extension BinaryTypes {
    /// These types with `externals` and `externalNames` read from the module's `lines`.
    func readingExternals(_ lines: [String]) -> BinaryTypes {
        var types = self
        (types.externals, types.externalNames) = (Self.externals(in: lines), Self.externalNames(in: lines))
        return types
    }

    /// `externalNames`: for each declaration without a body, the `// Name` comment before it (an `// Isolation:` line
    /// may come between).
    static func externalNames(in lines: [String]) -> [String: String] {
        var found: [String: String] = [:]
        var name: String?
        for line in lines {
            if line.hasPrefix("// ") {
                if !line.hasPrefix("// Isolation:") { name = String(line.dropFirst(3)) }
                continue
            }
            defer { name = nil }
            guard let name, line.hasPrefix("sil "), !line.hasSuffix("{"), let at = line.range(of: " @"),
                let end = line[at.upperBound...].range(of: " : ")
            else { continue }
            found[String(line[at.upperBound..<end.lowerBound])] = name
        }
        return found
    }
}

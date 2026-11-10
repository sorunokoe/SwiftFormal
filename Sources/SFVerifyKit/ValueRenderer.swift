import SFSIL

/// Swift-like text for a counterexample value, from its SIL layout: `.circle(-3)`, `nil`, `Point(x: 1, y: 2)`.
/// Scalars inside structs and enums print as signed decimals (their exact Swift type is not in the layout);
/// one-bit scalars print as `true`/`false`.
enum ValueRenderer {
    static func render(_ type: ValueType, _ values: ArraySlice<UInt64>, scalarName: String? = nil) -> String {
        switch type {
        case .opaque(let name):
            return opaque(name, values[values.startIndex])
        case .array(let element):
            let count = values.first ?? 0
            return "[\(count) \(count == 1 ? "element" : "elements") of \(element)]"
        case .hashed(let collection):
            let count = values.first ?? 0
            let what = collection.kind == .dictionary ? (count == 1 ? "entry" : "entries") : (count == 1 ? "element" : "elements")
            return "[\(count) \(what) of \(collection)]"
        case .scalar(let width):
            return scalar(values[values.startIndex], width: width, name: scalarName)
        case .aggregate(let name, let fields):
            return aggregate(name, fields, values)
        case .enumeration(let name, let cases):
            let tag = Int(values[values.startIndex])
            guard cases.indices.contains(tag) else { return "<invalid \(name)>" }
            let range = type.payloadLeafRange(ofCase: tag)
            let isOptional = name.hasPrefix("Optional<")
            guard let payload = cases[tag].payload else { return isOptional ? "nil" : "." + cases[tag].name }
            let slice = values[(values.startIndex + range.lowerBound)..<(values.startIndex + range.upperBound)]
            // `Double?` names the payload's type too (a scalar leaf does not say whether it is an `Int` or a `Double`).
            let text = render(payload, slice, scalarName: isOptional ? scalarName.map(Self.unwrappedOptional) : nil)
            if isOptional { return text }
            return "." + cases[tag].name + (text.hasPrefix("(") ? text : "(\(text))")
        }
    }

    /// `Double` for `Double?` or `Optional<Double>`; any other text unchanged.
    static func unwrappedOptional(_ text: String) -> String {
        let t = text
        if t.hasSuffix("?") { return String(t.dropLast()) }
        if t.hasPrefix("Optional<"), t.hasSuffix(">") { return String(t.dropFirst("Optional<".count).dropLast()) }
        return t
    }

    /// A struct or tuple: `Point(x: 1, y: 2)`, `(1, true)`. `CGFloat` is the `Double` it wraps (`SILCGFloat.swift`):
    /// `CGFloat(1.5)` is a Swift literal, `native:` is not.
    private static func aggregate(_ name: String, _ fields: [ValueType.Field], _ values: ArraySlice<UInt64>) -> String {
        if name == "CGFloat", fields.map(\.type) == [.scalar(64)] {
            return "CGFloat(\(Verifier.floatLiteral(bits: values[values.startIndex], type: "Double")))"
        }
        var parts: [String] = []
        var offset = values.startIndex
        // A scalar leaf does not say whether it is an `Int` or a `Double`: the struct's declaration does, when the
        // module that printed it is known (`StandIns.module`).
        let declared = StandIns.current?.module?.storedProperties(of: name).map { Dictionary($0, uniquingKeysWith: { a, _ in a }) }
        for field in fields {
            let n = field.type.leafWidths.count
            let scalarName = declared?[field.name].map { $0.split(separator: ".").last.map(String.init) ?? $0 }
            let text = render(field.type, values[offset..<(offset + n)], scalarName: scalarName)
            parts.append(name.isEmpty ? text : "\(field.name): \(text)")
            offset += n
        }
        return name.isEmpty ? "(" + parts.joined(separator: ", ") + ")" : "\(name)(" + parts.joined(separator: ", ") + ")"
    }

    /// A handle: a string's text, an Objective-C object's identity (plan item R6-1, so that two parameters that are one
    /// object show it), a numbered stand-in for a Foundation value (`OpaqueValues`; the same number is the same value
    /// within one counterexample), or `<any T>`.
    private static func opaque(_ name: String, _ handle: UInt64) -> String {
        if name == "String" { return text(handle) }
        if name == "object" { return "<object 0x\(String(handle, radix: 16))>" }
        if name == "Date" { return "Date(timeIntervalSinceReferenceDate: \(Verifier.floatLiteral(bits: handle, type: "Double")))" }
        guard OpaqueValues.types[name] != nil, let standIns = StandIns.current else { return "<any \(name)>" }
        return standIns.value(handle, of: name)
    }

    /// A string handle (`StringIdentity`): the literal it is, or else a stand-in text (`StandIns`).
    static func text(_ handle: UInt64) -> String {
        if let known = StringIdentity.text(of: handle) { return StringIdentity.swiftLiteral(known) }
        return StandIns.current.map { StringIdentity.swiftLiteral($0.text(for: handle)) } ?? "<a string not in the code>"
    }

    /// Texts for the strings of one counterexample that equal none of the code's literals: `"a"`, `"b"`, … each
    /// different from the others and from every text logic has met. A counterexample that survives `Verifier.honest`
    /// depends on such strings only through `==` and emptiness, so the stand-ins reproduce it.
    final class StandIns: @unchecked Sendable {
        @TaskLocal static var current: StandIns?
        /// The module whose declarations name the types of struct fields (`aggregate`); nil where none is at hand.
        let module: SILModule?
        init(module: SILModule? = nil) { self.module = module }
        private var given: [UInt64: String] = [:]
        private var next = 0

        func text(for handle: UInt64) -> String {
            if let text = given[handle] { return text }
            var text: String
            repeat {
                let letter = String(UnicodeScalar(UInt8(97 + next % 26)))
                text = next < 26 ? letter : letter + String(next / 26)
                next += 1
            } while StringIdentity.isSeen(text)
            given[handle] = text
            return text
        }

        private var numbered: [String: [UInt64: Int]] = [:]

        /// `<UUID 1>`, `<UUID 2>`, … for the handles of one opaque type, numbered in the order met.
        func value(_ handle: UInt64, of type: String) -> String {
            let number = numbered[type]?[handle] ?? (numbered[type]?.count ?? 0) + 1
            numbered[type, default: [:]][handle] = number
            return "<\(type) \(number)>"
        }
    }

    private static func scalar(_ value: UInt64, width: Int, name: String?) -> String {
        if width == 1 || name == "Bool" { return value & 1 == 1 ? "true" : "false" }
        if let name, name == "Double" || name == "Float" { return Verifier.floatLiteral(bits: value, type: name) }
        if let name, name.hasPrefix("UInt") { return String(value) }
        let shift = UInt64(64 - width)
        return String(Int64(bitPattern: value << shift) >> Int64(shift))
    }
}

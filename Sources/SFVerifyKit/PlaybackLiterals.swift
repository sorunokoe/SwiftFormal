import Foundation
import SFBV
import SFProve
import SFSIL

// Concrete playback of methods and getters (app study round 6, L19): the counterexample's `self` and arguments written as
// Swift (`State(selectedTabIndex: -9223372036854775808).selectedTab`), so `--emit-tests` covers the members of structs
// and enums, not only free functions over scalars. A struct is written with its memberwise initializer, as the compiler
// printed it in the SIL. A stored property that initializer does not take, or that has a default and no literal (an
// array, a UUID), is left to the initializer; the replay is kept only when a proof shows that the function traps
// whatever those properties hold.

/// A call that replays a counterexample of a method, or why there is none.
enum MethodReplay: Equatable {
    case call(String)
    case none(String)
}

extension Verifier {
    /// The conflict budget of the proof that a trap does not depend on the properties a replay leaves out.
    static let leftOutProofBudget = 200_000

    /// A replay of a trap in a method, getter, static method or initializer of a struct or enum of the module.
    /// Rendered inside the counterexample's stand-in scope (`ValueRenderer.StandIns`), so strings are the same texts
    /// as in `inputs`.
    static func methodReplay(_ values: [UInt64], info: FunctionInfo, function: SILFunction, module: SILModule) -> MethodReplay {
        guard let member = Member(info.displayName) else { return .none("an accessor other than a getter") }
        guard let receiver = function.parameterTypes.last else { return .none("no receiver in the SIL signature") }
        var writer = LiteralWriter(module: module)
        guard let list = arguments(values, info: info, function: function, writer: &writer) else {
            return .none(writer.problem ?? "an argument has no Swift literal")
        }
        let call: String
        switch member.kind {
        case .staticMethod: call = "\(member.type).\(member.name)(\(list))"
        case .initializer: call = "\(member.type)(\(list))"
        case .getter, .method:
            let leaves = values[(values.count - receiver.leafWidths.count)...]
            guard let value = writer.literal(receiver, text: member.type, leaves, omittable: false) else {
                return .none(writer.problem ?? "self has no Swift literal")
            }
            let isMutating = info.parameterTypes.last?.contains("@inout") ?? false
            call =
                member.kind == .getter
                ? "\(value).\(member.name)"
                : isMutating ? "{ var value = \(value); return value.\(member.name)(\(list)) }()" : "\(value).\(member.name)(\(list))"
        }
        if let problem = writer.problem { return .none(problem) }
        if !writer.free.isEmpty, !trapsWhatever(writer.free, values: values, info: info, function: function, module: module) {
            return .none("the trap may depend on stored properties a test cannot set (\(writer.leftOut.joined(separator: ", ")))")
        }
        return .call(call)
    }

    /// The arguments of a member call, labelled (`by: 3`), without the receiver (the last SIL parameter); nil when one
    /// has no literal.
    private static func arguments(_ values: [UInt64], info: FunctionInfo, function: SILFunction, writer: inout LiteralWriter) -> String? {
        let labels = info.argumentLabels
        var offset = 0
        var arguments: [String] = []
        for (index, type) in function.parameterTypes.dropLast().enumerated() {
            let count = type.leafWidths.count
            defer { offset += count }
            let text = index < info.parameterTypes.count ? declaredType(info.parameterTypes[index]) : type.description
            guard let argument = writer.literal(type, text: text, values[offset..<(offset + count)], omittable: false) else { return nil }
            arguments.append(index < labels.count && labels[index] != "_" ? "\(labels[index]): \(argument)" : argument)
        }
        return arguments.joined(separator: ", ")
    }

    /// Whether the function traps for every valid value of the leaves `free`, the others fixed to `values`: then a test
    /// that leaves those properties to the initializer still traps. A proof, checked like every other.
    static func trapsWhatever(_ free: [Int], values: [UInt64], info: FunctionInfo, function: SILFunction, module: SILModule) -> Bool {
        let widths = function.parameterWidths
        let outcome = try? proveReporting(inputWidths: free.map { widths[$0] }, conflictBudget: leftOutProofBudget) { c, bits in
            var inputs = zip(widths, values).map { c.constant($1, width: $0) }
            for (k, leaf) in free.enumerated() { inputs[leaf] = bits[k] }
            let f = try encodeLocated(module, c, symbol: info.symbol, arguments: inputs)
            var goal = c.or(-function.inputAssumption(c, inputs), f.trap)
            if let assumption = f.assumption { goal = c.or(-assumption, goal) }
            return goal
        }
        return outcome?.verdict == .proved
    }

    /// `Int` for `@guaranteed Int`, `Store.State` for `@inout Store.State`.
    static func declaredType(_ text: String) -> String {
        text.split(separator: " ").last.map(String.init) ?? text
    }
}

/// What kind of member a display name such as `Store.State.selectedTab.getter` or `static Bag.make(_:)` names.
struct Member {
    enum Kind { case getter, method, staticMethod, initializer }
    let kind: Kind
    let type: String
    let name: String

    init?(_ displayName: String) {
        var base = displayName.firstIndex(of: "(").map { String(displayName[..<$0]) } ?? displayName
        let isStatic = base.hasPrefix("static ")
        if isStatic { base.removeFirst("static ".count) }
        var parts = base.split(separator: ".").map(String.init)
        guard parts.count >= 2, let last = parts.popLast() else { return nil }
        if last == "getter" {
            guard parts.count >= 2, !isStatic, let property = parts.popLast() else { return nil }
            (kind, name) = (.getter, property)
        } else if displayName.contains("("), last == "init" {
            (kind, name) = (.initializer, last)
        } else if displayName.contains("("), !Self.accessors.contains(last) {
            (kind, name) = (isStatic ? .staticMethod : .method, last)
        } else {
            return nil
        }
        type = parts.joined(separator: ".")
    }

    private static let accessors: Set = ["setter", "modify", "read", "didset", "willset", "unsafeAddressor", "unsafeMutableAddressor"]
}

/// Writes counterexample values as Swift source, by layout and declared type. Leaves of a property it leaves to the
/// initializer go into `free`; anything it cannot write sets `problem`.
struct LiteralWriter {
    let module: SILModule
    /// Leaf indices (into the function's inputs) that the written source does not fix.
    private(set) var free: [Int] = []
    /// `State.items` for each property left to its initializer, for the message when the proof fails.
    private(set) var leftOut: [String] = []
    private(set) var problem: String?

    init(module: SILModule) { self.module = module }

    /// Swift source for `values` of `type`, declared as `text`; nil when there is none. With `omittable`, a missing
    /// literal is not a problem: the caller leaves the property to its default.
    mutating func literal(_ type: ValueType, text: String, _ values: ArraySlice<UInt64>, omittable: Bool) -> String? {
        let name = Self.plain(text)
        func fail(_ why: String) -> String? {
            if !omittable, problem == nil { problem = why }
            return nil
        }
        switch type {
        case .scalar(let width):
            guard Self.scalarNames.contains(name) else { return fail("\(name) has no Swift literal here") }
            return Verifier.render(values[values.startIndex], type: name, width: width)
        case .opaque(let opaque):
            guard opaque == "String" else { return fail("a \(opaque) has no Swift literal") }
            return ValueRenderer.text(values[values.startIndex])
        case .enumeration(let enumName, let cases):
            let tag = Int(values[values.startIndex])
            guard cases.indices.contains(tag) else { return fail("an invalid \(enumName)") }
            let range = type.payloadLeafRange(ofCase: tag)
            let payload = values[(values.startIndex + range.lowerBound)..<(values.startIndex + range.upperBound)]
            guard enumName.hasPrefix("Optional<") else { return enumLiteral(enumName, case: cases[tag], payload, omittable: omittable) }
            return cases[tag].payload.map { literal($0, text: Self.unwrapped(name), payload, omittable: omittable) } ?? "nil"
        case .aggregate(let structName, _):
            guard !structName.isEmpty else { return fail("a tuple has no literal here") }
            return structLiteral(structName, type, values, omittable: omittable)
        case .array, .hashed:
            return fail("\(type) has no Swift literal")
        }
    }

    private static let scalarNames: Set = [
        "Int", "Int8", "Int16", "Int32", "Int64", "UInt", "UInt8", "UInt16", "UInt32", "UInt64", "Bool", "Double", "Float",
    ]

    private mutating func enumLiteral(_ name: String, case value: ValueType.Case, _ payload: ArraySlice<UInt64>, omittable: Bool) -> String?
    {
        if let why = Self.privacy(of: name, in: module) { return omittable ? nil : setProblem(why) }
        guard let payloadType = value.payload else { return "\(name).\(value.name)" }
        guard let declared = module.cases(of: name)?.first(where: { $0.name == value.name })?.payload else {
            return omittable ? nil : setProblem("the cases of \(name) are not in the SIL")
        }
        // `(code: Int8, Bool)`: labels and types of each element; one unlabeled payload is stored as itself.
        let elements = Self.payloadElements(declared)
        let fields: [(ValueType, ArraySlice<UInt64>)]
        if elements.count == 1 && elements[0].label == nil {
            fields = [(payloadType, payload)]
        } else {
            guard case .aggregate(_, let tupleFields) = payloadType, tupleFields.count == elements.count else {
                return omittable ? nil : setProblem("the payload of \(name).\(value.name) does not match its declaration")
            }
            var offset = payload.startIndex
            fields = tupleFields.map { field in
                defer { offset += field.type.leafWidths.count }
                return (field.type, payload[offset..<(offset + field.type.leafWidths.count)])
            }
        }
        var parts: [String] = []
        for ((type, leaves), element) in zip(fields, elements) {
            guard let text = literal(type, text: element.type, leaves, omittable: false) else { return nil }
            parts.append(element.label.map { "\($0): \(text)" } ?? text)
        }
        return "\(name).\(value.name)(\(parts.joined(separator: ", ")))"
    }

    private mutating func structLiteral(_ name: String, _ type: ValueType, _ values: ArraySlice<UInt64>, omittable: Bool) -> String? {
        if let why = Self.privacy(of: name, in: module) { return omittable ? nil : setProblem(why) }
        guard case .aggregate(_, let fields) = type, let declaration = module.declaration(of: name),
            let stored = module.storedProperties(of: name), stored.count == fields.count
        else { return omittable ? nil : setProblem("\(name) is not a struct declared in the scanned code") }
        guard let initializer = MemberwiseInitializer(declaration, stored: stored.map(\.name)) else {
            return omittable ? nil : setProblem("\(name) has no memberwise initializer a test can call")
        }
        var offsets: [Int] = []
        var offset = values.startIndex
        for field in fields {
            offsets.append(offset)
            offset += field.type.leafWidths.count
        }
        func leaves(_ i: Int) -> ArraySlice<UInt64> { values[offsets[i]..<(offsets[i] + fields[i].type.leafWidths.count)] }
        var arguments: [String] = []
        var written: Set<Int> = []
        for parameter in initializer.parameters {
            let i = parameter.field
            let saved = (free, leftOut, problem)
            if let text = literal(fields[i].type, text: parameter.type, leaves(i), omittable: parameter.hasDefault) {
                arguments.append("\(parameter.label): \(text)")
                written.insert(i)
            } else if parameter.hasDefault {
                (free, leftOut, problem) = saved  // left to its default as a whole
            } else {
                return nil
            }
        }
        for i in fields.indices where !written.contains(i) {
            free += Array(leaves(i).indices)
            leftOut.append("\(name).\(stored[i].name)")
        }
        return "\(name)(\(arguments.joined(separator: ", ")))"
    }

    private mutating func setProblem(_ why: String) -> String? {
        if problem == nil { problem = why }
        return nil
    }

    /// `Int` for `Swift.Int`; `Tab?` and `Optional<Tab>` stay as they are.
    static func plain(_ text: String) -> String {
        let t = text.trimmingCharacters(in: .whitespaces)
        return t.hasPrefix("Swift.") ? String(t.dropFirst("Swift.".count)) : t
    }

    /// `Tab` for `Tab?` or `Optional<Tab>`.
    static func unwrapped(_ text: String) -> String {
        if text.hasSuffix("?") { return String(text.dropLast()) }
        if text.hasPrefix("Optional<"), text.hasSuffix(">") { return String(text.dropFirst("Optional<".count).dropLast()) }
        return text
    }

    /// Why a test cannot name `type`: it, or a type it is nested in, is `private` or `fileprivate`.
    static func privacy(of type: String, in module: SILModule) -> String? {
        let parts = type.split(separator: ".")
        for end in parts.indices {
            let name = parts[...end].joined(separator: ".")
            guard let header = module.declaration(of: name)?.header else { continue }
            let words = header.split(separator: " ")
            if words.contains("private") || words.contains("fileprivate") { return "\(name) is private (a test cannot name it)" }
        }
        return nil
    }

    /// The elements of an enum payload as declared: `(code: Int8, Bool)` gives [("code", "Int8"), (nil, "Bool")].
    static func payloadElements(_ text: String) -> [(label: String?, type: String)] {
        guard text.hasPrefix("("), text.hasSuffix(")") else { return [(nil, text)] }
        return splitAtTopLevelCommas(String(text.dropFirst().dropLast())).map { element in
            let e = element.trimmingCharacters(in: .whitespaces)
            if let colon = e.firstIndex(of: ":"), e[..<colon].allSatisfy({ $0.isLetter || $0.isNumber || $0 == "_" }) {
                return (String(e[..<colon]), String(e[e.index(after: colon)...]).trimmingCharacters(in: .whitespaces))
            }
            return (nil, e)
        }
    }
}

/// `text` split at the commas outside brackets, parentheses, angle brackets and string literals (default values such
/// as `= [1, 2]` included).
func splitAtTopLevelCommas(_ text: String) -> [String] {
    var parts: [String] = []
    var depth = 0
    var quoted = false
    var current = ""
    var previous: Character = " "
    for character in text {
        defer { previous = character }
        if character == "\"" && previous != "\\" { quoted.toggle() }
        if !quoted {
            if "([{<".contains(character) { depth += 1 }
            if ")]}".contains(character) || (character == ">" && previous != "-") { depth -= 1 }
            if character == ",", depth == 0 {
                parts.append(current.trimmingCharacters(in: .whitespaces))
                current = ""
                continue
            }
        }
        current.append(character)
    }
    let last = current.trimmingCharacters(in: .whitespaces)
    if !last.isEmpty { parts.append(last) }
    return parts
}

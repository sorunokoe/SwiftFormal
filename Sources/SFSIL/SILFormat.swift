import Foundation
import SFBV

// Reading guide
// `String(format:_:)` with a literal format: what it prints, and when it reads an argument it was not given.
//
// The arguments are an array literal of `any CVarArg` that the calling function builds (`init_existential_addr` of
// each element, then a `store`); its elements are read from the function's body (`FunctionIndex`), as the case texts
// of a `switch` are (`SILStringFacts.swift`). The format is parsed as `printf` reads it, and each conversion is
// matched with the argument it reads:
//
// - a conversion with no argument left, `%@` or `%s` given a number, a number conversion given a string, a floating
//   conversion given an integer or an integer conversion given a floating value, is undefined behaviour: a trap here;
// - `%d`, `%i` of a signed integer print its decimal text when the length modifier matches it: none for 32 bits or
//   fewer, `l`, `ll`, `q`, `z`, `j` or `t` for 64 bits (and none for 64 bits when the value fits an `Int32`). `h` and
//   `hh` narrow the value, and a 64-bit length reads a narrow argument zero-extended: some text logic does not model;
// - `%@` of a `String` prints the string; `%%` prints "%";
// - any other conversion, or one with flags or a width, prints some text logic does not model: non-empty for a number
//   conversion without a precision, and any text, empty included, for `%c`, `%C`, `%@` or a precision (`%.0d` of 0
//   prints nothing, as `%c` of 0 does).
//
// The pieces are joined as `+` joins them (`SILTextSplits.swift`). `String(format:)` without a locale does not use
// the user's locale. A format that is not a literal (a localized format) cannot be checked against its arguments:
// with opaque calls on (the default) it is assumed to match them, an assumption the report names.
// Part of `FunctionRun` (`SILFunctionRun.swift`).

enum TextFormat {
    static let symbol = "$sSS10FoundationE6format_S2Sh_s7CVarArg_pdtcfC"
    static let name = "String(format:_:)"
    static let assumption =
        "String(format:) with a format that is not a literal (a localized format) reads only the arguments it is given, of the types it expects"

    /// What an argument is, as a conversion reads it.
    enum Argument {
        case integer(signed: Bool, width: Int)
        case floating
        case string
    }

    static let arguments: [String: Argument] = [
        "Int": .integer(signed: true, width: 64), "Int64": .integer(signed: true, width: 64),
        "Int32": .integer(signed: true, width: 32), "Int16": .integer(signed: true, width: 16),
        "Int8": .integer(signed: true, width: 8), "UInt": .integer(signed: false, width: 64),
        "UInt64": .integer(signed: false, width: 64), "UInt32": .integer(signed: false, width: 32),
        "UInt16": .integer(signed: false, width: 16), "UInt8": .integer(signed: false, width: 8),
        "Double": .floating, "Float": .floating, "CGFloat": .floating, "String": .string,
    ]

    static func argument(_ type: String) -> Argument? {
        arguments[type.hasPrefix("Swift.") ? String(type.dropFirst(6)) : type]
    }

    /// A piece of a format: literal text, or a conversion.
    enum Piece: Equatable {
        case text(String)
        /// `position` is the argument it reads (from `n$`, or the next one); `plain` when it has no flags, width or
        /// precision; `length` its length modifier ("" for none); `precision` when it has one.
        case conversion(kind: Character, position: Int, plain: Bool, length: String, precision: Bool)
    }

    enum ParseError: Error { case unsupported(String) }

    /// The pieces of `format`, or why it is not read.
    static func parse(_ format: String) throws(ParseError) -> [Piece] {
        var reader = Reader(s: Array(format.unicodeScalars))
        var (pieces, text) = ([Piece](), "")
        while let scalar = reader.next() {
            guard scalar == "%" else {
                text.unicodeScalars.append(scalar)
                continue
            }
            guard let first = reader.peek() else { throw .unsupported("a format that ends with %") }
            if first == "%" {
                _ = reader.next()
                text += "%"
                continue
            }
            if !text.isEmpty { pieces.append(.text(text)) }
            text = ""
            pieces.append(try reader.conversion())
        }
        if !text.isEmpty { pieces.append(.text(text)) }
        return pieces
    }

    /// Reads a format as `printf` does.
    private struct Reader {
        let s: [Unicode.Scalar]
        var i = 0
        /// The argument a conversion with no `n$` reads.
        var following = 0

        func peek() -> Unicode.Scalar? { i < s.count ? s[i] : nil }

        mutating func next() -> Unicode.Scalar? {
            defer { i += 1 }
            return peek()
        }

        /// Reads scalars while `keep` holds them.
        mutating func read(while keep: (Unicode.Scalar) -> Bool) -> String {
            var out = ""
            while let x = peek(), keep(x) {
                out.unicodeScalars.append(x)
                i += 1
            }
            return out
        }

        /// The conversion after a `%`.
        mutating func conversion() throws(ParseError) -> Piece {
            let start = i
            let digits = read { ("0"..."9").contains($0) }
            var position = following
            if peek() == "$", let n = Int(digits), n >= 1 {
                position = n - 1
                i += 1
            } else {
                i = start
                following += 1
            }
            let flags = read { "-+ #0'".unicodeScalars.contains($0) }
            let size = read { ("0"..."9").contains($0) || $0 == "." || $0 == "*" }
            if size.contains("*") { throw .unsupported("a format with * (a width or precision read from the arguments)") }
            let length = read { "hlqLzjt".unicodeScalars.contains($0) }
            guard let scalar = next() else { throw .unsupported("a format that ends inside a conversion") }
            let kind = Character(scalar)
            guard "diouxXcCeEfFgGaA@sSp".contains(kind) else { throw .unsupported("the conversion %\(kind)") }
            return .conversion(
                kind: kind, position: position, plain: flags.isEmpty && size.isEmpty, length: length, precision: size.contains("."))
        }
    }

    /// The length modifiers with which `%d` reads 64 bits.
    static let wide: Set<String> = ["l", "ll", "q", "z", "j", "t"]

    /// Why conversion `kind` with `length` may not read `argument`; nil when it may.
    static func mismatch(_ kind: Character, _ length: String, _ argument: Argument) -> String? {
        if length.contains("L"), case .floating = argument { return "%L\(kind) given a Double (it reads a long double)" }
        return switch (kind, argument) {
        case ("@", .string): nil
        case ("@", _): "%@ given a number"
        case ("s", _), ("S", _): "%\(kind) given a Swift value (it reads a C string)"
        case (_, .string) where kind != "p": "%\(kind) given a String"
        case (_, .integer) where "eEfFgGaA".contains(kind): "%\(kind) given an integer"
        case (_, .floating) where "diouxXcCp".contains(kind): "%\(kind) given a floating-point value"
        default: nil
        }
    }
}

extension FunctionRun {
    /// Encodes `request` when `target` is `String(format:_:)`; false when it is not.
    func encodeFormat(_ target: String, _ request: SummarizedCall) throws -> Bool {
        guard target == TextFormat.symbol else { return false }
        guard request.names.count == 3, request.type.leafWidths == [64] else {
            throw SILError.invalid("\(TextFormat.name) of unexpected shape at \(request.id)")
        }
        let text = StdlibSummary.Text(c: c)
        guard let literal = text.known(try flat(request.names[0])[0]) else {
            guard module.opaqueCalls == .all else {
                throw SILError.unsupported("\(TextFormat.name) with a format that is not a literal \(OpaqueCallMode.strictNote)")
            }
            env[request.id] = make(request.type, [c.input(width: 64)])
            out.approximations.insert(TextFormat.name)
            Assumptions.note(TextFormat.assumption)
            return true
        }
        let pieces: [TextFormat.Piece]
        do {
            pieces = try TextFormat.parse(literal)
        } catch .unsupported(let why) {
            throw SILError.unsupported("\(TextFormat.name) with \(why)")
        }
        let arguments = try formatArguments(request.names[1])
        var (value, exact) = (text.empty ?? c.input(width: 64), true)
        for piece in pieces {
            let part: (value: BV, exact: Bool)
            switch printed(piece, arguments, text) {
            case .success(let printed): part = printed
            case .failure(let trap): return try formatTrap(request, trap.message)
            }
            let joined = text.concatenate(value, part.value)
            (value, exact) = (joined.value, exact && joined.exact && part.exact)
        }
        env[request.id] = make(request.type, [value])
        if !exact { out.approximations.insert(TextFormat.name) }
        return true
    }

    struct FormatTrap: Error { let message: String }

    /// What `piece` prints, or the undefined behaviour of reading its argument.
    private func printed(
        _ piece: TextFormat.Piece, _ arguments: [(TextFormat.Argument, [BV])], _ text: StdlibSummary.Text
    ) -> Result<(value: BV, exact: Bool), FormatTrap> {
        switch piece {
        case .text(let t):
            return .success(text.handle(t).map { ($0, true) } ?? (text.empty.map(text.nonEmpty) ?? c.input(width: 64), false))
        case .conversion(let kind, let position, _, let length, _):
            guard arguments.indices.contains(position) else {
                return .failure(
                    FormatTrap(message: "\(TextFormat.name) reads argument \(position + 1) of \(arguments.count): undefined behaviour"))
            }
            let (argument, leaves) = arguments[position]
            if let why = TextFormat.mismatch(kind, length, argument) {
                return .failure(FormatTrap(message: "\(TextFormat.name): \(why), undefined behaviour"))
            }
            return .success(formatted(piece, argument, leaves, text))
        }
    }

    private func formatted(
        _ conversion: TextFormat.Piece, _ argument: TextFormat.Argument, _ leaves: [BV], _ text: StdlibSummary.Text
    ) -> (value: BV, exact: Bool) {
        guard case .conversion(let kind, _, let plain, let length, let precision) = conversion else { return (c.input(width: 64), false) }
        // Any text, the empty one included.
        let unknown = c.input(width: 64)
        // `%c` of 0 and a precision of 0 of 0 (`%.0d`, `%.0x`) print nothing; every other number conversion a digit.
        let some = kind == "c" || kind == "C" || kind == "@" || precision ? unknown : text.empty.map(text.nonEmpty) ?? unknown
        switch argument {
        case .string:
            // `%p` of a String prints an address.
            return kind == "@" && plain ? (leaves[0], true) : (some, false)
        case .integer(let signed, let width):
            guard plain, kind == "d" || kind == "i", signed, leaves.count == 1 else { return (some, false) }
            let n = leaves[0]
            let decimal = text.decimal(n, signed: true)
            switch (length, width) {
            case ("", ...32): return decimal
            case (let length, 64) where TextFormat.wide.contains(length): return decimal
            case ("", 64):
                // `%d` reads the low 32 bits of an Int: its decimal text only when the value fits.
                let fits = c.and(
                    -c.slt(n, c.constant(UInt64(bitPattern: Int64(Int32.min)), width: 64)), c.slt(n, c.constant(1 << 31, width: 64)))
                return (c.select(fits, decimal.value, some), false)
            // `h` and `hh` narrow the value; a 64-bit length reads a narrow argument zero-extended.
            default: return (some, false)
            }
        case .floating:
            return (some, false)
        }
    }

    /// Encodes an existential box or an existential address.
    func encodeExistential(_ instruction: Instruction) throws {
        switch instruction {
        case .existentialBox(let id, let payload): try encodeExistentialBox(id, payload)
        case .existentialAddress(let id, let base, let payload): try encodeExistentialAddress(id, base, payload)
        default: throw SILError.invalid("not an existential instruction")
        }
    }

    /// Encodes `Instruction.existentialAddress`: only an element of an array under construction, whose stores are
    /// dropped (`formatArguments` reads them from the body).
    func encodeExistentialAddress(_ id: String, _ base: String, _ payload: String) throws {
        if case .address(.slot(let slot, 0, _)) = env[base], let element = literalSlots[slot] {
            // An element of an array literal: its contents are not modelled.
            unknownLiterals.insert(element.literal.slot)
        } else if case .address(.sink) = env[base] {
        } else {
            throw SILError.unsupported("init_existential_addr of \(payload) outside an array literal")
        }
        guard module.destroysWithoutModuleCode(payload) else {
            throw SILError.unsupported("an existential holding \(payload), whose destruction may run code of this module")
        }
        env[id] = .address(.sink)
    }

    private func formatTrap(_ request: SummarizedCall, _ message: String) throws -> Bool {
        trap(c.trueLit, site: .stdlib(id: request.id, message: message))
        env[request.id] = make(request.type, [c.input(width: 64)])
        return true
    }

    /// Whether `operation` allocates or finalizes an `[any CVarArg]` literal whose elements are each initialised only
    /// by `init_existential_addr` (whose payload type `encodeExistentialAddress` checks): destroying it then runs no
    /// code of this module, even when the module has types that conform to `CVarArg`.
    func holdsCheckedFormatArguments(
        _ operation: StdlibSummary.ArrayOperation, _ substitution: String, _ request: SummarizedCall
    ) -> Bool {
        guard substitution == "any CVarArg" else { return false }
        let index = FunctionIndex(function)
        switch operation {
        case .make(.allocate):
            let array = index.defined.first {
                guard case .extract(_, request.id, 0, .tuple) = $0.value else { return false }
                return true
            }?.key
            return array.flatMap { formatLiteralPayloads($0, index) } != nil
        case .make(.finalize): return request.names.first.flatMap { formatLiteralPayloads($0, index) } != nil
        default: return false
        }
    }

    /// Whether `argument`, passed as a `parameter` to a call with no body, is an `[any CVarArg]` literal of standard
    /// numbers and strings: the callee can only print them, as `String(format:)` does, and runs no code of this module.
    func isFormatArgumentLiteral(_ parameter: String, _ argument: String) -> Bool {
        guard ["Array<any CVarArg>", "[any CVarArg]"].contains(parameter),
            let payloads = formatLiteralPayloads(argument, FunctionIndex(function))
        else { return false }
        return payloads.allSatisfy { TextFormat.argument($0) != nil }
    }

    /// The payload types of the `[any CVarArg]` array literal `array` when each of its elements is initialised only by
    /// `init_existential_addr`; nil when it is not such a literal.
    private func formatLiteralPayloads(_ array: String, _ index: FunctionIndex) -> [String]? {
        guard let (name, allocation) = index.allocation(of: array),
            case .apply(_, _, let counts, _, _, _) = index.defined[allocation], counts.count == 1,
            case .literal(_, _, let n) = index.defined[counts[0]], n >= 1, n <= SILEncoder.maxLiteralElements,
            let base = index.elementBase(of: name), let elements = index.elementAddresses(base: base, count: n)
        else { return nil }
        let addresses = Set(elements)
        var payloads: [String] = []
        for instruction in function.blocks.flatMap(\.instructions) {
            switch instruction {
            case .existentialAddress(_, let element, let type) where addresses.contains(element): payloads.append(type)
            case .indexAddress(_, base, let k):
                guard case .literal = index.defined[k] else { return nil }
            default:
                guard addresses.isDisjoint(with: Self.operands(of: instruction)) else { return nil }
            }
        }
        return payloads
    }

    /// Every name `instruction` reads (every string in its payload but the name it defines): a conservative over-approximation.
    static func operands(of instruction: Instruction) -> Set<String> {
        var names: Set<String> = []
        func collect(_ value: Any) {
            if let name = value as? String {
                names.insert(name)
            } else {
                for child in Mirror(reflecting: value).children { collect(child.value) }
            }
        }
        collect(instruction)
        if let defined = instruction.definedName { names.remove(defined) }
        return names
    }

    /// The arguments of the `[any CVarArg]` array literal `array` this function builds: each one's kind and value.
    private func formatArguments(_ array: String) throws -> [(TextFormat.Argument, [BV])] {
        let index = FunctionIndex(function)
        guard let (name, allocation) = index.allocation(of: array), case .apply(_, _, let counts, _, _, _) = index.defined[allocation],
            counts.count == 1, case .literal(_, _, let n) = index.defined[counts[0]], n <= 64
        else { throw SILError.unsupported("\(TextFormat.name) with arguments that are not an array literal") }
        if n == 0 { return [] }
        guard let base = index.elementBase(of: name), let elements = index.elementAddresses(base: base, count: n) else {
            throw SILError.unsupported("\(TextFormat.name) with arguments that are not an array literal")
        }
        var payloads: [String: [(address: String, type: String)]] = [:]
        for case .existentialAddress(let address, let element, let type) in index.defined.values {
            payloads[element, default: []].append((address, type))
        }
        return try elements.map { element in
            guard let payload = payloads[element], payload.count == 1, let stores = index.stores[payload[0].address], stores.count == 1,
                stores[0].block == index.block[allocation]
            else {
                throw SILError.unsupported(
                    "\(TextFormat.name) with an argument that is already an `any CVarArg` (it may be an object of a read module)")
            }
            guard let argument = TextFormat.argument(payload[0].type) else {
                throw SILError.unsupported("\(TextFormat.name) with a \(payload[0].type) argument")
            }
            let leaves = try flat(stores[0].value)
            guard leaves.count == 1 else { throw SILError.unsupported("\(TextFormat.name) with a \(payload[0].type) argument") }
            if case .integer(_, let width) = argument, leaves[0].width != width {
                throw SILError.invalid("\(TextFormat.name): a \(payload[0].type) argument of \(leaves[0].width) bits")
            }
            return (argument, [leaves[0]])
        }
    }
}

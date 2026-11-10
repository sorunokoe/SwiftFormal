// Reading guide
// Swift's in-memory layout of a value of a SIL type (`SwiftShape`), and the bytes a value's SIL leaves make in it
// (`image`). Written from the Swift ABI (TypeLayout.rst and the enum layout rules), not taken from either encoder: it
// reads SIL *types* only (`ValueType`), never the SIL encoder's semantics. `LLVMBridge.swift` cuts these bytes into the
// IR's parameters and results. A type whose layout this file does not know for certain is refused (`unsupported`).
// Tests: Tests/SFOracleTests/LLVMBridgeTests.swift (real compiler output), Tests/SFVerifyKitTests/CrossCheckTests.swift.

import SFBV
import SFCNF
import SFSIL

/// Swift's in-memory layout of a value of a SIL type, and how its SIL leaves fill those bytes.
indirect enum SwiftShape {
    /// An integer leaf: `i1` is a `Bool` byte (the value in bit 0, the other bits zero), wider ones fill their bytes.
    case integer(Int)
    /// A value logic keeps as one 64-bit handle (`String`, a closure, an array's count): `words` 8-byte words in memory.
    /// The words are a one-to-one function of the handle (`handleWords`), so the IR can only agree by moving them
    /// unchanged. `nonzero`: Swift keeps such a value's words away from zero (a string's object, a closure's function,
    /// an array's buffer are never null), which an `Optional` uses for `nil`; the encoding keeps them nonzero too.
    case handle(words: Int, nonzero: Bool)
    /// `Optional` of a `nonzero` handle: `nil` is all zero bytes, as Swift stores it in the payload's extra inhabitant.
    case nullableHandle(payload: SwiftShape, someCase: Int)
    case record(fields: [(offset: Int, shape: SwiftShape)], size: Int, align: Int)
    /// An enum without payloads: the case index (declaration order) in `size` bytes; no bytes for a single case.
    case plainEnum(cases: Int, size: Int)
    /// An enum with exactly one payload case whose payload has no unused bit patterns (only full-width integers), so
    /// Swift adds a tag byte after it: 0 for the payload case, 1 for the others, whose index (among the cases without
    /// payload, in declaration order) fills the payload bytes. No tag byte when it is the only case.
    case singlePayloadEnum(payload: SwiftShape, payloadCase: Int, cases: Int)
    /// An enum with one payload case whose payload is one byte with values to spare (a `Bool`, an enum without
    /// payloads, or such an enum again): the other cases take the spare values in order, after the payload's own
    /// (`Bool?` is 2 for `nil`).
    case byteEnum(payload: SwiftShape, payloadCase: Int, cases: Int)
    /// An enum with several payload cases, one of which fills the whole payload area with no bit pattern to spare, so
    /// Swift adds a tag byte after the area: the payload cases' order among themselves, then their count for every
    /// other case, whose index (among the cases without payload) fills the area. Bytes beyond a payload's own size mean
    /// nothing in that case.
    case taggedEnum(payloads: [Int: SwiftShape], cases: Int, area: Int)

    var size: Int {
        switch self {
        case .integer(let w): w == 1 ? 1 : w / 8
        case .handle(let words, _): words * 8
        case .nullableHandle(let payload, _): payload.size
        case .record(_, let size, _): size
        case .plainEnum(_, let size): size
        case .singlePayloadEnum(let payload, _, let cases): payload.size + (cases > 1 ? 1 : 0)
        case .byteEnum: 1
        case .taggedEnum(_, _, let area): area + 1
        }
    }

    var align: Int {
        switch self {
        case .integer(let w): w == 1 ? 1 : w / 8
        case .handle, .nullableHandle: 8
        case .record(_, _, let align): align
        case .plainEnum(_, let size): max(1, size)
        case .singlePayloadEnum(let payload, _, _): payload.align
        case .byteEnum: 1
        case .taggedEnum(let payloads, _, _): payloads.values.map(\.align).max() ?? 1
        }
    }

    /// For a one-byte value with values to spare: how many of the 256 byte values it uses (0 up to that count).
    var byteValues: Int? {
        switch self {
        case .integer(1): 2
        case .plainEnum(let n, 1): n
        case .byteEnum(let payload, _, let cases): payload.byteValues.map { $0 + cases - 1 }
        case .record(let fields, 1, _) where fields.count == 1: fields[0].shape.byteValues
        default: nil
        }
    }

    /// True when every bit pattern of the bytes is a value: no spare bits Swift could use for an enum's other cases.
    var usesEveryBitPattern: Bool {
        switch self {
        case .integer(let w): w >= 8
        case .record(let fields, _, _): fields.allSatisfy { $0.shape.usesEveryBitPattern }
        case .handle, .nullableHandle, .plainEnum, .singlePayloadEnum, .byteEnum, .taggedEnum: false
        }
    }

    /// The SIL leaves this shape reads, as `ValueType.leafWidths` lays them out.
    var leafCount: Int {
        switch self {
        case .integer, .handle, .plainEnum: 1
        case .nullableHandle: 2
        case .record(let fields, _, _): fields.reduce(0) { $0 + $1.shape.leafCount }
        case .singlePayloadEnum(let payload, _, _), .byteEnum(let payload, _, _): 1 + payload.leafCount
        case .taggedEnum(let payloads, _, _): 1 + payloads.values.reduce(0) { $0 + $1.leafCount }
        }
    }

    init(_ type: ValueType, depth: Int = 0) throws {
        guard depth < 32 else { throw LLVMError.unsupported("cross-check: type nesting too deep") }
        switch type {
        case .scalar(let w):
            guard [1, 8, 16, 32, 64].contains(w) else { throw LLVMError.unsupported("cross-check: layout of a \(w)-bit integer") }
            self = .integer(w)
        case .opaque(let name):
            self = try Self.opaque(name)
        case .array, .hashed:
            self = .handle(words: 1, nonzero: true)
        case .aggregate(_, let fields):
            self = try Self.record(try fields.map { try SwiftShape($0.type, depth: depth + 1) })
        case .enumeration(let name, let cases):
            self = try Self.enumeration(name, try cases.map { try $0.payload.map { try SwiftShape($0, depth: depth + 1) } })
        }
    }

    private static func opaque(_ name: String) throws -> SwiftShape {
        switch name {
        case "String", "Character", "closure": return .handle(words: 2, nonzero: true)
        case "KeyPath", "Builtin.RawPointer": return .handle(words: 1, nonzero: false)
        default: throw LLVMError.unsupported("cross-check: the IR layout of \(name) is not known to the bridge")
        }
    }

    /// Fields in declaration order, each at the next offset its alignment allows; the size has no tail padding.
    private static func record(_ shapes: [SwiftShape]) throws -> SwiftShape {
        var placed: [(offset: Int, shape: SwiftShape)] = []
        var offset = 0, align = 1
        for shape in shapes {
            offset = (offset + shape.align - 1) / shape.align * shape.align
            placed.append((offset, shape))
            offset += shape.size
            align = max(align, shape.align)
        }
        return .record(fields: placed, size: offset, align: align)
    }

    /// `payloads[k]` is the shape of case `k`'s payload, nil for a case without one.
    private static func enumeration(_ name: String, _ payloads: [SwiftShape?]) throws -> SwiftShape {
        let carrying = payloads.indices.filter { payloads[$0] != nil }
        if carrying.isEmpty {
            let n = payloads.count
            return .plainEnum(cases: n, size: n <= 1 ? 0 : n <= 256 ? 1 : n <= 65536 ? 2 : 4)
        }
        if carrying.count > 1 { return try multiPayload(name, payloads) }
        guard let payloadCase = carrying.first, let payload = payloads[payloadCase] else {
            throw LLVMError.invalid("cross-check: enum \(name) has no payload case")
        }
        return try onePayload(name, payload, payloadCase: payloadCase, cases: payloads.count)
    }

    private static func onePayload(_ name: String, _ payload: SwiftShape, payloadCase: Int, cases: Int) throws -> SwiftShape {
        if cases == 2, case .handle(_, true) = payload { return .nullableHandle(payload: payload, someCase: payloadCase) }
        if cases > 1, let used = payload.byteValues, used + cases - 1 <= 256 {
            return .byteEnum(payload: payload, payloadCase: payloadCase, cases: cases)
        }
        if cases > 1 {
            guard payload.usesEveryBitPattern, payload.size > 0 else {
                throw LLVMError.unsupported("cross-check: enum \(name) may keep its other cases in spare bits of its payload")
            }
            let indexBits = 8 * min(payload.size, 4)
            guard indexBits >= 32 || (cases - 1) < 1 << indexBits else {
                throw LLVMError.unsupported("cross-check: enum \(name) has too many cases for its payload bytes")
            }
        }
        return .singlePayloadEnum(payload: payload, payloadCase: payloadCase, cases: cases)
    }

    private static func multiPayload(_ name: String, _ payloads: [SwiftShape?]) throws -> SwiftShape {
        var shapes: [Int: SwiftShape] = [:]
        for (k, payload) in payloads.enumerated() { if let payload { shapes[k] = payload } }
        let area = shapes.values.map(\.size).max() ?? 0
        guard shapes.values.contains(where: { $0.usesEveryBitPattern && $0.size == area && area > 0 }) else {
            throw LLVMError.unsupported("cross-check: enum \(name) may keep its tag in spare bits of its payloads")
        }
        let empty = payloads.count - shapes.count
        let indexBits = 8 * min(area, 4)
        guard indexBits >= 32 || empty <= 1 << indexBits, shapes.count + (empty > 0 ? 1 : 0) < 256 else {
            throw LLVMError.unsupported("cross-check: enum \(name) needs more than one tag byte")
        }
        return .taggedEnum(payloads: shapes, cases: payloads.count, area: area)
    }

    /// The words of a handle `h` (64 bits, least significant first). One word: `h`, or `h` with its top bit set when it
    /// must be nonzero (an array's count, below 2^48 in every real array, so still one-to-one). Two words:
    /// `(h >> 1) | 2^63` and `2 | (h & 1)`, both nonzero and together one-to-one.
    static func handleWords(_ h: [Int32], words: Int, nonzero: Bool, _ c: CNFBuilder) throws -> [Int32] {
        guard h.count == 64 else { throw LLVMError.invalid("cross-check: a handle is not 64 bits") }
        switch words {
        case 1: return nonzero ? Array(h[0..<63]) + [c.trueLit] : h
        case 2:
            let high = Array(h[1..<64]) + [c.trueLit]
            let low = [h[0], c.trueLit] + Array(repeating: c.falseLit, count: 62)
            return high + low
        default: throw LLVMError.unsupported("cross-check: a handle of \(words) words")
        }
    }
}

/// One bit of a value's bytes, and whether it carries meaning (padding does not, and is never compared).
struct ImageBit {
    let bit: Int32
    /// True where the bit is part of the value; false for padding. A literal, because inside an enum whether a byte
    /// is padding depends on the active case.
    let meaningful: Int32
}

/// Which case of an enum value is active, by its SIL tag, relative to the one payload case.
private struct ActiveCase {
    let tag: BV
    let payloadCase: Int
    let cases: Int

    func isCase(_ k: Int, _ c: CNFBuilder) -> Int32 { c.eq(tag, c.constant(UInt64(k), width: tag.width)) }

    /// `value(i)` for the active case, `i` its index among the cases other than the payload case, in `width` bits
    /// (zero where the payload case is active).
    func perOtherCase(width: Int, _ c: CNFBuilder, value: (Int) -> UInt64) -> BV {
        var chosen = c.constant(0, width: width)
        for k in 0..<cases where k != payloadCase {
            chosen = c.select(isCase(k, c), c.constant(value(k < payloadCase ? k : k - 1), width: width), chosen)
        }
        return chosen
    }
}

extension SwiftShape {
    /// The bytes of the value whose leaves are `leaves` (8 bits per byte, least significant first). Padding bits are
    /// `padding()`: fresh inputs for an argument, anything for an expected result.
    func image(_ c: CNFBuilder, _ leaves: ArraySlice<BV>, padding: () -> Int32) throws -> [ImageBit] {
        guard leaves.count == leafCount else { throw LLVMError.invalid("cross-check: leaf count does not match the layout") }
        if case .record = self { return try recordImage(c, leaves, padding: padding) }
        // Every other shape starts with a leaf: the value, or an enum's tag.
        guard let first = leaves.first else { throw LLVMError.invalid("cross-check: no leaves for \(self)") }
        let rest = leaves.dropFirst()
        switch self {
        case .integer, .handle, .plainEnum:
            return try leafImage(first, c)
        case .nullableHandle(let payload, let someCase):
            let some = c.eq(first, c.constant(UInt64(someCase), width: first.width))
            return try payload.image(c, rest, padding: padding).map { ImageBit(bit: c.and(some, $0.bit), meaningful: c.trueLit) }
        case .record:
            return try recordImage(c, leaves, padding: padding)  // handled above; kept for exhaustiveness
        case .singlePayloadEnum(let payload, let payloadCase, let cases):
            let inner = try payload.image(c, rest, padding: padding)
            return cases > 1 ? Self.extraTagImage(inner, ActiveCase(tag: first, payloadCase: payloadCase, cases: cases), c) : inner
        case .byteEnum(let payload, let payloadCase, let cases):
            guard let used = payload.byteValues else { throw LLVMError.invalid("cross-check: byte enum payload") }
            let inner = try payload.image(c, rest, padding: padding)
            return Self.spareValueImage(inner, used: used, ActiveCase(tag: first, payloadCase: payloadCase, cases: cases), c)
        case .taggedEnum:
            return try taggedImage(c, leaves, padding: padding)
        }
    }

    /// The bytes of a shape made of one leaf.
    private func leafImage(_ leaf: BV, _ c: CNFBuilder) throws -> [ImageBit] {
        switch self {
        case .integer(let w):
            guard leaf.width == w else { throw LLVMError.invalid("cross-check: leaf width does not match the layout") }
            return Self.meaningful(w == 1 ? leaf.bits + Array(repeating: c.falseLit, count: 7) : leaf.bits, c)
        case .handle(let words, let nonzero):
            return Self.meaningful(try Self.handleWords(leaf.bits, words: words, nonzero: nonzero, c), c)
        case .plainEnum(_, let size):
            guard size > 0 else { return [] }
            guard leaf.width <= size * 8 else { throw LLVMError.invalid("cross-check: enum tag wider than its bytes") }
            return Self.meaningful(c.zeroExtend(leaf, to: size * 8).bits, c)
        default:
            throw LLVMError.invalid("cross-check: \(self) is not made of one leaf")
        }
    }

    private static func meaningful(_ bits: [Int32], _ c: CNFBuilder) -> [ImageBit] {
        bits.map { ImageBit(bit: $0, meaningful: c.trueLit) }
    }

    private func recordImage(_ c: CNFBuilder, _ leaves: ArraySlice<BV>, padding: () -> Int32) throws -> [ImageBit] {
        guard case .record(let fields, let size, _) = self else { throw LLVMError.invalid("cross-check: not a record") }
        var bits = (0..<(size * 8)).map { _ in ImageBit(bit: padding(), meaningful: c.falseLit) }
        var next = leaves.startIndex
        for field in fields {
            let n = field.shape.leafCount
            let part = try field.shape.image(c, leaves[next..<(next + n)], padding: padding)
            for (k, bit) in part.enumerated() { bits[field.offset * 8 + k] = bit }
            next += n
        }
        return bits
    }

    /// A payload followed by a tag byte: 0 and the payload where the payload case is active, else 1 and the index of the
    /// case among the cases without payload.
    private static func extraTagImage(_ inner: [ImageBit], _ active: ActiveCase, _ c: CNFBuilder) -> [ImageBit] {
        let isPayload = active.isCase(active.payloadCase, c)
        let empty = active.perOtherCase(width: inner.count, c) { UInt64($0) }
        let payload = zip(inner, empty.bits).map { p, e in
            ImageBit(bit: c.mux(isPayload, p.bit, e), meaningful: c.mux(isPayload, p.meaningful, c.trueLit))
        }
        return payload + meaningful([-isPayload] + Array(repeating: c.falseLit, count: 7), c)
    }

    /// One byte: the payload's where the payload case is active, else the spare value `used + index` of the case.
    private static func spareValueImage(_ inner: [ImageBit], used: Int, _ active: ActiveCase, _ c: CNFBuilder) -> [ImageBit] {
        let isPayload = active.isCase(active.payloadCase, c)
        let spare = active.perOtherCase(width: 8, c) { UInt64(used + $0) }
        return zip(inner, spare.bits).map { p, e in ImageBit(bit: c.mux(isPayload, p.bit, e), meaningful: c.trueLit) }
    }

    private func taggedImage(_ c: CNFBuilder, _ leaves: ArraySlice<BV>, padding: () -> Int32) throws -> [ImageBit] {
        guard case .taggedEnum(let payloads, let cases, let area) = self else { throw LLVMError.invalid("cross-check: not a tagged enum") }
        let tag = leaves[leaves.startIndex]
        func isCase(_ k: Int) -> Int32 { c.eq(tag, c.constant(UInt64(k), width: tag.width)) }
        // A case without payload: its index (among those cases) fills the area, and the tag byte is the payload count.
        var emptyIndex = c.constant(0, width: area * 8)
        for (order, k) in (0..<cases).filter({ payloads[$0] == nil }).enumerated() {
            emptyIndex = c.select(isCase(k), c.constant(UInt64(order), width: area * 8), emptyIndex)
        }
        var bits = Self.meaningful(emptyIndex.bits, c)
        var tagByte = c.constant(UInt64(payloads.count), width: 8)
        var next = leaves.startIndex + 1
        for (order, k) in payloads.keys.sorted().enumerated() {
            guard let shape = payloads[k] else { continue }
            let inner = try shape.image(c, leaves[next..<(next + shape.leafCount)], padding: padding)
            next += shape.leafCount
            let active = isCase(k)
            for position in 0..<(area * 8) {
                let p = position < inner.count ? inner[position] : ImageBit(bit: padding(), meaningful: c.falseLit)
                bits[position] = ImageBit(
                    bit: c.mux(active, p.bit, bits[position].bit), meaningful: c.mux(active, p.meaningful, bits[position].meaningful))
            }
            tagByte = c.select(active, c.constant(UInt64(order), width: 8), tagByte)
        }
        return bits + Self.meaningful(tagByte.bits, c)
    }
}

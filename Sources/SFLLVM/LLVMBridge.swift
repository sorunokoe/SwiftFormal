// Reading guide
// The bridge between the two readers' views of one function's signature, for the SIL ≡ IR cross-check.
// SIL keeps a value as leaves (`ValueType.leafWidths`); the IR passes it the way Swift's calling convention lowers it:
// as the bytes of the value in memory, cut into integer and pointer pieces (a `Point(x: Int32, y: Int32)` is one i64),
// or by reference when it is large (`ptr dereferenceable(N)`), and a large result through an `sret` pointer.
// `SwiftShape` (`SwiftShape.swift`) is Swift's own memory layout of a SIL type, written from the Swift ABI, not taken
// from either encoder. The bridge reads SIL *types* only (`parameterTypes`, `resultType`); it never calls into the SIL
// encoder's semantics, so the two encodings stay independent.
// Every mismatch between the predicted layout and what the IR header says is a refusal (`unsupported`), never a guess.
// Tests: Tests/SFOracleTests/LLVMBridgeTests.swift (agreement and planted disagreements), Tests/SFVerifyKitTests/CrossCheckTests.swift.

import SFBV
import SFCNF
package import SFProve
package import SFSIL

/// How one IR piece (a parameter, or a field of a direct result) sits in a value's bytes.
private struct Piece {
    let offset: Int
    let type: LType
    var bytes: Int { if case .int(let n) = type { max(1, n / 8) } else { 8 } }
}

/// The natural size and alignment of a piece of type `type` (an integer or a pointer).
private func pieceAlignment(_ type: LType) throws -> Int {
    switch type {
    case .int(let n) where n == 1: return 1
    case .int(let n) where n % 8 == 0 && n <= 64:
        var a = 1
        while a < n / 8 { a *= 2 }
        return a
    case .ptr: return 8
    default: throw LLVMError.unsupported("cross-check: IR piece of type \(type.description)")
    }
}

/// The IR pieces of a value of `size` bytes, taken from the front of `types` in order, each at the next offset its
/// alignment allows, until the value's bytes are used up. Nil when they do not fit exactly.
private func cut(_ types: ArraySlice<LType>, size: Int) throws -> [Piece]? {
    var pieces: [Piece] = []
    var offset = 0
    var rest = types
    while offset < size, let type = rest.first {
        let align = try pieceAlignment(type)
        offset = (offset + align - 1) / align * align
        let piece = Piece(offset: offset, type: type)
        guard offset + piece.bytes <= size else { return nil }
        pieces.append(piece)
        offset += piece.bytes
        rest = rest.dropFirst()
    }
    return offset == size ? pieces : nil
}

/// The bits of `piece` in `image`. An `i1` piece reads bit 0 and requires the rest of its byte to be zero.
private func bits(of piece: Piece, in image: [ImageBit], _ c: CNFBuilder) throws -> [ImageBit] {
    let start = piece.offset * 8
    guard start + piece.bytes * 8 <= image.count else { throw LLVMError.invalid("cross-check: piece outside the value") }
    if piece.type == .int(1) {
        let high = image[(start + 1)..<(start + 8)]
        guard high.allSatisfy({ $0.bit == c.falseLit && $0.meaningful == c.trueLit }) else {
            throw LLVMError.unsupported("cross-check: an i1 piece where the value's byte is not a Bool")
        }
        return [image[start]]
    }
    return Array(image[start..<(start + piece.bytes * 8)])
}

/// How each SIL parameter reaches the IR function.
private enum Passing {
    case direct([Piece])
    case byReference
    case absent
}

/// How the IR function's signature carries SIL's: decided once from the two headers, before any proof.
private struct BridgePlan {
    let resultShape: SwiftShape
    /// The result comes back through an `sret` first parameter.
    let sret: Bool
    /// Otherwise, the pieces of the IR result (none for `void`).
    let resultPieces: [Piece]
    let shapes: [SwiftShape]
    let passing: [Passing]

    init(sil: SILFunction, llvm: LLVMFunction) throws {
        guard sil.errorType == nil, sil.objectParameter == nil, !sil.returnsObject else {
            throw LLVMError.unsupported("cross-check: throwing functions and class references are not bridged")
        }
        guard sil.indirectResult == nil, sil.writtenBackWidths.isEmpty else {
            throw LLVMError.unsupported("cross-check: results written through an address (@out, inout, mutating) are not bridged")
        }
        let refused: Set<String> = ["swifterror", "swiftasync", "byval", "inalloca", "preallocated", "inreg", "nest"]
        if let p = llvm.parameters.first(where: { !$0.attributes.isDisjoint(with: refused) }) {
            throw LLVMError.unsupported("cross-check: IR parameter %\(p.name) with \(p.attributes.intersection(refused).sorted())")
        }
        resultShape = try SwiftShape(sil.resultType)
        var parameters = llvm.parameters[...]
        sret = parameters.first?.attributes.contains("sret") == true
        if sret {
            guard llvm.returnType == .void, parameters.first?.type == .ptr, resultShape.size > 0 else {
                throw LLVMError.unsupported("cross-check: sret result does not match the SIL result")
            }
            parameters = parameters.dropFirst()
        }
        guard !parameters.contains(where: { $0.attributes.contains("sret") }) else {
            throw LLVMError.unsupported("cross-check: sret on a parameter other than the first")
        }
        resultPieces = try Self.resultPieces(llvm.returnType, sret: sret, size: resultShape.size, sil: sil.resultType)
        shapes = try sil.parameterTypes.map { try SwiftShape($0) }
        passing = try Self.passing(shapes, &parameters)
        guard parameters.isEmpty else {
            throw LLVMError.unsupported("cross-check: the IR has parameters SIL does not (\(parameters.map(\.name)))")
        }
    }

    private static func resultPieces(_ type: LType, sret: Bool, size: Int, sil: ValueType) throws -> [Piece] {
        let fields: [LType]
        switch type {
        case .void:
            guard sret || size == 0 else { throw LLVMError.unsupported("cross-check: the IR returns nothing for a SIL result") }
            return []
        case .tuple(let elements): fields = elements
        default: fields = [type]
        }
        guard !sret, let pieces = try cut(fields[...], size: size), pieces.count == fields.count else {
            throw LLVMError.unsupported("cross-check: IR result \(type.description) does not fit SIL result \(sil)")
        }
        return pieces
    }

    /// Which IR parameters carry each SIL parameter: none for an empty value, one pointer for a value passed by
    /// reference (`dereferenceable` exactly its size), else the pieces its bytes are cut into.
    private static func passing(_ shapes: [SwiftShape], _ parameters: inout ArraySlice<LParameter>) throws -> [Passing] {
        var passing: [Passing] = []
        for shape in shapes {
            if shape.size == 0 {
                passing.append(.absent)
            } else if let next = parameters.first, next.type == .ptr, next.dereferenceable == shape.size {
                passing.append(.byReference)
                parameters = parameters.dropFirst()
            } else {
                guard let pieces = try cut(parameters.map(\.type)[...], size: shape.size), !pieces.isEmpty else {
                    throw LLVMError.unsupported("cross-check: the IR parameters do not fit a SIL parameter of \(shape.size) bytes")
                }
                passing.append(.direct(pieces))
                parameters = parameters.dropFirst(pieces.count)
            }
        }
        return passing
    }

    /// The IR function's arguments for SIL's inputs.
    struct Arguments {
        let values: [LLVMEncoder.Value]
        /// The bytes behind the arguments passed by reference.
        let memory: LLVMEncoder.Memory
        /// The `sret` region the result is written into, if any.
        let result: Int?
    }

    func arguments(_ inputs: [BV], _ encoder: LLVMEncoder, _ c: CNFBuilder) throws -> Arguments {
        var memory: LLVMEncoder.Memory = [:]
        var values: [LLVMEncoder.Value] = []
        let result = sret ? encoder.addRegion(size: resultShape.size, writable: true) : nil
        if let result { values.append(.address(region: result, offset: 0)) }
        var next = 0
        for (shape, how) in zip(shapes, passing) {
            guard next + shape.leafCount <= inputs.count else { throw LLVMError.invalid("cross-check: parameter leaves do not add up") }
            let image = try shape.image(c, inputs[next..<(next + shape.leafCount)], padding: { c.input(width: 1).bits[0] })
            next += shape.leafCount
            switch how {
            case .absent:
                break
            case .byReference:
                let region = encoder.addRegion(size: shape.size, writable: false)
                for byte in 0..<shape.size {
                    let bits = BV(bits: image[(byte * 8)..<(byte * 8 + 8)].map(\.bit))
                    memory[LLVMEncoder.ByteKey(region: region, offset: byte)] = LLVMEncoder.Val(bits: bits, poison: c.falseLit)
                }
                values.append(.address(region: region, offset: 0))
            case .direct(let pieces):
                for piece in pieces {
                    let bits = try SFLLVM.bits(of: piece, in: image, c).map(\.bit)
                    values.append(.scalar(LLVMEncoder.Val(bits: BV(bits: bits), poison: c.falseLit)))
                }
            }
        }
        guard next == inputs.count else { throw LLVMError.invalid("cross-check: parameter leaves do not add up") }
        return Arguments(values: values, memory: memory, result: result)
    }

    /// True when every meaningful bit of `expected` equals what the IR returned; and whether that is poison.
    func sameResult(_ l: LLVMEncoder.Outcome, region: Int?, expected: [ImageBit], _ c: CNFBuilder) throws -> (same: Int32, poison: Int32) {
        let returned = try region.map { try sretBits(l, region: $0, expected: expected, c) } ?? (try directBits(l, expected: expected, c))
        var same = c.trueLit
        for (position, bit) in returned.bits {
            let want = expected[position]
            same = c.and(same, c.or(-want.meaningful, -c.xor(want.bit, bit)))
        }
        return (same, returned.poison)
    }

    /// The result bytes the IR wrote into the `sret` region; a meaningful byte it leaves unwritten is refused.
    private func sretBits(_ l: LLVMEncoder.Outcome, region: Int, expected: [ImageBit], _ c: CNFBuilder) throws
        -> (bits: [(Int, Int32)], poison: Int32)
    {
        var bits: [(Int, Int32)] = []
        var poison = c.falseLit
        for byte in 0..<resultShape.size where !expected[(byte * 8)..<(byte * 8 + 8)].allSatisfy({ $0.meaningful == c.falseLit }) {
            guard let written = l.memory[LLVMEncoder.ByteKey(region: region, offset: byte)] else {
                throw LLVMError.unsupported("cross-check: the IR does not write byte \(byte) of the result")
            }
            poison = c.or(poison, written.poison)
            for k in 0..<8 { bits.append((byte * 8 + k, written.bits.bits[k])) }
        }
        return (bits, poison)
    }

    /// The bits of the IR's direct result, each at its place in the result's bytes.
    private func directBits(_ l: LLVMEncoder.Outcome, expected: [ImageBit], _ c: CNFBuilder) throws -> (bits: [(Int, Int32)], poison: Int32)
    {
        guard !resultPieces.isEmpty else { return ([], c.falseLit) }
        let values: [LLVMEncoder.Value]
        switch l.result {
        case .aggregate(let elements)?: values = elements
        case let v? where resultPieces.count == 1: values = [v]
        default: throw LLVMError.invalid("cross-check: IR result shape")
        }
        guard values.count == resultPieces.count else { throw LLVMError.invalid("cross-check: IR result shape") }
        var bits: [(Int, Int32)] = []
        var poison = c.falseLit
        var covered = Set<Int>()
        for (piece, value) in zip(resultPieces, values) {
            guard case .scalar(let v) = value else { throw LLVMError.unsupported("cross-check: the IR returns an address") }
            let positions = try SFLLVM.bits(of: piece, in: expected, c).indices.map { piece.offset * 8 + $0 }
            guard v.width == positions.count else { throw LLVMError.invalid("cross-check: result piece width") }
            poison = c.or(poison, v.poison)
            bits += zip(positions, v.bits.bits).map { ($0, $1) }
            covered.formUnion(piece.offset..<(piece.offset + piece.bytes))
        }
        for byte in 0..<resultShape.size where !covered.contains(byte) {
            guard expected[(byte * 8)..<(byte * 8 + 8)].allSatisfy({ $0.meaningful == c.falseLit }) else {
                throw LLVMError.unsupported("cross-check: the IR result leaves out byte \(byte) of the SIL result")
            }
        }
        return (bits, poison)
    }
}

extension LLVMVerifier {
    /// N-version check of the compiler lowering: encodes `symbol` from the SIL and, independently, from the LLVM IR
    /// of the same compilation, on shared input bits, and proves they mean the same thing: the same inputs trap,
    /// the same inputs are undefined, and the returned value is equal whenever neither happens.
    ///
    /// A `.counterexample` carries inputs on which the two encodings disagree: either the compiler's SIL-to-IR
    /// lowering, or one of the two encoders, is wrong.
    ///
    /// Both encoders are given the same symbol, since Swift mangles identically in SIL and IR.
    ///
    /// The IR's arguments and result are tied to SIL's through `SwiftShape` (see the reading guide); inputs are real
    /// values of the SIL parameter types (`SILFunction.inputAssumption`). Throws `unsupported` for anything the bridge
    /// cannot tie, and when a counterexample rests on the unknown result of a summarized standard-library call.
    package static func proveEquivalentToSIL(
        symbol: String,
        silModule: SILModule,
        llvmModule: LLVMModule,
        relation: Relation = .equal,
        conflictBudget: Int = 1_000_000
    ) throws -> ProofVerdict {
        let sil = try silModule.function(symbol)
        let plan = try BridgePlan(sil: sil, llvm: try llvmModule.function(symbol))
        var approximated = false
        let verdict = try SFProve.prove(inputWidths: sil.parameterWidths, conflictBudget: conflictBudget) { c, inputs in
            let s = try SILEncoder(module: silModule, builder: c).encode(symbol: symbol, arguments: inputs)
            if !s.approximations.isEmpty { approximated = true }
            let encoder = LLVMEncoder(module: llvmModule, builder: c)
            let arguments = try plan.arguments(inputs, encoder, c)
            let l = try encoder.encode(symbol: symbol, arguments: arguments.values, memory: arguments.memory, stack: [])
            let expected = try plan.resultShape.image(c, s.results[...], padding: { c.falseLit })
            let result = try plan.sameResult(l, region: arguments.result, expected: expected, c)
            let lUndefined = c.or(l.undefined, c.and(l.returned, result.poison))
            switch relation {
            case .equal:
                let sameTrap = -c.xor(s.trap, l.trap)
                let sameUndefined = -c.xor(s.undefined, lUndefined)
                let bothOK = c.and(-s.trap, -s.undefined)
                let agree = c.and(c.and(sameTrap, sameUndefined), c.or(-bothOK, result.same))
                // Only real values are compared: an enum input with an impossible tag has no defined meaning.
                return c.or(-sil.inputAssumption(c, inputs), agree)
            }
        }
        if approximated, case .counterexample = verdict {
            throw LLVMError.unsupported("cross-check: the SIL encoding uses unknown results of summarized calls")
        }
        return verdict
    }
}

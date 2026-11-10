public import SFCNF

/// Builds CNF with Tseitin gates. Literal 1 is fixed true, so constants fold away.
public final class CNFBuilder {
    public private(set) var numVars = 1
    public private(set) var clauses: [Clause] = [[1]]
    public let trueLit: Int32 = 1
    private var andGates: [GateKey: Int32] = [:]
    private var xorGates: [GateKey: Int32] = [:]

    private struct GateKey: Hashable { let a: Int32, b: Int32 }
    public var falseLit: Int32 { -1 }

    /// The gate each variable is the output of, by variable (`CNFCone.swift`); shorter than `numVars + 1` when the
    /// last variables are no gate outputs.
    var gates: [Gate] = []

    /// Optional replacements for the full-width multiplier circuits, used by abstraction-refinement provers.
    /// A hook is consulted only after constant and narrow-operand shortcuts, and must return an equal value.
    package var mulHook: ((BV, BV) -> BV)?
    package var unsignedMulOverflowHook: ((BV, BV) -> Int32)?
    package var signedMulOverflowHook: ((BV, BV) -> Int32)?

    /// Handles of the string texts met while encoding into this builder, in order (`SFSIL.StringIdentity`). A text
    /// operation on a handle that may be several of them is computed for each one.
    package var textHandles: [UInt64] = []
    /// Facts about text results that hold for each recorded text (`SFSIL.SILStringFacts`): each is called once for every
    /// handle in `textHandles`, also for those recorded after it was added.
    package var textRules: [(CNFBuilder, UInt64) -> Void] = []
    /// String handles known to start with the bytes of an ASCII text (`SFSIL.SILTextSplits`).
    package var textStarts: [(handle: BV, start: String)] = []
    /// The parts of a concatenation, by the handle's bits: each a handle and, for a known text, its id
    /// (`SFSIL.SILTextSplits`).
    package var textSkeletons: [[Int32]: [(handle: BV, text: UInt64?)]] = [:]

    /// What each getter on an opaque Foundation value returned in this builder, by getter, with the handle it read
    /// (`SFSIL.OpaqueValues`): the same handle gives the same result.
    package var opaqueResults: [String: [(key: BV, value: [BV])]] = [:]

    /// The array literals made in this builder, by the bits of their count (`SFSIL.SILArrayLiterals`): each literal's
    /// length, and its elements once they are known.
    package var arrayLiterals: [[Int32]: (count: Int, elements: [[BV]]?)] = [:]

    public init() {}

    package var cnf: CNF { CNF(numVars: numVars, clauses: clauses) }

    public func fresh() -> Int32 {
        numVars += 1
        return Int32(numVars)
    }

    /// The value of each named constant, by variable (`namedConstant`): 1 false, 2 true, 0 not named. Empty while there
    /// is none.
    private var named: [UInt8] = []

    /// A fresh variable fixed to `value` by a unit clause: a constant with an identity of its own. Gates fold it like
    /// `trueLit`/`falseLit` (so a circuit over it is the same as over the constant), but the literal itself stays
    /// distinct from every other, so a value built from such bits can be told apart from an equal one
    /// (`SFSIL.SILArrayLiterals` names each array literal's count this way).
    package func namedConstant(_ value: Bool) -> Int32 {
        let v = fresh()
        addClause([value ? v : -v])
        if named.count <= Int(v) { named += Array(repeating: 0, count: Int(v) + 1 - named.count) }
        named[Int(v)] = value ? 2 : 1
        return v
    }

    /// `a`, or `trueLit`/`falseLit` when `a` is a named constant or its negation.
    @inline(__always) func folded(_ a: Int32) -> Int32 {
        guard !named.isEmpty, Int(abs(a)) < named.count, named[Int(abs(a))] != 0 else { return a }
        return ((named[Int(abs(a))] == 2) == (a > 0)) ? trueLit : falseLit
    }

    public func addClause(_ clause: Clause) { clauses.append(clause) }

    public func constant(_ value: Bool) -> Int32 { value ? trueLit : falseLit }

    public func not(_ a: Int32) -> Int32 { -a }

    public func and(_ a: Int32, _ b: Int32) -> Int32 {
        let (a, b) = (folded(a), folded(b))
        if a == falseLit || b == falseLit || a == -b { return falseLit }
        if a == trueLit || a == b { return b }
        if b == trueLit { return a }
        let key = GateKey(a: min(a, b), b: max(a, b))
        if let known = andGates[key] { return known }
        let o = fresh()
        andGates[key] = o
        recordGate(o, a, b, isXor: false)
        addClause([-o, a])
        addClause([-o, b])
        addClause([o, -a, -b])
        return o
    }

    public func or(_ a: Int32, _ b: Int32) -> Int32 { -and(-a, -b) }

    public func xor(_ a: Int32, _ b: Int32) -> Int32 {
        let (a, b) = (folded(a), folded(b))
        if a == falseLit { return b }
        if b == falseLit { return a }
        if a == trueLit { return -b }
        if b == trueLit { return -a }
        if a == b { return falseLit }
        if a == -b { return trueLit }
        // xor(-x, y) = -xor(x, y): share one gate per pair of variables.
        let flip = (a < 0) != (b < 0)
        let (x, y) = (abs(a), abs(b))
        let key = GateKey(a: min(x, y), b: max(x, y))
        if let known = xorGates[key] { return flip ? -known : known }
        let o = xorGate(x, y)
        xorGates[key] = o
        return flip ? -o : o
    }

    private func xorGate(_ a: Int32, _ b: Int32) -> Int32 {
        let o = fresh()
        recordGate(o, a, b, isXor: true)
        addClause([-a, -b, -o])
        addClause([a, b, -o])
        addClause([a, -b, o])
        addClause([-a, b, o])
        return o
    }

    public func mux(_ select: Int32, _ whenTrue: Int32, _ whenFalse: Int32) -> Int32 {
        or(and(select, whenTrue), and(-select, whenFalse))
    }
}

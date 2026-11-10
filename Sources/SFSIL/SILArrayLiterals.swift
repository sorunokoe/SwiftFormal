// Reading guide
// The elements of an array literal the code builds (app study round 6, L6: `UnitDefaults.defaultUnits()` returns six
// rows, and a contract on them was `undecided`). Arrays are modelled by their count (`ValueType.array`); this file
// adds, for each literal, the values its elements were initialized with, so that `a[i]` on it is exact, also in a
// caller and in the `ensures` of the function that returned it.
//
// How a literal is known. `_allocateUninitializedArray(n)` with a constant n gives the new array a count of its own:
// n written in named constants (`CNFBuilder.namedConstant`, `literalCount`), so that the count's bits name this one
// literal while every circuit over them folds exactly as over the constant n.
// Its element storage (`struct_extract` along `Array._buffer`, then `ref_tail_addr`, then `index_addr` by a constant)
// is n stack slots of this run. `_finalizeUninitializedArray` reads the slots: when every element was stored, the
// elements are recorded in the builder under the count (`CNFBuilder.arrayLiterals`), which every encoder of the same
// query shares. A read through the summary of `Array.subscript` of an array whose count is such a circuit is that
// element.
//
// Why a recorded element is the element. The bits of a literal's count leave that literal's copies nowhere: every
// gate over a named constant folds it (`and`, `xor`, `select`, so `append`, `insert`, `remove…`, `+` and a join make
// plain bits), and every place a count turns into an `Int` (`count`, `endIndex`, `indices`) or an `Int` turns into a
// count (`Array(repeating:count:)`, a literal longer than `maxLiteralElements`) strips it (`plainCount`). So a recorded
// count reaches a read only along copies of that literal. The only operation that keeps a copy's count while changing
// an element is a write through `Array.subscript.modify` (the only element-writing call logic reads): each one forgets
// the elements of that count, for every copy, before any later read is encoded (blocks are encoded in an order that
// follows every path; a loop header gets fresh values). A store after `_finalizeUninitializedArray`, a store of another type, an
// element address at a variable or out-of-range offset, or a literal of more than `maxLiteralElements` leaves the
// elements unknown (or unsupported), as before.
// Tests: Tests/SFSILTests/SILArrayLiteralTests.swift, Tests/SFVerifyKitTests/ArrayLiteralScanTests.swift.

import SFBV
import SFSemantics

/// An array literal under construction in one run of a function: the prefix of its element slots, its length, and
/// the layout of its elements.
struct LiteralArray {
    let slot: String
    let count: Int
    let element: ValueType

    func elementSlot(_ k: Int) -> String { "\(slot)[\(k)]" }
}

extension SILEncoder {
    /// Literals longer than this keep unknown elements (every read selects among all of them).
    static let maxLiteralElements = 64

    /// A count for a new literal of `n` elements that names it alone (see the top of this file).
    func literalCount(_ n: Int) -> BV {
        let count = BV(bits: (0..<48).map { c.namedConstant((n >> $0) & 1 == 1) } + Array(repeating: c.falseLit, count: 16))
        c.arrayLiterals[count.bits] = (n, nil)
        return count
    }

    /// `n` without the identity of an array literal: the same value in plain constants and gates. Every `Int` read out of
    /// an array's count, and every count made from an `Int`, goes through this, so that a literal's count bits stay in
    /// copies of that literal only (see the top of this file).
    func plainCount(_ n: BV) -> BV { BV(bits: n.bits.map { c.and($0, c.trueLit) }) }

    /// The length of an array with this count, when it is known: a constant, or the length of a literal.
    func knownCount(_ count: BV) -> UInt64? {
        c.constantValue(count) ?? c.arrayLiterals[count.bits].map { UInt64($0.count) }
    }

    /// Records the elements of the literal with this count (`nil` leaves them unknown).
    func recordElements(_ elements: [[BV]]?, count: BV) {
        guard let known = c.arrayLiterals[count.bits] else { return }
        c.arrayLiterals[count.bits] = (known.count, elements)
    }

    /// The element at `index` of the array with this count, when its elements are known and have `widths`.
    func literalElement(_ count: BV, at index: BV, widths: [Int]) -> [BV]? {
        guard let elements = c.arrayLiterals[count.bits]?.elements, let last = elements.last,
            elements.allSatisfy({ $0.map(\.width) == widths }), index.width == 64
        else { return nil }
        var value = last
        for k in stride(from: elements.count - 2, through: 0, by: -1) {
            let hit = c.eq(index, c.constant(UInt64(k), width: 64))
            value = zip(elements[k], value).map { c.select(hit, $0, $1) }
        }
        return value
    }

    /// The elements of `literal` from its slots, nil when one was not stored on every path.
    static func storedElements(_ literal: LiteralArray, _ cells: [String: BV]) -> [[BV]]? {
        let width = literal.element.leafWidths.count
        var elements: [[BV]] = []
        for k in 0..<literal.count {
            var leaves: [BV] = []
            for i in 0..<width {
                guard let v = cells["\(literal.elementSlot(k))#\(i)"] else { return nil }
                leaves.append(v)
            }
            elements.append(leaves)
        }
        return elements
    }
}

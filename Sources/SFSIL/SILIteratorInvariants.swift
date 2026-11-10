import SFBV
import SFCNF

extension SILVerifier {
    /// Plan item L4: one invariant per loop header of `symbol`, the well-formedness of every `for-in` iterator whose
    /// state the header carries in a stack cell (`IteratorWellFormedness`), `true` where there is none. These are
    /// candidates, not assumptions: `proveLoopFunction` checks each one (INIT: it holds when the loop is entered; STEP:
    /// one pass through the body keeps it), so a wrong one fails the proof and is never believed. It holds because only
    /// `makeIterator()` and `next()` touch an iterator's state.
    package static func iteratorInvariants(of symbol: String, in module: SILModule) throws -> [LoopInvariant] {
        let function = try module.function(symbol)
        var slots: [(id: String, wellFormed: IteratorWellFormedness)] = []
        for block in function.blocks {
            for case .allocStack(let id, let type) in block.instructions {
                if let wellFormed = IteratorWellFormedness(type) { slots.append((id, wellFormed)) }
            }
        }
        return try loops(of: symbol, in: module).map { info in
            var position: [String: Int] = [:]
            for (index, variable) in info.variables.enumerated() where variable.isStackCell { position[variable.name] = index }
            let checks = slots.compactMap { slot -> (IteratorWellFormedness, [Int])? in
                let indices = (0..<slot.wellFormed.leafCount).compactMap { position["\(slot.id)#\($0)"] }
                return indices.count == slot.wellFormed.leafCount ? (slot.wellFormed, indices) : nil
            }
            return LoopInvariant(header: info.header) { c, state in
                checks.reduce(c.trueLit) { holds, check in c.and(holds, check.0.holds(c, check.1.map { state.variables[$0] })) }
            }
        }
    }
}

/// What every state of a `for-in` iterator satisfies when only `makeIterator()` and `next()` made it (`SILIterators.swift`).
struct IteratorWellFormedness {
    enum Kind {
        /// `IndexingIterator<Range<B>>`, leaves `[lowerBound, upperBound, position]`: `lowerBound <= position <=
        /// upperBound`.
        case range(signed: Bool)
        /// `IndexingIterator<ClosedRange<B>>`, leaves `[lowerBound, upperBound, inRange, x]`: `lowerBound <= upperBound`,
        /// and `lowerBound <= x <= upperBound` unless the position is `.pastEnd`.
        case closedRange(signed: Bool)
        /// `IndexingIterator<Array<X>>`, leaves `[count, position]`: `count < 2^48` and `position <= count`.
        case array
        /// `EnumeratedSequence<Array<X>>.Iterator`, leaves `[count, position, offset]`: as `array`, and `offset == position`.
        case enumerated

        var leafCount: Int {
            switch self {
            case .range, .enumerated: 3
            case .closedRange: 4
            case .array: 2
            }
        }
    }

    let kind: Kind
    let leafCount: Int

    init?(_ type: ValueType) {
        guard case .aggregate(let name, _) = type else { return nil }
        if name.hasPrefix("EnumeratedSequence<"), name.hasSuffix(">.Iterator") {
            kind = .enumerated
        } else if let argument = Iterated.argument(of: "IndexingIterator", in: name) {
            switch Iterated(argument) {
            case .range(let b): kind = .range(signed: StdlibSummary.integerKind(b) == .signed)
            case .closedRange(let b): kind = .closedRange(signed: StdlibSummary.integerKind(b) == .signed)
            case .array: kind = .array
            case .integer, nil: return nil
            }
        } else {
            return nil
        }
        leafCount = type.leafWidths.count
        guard leafCount == kind.leafCount else { return nil }
    }

    func holds(_ c: CNFBuilder, _ leaves: [BV]) -> Int32 {
        func lessOrEqual(_ a: BV, _ b: BV, _ signed: Bool) -> Int32 { signed ? c.sle(a, b) : -c.ult(b, a) }
        switch kind {
        case .range(let signed):
            return c.and(lessOrEqual(leaves[0], leaves[2], signed), lessOrEqual(leaves[2], leaves[1], signed))
        case .closedRange(let signed):
            let inside = c.and(lessOrEqual(leaves[0], leaves[3], signed), lessOrEqual(leaves[3], leaves[1], signed))
            return c.and(lessOrEqual(leaves[0], leaves[1], signed), c.or(-leaves[2].bits[0], inside))
        case .array, .enumerated:
            let (count, position) = (leaves[0], leaves[1])
            let valid = c.and(c.ult(count, c.constant(1 << 48, width: 64)), -c.ult(count, position))
            guard case .enumerated = kind else { return valid }
            return c.and(valid, c.eq(leaves[2], position))
        }
    }
}

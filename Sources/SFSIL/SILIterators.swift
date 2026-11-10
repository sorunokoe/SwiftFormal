import Foundation
import SFBV
import SFCNF

// Plan item L4: `for-in` at `-Onone`. Sema turns `for x in s { … }` into `var it = s.makeIterator(); while let x =
// it.next() { … }` (`SILGenStmt.cpp`), and at `-Onone` both calls are unspecialized generic calls into the standard
// library. This file gives the iterator types of `Range`, `ClosedRange`, `stride(from:to:by:)`,
// `stride(from:through:by:)`, `Array`, `enumerated()` and `indices` their stored properties, in declaration order
// (swift-6.4.0-RELEASE: `Collection.swift`, `Range.swift`, `ClosedRange.swift`, `Stride.swift`,
// `EnumeratedSequence.swift`), and their calls exact summaries (`IteratorOperation`): state as integers, `next()`
// returns `.some(x)` while in range, and the checks the shipped (release) standard library makes are traps. Array
// elements stay unknown; only the count is modelled. The loop itself goes through `LoopVerify` like a `while` loop,
// with the iterator's well-formedness as a candidate invariant that the loop proof checks (`iteratorInvariants`).

/// One summarized call of `for-in` iteration. The single generic substitution says over what.
package enum IteratorOperation: Sendable, Hashable {
    /// `Collection<>.makeIterator()` (`IndexingIterator(_elements: self)`) of `Range<B>`, `ClosedRange<B>`, `Array<X>`.
    case makeIndexingIterator
    /// `IndexingIterator.next()` over `Range<B>`, `ClosedRange<B>`, `Array<X>`.
    case indexingNext
    /// `stride(from:to:by:)` and `stride(from:through:by:)` of `Int`: `_precondition(stride != 0)`.
    case stride
    /// `StrideTo.makeIterator()`, `StrideThrough.makeIterator()` of `Int`: `_current = (0, _start)`.
    case makeStrideIterator(through: Bool)
    /// `StrideToIterator.next()`, `StrideThroughIterator.next()` of `Int`, with the overflow-safe integer `_step`.
    case strideNext(through: Bool)
    /// `Sequence.enumerated()` of `Array<X>`.
    case enumerated
    /// `EnumeratedSequence.makeIterator()` of `Array<X>`: the array's iterator and `_count = 0`.
    case makeEnumeratedIterator
    /// `EnumeratedSequence.Iterator.next()` of `Array<X>`.
    case enumeratedNext
    /// `RandomAccessCollection<>.indices` of `Array<X>`: `startIndex..<endIndex`.
    case indices
}

/// What a `for-in` call iterates: the substitution of the call.
enum Iterated {
    case range(bound: String)
    case closedRange(bound: String)
    case array(element: String)
    case integer(String)

    init?(_ text: String) {
        let t = text.trimmingCharacters(in: .whitespaces)
        if let element = TypeContext.arrayElement(t) {
            self = .array(element: element)
        } else if let bound = Self.argument(of: "Range", in: t), Self.isInteger(bound) {
            self = .range(bound: bound)
        } else if let bound = Self.argument(of: "ClosedRange", in: t), Self.isInteger(bound) {
            self = .closedRange(bound: bound)
        } else if Self.isInteger(t) {
            self = .integer(t)
        } else {
            return nil
        }
    }

    /// `X` for `Name<X>`, nil for anything else.
    static func argument(of name: String, in t: String) -> String? {
        guard t.hasPrefix(name + "<"), t.hasSuffix(">") else { return nil }
        let inner = String(t.dropFirst(name.count + 1).dropLast())
        return splitTopLevel(inner).count == 1 ? inner : nil
    }

    /// A standard fixed-width integer type: its `Stride` is `Int` and `advanced(by:)` is integer addition.
    static func isInteger(_ t: String) -> Bool { StdlibSummary.integerKind(t) != nil }
}

// MARK: - layouts

extension TypeContext {
    /// The layout of a standard-library type of `for-in` iteration, nil for any other type. Only integer bounds and
    /// arrays: an iterator over anything else is refused where it is used.
    func iterationType(_ t: String, depth: Int) throws(SILError) -> ValueType? {
        if let member = try iterationMemberType(t, depth: depth) { return member }
        guard t.hasSuffix(">"), let open = t.firstIndex(of: "<") else { return nil }
        let argument = String(t[t.index(after: open)..<t.index(before: t.endIndex)])
        guard splitTopLevel(argument).count == 1, let list = try iterationFields(String(t[..<open]), argument, depth: depth + 1)
        else { return nil }
        return .aggregate(name: t, fields: list.map { .init(name: $0.0, type: $0.1) })
    }

    /// `EnumeratedSequence<Array<X>>.Iterator` (`_base: Base.Iterator`, `_count: Int`) and `ClosedRange<B>.Index`
    /// (`case pastEnd`, `case inRange(Bound)`).
    private func iterationMemberType(_ t: String, depth: Int) throws(SILError) -> ValueType? {
        if t.hasSuffix(">.Iterator"), let base = Iterated.argument(of: "EnumeratedSequence", in: String(t.dropLast(".Iterator".count))),
            TypeContext.arrayElement(base) != nil
        {
            let iterator = try resolve("IndexingIterator<\(base)>", depth: depth + 1)
            return .aggregate(name: t, fields: [.init(name: "_base", type: iterator), .init(name: "_count", type: .scalar(64))])
        }
        guard t.hasSuffix(">.Index"), let b = Iterated.argument(of: "ClosedRange", in: String(t.dropLast(".Index".count))),
            Iterated.isInteger(b)
        else { return nil }
        let element = try resolve(b, depth: depth + 1)
        return .enumeration(name: t, cases: [.init(name: "pastEnd", payload: nil), .init(name: "inRange", payload: element)])
    }

    /// The stored properties of `name<argument>`, in declaration order; nil for another type or argument.
    private func iterationFields(_ name: String, _ argument: String, depth: Int) throws(SILError) -> [(String, ValueType)]? {
        let word = ValueType.scalar(64)
        switch name {
        case "Range", "ClosedRange":
            // `public let lowerBound: Bound`, `public let upperBound: Bound`.
            guard Iterated.isInteger(argument) else { return nil }
            let b = try resolve(argument, depth: depth)
            return [("lowerBound", b), ("upperBound", b)]
        case "IndexingIterator":
            // `internal let _elements: Elements`, `internal var _position: Elements.Index`.
            guard let position = try indexType(of: argument, depth: depth) else { return nil }
            return [("_elements", try resolve(argument, depth: depth)), ("_position", position)]
        case "StrideTo", "StrideThrough", "StrideToIterator", "StrideThroughIterator":
            // `_start: Element`, `_end: Element`, `_stride: Element.Stride` (`Int` for every standard integer); an iterator
            // adds `_current: (index: Int?, value: Element)`, and `StrideThroughIterator` then `_didReturnEnd: Bool`.
            guard Iterated.isInteger(argument) else { return nil }
            let b = try resolve(argument, depth: depth)
            var list = [("_start", b), ("_end", b), ("_stride", word)]
            guard name.hasSuffix("Iterator") else { return list }
            list.append(("_current", try resolve("(index: Optional<Int>, value: \(argument))", depth: depth)))
            return name.hasPrefix("StrideThrough") ? list + [("_didReturnEnd", .scalar(1))] : list
        case "EnumeratedSequence":
            // `internal var _base: Base`.
            return TypeContext.arrayElement(argument) == nil ? nil : [("_base", try resolve(argument, depth: depth))]
        default:
            return nil
        }
    }

    /// `Elements.Index` of an `IndexingIterator<Elements>`: the bound of a `Range`, `ClosedRange.Index`, `Int` for an array.
    private func indexType(of elements: String, depth: Int) throws(SILError) -> ValueType? {
        switch Iterated(elements) {
        case .range(let b): try resolve(b, depth: depth)
        case .closedRange: try resolve("\(elements).Index", depth: depth)
        case .array: .scalar(64)
        case .integer, nil: nil
        }
    }
}

extension SILModule {
    /// Whether a read module declares a type named `name` (a struct, enum, class, protocol, or an ambiguous name).
    func declaresType(_ name: String) -> Bool {
        types.structs[name] != nil || types.enums[name] != nil || types.generics[name] != nil || types.rejected[name] != nil
            || types.ambiguous.contains(name)
    }
}

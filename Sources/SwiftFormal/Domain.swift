/// A finite, indexable, deterministic set of inputs.
///
/// `complete` is the claim that this domain is the *whole* input space under verification
/// (for example every case of an enum). A domain built from hand-picked representatives is
/// not complete, so verdicts over it can never be `proved`.
///
/// A domain is immutable once built, so it is `@unchecked Sendable`: it can be a global `let`, which
/// Swift 6 requires for shared test fixtures. The values it produces are as thread-safe as their type.
public struct Domain<Value>: @unchecked Sendable {
    /// Number of values, saturating at `Int.max`.
    public let count: Int
    /// Whether the domain lists every possible value. Only then can a verdict be `proved`.
    public let complete: Bool
    @usableFromInline let element: (Int) -> Value
    @usableFromInline let random: (inout SplitMix64) -> Value

    @usableFromInline init(
        count: Int,
        complete: Bool,
        element: @escaping (Int) -> Value,
        random: @escaping (inout SplitMix64) -> Value
    ) {
        self.count = count
        self.complete = complete
        self.element = element
        self.random = random
    }

    /// The value at `index`, for `0 ..< count` when `count` is not saturated.
    @inlinable public subscript(index: Int) -> Value {
        precondition(index >= 0 && index < count, "Domain index out of range")
        return element(index)
    }

    /// Applies a transform, for example to build a struct from a product of fields.
    @inlinable public func map<T>(_ transform: @escaping (Value) -> T) -> Domain<T> {
        Domain<T>(
            count: count,
            complete: complete,
            element: { transform(element($0)) },
            random: { transform(random(&$0)) }
        )
    }

    /// Keeps values that satisfy `isIncluded`. Scans the whole domain eagerly, so it is meant for
    /// domains of at most ten million values; build valid values with `map` for larger ones.
    public func filter(_ isIncluded: @escaping (Value) -> Bool) -> Domain<Value> {
        precondition(count <= Domain.filterScanLimit, "filter scans eagerly; use map to build valid values instead")
        return Domain.of((0..<count).map(element).filter(isIncluded)).withCompleteness(complete)
    }

    /// Declares the domain a sample rather than the whole input space.
    public var asSample: Domain<Value> { withCompleteness(false) }

    /// At most `limit` values, spread evenly over the domain (always including the first and last).
    /// A smaller domain than the original is a sample, so the result is not `complete` when values were dropped.
    public func evenlySpaced(_ limit: Int) -> Domain<Value> {
        precondition(limit > 0)
        guard count > limit else { return self }
        // Full width: `index * (count - 1)` overflows `Int` for a domain near `Int.max`; the quotient always fits.
        let picks = limit == 1 ? [0] : (0..<limit).map { (limit - 1).dividingFullWidth((count - 1).multipliedFullWidth(by: $0)).quotient }
        return Domain(
            count: picks.count,
            complete: false,
            element: { element(picks[$0]) },
            random: { rng in element(picks[Int(rng.next() % UInt64(picks.count))]) }
        )
    }

    static var filterScanLimit: Int { 10_000_000 }

    func withCompleteness(_ complete: Bool) -> Domain<Value> {
        Domain(count: count, complete: complete, element: element, random: random)
    }
}

// MARK: - Sources of values

extension Domain {
    /// The given values, taken as the whole domain.
    public static func of(_ values: [Value]) -> Domain {
        Domain(
            count: values.count,
            complete: true,
            element: { values[$0] },
            random: { values[Int($0.next() % UInt64(max(values.count, 1)))] }
        )
    }

    /// Hand-picked representatives. The domain is marked incomplete, so verdicts are `bounded`.
    public static func samples(_ values: [Value]) -> Domain {
        of(values).asSample
    }

    /// A domain with exactly one value.
    public static func just(_ value: Value) -> Domain { of([value]) }
}

extension Domain where Value: CaseIterable {
    /// Every value `allCases` lists, claimed complete at the call site like `of`. Write it only where you know the
    /// list is complete (the compiler synthesized it): a hand-written `allCases` that leaves values out makes
    /// "proved" mean "proved over the listed values". `CaseIterable.domain` makes no such claim and is a sample.
    public static var allCases: Domain { of(Array(Value.allCases)) }
}

extension Domain where Value == Bool {
    /// Both Boolean values.
    public static var bool: Domain { of([false, true]) }
}

extension Domain where Value == Int {
    /// Every integer in the range. The range is a precondition of the verification.
    public static func int(_ range: ClosedRange<Int>) -> Domain {
        let (span, overflow) = range.upperBound.subtractingReportingOverflow(range.lowerBound)
        let count = overflow || span == Int.max ? Int.max : span + 1
        return Domain(
            count: count,
            complete: true,
            element: { range.lowerBound + $0 },
            random: { range.lowerBound &+ Int(truncatingIfNeeded: $0.next() % UInt64(count)) }
        )
    }

    /// Edge values of the full `Int` range plus values around zero and powers of two.
    public static var boundaries: Domain {
        var values: Set<Int> = [Int.min, Int.min + 1, -1, 0, 1, Int.max - 1, Int.max]
        for shift in 1..<63 {
            let power = 1 << shift
            values.formUnion([power - 1, power, power + 1, -power, -power + 1, -power - 1])
        }
        return samples(values.sorted())
    }
}

// MARK: - Combinators

extension Domain {
    /// `nil` plus every value of `wrapped`.
    public static func optional<Wrapped>(_ wrapped: Domain<Wrapped>) -> Domain<Wrapped?> where Value == Wrapped? {
        let total = saturatingAdd(wrapped.count, 1)
        return Domain<Wrapped?>(
            count: total,
            complete: wrapped.complete,
            element: { $0 == 0 ? nil : wrapped.element($0 - 1) },
            random: { $0.next() % UInt64(total) == 0 ? nil : wrapped.random(&$0) }
        )
    }

    /// Arrays of every length up to `maxLength`.
    public static func arrays<Element>(of elements: Domain<Element>, maxLength: Int) -> Domain<[Element]>
    where Value == [Element] {
        precondition(maxLength >= 0)
        var perLength: [Int] = []
        var total = 0
        var power = 1
        for length in 0...maxLength {
            if length > 0 { power = saturatingMultiply(power, elements.count) }
            perLength.append(power)
            total = saturatingAdd(total, power)
        }
        return Domain<[Element]>(
            count: total,
            complete: elements.complete,
            element: { index in
                var remaining = index
                var length = 0
                while remaining >= perLength[length] {
                    remaining -= perLength[length]
                    length += 1
                }
                return (0..<length).map { _ in
                    defer { remaining /= elements.count }
                    return elements.element(remaining % elements.count)
                }
            },
            random: { rng in
                let length = Int(rng.next() % UInt64(maxLength + 1))
                return (0..<length).map { _ in elements.random(&rng) }
            }
        )
    }

    /// Every value of every domain in `parts`, one part after the other. This is how an enum with payload
    /// cases is built: one part per case.
    public static func union(_ parts: [Domain]) -> Domain {
        let nonEmpty = parts.filter { $0.count > 0 }
        guard !nonEmpty.isEmpty else { return of([]) }
        // Where each part starts, so an index finds its part by binary search instead of a walk over the parts.
        var starts: [Int] = []
        var total = 0
        for part in nonEmpty {
            starts.append(total)
            total = saturatingAdd(total, part.count)
        }
        return Domain(
            count: total,
            complete: nonEmpty.allSatisfy(\.complete),
            element: { index in
                var low = 0
                var high = starts.count - 1
                while low < high {
                    let middle = (low + high + 1) / 2
                    if starts[middle] <= index { low = middle } else { high = middle - 1 }
                }
                let offset = index - starts[low]
                precondition(offset < nonEmpty[low].count, "Domain index out of range")
                return nonEmpty[low].element(offset)
            },
            random: { rng in nonEmpty[Int(rng.next() % UInt64(nonEmpty.count))].random(&rng) }
        )
    }

    /// Every pair.
    @inlinable public static func product<A, B>(_ a: Domain<A>, _ b: Domain<B>) -> Domain<(A, B)> where Value == (A, B) {
        Domain<(A, B)>(
            count: saturatingMultiply(a.count, b.count),
            complete: a.complete && b.complete,
            element: { (a.element($0 / b.count), b.element($0 % b.count)) },
            random: { (a.random(&$0), b.random(&$0)) }
        )
    }

    /// Every triple.
    @inlinable public static func product<A, B, C>(_ a: Domain<A>, _ b: Domain<B>, _ c: Domain<C>) -> Domain<(A, B, C)>
    where Value == (A, B, C) {
        Domain<(A, B, C)>(
            count: saturatingMultiply(saturatingMultiply(a.count, b.count), c.count),
            complete: a.complete && b.complete && c.complete,
            element: { index in
                (a.element(index / (c.count * b.count)), b.element((index / c.count) % b.count), c.element(index % c.count))
            },
            random: { (a.random(&$0), b.random(&$0), c.random(&$0)) }
        )
    }

    /// Every 4-tuple.
    @inlinable public static func product<A, B, C, D>(_ a: Domain<A>, _ b: Domain<B>, _ c: Domain<C>, _ d: Domain<D>)
        -> Domain<(A, B, C, D)> where Value == (A, B, C, D)
    {
        Domain<(A, B, C, D)>(
            count: saturatingMultiply(saturatingMultiply(a.count, b.count), saturatingMultiply(c.count, d.count)),
            complete: a.complete && b.complete && c.complete && d.complete,
            element: { index in
                (
                    a.element(index / (d.count * c.count * b.count)),
                    b.element((index / (d.count * c.count)) % b.count),
                    c.element((index / d.count) % c.count),
                    d.element(index % d.count)
                )
            },
            random: { (a.random(&$0), b.random(&$0), c.random(&$0), d.random(&$0)) }
        )
    }
}

// A product of five or six domains is a tuple of five or six, from as many parameters: what `@Verify(over:)` walks for
// a function with that many.
// swiftlint:disable large_tuple function_parameter_count
extension Domain {
    /// Every 5-tuple, in the order of the nested pairs `product(a, product(b, …))`.
    public static func product<A, B, C, D, E>(_ a: Domain<A>, _ b: Domain<B>, _ c: Domain<C>, _ d: Domain<D>, _ e: Domain<E>)
        -> Domain<(A, B, C, D, E)> where Value == (A, B, C, D, E)
    {
        Domain<(A, (B, (C, (D, E))))>.product(a, .product(b, .product(c, .product(d, e)))).map {
            ($0.0, $0.1.0, $0.1.1.0, $0.1.1.1.0, $0.1.1.1.1)
        }
    }

    /// Every 6-tuple. More parameters: nest `product` and `map` the nested pairs to a flat tuple.
    public static func product<A, B, C, D, E, F>(
        _ a: Domain<A>, _ b: Domain<B>, _ c: Domain<C>, _ d: Domain<D>, _ e: Domain<E>, _ f: Domain<F>
    ) -> Domain<(A, B, C, D, E, F)> where Value == (A, B, C, D, E, F) {
        Domain<(A, (B, C, D, E, F))>.product(a, .product(b, c, d, e, f)).map { ($0.0, $0.1.0, $0.1.1, $0.1.2, $0.1.3, $0.1.4) }
    }
}
// swiftlint:enable large_tuple function_parameter_count

// MARK: - The domain of a parameter type

extension Domain where Value: Finite {
    /// The type's whole domain, `Value.domain`. `@Verify` without `over:` writes this for each parameter.
    public static func ofParameterType(_ type: Value.Type) -> Domain { Value.domain }
}

extension Domain {
    /// For a type that is not `Finite`: no values, and not the whole input space, so a walk over it is `bounded`, never
    /// `proved`. `@Verify` without `over:` writes `ofParameterType` for each parameter whose type it cannot tell from the
    /// source; the compiler picks the `Finite` overload whenever the type is `Finite`. Give `@Verify(over:)` a domain to
    /// walk such a parameter; Scan proves the contract either way.
    @_disfavoredOverload public static func ofParameterType(_ type: Value.Type) -> Domain {
        Domain(
            count: 0, complete: false, element: { _ in preconditionFailure("an empty domain has no values") },
            random: { _ in
                preconditionFailure("an empty domain has no values")
            })
    }
}

// MARK: - Helpers

@usableFromInline func saturatingAdd(_ a: Int, _ b: Int) -> Int {
    let (sum, overflow) = a.addingReportingOverflow(b)
    return overflow ? Int.max : sum
}

@usableFromInline func saturatingMultiply(_ a: Int, _ b: Int) -> Int {
    let (product, overflow) = a.multipliedReportingOverflow(by: b)
    return overflow ? Int.max : product
}

/// Deterministic generator so sampled runs reproduce exactly.
public struct SplitMix64: RandomNumberGenerator {
    private var state: UInt64

    /// Creates a generator that always produces the same sequence for the same `seed`.
    public init(seed: UInt64) { state = seed }

    /// Returns the next pseudo-random value.
    public mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}

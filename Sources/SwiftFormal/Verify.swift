/// Runs `function` on every input of `domain` and checks `properties` against each result.
///
/// The function is the real function under test, not a model of it. A `proved` verdict therefore
/// has no translation gap: the only things trusted are the compiler and the domain you described.
/// When the domain is larger than the budget, or is a sample, the verdict is `bounded`, never `proved`.
///
/// Inputs for which `assuming` returns `false` are excluded, not evaluated and not counted as checked
/// (this is how `#requires` narrows the input space). They are reported in `Report.excluded`.
///
/// A throwing call fails the implicit `total` property. Swift traps (overflow, force unwrap) cannot be
/// caught in-process; they stop the run at an input that is reproducible from the deterministic walk. On macOS and
/// Linux, `Prove(neverTraps:)` in `SwiftFormalTesting` runs the walk in a Swift Testing exit test and turns a trap into
/// a failure that names the input.
///
/// The walk behind `Prove` and `@Verify`; users write those (`package`, so it is not a way of its own).
package func runWalk<Input, Output>(
    _ subject: String = "function",
    _ function: @escaping (Input) throws -> Output,
    over domain: Domain<Input>,
    budget: Budget = .default,
    @PropertyBuilder<Input, Output> properties: () -> [Property<Input, Output>] = { [] },
    assuming: ((Input) -> Bool)? = nil
) -> Report {
    var slots = Slot<Input, Output>.forWalk(properties())

    let enumerateAll = domain.count <= budget.maxEvaluations
    let planned = enumerateAll ? domain.count : budget.maxEvaluations
    var rng = SplitMix64(seed: budget.seed)
    var evaluated = 0
    var excluded = 0
    var skipped = 0

    // This loop runs up to `Budget.maxEvaluations` times, so it does no per-input work over the whole slot list:
    // `openProperties` counts the properties (slots after `total`) that have not failed yet.
    let (element, random) = (domain.element, domain.random)
    // Unspecialized generic code (every caller in another module) pays a value-witness copy for each read of a
    // generic array element, and Array<T> checks for NSArray bridging on each access. Keep the per-input state in
    // non-generic storage and the observers in a ContiguousArray.
    let observe = ContiguousArray(slots.map(\.observer.observe))
    var failed = ContiguousArray(repeating: false, count: slots.count)
    var openProperties = slots.count - 1
    // Off except in a trap walk's child process (SwiftFormalTesting); `call` is then `function` itself.
    let (probe, call) = WalkProbe.Writer.forWalk(watching: function)

    walk: for step in 0..<planned {
        probe.enter(step)
        let input = enumerateAll ? element(step) : random(&rng)
        if let assuming, !assuming(input) {
            excluded += 1
            continue
        }
        evaluated += 1

        let output: Output
        do {
            output = try call(input)
        } catch {
            if !failed[0] { (failed[0], slots[0].failure) = (true, Counterexample(input: describe(input), detail: "threw \(error)")) }
            // Other properties cannot judge an input that has no output; keep walking for them.
            skipped += 1
            if openProperties == 0 { break walk }
            continue
        }

        var index = 1
        while index < observe.count {
            if !failed[index], let message = observe[index](input, output, function) {
                failed[index] = true
                slots[index].failure = Counterexample(input: describe(input), detail: message)
                openProperties -= 1
            }
            index += 1
        }
        if openProperties == 0 && failed[0] { break walk }
    }
    probe.leave()

    let tally = Tally(evaluated: evaluated, excluded: excluded, skipped: skipped)
    return Report(
        subject: subject,
        domainSize: domain.count,
        domainComplete: domain.complete && enumerateAll,
        evaluated: evaluated,
        excluded: excluded,
        results: verdicts(of: slots, tally: tally, domain: domain, enumerateAll: enumerateAll, budget: budget)
    )
}

/// Where a walk is, for the signal handler of a trap walk (`Prove(neverTraps:)` in SwiftFormalTesting).
///
/// A signal handler may only read plain memory, so these are plain globals. They are written only while
/// `isPublishing` is true, which a trap walk sets in its own exit-test child process and nobody else does.
package enum WalkProbe {
    /// Whether `runWalk` publishes its position. Read once per walk.
    nonisolated(unsafe) package static var isPublishing = false
    /// The step of the input being judged (the walk's loop index), or -1 outside a walk.
    nonisolated(unsafe) package static var step = -1
    /// Whether the walk is inside the function under test; otherwise it is choosing the input, checking `#requires`,
    /// or running a property.
    nonisolated(unsafe) package static var inFunction = false

    /// Writes the probe for one walk when `isOn`, and does nothing otherwise.
    struct Writer {
        let isOn: Bool

        /// The walk took the input at `step` and is choosing or checking it.
        @inline(__always) func enter(_ step: Int) {
            guard isOn else { return }
            WalkProbe.step = step
            WalkProbe.inFunction = false
        }

        /// A writer for one walk, and `function` marking the time inside it, or `function` itself when the probe is
        /// off. A property that calls the function again uses the original, so that call counts as checking.
        static func forWalk<Input, Output>(
            watching function: @escaping (Input) throws -> Output
        ) -> (Writer, (Input) throws -> Output) {
            let writer = Writer(isOn: WalkProbe.isPublishing)
            guard writer.isOn else { return (writer, function) }
            return (
                writer,
                { input in
                    WalkProbe.inFunction = true
                    defer { WalkProbe.inFunction = false }
                    return try function(input)
                }
            )
        }

        /// The walk is over; a property's final check is not tied to an input.
        @inline(__always) func leave() {
            if isOn { WalkProbe.step = -1 }
        }
    }
}

extension Domain {
    /// The input `runWalk` takes at `step` with this budget: the element at `step` when the whole domain fits the
    /// budget, otherwise the `step + 1`-th draw from `SplitMix64(seed:)`. A step counts inputs `#requires` excludes.
    package func walkInput(atStep step: Int, maxEvaluations: Int, seed: UInt64) -> Value {
        if count <= maxEvaluations { return element(step) }
        var rng = SplitMix64(seed: seed)
        for _ in 0..<step { _ = random(&rng) }
        return random(&rng)
    }
}

struct Tally {
    let evaluated: Int
    let excluded: Int
    let skipped: Int
}

func verdicts<Input, Output>(
    of slots: [Slot<Input, Output>],
    tally: Tally,
    domain: Domain<Input>,
    enumerateAll: Bool,
    budget: Budget
) -> [PropertyResult] {
    let boundedReason =
        tally.skipped > 0
        ? "\(tally.skipped) inputs threw and could not be judged"
        : boundedReason(domain: domain, enumerateAll: enumerateAll, budget: budget)

    var results: [PropertyResult] = []
    for (index, slot) in slots.enumerated() {
        let fullyWalked = enumerateAll && tally.evaluated + tally.excluded == domain.count && (index == 0 || tally.skipped == 0)
        if let failure = slot.failure {
            results.append(PropertyResult(name: slot.name, verdict: .counterexample(failure)))
        } else if let message = slot.observer.finish(fullyWalked && domain.complete) {
            results.append(PropertyResult(name: slot.name, verdict: .counterexample(Counterexample(input: nil, detail: message))))
        } else if fullyWalked && domain.complete {
            results.append(PropertyResult(name: slot.name, verdict: .proved(checked: tally.evaluated)))
        } else {
            results.append(
                PropertyResult(name: slot.name, verdict: .bounded(checked: tally.evaluated, reason: boundedReason ?? "stopped early")))
        }
    }
    return results
}

struct Slot<Input, Output> {
    let name: String
    let observer: Property<Input, Output>.Observer
    var failure: Counterexample?

    /// The implicit `total` property first, then `properties` in the order they were written.
    static func forWalk(_ properties: [Property<Input, Output>]) -> [Slot] {
        [Slot(name: "total", observer: .init(observe: { _, _, _ in nil }), failure: nil)]
            + properties.map { Slot(name: $0.name, observer: $0.makeObserver(), failure: nil) }
    }
}

private func boundedReason<Input>(domain: Domain<Input>, enumerateAll: Bool, budget: Budget) -> String? {
    if !domain.complete { return "the domain is a sample, not the whole input space" }
    if !enumerateAll { return "domain has \(domain.count) values; budget allows \(budget.maxEvaluations), checked a seeded sample" }
    return nil
}

/// A value as text for a report, shortened to 300 characters.
func describe<T>(_ value: T) -> String {
    let text = String(describing: value)
    return text.count > 300 ? String(text.prefix(300)) + "..." : text
}

/// Every counterexample of every property, not only the first: for a list of every failing input (a data audit, every
/// translation key in every language), which `SwiftFormalTesting` reports with `reporting: .everyFailure`.
///
/// It walks the same inputs as `runWalk` with the same budget (the whole domain when it fits, else the same seeded
/// draws), and keeps calling each property after it failed. A property that fails only at the end of the walk (a
/// table row or an output never reached) gives one counterexample without an input, as in `runWalk`. An input on which
/// `function` throws is a counterexample of `total`. Inputs `assuming` excludes are skipped.
///
/// It lives here because a property's observer is internal to this module.
package func everyCounterexample<Input, Output>(
    of function: (Input) throws -> Output,
    over domain: Domain<Input>,
    budget: Budget = .default,
    properties: [Property<Input, Output>],
    assuming: ((Input) -> Bool)? = nil
) -> [(property: String, counterexample: Counterexample)] {
    let observers = properties.map { (name: $0.name, observer: $0.makeObserver()) }
    let enumerateAll = domain.count <= budget.maxEvaluations
    let planned = enumerateAll ? domain.count : budget.maxEvaluations
    var rng = SplitMix64(seed: budget.seed)
    var found: [(property: String, counterexample: Counterexample)] = []
    var walked = 0
    var threw = false
    for step in 0..<planned {
        let input = enumerateAll ? domain[step] : domain.random(&rng)
        if let assuming, !assuming(input) {
            walked += 1
            continue
        }
        walked += 1
        let output: Output
        do {
            output = try function(input)
        } catch {
            threw = true
            found.append(("total", Counterexample(input: describe(input), detail: "threw \(error)")))
            continue
        }
        for (name, observer) in observers {
            if let message = observer.observe(input, output, function) {
                found.append((name, Counterexample(input: describe(input), detail: message)))
            }
        }
    }
    let wholeDomain = enumerateAll && walked == domain.count && domain.complete && !threw
    for (name, observer) in observers {
        if let message = observer.finish(wholeDomain) { found.append((name, Counterexample(input: nil, detail: message))) }
    }
    return found
}

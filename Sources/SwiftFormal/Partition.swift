/// Groups every input of `domain` by the output `function` returns for it, in the order the outputs first appear.
///
/// Walks the whole domain (at most `limit` values). Inputs for which `function` throws are listed in `threw`.
package func runPartition<Input, Output: Equatable>(
    _ function: (Input) throws -> Output,
    over domain: Domain<Input>,
    limit: Int = 100_000
) -> Partition<Input, Output> {
    walkPartition(function, over: domain, limit: limit) { output, groups in groups.firstIndex { $0.output == output } }
}

/// The same groups in the same order as the `Equatable` version, found by hashing instead of by a linear search,
/// so a domain with many distinct outputs costs O(n) instead of O(n × groups).
package func runPartition<Input, Output: Hashable>(
    _ function: (Input) throws -> Output,
    over domain: Domain<Input>,
    limit: Int = 100_000
) -> Partition<Input, Output> {
    var positions: [Output: Int] = [:]
    return walkPartition(function, over: domain, limit: limit) { output, groups in
        if let position = positions[output] { return position }
        positions[output] = groups.count
        return nil
    }
}

/// `position` returns the index of the group that `output` belongs to, or nil when it starts a new group.
func walkPartition<Input, Output>(
    _ function: (Input) throws -> Output,
    over domain: Domain<Input>,
    limit: Int,
    position: (Output, [(output: Output, inputs: [Input])]) -> Int?
) -> Partition<Input, Output> {
    precondition(domain.count <= limit, "partition walks the whole domain; \(domain.count) values exceeds limit \(limit)")
    var groups: [(output: Output, inputs: [Input])] = []
    var threw: [(input: Input, error: String)] = []
    for index in 0..<domain.count {
        let input = domain[index]
        do {
            let output = try function(input)
            if let found = position(output, groups) {
                groups[found].inputs.append(input)
            } else {
                groups.append((output, [input]))
            }
        } catch {
            threw.append((input, "\(error)"))
        }
    }
    return Partition(groups: groups, threw: threw, inputCount: domain.count)
}

/// Inputs grouped by the output the function returned for them. See `runPartition(_:over:limit:)`.
package struct Partition<Input, Output> {
    /// One group per distinct output, in the order the outputs first appeared.
    package let groups: [(output: Output, inputs: [Input])]
    /// The inputs for which the function threw, with the error's description.
    package let threw: [(input: Input, error: String)]
    /// The number of inputs walked.
    package let inputCount: Int

    init(groups: [(output: Output, inputs: [Input])], threw: [(input: Input, error: String)], inputCount: Int) {
        self.groups = groups
        self.threw = threw
        self.inputCount = inputCount
    }

    /// The groups that hold more than one input.
    package var collisions: [(output: Output, inputs: [Input])] { groups.filter { $0.inputs.count > 1 } }

    /// True when no two inputs share an output and nothing threw.
    package var isInjective: Bool { collisions.isEmpty && threw.isEmpty }
}

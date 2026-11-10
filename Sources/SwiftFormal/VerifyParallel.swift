import Dispatch

/// How many threads `runWalk(_:_:over:budget:parallelism:properties:assuming:)` evaluates the function on.
package struct Parallelism: Sendable, Equatable {
    /// The most evaluations that run at the same time.
    package let threads: Int
    /// The most consecutive inputs one thread evaluates before it takes the next batch.
    package let chunkSize: Int

    /// `count` threads, each taking up to `chunkSize` consecutive inputs at a time.
    package static func threads(_ count: Int, chunkSize: Int = 1024) -> Parallelism {
        precondition(count > 0 && chunkSize > 0, "Parallelism needs at least one thread and a positive chunk size")
        return Parallelism(threads: count, chunkSize: chunkSize)
    }
}

/// The results of one chunk of inputs. Written by exactly one worker, read after `concurrentPerform` returns, which
/// orders the accesses.
private final class Chunk<Output>: @unchecked Sendable {
    /// One output per input that was neither excluded nor threw, in walk order.
    var outputs: [Output] = []
    /// A second evaluation of the same input, made right after the first (only when an observer re-evaluates).
    var again: [Result<Output, any Error>] = []
    /// Offsets of the inputs that were excluded or threw, ascending; `errors[k]` is `nil` for an exclusion.
    var exceptions: [Int] = []
    var errors: [(any Error)?] = []
}

/// `runWalk` with the function evaluated on several threads. The report is the same as the serial `runWalk`'s for the
/// same arguments: inputs are produced on the calling thread in walk order (a domain's closures need not be
/// thread-safe), only `function` and `assuming` run on the worker threads, and every property observes the results on
/// the calling thread, in walk order.
///
/// Worth it when one evaluation costs about a microsecond or more; for cheaper functions the threads cost more than
/// they save. Inputs are evaluated in batches, so after the walk stops early (every property failed) some inputs past
/// the stopping point may already have been evaluated. A trap (overflow, force unwrap) stops the process on whichever
/// thread hits it, so the trapping input is not reproducible from the walk order as it is with the serial `runWalk`.
package func runWalk<Input: Sendable, Output: Sendable>(
    _ subject: String = "function",
    _ function: @escaping @Sendable (Input) throws -> Output,
    over domain: Domain<Input>,
    budget: Budget = .default,
    parallelism: Parallelism,
    @PropertyBuilder<Input, Output> properties: () -> [Property<Input, Output>] = { [] },
    assuming: (@Sendable (Input) -> Bool)? = nil
) -> Report {
    var fold = OrderedFold(properties: properties(), function: function)
    let enumerateAll = domain.count <= budget.maxEvaluations
    let planned = enumerateAll ? domain.count : budget.maxEvaluations
    var rng = SplitMix64(seed: budget.seed)
    let element = domain.element
    let random = domain.random
    let reevaluate = fold.anyReevaluates
    let threads = parallelism.threads
    let largestRound = threads * 4 * parallelism.chunkSize
    // Rounds grow geometrically, so an early stop wastes little work: 16 inputs per thread, doubling up to 4 chunks
    // per thread.
    var round = min(threads * 16, largestRound)
    var next = 0
    walk: while next < planned {
        let end = next + min(round, planned - next)
        round = min(round * 2, largestRound)
        var produced: [Input] = []
        produced.reserveCapacity(end - next)
        for step in next..<end { produced.append(enumerateAll ? element(step) : random(&rng)) }
        let inputs = produced
        let size = max(1, min(parallelism.chunkSize, (inputs.count + threads - 1) / threads))
        let chunks = (0..<(inputs.count + size - 1) / size).map { _ in Chunk<Output>() }
        DispatchQueue.concurrentPerform(iterations: min(threads, chunks.count)) { worker in
            for index in stride(from: worker, to: chunks.count, by: threads) {
                let batch = inputs[(index * size)..<min(inputs.count, (index + 1) * size)]
                chunks[index].evaluate(batch, function: function, assuming: assuming, reevaluate: reevaluate)
            }
        }
        for (index, chunk) in chunks.enumerated() {
            let batch = inputs[(index * size)..<min(inputs.count, (index + 1) * size)]
            guard fold.observe(chunk, of: batch) else { break walk }
        }
        next = end
    }

    let tally = Tally(evaluated: fold.evaluated, excluded: fold.excluded, skipped: fold.skipped)
    return Report(
        subject: subject,
        domainSize: domain.count,
        domainComplete: domain.complete && enumerateAll,
        evaluated: fold.evaluated,
        excluded: fold.excluded,
        results: verdicts(of: fold.slots, tally: tally, domain: domain, enumerateAll: enumerateAll, budget: budget)
    )
}

extension Chunk {
    /// Runs on a worker thread, so only the `@Sendable` closures are called.
    func evaluate<Input>(
        _ batch: ArraySlice<Input>, function: @Sendable (Input) throws -> Output, assuming: (@Sendable (Input) -> Bool)?,
        reevaluate: Bool
    ) {
        outputs.reserveCapacity(batch.count)
        for offset in 0..<batch.count {
            let input = batch[batch.startIndex + offset]
            if let assuming, !assuming(input) {
                exceptions.append(offset)
                errors.append(nil)
                continue
            }
            do {
                outputs.append(try function(input))
                if reevaluate { again.append(Result { try function(input) }) }
            } catch {
                exceptions.append(offset)
                errors.append(error)
            }
        }
    }
}

/// The serial walk's bookkeeping, fed one evaluated chunk at a time in walk order on the calling thread.
private struct OrderedFold<Input, Output> {
    var slots: [Slot<Input, Output>]
    let function: (Input) throws -> Output
    let observe: ContiguousArray<(Input, Output, Property<Input, Output>.Evaluate) -> String?>
    let reevaluates: ContiguousArray<Bool>
    let anyReevaluates: Bool
    var failed: ContiguousArray<Bool>
    var openProperties: Int
    var evaluated = 0
    var excluded = 0
    var skipped = 0

    init(properties: [Property<Input, Output>], function: @escaping (Input) throws -> Output) {
        slots = [Slot(name: "total", observer: .init(observe: { _, _, _ in nil }), failure: nil)]
        slots += properties.map { Slot(name: $0.name, observer: $0.makeObserver(), failure: nil) }
        self.function = function
        observe = ContiguousArray(slots.map(\.observer.observe))
        reevaluates = ContiguousArray(slots.map(\.observer.reevaluatesOnce))
        anyReevaluates = reevaluates.contains(true)
        failed = ContiguousArray(repeating: false, count: slots.count)
        openProperties = slots.count - 1
    }

    /// Observes `chunk`, the results for `batch`, as the serial walk would. `false` when the walk stops there.
    mutating func observe(_ chunk: Chunk<Output>, of batch: ArraySlice<Input>) -> Bool {
        var nextException = 0
        var outputIndex = 0
        for offset in 0..<batch.count {
            let input = batch[batch.startIndex + offset]
            if nextException < chunk.exceptions.count && chunk.exceptions[nextException] == offset {
                let error = chunk.errors[nextException]
                nextException += 1
                guard let error else {
                    excluded += 1
                    continue
                }
                evaluated += 1
                if !failed[0] { (failed[0], slots[0].failure) = (true, Counterexample(input: describe(input), detail: "threw \(error)")) }
                skipped += 1
                if openProperties == 0 { return false }
                continue
            }
            evaluated += 1
            let output = chunk.outputs[outputIndex]
            let again = anyReevaluates ? chunk.again[outputIndex] : nil
            outputIndex += 1
            var index = 1
            while index < observe.count {
                if !failed[index] {
                    let evaluate: (Input) throws -> Output
                    if reevaluates[index], let again { evaluate = { _ in try again.get() } } else { evaluate = function }
                    if let message = observe[index](input, output, evaluate) {
                        failed[index] = true
                        slots[index].failure = Counterexample(input: describe(input), detail: message)
                        openProperties -= 1
                    }
                }
                index += 1
            }
            if openProperties == 0 && failed[0] { return false }
        }
        return true
    }
}

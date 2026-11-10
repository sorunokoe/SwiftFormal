// A walk that survives a trap: it runs in a Swift Testing exit test, so a trap ends only the child process, and the
// parent names the input. Exit tests exist on macOS and Linux; on iOS and the other Apple platforms they are
// unavailable, so this file is compiled out there and a trap still ends the run. Exit tests arrived in Swift 6.2 and
// passing a value into one (the confirmation's capture list) in Swift 6.3, so it needs Swift 6.3.
#if (os(macOS) || os(Linux)) && compiler(>=6.3)
    #if canImport(Darwin)
        import Darwin
    #elseif canImport(Glibc)
        import Glibc
    #endif
    internal import Foundation
    package import SwiftFormal
    package import Testing

    /// One step of a walk, with what it takes to rebuild its input: the domain's size and the budget.
    ///
    /// It is `Codable`, so it can cross into the confirming exit test through a capture list:
    /// `{ [step = step as WalkStep] in callAloneInExitTest(step, over: domain) { f($0) } }`.
    package struct WalkStep: Codable, Sendable, Hashable, CustomStringConvertible {
        /// The walk's loop index: inputs `#requires` excluded count too.
        package let step: Int
        /// The size of the domain the walk ran over.
        package let domainCount: Int
        /// The budget's `maxEvaluations`.
        package let maxEvaluations: Int
        /// The budget's seed.
        package let seed: UInt64

        /// Creates a step of a walk over a domain of `domainCount` values with the given budget.
        package init(step: Int, domainCount: Int, budget: Budget) {
            self.step = step
            self.domainCount = domainCount
            self.maxEvaluations = budget.maxEvaluations
            self.seed = budget.seed
        }

        /// The input the walk took at this step, or `nil` when `domain` is not the domain the walk ran over (its size
        /// differs) or the walk never reached this step.
        package func input<Input>(in domain: Domain<Input>) -> Input? {
            guard domain.count == domainCount, step >= 0, step < min(domainCount, maxEvaluations) else { return nil }
            return domain.walkInput(atStep: step, maxEvaluations: maxEvaluations, seed: seed)
        }

        /// `step n`.
        package var description: String { "step \(step)" }
    }

    /// Walks `function` over `domain` inside an exit test, so that a trap names its input.
    ///
    /// Call it as the whole body of `#expect(processExitsWith: .failure, observing: [\.standardErrorContent])`, then
    /// pass the result to ``TrapWalk``. The child process never returns: it exits with its own code after a full walk,
    /// or dies of the trap after writing the step it was on. The verdict is decided as by `Prove`, but the issue
    /// is recorded by the parent (``TrapWalk/expectNoTrap(sourceLocation:)``).
    ///
    /// ```swift
    /// @Test func averageNeverTraps() async {
    ///     let child = await #expect(processExitsWith: .failure, observing: [\.standardErrorContent]) {
    ///         walkInThisExitTest("average", { average($0.0, $0.1) }, over: bytePairs)
    ///     }
    ///     var walk = TrapWalk(child, over: bytePairs)
    ///     if let step = walk.stepToConfirm {
    ///         walk.confirm(
    ///             await #expect(processExitsWith: .failure) { [step = step as WalkStep] in
    ///                 callAloneInExitTest(step, over: bytePairs) { average($0.0, $0.1) }
    ///             })
    ///     }
    ///     walk.expectNoTrap()
    /// }
    /// ```
    ///
    /// Outside an exit test it records an issue and returns without walking: exiting would end the whole test run.
    /// Suite defaults (``WalkDefaults``) do not reach the child process; pass `budget` here.
    package func walkInThisExitTest<Input, Output>(
        _ subject: String = "function",
        _ function: @escaping (Input) throws -> Output,
        over domain: Domain<Input>,
        budget: Budget = .default,
        allowBounded: Bool = false,
        sourceLocation: SourceLocation = #_sourceLocation,
        @PropertyBuilder<Input, Output> properties: () -> [Property<Input, Output>] = { [] }
    ) {
        guard ExitTest.current != nil else {
            Issue.record(
                "walkInThisExitTest runs only inside #expect(processExitsWith: .failure, observing: [\\.standardErrorContent])",
                sourceLocation: sourceLocation)
            return
        }
        TrapWalkProtocol.walkInThisChild(
            subject, function, over: domain,
            ChildWalk(budget: budget, allowBounded: allowBounded, inputType: nil, logAt: sourceLocation), properties: properties)
    }

    /// Calls `function` on the input of one walk step, alone, inside an exit test: the confirmation of a trap.
    ///
    /// Call it as the whole body of `#expect(processExitsWith: .failure) { [step = step as WalkStep] in ... }` and
    /// pass the result to ``TrapWalk/confirm(_:)``. The child exits with its own code when the call returns or throws,
    /// and dies of the trap when it traps. Outside an exit test it records an issue and returns without calling.
    package func callAloneInExitTest<Input, Output>(
        _ step: WalkStep,
        over domain: Domain<Input>,
        sourceLocation: SourceLocation = #_sourceLocation,
        _ function: (Input) throws -> Output
    ) {
        guard ExitTest.current != nil else {
            Issue.record(
                "callAloneInExitTest runs only inside #expect(processExitsWith: .failure)", sourceLocation: sourceLocation)
            return
        }
        guard let input = step.input(in: domain) else { exit(TrapWalkProtocol.aloneInputUnknown) }
        _ = try? function(input)
        exit(TrapWalkProtocol.aloneReturned)
    }

    /// What calling the function alone on a trapping input did (``callAloneInExitTest(_:over:sourceLocation:_:)``).
    package enum AloneCall: Sendable, Hashable {
        /// The confirmation has not run.
        case notRun
        /// The call trapped too: the function traps on this input.
        case traps
        /// The call returned (or threw): the trap needs what earlier calls did, or came from checking.
        case returns
        /// The confirming exit test gave no result, or exited in another way.
        case noResult
    }

    /// What a walk in an exit test did, read by the parent process from the child's exit status and standard error.
    ///
    /// Every outcome except a clean walk with an accepted verdict fails the test in
    /// ``expectNoTrap(sourceLocation:)``. None of them is ever a proof that the function cannot trap on inputs the
    /// walk did not reach: a trap stops the walk.
    package struct TrapWalk<Input>: CustomStringConvertible {
        /// A trap during the walk, with the input it happened on.
        package struct Trap {
            /// The step of the walk, to pass to ``callAloneInExitTest(_:over:sourceLocation:_:)``.
            package let step: WalkStep
            /// The input the walk was judging.
            package let input: Input
            /// The signal that ended the child (`SIGTRAP` for a Swift trap on arm64, `SIGILL` on x86-64).
            package let signal: Int32
            /// The runtime's message from standard error (`Fatal error: …`), when it printed one.
            package let message: String?
            /// What calling the function alone on the input did; `.notRun` until ``TrapWalk/confirm(_:)``.
            package var alone: AloneCall
        }

        /// The outcome of the walk.
        package enum Outcome {
            /// The child walked every planned input without a trap. `report` is the walk's report as text;
            /// `proved` and `accepted` are its verdict, judged as by `Prove` with the child's `allowBounded`.
            case walked(report: String, proved: Bool, accepted: Bool)
            /// The function under test trapped on the input.
            case trapped(Trap)
            /// A property, an observer or `#requires` trapped while checking the input, not the function call itself.
            case trappedWhileChecking(Trap)
            /// The child died of a signal, but no step was published: the trap happened outside the walk of an input
            /// (before it, or in a property's final check), standard error was not observed, or the child walked a
            /// different domain. `detail` says which.
            case trappedInputUnknown(signal: Int32, detail: String)
            /// The child ended in a way the walk never does: an exit code of its own (the function called `exit`), a
            /// signal it does not handle (`SIGKILL`), or no result at all.
            case unexpectedExit(String)
        }

        /// What the walk did.
        package private(set) var outcome: Outcome
        /// The subject the child walked, or `"function"` when its standard error was not observed.
        package let subject: String
        /// The walk's JSON line, written by the child of `Prove(neverTraps:)` after a walk without a trap.
        let childRecord: String?

        /// Reads the result of the exit test that ran ``walkInThisExitTest(_:_:over:budget:allowBounded:sourceLocation:properties:)``.
        package init(_ child: ExitTest.Result?, over domain: Domain<Input>) {
            self.init(status: child?.exitStatus, standardError: child?.standardErrorContent ?? [], over: domain)
        }

        init(status: ExitStatus?, standardError: [UInt8], over domain: Domain<Input>) {
            // Line by line, so a line that is not UTF-8 (the function printed bytes) costs only that line.
            let lines = standardError.split(separator: 0x0A).map { String(bytes: $0, encoding: .utf8) ?? "" }
            let parsed = TrapWalkProtocol.Parsed(lines)
            subject = parsed.subject ?? "function"
            childRecord = parsed.record
            outcome = Self.classify(status, parsed, domain)
        }

        // A switch over the exit status; each branch says why it is not a clean walk.
        private static func classify(_ status: ExitStatus?, _ parsed: TrapWalkProtocol.Parsed, _ domain: Domain<Input>) -> Outcome {
            guard let status else {
                return .unexpectedExit(
                    "the exit test returned no result: write it as #expect(processExitsWith: .failure, ...)")
            }
            switch status {
            case .exitCode(TrapWalkProtocol.walkedAccepted), .exitCode(TrapWalkProtocol.walkedRejected):
                guard let done = parsed.done, parsed.header != nil else {
                    return .unexpectedExit(
                        "\(status), but the walk's report is missing: add observing: [\\.standardErrorContent]")
                }
                let accepted = status == .exitCode(TrapWalkProtocol.walkedAccepted)
                return .walked(report: parsed.report.joined(separator: "\n"), proved: done.proved, accepted: accepted)
            case .exitCode(let code):
                return .unexpectedExit(
                    code == TrapWalkProtocol.walkTypeUnknown
                        ? "the child process did not find the walk's type by its name"
                        : "\(status) (the walk exits only with its own codes or a trap's signal)")
            case .signal(let signal) where TrapWalkProtocol.handledSignals.contains(signal):
                guard let header = parsed.header else {
                    return .trappedInputUnknown(
                        signal: signal, detail: "no walk header: add observing: [\\.standardErrorContent]")
                }
                guard let marker = parsed.trap else {
                    return .trappedInputUnknown(
                        signal: signal, detail: "the trap was not on an input (before the walk or in a final check)")
                }
                let step = WalkStep(
                    step: marker.step, domainCount: header.domainCount,
                    budget: Budget(maxEvaluations: header.maxEvaluations, seed: header.seed))
                guard let input = step.input(in: domain) else {
                    return .trappedInputUnknown(
                        signal: signal,
                        detail: "the child walked \(header.domainCount) values; this domain has \(domain.count)")
                }
                let trap = Trap(step: step, input: input, signal: signal, message: parsed.runtimeMessage, alone: .notRun)
                return marker.inFunction ? .trapped(trap) : .trappedWhileChecking(trap)
            case .signal:
                return .unexpectedExit("\(status), a signal the walk does not handle")
            @unknown default:
                return .unexpectedExit("\(status)")
            }
        }

        /// The step to run alone with ``callAloneInExitTest(_:over:sourceLocation:_:)``: set after a trap on a known
        /// input that is not confirmed yet.
        package var stepToConfirm: WalkStep? {
            switch outcome {
            case .trapped(let trap) where trap.alone == .notRun, .trappedWhileChecking(let trap) where trap.alone == .notRun:
                trap.step
            default: nil
            }
        }

        /// Records the result of the exit test that ran ``callAloneInExitTest(_:over:sourceLocation:_:)``.
        package mutating func confirm(_ alone: ExitTest.Result?) {
            confirm(status: alone?.exitStatus)
        }

        mutating func confirm(status: ExitStatus?) {
            let alone: AloneCall =
                switch status {
                case .signal: .traps
                case .exitCode(TrapWalkProtocol.aloneReturned): .returns
                default: .noResult
                }
            switch outcome {
            case .trapped(var trap):
                trap.alone = alone
                outcome = .trapped(trap)
            case .trappedWhileChecking(var trap):
                trap.alone = alone
                outcome = .trappedWhileChecking(trap)
            default: break
            }
        }

        /// Records a test issue unless the walk ran to the end with an accepted verdict: an error for a trap, an
        /// unknown input, an unexpected exit or a rejected verdict, and a warning for an accepted `bounded` one.
        /// Returns whether the test should pass.
        @discardableResult
        package func expectNoTrap(sourceLocation: SourceLocation = #_sourceLocation) -> Bool {
            switch outcome {
            case let .walked(report, proved, accepted):
                if proved { return true }
                let text = accepted ? "bounded, accepted with allowBounded (not a proof):\n" + report : report
                Issue.record(Comment(rawValue: text), severity: accepted ? .warning : .error, sourceLocation: sourceLocation)
                return accepted
            default:
                Issue.record(Comment(rawValue: description), sourceLocation: sourceLocation)
                return false
            }
        }

        /// One line per outcome, naming the input when it is known.
        package var description: String {
            switch outcome {
            case .walked(let report, _, _):
                return report
            case .trapped(let trap):
                let alone =
                    switch trap.alone {
                    case .traps: "; confirmed: it traps when called alone on this input"
                    case .returns: "; called alone on this input it does not trap, so the trap depends on earlier calls"
                    case .notRun: "; not confirmed alone"
                    case .noResult: "; the call alone gave no result"
                    }
                return "\(subject) traps for input \(describeMasked(trap.input)) (\(trap.step), \(Self.name(trap)))\(alone)"
            case .trappedWhileChecking(let trap):
                let alone = trap.alone == .traps ? "; the function alone traps on it too" : ""
                return "\(subject): a property, observer or #requires trapped while checking input "
                    + "\(describeMasked(trap.input)) (\(trap.step), \(Self.name(trap)))\(alone)"
            case let .trappedInputUnknown(signal, detail):
                return "\(subject) trapped (\(TrapWalkProtocol.signalName(signal))); the input is unknown: \(detail)"
            case .unexpectedExit(let detail):
                return "\(subject): the walk's process ended unexpectedly: \(detail)"
            }
        }

        private static func name(_ trap: Trap) -> String {
            TrapWalkProtocol.signalName(trap.signal) + (trap.message.map { ": \($0)" } ?? "")
        }
    }
#endif

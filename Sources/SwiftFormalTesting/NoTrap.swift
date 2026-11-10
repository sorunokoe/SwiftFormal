// The trap check in one call: `await Prove(neverTraps: MyWalk.self)`. The walk runs in an exit test that this
// file declares, so a test writes no `#expect(processExitsWith:)` of its own. An exit test's body runs in a new process
// and can capture only `Codable` values, so the function under test cannot cross as a closure: it crosses as the
// mangled name of a type the test declares (`ExitTestWalk`), which the child process finds with `_typeByName`.
#if (os(macOS) || os(Linux)) && compiler(>=6.3)
    #if canImport(Darwin)
        import Darwin
    #elseif canImport(Glibc)
        import Glibc
    #endif
    internal import Foundation
#endif
public import SwiftFormal
public import Testing

/// A function and the inputs to walk it over, declared as a type so a trap check can run it in another process.
///
/// The child process finds the type by its name, so declare it `internal` (or `public`) at file scope or inside another
/// such type: a `private` or `fileprivate` type, or one inside a function, has no name another process can look up
/// (`Prove(neverTraps:)` then records an issue and walks nothing).
///
/// ```swift
/// enum SelectedTab: ExitTestWalk {
///     static let inputs: Domain<Int> = .of([0, 1, 2, -1])
///     static func call(_ index: Int) -> Tab { TabsState(selectedTabIndex: index).selectedTab }
/// }
///
/// @Test func selectedTabNeverTraps() async {
///     await Prove(neverTraps: SelectedTab.self)
/// }
/// ```
public protocol ExitTestWalk {
    /// The input of the function under test.
    associatedtype Input
    /// The output of the function under test.
    associatedtype Output
    /// The inputs to walk.
    static var inputs: Domain<Input> { get }
    /// Calls the function under test on one input.
    static func call(_ input: Input) throws -> Output
}

extension Prove {
    /// Walks `walk` over its inputs in a child process, and records a test issue if the function traps, naming the input.
    ///
    /// ```swift
    /// @Test func selectedTabNeverTraps() async {
    ///     await Prove(neverTraps: SelectedTab.self)
    /// }
    /// ```
    ///
    /// A Swift trap (overflow, force unwrap, an index out of range) ends the process it happens in, so a walk in the test
    /// process cannot report it. This runs the walk in a Swift Testing exit test: a trap ends only the child, which writes
    /// the step it was on; the parent names the input, then calls the function alone on it in a second child, to tell "it
    /// traps on this input" from "it traps only after earlier calls". A walk without a trap is judged like any other
    /// `Prove`, with the implicit `total` property (it must not throw). A trap stops the walk, so ``report`` then has one
    /// failed property, "never traps", with the input. The child cannot call a closure of the test, so the function and
    /// its inputs are an ``ExitTestWalk`` type.
    ///
    /// `swiftformal check` reads the function under test from the body of the type's `call`, as it reads an `it:`
    /// closure (`TabsState.selectedTab` for `TabsState(selectedTabIndex: index).selectedTab`), runs the walk like any
    /// other, and reads a trap as a failure of "never traps" with the input. Pass a subject
    /// (`Prove("TabsState.selectedTab", neverTraps: …)`) when the body does not start with that call.
    ///
    /// Exit tests exist on macOS and Linux with Swift 6.3 or newer. Elsewhere (iOS) nothing is walked: the walk records
    /// a warning (Swift 6.3), its report is `bounded` with nothing checked, and `swiftformal check` sees no result for it.
    ///
    /// - Parameters:
    ///   - subject: The name in the report and the function `swiftformal check` links the walk to. By default the
    ///     check reads it from the type's `call`, and the report names the type's `call` (`SelectedTab.call`).
    ///   - walk: The type that names the inputs and calls the function.
    ///   - budget: The most inputs to evaluate before the verdict is only `bounded`. Suite defaults reach the child.
    ///   - allowBounded: Accept "no trap found" for a domain too large to walk in full.
    ///   - knownIssue: A failure the test expects (a trap on a known input); the test then fails once it stops failing.
    ///   - sourceLocation: Where the issues and the walk's record are placed: the call.
    @discardableResult
    public init<Walk: ExitTestWalk>(
        _ subject: String? = nil,
        neverTraps walk: Walk.Type,
        budget: Budget = WalkDefaults.budget,
        allowBounded: Bool = WalkDefaults.allowBounded,
        knownIssue: KnownFailure? = nil,
        sourceLocation: SourceLocation = #_sourceLocation
    ) async where Walk.Input == Input, Walk.Output == Output {
        // Without a subject the walk is named after the function it calls, `SelectedTab.call`: the test's name would
        // read as "<test> traps for input …".
        report = await walk.walkNeverTraps(
            subject ?? "\(Walk.self).call", budget: budget, allowBounded: allowBounded, knownIssue: knownIssue,
            sourceLocation: sourceLocation)
        failures = report.counterexamples
    }
}

/// The walk of `Prove(neverTraps:)`: the exit tests, the walk's record and the issues. Returns the walk's report: one
/// built from the record the parent logged, so it says exactly what `swiftformal check` reads.
extension ExitTestWalk {
    static func walkNeverTraps(
        _ subject: String, budget: Budget, allowBounded: Bool, knownIssue: KnownFailure?, sourceLocation: SourceLocation
    ) async -> Report {
        typealias Walk = Self
        #if (os(macOS) || os(Linux)) && compiler(>=6.3)
            guard let name = _mangledTypeName(Walk.self), _typeByName(name) != nil else {
                let reason =
                    "\(Walk.self) cannot be found by name in another process: declare it internal (not private or fileprivate), at file scope or inside a type, not in a function"
                Issue.record(Comment(rawValue: reason), sourceLocation: sourceLocation)
                return notWalked(subject, Walk.inputs.count, reason: reason)
            }
            let request = NoTrapRequest(
                typeName: name, subject: subject, maxEvaluations: budget.maxEvaluations, seed: budget.seed, allowBounded: allowBounded)
            let trapWalk = await NoTrapChild.run(request, over: Walk.inputs)
            let line = trapWalk.record(subject: subject, inputType: Walk.Input.self, knownIssue: knownIssue, sourceLocation: sourceLocation)
            return line.report
        #else
            #if compiler(>=6.3)
                Issue.record(
                    "Prove(neverTraps:) needs exit tests (macOS or Linux, Swift 6.3): \(subject) was not walked", severity: .warning,
                    sourceLocation: sourceLocation)
            #endif
            return notWalked(subject, Walk.inputs.count, reason: "not walked: exit tests need macOS or Linux and Swift 6.3")
        #endif
    }
}

/// The report of a trap walk that did not run: `bounded` with nothing checked, never a proof.
private func notWalked(_ subject: String, _ domainSize: Int, reason: String) -> Report {
    Report(
        subject: subject, domainSize: domainSize, domainComplete: false, evaluated: 0, excluded: 0,
        results: [PropertyResult(name: "never traps", verdict: .bounded(checked: 0, reason: reason))])
}

extension WalkLog.Line {
    /// The report this line records. A property whose verdict is not `proved` or `bounded` is a failure, and a line with
    /// no property, or whose own verdict is not `proved` while every property is, gets a failed one: a line read back
    /// is never more of a proof than it says.
    var report: Report {
        var results = properties.map { property -> PropertyResult in
            let checked = property.checked ?? evaluated
            let verdict: Verdict =
                switch property.verdict {
                case "proved": .proved(checked: checked)
                case "bounded": .bounded(checked: checked, reason: property.detail ?? "not the whole domain")
                default: .counterexample(Counterexample(input: property.input, detail: property.detail ?? property.verdict))
                }
            return PropertyResult(name: property.name, verdict: verdict)
        }
        if results.isEmpty || (verdict != "proved" && results.allSatisfy(\.verdict.isProved)) {
            let detail = "the walk's record says \(verdict)"
            results.append(PropertyResult(name: "never traps", verdict: .counterexample(Counterexample(input: nil, detail: detail))))
        }
        return Report(
            subject: subject, domainSize: domainSize, domainComplete: domainComplete, evaluated: evaluated, excluded: 0,
            results: results)
    }
}

#if (os(macOS) || os(Linux)) && compiler(>=6.3)
    /// What the child of `Prove(neverTraps:)` needs: the walk's type by mangled name, and the budget.
    struct NoTrapRequest: Codable, Sendable {
        var typeName: String
        var subject: String
        var maxEvaluations: Int
        var seed: UInt64
        var allowBounded: Bool
        var budget: Budget { Budget(maxEvaluations: maxEvaluations, seed: seed) }
    }

    /// The two exit tests of `Prove(neverTraps:)`. Their bodies run in a child process, which finds the walk's type by name.
    enum NoTrapChild {
        /// The walk, then, after a trap on a known input, the function alone on it.
        static func run<Input>(_ request: NoTrapRequest, over inputs: Domain<Input>) async -> TrapWalk<Input> {
            var trapWalk = TrapWalk(await walk(request), over: inputs)
            if let step = trapWalk.stepToConfirm { trapWalk.confirm(await callAlone(request, step: step)) }
            return trapWalk
        }

        /// The walk, as `walkInThisExitTest` runs it.
        static func walk(_ request: NoTrapRequest) async -> ExitTest.Result? {
            await #expect(processExitsWith: .failure, observing: [\.standardErrorContent]) { [request = request as NoTrapRequest] in
                guard let type = _typeByName(request.typeName) as? any ExitTestWalk.Type else {
                    exit(TrapWalkProtocol.walkTypeUnknown)
                }
                NoTrapChild.runWalk(type, request)
            }
        }

        /// The function alone on the input of `step`, as `callAloneInExitTest` calls it.
        static func callAlone(_ request: NoTrapRequest, step: WalkStep) async -> ExitTest.Result? {
            await #expect(processExitsWith: .failure) { [request = request as NoTrapRequest, step = step as WalkStep] in
                guard let type = _typeByName(request.typeName) as? any ExitTestWalk.Type else {
                    exit(TrapWalkProtocol.walkTypeUnknown)
                }
                NoTrapChild.runAlone(type, step)
            }
        }

        private static func runWalk<Walk: ExitTestWalk>(_: Walk.Type, _ request: NoTrapRequest) -> Never {
            TrapWalkProtocol.walkInThisChild(
                request.subject, Walk.call, over: Walk.inputs,
                ChildWalk(budget: request.budget, allowBounded: request.allowBounded, inputType: Walk.Input.self, logAt: nil),
                properties: { [] })
        }

        private static func runAlone<Walk: ExitTestWalk>(_: Walk.Type, _ step: WalkStep) -> Never {
            guard let input = step.input(in: Walk.inputs) else { exit(TrapWalkProtocol.aloneInputUnknown) }
            _ = try? Walk.call(input)
            exit(TrapWalkProtocol.aloneReturned)
        }
    }

    extension TrapWalk {
        /// Logs the walk's line for `swiftformal check` at `location`, attaches it, and records the issues: none for a
        /// proof, a warning for an accepted `bounded` verdict, an error otherwise.
        /// Returns the logged line.
        @discardableResult
        func record(subject: String, inputType: Any.Type, knownIssue: KnownFailure?, sourceLocation: SourceLocation) -> WalkLog.Line {
            let line = checkLine(subject: subject, inputType: inputType, at: sourceLocation)
            let encoded = try? JSONEncoder().encode(line)
            if let encoded { WalkLog.append(encoded) }
            let found = findings
            #if compiler(>=6.2)
                if Test.current != nil {
                    let everyReport = WalkAttachments.everyReport(environment: ProcessInfo.processInfo.environment)
                    let files = WalkAttachments.contents(
                        subject: subject, line: encoded, text: description, proved: found.severity == nil, everyReport: everyReport)
                    for file in files { Attachment.record(file.text, named: file.name, sourceLocation: sourceLocation) }
                }
            #endif
            WalkIssue.record(found, knownIssue: knownIssue, sourceLocation: sourceLocation)
            return line
        }

        /// What the walk found, for its issues.
        var findings: WalkFindings {
            switch outcome {
            case let .walked(report, proved, accepted):
                let severity: WalkIssue.Severity? = proved ? nil : accepted ? .warning : .error
                let text = severity == .warning ? "bounded, accepted with allowBounded (not a proof):\n" + report : report
                let failed = childLine?.properties.filter { $0.verdict == "failed" }.map(\.input) ?? [nil]
                return WalkFindings(
                    message: text, severity: severity, failingInputs: severity == .error ? failed : [], listsEveryFailure: false)
            case .trapped(let trap), .trappedWhileChecking(let trap):
                return WalkFindings(
                    message: description, severity: .error, failingInputs: [describeInput(trap.input)], listsEveryFailure: false)
            case .trappedInputUnknown, .unexpectedExit:
                return WalkFindings(message: description, severity: .error, failingInputs: [nil], listsEveryFailure: false)
            }
        }

        /// The walk's line for `swiftformal check`: the child's own after a walk without a trap, else a failure of
        /// "never traps", with the input when it is known. A trap is never `proved` or `bounded`.
        func checkLine(subject: String, inputType: Any.Type, at location: SourceLocation) -> WalkLog.Line {
            if case .walked = outcome, var line = childLine {
                line.subject = subject
                line.place(at: location)
                return line
            }
            var input: String?
            var evaluated = 0
            var domainSize = 0
            if case .trapped(let trap) = outcome {
                (input, evaluated, domainSize) = (describeInput(trap.input), trap.step.step + 1, trap.step.domainCount)
            }
            if case .trappedWhileChecking(let trap) = outcome {
                (input, evaluated, domainSize) = (describeInput(trap.input), trap.step.step + 1, trap.step.domainCount)
            }
            var line = WalkLog.Line(
                subject: subject, verdict: "failed", evaluated: evaluated, domainSize: domainSize, domainComplete: false,
                properties: [WalkLog.Property(name: "never traps", verdict: "failed", input: input, detail: description)], file: "",
                line: 0, test: nil, inputType: String(reflecting: inputType))
            line.place(at: location)
            return line
        }

        private var childLine: WalkLog.Line? {
            childRecord.flatMap { try? JSONDecoder().decode(WalkLog.Line.self, from: Data($0.utf8)) }
        }
    }

    /// An input as a report prints it (`Counterexample.input`), so a known issue's inputs match it.
    func describeInput<Input>(_ input: Input) -> String {
        let text = String(describing: input)
        return text.count > 300 ? String(text.prefix(300)) + "..." : text
    }
#endif

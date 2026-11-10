/// Design-by-contract checks that live inside the function they describe.
///
/// In a normal run a violated contract is an `assertionFailure`: it stops a debug build at the
/// broken call. While `verify_<name>()` walks a domain, the same checks record the violation
/// instead, so it comes back as a counterexample with the real input. The `@Verify`, `#requires`
/// and `#ensures` macros expand to these calls; `@Verify` puts the calls in the body inside
/// `#if DEBUG` unless `checks: .always`, so a release build neither evaluates nor reports them.
public enum Contract {
    // One recorder serves one synchronous call, so it is never shared between threads.
    final class Recorder: @unchecked Sendable {
        var violations: [String] = []
    }

    @TaskLocal static var recorder: Recorder?

    /// A precondition. Callers must satisfy it; a walk never calls the function outside it.
    public static func requires(
        _ condition: @autoclosure () -> Bool,
        _ text: @autoclosure () -> String = "",
        file: StaticString = #fileID,
        line: UInt = #line
    ) {
        // The condition first: reading the task-local recorder costs more than a typical condition, and it is only
        // needed when the condition fails. Inside a verification the walk already excludes inputs outside `#requires`.
        if !condition() && recorder == nil { assertionFailure("requires failed: \(text())", file: file, line: line) }
    }

    /// A postcondition on the value being returned. A violation names the returned value, shortened to 300 characters.
    @discardableResult
    public static func ensures<Result>(
        _ result: Result,
        _ text: @autoclosure () -> String = "",
        file: StaticString = #fileID,
        line: UInt = #line,
        _ predicate: (Result) -> Bool
    ) -> Result {
        if !predicate(result) {
            if let recorder {
                recorder.violations.append("\(text()) (result: \(describe(result)))")
            } else {
                // Built inside the autoclosure, so a release build (where the assertion is off) formats nothing.
                assertionFailure("ensures failed: \(text()) (result: \(describe(result)))", file: file, line: line)
            }
        }
        return result
    }

    /// Called by `@Verify` when a `#requires` condition is false. The condition is checked in the caller as plain
    /// Swift, so Scan reads it from the compiled function; Scan treats this call as a trap.
    @inline(never)
    public static func requiresFailed(_ text: StaticString, file: StaticString = #fileID, line: UInt = #line) {
        if recorder == nil { assertionFailure("requires failed: \(text)", file: file, line: line) }
    }

    /// Called by `@Verify` when an `#ensures` predicate is false for the returned value. Scan treats this call as a
    /// trap; while `verify_<name>()` walks a domain it records the violation instead.
    @inline(never)
    public static func ensuresFailed(_ text: StaticString, file: StaticString = #fileID, line: UInt = #line) {
        if let recorder {
            recorder.violations.append("\(text)")
        } else {
            assertionFailure("ensures failed: \(text)", file: file, line: line)
        }
    }
}

/// What `_verifyContracts` observes for one call.
package struct Checked<Output> {
    /// The value the function returned.
    package let output: Output
    /// The `ensures` messages that failed for this call. Empty when every check held.
    package let violations: [String]
}

/// Called by the `verify_<name>()` that `@Verify` writes; do not call it. Mark the function `@Verify`, or walk it in a
/// test with `Prove`.
///
/// Verifies the `Contract.ensures` checks of `function` over the inputs that satisfy `requires`. `function` must be the
/// instrumented function itself, the one `@Verify` marks. Every `ensures` that fails on an input is reported for that
/// input. Extra properties see the function's output as usual. It is public, under a name that says so, only because
/// the code `@Verify` writes compiles in the app's module.
@_documentation(visibility: internal)
public func _verifyContracts<Input, Output>(
    _ subject: String = "function",
    _ function: @escaping (Input) throws -> Output,
    over domain: Domain<Input>,
    budget: Budget = .default,
    @PropertyBuilder<Input, Output> properties: () -> [Property<Input, Output>] = { [] },
    requires: ((Input) -> Bool)? = nil
) -> Report {
    let extra = properties()
    // One recorder, bound once for the whole walk and emptied before each call. Every call the walk makes sees it,
    // also the extra calls a property makes (`.deterministic()` calls the function again), so a failing `ensures`
    // is recorded there instead of stopping a debug build.
    let recorder = Contract.Recorder()
    let checked = { (input: Input) throws -> Checked<Output> in
        recorder.violations = []
        let output = try function(input)
        return Checked(output: output, violations: recorder.violations)
    }
    return Contract.$recorder.withValue(recorder) {
        runWalk(
            subject,
            checked,
            over: domain,
            budget: budget,
            properties: {
                Property<Input, Checked<Output>>.perInput("ensures") { _, checked in
                    checked.violations.first.map { "violated: \($0)" }
                }
                for property in extra {
                    Property<Input, Checked<Output>>.custom(property.name) {
                        let inner = property.makeObserver()
                        return .init(
                            observe: { input, checked, _ in inner.observe(input, checked.output) { try function($0) } },
                            finish: inner.finish
                        )
                    }
                }
            },
            assuming: requires
        )
    }
}

// The child-to-parent protocol of a trap walk (TrapWalk.swift): exit codes, the lines on standard error, and the
// signal handler that writes the step. Compiled only where exit tests exist.
#if (os(macOS) || os(Linux)) && compiler(>=6.3)
    #if canImport(Darwin)
        import Darwin
    #elseif canImport(Glibc)
        import Glibc
    #endif
    internal import Foundation
    internal import SwiftFormal
    internal import Testing

    /// How a child walks: the budget, whether a `bounded` verdict is accepted, the input type for the record, and where
    /// to log the report from the child (`nil`: send it to the parent).
    struct ChildWalk {
        var budget: Budget
        var allowBounded: Bool
        var inputType: Any.Type?
        var logAt: SourceLocation?
    }

    /// The lines and exit codes a trap walk's child writes and its parent reads.
    enum TrapWalkProtocol {
        static let walkedAccepted: Int32 = 86
        static let walkedRejected: Int32 = 87
        static let aloneReturned: Int32 = 88
        static let aloneInputUnknown: Int32 = 89
        /// The child of `Prove(neverTraps:)` did not find the walk's type by its name.
        static let walkTypeUnknown: Int32 = 90

        static let headerTag = "SWIFTFORMAL-WALK "
        static let subjectTag = "SWIFTFORMAL-WALK-SUBJECT "
        static let trapTag = "SWIFTFORMAL-WALK-TRAP "
        static let reportBegin = "SWIFTFORMAL-WALK-REPORT-BEGIN"
        static let reportEnd = "SWIFTFORMAL-WALK-REPORT-END"
        static let doneTag = "SWIFTFORMAL-WALK-DONE "
        /// The walk's JSON line for `swiftformal check`, which the parent places at its own call and logs.
        static let recordTag = "SWIFTFORMAL-WALK-RECORD "

        /// Swift traps are `SIGTRAP` (arm64) or `SIGILL` (x86-64); the others are crashes on an input too.
        static let handledSignals: [Int32] = [SIGTRAP, SIGILL, SIGABRT, SIGFPE, SIGBUS, SIGSEGV]

        static func signalName(_ signal: Int32) -> String {
            let names: [Int32: String] = [
                SIGTRAP: "SIGTRAP", SIGILL: "SIGILL", SIGABRT: "SIGABRT", SIGFPE: "SIGFPE", SIGBUS: "SIGBUS",
                SIGSEGV: "SIGSEGV", SIGKILL: "SIGKILL",
            ]
            return names[signal] ?? "signal \(signal)"
        }

        static func header(subject: String, step: WalkStep) -> String {
            let oneLine = subject.replacingOccurrences(of: "\n", with: " ")
            return "\n\(headerTag)\(step.domainCount) \(step.maxEvaluations) \(step.seed)\n\(subjectTag)\(oneLine)\n"
        }

        static func footer(report: Report, accepted: Bool, record: Data? = nil) -> String {
            let verdict = report.isProved ? "proved" : report.hasNoCounterexample ? "bounded" : "failed"
            let line = record.flatMap { String(bytes: $0, encoding: .utf8) }.map { "\(recordTag)\($0)\n" } ?? ""
            return "\n\(reportBegin)\n\(report.description)\n\(reportEnd)\n\(line)\(doneTag)\(verdict) \(accepted ? 1 : 0)\n"
        }

        /// Walks `function` in this exit-test child and exits: with its own code after the walk, or of a trap's signal
        /// after writing the step. With `ChildWalk.logAt` it appends the report to the side file from here
        /// (`walkInThisExitTest`); without it the report's JSON line goes to the parent on standard error (`Prove(neverTraps:)`).
        static func walkInThisChild<Input, Output>(
            _ subject: String, _ function: @escaping (Input) throws -> Output, over domain: Domain<Input>, _ walk: ChildWalk,
            properties: () -> [Property<Input, Output>]
        ) -> Never {
            let (budget, allowBounded, inputType, location) = (walk.budget, walk.allowBounded, walk.inputType, walk.logAt)
            writeToStandardError(header(subject: subject, step: WalkStep(step: 0, domainCount: domain.count, budget: budget)))
            installSignalHandlers()
            WalkProbe.isPublishing = true
            let report = runWalk(subject, function, over: domain, budget: budget, properties: properties)
            WalkProbe.isPublishing = false
            let accepted = WalkIssue.severity(for: report, allowBounded: allowBounded) != .error
            var record: Data?
            if let location {
                WalkLog.append(report, inputType: inputType, at: location)
            } else {
                let placeholder = SourceLocation(fileID: "SwiftFormalTesting/Child.swift", filePath: "Child.swift", line: 1, column: 1)
                record = try? JSONEncoder().encode(
                    WalkLog.record(for: report, inputType: inputType.map { String(reflecting: $0) }, at: placeholder))
            }
            writeToStandardError(footer(report: report, accepted: accepted, record: record))
            exit(accepted ? walkedAccepted : walkedRejected)
        }

        static func writeToStandardError(_ text: String) {
            FileHandle.standardError.write(Data(text.utf8))
        }

        static func installSignalHandlers() {
            // Touch the probe first, so the handler never runs a global's lazy initializer.
            WalkProbe.step = -1
            WalkProbe.inFunction = false
            for number in handledSignals { _ = signal(number, writeTrapStep) }
        }

        /// What the parent reads back.
        struct Parsed {
            /// The walk's domain size and budget, as step 0.
            var header: WalkStep?
            var subject: String?
            var trap: (step: Int, inFunction: Bool)?
            var report: [String] = []
            var done: (proved: Bool, accepted: Bool)?
            var runtimeMessage: String?
            /// The walk's JSON line, from the child of `Prove(neverTraps:)`.
            var record: String?

            init(_ lines: [String]) {
                var inReport = false
                for line in lines {
                    if inReport {
                        if line == TrapWalkProtocol.reportEnd { inReport = false } else { report.append(line) }
                    } else if line == TrapWalkProtocol.reportBegin {
                        inReport = true
                    } else {
                        read(line)
                    }
                }
            }

            private mutating func read(_ line: String) {
                if let value = Self.value(of: TrapWalkProtocol.subjectTag, in: line) {
                    subject = String(value)
                } else if let value = Self.value(of: TrapWalkProtocol.recordTag, in: line) {
                    record = String(value)
                } else if let fields = Self.fields(of: TrapWalkProtocol.trapTag, in: line), fields.count == 2,
                    let step = Int(fields[0])
                {
                    trap = (step, fields[1] == "0")
                } else if let fields = Self.fields(of: TrapWalkProtocol.doneTag, in: line), fields.count == 2 {
                    done = (fields[0] == "proved", fields[1] == "1")
                } else if let fields = Self.fields(of: TrapWalkProtocol.headerTag, in: line), fields.count == 3,
                    let count = Int(fields[0]), let budget = Int(fields[1]), budget > 0, let seed = UInt64(fields[2])
                {
                    header = WalkStep(step: 0, domainCount: count, budget: Budget(maxEvaluations: budget, seed: seed))
                } else if ["Fatal error", "Precondition failed", "Assertion failed"].contains(where: line.contains) {
                    runtimeMessage = line.trimmingCharacters(in: .whitespaces)
                }
            }

            private static func value(of tag: String, in line: String) -> Substring? {
                line.hasPrefix(tag) ? line.dropFirst(tag.count) : nil
            }

            private static func fields(of tag: String, in line: String) -> [Substring]? {
                value(of: tag, in: line)?.split(separator: " ")
            }
        }
    }

    /// The signal handler: async-signal-safe, so it only loads two globals and calls `write(2)`, `signal` and `raise`.
    /// It writes `SWIFTFORMAL-WALK-TRAP <step> <0 in the function | 1 checking>` when the walk is on an input, then
    /// dies of the same signal with the default action, so the exit status is still the signal.
    private func writeTrapStep(_ number: Int32) {
        let step = WalkProbe.step
        if step >= 0 {
            let tag: StaticString = "\nSWIFTFORMAL-WALK-TRAP "
            _ = write(2, tag.utf8Start, tag.utf8CodeUnitCount)
            var divisor = 1
            while step / divisor >= 10 { divisor *= 10 }
            var rest = step
            var byte: UInt8 = 0
            while divisor > 0 {
                byte = UInt8(truncatingIfNeeded: 48 + rest / divisor)
                _ = write(2, &byte, 1)
                rest %= divisor
                divisor /= 10
            }
            byte = 0x20
            _ = write(2, &byte, 1)
            byte = WalkProbe.inFunction ? 0x30 : 0x31
            _ = write(2, &byte, 1)
            byte = 0x0A
            _ = write(2, &byte, 1)
        }
        _ = signal(number, SIG_DFL)
        _ = raise(number)
    }
#endif

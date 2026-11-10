import Foundation

/// A `// sf:verify` comment on the line above a function, or at the end of its line. It asked the build to prove the
/// function before contracts were only `@Verify`; it is no longer read, and each one is reported (`Gate.staleMarkers`).
public struct GateMarker: Sendable, Equatable {
    public var file: String
    /// The line that holds `sf:verify`.
    public var markerLine: Int
    /// The line of the `func` or `init` it applies to; 0 when no declaration follows.
    public var declarationLine: Int
    /// `clamp` for `func clamp(...)`, `init` for an initializer.
    public var name: String
}

/// The build gate: which functions must be proved, and the diagnostics when one is not. The gated functions are those
/// marked `@Verify` (`BuildCheck.promises`), those with the contract it writes, and those with a hand-written
/// `f_requires` / `f_ensures`, which is reported as not read.
///
/// A gated function is fail-closed. If sfverify cannot prove it (it may trap, a contract fails, the proof
/// is undecided, the function is outside the supported subset, or it was not found), the build fails.
/// "Cannot verify" is never a silent pass, because a gate that passes when it understands nothing is a lie.
public enum Gate {
    public static let markerToken = "sf:verify"

    /// What a `// sf:verify` comment gets: it selects nothing, and the gate fails until it is replaced.
    package static let markerMessage =
        "`// sf:verify` is no longer read: mark the function @Verify instead (\(FunctionReport.inPlaceAdvice) for a contract)"

    /// Finds `// sf:verify` markers. A marker that is not followed by a function is reported as a problem.
    public static func markers(in files: [String]) -> (markers: [GateMarker], problems: [String]) {
        markers(in: files) { try? String(contentsOfFile: $0, encoding: .utf8) }
    }

    /// The same, with each file's text from `read` (nil: unreadable).
    package static func markers(in files: [String], read: (String) -> String?) -> (markers: [GateMarker], problems: [String]) {
        var markers: [GateMarker] = []
        var problems: [String] = []
        for file in files {
            guard let text = read(file), text.contains(markerToken) else { continue }
            let lines = text.components(separatedBy: "\n")
            for (index, line) in lines.enumerated() where hasMarker(line) {
                if let declaration = declaration(startingAt: index, in: lines) {
                    markers.append(
                        GateMarker(file: file, markerLine: index + 1, declarationLine: declaration.line + 1, name: declaration.name))
                } else {
                    problems.append("\(file):\(index + 1):1: error: [sfverify] `\(markerToken)` is not followed by a function")
                }
            }
        }
        return (markers, problems)
    }

    /// Every `// sf:verify` comment in `files`, followed by a function or not: each is reported, none selects anything.
    package static func staleMarkers(in files: [String], read: (String) -> String?) -> [SourceLocation] {
        var found: [SourceLocation] = []
        for file in files {
            guard let text = read(file), text.contains(markerToken) else { continue }
            for (index, line) in text.components(separatedBy: "\n").enumerated() where hasMarker(line) {
                found.append(SourceLocation(file: file, line: index + 1, column: 1))
            }
        }
        return found
    }

    /// Functions with a function named like their contract next to them: `f_requires` or `f_ensures`. Scan reads
    /// only the contract `@Verify` writes, so these are scanned to report a hand-written one (`ignoredContracts`).
    public static func contractNames(in files: [String]) -> Set<String> {
        contractNames(in: files) { try? String(contentsOfFile: $0, encoding: .utf8) }
    }

    /// The same, with each file's text from `read` (nil: unreadable).
    package static func contractNames(in files: [String], read: (String) -> String?) -> Set<String> {
        var names: Set<String> = []
        for file in files {
            guard let text = read(file) else { continue }
            for line in text.components(separatedBy: "\n") {
                guard let name = functionName(in: line) else { continue }
                for suffix in ["_requires", "_ensures"] where name.hasSuffix(suffix) && name.count > suffix.count {
                    names.insert(String(name.dropLast(suffix.count)))
                }
            }
        }
        return names
    }

    /// Errors for a gate that ran out of wall-clock time: one per gated declaration, so each shows in the editor.
    public static func timeoutDiagnostics(files: [String], seconds: Int) -> [String] {
        let message =
            "the proof did not finish within \(seconds) s; raise --time-limit, or simplify it (wide multiplication/division is hard for SAT: try narrower types)"
        let gated = BuildCheck.promises(in: files).promises.map {
            error(SourceLocation(file: $0.file, line: $0.declarationLine, column: 1), "\($0.name): " + message)
        }
        return gated.isEmpty ? [error(nil, message)] : gated
    }

    /// Turns a report into diagnostics. `passed` is false when any gated function is not proved.
    ///
    /// - Parameters:
    ///   - promises: The `@Verify` functions (`BuildCheck.promises`). A function with a contract, or with a
    ///     hand-written one Scan did not read, is gated too.
    ///   - files: The gated sources. When given, a broken contract adds a `note:` at its `_ensures` (or `_requires`)
    ///     function when the source declares one, and a trap in a callee without a position adds one at that callee's
    ///     declaration.
    public static func check(_ report: ScanReport, promises: [Promise], files: [String] = []) -> GateResult {
        var diagnostics: [String] = []
        var gated = 0
        var proved = 0
        var matched: Set<Int> = []

        for function in report.functions {
            let promiseIndex = promises.firstIndex { BuildCheck.covers($0, function) }
            let base = function.name.firstIndex(of: "(").map { String(function.name[..<$0]) } ?? function.name
            let shortName = base.split(separator: ".").last.map(String.init) ?? base
            let unread = unreadContract(function, shortName: shortName, files: files)
            guard promiseIndex != nil || function.hasContract || unread != nil else { continue }
            if let promiseIndex { matched.insert(promiseIndex) }
            gated += 1
            // Never proved, whatever its status says: a contract that is not checked.
            if let unread {
                diagnostics.append(unread)
                continue
            }

            switch function.status {
            case .safe, .contractHolds:
                proved += 1
            case .mayTrap, .contractFails:
                diagnostics += failure(function, shortName: shortName, files: files)
            case .undecided:
                diagnostics.append(undecided(function))
            case .unsupported:
                let why = [function.category, function.detail].compactMap { $0 }.joined(separator: ": ")
                diagnostics.append(
                    error(
                        function.location,
                        "\(function.name) is gated but outside what sfverify can prove (\(why.isEmpty ? "unsupported" : why)); remove @Verify or simplify the function"
                    ))
                diagnostics += explanation(function)
            case .internalError:
                diagnostics.append(
                    error(
                        function.location,
                        "\(function.name): the prover failed (\(function.detail ?? "internal error")); the build is stopped rather than trusting it"
                    ))
            }
        }

        for (index, promise) in promises.enumerated() where !matched.contains(index) {
            gated += 1
            diagnostics.append(
                error(
                    SourceLocation(file: promise.file, line: promise.declarationLine, column: 1),
                    "@Verify on \(promise.name) matched no compiled function (generic, never emitted, or in a type sfverify cannot read)"
                ))
        }
        return GateResult(diagnostics: diagnostics, gated: gated, proved: proved)
    }

    // MARK: scanning

    private static func hasMarker(_ line: String) -> Bool {
        guard let comment = line.range(of: "//") else { return false }
        return line[comment.upperBound...].contains(markerToken)
    }

    /// The `func`/`init` a marker at `index` applies to: on the same line, or the next line that is not blank,
    /// a comment, or an attribute.
    static func declaration(startingAt index: Int, in lines: [String]) -> (line: Int, name: String)? {
        if let name = declarationName(in: stripComment(lines[index])) { return (index, name) }
        var next = index + 1
        while next < lines.count {
            let code = stripComment(lines[next]).trimmingCharacters(in: .whitespaces)
            next += 1
            if code.isEmpty || code.hasPrefix("@") && declarationName(in: code) == nil { continue }
            if let name = declarationName(in: code) { return (next - 1, name) }
            return nil
        }
        return nil
    }

    private static func stripComment(_ line: String) -> String {
        guard let comment = line.range(of: "//") else { return line }
        return String(line[..<comment.lowerBound])
    }

    private static func declarationName(in code: String) -> String? {
        if let name = functionName(in: code) { return name }
        let trimmed = code.trimmingCharacters(in: .whitespaces)
        let words = trimmed.split(whereSeparator: { $0 == " " || $0 == "(" || $0 == "<" || $0 == "?" || $0 == "!" })
        return words.contains("init") && trimmed.contains("init") ? "init" : nil
    }

    private static func functionName(in code: String) -> String? {
        guard let range = code.range(of: #"\bfunc\s+([A-Za-z_][A-Za-z0-9_]*)"#, options: .regularExpression) else { return nil }
        return code[range].split(whereSeparator: { $0 == " " || $0 == "\t" }).last.map(String.init)
    }

    /// The error for a contract that is not checked: a hand-written `f_requires` / `f_ensures` next to `function`
    /// (`ignoredContracts`), or `function` itself being a peer `@Verify` wrote that Scan could not pair. Nil otherwise.
    private static func unreadContract(_ function: FunctionReport, shortName: String, files: [String]) -> String? {
        if let message = function.ignoredContractMessage {
            return error(function.location, "\(function.name): contract not read: \(message)")
        }
        guard function.origin != nil, let suffix = ["_requires", "_ensures"].first(where: shortName.hasSuffix),
            shortName.count > suffix.count
        else { return nil }
        let target = String(shortName.dropLast(suffix.count))
        let place = BuildCheck.inSource(function.location) ?? declaration(of: target, in: files)
        return error(place, "\(function.name) checks nothing: no \(target) in the same type takes the parameters it expects")
    }

    static func sameFile(_ a: String, _ b: String) -> Bool {
        URL(fileURLWithPath: a).standardizedFileURL.path == URL(fileURLWithPath: b).standardizedFileURL.path
    }

    /// The error of a gated function that may trap or breaks its contract, with its notes.
    private static func failure(_ function: FunctionReport, shortName: String, files: [String]) -> [String] {
        let verb = function.status == .mayTrap ? "may trap" : "breaks its contract"
        guard let counterexample = function.counterexample else { return [error(function.location, "\(function.name) \(verb)")] }
        // A place in code a macro wrote (the body `@Verify` rewrites) is no file an editor can open: the function's own.
        let place = BuildCheck.inSource(counterexample.at) ?? function.location
        var lines = [
            error(place, "\(function.name) \(verb): \(counterexample.failure) when \(counterexample.inputs.joined(separator: ", "))")
        ]
        if let replay = counterexample.replay { lines.append(note(place, "replay: \(replay)")) }
        return lines + counterexampleNotes(function, counterexample, shortName: shortName, files: files)
    }

    /// Notes that lead from a counterexample to the code involved (K11): the gated declaration with the inputs when the
    /// error sits elsewhere, the `_ensures`/`_requires` function of a broken contract, and a trapping callee that has
    /// no position of its own.
    private static func counterexampleNotes(
        _ function: FunctionReport, _ counterexample: ScanCounterexample, shortName: String, files: [String]
    ) -> [String] {
        var notes: [String] = []
        let inputs = counterexample.inputs.joined(separator: ", ")
        let returns = counterexample.result.map { ", returns \($0)" } ?? ""
        if let at = BuildCheck.inSource(counterexample.at), let declared = function.location, !sameLocation(at, declared) {
            notes.append(note(declared, "\(function.name) is the gated function; inputs: \(inputs)\(returns)"))
        }
        let failure = counterexample.failure
        if failure.contains(shortName + "_ensures") || failure.hasPrefix("ensures is false"),
            let spec = declaration(of: shortName + "_ensures", in: files)
        {
            let call = counterexample.ensuresCall.map { "\($0) is false" } ?? "false for these inputs"
            notes.append(note(spec, "the postcondition \(shortName)_ensures: \(call); inputs: \(inputs)\(returns)"))
        } else if failure.contains(shortName + "_requires"), let spec = declaration(of: shortName + "_requires", in: files) {
            notes.append(note(spec, "the precondition \(shortName)_requires traps; inputs: \(inputs)"))
        }
        if failure.hasPrefix("calls "), let end = failure.range(of: ", which traps") {
            let callee = failure[failure.index(failure.startIndex, offsetBy: 6)..<end.lowerBound]
            let base = callee.split(separator: "(").first.map(String.init) ?? String(callee)
            let name = base.split(separator: ".").last.map(String.init) ?? base
            if let declared = declaration(of: name, in: files) { notes.append(note(declared, "\(callee) is declared here")) }
        }
        return notes
    }

    /// The position of `func <name>` when exactly one declaration in `files` has that name; nil otherwise (an overload
    /// would make the note point at the wrong one).
    private static func declaration(of name: String, in files: [String]) -> SourceLocation? {
        var found: [SourceLocation] = []
        for file in files {
            guard let text = try? String(contentsOfFile: file, encoding: .utf8), text.contains(name) else { continue }
            for (index, line) in text.components(separatedBy: "\n").enumerated() where functionName(in: stripComment(line)) == name {
                let column = (line.range(of: "func ").map { line.distance(from: line.startIndex, to: $0.lowerBound) } ?? 0) + 1
                found.append(SourceLocation(file: file, line: index + 1, column: column))
            }
        }
        return found.count == 1 ? found[0] : nil
    }

    private static func sameLocation(_ a: SourceLocation, _ b: SourceLocation) -> Bool {
        a.line == b.line && sameFile(a.file, b.file)
    }

    /// The error of an undecided gated function: why, and what to change (U7).
    private static func undecided(_ function: FunctionReport) -> String {
        let reason =
            function.category == Verifier.unmodelledCategory
            ? "could not be decided: \(function.detail ?? "it depends on results logic does not model")"
            : "could not be decided within the budget"
        return error(function.location, "\(function.name) \(reason); \(function.hint ?? "raise --budget or simplify it")")
    }

    /// Notes under an unsupported gated function: the construct, the calls that lead there, the fix (U7).
    private static func explanation(_ function: FunctionReport) -> [String] {
        var notes = function.at.map { [note($0, "Scan does not read this")] } ?? []
        notes += (function.calledFrom ?? []).map { note($0, "called from here") }
        if let hint = function.hint { notes.append(note(function.at ?? function.location, "fix: \(hint)")) }
        return notes
    }

    private static func error(_ location: SourceLocation?, _ message: String) -> String {
        CompilerDiagnostic.line(location, .error, message, tag: "[sfverify]", fallback: "sfverify")
    }

    private static func note(_ location: SourceLocation?, _ message: String) -> String {
        CompilerDiagnostic.line(location, .note, message, fallback: "sfverify")
    }
}

public struct GateResult: Sendable {
    public var diagnostics: [String]
    /// Functions the gate asked for: marked `@Verify`, or carrying a contract (read or not).
    public var gated: Int
    public var proved: Int
    public var passed: Bool { diagnostics.allSatisfy { !$0.contains(": error:") } }
}

extension SFVerify {
    /// Runs the build gate over `compile.files`: every `@Verify` function must be proved, and every `// sf:verify`
    /// comment (no longer read) is an error. Fails closed: a compiler error or prover error is a failure. When nothing
    /// is gated the compiler is not started at all, so a target without `@Verify` costs milliseconds.
    public static func gate(_ compile: CompileOptions, _ options: VerifyOptions = VerifyOptions()) -> GateResult {
        let read: (String) -> String? = { try? String(contentsOfFile: $0, encoding: .utf8) }
        let promises = BuildCheck.promises(in: compile.files, read: read).promises
        let contracts = Gate.contractNames(in: compile.files, read: read)
        // A stale marker is an error found without a compiler run (K11): it selects nothing.
        let stale = Gate.staleMarkers(in: compile.files, read: read).map {
            CompilerDiagnostic.line($0, .error, Gate.markerMessage, tag: "[sfverify]", fallback: "sfverify")
        }
        let asked = promises.count + contracts.count
        if promises.isEmpty && contracts.isEmpty { return GateResult(diagnostics: stale, gated: 0, proved: 0) }
        var narrowed = options
        narrowed.only = Array(Set(promises.map(\.name)).union(contracts)).sorted()
        // The gate fails closed on a compiler the reader was not validated against; there is no override (K2).
        let refusal: String?
        do {
            refusal = try ScanToolchain.select(swiftc: compile.compiler).gateRefusal(options.pin)
        } catch {
            refusal = "sfverify: error: [sfverify] could not run the Swift compiler: \(error)"
        }
        if let refusal {
            return GateResult(diagnostics: stale + [refusal], gated: asked, proved: 0)
        }
        do {
            let report = try run(compile, narrowed)
            var result = Gate.check(report, promises: promises, files: compile.files)
            result.diagnostics = stale + result.diagnostics
            return result
        } catch {
            let reason = "\(error)"
            let lines = reason.split(separator: "\n").map { String($0).replacingOccurrences(of: "COMPILER FAILED: ", with: "") }
                .filter { $0.contains(": error:") }
            return GateResult(
                diagnostics: stale + lines + [
                    "sfverify: error: [sfverify] could not compile \(compile.moduleName) to SIL, so nothing could be proved"
                        + (lines.isEmpty ? ": \(reason.prefix(300))" : "")
                ],
                gated: asked, proved: 0
            )
        }
    }
}

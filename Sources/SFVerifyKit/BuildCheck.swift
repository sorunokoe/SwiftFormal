import Foundation

/// A function whose promise the build checks: one marked `@Verify` (a function, a computed property, or the `get`
/// of one). A `// sf:verify` comment is no promise any more: it is reported (`BuildCheck.promises`).
public struct Promise: Sendable, Equatable {
    public enum Kind: Sendable, Equatable {
        /// `@Verify`: a test can still check what logic cannot read, so "not proved by logic" is a warning.
        case verify
    }

    public var file: String
    /// The first line of the declaration, attributes included.
    public var firstLine: Int
    /// The line with `func`.
    public var declarationLine: Int
    public var name: String
    public var kind: Kind
    /// The walk `@Verify` wrote for it (`verify_name()`), which a test can call. `nil` for a `mutating` method, a
    /// computed property or a function with nothing to walk: nothing but logic or the author's own tests checks those.
    public var walk: String?
}

/// What the build checks, and how each verdict is shown in Xcode.
///
/// - Broken: a contract that fails, or a trap, for a concrete input: an error.
/// - Not proved by logic (unsupported, undecided, not found): a warning, since a walk can still check it in the
///   tests. `strict` makes every warning an error.
/// - Not read: a hand-written `f_requires` / `f_ensures`, and a `// sf:verify` comment: an error that says to write the
///   contract in place with `@Verify`.
/// - Proved: nothing is shown.
public enum BuildCheck {
    /// `@Verify` functions in `files`, plus an error for each `// sf:verify` comment, which is no longer read.
    public static func promises(in files: [String]) -> (promises: [Promise], problems: [String]) {
        promises(in: files) { try? String(contentsOfFile: $0, encoding: .utf8) }
    }

    /// The same, with each file's text from `read` (nil: unreadable).
    package static func promises(in files: [String], read: (String) -> String?) -> (promises: [Promise], problems: [String]) {
        let problems = Gate.staleMarkers(in: files, read: read).map { line($0, .error, Gate.markerMessage) }
        var promises: [Promise] = []
        for file in files {
            guard let text = read(file), text.contains("@Verify") else { continue }
            let lines = text.components(separatedBy: "\n")
            for (index, line) in lines.enumerated() where isVerifyAttribute(line) {
                guard let promise = verifyPromise(at: index, in: lines, file: file) else { continue }
                if !promises.contains(where: { $0.file == file && $0.declarationLine == promise.declarationLine }) {
                    promises.append(promise)
                }
            }
        }
        return (promises, problems)
    }

    /// Turns a Scan report into the build's verdict: one diagnostic per promise that is broken or not proved by logic.
    /// Functions without a promise (no `@Verify`, no contract) are left out. A contract is the one Scan
    /// paired with its function (same type, same parameters); a `_requires` / `_ensures` it could not pair checks
    /// nothing, which is an error.
    ///
    /// With `walks` (the `Prove` walks of the test sources), a promise logic did not prove is an error unless a walk is
    /// linked to its function, and a linked one is a note naming the walk: the build then sees the test that checks it.
    /// That the walk runs, and passes, is for the tests.
    public static func evaluate(
        _ report: ScanReport, promises: [Promise], strict: Bool = false, walks: [WalkCheck]? = nil
    ) -> BuildCheckResult {
        var result = BuildCheckResult()
        let linker = WalkLinker(scans: [report])
        var matched: Set<Int> = []
        let ignored = Set(report.functions.flatMap { $0.ignoredContracts ?? [] })
        for function in report.functions {
            let index = promises.firstIndex { covers($0, function) }
            if index == nil, !ignored.contains(function.name), let spec = unpairedSpec(function) {
                result.checked += 1
                result.broken += 1
                result.diagnostics.append(spec)
                continue
            }
            if let message = function.ignoredContractMessage {
                // A contract the author wrote and Scan does not read: never a kept promise (fail closed).
                result.diagnostics.append(line(function.location, .error, "\(function.name): contract not read: \(message)"))
                if index == nil && !function.hasContract {
                    result.checked += 1
                    result.unproved += 1
                    continue
                }
            }
            guard index != nil || function.hasContract else { continue }
            if let index { matched.insert(index) }
            let coverage = WalkCoverage(walks, function: function, linker: linker)
            count(
                function, walk: index.flatMap { promises[$0].walk }, strict: strict || coverage.isMissing, coverage: coverage,
                into: &result)
        }
        for (index, promise) in promises.enumerated() where !matched.contains(index) {
            result.checked += 1
            result.unproved += 1
            let demanding = strict || walks != nil
            let why = "logic found no compiled function for it (generic, never emitted, or in a type it cannot read)"
            let next = walks != nil ? "; no walk can be linked to it" : untested(walk: promise.walk)
            result.diagnostics.append(
                line(
                    SourceLocation(file: promise.file, line: promise.declarationLine, column: 1), demanding ? .error : .warning,
                    "\(promise.name) is not proved: \(why)\(demanding && walks == nil ? "" : next)"))
        }
        return result
    }

    /// Counts a function with a promise as proved, broken or not proved, with its diagnostics.
    private static func count(
        _ function: FunctionReport, walk: String?, strict: Bool, coverage: WalkCoverage, into result: inout BuildCheckResult
    ) {
        result.checked += 1
        switch function.status {
        case .safe, .contractHolds:
            result.proved += 1
            if function.assumptions != nil { result.provedAssuming += 1 }
            result.diagnostics += assumed(function)
        case .mayTrap, .contractFails:
            result.broken += 1
            result.diagnostics += broken(function) + assumed(function)
        case .undecided, .unsupported, .internalError:
            result.unproved += 1
            result.diagnostics.append(unproved(function, demanding: strict, walk: walk, coverage: coverage))
        }
    }

    /// An error at the failing line (or the function, when the failure is in macro-written code), with the input and a replay.
    private static func broken(_ function: FunctionReport) -> [String] {
        let verb = function.status == .mayTrap ? "may trap" : "breaks its promise"
        guard let example = function.counterexample else { return [line(function.location, .error, "\(function.name) \(verb)")] }
        let place = inSource(example.at) ?? function.location
        var lines = [line(place, .error, "\(function.name) \(verb): \(example.failure) when \(example.inputs.joined(separator: ", "))")]
        if let replay = example.replay { lines.append(line(place, .note, "replay: \(replay)")) }
        return lines
    }

    /// What a verdict took on trust about calls with no body (`FunctionReport.assumptions`), as one note.
    private static func assumed(_ function: FunctionReport) -> [String] {
        guard let assumptions = function.assumptions else { return [] }
        return [line(function.location, .note, "\(function.name) assumes: \(assumptions.joined(separator: "; "))")]
    }

    /// What still checks a promise logic could not prove. Only a test that runs: the build cannot see whether one does.
    private static func untested(walk: String?) -> String {
        walk.map { "; only a test can check it now, e.g. #expect(\($0).isProved)" } ?? "; only a test that calls it can check it now"
    }

    private static func unproved(
        _ function: FunctionReport, demanding: Bool, walk: String?, coverage: WalkCoverage = WalkCoverage()
    ) -> String {
        var why: String
        switch function.status {
        case .undecided:
            // The budget only when the budget stopped it: results logic does not model are named, and a larger budget
            // would not help (app study round 6, L8).
            why =
                function.category == Verifier.unmodelledCategory
                ? "logic could not decide it: \(function.detail ?? "it depends on results logic does not model")"
                : "logic could not decide it within the budget"
            if let hint = function.hint { why += " (fix: \(hint))" }
        case .internalError: why = "the prover failed (\(function.detail ?? "internal error"))"
        case .unsupported where function.category == Verifier.contractNotReadCategory:
            // The function may be readable; its contract is what logic cannot read or pair (round 6, L9).
            why = "logic cannot read its contract (\(function.detail ?? "not paired"))"
        default:
            let reason =
                [function.category, function.detail].compactMap { $0 }.joined(separator: ": ")
                + (function.typePath.map { ", at \($0)" } ?? "")
            why = "logic cannot read it yet (\(reason.isEmpty ? "unsupported" : reason))"
        }
        let contract =
            function.hasContract && function.category != Verifier.contractNotReadCategory ? "; its contract is not checked" : ""
        if let leftTo = coverage.description {
            return line(function.location, .note, "\(function.name) is not proved by logic: \(why)\(contract); left to \(leftTo)")
        }
        let next = coverage.isRequired ? "; no walk is linked to it" : demanding ? "" : untested(walk: walk)
        return line(function.location, demanding ? .error : .warning, "\(function.name) is not proved: \(why)\(contract)\(next)")
    }

    /// Names to narrow the scan to; `nil` when there is nothing to check.
    public static func names(of promises: [Promise], contractNames: Set<String>) -> [String]? {
        let names = Set(promises.map(\.name)).union(contractNames)
        return names.isEmpty ? nil : names.sorted()
    }

    /// The promise of the `@Verify` on line `index`: a function, a computed property (`@Verify var body: String {`,
    /// whose getter Scan reports as `….body.getter`), or a `get` (`@Verify get {`, the property on a line above).
    private static func verifyPromise(at index: Int, in lines: [String], file: String) -> Promise? {
        if let property = propertyName(startingAt: index, in: lines) {
            return Promise(
                file: file, firstLine: index + 1, declarationLine: property.line + 1, name: property.name, kind: .verify, walk: nil)
        }
        if afterAttribute(lines[index]).hasPrefix("get") {
            guard let above = (0..<index).reversed().first(where: { propertyName(in: lines[$0]) != nil }),
                let name = propertyName(in: lines[above])
            else { return nil }
            return Promise(file: file, firstLine: above + 1, declarationLine: index + 1, name: name, kind: .verify, walk: nil)
        }
        guard let declaration = Gate.declaration(startingAt: index, in: lines) else { return nil }
        let mutating = lines[declaration.line].range(of: #"\bmutating\b"#, options: .regularExpression) != nil
        let walks = !mutating && hasWalk(attribute: lines[index], declarationLine: declaration.line, in: lines)
        return Promise(
            file: file, firstLine: index + 1, declarationLine: declaration.line + 1, name: declaration.name, kind: .verify,
            walk: walks ? "verify_\(declaration.name)()" : nil)
    }

    /// The computed property declared on line `index` (after the attributes there) or on the next code line.
    private static func propertyName(startingAt index: Int, in lines: [String]) -> (line: Int, name: String)? {
        if let name = propertyName(in: lines[index]) { return (index, name) }
        // A declaration after the attribute on the same line (`@Verify func f() { var y … }`) is not a property.
        if !afterAttribute(lines[index]).trimmingCharacters(in: .whitespaces).isEmpty { return nil }
        var next = index + 1
        while next < lines.count {
            let code = lines[next].trimmingCharacters(in: .whitespaces)
            if code.isEmpty || code.hasPrefix("//") || code.hasPrefix("@") && propertyName(in: code) == nil {
                next += 1
                continue
            }
            return propertyName(in: code).map { (next, $0) }
        }
        return nil
    }

    /// `body` in `@Verify public static var body: String {`: a line that declares a property, after attributes and
    /// modifiers; nil for any other line (a `func` whose body has a `var` too).
    private static func propertyName(in line: String) -> String? {
        let pattern =
            #"^\s*(@\w+(\([^)]*\))?\s+)*((public|package|internal|fileprivate|private|static|class|final|nonisolated|override|open)\s+)*"#
            + #"var\s+[A-Za-z_][A-Za-z0-9_]*"#
        guard let range = line.range(of: pattern, options: .regularExpression) else { return nil }
        return line[range].split(whereSeparator: { $0 == " " || $0 == "\t" }).last.map(String.init)
    }

    /// What follows `@Verify` and its arguments on the line: `get {` in `@Verify(checks: .always) get {`.
    private static func afterAttribute(_ line: String) -> Substring {
        var rest = line.trimmingCharacters(in: .whitespaces).dropFirst("@Verify".count)
        if rest.first == "(" {
            var depth = 0
            while let character = rest.first {
                rest = rest.dropFirst()
                if character == "(" { depth += 1 }
                if character == ")" { depth -= 1 }
                if depth == 0 { break }
            }
        }
        return rest.drop { $0 == " " || $0 == "\t" }
    }

    static func isVerifyAttribute(_ line: String) -> Bool {
        let code = line.trimmingCharacters(in: .whitespaces)
        guard code.hasPrefix("@Verify") else { return false }
        let rest = code.dropFirst("@Verify".count)
        return rest.first.map { $0 == "(" || $0 == " " || $0 == "\t" } ?? true
    }

    /// Code that a macro wrote (`@Verify`'s body) has a location in a buffer the editor cannot open.
    static func inSource(_ location: SourceLocation?) -> SourceLocation? {
        guard let location, !(location.file as NSString).lastPathComponent.hasPrefix("@__swiftmacro") else { return nil }
        return location
    }

    static func covers(_ promise: Promise, _ function: FunctionReport) -> Bool {
        guard let location = function.location, Gate.sameFile(promise.file, location.file) else { return false }
        return (promise.firstLine...max(promise.firstLine, promise.declarationLine)).contains(location.line)
    }

    /// Scan leaves out every `_requires` / `_ensures` it paired, so one in the report belongs to no function.
    private static func unpairedSpec(_ function: FunctionReport) -> String? {
        let base = function.name.firstIndex(of: "(").map { String(function.name[..<$0]) } ?? function.name
        let last = base.split(separator: ".").last.map(String.init) ?? base
        guard let suffix = ["_requires", "_ensures"].first(where: { last.hasSuffix($0) && last.count > $0.count }) else {
            return nil
        }
        let target = String(last.dropLast(suffix.count))
        let shape =
            suffix == "_requires"
            ? "the parameters of \(target)"
            : "the parameters of \(target), then its result if it returns one, then `old: Self` if it is mutating"
        let pairing = "no \(target) in the same type takes the parameters it expects (\(shape))"
        guard function.origin == nil else {
            // A peer `@Verify` wrote, in a shape Scan cannot pair.
            return line(function.location, .error, "\(function.name) checks nothing: \(pairing)")
        }
        return line(
            function.location, .error,
            "\(function.name) checks nothing: it is written by hand, Scan reads only the contract @Verify writes, and "
                + "\(pairing); \(FunctionReport.inPlaceAdvice)")
    }

    private static func line(_ location: SourceLocation?, _ severity: CompilerDiagnostic.Severity, _ message: String) -> String {
        CompilerDiagnostic.line(location, severity, message, tag: "[SwiftFormal]", fallback: "swiftformal")
    }
}

public struct BuildCheckResult: Sendable {
    public var diagnostics: [String] = []
    public var checked = 0
    public var proved = 0
    /// Of `proved`: proofs that rest on assumptions about calls with no body (`FunctionReport.assumptions`).
    public var provedAssuming = 0
    public var broken = 0
    /// Not proved by logic: unsupported, undecided, prover error, or not found.
    public var unproved = 0
    public var passed: Bool { !diagnostics.contains { $0.contains(": error: ") } }
}

// MARK: - Finding targets, and skipping unchanged ones

extension BuildCheck {
    public struct Target: Sendable, Equatable {
        public var name: String
        /// `…/Sources/<name>`.
        public var directory: String
        public var files: [String]

        public init(name: String, directory: String, files: [String]) {
            self.name = name
            self.directory = directory
            self.files = files
        }
    }

    /// SwiftPM targets under `root` (in any package below it) whose sources have a promise to check: `@Verify`,
    /// `// sf:verify`, or a `_requires` / `_ensures` function. A target is found by SwiftPM's default layout,
    /// `Sources/<Target>/`; one with a custom `path:` must be named with `--target`.
    public static func targets(under root: String) -> [Target] {
        let root = URL(fileURLWithPath: root).standardizedFileURL.path
        var byDirectory: [String: Target] = [:]
        let skipped: Set = [".build", ".git", ".swiftpm", "Tests", "DerivedData", "Pods", "Carthage", "node_modules"]
        guard let walker = FileManager.default.enumerator(atPath: root) else { return [] }
        while let relative = walker.nextObject() as? String {
            let parts = relative.split(separator: "/").map(String.init)
            if let last = parts.last, skipped.contains(last) || (last.hasPrefix(".") && !last.hasSuffix(".swift")) {
                walker.skipDescendants()
                continue
            }
            guard relative.hasSuffix(".swift"), let sources = parts.lastIndex(of: "Sources"), sources + 2 < parts.count else {
                continue
            }
            let directory = ([root] + parts[...(sources + 1)]).joined(separator: "/")
            byDirectory[directory, default: Target(name: parts[sources + 1], directory: directory, files: [])]
                .files.append(root + "/" + relative)
        }
        return byDirectory.values.filter { hasPromise($0.files) }.map { target in
            var sorted = target
            sorted.files.sort()
            return sorted
        }.sorted { $0.name < $1.name }
    }

    /// The `Sources/<name>` directory for `name` under `root`, for a target given by name.
    public static func target(named name: String, under root: String) -> Target? {
        let root = URL(fileURLWithPath: root).standardizedFileURL.path
        let direct = root + "/Sources/" + name
        if let files = swiftFiles(in: direct) { return Target(name: name, directory: direct, files: files) }
        guard let walker = FileManager.default.enumerator(atPath: root) else { return nil }
        while let relative = walker.nextObject() as? String {
            let last = (relative as NSString).lastPathComponent
            if [".build", ".git", ".swiftpm", "DerivedData"].contains(last) { walker.skipDescendants(); continue }
            if relative.hasSuffix("Sources/" + name), let files = swiftFiles(in: root + "/" + relative) {
                return Target(name: name, directory: root + "/" + relative, files: files)
            }
        }
        return nil
    }

    static func hasPromise(_ files: [String]) -> Bool {
        files.contains { file in
            guard let text = try? String(contentsOfFile: file, encoding: .utf8) else { return false }
            return text.contains("@Verify") || text.contains(Gate.markerToken) || text.contains("_ensures(")
                || text.contains("_requires(")
        }
    }

    /// Changes when any source file of the target changes (path, size or modification time), or `salt` does.
    public static func fingerprint(of files: [String], salt: String) -> String {
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325
        func mix(_ text: String) {
            for byte in text.utf8 {
                hash ^= UInt64(byte)
                hash = hash &* 0x0000_0100_0000_01b3
            }
        }
        mix(salt)
        for file in files.sorted() {
            let attributes = try? FileManager.default.attributesOfItem(atPath: file)
            let modified = (attributes?[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0
            let size = (attributes?[.size] as? NSNumber)?.intValue ?? -1
            mix("\(file)|\(size)|\(modified)\n")
        }
        return String(hash, radix: 16)
    }

    private static func swiftFiles(in directory: String) -> [String]? {
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: directory, isDirectory: &isDirectory), isDirectory.boolValue,
            let walker = FileManager.default.enumerator(atPath: directory)
        else { return nil }
        return walker.compactMap { $0 as? String }.filter { $0.hasSuffix(".swift") }.map { directory + "/" + $0 }.sorted()
    }
}

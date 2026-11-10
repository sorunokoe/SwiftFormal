import Foundation

/// `swiftformal check`: logic first, then the walks; a proved contract does not stand in for a walk's other promises.
///
/// 1. Scan every target with the SIL prover (all inputs, no code runs).
/// 2. Find the `Prove(…)` walks in the test sources and link each one to the scanned functions its subject names
///    (written first, or read from the `it:` closure).
/// 3. Run the walks with `swift test --filter`: every linked one, except those that cover only functions where logic
///    already found a failing input (listed as not run, with that reason).
/// 4. Merge both into one verdict per function.
public enum Check {
    /// Environment variable that makes each `Prove` append one ``WalkRecord`` JSON line.
    public static let walkLogVariable = "SWIFTFORMAL_WALK_LOG"

    // MARK: linking walks to functions (the keys are in CheckKeys.swift)

    /// Code a macro wrote (`@Observable` accessors, `#Preview`): a walk over the type does not claim to check it.
    public static func isMacroExpansion(_ function: FunctionReport) -> Bool { isMacroExpansion(at: function.location) }

    static func isMacroExpansion(at location: SourceLocation?) -> Bool {
        location.map { URL(fileURLWithPath: $0.file).lastPathComponent.hasPrefix("@__swiftmacro_") } ?? false
    }

    /// Every `Prove(…)` in `files`, with the `@Suite` type and `@Test` function it sits in.
    public static func findWalks(in files: [String]) -> [WalkCheck] {
        var walks: [WalkCheck] = []
        let texts = files.sorted().compactMap { file in (try? String(contentsOfFile: file, encoding: .utf8)).map { (file, $0) } }
        let sources = WalkSources(texts: texts.map(\.1))
        for (file, text) in texts {
            var suite: String?
            var test: String?
            var lastAttributeWasTest = false
            let lines = text.components(separatedBy: "\n")
            for (index, line) in lines.enumerated() {
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                if let name = declaredName(in: trimmed, after: ["struct ", "final class ", "class ", "enum ", "extension "]),
                    !line.hasPrefix(" "), !line.hasPrefix("\t")
                {
                    suite = name
                    test = nil
                }
                if trimmed.hasPrefix("@Test") { lastAttributeWasTest = true }
                if let name = declaredName(in: trimmed, after: ["func "]),
                    line.hasPrefix("    func ") || line.hasPrefix("\tfunc ") || lastAttributeWasTest
                {
                    test = name
                    lastAttributeWasTest = false
                }
                for subject in walkSubjects(in: lines, at: index, sources: sources) {
                    walks.append(WalkCheck(subject: subject, file: file, line: index + 1, suite: suite, test: test))
                }
            }
        }
        return walks
    }

    private static func declaredName(in line: String, after keywords: [String]) -> String? {
        var line = droppingAttributes(Substring(line))
        for modifier in ["public ", "internal ", "private ", "fileprivate ", "static ", "nonisolated ", "mutating "] {
            while line.hasPrefix(modifier) { line = line.dropFirst(modifier.count) }
        }
        for keyword in keywords where line.hasPrefix(keyword) {
            let name = line.dropFirst(keyword.count).prefix { $0.isLetter || $0.isNumber || $0 == "_" }
            return name.isEmpty ? nil : String(name)
        }
        return nil
    }

    /// `@Test`, `@Test("name")`, `@Suite(.serialized)`, `@MainActor`: attributes written on the declaration's line.
    private static func droppingAttributes(_ line: Substring) -> Substring {
        var line = line
        while line.first == "@" {
            var rest = line.dropFirst().drop { $0.isLetter || $0.isNumber || $0 == "_" || $0 == "." }
            if rest.first == "(" {
                var depth = 0
                var inString = false
                guard
                    let close = rest.firstIndex(where: { character in
                        if character == "\"" { inString.toggle() }
                        guard !inString else { return false }
                        if character == "(" { depth += 1 }
                        if character == ")" { depth -= 1 }
                        return depth == 0
                    })
                else { return line }
                rest = rest[rest.index(after: close)...]
            }
            line = rest.drop { $0 == " " || $0 == "\t" }
        }
        return line
    }

    // MARK: deciding what to run

    /// Which walks must run: every linked one. A contract that holds says nothing about another promise a walk states
    /// (a table, injectivity), so it does not stand in for the walk. Only a walk that covers nothing but functions where
    /// logic already found a failing input is skipped (`skippedByLogic`, listed as not run). A walk linked only to
    /// functions a selector left out (`ScanReport.unselected`) does not run and is not unlinked.
    public static func plan(scans: [ScanReport], walks: [WalkCheck]) -> CheckPlan {
        let linker = WalkLinker(scans: scans)
        var needed: Set<Int> = []
        var skippedByLogic: Set<Int> = []
        var linked: Set<Int> = []
        for scan in scans {
            for function in scan.functions where !isMacroExpansion(function) {
                let key = functionKey(function.name)
                for (index, walk) in walks.enumerated()
                where linker.mayCover(walk, functionName: function.name, key: key) {
                    linked.insert(index)
                    switch function.status {
                    case .contractFails: skippedByLogic.insert(index)
                    case .contractHolds, .mayTrap, .safe, .unsupported, .undecided, .internalError: needed.insert(index)
                    }
                }
            }
        }
        var notSelected: Set<Int> = []
        for scan in scans {
            for function in scan.unselected where !isMacroExpansion(at: function.location) {
                let key = functionKey(function.name)
                for (index, walk) in walks.enumerated() where linker.mayCover(walk, functionName: function.name, key: key) {
                    notSelected.insert(index)
                }
            }
        }
        return CheckPlan(
            walks: walks, run: needed.sorted(), skippedByLogic: skippedByLogic.subtracting(needed).sorted(),
            unlinked: Set(walks.indices).subtracting(linked).subtracting(notSelected).sorted(),
            notSelected: notSelected.subtracting(linked).sorted()
        )
    }

    // MARK: merging

    /// One verdict per scanned function: its logic result combined with the records of the walks that cover it.
    /// `knownIssues` are walk places (`File.swift:line`) whose failure the test marks as known; `packages` (one per scan).
    public static func merge(
        scans: [ScanReport], plan: CheckPlan, records: [WalkRecord], knownIssues: Set<String>, packages: [String]? = nil
    ) -> CheckReport {
        func walkKey(_ file: String, _ line: Int) -> String { "\(URL(fileURLWithPath: file).lastPathComponent):\(line)" }
        var byWalk: [String: [WalkRecord]] = [:]
        for record in records { byWalk[walkKey(record.file, record.line), default: []].append(record) }
        // `$0.member` becomes `Type.member` with the input type the walk reported. One that did not report covers every
        // function it may cover, so it shows as missing; one whose type names no scanned function is unlinked.
        var ran: [WalkCheck] = []
        var unlinked = plan.unlinked.map { plan.walks[$0] }
        let linker = WalkLinker(scans: scans)
        let names = scans.flatMap { $0.inventory.map(\.name) }
        for var walk in plan.run.map({ plan.walks[$0] }) {
            if inputMember(walk.subject) != nil, let type = byWalk[walkKey(walk.file, walk.line)]?.first?.inputType {
                walk.subject = typeKey(reflecting: type) + "." + walk.subject.dropFirst(3)
                guard linker.linksToAny(subject: walk.subject, among: names) else {
                    unlinked.append(walk)
                    continue
                }
            }
            ran.append(walk)
        }

        var entries: [CheckEntry] = []
        for (scan, package) in zip(scans, scans.indices.map { packages?.dropFirst($0).first }) {
            for function in scan.functions {
                let key = functionKey(function.name)
                let walks = isMacroExpansion(function) ? [] : ran.filter { linker.mayCover($0, functionName: function.name, key: key) }
                var results: [CheckEntry.WalkResult] = []
                for walk in walks {
                    let key = walkKey(walk.file, walk.line)
                    let found = byWalk[key] ?? []
                    // A subject that names only the type covers this member without naming it (app study round 6, L18). A
                    // `$0.member` walk whose input type is not known names a member, so it is not a walk over a type.
                    let namesMember = inputMember(walk.subject) != nil || subjectKey(walk.subject) == functionKey(function.name)
                    let wholeType = namesMember ? nil : true
                    results.append(.init(walk: walk, records: found, knownIssue: knownIssues.contains(key), wholeType: wholeType))
                }
                entries.append(CheckEntry(module: scan.module, package: package, function: function, walks: results))
            }
        }
        return CheckReport(
            entries: entries, unlinkedWalks: unlinked,
            notRunWalks: plan.skippedByLogic.map { plan.walks[$0].withKind(.logicFoundFailure) },
            ranWalks: ran.count,
            totalWalks: plan.walks.count,
            modules: scans.indices.map { CheckReport.Module(scans[$0], package: packages?.dropFirst($0).first) })
    }

    /// `file:line` of every `Prove` whose issue a test marked with `withKnownIssue`, from Swift Testing's console output.
    public static func knownIssues(inTestOutput output: String) -> Set<String> {
        var found: Set<String> = []
        for line in output.components(separatedBy: "\n") {
            guard let range = line.range(of: "recorded a known issue at ") else { continue }
            let place = line[range.upperBound...].split(separator: ":")
            guard place.count >= 2, let number = Int(place[1]) else { continue }
            found.insert("\(place[0]):\(number)")
        }
        return found
    }

    /// The records each `Prove` appended to `path` (one JSON object per line); unreadable lines are skipped.
    public static func readWalkLog(_ path: String) -> [WalkRecord] {
        guard let text = try? String(contentsOfFile: path, encoding: .utf8) else { return [] }
        let decoder = JSONDecoder()
        return text.split(separator: "\n").compactMap { try? decoder.decode(WalkRecord.self, from: Data($0.utf8)) }
    }

    /// `swift build --build-tests` in `package`, started before the scan so that the two overlap. `runWalks` then
    /// runs the tests without building them again. The build writes to `log`.
    public final class TestBuild {
        private let build: Spawn.Background
        private let handle: FileHandle

        fileprivate init(build: Spawn.Background, handle: FileHandle) {
            self.build = build
            self.handle = handle
        }

        /// Stops the build, for a run that needs no walk.
        public func cancel() {
            build.stop()
            try? handle.close()
        }

        fileprivate func succeeded() -> Bool {
            let status = build.wait()
            try? handle.close()
            return status == 0
        }
    }

    /// Starts `swift build --build-tests` in `package`, writing its output to `log`, and returns at once.
    public static func startTestBuild(package: String, log: String) throws -> TestBuild {
        FileManager.default.createFile(atPath: log, contents: nil)
        let handle = try FileHandle(forWritingTo: URL(fileURLWithPath: log))
        let swift = try ScanToolchain.swiftCommand(["build", "--build-tests", "--package-path", package])
        let build = try Spawn.start(swift.executable, swift.arguments, log: handle)
        return TestBuild(build: build, handle: handle)
    }

    /// `swift test` for only `walks`, with the walk log switched on. Returns the console output. With `built`, a test
    /// build that succeeded, or with `skipBuild` (the tests were built already), the tests are not built again; when the
    /// build failed, `swift test` builds them and shows why.
    public static func runWalks(
        _ walks: [WalkCheck], package: String, log: String, built: TestBuild? = nil, skipBuild alreadyBuilt: Bool = false
    ) throws -> (output: String, exitCode: Int32) {
        var filters: [String] = []
        for walk in walks {
            guard let test = walk.test else { continue }
            let pattern = (walk.suite.map { "\($0)/" } ?? "") + NSRegularExpression.escapedPattern(for: test + "(")
            if !filters.contains(pattern) { filters.append(pattern) }
        }
        guard !filters.isEmpty else { return ("", 0) }
        try? FileManager.default.removeItem(atPath: log)
        // The event stream and the attachments of an earlier run must not be read as this run's.
        try? FileManager.default.removeItem(atPath: eventStreamPath(log: log))
        try? FileManager.default.removeItem(atPath: attachmentsPath(log: log))
        let version = (try? ScanToolchain.current()).flatMap { eventStreamVersion(compilerVersion: $0.versionLine) }
        if version != nil { try FileManager.default.createDirectory(atPath: attachmentsPath(log: log), withIntermediateDirectories: true) }
        let outputPath = log + ".out"
        FileManager.default.createFile(atPath: outputPath, contents: nil)
        let handle = try FileHandle(forWritingTo: URL(fileURLWithPath: outputPath))
        var environment = ProcessInfo.processInfo.environment
        // The tests run in another working directory: a relative path would send the records somewhere else.
        // The side file stays on: it is what `walkResults` reads when there is no event stream.
        let absolute = URL(fileURLWithPath: log).standardizedFileURL.path
        environment[walkLogVariable] = absolute
        environment[walkEventsVariable] = "1"
        let skipBuild = alreadyBuilt || built?.succeeded() == true ? ["--skip-build"] : []
        let swift = try ScanToolchain.swiftCommand(
            ["test", "--package-path", package] + skipBuild + eventStreamArguments(log: absolute, version: version)
                + filters.flatMap { ["--filter", $0] })
        let result = try Spawn.run(swift.executable, swift.arguments, environment: environment, log: handle)
        try? handle.close()
        let output = (try? String(contentsOfFile: outputPath, encoding: .utf8)) ?? ""
        return (output, result.status)
    }
}

/// One `Prove(…)` found in a test file.
public struct WalkCheck: Codable, Sendable, Equatable {
    public var subject: String
    public var file: String
    public var line: Int
    /// The type the test is declared in (the `@Suite`), when there is one.
    public var suite: String?
    /// The `@Test` function the call is in.
    public var test: String?
    /// For a walk `check` sees but does not run: why (absent for a walk it runs).
    public var kind: Kind?

    /// Walks `check` finds but does not run, each listed with the reason.
    public enum Kind: String, Codable, Sendable {
        /// Covers only functions where logic already found a failing input: `check` skips it (set by `merge`).
        case logicFoundFailure
    }

    public init(subject: String, file: String, line: Int, suite: String?, test: String?, kind: Kind? = nil) {
        self.subject = subject
        self.file = file
        self.line = line
        self.suite = suite
        self.test = test
        self.kind = kind
    }

    /// Why `check` does not run it; nil for a walk it runs.
    var notRunReason: String? {
        switch kind {
        case .logicFoundFailure:
            "logic already found a failing input in every function it covers, so check did not run it; its own promises are not checked"
        case nil: nil
        }
    }

    func withKind(_ kind: Kind) -> WalkCheck {
        var walk = self
        walk.kind = kind
        return walk
    }

    var place: String { "\(URL(fileURLWithPath: file).lastPathComponent):\(line)" }
}

public struct CheckPlan: Sendable {
    public var walks: [WalkCheck]
    /// Indices into `walks` that must run: every linked walk but those in `skippedByLogic`.
    public var run: [Int]
    /// Linked only to functions where logic already found a failing input; `merge` lists them as not run.
    public var skippedByLogic: [Int]
    /// Their subject names no scanned function.
    public var unlinked: [Int]
    /// Linked only to functions a selector left out: neither run nor unlinked.
    public var notSelected: [Int] = []
}

/// One `Prove` result, as written by SwiftFormalTesting when `SWIFTFORMAL_WALK_LOG` is set.
public struct WalkRecord: Codable, Sendable {
    public struct Property: Codable, Sendable {
        public var name: String
        /// `proved`, `bounded` or `failed`.
        public var verdict: String
        public var checked: Int?
        public var input: String?
        public var detail: String?
        /// Set by `check` when logic decided the property for every input (`Check.applyingRelational`): `proved` or `refuted`.
        public var logic: String?
    }
    public var subject: String
    /// `proved`, `bounded` or `failed`.
    public var verdict: String
    public var evaluated: Int
    public var domainSize: Int
    public var domainComplete: Bool
    public var properties: [Property]
    public var file: String
    public var line: Int
    public var test: String?
    /// The type `$0` stands for in the walk's `it:` closure, as Swift prints it (`AppFeature.Surface`): the input, or the
    /// state of a session walk.
    public var inputType: String?
}

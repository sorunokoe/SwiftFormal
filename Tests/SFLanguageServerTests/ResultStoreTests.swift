import Foundation
import SFLanguageServer
import SFVerifyKit
import Testing

/// Generations and staleness: a verdict is shown as proved only when nothing it depends on changed since its check
/// started, and only for the text it was proved about.
@Suite struct ResultStoreTests {
    @Test func anEditTurnsEveryResultItMayAffectStale() throws {
        let package = try FixturePackage()
        defer { package.remove() }
        let store = ResultStore()
        #expect(store.publish(try finishedRun(package, generation: store.generation)) == 3)
        let hash = InputSnapshot.digest(Data(FixturePackage.libText.utf8))
        #expect(store.all.allSatisfy { $0.isCurrent(currentHash: hash) })

        #expect(store.change(.packages(["/elsewhere"])) == 0)
        #expect(store.all.allSatisfy { $0.isCurrent(currentHash: hash) })
        #expect(store.change(.packages([package.root])) == 3)
        #expect(store.all.allSatisfy { !$0.isCurrent(currentHash: hash) })
        #expect(store.all.allSatisfy { Render.lensTitle($0, current: $0.isCurrent(currentHash: hash)).hasPrefix("⚠ stale") })
        // Stale stays stale, even if the text is changed back: only a new check clears it.
        #expect(store.change(.everything) == 0)
    }

    @Test func aRunThatStartedBeforeAnEditIsStoredStale() throws {
        let package = try FixturePackage()
        defer { package.remove() }
        let store = ResultStore()
        let started = store.generation
        store.change(.packages([package.root]))
        #expect(store.publish(try finishedRun(package, generation: started)) == 0)
        #expect(store.all.count == 3 && store.all.allSatisfy(\.stale))
        // A run that started after the edit is current.
        #expect(store.publish(try finishedRun(package, generation: store.generation)) == 3)
        store.pruneEvents(upTo: store.generation)
        #expect(store.publish(try finishedRun(package, generation: started)) == 3)
    }

    @Test func aChangeElsewhereDoesNotStaleARun() throws {
        let package = try FixturePackage()
        defer { package.remove() }
        let store = ResultStore()
        let started = store.generation
        store.change(.packages(["/other"]))
        #expect(store.publish(try finishedRun(package, generation: started)) == 3)
    }

    @Test func unknownDependenciesAreAffectedByAnyChange() throws {
        let package = try FixturePackage()
        defer { package.remove() }
        let store = ResultStore()
        var run = try finishedRun(package, generation: store.generation)
        run.closures = [package.root: nil]
        store.publish(run)
        #expect(store.change(.packages(["/other"])) == 3)
    }

    @Test func aResultIsCurrentOnlyForTheTextItWasProvedAbout() throws {
        let package = try FixturePackage()
        defer { package.remove() }
        let store = ResultStore()
        store.publish(try finishedRun(package, generation: store.generation))
        let half = try #require(store.all.first { $0.entry.function == "half(_:)" })
        #expect(half.isCurrent(currentHash: InputSnapshot.digest(Data(FixturePackage.libText.utf8))))
        #expect(!half.isCurrent(currentHash: InputSnapshot.digest(Data((FixturePackage.libText + " ").utf8))))
        #expect(!half.isCurrent(currentHash: nil))
        #expect(Render.lensTitle(half, current: false).hasPrefix("⚠ stale"))
    }

    @Test func aResultWithoutAHashedFileIsNeverCurrent() throws {
        let package = try FixturePackage()
        defer { package.remove() }
        let store = ResultStore()
        let generated = package.root + "/.build/DerivedSources/x.swift"
        let json = try #require(String(bytes: checkJSON(file: package.source), encoding: .utf8)).replacingOccurrences(
            of: package.source, with: generated)
        store.publish(try finishedRun(package, generation: 0, json: Data(json.utf8)))
        #expect(store.all.allSatisfy { $0.fileHash == nil && !$0.isCurrent(currentHash: nil) })
    }

    @Test func walkVerdictsAlsoDependOnTheTestsPackage() throws {
        let package = try FixturePackage()
        defer { package.remove() }
        let store = ResultStore()
        let tests = TargetRef(package: "/tests", target: "FormalTests")
        var run = try finishedRun(package, generation: 0, job: CheckJob(scans: [package.target], tests: tests, walks: true))
        run.closures["/tests"] = ["/tests", package.root]
        store.publish(run)
        // `add` has a logic counterexample (final without walks); `half` (safe) and `pick` (undecided) wait for walks.
        #expect(store.change(.packages(["/tests"])) == 2)
        #expect(store.all.filter(\.stale).map(\.entry.function).sorted() == ["half(_:)", "pick(_:)"])
    }

    @Test func aProofTheFactsDoNotSupportIsUnchecked() throws {
        let file = "/w/Sources/Lib/Lib.swift"
        let json = try #require(String(bytes: checkJSON(file: file), encoding: .utf8))
            .replacingOccurrences(
                of: #""logic": "undecided", "outcome": "unchecked""#, with: #""logic": "undecided", "outcome": "cannotTrap""#)
        let results = try CheckResults.read(Data(json.utf8))
        let pick = try #require(results.entries.first { $0.function == "pick(_:)" })
        #expect(pick.outcome == .cannotTrap)
        #expect(pick.checkedOutcome == .unchecked)
    }

    /// Two packages that both have a target named `Lib`, checked in one run: each verdict belongs to its own package
    /// only, so an edit in B stales B's verdicts and never leaves a copy of them under A showing ✓.
    @Test(arguments: [true, false])
    func twoTargetsWithTheSameNameKeepTheirOwnVerdicts(reportNamesPackages: Bool) throws {
        let a = try FixturePackage()
        let b = try FixturePackage()
        defer { a.remove(); b.remove() }
        let store = ResultStore()
        var run = try finishedRun(
            a, generation: 0, job: CheckJob(scans: [a.target, b.target], walks: false),
            json: try twoPackagesJSON(a, b, namePackages: reportNamesPackages))
        run.closures = [a.root: [a.root], b.root: [b.root]]
        run.snapshot = InputSnapshot.capture(roots: [a.root, b.root], context: [:], hash: true)
        if !reportNamesPackages {
            run.sourceDirectories = [a.target: a.root + "/Sources/Lib", b.target: b.root + "/Sources/Lib"]
        }
        #expect(store.publish(run) == 6)
        #expect(store.results[a.target]?.map(\.file) == Array(repeating: a.source, count: 3))
        #expect(store.results[b.target]?.map(\.file) == Array(repeating: b.source, count: 3))
        #expect(store.results[a.target]?.first?.module?.configurations == ["debug"])
        #expect(store.results[b.target]?.first?.module?.configurations == ["debug", "release"])
        #expect(Set(store.all.map(\.id)).count == 6)

        #expect(store.change(.packages([b.root])) == 3)
        let hash = InputSnapshot.digest(Data(FixturePackage.libText.utf8))
        #expect(store.results(inFile: b.source).allSatisfy { !$0.isCurrent(currentHash: hash) })
        #expect(store.results(inFile: a.source).allSatisfy { $0.isCurrent(currentHash: hash) })
    }

    /// A report without package names, from two targets named alike, whose folders are not known: nothing can be
    /// attributed, so nothing is shown (never a verdict under the wrong package).
    @Test func verdictsThatCannotBeAttributedAreDropped() throws {
        let a = try FixturePackage()
        let b = try FixturePackage()
        defer { a.remove(); b.remove() }
        let store = ResultStore()
        let run = try finishedRun(
            a, generation: 0, job: CheckJob(scans: [a.target, b.target], walks: false), json: try twoPackagesJSON(a, b, namePackages: false)
        )
        #expect(store.publish(run) == 0)
        #expect(store.all.isEmpty)
    }

    @Test func anUnknownVerdictFailsTheRead() throws {
        let json = try #require(String(bytes: checkJSON(file: "/w/a.swift"), encoding: .utf8))
            .replacingOccurrences(of: #""outcome": "cannotTrap""#, with: #""outcome": "provedSomehow""#)
        #expect(throws: (any Error).self) { try CheckResults.read(Data(json.utf8)) }
        #expect(throws: (any Error).self) { try CheckResults.read(Data(#"{"schemaVersion": 2, "entries": []}"#.utf8)) }
    }
}

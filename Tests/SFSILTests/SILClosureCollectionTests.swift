import Foundation
import Testing
import SFProve
import SFSIL

/// The closure-taking calls of `Array` with a closure literal (`SILClosureCollections.swift`), in real `swiftc -Onone`
/// output: over a literal the closure runs on each element, exactly; over an array of unknown length only a scan's
/// `CollectionBounds` reads the call, and only a length the code fixes gives a proof.
enum ClosureCollectionFixture {
    static let source = """
        public func mapped(_ k: Int8) -> Int8 {
            guard k >= 0 && k <= 2 else { return 0 }
            let a = [Int8(1), 2, 3].map { $0 * 2 + k }
            precondition(a.count == 3 && !a.isEmpty && a[0] == 2 + k && a[2] == 6 + k)
            return a[1]
        }
        public func mappedWrong(_ k: Int8) -> Int8 {
            guard k >= 0 && k <= 2 else { return 0 }
            let a = [Int8(1), 2, 3].map { $0 * 2 + k }
            precondition(a[1] == 4)
            return a[1]
        }
        public func filtered(_ x: Int8) -> Int { let n = [Int8(1), 5, 3, 7].filter { $0 > 2 }.count; precondition(n == 3); return n }
        public func filteredWrong(_ x: Int8) -> Int { let n = [Int8(1), 5, 3, 7].filter { $0 > 2 }.count; precondition(n == 2); return n }
        public func compacted(_ x: Int8) -> Int { let n = [Int8(1), nil, 3].compactMap { $0 }.count; precondition(n == 2); return n }
        public func compactedWrong(_ x: Int8) -> Int { let n = [Int8(1), nil, 3].compactMap { $0 }.count; precondition(n == 3); return n }
        public func found(_ x: Int8) -> Int8 { let f = [Int8(1), 5, 3, 7].first(where: { $0 > 4 }); precondition(f == 5); return f ?? 0 }
        public func foundWrong(_ x: Int8) -> Int8 { let f = [Int8(1), 5, 3, 7].first(where: { $0 > 4 }); precondition(f == 7); return f ?? 0 }
        public func notFound(_ x: Int8) -> Int8 { let f = [Int8(1), 5].first(where: { $0 > 9 }); precondition(f == nil); return 0 }
        public func stopsAtTheFirst(_ x: Int8) -> Bool { [Int8(1), 0].first(where: { 10 / $0 > 3 }) != nil }
        public func runsOnEach(_ x: Int8) -> [Int8] { [Int8(1), 0, 2].map { 10 / $0 } }
        public func contained(_ x: Int8) -> Bool { let b = [Int8(1), 5].contains(where: { $0 == x }); precondition(b == (x == 1 || x == 5)); return b }
        public func containedWrong(_ x: Int8) -> Bool { let b = [Int8(1), 5].contains(where: { $0 == x }); precondition(b == (x == 1)); return b }
        public func all(_ x: Int8) -> Bool { let b = [Int8(1), 5].allSatisfy { $0 < x }; precondition(b == (x > 5)); return b }
        public func allWrong(_ x: Int8) -> Bool { let b = [Int8(1), 5].allSatisfy { $0 < x }; precondition(b == (x > 1)); return b }
        public func counted(_ x: Int8) -> Int { let n = [Int8(1), 5, 3].count(where: { $0 >= 3 }); precondition(n == 2); return n }
        public func countedWrong(_ x: Int8) -> Int { let n = [Int8(1), 5, 3].count(where: { $0 > 3 }); precondition(n == 2); return n }
        public func byFunction(_ x: Int8) -> Int8 { [Int8(1), 2].map(half)[1] + 126 }
        public func half(_ v: Int8) -> Int8 { v / 2 }

        public func unknown(_ a: [Int8]) -> Int { a.filter { $0 > 0 }.count }
        public func unknownTraps(_ a: [Int8]) -> [Int8] { a.map { $0 + 1 } }
        public func fixed(_ a: [Int8]) -> Int { guard a.count == 2 else { return 0 }; return a.filter { $0 > 0 }.count }
        """
    static let module = try! SILCompiler.module(source: source, name: "Cl", optimization: .none)

    static func verdict(_ name: String, _ bounds: CollectionBounds? = nil) throws -> ProofVerdict {
        try CollectionBounds.$current.withValue(bounds) {
            try SILVerifier.proveAggregate(try module.symbol(module: "Cl", name: name), in: module)
        }
    }
}

@Suite(.tags(.slow)) struct SILClosureCollectionTests {
    @Test func overALiteralTheClosureRunsOnEachElement() throws {
        for name in ["mapped", "filtered", "compacted", "found", "notFound", "stopsAtTheFirst", "contained", "all", "counted"] {
            #expect(try ClosureCollectionFixture.verdict(name) == .proved, "\(name)")
        }
        for name in [
            "mappedWrong", "filteredWrong", "compactedWrong", "foundWrong", "runsOnEach", "containedWrong", "allWrong",
            "countedWrong",
        ] {
            guard case .counterexample = try ClosureCollectionFixture.verdict(name) else {
                Issue.record("\(name) traps")
                continue
            }
        }
    }

    @Test func aFunctionPassedAsTheClosureRuns() throws {
        // `map(half)` passes a reabstraction thunk that captures `half`: 2 / 2 + 126 = 127.
        #expect(try ClosureCollectionFixture.verdict("byFunction") == .proved)
    }

    @Test func anArrayOfUnknownLengthIsNeverProvedForEveryLength() throws {
        for name in ["unknown", "unknownTraps"] {
            #expect(throws: SILError.self, "\(name)") { try ClosureCollectionFixture.verdict(name) }
            // Longer than the bound may fail, on a choice no counterexample can rest on.
            let exact = CollectionBounds(.exact)
            #expect(try ClosureCollectionFixture.verdict(name, exact) == .unknown, "\(name)")
            #expect(exact.notes.count == 1, "\(exact.notes)")
        }
        let bounded = CollectionBounds(.bounded)
        #expect(try ClosureCollectionFixture.verdict("unknown", bounded) == .proved)
        #expect(bounded.notes.first?.contains("n ≤ 8") == true, "\(bounded.notes)")
        // 127 + 1 overflows within the bound; on fresh elements the counterexample is not replayed, so not proved.
        #expect(try ClosureCollectionFixture.verdict("unknownTraps", CollectionBounds(.bounded)) != .proved)
    }

    @Test func aLengthTheCodeFixesIsProvedExactly() throws {
        #expect(try ClosureCollectionFixture.verdict("fixed", CollectionBounds(.exact)) == .proved)
    }
}

import Foundation
import Testing

@testable import SFVerifyKit

/// The walks' relational claims read from test sources, and logic's results laid over the walks' records
/// (`RelationalWalks.swift`).
@Suite struct RelationalWalkTests {
    typealias Step = RelationalStep

    static func requests(_ text: String) -> [RelationalRequest] {
        Check.relationalRequests(files: ["/t/Walks.swift"], texts: [text])
    }

    @Test func readsTheClaimsOfAWalk() {
        let text = """
            @Test func seats() {
                Prove("SeatRule.body", it: { SeatRule(input: $0).execute() }, over: .samples(seats)) {
                    Injective()
                    RoundTrip(through: { SeatBack(input: $0)
                        .execute() })
                    Agrees("same as the table", with: { tableSeat($0) })
                    Matches { Seats.code(of: $0) }
                    Holds("not empty") { _, code in !code.isEmpty }
                }
            }
            """
        let found = Self.requests(text)
        let rule = [
            Step(.initializer, type: "SeatRule", name: "init", labels: ["input"]), Step(.method, type: "SeatRule", name: "execute"),
        ]
        #expect(found.map(\.property) == ["injective", "round trip", "same as the table", "matches oracle"])
        #expect(found.allSatisfy { $0.forward == rule && $0.line == 2 && $0.file == "/t/Walks.swift" })
        #expect(found[0].claim == .injective && found[0].other.isEmpty)
        #expect(found[1].claim == .roundTrip)
        #expect(
            found[1].other == [
                Step(.initializer, type: "SeatBack", name: "init", labels: ["input"]), Step(.method, type: "SeatBack", name: "execute"),
            ])
        #expect(found[2].claim == .agrees && found[2].other == [Step(.function, name: "tableSeat", labels: ["_"])])
        #expect(found[3].claim == .agrees && found[3].other == [Step(.function, type: "Seats", name: "code", labels: ["of"])])
    }

    @Test func readsKeyPathsNamedParametersAndAnUnwrappedInverse() {
        let text = """
            Prove("code", it: { (card: Card) in cardCode(card) }, over: cards) {
                RoundTrip { try cardFromCode($0)! }
            }
            Prove(it: \\.code.value, over: .samples(seats)) { Injective() }
            """
        let found = Self.requests(text)
        #expect(found.count == 2)
        #expect(found[0].forward == [Step(.function, name: "cardCode", labels: ["_"])])
        #expect(found[0].other == [Step(.function, name: "cardFromCode", labels: ["_"])] && found[0].unwrapsOther)
        #expect(found[1].forward == [Step(.getter, name: "code"), Step(.getter, name: "value")] && found[1].line == 4)
    }

    /// Anything that is not one chain on the walk's input is not read: the walk's verdict stands.
    @Test func leavesOtherClosuresToTheWalk() {
        let walks = [
            "Prove(it: { SeatRule(input: $0, table: table).execute() }) { Injective() }",
            "Prove(it: { rule.execute($0) }) { Injective() }",
            "Prove(it: { $0.code + suffix }) { Injective() }",
            "Prove(it: { code(\"\\($0)\") }) { Injective() }",
            "Prove(it: { let x = $0; return f(x) }) { Injective() }",
            "Prove(it: { f($0) }) { Agrees(with: { g($0) }, where: { $0 == $1 }) }",
            "Prove(it: { f($0) }) { RoundTrip(through: { g($0, 1) }) }",
            "Prove(it: { f($0)! }) { Injective() }",
            "Prove(it: { f($0) }) { Agrees(with: { g($0)! }) }",
            "Prove(it: { f($0) }) { Injective(except: [(a, b)]) }",
            "// Prove(it: { f($0) }) { Injective() }",
            "MyProve(it: { f($0) }) { Injective() }",
        ]
        for walk in walks { #expect(Self.requests(walk).isEmpty, "\(walk)") }
        #expect(Self.requests("Prove(it: { f($0) }) { Injective() }").count == 1)
    }

    /// A test may declare the `==` the walk compares with, or a function or type of the same name as the app's: the
    /// walk calls that one.
    @Test func leavesWalksAloneWhenTheTestsDeclareWhatTheyCall() {
        let walk = "Prove(it: { Seats.code(of: $0) }) { RoundTrip(through: { seat(code: $0) }) }"
        #expect(Self.requests(walk).count == 1)
        for declaration in [
            "static func == (a: Seat, b: Seat) -> Bool { true }", "func seat(code: Int) -> Seat { .init() }",
            "extension Seats { }", "enum Seats { }",
        ] {
            #expect(Check.relationalRequests(files: ["/t/A.swift", "/t/B.swift"], texts: [walk, declaration]).isEmpty, "\(declaration)")
        }
    }

    @Test func followsAMethodThatOnlyReturnsBody() {
        let text = """
            import Testing
            @testable import App
            func walk() { Prove(it: { SeatRule(input: $0).execute() }) { Injective() } }
            """
        let rule = """
            public protocol Rule { associatedtype Output; var body: Output { get } }
            public extension Rule { func execute() -> Output { body } }
            public struct SeatRule: Rule { public let input: Int; public var body: Int { input } }
            """
        let app = Check.SourceTarget(package: "/p", name: "App", files: ["/p/App/Rule.swift"])
        let requests = Self.requests(text)
        let resolved = Check.resolvingForwarders(requests, testTexts: [text], scanned: ["App"], targets: [app]) {
            $0 == "/p/App/Rule.swift" ? rule : nil
        }
        #expect(resolved.first?.forward.last == Step(.getter, type: "SeatRule", name: "body"))
    }

    // MARK: overlay

    /// A walk property: its name, verdict and detail.
    struct Row {
        let name: String, verdict: String, detail: String?
        init(_ name: String, _ verdict: String, _ detail: String?) { (self.name, self.verdict, self.detail) = (name, verdict, detail) }
    }

    static func record(
        complete: Bool = false, properties: [Row], inputType: String = "M.Seat", file: String = "/x/t/Walks.swift", line: Int = 2
    ) throws -> WalkRecord {
        let list = properties.map { p in
            "{\"name\": \"\(p.name)\", \"verdict\": \"\(p.verdict)\"" + (p.detail.map { ", \"detail\": \"\($0)\"" } ?? "") + "}"
        }
        let overall =
            properties.contains { $0.verdict == "failed" }
            ? "failed" : properties.allSatisfy { $0.verdict == "proved" } ? "proved" : "bounded"
        let json = """
            {"subject": "seat", "verdict": "\(overall)", "evaluated": 8, "domainSize": 8, "domainComplete": \(complete),
             "properties": [\(list.joined(separator: ", "))], "file": "\(file)", "line": \(line), "inputType": "\(inputType)"}
            """
        return try JSONDecoder().decode(WalkRecord.self, from: Data(json.utf8))
    }

    static func result(
        _ verdict: RelationalResult.Verdict, property: String = "injective", inputType: String? = "M.Seat",
        file: String = "/x/t/Walks.swift", line: Int = 2
    ) -> RelationalResult {
        let request = RelationalRequest(claim: .injective, file: file, line: line, property: property, forward: [])
        var result = RelationalResult(
            request: request, verdict: verdict, inputs: verdict == .refuted ? "a = 1, b = 2" : nil,
            detail: verdict == .refuted ? "both give 3" : nil, assumptions: verdict == .proved ? ["text of a key"] : nil)
        result.inputType = inputType
        return result
    }

    static let sample = Check.sampleReason

    @Test func aProofMakesABoundedWalkProvedForEveryInput() throws {
        let record = try Self.record(properties: [Row("total", "bounded", Self.sample), Row("injective", "bounded", Self.sample)])
        let proved = Check.applyingRelational([Self.result(.proved)], to: [record])[0]
        #expect(proved.properties[1].verdict == "proved" && proved.properties[1].logic == "proved")
        #expect(proved.properties[1].detail == "for every input, by logic, assuming text of a key")
        // Logic proved the rule returns normally for every input before the claim: that is `total`.
        #expect(proved.properties[0].verdict == "proved" && proved.properties[0].logic == "proved")
        #expect(proved.verdict == "proved")
        let other = try Self.record(properties: [Row("injective", "bounded", Self.sample), Row("not empty", "bounded", Self.sample)])
        #expect(Check.applyingRelational([Self.result(.proved)], to: [other])[0].verdict == "bounded")
    }

    @Test func aCounterexampleFailsOnlyAWalkOverASample() throws {
        let sampled = try Self.record(properties: [Row("injective", "bounded", Self.sample)])
        let failed = Check.applyingRelational([Self.result(.refuted)], to: [sampled])[0]
        #expect(failed.verdict == "failed" && failed.properties[0].logic == "refuted")
        #expect(failed.properties[0].input == "a = 1, b = 2")
        #expect(failed.properties[0].detail == "both give 3 (found by logic, outside the walked inputs)")
        // A range too big to walk states a precondition; a complete domain is the walk's claim; a rule over `Seat?`
        // may fail at `nil`, which the walk does not give.
        let range = try Self.record(properties: [
            Row("injective", "bounded", "domain has 9 values; budget allows 8, checked a seeded sample")
        ]
        )
        let complete = try Self.record(complete: true, properties: [Row("injective", "proved", nil)])
        for record in [range, complete] { #expect(Check.applyingRelational([Self.result(.refuted)], to: [record])[0].verdict != "failed") }
        let optional = Self.result(.refuted, inputType: "Swift.Optional<M.Seat>")
        #expect(Check.applyingRelational([optional], to: [sampled])[0].verdict == "bounded")
        #expect(Check.applyingRelational([Self.result(.refuted, inputType: "M.Seat")], to: [sampled])[0].verdict == "failed")
    }

    @Test func theWalksFailureUnknownsAndConflictsStand() throws {
        let failed = try Self.record(properties: [Row("injective", "failed", "both give 1")])
        let kept = Check.applyingRelational([Self.result(.proved)], to: [failed])[0]
        #expect(kept.verdict == "failed" && kept.properties[0].logic == nil && kept.properties[0].detail == "both give 1")
        let sampled = try Self.record(properties: [Row("injective", "bounded", Self.sample)])
        #expect(Check.applyingRelational([Self.result(.unknown)], to: [sampled])[0].properties[0].logic == nil)
        let conflict = Check.applyingRelational([Self.result(.proved), Self.result(.refuted)], to: [sampled])[0]
        #expect(conflict.verdict == "bounded" && conflict.properties[0].logic == nil)
        // Two properties of one name in one walk: which one the claim is about is not known.
        let twice = try Self.record(properties: [Row("injective", "bounded", Self.sample), Row("injective", "bounded", Self.sample)])
        #expect(Check.applyingRelational([Self.result(.proved)], to: [twice])[0].verdict == "bounded")
    }

    @Test func spellsOptionalsOneWay() {
        #expect(RelationalTypeSource.canonical("M.Seat") == "M.Seat")
        #expect(RelationalTypeSource.canonical("M.Seat??") == "Swift.Optional<Swift.Optional<M.Seat>>")
        #expect(RelationalTypeSource.canonical("Swift.Optional<M.Seat?>") == "Swift.Optional<Swift.Optional<M.Seat>>")
    }

    /// The type a rule's first step takes, read from its full demangled name; nil when it cannot be named exactly.
    @Test func readsTheTypeFromTheDemangledName() {
        let context = RelationalTypeSource.context(symbol: "s")
        #expect(context.typeName(in: "M.Row.code.getter : Swift.Int") == "M.Row")
        #expect(context.typeName(in: "M.Rule.execute() -> Swift.Int") == "M.Rule")
        #expect(context.typeName(in: "(extension in App):Shared.Surface.text.getter : Swift.String") == "Shared.Surface")
        #expect(context.typeName(in: "M.code.getter : Swift.Int") == nil)
        #expect(context.typeName(in: "M.Box<A>.code.getter : Swift.Int") == nil)
        #expect(context.typeName(in: "(M.Row in _0123).code.getter : Swift.Int") == nil)
        let parameter = RelationalTypeSource.parameter(symbol: "s", index: 0)
        #expect(parameter.typeName(in: "M.Rule.init(input: M.Seat) -> M.Rule") == "M.Seat")
        #expect(parameter.typeName(in: "M.f(M.Seat?, (Swift.Int) -> Swift.Int) -> Swift.Int") == "Swift.Optional<M.Seat>")
        #expect(
            RelationalTypeSource.parameter(symbol: "s", index: 1).typeName(in: "M.f(a: (Swift.Int) -> Swift.Int, b: M.Seat) -> ()")
                == "M.Seat")
        #expect(parameter.typeName(in: "M.f(x: inout M.Seat) -> ()") == nil)
        let result = RelationalTypeSource.result(symbol: "s")
        #expect(result.typeName(in: "M.Rule.input.getter : M.Seat?") == "Swift.Optional<M.Seat>")
        #expect(result.typeName(in: "M.Rule.execute() -> M.Seat") == nil)
    }

    /// `$0.code` matches any scanned `code`: a result about another type's, or a type logic could not name, leaves the
    /// walk as it was, its `total` too.
    @Test func aResultAboutAnotherTypeLeavesTheWalkAlone() throws {
        let walk = try Self.record(properties: [Row("total", "bounded", Self.sample), Row("injective", "bounded", Self.sample)])
        for other in ["M.Row", "N.Seat", "Seat", "Swift.Optional<M.Seat>", "M.Seat?", nil] {
            for verdict in [RelationalResult.Verdict.proved, .refuted] {
                let after = Check.applyingRelational([Self.result(verdict, inputType: other)], to: [walk])[0]
                #expect(after.verdict == "bounded" && after.properties.allSatisfy { $0.logic == nil }, "\(other ?? "nil") \(verdict)")
            }
        }
        // The demangler's `M.Seat?` is Swift's `Swift.Optional<M.Seat>`.
        let optional = try Self.record(properties: [Row("injective", "bounded", Self.sample)], inputType: "Swift.Optional<M.Seat>")
        #expect(Check.applyingRelational([Self.result(.proved, inputType: "M.Seat?")], to: [optional])[0].verdict == "proved")
    }

    /// Two test files of one name, a walk at the same line in each: a result is about the one at its path.
    @Test func walksInTwoFilesOfOneNameAreToldApart() throws {
        let first = try Self.record(properties: [Row("injective", "bounded", Self.sample)], file: "/p/A/MapperTests.swift", line: 40)
        let second = try Self.record(properties: [Row("injective", "bounded", Self.sample)], file: "/p/B/MapperTests.swift", line: 40)
        let proof = Self.result(.proved, file: "/p/A/MapperTests.swift", line: 40)
        let after = Check.applyingRelational([proof], to: [first, second])
        #expect(after[0].verdict == "proved")
        #expect(after[1].verdict == "bounded" && after[1].properties[0].logic == nil)
        // A scan that read the rule and did not decide the claim cancels another scan's proof; one with no such
        // function says nothing.
        var undecided = Self.result(.unknown, file: "/p/A/MapperTests.swift", line: 40)
        #expect(Check.applyingRelational([proof, undecided], to: [first])[0].verdict == "bounded")
        #expect(Check.applyingRelational([undecided, proof], to: [first])[0].verdict == "bounded")
        undecided.unresolved = .noMatchingFunction
        #expect(Check.applyingRelational([proof, undecided], to: [first])[0].verdict == "proved")
    }
}

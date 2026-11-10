import Foundation
@testable import SFGenKit
import Testing

/// A symbol graph written by hand in the shape `swift symbolgraph-extract` emits, for the parts `sfgen domains` reads.
private struct Graph {
    let module: String
    var symbols: [[String: Any]] = []
    var relationships: [[String: Any]] = []

    init(module: String = "Lib") { self.module = module }

    func id(_ path: [String]) -> String { "s:\(module).\(path.joined(separator: "."))" }

    @discardableResult
    mutating func symbol(
        _ kind: String, _ path: [String], _ declaration: String, access: String = "public", extra: [String: Any] = [:]
    ) -> String {
        let id = id(path)
        var symbol: [String: Any] = [
            "kind": ["identifier": kind], "identifier": ["precise": id], "pathComponents": path, "accessLevel": access,
            "names": ["title": path.last ?? ""], "declarationFragments": [["kind": "text", "spelling": declaration]],
        ]
        symbol.merge(extra) { $1 }
        symbols.append(symbol)
        if path.count > 1 { relationships.append(["kind": "memberOf", "source": id, "target": self.id(Array(path.dropLast()))]) }
        return id
    }

    mutating func type(_ kind: String, _ name: String, access: String = "public") {
        symbol("swift.\(kind)", name.components(separatedBy: "."), "\(kind) \(name)", access: access)
    }

    /// `init(label: Type, …)`.
    mutating func initializer(_ owner: String, _ parameters: [(String, String)]) {
        let labels = parameters.map { "\($0.0):" }.joined()
        symbol(
            "swift.init", owner.components(separatedBy: ".") + ["init(\(labels))"],
            "init(\(parameters.map { "\($0.0): \($0.1)" }.joined(separator: ", ")))",
            extra: [
                "functionSignature": [
                    "parameters": parameters.map {
                        ["name": $0.0, "declarationFragments": [["kind": "text", "spelling": "\($0.0): \($0.1)"]]]
                    }
                ]
            ])
    }

    mutating func property(_ owner: String, _ name: String, _ type: String, settable: Bool = false) {
        symbol("swift.property", owner.components(separatedBy: ".") + [name], "var \(name): \(type) { get\(settable ? " set" : "") }")
    }

    mutating func shared(_ owner: String) {
        symbol("swift.type.property", [owner, "shared"], "static let shared: \(owner)")
    }

    mutating func method(_ owner: String, _ name: String) {
        symbol("swift.method", [owner, name], "func \(name)")
    }

    mutating func enumCase(_ owner: String, _ name: String, payload: String? = nil, unavailable: Bool = false) {
        let declaration = payload.map { "case \(name)(\($0))" } ?? "case \(name)"
        let availability: [String: Any] = ["availability": [["domain": "*", "isUnconditionallyUnavailable": true]]]
        symbol("swift.enum.case", [owner, payload == nil ? name : "\(name)(_:)"], declaration, extra: unavailable ? availability : [:])
    }

    mutating func caseIterable(_ name: String) {
        relationships.append(["kind": "conformsTo", "source": id([name]), "target": "s:s12CaseIterableP"])
    }

    /// `class Sub: Base`, with `Base` in this graph or, given its precise identifier, in another module.
    mutating func inherits(_ sub: String, from base: String, external: String? = nil) {
        var relationship: [String: Any] = ["kind": "inheritsFrom", "source": id([sub]), "target": external ?? id([base])]
        if external != nil { relationship["targetFallback"] = base }
        relationships.append(relationship)
    }

    /// `func onEnum(of value: Base) -> Kind`, the switch SKIE generates for a sealed hierarchy.
    mutating func onEnum(base: String, kind: String) {
        let returns: [[String: Any]] = [["kind": "typeIdentifier", "spelling": kind, "preciseIdentifier": id([kind])]]
        symbol(
            "swift.func", ["onEnum(of:)"], "func onEnum(of value: \(base)) -> \(kind)",
            extra: [
                "functionSignature": [
                    "parameters": [
                        [
                            "name": "value",
                            "declarationFragments": [
                                ["kind": "text", "spelling": "value: "],
                                ["kind": "typeIdentifier", "spelling": base, "preciseIdentifier": id([base])],
                            ],
                        ]
                    ],
                    "returns": returns,
                ]
            ])
    }

    var binaryModule: BinaryModule {
        var result = BinaryModule(name: module)
        result.add(graph: ["module": ["name": module], "symbols": symbols, "relationships": relationships])
        return result
    }
}

/// The stand-ins of the planted-bug suite's shapes 9 and 10 (`PlantedBugs/`), as Kotlin types reach Swift: two enums
/// (`Volume`'s `allCases` is hand-written and leaves a case out), and a sealed class: a base, a singleton and two data
/// classes, and an `onEnum(of:)` switch over them.
private func rewardGraph() -> Graph {
    var graph = Graph(module: "SwiftFormalTestingTests")
    graph.type("class", "Reward", access: "open")
    graph.type("class", "RewardNone")
    graph.inherits("RewardNone", from: "Reward")
    graph.shared("RewardNone")
    graph.type("class", "RewardPoints")
    graph.inherits("RewardPoints", from: "Reward")
    graph.property("RewardPoints", "doubled", "Bool")
    graph.initializer("RewardPoints", [("doubled", "Bool")])
    graph.type("class", "RewardVoucher")
    graph.inherits("RewardVoucher", from: "Reward")
    graph.property("RewardVoucher", "expired", "Bool")
    graph.initializer("RewardVoucher", [("expired", "Bool")])
    graph.type("enum", "RewardKind")
    graph.enumCase("RewardKind", "none", payload: "RewardNone")
    graph.enumCase("RewardKind", "points", payload: "RewardPoints")
    graph.enumCase("RewardKind", "voucher", payload: "RewardVoucher")
    graph.onEnum(base: "Reward", kind: "RewardKind")
    graph.type("enum", "SignalStrength")
    for name in ["none", "weak", "fair", "strong"] { graph.enumCase("SignalStrength", name) }
    graph.caseIterable("SignalStrength")
    graph.type("enum", "Volume")
    for name in ["mute", "low", "high"] { graph.enumCase("Volume", name) }
    graph.caseIterable("Volume")
    return graph
}

private func entry(_ result: BinaryDomainResult, _ type: String) -> BinaryDomainEntry? {
    result.entries.first { $0.type == type }
}

@Suite("sfgen domains: walk domains for a binary framework's types")
struct BinaryDomainTests {
    @Test("the planted-bug suite's generated domains are this generator's output, unedited")
    func committedRewardDomainsAreCurrent() throws {
        let result = BinaryDomainWriter.generate(rewardGraph().binaryModule)
        let committed = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("SwiftFormalTestingTests/GeneratedBinaryDomains.swift")
        // The test module cannot import itself; everything else is as generated.
        let expected = result.source.replacingOccurrences(of: "import SwiftFormalTestingTests\n", with: "")
        #expect(try String(contentsOf: committed, encoding: .utf8) == expected)
        #expect(
            result.entries.map { "\($0.type) \($0.category.rawValue) \($0.status.rawValue)" } == [
                "Reward sealed exhaustive", "RewardNone object exhaustive", "RewardPoints init exhaustive",
                "RewardVoucher init exhaustive", "SignalStrength enum exhaustive", "Volume enum exhaustive",
            ])
        #expect(result.source.contains("case .none, .points, .voucher: break"))
    }

    @Test("a sealed hierarchy with a case it cannot build, or a bounded case, is bounded")
    func sealedWithElseOrBoundedCaseIsBounded() throws {
        var graph = rewardGraph()
        graph.type("class", "RewardCash")
        graph.property("RewardCash", "cents", "Int32")
        graph.initializer("RewardCash", [("cents", "Int32")])
        graph.enumCase("RewardKind", "cash", payload: "RewardCash")
        graph.enumCase("RewardKind", "else")
        let result = BinaryDomainWriter.generate(graph.binaryModule)
        let reward = try #require(entry(result, "Reward"))
        #expect(reward.status == .bounded)
        #expect(reward.reason.contains("else"))
        #expect(entry(result, "RewardCash")?.status == .bounded)
        #expect(result.source.contains("]).asSample"))
        #expect(result.source.contains("case .cash, .`else`, .none, .points, .voucher: break"))
    }

    @Test("a data class over Bool and CaseIterable enum fields is exhaustive; numbers and strings bound it")
    func dataClassFields() throws {
        var graph = Graph()
        graph.type("enum", "Firmness")
        graph.enumCase("Firmness", "soft")
        graph.enumCase("Firmness", "firm")
        graph.caseIterable("Firmness")
        graph.type("class", "Surface")
        graph.property("Surface", "firmness", "Firmness")
        graph.property("Surface", "wet", "Bool?")
        graph.initializer("Surface", [("firmness", "Firmness"), ("wet", "Bool?")])
        graph.type("struct", "Shot")
        graph.property("Shot", "carry", "Double")
        graph.property("Shot", "club", "String")
        graph.initializer("Shot", [("carry", "Double"), ("club", "String")])
        let result = BinaryDomainWriter.generate(graph.binaryModule)
        #expect(entry(result, "Firmness")?.status == .exhaustive)
        #expect(entry(result, "Surface")?.status == .exhaustive)
        #expect(result.source.contains("let f0 = SwiftFormal.Domain<Lib.Firmness>.firmness"))
        #expect(result.source.contains(".optional(SwiftFormal.Domain<Bool>.bool)"))
        let shot = try #require(entry(result, "Shot"))
        #expect(shot.status == .bounded)
        #expect(result.source.contains(".nan"))
        #expect(result.source.contains("\"Ünïcødé ✓\""))
    }

    @Test("state the initializer does not set bounds a class; an open class or a plain enum is no root")
    func stateTheInitializerMissesIsBounded() {
        var graph = Graph()
        graph.type("class", "Settable")
        graph.property("Settable", "on", "Bool", settable: true)
        graph.initializer("Settable", [("on", "Bool")])
        graph.type("class", "Stateful")
        graph.property("Stateful", "on", "Bool")
        graph.initializer("Stateful", [("on", "Bool")])
        graph.method("Stateful", "toggle()")
        graph.type("class", "DataLike")
        graph.property("DataLike", "on", "Bool")
        graph.initializer("DataLike", [("on", "Bool")])
        graph.method("DataLike", "doCopy(on:)")
        graph.method("DataLike", "component1()")
        graph.type("class", "Hidden")
        graph.property("Hidden", "on", "Bool")
        graph.property("Hidden", "count", "Bool")
        graph.initializer("Hidden", [("on", "Bool")])
        graph.type("class", "Base", access: "open")
        graph.initializer("Base", [])
        graph.type("enum", "Mode")
        graph.enumCase("Mode", "fast")
        graph.type("class", "Closed")
        let result = BinaryDomainWriter.generate(graph.binaryModule)
        #expect(entry(result, "Settable")?.status == .bounded)
        #expect(entry(result, "Stateful")?.status == .bounded)
        #expect(entry(result, "Stateful")?.reason.contains("toggle()") == true)
        #expect(entry(result, "DataLike")?.status == .exhaustive)
        #expect(entry(result, "Hidden")?.status == .bounded)
        #expect(entry(result, "Base")?.status == .skipped)
        #expect(entry(result, "Mode")?.status == .skipped)
        #expect(entry(result, "Closed")?.reason == "no public initializer")
    }

    @Test("an enum's allCases is checked against the graph's cases when the walk runs; a case it cannot check bounds it")
    func enumAllCasesIsCheckedAgainstTheGraph() throws {
        var graph = Graph()
        graph.type("enum", "Firmness")
        graph.enumCase("Firmness", "soft")
        graph.enumCase("Firmness", "firm")
        graph.caseIterable("Firmness")
        graph.type("enum", "Carry")
        graph.enumCase("Carry", "short")
        graph.enumCase("Carry", "long", payload: "Int")
        graph.caseIterable("Carry")
        graph.type("enum", "Legacy")
        graph.enumCase("Legacy", "current")
        graph.enumCase("Legacy", "old", unavailable: true)
        graph.caseIterable("Legacy")
        let result = BinaryDomainWriter.generate(graph.binaryModule)
        #expect(result.source.contains("let all = Lib.Firmness.allCases"))
        #expect(result.source.contains("guard all.count == 2, Set(all).count == 2 else {"))
        #expect(entry(result, "Firmness")?.member == "firmness")
        let carry = try #require(entry(result, "Carry"))
        #expect(carry.status == .bounded)
        #expect(carry.reason.contains("long"))
        #expect(entry(result, "Legacy")?.status == .bounded)
        #expect(result.source.contains("SwiftFormal.Domain<Lib.Carry>.samples(Array(Lib.Carry.allCases))"))
    }

    @Test("settable state and methods of any superclass, or a superclass outside the graph, bound a class and its hierarchy")
    func inheritedStateIsBounded() throws {
        var graph = Graph()
        graph.type("class", "Shot", access: "open")
        graph.property("Shot", "tag", "Bool", settable: true)
        graph.type("class", "Putt")
        graph.inherits("Putt", from: "Shot")
        graph.property("Putt", "short", "Bool")
        graph.initializer("Putt", [("short", "Bool")])
        graph.type("enum", "ShotKind")
        graph.enumCase("ShotKind", "putt", payload: "Putt")
        graph.onEnum(base: "Shot", kind: "ShotKind")
        graph.type("class", "Surface", access: "open")
        graph.method("Surface", "dry()")
        graph.type("class", "Sand", access: "open")
        graph.inherits("Sand", from: "Surface")
        graph.type("class", "DeepSand")
        graph.inherits("DeepSand", from: "Sand")
        graph.property("DeepSand", "wet", "Bool")
        graph.initializer("DeepSand", [("wet", "Bool")])
        graph.type("class", "Boxed")
        graph.inherits("Boxed", from: "NSNumber", external: "c:objc(cs)NSNumber")
        graph.property("Boxed", "on", "Bool")
        graph.initializer("Boxed", [("on", "Bool")])
        graph.type("class", "Plain")
        graph.inherits("Plain", from: "NSObject", external: "c:objc(cs)NSObject")
        graph.property("Plain", "on", "Bool")
        graph.initializer("Plain", [("on", "Bool")])
        let result = BinaryDomainWriter.generate(graph.binaryModule)
        let putt = try #require(entry(result, "Putt"))
        #expect(putt.status == .bounded)
        #expect(putt.reason.contains("tag"), "\(putt.reason)")
        #expect(entry(result, "Shot")?.status == .bounded)
        #expect(entry(result, "DeepSand")?.status == .bounded)
        #expect(entry(result, "DeepSand")?.reason.contains("dry()") == true)
        #expect(entry(result, "Boxed")?.status == .bounded)
        #expect(entry(result, "Boxed")?.reason.contains("NSNumber") == true)
        #expect(entry(result, "Plain")?.status == .exhaustive)
    }

    @Test("an onEnum(of:) whose enum the graph hides is counted, not guessed at")
    func missingSealedEnumIsCounted() {
        var graph = rewardGraph()
        graph.symbols.removeAll { ($0["pathComponents"] as? [String])?.first == "RewardKind" }
        let module = graph.binaryModule
        #expect(module.sealedEnumsMissing == 1)
        #expect(module.sealed.isEmpty)
    }

    @Test("the output does not depend on the order of the graph")
    func outputIsDeterministic() {
        var graph = rewardGraph()
        let forward = BinaryDomainWriter.generate(graph.binaryModule).source
        graph.symbols.reverse()
        graph.relationships.reverse()
        #expect(BinaryDomainWriter.generate(graph.binaryModule).source == forward)
    }
}

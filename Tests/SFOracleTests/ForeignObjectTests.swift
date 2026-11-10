import Foundation
import SFVerifyKit
import Testing

/// Objective-C objects (plan item R6-1), shaped like a Kotlin/Native export: a clang module with an `NS_ASSUME_NONNULL`
/// interface, compiled into the scanned Swift with `-I`. An object is an opaque reference; a getter or method returns
/// any value of its declared type, and a counterexample that rests on one says what the foreign object returned.
@Suite(.tags(.oracle), .requiresPinnedCompiler) struct ForeignObjectTests {
    static let header = """
        #import <Foundation/Foundation.h>
        NS_ASSUME_NONNULL_BEGIN
        @interface GKTBase : NSObject
        @end
        @interface GKTDomainX : GKTBase
        @property (readonly) int32_t count;
        @property (readonly) int32_t index;
        @property (readonly) BOOL enabled;
        @property (readonly) NSString *name;
        @property (readonly, nullable) NSString *nickname;
        @property (readonly, nullable) GKTDomainX *next;
        @property (readonly) GKTDomainX *parent;
        @property int32_t mutableCount;
        - (int32_t)scoreFor:(int32_t)hole;
        - (instancetype)initWithCount:(int32_t)count;
        - (void)visit:(void (^)(void))block;
        @end
        @protocol GKTDomainRecord
        @property (readonly) int32_t rounds;
        @end
        @interface GKTKind : GKTBase
        @property (class, readonly) GKTKind *driver;
        @end
        __attribute__((swift_name("GKTRenamed")))
        @interface GKTObjCRenamed : GKTBase
        @property (readonly) int32_t value;
        @end
        NS_ASSUME_NONNULL_END
        """

    static let source = """
        import GKT
        struct R { let input: GKTDomainX; var body: Int { Int(input.count) } }
        func pick(_ input: GKTDomainX) -> Int { [1, 2, 3][Int(input.index)] }
        struct Holder { let x: GKTDomainX; let n: Int }
        func store(_ x: GKTDomainX, _ n: Int) -> Int { let h = Holder(x: x, n: n); return h.n }
        func nick(_ x: GKTDomainX) -> Int { x.nickname!.isEmpty ? 0 : 1 }
        func nextCount(_ x: GKTDomainX) -> Int32 { x.next!.count }
        func parentCount(_ x: GKTDomainX) -> Int { Int(x.parent.count) }
        func readOnce(_ x: GKTDomainX) -> Int { let i = x.index; return i >= 0 && i < 3 ? [1, 2, 3][Int(i)] : 0 }
        func readTwice(_ x: GKTDomainX) -> Int { x.index >= 0 && x.index < 3 ? [1, 2, 3][Int(x.index)] : 0 }
        func setter(_ a: GKTDomainX) { a.mutableCount = 3 }
        func setThenRead(_ a: GKTDomainX) -> Int { a.mutableCount = 1; return [1, 2, 3][Int(a.mutableCount)] }
        func score(_ a: GKTDomainX) -> Int32 { a.score(for: 4) }
        func scorePlusOne(_ a: GKTDomainX) -> Int32 { a.score(for: 4) + 1 }
        func enabled(_ a: GKTDomainX) -> Bool { a.enabled }
        func name(_ a: GKTDomainX) -> String { a.name }
        func nameIsEmpty(_ a: GKTDomainX) -> Bool { a.name.isEmpty }
        func rounds(_ t: any GKTDomainRecord) -> Int32 { t.rounds }
        func roundsPick(_ t: any GKTDomainRecord) -> Int { [1, 2][Int(t.rounds)] }
        func same(_ a: GKTDomainX, _ b: GKTDomainX) -> Bool { a === b }
        func sameTraps(_ a: GKTDomainX, _ b: GKTDomainX) -> Int { a === b ? [1][1] : 0 }
        func loopPick(_ x: GKTDomainX) -> Int { var i = 0; while i < 3 { i += 1 }; return [1, 2, 3][Int(x.index)] }
        func selfSame(_ a: GKTDomainX) -> Int { a === a ? 0 : [1][1] }
        func asBase(_ a: GKTDomainX) -> GKTBase { a }
        func kind() -> GKTKind { GKTKind.driver }
        // Mangled with its Objective-C name, printed with its Swift name.
        func renamed(_ r: GKTRenamed) -> Int32 { r.value }
        // Out of scope: kept unsupported.
        func equal(_ a: GKTKind, _ b: GKTKind) -> Bool { a == b }
        func make() -> GKTDomainX { GKTDomainX(count: 3) }
        func cast(_ o: GKTBase) -> Int32 { (o as? GKTDomainX)?.count ?? 0 }
        func describe(_ a: GKTDomainX) -> String { "\\(a)" }
        func visit(_ a: GKTDomainX) { a.visit {} }
        func observe(_ a: GKTDomainX) { _ = a.observe(\\.count) { _, _ in } }
        func isDriver(_ k: GKTKind) -> Int { switch k { case GKTKind.driver: 1; default: 0 } }
        """

    /// A module of its own: the Swift subclass and conformance make their foreign supertypes unreadable everywhere.
    static let subclassing = """
        import GKT
        final class Mine: GKTDomainX {}
        final class Tour: NSObject, GKTDomainRecord { var rounds: Int32 { 3 } }
        func count(_ x: GKTDomainX) -> Int32 { x.count }
        func rounds(_ t: any GKTDomainRecord) -> Int32 { t.rounds }
        func baseOnly(_ k: GKTKind) -> GKTKind { k }
        // A member this module adds to an Objective-C class: a call to it runs this Swift code.
        extension GKTRenamed { @objc var extra: Int32 { 0 } }
        func renamedExtra(_ r: GKTRenamed) -> Int32 { r.extra }
        // A member of this module's own class: reached only through one of its objects, which `renamed` cannot be.
        final class Helper: NSObject { @objc var value: Int32 { 0 } }
        func renamedValue(_ r: GKTRenamed) -> Int32 { r.value }
        // An `@objc` Swift class is a class of this module: not read.
        func helperValue(_ h: Helper) -> Int32 { h.value }
        """

    static func scan(_ source: String, module: String, opaqueCalls: Bool = true) throws -> ScanReport {
        let directory = NSTemporaryDirectory() + "sfv-foreign-\(UUID().uuidString)"
        try FileManager.default.createDirectory(atPath: directory + "/GKT", withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: directory) }
        let map = "module GKT {\n  header \"GKT.h\"\n  export *\n}\n"
        try map.write(toFile: directory + "/GKT/module.modulemap", atomically: true, encoding: .utf8)
        try header.write(toFile: directory + "/GKT/GKT.h", atomically: true, encoding: .utf8)
        let file = directory + "/\(module).swift"
        try source.write(toFile: file, atomically: true, encoding: .utf8)
        var options = VerifyOptions()
        options.configurations = [.debug]
        options.opaqueCalls = opaqueCalls
        return try SFVerify.run(CompileOptions(files: [file], moduleName: module, extraArguments: ["-I", directory + "/GKT"]), options)
    }

    static let report = Result { try scan(source, module: "Foreign") }
    static let strict = Result { try scan(source, module: "Foreign", opaqueCalls: false) }

    private static func function(_ name: String, in report: ScanReport? = nil) throws -> FunctionReport {
        let report = try report ?? Self.report.get()
        let found = report.functions.first { $0.name.hasPrefix(name + "(") || $0.name.hasPrefix(name + ".") }
        return try #require(found, "\(report.functions.map(\.name))")
    }

    private static func describe(_ f: FunctionReport) -> String {
        "\(f.name): \(f.status) \(f.category ?? "") \(f.detail ?? "") \(f.counterexample.map { "\($0.inputs) \($0.failure)" } ?? "")"
    }

    /// (a), (c): reading, holding, passing and storing an object cannot trap; `Int32` to `Int` widens.
    @Test func gettersAndHeldObjectsAreSafe() throws {
        for name in [
            "R.body", "store", "parentCount", "readOnce", "setter", "score", "enabled", "name", "nameIsEmpty", "rounds", "same",
            "selfSame", "asBase", "kind", "renamed",
        ] {
            let f = try Self.function(name)
            #expect(f.status == .safe, "\(Self.describe(f))")
        }
    }

    /// (b): an index the foreign object returns may be out of range; the report says which call returned what.
    @Test func aTrapOnAForeignResultIsReportedWithIt() throws {
        let f = try Self.function("pick")
        #expect(f.status == .mayTrap, "\(Self.describe(f))")
        let example = try #require(f.counterexample)
        let returned = try #require(example.foreignResults?.first, "\(example)")
        #expect(returned.hasPrefix("input.index returned "), "\(returned)")
        let value = try #require(Int(returned.split(separator: " ").last ?? ""), "\(returned)")
        #expect(value < 0 || value >= 3)
        #expect(example.inputs.contains(returned))
        #expect(example.replay == nil)
        #expect(example.failure.contains("Index out of range"), "\(example.failure)")
    }

    /// (e): nothing that can trap for some foreign value is `safe`; each call returns its own value.
    @Test func trapsThatDependOnForeignValuesAreNotSafe() throws {
        for name in ["nick", "nextCount", "readTwice", "setThenRead", "scorePlusOne", "roundsPick", "sameTraps"] {
            let f = try Self.function(name)
            #expect(f.status == .mayTrap, "\(Self.describe(f))")
        }
        // A loop proof reads foreign results as approximations: never `safe`, and no foreign values are claimed.
        let loop = try Self.function("loopPick")
        #expect(loop.status != .safe && loop.counterexample?.foreignResults == nil, "\(Self.describe(loop))")
        let nick = try #require(try Self.function("nick").counterexample?.foreignResults)
        #expect(nick == ["x.nickname returned nil"], "\(nick)")
        let twice = try #require(try Self.function("readTwice").counterexample?.foreignResults)
        #expect(twice.count == 3 && twice.allSatisfy { $0.hasPrefix("x.index returned ") }, "\(twice)")
    }

    /// (d): what this item leaves out stays `unsupported`, with a reason.
    @Test func outOfScopeConstructsStayUnsupported() throws {
        let reasons = [
            "make": "creating an Objective-C object", "cast": "checked_cast", "describe": "print", "visit": "block",
            "observe": "NSKeyValueObserving",
        ]
        for (name, reason) in reasons {
            let f = try Self.function(name)
            #expect(f.status == .unsupported, "\(Self.describe(f))")
            #expect((f.detail ?? "").contains(reason), "\(Self.describe(f))")
        }
    }

    /// `==` of Objective-C objects calls `isEqual:`, which Scan does not read: either answer, listed as an assumption;
    /// refused with `--no-opaque-calls`.
    @Test func objectiveCEqualityIsAnAssumption() throws {
        for name in ["equal", "isDriver"] {
            let f = try Self.function(name)
            #expect(f.status == .safe, "\(Self.describe(f))")
            #expect(f.assumptions?.contains { $0.contains("isEqual:") } == true, "\(Self.describe(f))")
            let strict = try Self.function(name, in: Self.strict.get())
            #expect(strict.status == .unsupported && (strict.detail ?? "").contains("--no-opaque-calls"), "\(Self.describe(strict))")
        }
    }

    /// (d): a Swift subclass or conformance means a call or a release may run Swift code of this module.
    @Test func swiftSubclassesAndConformancesMakeTheirSupertypesUnreadable() throws {
        let report = try Self.scan(Self.subclassing, module: "Subclassing")
        for name in ["count", "rounds"] {
            let f = try Self.function(name, in: report)
            #expect(f.status == .unsupported, "\(Self.describe(f))")
            #expect((f.detail ?? "").contains("subclasses or conforms"), "\(Self.describe(f))")
        }
        let unrelated = try Self.function("baseOnly", in: report)
        #expect(unrelated.status == .safe, "\(Self.describe(unrelated))")
        let added = try Self.function("renamedExtra", in: report)
        #expect(added.status == .unsupported && (added.detail ?? "").contains("also implements extra"), "\(Self.describe(added))")
        let own = try Self.function("renamedValue", in: report)
        #expect(own.status == .safe, "\(Self.describe(own))")
        let helper = try Self.function("helperValue", in: report)
        #expect(helper.status == .unsupported && (helper.detail ?? "").contains("class"), "\(Self.describe(helper))")
    }
}

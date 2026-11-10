import Foundation
import Testing
import SFProve
import SFSIL

/// The Composable Architecture's `@ObservableState`, read against a stub `ComposableArchitecture` module whose
/// declarations have the same mangled names as TCA 1.26. The fixture is what the macro expands to, by hand.
enum PackageFixture {
    static let stub = """
        import Observation
        public struct ObservableStateID: Equatable, Hashable, Sendable {
            private final class Storage: @unchecked Sendable {}
            private let storage = Storage()
            public init() {}
            public static func == (l: Self, r: Self) -> Bool { l.storage === r.storage }
            public func hash(into hasher: inout Hasher) { hasher.combine(ObjectIdentifier(storage)) }
        }
        public final class PerceptionRegistrar: @unchecked Sendable { public init() {} }
        public struct ObservationStateRegistrar: Sendable {
            public private(set) var id = ObservableStateID()
            @usableFromInline let registrar = PerceptionRegistrar()
            public init() {}
            public func access<Subject: Observable, Member>(_ subject: Subject, keyPath: KeyPath<Subject, Member>) {}
            public mutating func _$willModify() { id = ObservableStateID() }
        }
        extension ObservationStateRegistrar: Equatable, Hashable {
            public static func == (_: Self, _: Self) -> Bool { true }
            public func hash(into hasher: inout Hasher) {}
        }
        """

    static let state = """
        import ComposableArchitecture
        import Observation

        public struct Counter: Observable, Equatable {
            var _count: Int8 = 0
            var _$observationRegistrar = ObservationStateRegistrar()
            public init() {}
            public var _$id: ObservableStateID { _$observationRegistrar.id }
            public mutating func _$willModify() { _$observationRegistrar._$willModify() }
            public var count: Int8 {
                get { _$observationRegistrar.access(self, keyPath: \\.count); return _count }
                set { _count = newValue }
            }
            public var isBig: Bool { count > 100 }
        }

        public func big(_ s: Counter) -> Bool { s.isBig }
        public func next(_ s: Counter) -> Int8 { s.count + 1 }
        public func fresh() -> Counter { Counter() }
        public func id(_ s: Counter) -> ObservableStateID { s._$id }
        public func touch(_ s: inout Counter) { s._$willModify() }
        public func same(_ a: Counter, _ b: Counter) -> Bool { a == b }
        public func observe(_ s: Counter, _ k: KeyPath<Counter, Int8>) { s._$observationRegistrar.access(s, keyPath: k) }
        """

    /// The directory holding the stub's `ComposableArchitecture.swiftmodule`.
    static let stubDirectory: String = {
        let directory = NSTemporaryDirectory() + "sf-tca-stub-\(UUID().uuidString)"
        try! FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
        try! stub.write(toFile: directory + "/stub.swift", atomically: true, encoding: .utf8)
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/xcrun")
        process.arguments = [
            "swiftc", "-emit-module", "-parse-as-library", "-module-name", "ComposableArchitecture",
            "-emit-module-path", directory + "/ComposableArchitecture.swiftmodule", directory + "/stub.swift",
        ]
        try! process.run()
        process.waitUntilExit()
        precondition(process.terminationStatus == 0, "the ComposableArchitecture stub did not compile")
        return directory
    }()

    static func module(_ source: String = state, confirmed: [String] = ["ObservationStateRegistrar", "ObservableStateID"]) throws
        -> SILModule
    {
        var module = try SILCompiler.module(source: source, name: "Tca", optimization: .none, extraArguments: ["-I", stubDirectory])
        module.confirmPackageTypes(confirmed)
        return module
    }
    static let confirmed = try! module()

    static func verdict(_ name: String, in module: SILModule = confirmed) throws -> ProofVerdict {
        try SILVerifier.proveAggregate(try module.symbol(module: "Tca", name: name), in: module, ensures: { c, _, _ in c.trueLit })
    }
    static func rejection(_ name: String, in module: SILModule) -> String? {
        do {
            _ = try verdict(name, in: module)
            return nil
        } catch {
            return "\(error)"
        }
    }
}

@Suite(.tags(.slow)) struct SILPackageTypeTests {
    @Test func observableStateReadsAreProved() throws {
        for name in ["big", "fresh", "id", "touch", "same"] {
            #expect(try PackageFixture.verdict(name) == .proved, "\(name)")
        }
    }

    @Test func aTrapBehindAnObservedReadIsFound() throws {
        guard case .counterexample(let inputs) = try PackageFixture.verdict("next") else {
            Issue.record("count + 1 overflows")
            return
        }
        // The leaves are `_count`, then the registrar's two opaque handles.
        #expect(inputs.first == 127, "\(inputs)")
    }

    @Test func anUnconfirmedPackageNameIsNotRead() throws {
        let module = try PackageFixture.module(confirmed: [])
        let reason = try #require(PackageFixture.rejection("big", in: module))
        #expect(reason.contains("ObservationStateRegistrar"), "\(reason)")
    }

    @Test func aReadModuleThatMentionsIssueReportersStopsTrustingAccess() throws {
        let source = PackageFixture.state + "\npublic func reporter() -> String { \"IssueReporters.current\" }\n"
        let reason = try #require(PackageFixture.rejection("big", in: try PackageFixture.module(source)))
        #expect(reason.contains("IssueReporting"), "\(reason)")
    }

    @Test func keyPathsThatCaptureValuesOrUseAnotherModuleAreNotRead() throws {
        let source = """
            public struct Box { public var items: [Int8] = [] }
            public func element() -> KeyPath<Box, Int8> { \\Box.items[0] }
            public func length() -> KeyPath<String, Int> { \\String.count }
            public func plain() -> KeyPath<Box, [Int8]> { \\Box.items }
            """
        let module = try PackageFixture.module(source)
        for name in ["element", "length"] {
            let reason = try #require(PackageFixture.rejection(name, in: module), "\(name)")
            #expect(reason.contains("keypath") || reason.contains("key path"), "\(name): \(reason)")
        }
        #expect(try PackageFixture.verdict("plain", in: module) == .proved)
    }

    /// Observation hashes the key path it records; a key path that captured a value hashes it with that value's own
    /// `hash(into:)`. Only a literal of the function itself is known to capture nothing.
    @Test func recordingAReadThroughAKeyPathParameterIsNotTrusted() throws {
        let reason = try #require(PackageFixture.rejection("observe", in: PackageFixture.confirmed))
        #expect(reason.contains("not a key path literal"), "\(reason)")
    }

    /// Releasing `\S.[Bomb()]` destroys the captured `Bomb`, whose deinit traps. A key path that is not a literal of
    /// the function may hold one, so in such a build key path values are refused like closures.
    @Test func keyPathsAreRefusedWhenADeinitOfTheModuleCanTrap() throws {
        let source = """
            final class Bomb: Hashable {
                deinit { fatalError("boom") }
                static func == (l: Bomb, r: Bomb) -> Bool { l === r }
                func hash(into h: inout Hasher) {}
            }
            public struct S { subscript(b: Bomb) -> Int8 { 0 } }
            public struct Box { var k: KeyPath<S, Int8>; var n: Int8 }
            public func reset(_ b: inout Box, _ k: KeyPath<S, Int8>) { b.k = k }
            """
        let reason = try #require(PackageFixture.rejection("reset", in: try PackageFixture.module(source)))
        #expect(reason.contains("destroying it may run a deinit"), "\(reason)")
    }

    @Test func aReadModulesOwnDeclarationWinsOverThePackageName() throws {
        let source = """
            public struct ObservationStateRegistrar { public var n: Int8 = 0 }
            public func bump(_ r: ObservationStateRegistrar) -> Int8 { r.n + 1 }
            """
        guard case .counterexample(let inputs) = try PackageFixture.verdict("bump", in: try PackageFixture.module(source)) else {
            Issue.record("the module's own ObservationStateRegistrar has an Int8 that overflows")
            return
        }
        #expect(inputs == [127], "\(inputs)")
    }
}

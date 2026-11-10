import Foundation
import SFVerifyKit
import Testing

/// A Composable Architecture-shaped state with a `UUID` and a `URL`, through the whole pipeline: the type-name probe
/// confirms the Foundation names, then every accessor and the synthesized conformances are read (`SILOpaqueValues`).
@Suite struct FoundationValueScanTests {
    static let source = """
        import Foundation

        public struct State: Equatable, Hashable {
            public let id: UUID
            public var url: URL?
            public var count: Int
            public init(id: UUID, url: URL?, count: Int) { self.id = id; self.url = url; self.count = count }
            public func pick() -> Int { [1, 2][count] }
            #sourceLocation(file: "@__swiftmacro_3App2id6VerifyfMp_.swift", line: 1)
            public func id_ensures(_ result: UUID) -> Bool { result == id }
            #sourceLocation()
            public func currentID() -> UUID { id }
            #sourceLocation(file: "@__swiftmacro_3App9currentID6VerifyfMp_.swift", line: 1)
            public func currentID_ensures(_ result: UUID) -> Bool { result == id }
            #sourceLocation()
            public func sameAs(_ other: State) -> Bool { id == other.id }
            #sourceLocation(file: "@__swiftmacro_3App6sameAs6VerifyfMp_.swift", line: 1)
            public func sameAs_ensures(_ other: State, _ result: Bool) -> Bool { result }
            #sourceLocation()
            public func otherID(_ o: State) -> UUID { o.id }
            #sourceLocation(file: "@__swiftmacro_3App7otherID6VerifyfMp_.swift", line: 1)
            public func otherID_ensures(_ o: State, _ result: UUID) -> Bool { result == id }
            #sourceLocation()
            public mutating func bump() { count &+= 1 }
            #sourceLocation(file: "@__swiftmacro_3App4bump6VerifyfMp_.swift", line: 1)
            public func bump_ensures(old: State) -> Bool { id == old.id && count == old.count &+ 1 }
            #sourceLocation()
        }
        public func twoFresh(_ x: Int8) -> Int8 { UUID() == UUID() ? x + 1 : x }
        public func link(_ s: String) -> URL? { URL(string: s) }
        """

    static func run() throws -> ScanReport {
        let directory = NSTemporaryDirectory() + "sfv-values-\(UUID().uuidString)"
        try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: directory) }
        let file = directory + "/state.swift"
        try source.write(toFile: file, atomically: true, encoding: .utf8)
        var options = VerifyOptions()
        options.configurations = [.debug]
        return try SFVerify.run(CompileOptions(files: [file], moduleName: "Values"), options)
    }

    @Test func aStateWithAUUIDAndAURLIsRead() throws {
        let report = try Self.run()
        func status(_ name: String) -> ScanStatus? { report.functions.first { $0.name.hasPrefix(name) }?.status }
        for name in ["State.url.getter", "State.url.setter", "State.count.getter", "State.count.setter", "State.init("] {
            #expect(status(name) == .safe, "\(name): \(report.functions.first { $0.name.hasPrefix(name) }?.detail ?? "missing")")
        }
        for name in ["static State.__derived_struct_equals", "State.hash(into:)", "State.hashValue.getter", "link("] {
            #expect(status(name) == .safe, "\(name)")
        }
        // `id_ensures` pairs with the stored property's getter; the address-only result is passed to it.
        for name in ["State.id.getter", "State.currentID()", "State.bump()"] { #expect(status(name) == .contractHolds, "\(name)") }

        let pick = try #require(report.functions.first { $0.name.hasPrefix("State.pick()") })
        #expect(pick.status == .mayTrap)
        #expect(pick.counterexample?.inputs.first?.contains("id: <UUID 1>") == true, "\(pick.counterexample?.inputs ?? [])")
        #expect(pick.counterexample?.replay == nil, "a state with a UUID cannot be written as a literal")

        // Two unknown states may have different ids: the contract `result` (always true) is refuted.
        let sameAs = try #require(report.functions.first { $0.name.hasPrefix("State.sameAs(") })
        #expect(sameAs.status == .contractFails)
        #expect(sameAs.counterexample?.inputs.joined().contains("<UUID 2>") == true, "\(sameAs.counterexample?.inputs ?? [])")
        // A false control for the address-only result handed to `ensures`: it is `o.id`, not `self.id`.
        let otherID = try #require(report.functions.first { $0.name.hasPrefix("State.otherID(") })
        #expect(otherID.status == .contractFails)
        #expect(otherID.counterexample?.result?.hasPrefix("<UUID ") == true, "\(otherID.counterexample?.result ?? "no result")")
        // Two fresh UUIDs: nothing says whether they are equal.
        #expect(status("twoFresh(") == .undecided)
    }
}

import SFVerifyKit
import Testing

@Suite struct RawValueEnumContractTests {
    /// L4: `==` on an enum with `String` raw values in `#requires` and `#ensures` (the generic builtin
    /// `getEnumTag`). Each contract is read, and gives its true and its false outcome.
    static let rawValueEnumApp = """
        import SwiftFormal

        public enum Club: String { case driver, iron, putter }

        func pick(_ n: Int8) -> Club {
            let __sf_result: Club = { () -> Club in n > 100 ? .driver : .iron }()
            if !(({ $0 == .iron || $0 == .driver })(__sf_result)) { SwiftFormal.Contract.ensuresFailed("{ $0 == .iron || $0 == .driver }") }
            return __sf_result
        }
        #sourceLocation(file: "@__swiftmacro_3App4pick6VerifyfMp_.swift", line: 1)
        func pick_ensures(_ n: Int8, _ __sf_result: Club) -> Bool { ({ $0 == .iron || $0 == .driver })(__sf_result) }
        #sourceLocation()

        func pickWrong(_ n: Int8) -> Club {
            let __sf_result: Club = { () -> Club in n > 100 ? .driver : .iron }()
            if !(({ $0 == .iron })(__sf_result)) { SwiftFormal.Contract.ensuresFailed("{ $0 == .iron }") }
            return __sf_result
        }
        #sourceLocation(file: "@__swiftmacro_3App9pickWrong6VerifyfMp_.swift", line: 1)
        func pickWrong_ensures(_ n: Int8, _ __sf_result: Club) -> Bool { ({ $0 == .iron })(__sf_result) }
        #sourceLocation()

        func lift(_ club: Club, _ n: Int8) -> Int8 {
            if !(club != .putter) { SwiftFormal.Contract.requiresFailed("club != .putter") }
            let __sf_result: Int8 = { () -> Int8 in club == .putter ? n &+ 1 : n }()
            if !(({ $0 == n })(__sf_result)) { SwiftFormal.Contract.ensuresFailed("{ $0 == n }") }
            return __sf_result
        }
        #sourceLocation(file: "@__swiftmacro_3App4lift6VerifyfMp_.swift", line: 1)
        func lift_requires(_ club: Club, _ n: Int8) -> Bool { (club != .putter) }
        func lift_ensures(_ club: Club, _ n: Int8, _ __sf_result: Int8) -> Bool { ({ $0 == n })(__sf_result) }
        #sourceLocation()

        func liftWrong(_ club: Club, _ n: Int8) -> Int8 {
            if !(club != .driver) { SwiftFormal.Contract.requiresFailed("club != .driver") }
            let __sf_result: Int8 = { () -> Int8 in club == .putter ? n &+ 1 : n }()
            if !(({ $0 == n })(__sf_result)) { SwiftFormal.Contract.ensuresFailed("{ $0 == n }") }
            return __sf_result
        }
        #sourceLocation(file: "@__swiftmacro_3App9liftWrong6VerifyfMp_.swift", line: 1)
        func liftWrong_requires(_ club: Club, _ n: Int8) -> Bool { (club != .driver) }
        func liftWrong_ensures(_ club: Club, _ n: Int8, _ __sf_result: Int8) -> Bool { ({ $0 == n })(__sf_result) }
        #sourceLocation()
        """

    @Test func equalityOnAStringBackedEnumIsReadInContracts() throws {
        let report = try VerifyContractScanTests.scan(Self.rawValueEnumApp)
        func fn(_ name: String) throws -> FunctionReport { try #require(report.functions.first { $0.name.hasPrefix(name + "(") }) }
        let pick = try fn("pick")
        #expect(pick.status == .contractHolds, "\(pick)")
        let pickWrong = try fn("pickWrong")
        #expect(pickWrong.status == .contractFails, "\(pickWrong)")
        #expect(pickWrong.counterexample?.failure.hasPrefix("ensures failed: { $0 == .iron }") == true, "\(pickWrong)")
        let lift = try fn("lift")
        #expect(lift.status == .contractHolds, "\(lift)")
        let liftWrong = try fn("liftWrong")
        #expect(liftWrong.status == .contractFails, "\(liftWrong)")
    }
}

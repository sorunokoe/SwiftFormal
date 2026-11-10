import Foundation
import SFVerifyKit
import Testing

/// `sfverify --mutate`: a contract that holds is checked again on small edits of its function, and reported as weak
/// when an edit that changes what the function does still satisfies it. Verdicts never change.
private enum StrengthFixture {
    /// The shape of the app's `ValuesState.discardEdit` (app study round 6), with integer texts: the weak contract says
    /// nothing about the loaded case, so deleting the restore (`case .loaded: break`) still satisfied it.
    static let source = """
        public struct Values: Equatable {
            public var altitude: Int8
            public var temperature: Int8
        }
        public enum Data: Equatable {
            case loading
            case loaded(Values)
            case failed
        }
        public struct State {
            public var data: Data
            public var tile: Int8
            public var altitudeText: Int8
            public var temperatureText: Int8

            public mutating func show(_ values: Values) {
                altitudeText = values.altitude
                temperatureText = values.temperature
            }

            public mutating func discardEdit() {
                switch data {
                case let .loaded(values): show(values)
                case .loading, .failed: break
                }
            }
            #sourceLocation(file: "@__swiftmacro_3App11discardEdit6VerifyfMp_.swift", line: 1)
            public func discardEdit_ensures(old: State) -> Bool {
                guard data == old.data, tile == old.tile else { return false }
                guard case .loaded = data else { return altitudeText == old.altitudeText && temperatureText == old.temperatureText }
                return true
            }
            #sourceLocation()

            // What `@Verify` writes: the body runs in a closure that captures `self`.
            public mutating func discardEditVerified() {
                let __sf_result: Void = { () -> Void in
                    switch data {
                    case let .loaded(values): show(values)
                    case .loading, .failed: break
                    }
                }()
                return __sf_result
            }
            #sourceLocation(file: "@__swiftmacro_3App19discardEditVerified6VerifyfMp_.swift", line: 1)
            public func discardEditVerified_ensures(old: State) -> Bool {
                guard data == old.data, tile == old.tile else { return false }
                guard case .loaded = data else { return altitudeText == old.altitudeText && temperatureText == old.temperatureText }
                return true
            }
            #sourceLocation()

            public mutating func restore() {
                switch data {
                case let .loaded(values): show(values)
                case .loading, .failed: break
                }
            }
            #sourceLocation(file: "@__swiftmacro_3App7restore6VerifyfMp_.swift", line: 1)
            public func restore_ensures(old: State) -> Bool {
                guard data == old.data, tile == old.tile else { return false }
                guard case let .loaded(v) = old.data else {
                    return altitudeText == old.altitudeText && temperatureText == old.temperatureText
                }
                return altitudeText == v.altitude && temperatureText == v.temperature
            }
            #sourceLocation()
        }

        // Contracts that are exactly the output: no edit that changes the result can satisfy them.
        public func twice(_ x: Int8) -> Int8 { x &+ x }
        #sourceLocation(file: "@__swiftmacro_3App5twice6VerifyfMp_.swift", line: 1)
        public func twice_ensures(_ x: Int8, _ r: Int8) -> Bool { r == x &+ x }
        #sourceLocation()
        public func clamp(_ x: Int8, _ lo: Int8, _ hi: Int8) -> Int8 {
            if x < lo { return lo }
            if x > hi { return hi }
            return x
        }
        #sourceLocation(file: "@__swiftmacro_3App5clamp6VerifyfMp_.swift", line: 1)
        public func clamp_requires(_ x: Int8, _ lo: Int8, _ hi: Int8) -> Bool { lo <= hi }
        public func clamp_ensures(_ x: Int8, _ lo: Int8, _ hi: Int8, _ r: Int8) -> Bool { r == (x < lo ? lo : x > hi ? hi : x) }
        #sourceLocation()
        public func isAdult(_ age: UInt8) -> Bool { age >= 18 }
        #sourceLocation(file: "@__swiftmacro_3App7isAdult6VerifyfMp_.swift", line: 1)
        public func isAdult_ensures(_ age: UInt8, _ r: Bool) -> Bool { r == (age >= 18) }
        #sourceLocation()

        // Only a range: returning `lo` is as good as the real result.
        public func bound(_ x: Int8, _ lo: Int8, _ hi: Int8) -> Int8 {
            if x < lo { return lo }
            if x > hi { return hi }
            return x
        }
        #sourceLocation(file: "@__swiftmacro_3App5bound6VerifyfMp_.swift", line: 1)
        public func bound_requires(_ x: Int8, _ lo: Int8, _ hi: Int8) -> Bool { lo <= hi }
        public func bound_ensures(_ x: Int8, _ lo: Int8, _ hi: Int8, _ r: Int8) -> Bool { r >= lo && r <= hi }
        #sourceLocation()

        // Only the putter is pinned: the driver and the iron can trade lofts.
        public enum Club { case driver, iron, putter, wedge }
        public func loft(_ club: Club) -> Int8 {
            switch club {
            case .driver: 10
            case .iron: 30
            case .putter: 3
            case .wedge: 50
            }
        }
        #sourceLocation(file: "@__swiftmacro_3App4loft6VerifyfMp_.swift", line: 1)
        public func loft_ensures(_ club: Club, _ r: Int8) -> Bool { club == .putter ? r < 5 : r >= 5 }
        #sourceLocation()

        // Both branches do the same: negating the condition changes nothing, so that edit is not reported.
        public func either(_ flag: Bool, _ x: Int8) -> Int8 {
            if flag { return x &+ 1 } else { return x &+ 1 }
        }
        #sourceLocation(file: "@__swiftmacro_3App6either6VerifyfMp_.swift", line: 1)
        public func either_ensures(_ flag: Bool, _ x: Int8, _ r: Int8) -> Bool { r != x }
        #sourceLocation()
        """

    static func run(mutate: Bool) throws -> ScanReport {
        let dir = NSTemporaryDirectory() + "sfv-strength-\(UUID().uuidString)"
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: dir) }
        let file = dir + "/state.swift"
        try source.write(toFile: file, atomically: true, encoding: .utf8)
        var options = VerifyOptions()
        options.configurations = [.debug]
        options.mutate = mutate
        return try SFVerify.run(CompileOptions(files: [file], moduleName: "Strength"), options)
    }

    static let mutated = Result { try run(mutate: true) }
    static let plain = Result { try run(mutate: false) }

    static func function(_ name: String, in report: ScanReport) throws -> FunctionReport {
        try #require(report.functions.first { $0.name.hasPrefix(name + "(") })
    }
}

@Suite struct ContractStrengthTests {
    @Test func aContractThatSaysNothingAboutTheLoadedCaseIsWeak() throws {
        let f = try StrengthFixture.function("State.discardEdit", in: try StrengthFixture.mutated.get())
        #expect(f.status == .contractHolds, "--mutate never changes a verdict")
        let weak = try #require(f.weakContract)
        let skipped = try #require(weak.survivors.first { $0.kind == "skippedCall" })
        #expect(skipped.mutation == "the call to State.show(_:) is skipped")
        #expect(skipped.at?.line == 23)
        #expect(skipped.mayBeEquivalent == nil, "integers: the difference is exact")
        let differsOn = try #require(skipped.differsOn)
        #expect(differsOn.count == 1 && differsOn[0].hasPrefix("self = State(data: .loaded("))
        #expect(weak.mutantsTried >= 1)
    }

    @Test func anEditInsideTheClosureOfAVerifyBodyIsFound() throws {
        let f = try StrengthFixture.function("State.discardEditVerified", in: try StrengthFixture.mutated.get())
        #expect(f.status == .contractHolds)
        let mutations = f.weakContract?.survivors.map(\.mutation) ?? []
        #expect(mutations.contains("closure #1 in State.discardEditVerified() is skipped (under @Verify, the whole body)"), "\(mutations)")
        let skipped = try #require(f.weakContract?.survivors.first { $0.mutation == "the call to State.show(_:) is skipped" })
        #expect(skipped.at == nil, "the closure's debug positions are not kept")
        #expect(skipped.differsOn != nil)
    }

    @Test func aContractThatRestoresTheTextsIsNotWeak() throws {
        let f = try StrengthFixture.function("State.restore", in: try StrengthFixture.mutated.get())
        #expect(f.status == .contractHolds)
        #expect(f.weakContract == nil, "\(f.weakContract?.survivors.map(\.mutation) ?? [])")
    }

    @Test func aContractThatIsExactlyTheOutputHasNoSurvivor() throws {
        let report = try StrengthFixture.mutated.get()
        for name in ["twice", "clamp", "isAdult"] {
            let f = try StrengthFixture.function(name, in: report)
            #expect(f.status == .contractHolds, "\(name)")
            #expect(f.weakContract == nil, "\(name): \(f.weakContract?.survivors.map(\.mutation) ?? [])")
        }
    }

    @Test func aRangeContractLetsAnotherResultThrough() throws {
        let f = try StrengthFixture.function("bound", in: try StrengthFixture.mutated.get())
        let mutations = f.weakContract?.survivors.map(\.mutation) ?? []
        #expect(mutations.contains("it returns lo instead"), "\(mutations)")
    }

    @Test func twoCasesThatTheContractDoesNotTellApartCanSwap() throws {
        let f = try StrengthFixture.function("loft", in: try StrengthFixture.mutated.get())
        let mutations = f.weakContract?.survivors.map(\.mutation) ?? []
        #expect(mutations.contains("the cases .driver and .iron are swapped"), "\(mutations)")
        #expect(!mutations.contains("the cases .iron and .putter are swapped"), "the contract pins the putter")
    }

    @Test func anEditThatChangesNothingIsNotReported() throws {
        let f = try StrengthFixture.function("either", in: try StrengthFixture.mutated.get())
        let weak = try #require(f.weakContract, "`&+ 1` becoming `&- 1` (or the constant 2) still satisfies r != x")
        #expect(!weak.survivors.contains { $0.kind == "negatedBranch" }, "\(weak.survivors.map(\.mutation))")
    }

    @Test func theTextNamesTheEditAndAnInputThatTellsThemApart() throws {
        let text = try StrengthFixture.mutated.get().text()
        let line = text.split(separator: "\n").first {
            $0.hasPrefix("      weak: the contract still holds when the call to State.show(_:) is skipped (")
        }
        #expect(line?.hasSuffix("/state.swift:23:35)") == true, "\(text)")
        #expect(text.contains("            the function and the edited one differ on self = State(data: .loaded("))
        #expect(text.contains("weak: an edit of the code still satisfies it)"))
    }

    @Test func withoutMutateNothingChanges() throws {
        let plain = try StrengthFixture.plain.get(), mutated = try StrengthFixture.mutated.get()
        #expect(plain.functions.map(\.status) == mutated.functions.map(\.status))
        #expect(plain.functions.allSatisfy { $0.weakContract == nil })
        #expect(plain.summary.weakContracts == nil)
        #expect(mutated.summary.weakContracts == 5)
        let json = try plain.json()
        #expect(!json.contains("weakContract"))
        #expect(!plain.text().contains("weak"))
    }
}

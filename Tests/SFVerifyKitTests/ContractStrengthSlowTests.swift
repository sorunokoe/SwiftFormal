import Foundation
import SFVerifyKit
import Testing

/// `sfverify --mutate` on the shape the app really has: texts made from the loaded values. With `String(_:)` of an
/// integer (its decimal text is known since the string facts) the dropped restore is a definite survivor with an input;
/// with a text logic does not model (a number mixed with a literal) it is still reported, as one that may differ,
/// with the reason. Slow: the texts make each proof take seconds in a debug build.
@Suite struct ContractStrengthSlowTests {
    static let source = """
        public struct Values: Equatable {
            public var altitude: Int
            public var temperature: Int
        }
        public enum Data: Equatable {
            case loading
            case loaded(Values)
            case failed
        }
        public struct State {
            public var data: Data
            public var altitudeText: String
            public var temperatureText: String

            public mutating func show(_ values: Values) {
                altitudeText = String(values.altitude)
                temperatureText = String(values.temperature)
            }

            public mutating func discardEdit() {
                switch data {
                case let .loaded(values): show(values)
                case .loading, .failed: break
                }
            }
            #sourceLocation(file: "@__swiftmacro_3App11discardEdit6VerifyfMp_.swift", line: 1)
            public func discardEdit_ensures(old: State) -> Bool {
                guard data == old.data else { return false }
                guard case .loaded = data else { return altitudeText == old.altitudeText && temperatureText == old.temperatureText }
                return true
            }
            #sourceLocation()
        }
        """

    static func discardEdit(_ source: String, module: String) throws -> (FunctionReport, String) {
        let dir = NSTemporaryDirectory() + "sfv-strength-texts-\(UUID().uuidString)"
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: dir) }
        let file = dir + "/texts.swift"
        try source.write(toFile: file, atomically: true, encoding: .utf8)
        var options = VerifyOptions()
        options.configurations = [.debug]
        options.mutate = true
        let report = try SFVerify.run(CompileOptions(files: [file], moduleName: module), options)
        let f = try #require(report.functions.first { $0.name.hasPrefix("State.discardEdit(") })
        return (f, report.text())
    }

    @Test func aDroppedRestoreOfDecimalTextsDiffersOnAnInput() throws {
        let (f, text) = try Self.discardEdit(Self.source, module: "Texts")
        #expect(f.status == .contractHolds)
        let skipped = try #require(f.weakContract?.survivors.first { $0.mutation == "the call to State.show(_:) is skipped" })
        #expect(skipped.mayBeEquivalent != true, "\(skipped)")
        #expect(skipped.differsOn?.first?.hasPrefix("self = State(data: .loaded(") == true, "\(skipped)")
        #expect(text.contains("            the function and the edited one differ on self = State(data: .loaded("), "\(text)")
    }

    @Test func aDroppedRestoreOfTextsMayDifferAndSaysWhy() throws {
        let mixed = Self.source
            .replacingOccurrences(of: "altitudeText = String(values.altitude)", with: "altitudeText = \"\\(values.altitude) m\"")
            .replacingOccurrences(
                of: "temperatureText = String(values.temperature)", with: "temperatureText = \"\\(values.temperature) °\"")
        #expect(mixed != Self.source)
        let (f, text) = try Self.discardEdit(mixed, module: "MixedTexts")
        #expect(f.status == .contractHolds)
        let skipped = try #require(f.weakContract?.survivors.first { $0.mutation == "the call to State.show(_:) is skipped" })
        #expect(skipped.mayBeEquivalent == true, "\(skipped)")
        #expect(skipped.reason?.contains("which logic does not model") == true, "\(String(describing: skipped.reason))")
        #expect(text.contains("            the function and the edited one may differ on self = State(data: .loaded("), "\(text)")
    }
}

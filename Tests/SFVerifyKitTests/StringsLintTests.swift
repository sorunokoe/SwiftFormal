import Foundation
import SFVerifyKit
import Testing

/// `swiftformal strings` on `Fixtures/Strings`: a `.lproj` table (`.strings` and `.stringsdict`) in en and da, and
/// an `.xcstrings` catalogue in en, de and da, each with planted problems.
@Suite struct StringsLintTests {
    static let fixtures = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("Fixtures/Strings")
    static let report = StringsLint.run(
        paths: [fixtures.appendingPathComponent("Catalogues").path], sources: [fixtures.appendingPathComponent("Sources").path])

    static func problems(_ kind: StringsLint.Kind) -> [String] {
        report.problems.filter { $0.kind == kind }.map { "\($0.key)[\($0.language ?? "")]" }.sorted()
    }

    @Test func countsTablesKeysAndLanguages() {
        #expect(Self.report.tables == 2)
        // The stale key of the catalogue is not counted.
        #expect(Self.report.keys == 9)
        #expect(Self.report.languages == 3)
        #expect(Self.report.count(.unreadable) == 0)
    }

    @Test func aKeyMissingInOneLanguage() {
        // A sentence key with no source-language text shows itself, so "Play %lld holes" is not missing in en.
        #expect(Self.problems(.missing) == ["greeting[da]", "menu.title[da]"])
    }

    @Test func formatArgumentsThatDisagree() {
        let format = Self.report.problems.filter { $0.kind == .format }
        #expect(Self.problems(.format) == ["Play %lld holes[da]", "holes.count[da]", "score.format[da]", "score.format[da]"])
        // The reference of a sentence key is the key itself; a plural form may read fewer arguments ("Ein Schlag").
        #expect(format.contains { $0.key == "Play %lld holes" && $0.detail.contains("reads 2 argument(s), en reads 1") })
        #expect(format.contains { $0.key == "score.format" && $0.detail.contains("argument 1 is read as an object (%@)") })
        #expect(format.contains { $0.key == "holes.count" && $0.detail.contains("an object") })
    }

    @Test func aTextThatIsItsKey() {
        // A stale key's text is its key too, but it is not checked.
        #expect(Self.problems(.textIsKey) == ["club.iron[da]"])
    }

    @Test func sourceKeysNoCatalogueHas() {
        #expect(Self.problems(.unknownKey) == ["club.wedge[]", "missing.key[]"])
    }

    @Test func aCleanTableHasNoProblems() {
        let clean = Self.fixtures.appendingPathComponent("Catalogues/Catalogue.xcstrings").path
        let report = StringsLint.run(paths: [clean])
        #expect(report.problems.map(\.key).sorted() == ["Play %lld holes", "menu.title"])
    }
}

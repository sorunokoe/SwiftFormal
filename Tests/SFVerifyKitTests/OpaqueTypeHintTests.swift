import Foundation
import SFVerifyKit
import Testing

/// App study round 6, L10 and L3: a type Scan cannot read (here `Data`; in the app `URL`, `UUID`, SwiftUI's `Color`, a type of a binary
/// framework) got "pass the fields the arithmetic needs", also where no arithmetic is involved, and a stored field deep
/// inside `self` was not placed ("BagStore.State.showTabs.getter … — type Color" with no `at`). The hint says the
/// value is opaque and what to do; `typePath` names the field.
@Suite struct OpaqueTypeHintTests {
    static let source = """
        import Foundation

        struct Style { var weight: Int8; var link: Data }
        struct Tab { var title: Int8; var style: Style }
        enum Loading { case idle, loaded(Tab) }
        struct BagState {
            var count: Int8
            var others: [Tab]
            var main: Tab
            var showTabs: Bool { count > 1 }
        }
        struct Screen {
            var state: Loading
            var isIdle: Bool { if case .idle = state { true } else { false } }
        }
        func opened(_ link: Data, _ times: Int8) -> Int8 { times }
        """

    @Test func aStoredOpaqueFieldIsPlacedAndTheHintFitsIt() throws {
        let report = try ExplainTests.scan(Self.source)
        let tabs = try #require(report.functions.first { $0.name == "BagState.showTabs.getter" })
        #expect(tabs.status == .unsupported && tabs.category == "type Data", "\(tabs.status) \(tabs.category ?? "")")
        #expect(tabs.typePath == "self.main.style.link: Data", "\(tabs.typePath ?? "nil")")
        let hint = try #require(tabs.hint)
        #expect(!hint.contains("arithmetic"), "\(hint)")
        #expect(hint.hasPrefix("blocked by field 'main.style.link' of type Data."), "\(hint)")
        #expect(hint.contains("Scan cannot read Data") && hint.contains("walk"), "\(hint)")

        let screen = try #require(report.functions.first { $0.name == "Screen.isIdle.getter" })
        #expect(screen.typePath == "self.state.loaded.style.link: Data", "\(screen.typePath ?? "nil")")

        let text = report.text(showUnsupported: true)
        #expect(text.contains("      where: self.main.style.link: Data"), "\(text)")
    }

    @Test func aParameterOfAnOpaqueTypeIsNamed() throws {
        let report = try ExplainTests.scan(Self.source)
        let opened = try #require(report.functions.first { $0.name.hasPrefix("opened(") })
        #expect(opened.category == "type Data")
        #expect(opened.typePath == "link: Data", "\(opened.typePath ?? "nil")")
        #expect(opened.hint?.hasPrefix("blocked by parameter 'link' of type Data.") == true, "\(opened.hint ?? "nil")")
    }

    @Test func theTypeHintNamesNoArithmetic() {
        let hint = Verifier.hint(forCategory: "type UUID")
        #expect(hint.contains("Scan cannot read UUID") && hint.contains("`Prove`") && !hint.contains("arithmetic"), "\(hint)")
    }

    /// L10: the hint of every unsupported result that a type blocks names the field path to it, in the form
    /// "blocked by field 'model.player.photo' of type Data", also when the type has a category of its own
    /// (here a class, "classes and objects").
    static let blocked = """
        import Foundation

        struct Player { var photo: Data; var rating: Int8 }
        struct Model { var player: Player; var rounds: Int8 }
        struct Card { var model: Model; var holes: Int8 { model.rounds &+ 1 } }
        final class Cache { var hits: Int8 = 0 }
        struct Forecast { var cache: Cache; var rain: Int8 }
        struct Sky { var forecast: Forecast; var wind: Int8 }
        func calm(_ sky: Sky) -> Bool { sky.wind < 3 }
        """

    @Test func theHintNamesTheBlockingFieldPath() throws {
        let report = try ExplainTests.scan(Self.blocked)
        let card = try #require(report.functions.first { $0.name == "Card.holes.getter" })
        #expect(card.status == .unsupported, "\(card)")
        #expect(card.hint?.hasPrefix("blocked by field 'model.player.photo' of type Data.") == true, "\(card.hint ?? "nil")")

        let calm = try #require(report.functions.first { $0.name.hasPrefix("calm(") })
        #expect(calm.status == .unsupported && calm.category == "classes and objects", "\(calm)")
        #expect(calm.typePath == "sky.forecast.cache: Cache", "\(calm.typePath ?? "nil")")
        #expect(calm.hint?.hasPrefix("blocked by field 'sky.forecast.cache' of type Cache.") == true, "\(calm.hint ?? "nil")")

        let check = Check.merge(scans: [report], plan: Check.plan(scans: [report], walks: []), records: [], knownIssues: [])
        let text = check.text(showUnchecked: true)
        #expect(text.contains("  · calm(_:) — logic: classes and objects, blocked by field 'sky.forecast.cache' of type Cache"), "\(text)")
    }
}

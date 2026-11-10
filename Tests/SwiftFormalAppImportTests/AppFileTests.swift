// An app file: SwiftUI, Foundation, Combine and Observation (UIKit where it exists) next to `import SwiftFormal`, built
// with the package's strict settings (`MemberImportVisibility`, `InternalImportsByDefault`, `ExistentialAny`). It is a
// compile test: SwiftUI's `Image(systemName:)` and `Table` must not be ambiguous with a SwiftFormal name (pre-release builds had a
// top-level `Table` and `Image`), and `@Verify` must work there. AppNames.swift holds the app's own types.
#if canImport(SwiftUI)
    import Combine
    import Foundation
    import Observation
    import SwiftFormal
    import SwiftUI
    import Testing
    #if canImport(UIKit)
        import UIKit
    #endif

    struct Rule: Identifiable {
        let id: Int
        let title: String

        @Verify
        static func badge(_ urgent: Bool) -> String {
            #ensures { !$0.isEmpty }
            urgent ? "!" : "·"
        }
    }

    @available(macOS 14, iOS 17, *)
    @Observable final class RulesModel {
        var rules: [Rule] = [Rule(id: 1, title: "Grass")]
        let changes = PassthroughSubject<Int, Never>()
    }

    @available(macOS 14, iOS 17, *)
    struct RulesView: View {
        let model: RulesModel

        var body: some View {
            VStack {
                Image(systemName: "flag")
                Table(model.rules) {
                    TableColumn("Rule", value: \.title)
                }
                .framed()
                Text(Rule.badge(model.rules.isEmpty))
            }
        }
    }

    // `Table` in a type position: before 0.1.0 this was "ambiguous for type lookup" (SwiftFormal had a `Table` too).
    @available(macOS 14, iOS 17, *)
    extension Table {
        func framed() -> some View { padding() }
    }

    @Suite struct AppFileTests {
        @Test func swiftUINamesAndVerifyLiveInOneFile() {
            let image: Image = Image(systemName: "flag")
            _ = image
            #expect(Rule.verify_badge().isProved)
            #expect(Rule.badge_ensures(true, "!"))
        }
    }
#endif

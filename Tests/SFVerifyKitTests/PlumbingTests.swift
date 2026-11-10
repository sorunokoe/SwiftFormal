import Foundation
import Testing

@testable import SFVerifyKit

/// App study round 6, item 7: in app code most `unsupported` functions are plumbing (property wrappers, dependency
/// injection, view bodies), not logic. The summary counts them as their own group; no verdict changes.
@Suite struct PlumbingTests {
    private static func unsupported(
        _ name: String, symbol: String? = nil, category: String, detail: String? = nil, origin: String? = nil
    ) -> FunctionReport {
        var report = FunctionReport(
            name: name, symbol: symbol ?? "$s3App" + name, location: nil, status: .unsupported, category: category,
            detail: detail ?? "UNSUPPORTED: \(category)", counterexample: nil, hasContract: false, seconds: 0)
        report.origin = origin
        return report
    }

    private static let timing = ScanReport.Timing(compileSeconds: 0, parseSeconds: 0, verifySeconds: 0, silBytes: 0)

    @Test func propertyWrappersInjectionAndViewBodiesArePlumbing() throws {
        let identity =
            "UNSUPPORTED: apply: %26 = apply %25(%24) : $@convention(thin) @Sendable (@in_guaranteed AddModelStore.State) "
            + "-> @owned @callee_guaranteed (@guaranteed String, @guaranteed String) -> Bool"
        let plumbing = [
            Self.unsupported("AppDelegate._service.setter", category: "type Injected<AuthService>"),
            Self.unsupported("Settings.container.getter", category: "type Container"),
            Self.unsupported("Row.text.setter", category: "type Binding<String>"),
            Self.unsupported("Row._unit.getter", category: "type State<UnitSystem>"),
            Self.unsupported("Card._size.getter", category: "type Environment<DynamicTypeSize>"),
            Self.unsupported("BagView.store.getter", category: "type Store<BagStore.State, BagStore.Action>"),
            Self.unsupported("Picker._clock.setter", category: "type Dependency<any Clock<Duration>>"),
            Self.unsupported("Banner.body.getter", symbol: "$s7MainApp6BannerV4bodyQrvg", category: "type Injected<Component>"),
            Self.unsupported("Chart.body.getter", symbol: "$s7MainApp5ChartV4bodyQrvg", category: "closures"),
            Self.unsupported("AddModelStore.State.model.setter", category: "other", detail: identity),
        ]
        let logic = [
            Self.unsupported("Rule.body.getter", symbol: "$s3App4RuleV4bodySSvg", category: "type KmpDomainItem"),
            Self.unsupported("MyStore.reduce(into:action:)", category: "type MyStore.State"),
            Self.unsupported("parse(_:)", category: "strings"),
            Self.unsupported("Row.state(_:)", category: "type State"),
            Self.unsupported("load(_:)", category: "type Effect<Action>"),
        ]
        let generated = Self.unsupported("Model.count.setter", category: "type Binding<Int>", origin: "macro")
        let safe = FunctionReport(
            name: "half(_:)", symbol: "$s3App4halfyS2iF", location: nil, status: .safe, category: nil, detail: nil,
            counterexample: nil, hasContract: false, seconds: 0)
        let report = ScanReport(
            module: "App", optimization: "-Onone", functions: plumbing + logic + [generated, safe], timing: Self.timing)

        #expect(report.summary.plumbing == plumbing.count)
        #expect(report.summary.unsupported == plumbing.count + logic.count)
        #expect(report.summary.safe == 1)
        let text = report.text()
        #expect(text.contains("    \(plumbing.count) of them plumbing (property wrappers, dependency injection, view bodies)"), "\(text)")
        #expect(try report.json().contains("\"plumbing\" : \(plumbing.count)"))
    }

    @Test func withoutPlumbingTheKeyAndTheLineAreAbsent() throws {
        let report = ScanReport(
            module: "App", optimization: "-Onone", functions: [Self.unsupported("parse(_:)", category: "strings")], timing: Self.timing)
        #expect(report.summary.plumbing == nil)
        #expect(!report.text().contains("plumbing"))
        #expect(try !report.json().contains("plumbing"))
    }
}

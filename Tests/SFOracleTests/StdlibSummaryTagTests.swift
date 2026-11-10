import Foundation
import SFSIL
import SFTestSupport
import Testing

/// Plan item R9: every standard-library entry of `StdlibSummary.table` expects exactly the `[_semantics "…"]` tags the
/// pinned compiler prints on it. `tools/summary-probe/probe.swift` calls every entry, so a new entry the probe does not
/// call fails here too (plan item R6 uses the same probe).
@Suite(.tags(.oracle), .requiresPinnedCompiler) struct StdlibSummaryTagTests {
    static let probe = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("tools/summary-probe/probe.swift")

    /// Internal standard-library functions that user code never calls at `-Onone`, so the probe cannot print them.
    static let notCallable: Set<String> = ["$sSa9_getCountSiyF"]

    @Test func theTableExpectsExactlyThePrintedTags() throws {
        let source = try String(contentsOf: Self.probe, encoding: .utf8)
        let text = try SILCompiler.emit(source: source, module: "Probe", optimization: .none)
        let module = try SILModule(text: text)
        let stdlib = StdlibSummary.table.filter { !$0.key.hasPrefix("$s22ComposableArchitecture") }
        #expect(stdlib.count >= 50)
        for (symbol, entry) in stdlib.sorted(by: { $0.key < $1.key }) where !Self.notCallable.contains(symbol) {
            #expect(text.contains("@\(symbol) : "), "the probe does not call \(entry.name) (\(symbol))")
            #expect(module.semanticsTags(of: symbol) == entry.semantics, "\(entry.name) (\(symbol))")
        }
    }
}

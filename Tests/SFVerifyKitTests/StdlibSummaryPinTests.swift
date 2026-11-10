import Foundation
import SFSIL
import Testing

/// Plan item R6: every standard-library row of the summary table is pinned in `Scripts/baseline/stdlib-summaries.json`
/// (`Scripts/check-summary-pin.py`), and nothing else is. A new row fails here until the pin is regenerated and
/// reviewed; the script reads the table with a regular expression, so this also checks that it reads every row.
@Suite struct StdlibSummaryPinTests {
    static let baseline = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("Scripts/baseline/stdlib-summaries.json")

    private struct Pin: Decodable {
        let entries: [String: PinEntry]
    }

    private struct PinEntry: Decodable { let name: String }

    @Test func thePinCoversExactlyTheStandardLibraryRows() throws {
        let pin = try JSONDecoder().decode(Pin.self, from: Data(contentsOf: Self.baseline))
        let rows = StdlibSummary.table.filter { !$0.key.hasPrefix("$s22ComposableArchitecture") }
        #expect(Set(pin.entries.keys) == Set(rows.keys))
        for (symbol, entry) in rows { #expect(pin.entries[symbol]?.name == entry.name, "\(symbol)") }
    }
}

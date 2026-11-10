import SwiftFormal
import Testing

// An app's own types with the names of SwiftFormal's walk API. A declaration in the app's module shadows an imported
// one, so the app keeps its names; the code `@Verify` writes names `SwiftFormal.Report`, `SwiftFormal.Domain`, … so the
// app's types never capture it.

struct Report { let title: String }
struct Property { let address: String }
struct Domain { let host: String }
struct Budget { let cents: Int }
struct Contract { let signed: Bool }
enum Verdict { case guilty, notGuilty }
struct Partition { let size: Int }
struct Checked { let at: Int }
struct Matches { let count: Int }
struct Outputs { let channels: Int }
struct Counterexample { let note: String }

@Verify(over: .int(0...100))
func cents(_ euros: Int) -> Int {
    #requires(euros >= 0)
    #ensures { $0 == euros * 100 }
    euros * 100
}

@Suite struct AppNamesTests {
    @Test func theAppsOwnTypesWinAndVerifyStillWorks() {
        let report = Report(title: "Q3")
        let budget = Budget(cents: cents(3))
        #expect(report.title == "Q3" && budget.cents == 300)
        let walk: SwiftFormal.Report = verify_cents()
        #expect(walk.isProved, "\(walk)")
        _ = (Property(address: ""), Domain(host: ""), Contract(signed: true), Verdict.guilty, Partition(size: 0))
        _ = (Checked(at: 0), Matches(count: 0), Outputs(channels: 0), Counterexample(note: ""))
    }
}

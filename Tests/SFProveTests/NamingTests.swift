import SFProve
import SwiftFormal
import Testing

@Suite struct VocabularyTests {
    @Test func bothVerdictsCanBeNamedInOneFile() {
        let walked: Verdict = .proved(checked: 3)
        let proven: ProofVerdict = .proved
        #expect(walked.isProved)
        #expect(proven == .proved)
    }
}

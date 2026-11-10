import SFSIL
import SFVerifyKit
import Testing

/// Plan item L13: the coverage table files each refusal under the construct that caused it.
@Suite struct UnsupportedCategoryTests {
    @Test func dictionariesAreNotArraysAndArraysOfExistentialsAreArrays() {
        let note = SILError.supportedTypesNote
        #expect(Verifier.category(of: .unsupported("type [String : Int]\(note)")) == "dictionaries and sets")
        #expect(Verifier.category(of: .unsupported("type [String : [Int]]\(note)")) == "dictionaries and sets")
        #expect(Verifier.category(of: .unsupported("type [Int]\(note)")) == "arrays")
        #expect(Verifier.category(of: .unsupported("type [(a: Int, b: Int)]\(note)")) == "arrays")
        #expect(
            Verifier.category(
                of: .unsupported("array of any P: destroying its elements may run code of this module (classes, closures, existentials)"))
                == "arrays")
    }
}

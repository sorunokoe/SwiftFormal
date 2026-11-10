import SwiftFormal
import Testing

enum Tab: CaseIterable, Finite { case recent, saved }

@Verify(over: .product(.int(-1...3), .int(-1...3)))
func initialTab(recent: Int, saved: Int) -> Tab {
    #ensures { recent <= 0 || $0 == .recent }
    if recent > 0 {
        .recent
    } else if saved > 0 {
        .saved
    } else {
        .recent
    }
}

@Verify(over: .int(0...3))
func name(of index: Int) -> String {
    #requires(index >= 0)
    switch index {
    case 0: "zero"
    case 1: "one"
    default: "many"
    }
}

@Verify(over: .int(0...3))
func doubled(_ x: Int) -> Int {
    #requires(x >= 0)
    #ensures { $0 >= x }
    x * 2
}

@Suite struct ImplicitReturnTests {
    @Test func aSingleExpressionBodyNeedsNoReturn() {
        #expect(verify_initialTab().isProved)
        #expect(verify_name().isProved)
        #expect(verify_doubled().isProved)
        #expect(name(of: 1) == "one")
    }
}

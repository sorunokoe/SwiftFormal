import SFSIL
import Testing

/// A block that ends in `unreachable` is a trap only behind a known failure: a call to a standard-library failure
/// function, or a `cond_fail` on a literal true (optimized code). A `cond_fail` that can never fire does not make the
/// `unreachable` a trap (found by the mutation lane, plan item V6, mutant M13).
@Suite struct SILFailureBlockTests {
    private static func parse(condition: String) throws -> SILFunction {
        let text = """
            sil_stage canonical

            sil @f : $@convention(thin) () -> () {
            bb0:
              %0 = integer_literal $Builtin.Int1, \(condition)
              cond_fail %0, "failure"
              unreachable
            }
            """
        return try SILModule(text: text).function("f")
    }

    @Test func aCondFailOnLiteralTrueBeforeUnreachableIsATrap() throws {
        _ = try Self.parse(condition: "-1")
        _ = try Self.parse(condition: "1")
    }

    @Test func aCondFailThatNeverFiresDoesNotMakeUnreachableATrap() {
        #expect {
            _ = try Self.parse(condition: "0")
        } throws: { error in
            guard case SILError.unsupported(let reason) = error else { return false }
            return reason.contains("unreachable without a known failure")
        }
    }
}

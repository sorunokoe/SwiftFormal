import SFSIL
import Testing

/// Plan item V8: shapes the compiler really prints that the reader does not model are `unsupported`, never `invalid`
/// (which reads as a bug in the tool).
@Suite struct RealOutputIsUnsupportedNotInvalidTests {
    private static func error(_ body: String, signature: String) -> SILError? {
        let text = """
            sil_stage canonical

            sil @f : $@convention(thin) \(signature) {
            \(body)
            }
            """
        do {
            let module = try SILModule(text: text)
            _ = try module.function("f")
            return nil
        } catch let error as SILError {
            return error
        } catch {
            return nil
        }
    }

    @Test func aGenericBuiltinAndSeveralOutResultsAreUnsupported() {
        let generic = Self.error(
            "bb0:\n  %1 = builtin \"sizeof\"<Int>() : $Builtin.Word\n  %2 = tuple ()\n  return %2", signature: "() -> ()")
        guard case .unsupported(let reason)? = generic else {
            Issue.record("generic builtin gave \(String(describing: generic))")
            return
        }
        #expect(reason.contains("generic builtin sizeof"))
        let two = Self.error(
            "bb0(%0 : $*Int, %1 : $*Int):\n  %2 = tuple ()\n  return %2", signature: "() -> (@out Int, @out Int)")
        guard case .unsupported(let why)? = two else {
            Issue.record("two @out results gave \(String(describing: two))")
            return
        }
        #expect(why.contains("several @out results"))
    }
}

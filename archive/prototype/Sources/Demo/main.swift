import FormalSpec
import Foundation

// 1. The spec: small, pure, reviewable by a human. This is what you review,
//    not the thousands of lines an agent may generate around it.
let checkout = SpecModule("Checkout") {
    Function("applyDiscount", ("subtotal", .nat), ("discount", .nat)) { p in
        ifThen(p[1] <= p[0], p[0] - p[1], else: 0)
    }
    Function("capQuantity", ("requested", .nat), ("stock", .nat), ("maxPerOrder", .nat)) { p in
        min(p[0], min(p[1], p[2]))
    }
    Function("taxCents", ("amount", .nat), ("basisPoints", .nat)) { p in
        p[0] * p[1] / 10_000
    }

    Theorem("discount_never_exceeds_subtotal", ("s", .nat), ("d", .nat)) { v in
        call("applyDiscount", v[0], v[1]) <= v[0]
    }
    Theorem("valid_discount_is_exact", ("s", .nat), ("d", .nat)) { v in
        (v[1] <= v[0]) ==> equals(call("applyDiscount", v[0], v[1]) + v[1], v[0])
    }
    Theorem("never_sell_more_than_stock", ("q", .nat), ("st", .nat), ("m", .nat)) { v in
        call("capQuantity", v[0], v[1], v[2]) <= v[1] && call("capQuantity", v[0], v[1], v[2]) <= v[2]
    }
    // Non-linear arithmetic: automation alone is not enough here, so the proof
    // is written explicitly. This is the slot an AI agent fills in and Lean checks.
    Theorem(
        "tax_never_exceeds_amount", ("a", .nat), ("bps", .nat),
        proof: """
        by
          intro h
          unfold taxCents
          apply Nat.div_le_of_le_mul
          rw [Nat.mul_comm 10000 a]
          exact Nat.mul_le_mul_left a h
        """
    ) { v in
        (v[1] <= 10_000) ==> (call("taxCents", v[0], v[1]) <= v[0])
    }
}

// 2. "Production" code, e.g. written by an AI agent. Note the subtle bug.
func applyDiscountNaive(subtotal: Int, discount: Int) -> Int { subtotal - discount }
func applyDiscountFixed(subtotal: Int, discount: Int) -> Int { discount <= subtotal ? subtotal - discount : 0 }

// 3. Emit Lean.
let outputDir = URL(fileURLWithPath: CommandLine.arguments.dropFirst().first ?? "lean")
try FileManager.default.createDirectory(at: outputDir, withIntermediateDirectories: true)
let leanFile = outputDir.appendingPathComponent("Checkout.lean")
try LeanEmitter.emit(checkout).write(to: leanFile, atomically: true, encoding: .utf8)
print("Wrote \(leanFile.path)")

// 4. Differential testing: spec (proven in Lean) vs production Swift.
func asNat(_ x: Int) -> SpecInterpreter.Value { .nat(x < 0 ? UInt64.max : UInt64(x)) }
for (label, impl) in [("naive", applyDiscountNaive), ("fixed", applyDiscountFixed)] {
    let mismatch = try differentialTest(checkout, function: "applyDiscount", arity: 2) { args in
        asNat(impl(Int(args[0]), Int(args[1])))
    }
    if let mismatch {
        print("✗ applyDiscount (\(label)) disagrees with spec: \(mismatch)  (UInt64.max = negative result)")
    } else {
        print("✓ applyDiscount (\(label)) agrees with spec on 10,000 random inputs")
    }
}

// 5. Ask Lean's kernel to check every theorem.
let candidates = [ProcessInfo.processInfo.environment["HOME"].map { "\($0)/.elan/bin/lean" }, "/usr/local/bin/lean"]
if let lean = candidates.compactMap({ $0 }).first(where: FileManager.default.isExecutableFile(atPath:)) {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: lean)
    process.arguments = [leanFile.path]
    try process.run()
    process.waitUntilExit()
    print(process.terminationStatus == 0 ? "✓ Lean kernel accepted all theorems" : "✗ Lean rejected the file")
    exit(process.terminationStatus)
} else {
    print("Lean not found; install with elan to check proofs.")
}

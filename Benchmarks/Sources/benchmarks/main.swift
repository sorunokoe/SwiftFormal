import Foundation
// `@testable`: the walk functions are `package` (users walk with `Prove`), so this package, built with
// `-enable-testing`, reaches them as SwiftFormal's own tests do.
@testable import SwiftFormal
// `proveSigned` and `prove` of SFProve, which SwiftFormalTesting re-exports.
import SwiftFormalTesting

// Wall time of the workloads the performance work changed, best of `--repeat` runs (default 5).
// Wall time on a shared machine is noisy, so nothing compares these numbers; the deterministic gate is
// Scripts/metrics.py. Run in release (the rpath finds the Testing.framework that SwiftFormalTesting links):
// swift run -c release -Xswiftc -enable-testing -Xlinker -rpath \
//   -Xlinker "$(xcrun --show-sdk-platform-path)/Developer/Library/Frameworks" --package-path Benchmarks [--repeat N] [--only NAME]

let arguments = CommandLine.arguments
let repeats = arguments.firstIndex(of: "--repeat").flatMap { Int(arguments[$0 + 1]) } ?? 5
let only = arguments.firstIndex(of: "--only").map { arguments[$0 + 1] }

/// Keeps a result alive so the optimizer cannot drop the work that produced it.
@inline(never) func keep<T>(_ value: T) { withExtendedLifetime(value) {} }

/// An opaque function, so the walk measures its own overhead and not an inlined body.
@inline(never) func triple(_ x: Int) -> Int { x &* 3 }

func measure(_ name: String, _ body: () throws -> Void) rethrows {
    if let only, !name.contains(only) { return }
    let clock = ContinuousClock()
    var best = Duration.seconds(1_000_000)
    for _ in 0..<repeats {
        let start = clock.now
        try body()
        best = min(best, clock.now - start)
    }
    let milliseconds = Double(best.components.seconds) * 1000 + Double(best.components.attoseconds) / 1e15
    print(name.padding(toLength: 52, withPad: " ", startingAt: 0), String(format: "%10.2f ms", milliseconds))
}

print("SwiftFormal benchmarks (best of \(repeats), wall time, informational)")

measure("verify 1M inputs, no properties") {
    keep(runWalk("triple", triple, over: .int(0...999_999)))
}
measure("verify 1M inputs, two properties") {
    keep(
        runWalk("triple", triple, over: .int(0...999_999)) {
            Property.deterministic()
            Property.satisfies("multiple of 3") { _, y in y % 3 == 0 }
        })
}
measure("verify 1M inputs of a 3-field product") {
    keep(runWalk("sum", { (t: (Int, Int, Int)) in t.0 &+ t.1 &+ t.2 }, over: .product(.int(0...99), .int(0...99), .int(0...99))))
}
measure("verify 1M sampled inputs of a 10M domain") {
    keep(runWalk("triple", triple, over: .int(0...9_999_999)))
}
/// About a microsecond of dependent multiply-adds, so the walk's own cost is small next to the function's.
@Sendable @inline(never) func burn(_ x: Int) -> Int {
    var value = UInt64(truncatingIfNeeded: x) | 1
    for _ in 0..<1_200 { value = value &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407 }
    return Int(truncatingIfNeeded: value >> 1)
}
let cores = ProcessInfo.processInfo.activeProcessorCount
measure("verify 200k inputs, 1 us function, serial") {
    keep(runWalk("burn", burn, over: .int(0...199_999)) { Property.satisfies("non-negative") { _, y in y >= 0 } })
}
measure("verify 200k inputs, 1 us function, all cores") {
    keep(
        runWalk("burn", burn, over: .int(0...199_999), parallelism: .threads(cores)) {
            Property.satisfies("non-negative") { _, y in y >= 0 }
        })
}
measure("verifyContracts 100k inputs") {
    keep(
        _verifyContracts(
            "clamped",
            { (x: Int) -> Int in
                Contract.requires(x >= 0)
                return Contract.ensures(min(x, 500)) { $0 <= 500 }
            }, over: .int(0...99_999)))
}
measure("Contract.requires, 1M calls") {
    var total = 0
    for x in 0..<1_000_000 {
        Contract.requires(x >= 0)
        total &+= x
    }
    keep(total)
}
measure("Contract.requires, 1M calls, opaque condition") {
    var total = 0
    for x in 0..<1_000_000 {
        Contract.requires(triple(x) >= 0)
        total &+= x
    }
    keep(total)
}
measure("verify 1M inputs, int domain through 3 maps") {
    keep(runWalk("triple", triple, over: Domain<Int>.int(0...999_999).map { $0 &+ 1 }.map { $0 &- 1 }.map { $0 ^ 0 }))
}
measure("verify 1M inputs, struct domain (map of 2-product)") {
    struct Point { var x: Int; var y: Int }
    keep(
        runWalk(
            "sum", { (p: Point) in p.x &+ p.y },
            over: Domain<(Int, Int)>.product(.int(0...999), .int(0...999)).map { Point(x: $0.0, y: $0.1) }))
}
measure("verify 32k inputs of a union of 2,000 parts") {
    keep(runWalk("triple", triple, over: .union((0..<2_000).map { Domain<Int>.int($0 * 100...$0 * 100 + 15) })))
}
measure("partition 100k inputs into 20k outputs") {
    keep(runPartition({ (x: Int) in x % 20_000 }, over: .int(0...99_999)))
}
try measure("prove: 16-bit discount (proveSigned)") {
    keep(
        try proveSigned(
            widths: [16, 16],
            requires: { $0[0] >= 0 && $0[0] <= 300 && $0[1] >= 0 && $0[1] <= 100 }
        ) { v in
            let result = v[0] - v[0] * v[1] / 100
            return result >= 0 && result <= v[0]
        })
}
try measure("prove: 32-bit a*b == b*a up to 20k conflicts") {
    keep(try prove(inputWidths: [32, 32], conflictBudget: 20_000) { c, v in c.eq(c.mul(v[0], v[1]), c.mul(v[1], v[0])) })
}
measure("prove, 0-conflict budget: 64-bit a*b == b*a (encoding)") {
    keep(try? prove(inputWidths: [64, 64], conflictBudget: 0) { c, v in c.eq(c.mul(v[0], v[1]), c.mul(v[1], v[0])) })
}

import Foundation
import SFBV
import SFCNF
import SFProve
import SFSemantics
#if canImport(CryptoKit)
    import CryptoKit
#endif

// MARK: - hashing

package enum ProofDigest {
    /// "sha256" when CryptoKit is available, otherwise "fnv1a128-weak".
    package static var algorithm: String {
        #if canImport(CryptoKit)
            "sha256"
        #else
            "fnv1a128-weak"
        #endif
    }

    /// Hex digest of `text` prefixed with the algorithm name, so digests from different algorithms never compare equal.
    package static func hash(_ text: String) -> String {
        hash(bytes: Array(text.utf8))
    }

    /// Hex digest of `bytes`, like `hash(_:)`.
    package static func hash(bytes: [UInt8]) -> String {
        #if canImport(CryptoKit)
            return "sha256:" + SHA256.hash(data: bytes).map { hex($0, digits: 2) }.joined()
        #else
            return "fnv1a128-weak:" + fnv1a128(bytes)
        #endif
    }

    /// FNV-1a with a 128-bit state. **Weaker than SHA-256**: not collision resistant against an adversary, only against
    /// accidents. Used only where CryptoKit is missing; public so tests can check it against published vectors.
    package static func fnv1a128(_ bytes: [UInt8]) -> String {
        var hi: UInt64 = 0x6c62_272e_07bb_0142, lo: UInt64 = 0x62b8_2175_6295_c58d  // offset basis
        for byte in bytes {
            lo ^= UInt64(byte)
            // multiply by the prime 2^88 + 0x13B, modulo 2^128
            let (carry, low) = lo.multipliedFullWidth(by: 0x13B)
            hi = hi &* 0x13B &+ carry &+ (lo << 24)
            lo = low
        }
        return hex(hi, digits: 16) + hex(lo, digits: 16)
    }

    /// `value` in lowercase hexadecimal, zero-padded to `digits`: `String(format: "%02x")` without a C variadic call,
    /// which `-strict-memory-safety` reports (plan item H7).
    static func hex(_ value: some BinaryInteger, digits: Int) -> String {
        let text = String(value, radix: 16)
        return String(repeating: "0", count: max(0, digits - text.count)) + text
    }
}

// MARK: - compiler identity

package struct CompilerToolchain: Codable, Sendable, Equatable {
    /// Full output of `xcrun swiftc -version` (trimmed).
    package var swiftcVersion: String
    /// Output of `xcrun --show-sdk-version`.
    package var sdkVersion: String

    package init(swiftcVersion: String, sdkVersion: String) {
        self.swiftcVersion = swiftcVersion
        self.sdkVersion = sdkVersion
    }

    /// First non-empty line of the version output, whitespace collapsed: what a pin compares.
    package var versionLine: String {
        let line = swiftcVersion.split(separator: "\n").first { !$0.trimmingCharacters(in: .whitespaces).isEmpty } ?? ""
        return line.split(separator: " ", omittingEmptySubsequences: true).joined(separator: " ")
    }

    private static let detected = Result {
        try CompilerToolchain(
            swiftcVersion: runTool(["swiftc", "-version"]), sdkVersion: runTool(["--show-sdk-version"]))
    }

    /// The installed toolchain. Detected once per process.
    package static func installed() throws -> CompilerToolchain { try detected.get() }

    private static func runTool(_ arguments: [String]) throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/xcrun")
        process.arguments = arguments
        let out = Pipe()
        process.standardOutput = out
        process.standardError = FileHandle.nullDevice
        try process.run()
        let data = out.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        let text = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        guard process.terminationStatus == 0, !text.isEmpty else {
            throw ProofCacheError.toolFailed("xcrun \(arguments.joined(separator: " ")) exited with \(process.terminationStatus)")
        }
        return text
    }
}

/// Everything about the toolchain and the frontend that a verdict depends on besides the SIL itself.
package struct CompilerFingerprint: Codable, Sendable, Equatable {
    package var swiftcVersion: String
    package var sdkVersion: String
    /// "-O", "-Onone", or "-Onone+-O" for an equivalence query across two compilations.
    package var optimization: String
    package var encoderVersion: Int
    /// Hash of S0 and encoder behaviour on fixed batteries (see `SemanticsDigest`).
    package var semanticsDigest: String

    package init(
        swiftcVersion: String, sdkVersion: String, optimization: String,
        encoderVersion: Int = SILFrontendVersion.semantics, semanticsDigest: String = SemanticsDigest.current
    ) {
        self.swiftcVersion = swiftcVersion
        self.sdkVersion = sdkVersion
        self.optimization = optimization
        self.encoderVersion = encoderVersion
        self.semanticsDigest = semanticsDigest
    }

    package init(toolchain: CompilerToolchain, optimization: Optimization) {
        self.init(swiftcVersion: toolchain.swiftcVersion, sdkVersion: toolchain.sdkVersion, optimization: optimization.rawValue)
    }

    package init(toolchain: CompilerToolchain, optimizations: (Optimization, Optimization)) {
        self.init(
            swiftcVersion: toolchain.swiftcVersion, sdkVersion: toolchain.sdkVersion,
            optimization: "\(optimizations.0.rawValue)+\(optimizations.1.rawValue)")
    }

    /// The fingerprint for the installed compiler. Spawns `xcrun` on first use only.
    package static func current(optimization: Optimization) throws -> CompilerFingerprint {
        CompilerFingerprint(toolchain: try .installed(), optimization: optimization)
    }

    /// Unambiguous text form, used inside keys.
    package var canonical: String {
        [
            ("swiftc", swiftcVersion), ("sdk", sdkVersion), ("optimization", optimization),
            ("encoder", String(encoderVersion)), ("semantics", semanticsDigest),
        ]
        .map { "\($0.0)=\($0.1.utf8.count):\($0.1)" }.joined(separator: "\n")
    }
}

// MARK: - automatic semantics digest

/// Hashes what the frontend *does*, so that changing S0 or the encoder changes every key without anyone remembering to bump
/// `SILFrontendVersion.semantics`.
///  * S0: `evaluate` (reference interpreter) and `encode` (circuit, folded on constants) for every operation family and
///    width, on every pair from a fixed battery of edge values (and both values of the overflow flag).
///  * Encoder canary: three small SIL functions (branches with block arguments, checked arithmetic, a guarded division,
///    a call) are parsed and encoded at constant inputs; trap, undefined and result are hashed. A parse or encode error is
///    hashed too, so breaking the parser also changes the digest.
package enum SemanticsDigest {
    package static let current: String = compute()

    package static func compute() -> String {
        ProofDigest.hash(s0Report() + floatReport() + canaryReport() + summaryReport() + summaryReport(OpaqueValues.table))
    }

    /// A canonical dump of the standard-library summary table (`StdlibSummary.table`): which calls are summarized and
    /// how. Editing a row (fixing what a summary assumes) then changes every key, so no cached proof made under the
    /// old row survives (plan item R7).
    package static func summaryReport(_ table: [String: StdlibSummary.Entry] = StdlibSummary.table) -> String {
        var text = "summaries\n"
        for (symbol, entry) in table.sorted(by: { $0.key < $1.key }) {
            let operation = entry.arrayOperation.map { "\($0)" } ?? "-"
            let tags = entry.semantics.sorted().joined(separator: ",") + (entry.integerText.map { " integerText=\($0)" } ?? "")
            text +=
                "\(symbol) \(entry.name) \(entry.summary) generic=\(entry.isGeneric) \(operation) collection=\(entry.onCollection) semantics=\(tags)\n"
        }
        return text
    }

    private static func mask(_ width: Int) -> UInt64 { width == 64 ? ~0 : (1 << UInt64(width)) - 1 }

    private static func battery(width: Int) -> [UInt64] {
        let m = mask(width), top: UInt64 = 1 << UInt64(width - 1)
        let raw: [UInt64] = [
            0, 1, 2, 3, UInt64(width - 1), UInt64(width), UInt64(width + 1), m, m &- 1, top, top &- 1, top &+ 1,
            0x5555_5555_5555_5555, 0xAAAA_AAAA_AAAA_AAAA, 7, 0x1234_5678_9ABC_DEF0,
        ].map { $0 & m }
        return Array(Set(raw)).sorted()
    }

    /// The floating-point builtins (`S0FloatInstance`) and classifications on special and sample bit patterns, so that a
    /// change to their meaning changes every key.
    package static func floatReport() -> String {
        var text = "S0Float\n"
        let patterns: [UInt64] = [
            0, 1 << 63, 0x3FF0_0000_0000_0000, 0xBFF0_0000_0000_0000, 0x7FF0_0000_0000_0000, 0xFFF0_0000_0000_0000,
            0x7FF8_0000_0000_0000, 0x0000_0000_0000_0001, 0x43E0_0000_0000_0000, 0xC3E0_0000_0000_0001, 0x4060_0000_0000_0000,
        ]
        var names = ["fneg_FPIEEE64", "int_fabs_FPIEEE64", "int_copysign_FPIEEE64", "bitcast_FPIEEE64_Int64", "fadd_FPIEEE64"]
        names += ["oeq", "ogt", "oge", "olt", "ole", "one", "ord", "ueq", "ugt", "uge", "ult", "ule", "une", "uno"].map {
            "fcmp_\($0)_FPIEEE64"
        }
        names += ["fptosi", "fptoui"].flatMap { kind in [8, 16, 32, 64].map { "\(kind)_FPIEEE64_Int\($0)" } }
        for name in names {
            guard let instance = S0FloatInstance(builtinName: name) else { text += "\(name) missing\n"; continue }
            for a in patterns {
                for b in instance.operandWidths.count == 2 ? patterns : [0] {
                    text += "\(name) \(a) \(b) \(instance.evaluate(Array([a, b].prefix(instance.operandWidths.count))))\n"
                }
            }
        }
        for kind in [S0FloatClass.finite, .nan, .infinite, .zero, .normal, .subnormal] {
            text += "\(kind) " + patterns.map { kind.evaluate($0, width: 64) ? "1" : "0" }.joined() + "\n"
        }
        return text + FloatCircuit.digestReport(patterns)
    }

    package static func s0Report() -> String {
        var text = "S0\n"
        let widths = Array(S0Instance.supportedWidths).sorted()
        var instances: [S0Instance] = []
        for op in S0Op.allCases {
            for w in widths {
                if let i = S0Instance(op: op, width: w) { instances.append(i) }
                for target in widths where target != w {
                    if let i = S0Instance(op: op, width: w, resultWidth: target) { instances.append(i) }
                }
            }
        }
        for instance in instances.sorted(by: { $0.builtinName < $1.builtinName }) {
            let values = battery(width: instance.width)
            // Every combination of battery values, a one-bit operand taking 0 and 1.
            var pairs: [[UInt64]] = [[]]
            for width in instance.operandWidths {
                let choices = width == 1 && instance.width != 1 ? [0, 1] : values
                pairs = pairs.flatMap { prefix in choices.map { prefix + [$0] } }
            }
            for args in pairs {
                let c = CNFBuilder()
                let widths = instance.operandWidths
                let (values, undefined) = instance.encode(c, zip(args, widths).map { c.constant($0, width: $1) })
                let folded = values.map { c.constantValue($0).map(String.init) ?? "?" }.joined(separator: ",")
                let ub = undefined == c.trueLit ? "U" : undefined == c.falseLit ? "D" : "?"
                text += "\(instance.builtinName) \(args) eval=\(instance.evaluate(args)) circuit=\(folded) \(ub)\n"
            }
        }
        return text
    }

    private static let canarySIL = """
        sil_stage canonical

        sil @$s7Fixture5clampys5Int32VAD_A2DtF : $@convention(thin) (Int32, Int32, Int32) -> Int32 {
        bb0(%0 : $Int32, %1 : $Int32, %2 : $Int32):
          %6 = struct_extract %0, #Int32._value
          %7 = struct_extract %1, #Int32._value
          %8 = builtin "cmp_slt_Int32"(%6, %7) : $Builtin.Int1
          cond_br %8, bb1, bb2
        bb1:
          br bb5(%1)
        bb2:
          %11 = struct_extract %2, #Int32._value
          %12 = builtin "cmp_slt_Int32"(%11, %6) : $Builtin.Int1
          cond_br %12, bb3, bb4
        bb3:
          br bb5(%2)
        bb4:
          br bb5(%0)
        bb5(%16 : $Int32):
          return %16
        }

        sil @$s7Fixture3avgys5Int32VAD_ADtF : $@convention(thin) (Int32, Int32) -> Int32 {
        bb0(%0 : $Int32, %1 : $Int32):
          %4 = struct_extract %0, #Int32._value
          %5 = struct_extract %1, #Int32._value
          %6 = integer_literal $Builtin.Int1, -1
          %7 = builtin "sadd_with_overflow_Int32"(%4, %5, %6) : $(Builtin.Int32, Builtin.Int1)
          %8 = tuple_extract %7, 0
          %9 = tuple_extract %7, 1
          cond_fail %9, "arithmetic overflow"
          %11 = integer_literal $Builtin.Int32, 2
          %12 = integer_literal $Builtin.Int32, -2147483648
          %13 = builtin "cmp_eq_Int32"(%8, %12) : $Builtin.Int1
          cond_br %13, bb1, bb2
        bb1:
          br bb3
        bb2:
          br bb3
        bb3:
          %17 = builtin "sdiv_Int32"(%8, %11) : $Builtin.Int32
          %18 = struct $Int32 (%17)
          return %18
        }

        sil [noinline] @$s7Fixture5twiceys5Int32VADF : $@convention(thin) (Int32) -> Int32 {
        bb0(%0 : $Int32):
          %2 = struct_extract %0, #Int32._value
          %3 = integer_literal $Builtin.Int32, 2
          %4 = integer_literal $Builtin.Int1, 0
          %5 = builtin "smul_with_overflow_Int32"(%3, %2, %4) : $(Builtin.Int32, Builtin.Int1)
          %6 = tuple_extract %5, 0
          %7 = struct $Int32 (%6)
          return %7
        }

        sil @$s7Fixture8useTwiceys5Int32VADF : $@convention(thin) (Int32) -> Int32 {
        bb0(%0 : $Int32):
          %2 = function_ref @$s7Fixture5twiceys5Int32VADF : $@convention(thin) (Int32) -> Int32
          %3 = apply %2(%0) : $@convention(thin) (Int32) -> Int32
          %4 = struct_extract %3, #Int32._value
          %5 = integer_literal $Builtin.Int32, 1
          %6 = integer_literal $Builtin.Int1, 0
          %7 = builtin "sadd_with_overflow_Int32"(%4, %5, %6) : $(Builtin.Int32, Builtin.Int1)
          %8 = tuple_extract %7, 0
          %9 = struct $Int32 (%8)
          return %9
        }
        """

    package static func canaryReport() -> String {
        var text = "canary\n"
        do {
            let module = try SILModule(text: canarySIL)
            let values: [UInt64] = [0, 1, 5, 0x7FFF_FFFF, 0x8000_0000, 0xFFFF_FFFF, 0xFFFF_FFFE, 0x4000_0000]
            for symbol in module.symbols {
                let function = try module.function(symbol)
                var cases: [[UInt64]] = [values.map { [$0] + Array(repeating: 3, count: function.parameterWidths.count - 1) }].flatMap {
                    $0
                }
                if function.parameterWidths.count > 1 {
                    cases = values.flatMap { a in
                        values.map { b in [a, b] + Array(repeating: 9, count: function.parameterWidths.count - 2) }
                    }
                }
                for args in cases {
                    let c = CNFBuilder()
                    let inputs = zip(function.parameterWidths, args).map { c.constant($1, width: $0) }
                    let e = try SILEncoder(module: module, builder: c).encode(symbol: symbol, arguments: inputs)
                    func flag(_ l: Int32) -> String { l == c.trueLit ? "1" : l == c.falseLit ? "0" : "?" }
                    text +=
                        "\(symbol) \(args) trap=\(flag(e.trap)) undefined=\(flag(e.undefined)) result=\(c.constantValue(e.result).map(String.init) ?? "?")\n"
                }
            }
        } catch {
            text += "error: \(error)\n"
        }
        return text
    }
}

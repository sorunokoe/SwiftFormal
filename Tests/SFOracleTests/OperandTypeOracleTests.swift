import Foundation
import SFBV
import SFSIL
import SFTestSupport
import Testing

/// Plan item L11: the SIL Scan reads prints no operand types, so the reader infers each value's type from the
/// instruction that defines it. The compiler prints them with `-Xllvm -sil-print-types` (same SSA numbering: it is a
/// printer option). This oracle compiles each source both ways and checks that the layout the encoder gave every value
/// has the leaf widths of the type the compiler printed for it.
@Suite(.tags(.oracle), .requiresPinnedCompiler) struct OperandTypeOracleTests {
    private static let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        .deletingLastPathComponent()

    private static let extraSource = """
        public struct Point: Equatable { public var x: Int32; public var y: Int32 }
        public enum Shape { case dot, line(Int16), box(w: Int8, h: Int8) }
        public func area(_ s: Shape) -> Int32 {
            switch s {
            case .dot: return 0
            case .line(let n): return Int32(n)
            case .box(let w, let h): return Int32(w) * Int32(h)
            }
        }
        public func mid(_ p: Point, _ q: Point) -> Point { Point(x: (p.x &+ q.x) / 2, y: (p.y &+ q.y) / 2) }
        public func firstOr(_ a: [Int8], _ d: Int8?) -> Int8 { a.first ?? d ?? 0 }
        public func scale(_ x: Double, _ k: Float) -> Bool { x * Double(k) < 1 }
        public func pick(_ b: Bool, _ t: (Int8, UInt16)) -> UInt16 { b ? UInt16(truncatingIfNeeded: t.0) : t.1 }
        """

    /// `source` without `import SwiftFormal`, `@Verify`, `#requires` and `#ensures` lines: the same bodies, compiled
    /// alone without the built macro.
    static func withoutVerify(_ source: String) -> String {
        source.split(separator: "\n", omittingEmptySubsequences: false).filter { line in
            let code = line.trimmingCharacters(in: .whitespaces)
            return !["import SwiftFormal", "@Verify", "#requires", "#ensures"].contains { code.hasPrefix($0) }
        }.joined(separator: "\n")
    }

    /// Every `%n : $T` operand of the typed text, per function symbol.
    static func operandTypes(_ text: String) -> [String: [String: String]] {
        var result: [String: [String: String]] = [:]
        var function: String?
        for line in text.split(separator: "\n") {
            if line.hasPrefix("sil "), let at = line.range(of: " @"),
                let colon = line.range(of: " : $", range: at.upperBound..<line.endIndex)
            {
                function = String(line[line.index(after: at.lowerBound)..<colon.lowerBound].dropFirst())
                continue
            }
            if line.hasPrefix("}") { function = nil }
            guard let function else { continue }
            let body = line.range(of: " //").map { line[..<$0.lowerBound] } ?? line[...]
            var rest = body[...]
            while let marker = rest.range(of: " : $") {
                let name = rest[..<marker.lowerBound].reversed().prefix { $0 != " " && $0 != "(" && $0 != "[" }.reversed()
                let type = typeText(rest[marker.upperBound...])
                if name.first == "%", String(name.dropFirst()).allSatisfy(\.isNumber) {
                    result[function, default: [:]][String(name)] = type
                }
                rest = rest[marker.upperBound...]
            }
        }
        return result
    }

    /// The type that starts `text`, up to a comma or closing bracket at depth 0.
    private static func typeText(_ text: Substring) -> String {
        var depth = 0
        var out = ""
        for character in text {
            if "([<{".contains(character) { depth += 1 }
            if ")]>}".contains(character) {
                if depth == 0 { break }
                depth -= 1
            }
            if character == ",", depth == 0 { break }
            out.append(character)
        }
        return out.trimmingCharacters(in: .whitespaces)
    }

    @Test func everyInferredValueTypeHasTheCompilersLeafWidths() throws {
        let sources = [
            try String(contentsOf: Self.root.appendingPathComponent("Examples/Metrics/Kernels.swift"), encoding: .utf8),
            Self.withoutVerify(
                try String(
                    contentsOf: Self.root.appendingPathComponent("Examples/GatedPackage/Sources/Kernels/Kernels.swift"), encoding: .utf8)),
            Self.extraSource,
        ]
        var compared = 0
        var mismatches: [String] = []
        for (index, source) in sources.enumerated() {
            let name = "Typed\(index)"
            let module = try SILCompiler.module(source: source, name: name, optimization: .none)
            let typed = Self.operandTypes(
                try SILCompiler.emit(source: source, module: name, optimization: .none, extraArguments: ["-Xllvm", "-sil-print-types"]))
            for symbol in module.symbols where symbol.hasPrefix("$s\(name.count)\(name)") {
                guard let function = try? module.function(symbol), let printed = typed[symbol] else { continue }
                let c = CNFBuilder()
                let encoder = SILEncoder(module: module, builder: c)
                var seen: [String: ValueType] = [:]
                encoder.observeValues = { owner, value, type in
                    if owner == symbol, let type { seen[value] = type }
                }
                guard (try? encoder.encode(symbol: symbol, arguments: function.parameterWidths.map { c.input(width: $0) })) != nil else {
                    continue
                }
                for (value, type) in seen {
                    guard let text = printed[value], !text.hasPrefix("*"), let expected = try? module.resolve(text) else { continue }
                    compared += 1
                    if expected.leafWidths != type.leafWidths {
                        mismatches.append(
                            "\(symbol) \(value): the compiler says \(text) \(expected.leafWidths), Scan read \(type.leafWidths)")
                    }
                }
            }
        }
        #expect(mismatches.isEmpty, "\(mismatches.count) mismatches, first: \(mismatches.prefix(5))")
        #expect(compared > 100, "only \(compared) values compared")
        print("OperandTypeOracleTests: \(compared) values compared")
    }
}

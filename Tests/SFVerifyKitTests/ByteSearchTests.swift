import Foundation
import Testing

@testable import SFVerifyKit

/// `SILText.prepare` searches every SIL line with `byteRange(of:)`; it must find what Foundation's `range(of:)` finds.
@Suite struct ByteSearchTests {
    private static let lines = [
        "  %5 = apply %4(%0, %1) : $@convention(thin) (Int32, Int32) -> Int32, loc \"a.swift\":3:12, scope 2 // id: %6",
        "  cond_fail %3 : $Builtin.Int1, \"arithmetic overflow\", loc * \"<compiler-generated>\":0:0, scope 1",
        "  debug_value %0 : $Int8, let, name \"x\", argno 1, loc \"a.swift\":1:13, scope 1",
        "sil [ossa] @$s7Fixture5clampys5Int32VAD_A2DtF : $@convention(thin) (Int32, Int32, Int32) -> Int32 {",
        "  %2 = string_literal utf8 \"héllo, loc 🙂 wörld\"",
        "// clamp(_:_:_:), loc \"a.swift\":1:13, scope 1",
        "aaab loc loc  , scope , scope 3",
        "",
        "é",
        "loc",
    ]
    private static let needles = [
        ", loc ", "loc ", ", scope ", " //", " @$", " : $", ", name \"", ", argno ", " = apply ", "string_literal utf8 \"",
        "aab", "ab", "a", "3", "x",
    ]

    @Test func findsWhatFoundationFinds() {
        for line in Self.lines {
            for needle in Self.needles {
                let expected = line.range(of: needle)
                #expect(line.byteRange(of: needle) == expected, "\(needle) in \(line)")
                #expect(line.bytesContain(needle) == (expected != nil))
                let tail = line.dropFirst(min(3, line.count))
                #expect(tail.byteRange(of: needle) == tail.range(of: needle), "\(needle) in \(tail)")
            }
        }
    }

    /// The character reading `SILText.location(in:)` had before it read ASCII text by bytes.
    private static func characterLocation(in text: String) -> SFVerifyKit.SourceLocation? {
        guard let r = text.range(of: "loc ") else { return nil }
        var rest = text[r.upperBound...]
        if rest.hasPrefix("* ") { rest = rest.dropFirst(2) }
        guard rest.hasPrefix("\""), let quote = rest.dropFirst().firstIndex(of: "\"") else { return nil }
        let file = String(rest[rest.index(after: rest.startIndex)..<quote])
        let numbers = rest[rest.index(after: quote)...].dropFirst().prefix { $0.isNumber || $0 == ":" }.split(separator: ":")
        guard numbers.count >= 2, let line = Int(numbers[0]), let column = Int(numbers[1]) else { return nil }
        return SFVerifyKit.SourceLocation(file: file, line: line, column: column)
    }

    @Test func locationsReadAsTheCharacterReadingDoes() {
        let lines = [
            "  %3 = apply %2(%0) : $@convention(thin) (Int8) -> Int8, loc \"/p/a.swift\":12:9, scope 4 // user: %4",
            "  cond_fail %5 : $Builtin.Int1, \"arithmetic overflow\", loc * \"<compiler-generated>\":0:0, scope 1",
            "// clamp(_:_:_:), loc \"Sources/K/K.swift\":1:13, scope 1",
            "loc \"a.swift\":7", "loc \"a.swift\"::7:8", "loc \"a.swift\":x:8", "loc a.swift:1:2", "loc \"unterminated:1:2",
            "loc * a.swift", "loc ", "no location here", "loc \"/p/é dir/a.swift\":3:4, scope 1",
            "loc \"\u{301}a.swift\":3:4", "loc \"a.swift\"\u{301}:3:4", "loc \"a.swift\":3:4\u{301}0, scope 2",
            "loc \"a.swift\":12345678901234567890:1", "%1 = string_literal utf8 \"loc \\\"x\\\":1:2\", loc \"b.swift\":5:6",
        ]
        for line in lines {
            #expect(SILText.location(in: line) == Self.characterLocation(in: line), "\(line)")
        }
    }
}

import Foundation
import Testing

@testable import ScalarExtraction

// Selected body from the 0.0.1 compiler artifact, without non-executing debug_value lines.
private let symbol = "$s13BridgeFixture15clampedDiscountys5Int64VAD_ADtF"
private let clamped = """
    sil_stage canonical
    sil @$s13BridgeFixture15clampedDiscountys5Int64VAD_ADtF : $@convention(thin) (Int64, Int64) -> Int64 {
    bb0(%0 : $Int64, %1 : $Int64):
      %4 = struct_extract %0, #Int64._value, loc "Fixture.swift":2:17, scope 2
      %5 = struct_extract %1, #Int64._value, loc "Fixture.swift":2:17, scope 2
      %6 = builtin "cmp_slt_Int64"(%4, %5) : $Builtin.Int1, loc "Fixture.swift":2:17, scope 2
      cond_br %6, bb1, bb2, loc "Fixture.swift":2:17, scope 2
    bb1:
      %8 = integer_literal $Builtin.Int64, 0, loc "Fixture.swift":3:16, scope 3
      %9 = struct $Int64 (%8), loc "Fixture.swift":3:16, scope 3
      br bb3(%9), loc "Fixture.swift":3:9, scope 3
    bb2:
      %11 = struct_extract %0, #Int64._value, loc "Fixture.swift":5:21, scope 1
      %12 = struct_extract %1, #Int64._value, loc "Fixture.swift":5:21, scope 1
      %13 = integer_literal $Builtin.Int1, -1, loc "Fixture.swift":5:21, scope 1
      %14 = builtin "ssub_with_overflow_Int64"(%11, %12, %13) : $(Builtin.Int64, Builtin.Int1), loc "Fixture.swift":5:21, scope 1
      %15 = tuple_extract %14, 0, loc "Fixture.swift":5:21, scope 1
      %16 = tuple_extract %14, 1, loc "Fixture.swift":5:21, scope 1
      cond_fail %16, "arithmetic overflow", loc "Fixture.swift":5:21, scope 1
      %18 = struct $Int64 (%15), loc "Fixture.swift":5:21, scope 1
      br bb3(%18), loc "Fixture.swift":5:5, scope 1
    bb3(%20 : $Int64):
      return %20, loc "Fixture.swift":6:1, scope 1
    }
    """

@Test(
    arguments: [
        (Int64(0), Int64(1), Int64(0)),
        (100, 20, 80),
        (Int64.max, 0, Int64.max),
        (Int64.max, Int64.max, 0),
        (-1, -2, 1),
    ] as [(Int64, Int64, Int64)])
func interpretsActualBranches(a: Int64, b: Int64, expected: Int64) throws {
    let function = try SILReader.extract(from: clamped, symbol: symbol)
    #expect(function.blockCount == 4)
    #expect(try function.evaluate(arguments: [a, b]) == .returned(expected))
}

@Test func modelsTrapAtItsSourceLocation() throws {
    let function = try SILReader.extract(from: clamped, symbol: symbol)
    #expect(
        try function.evaluate(arguments: [.max, -1])
            == .arithmeticTrap(SourceLocation(file: "Fixture.swift", line: 5, column: 21))
    )
}

@Test(arguments: [
    #"debug_value %18, let, name "result""#,
    #"debug_value %18, let, name "result", scope 5"#,
    #"debug_value %18, let, name "result", loc "Fixture.swift":5:9, scope 5 // id: %19"#,
    #"debug_value %18, let, name "result", argno 1"#,
])
func preservesBehaviorWithDebugMetadata(debug: String) throws {
    let text = clamped.replacingOccurrences(
        of: "  br bb3(%18)", with: "  \(debug)\n  br bb3(%18)"
    )
    let function = try SILReader.extract(from: text, symbol: symbol)
    #expect(try function.evaluate(arguments: [10, 3]) == .returned(7))
    #expect(try function.evaluate(arguments: [0, 1]) == .returned(0))
    #expect(
        try function.evaluate(arguments: [.max, -1])
            == .arithmeticTrap(SourceLocation(file: "Fixture.swift", line: 5, column: 21))
    )
}

@Test func localNameDoesNotSelectTheReturnedValue() throws {
    let text = clamped.replacingOccurrences(
        of: "  br bb3(%18)",
        with: "  debug_value %18, let, name \"result\"\n  br bb3(%0)"
    )
    let function = try SILReader.extract(from: text, symbol: symbol)
    #expect(try function.evaluate(arguments: [10, 3]) == .returned(10))
}

@Test(arguments: [
    #"debug_value %18, var, name "result""#,
    #"debug_value %18, let, name result"#,
    #"debug_value %18, let, name "result", unknown_attribute"#,
    #"debug_value %18, let, name "result", argno"#,
    #"debug_value %18, let, name "result", argno 1, argno 2"#,
    #"debug_value %18, let, name "result", return %0"#,
    "debug_value %18, let, name \"result\"\n  unknown_operation %18",
])
func rejectsUnsupportedDebugForms(debug: String) {
    let text = clamped.replacingOccurrences(
        of: "  br bb3(%18)", with: "  \(debug)\n  br bb3(%18)"
    )
    #expect {
        try SILReader.extract(from: text, symbol: symbol)
    } throws: { error in
        guard case ExtractionError.unsupported = error else { return false }
        return true
    }
}

@Test(arguments: ["%999", "%20"])
func validatesLocalDebugOperands(operand: String) {
    let text = clamped.replacingOccurrences(
        of: "  br bb3(%18)",
        with: "  debug_value \(operand), let, name \"result\"\n  br bb3(%18)"
    )
    #expect {
        try SILReader.extract(from: text, symbol: symbol)
    } throws: { error in
        guard case ExtractionError.invalidArtifact = error else { return false }
        return true
    }
}

@Test func rejectsUnknownInstruction() {
    let text = clamped.replacingOccurrences(
        of: "  %18 = struct $Int64 (%15)", with: "  %18 = unknown_operation %15"
    )
    #expect {
        try SILReader.extract(from: text, symbol: symbol)
    } throws: { error in
        guard case ExtractionError.unsupported(let detail) = error else { return false }
        return detail.contains("unknown_operation")
    }
}

@Test(arguments: [
    ("br bb3(%9)", "br bb3"),
    ("br bb3(%9)", "br bb3(%8)"),
    ("struct $Int64 (%15)", "struct $Int64 (%8)"),
    ("struct $Int64 (%15)", "struct $Int64 (%999)"),
    ("br bb3(%18)", "br bb99(%18)"),
])
func rejectsInvalidSSA(before: String, after: String) {
    let text = clamped.replacingOccurrences(of: before, with: after)
    #expect {
        try SILReader.extract(from: text, symbol: symbol)
    } throws: { error in
        guard case ExtractionError.invalidArtifact = error else { return false }
        return true
    }
}

@Test(arguments: [
    ("integer_literal $Builtin.Int1, -1", "integer_literal $Builtin.Int1, 0"),
    ("cond_fail %16, \"arithmetic overflow\"", "debug_value %16, let, name \"overflow\", argno 1"),
    ("cond_fail %16, \"arithmetic overflow\"", "cond_fail %13, \"arithmetic overflow\""),
    ("br bb3(%18)", "br bb2"),
    ("ssub_with_overflow_Int64", "smul_with_overflow_Int64"),
    ("#Int64._value", "#Amount.value"),
    ("struct $Int64 (%15)", "function_ref @unknown : $@convention(thin) () -> Int64"),
])
func rejectsUnsupportedSemantics(before: String, after: String) {
    #expect {
        try SILReader.extract(
            from: clamped.replacingOccurrences(of: before, with: after), symbol: symbol)
    } throws: { error in
        guard case ExtractionError.unsupported = error else { return false }
        return true
    }
}

@Test(arguments: [
    ("integer_literal $Builtin.Int1, -1", "integer_literal $Builtin.Int1, 2"),
    ("integer_literal $Builtin.Int64, 0", "integer_literal $Builtin.Int64, 9223372036854775808"),
    ("%18 = struct", "%15 = struct"),
    ("bb3(%20 : $Int64):", "bb1(%20 : $Int64):"),
    ("  br bb3(%18), loc", "  return %18\n  br bb3(%18), loc"),
])
func rejectsMalformedBodies(before: String, after: String) {
    #expect {
        try SILReader.extract(
            from: clamped.replacingOccurrences(of: before, with: after), symbol: symbol)
    } throws: { error in
        guard case ExtractionError.invalidArtifact = error else { return false }
        return true
    }
}

@Test func rejectsDuplicateMissingAndWrongStageBodies() {
    #expect(throws: ExtractionError.self) {
        try SILReader.extract(from: clamped + "\n" + clamped, symbol: symbol)
    }
    #expect(throws: ExtractionError.self) {
        try SILReader.extract(from: clamped, symbol: "missing")
    }
    #expect(throws: ExtractionError.self) {
        try SILReader.extract(
            from: clamped.replacingOccurrences(of: "sil_stage canonical", with: "sil_stage raw"),
            symbol: symbol)
    }
}

@Test func readsReturnValueInsteadOfGuessingFromSymbol() throws {
    let text = clamped.replacingOccurrences(
        of: "integer_literal $Builtin.Int64, 0", with: "integer_literal $Builtin.Int64, 42"
    )
    let function = try SILReader.extract(from: text, symbol: symbol)
    #expect(try function.evaluate(arguments: [0, 1]) == .returned(42))
    #expect(throws: ExtractionError.self) { try function.evaluate(arguments: [0]) }
}

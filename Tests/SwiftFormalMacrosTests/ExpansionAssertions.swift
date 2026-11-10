import SwiftSyntaxMacroExpansion
import SwiftSyntaxMacrosGenericTestSupport
import Testing

/// swift-syntax's expansion check, reporting through Swift Testing. Its XCTest variant would make `swift test` run a
/// second, XCTest pass over every test bundle; without XCTest tests the lanes can pass `--disable-xctest`.
func assertExpansion(
    _ source: String,
    expandedSource: String,
    diagnostics: [DiagnosticSpec] = [],
    macroSpecs: [String: MacroSpec],
    fileID: StaticString = #fileID,
    filePath: StaticString = #filePath,
    line: UInt = #line,
    column: UInt = #column
) {
    assertMacroExpansion(
        source,
        expandedSource: expandedSource,
        diagnostics: diagnostics,
        macroSpecs: macroSpecs,
        failureHandler: { failure in
            Issue.record(
                Comment(rawValue: failure.message),
                sourceLocation: SourceLocation(
                    fileID: "\(failure.location.fileID)", filePath: "\(failure.location.filePath)",
                    line: Int(failure.location.line), column: Int(failure.location.column)))
        },
        fileID: fileID,
        filePath: filePath,
        line: line,
        column: column
    )
}

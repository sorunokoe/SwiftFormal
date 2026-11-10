import Foundation

/// Imported modules of the same build that should have been linked but could not be (`CompiledModule.unlinkedModules`):
/// their types and functions are unknown to the scan, so the report says which and why (app study round 6, bug B).
enum UnlinkedModules {
    /// One warning per module, sorted by name: the module and the first compiler error of its reason.
    static func warnings(_ unlinked: [String: String]) -> [String] {
        unlinked.sorted { $0.key < $1.key }.map { module, reason in
            "module \(module) could not be linked, so its types and functions are unknown to this scan "
                + "(functions that use them are unsupported): \(firstError(in: reason))"
        }
    }

    /// The first `error:` line of a compiler's output (the source excerpt under it left out), or else its first line
    /// that is not a warning, note or excerpt (`no such module 'X'`); at most 300 characters. A reason keeps only the
    /// start of the output, so many warnings can push the error out: a warning is never given as the reason.
    static func firstError(in reason: String) -> String {
        let lines = reason.replacing(/\u{1B}\[[0-9;]*m/, with: "").split(separator: "\n").map {
            $0.trimmingCharacters(in: .whitespaces)
        }
        let failed = "COMPILER FAILED: "
        let cleaned = lines.map { $0.hasPrefix(failed) ? String($0.dropFirst(failed.count)) : $0 }
        // A source excerpt line (`8 |     @State`, `|  `- error: …`) repeats the message; the diagnostic line comes first.
        // Not excerpt lines, nor the links to diagnostic groups printed at the end (`[#DeprecatedDeclaration]: <…>`).
        let diagnostics = cleaned.filter { !$0.isEmpty && !$0.contains(/^[0-9]*\s*\|/) && !$0.hasPrefix("[#") }
        let error = diagnostics.first { $0.contains("error:") }
        let other = diagnostics.first { !$0.contains("warning:") && !$0.contains("note:") && !$0.contains("remark:") }
        let line = error ?? other ?? "the compiler failed; its error is past the part of the compiler output Scan keeps"
        return line.count > 300 ? String(line.prefix(300)) + "…" : line
    }

    /// The type names `source` declares (`struct`, `enum`, `class`, `actor`, `protocol`, `typealias`). A word in a
    /// comment may be found too; that only widens which hints mention the module.
    static func declaredTypes(in source: String) -> Set<String> {
        Set(source.matches(of: /\b(?:struct|enum|class|actor|protocol|typealias)\s+([A-Za-z_][A-Za-z0-9_]*)/).map { String($0.1) })
    }

    /// `functions` with the hint of each unsupported one whose type is declared in a module that could not be linked
    /// replaced by one that says so. Verdicts and categories are unchanged.
    static func explained(_ functions: [FunctionReport], compiled: CompiledModule) -> [FunctionReport] {
        guard !compiled.unlinkedModuleFiles.isEmpty, functions.contains(where: { $0.status == .unsupported }) else {
            return functions
        }
        var declaring: [String: String] = [:]  // type name -> module
        for (module, files) in compiled.unlinkedModuleFiles.sorted(by: { $0.key > $1.key }) {
            for file in files {
                guard let text = try? String(contentsOfFile: file, encoding: .utf8) else { continue }
                for name in declaredTypes(in: text) { declaring[name] = module }
            }
        }
        return functions.map { function in
            guard function.status == .unsupported, let type = typeName(of: function), let module = declaring[type] else {
                return function
            }
            var explained = function
            explained.hint =
                "\(type) is declared in \(module), which could not be linked (see the warnings): "
                + "Scan knows its types and functions only once that module compiles for the scan"
            return explained
        }
    }

    /// The outer type an unsupported function stopped at: `Outer` for the category `type Outer.Inner<Int>`, or for a
    /// callee without a body (`no body for Outer.member.getter`).
    private static func typeName(of function: FunctionReport) -> String? {
        let category = function.category ?? ""
        var name: Substring
        if category.hasPrefix("type ") {
            name = category.dropFirst(5)
        } else if category == "calls a function without a body", let detail = function.detail,
            let range = detail.range(of: "no body for ")
        {
            name = detail[range.upperBound...]
            guard name.contains(".") else { return nil }  // a free function names no type
        } else {
            return nil
        }
        let outer = name.prefix { $0.isLetter || $0.isNumber || $0 == "_" }
        return outer.isEmpty ? nil : String(outer)
    }
}

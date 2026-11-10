import SwiftSyntax

// The parts of a `@Verify` function the macro reads: its parameters and its body split into contract and code.

// MARK: - Parsing

struct Parameter {
    let label: String?
    let name: String
    /// The type as written, with `inout` and attributes (`inout Int`, `@escaping () -> Void`).
    let type: String
    let isInout: Bool
    let isVariadic: Bool
    let syntax: FunctionParameterSyntax

    init(_ syntax: FunctionParameterSyntax) {
        let first = syntax.firstName.text
        label = first == "_" ? nil : first
        name = syntax.secondName?.text ?? first
        type = syntax.type.trimmedDescription + (syntax.ellipsis != nil ? "..." : "")
        isInout = syntax.type.as(AttributedTypeSyntax.self)?.specifiers.contains { $0.trimmedDescription == "inout" } ?? false
        isVariadic = syntax.ellipsis != nil
        self.syntax = syntax
    }
}

/// The names an expression reads, such as `percent` in `percent <= 100` or in a string interpolation.
final class ReferencedNames: SyntaxVisitor {
    private var names: Set<String> = []

    static func `in`(_ expressions: [ExprSyntax]) -> Set<String> {
        let visitor = ReferencedNames(viewMode: .sourceAccurate)
        for expression in expressions { visitor.walk(expression) }
        return visitor.names
    }

    override func visit(_ node: DeclReferenceExprSyntax) -> SyntaxVisitorContinueKind {
        names.insert(node.baseName.text)
        return .visitChildren
    }
}

struct Requirement {
    let expression: ExprSyntax
    var text: String { expression.trimmedDescription }
}

struct Ensurement {
    let closure: ExprSyntax
    var text: String { closure.trimmedDescription }
}

/// A function body split into its contract statements and everything else.
struct ParsedBody {
    var requires: [Requirement] = []
    var ensures: [Ensurement] = []
    var statements: [CodeBlockItemSyntax] = []

    init(_ body: CodeBlockSyntax) {
        for item in body.statements {
            if let call = Self.macroCall(in: item), let argument = call.argument {
                switch call.name {
                case "requires":
                    requires.append(Requirement(expression: argument))
                    continue
                case "ensures":
                    ensures.append(Ensurement(closure: argument))
                    continue
                default:
                    break
                }
            }
            statements.append(item)
        }
    }

    private static func macroCall(in item: CodeBlockItemSyntax) -> (name: String, argument: ExprSyntax?)? {
        if let expression = item.item.as(MacroExpansionExprSyntax.self) {
            return (expression.macroName.text, argument(of: expression))
        }
        if let declaration = item.item.as(MacroExpansionDeclSyntax.self) {
            return (declaration.macroName.text, argument(of: declaration))
        }
        return nil
    }

    private static func argument(of node: some FreestandingMacroExpansionSyntax) -> ExprSyntax? {
        if let first = node.arguments.first { return first.expression }
        if let closure = node.trailingClosure { return ExprSyntax(closure) }
        return nil
    }
}

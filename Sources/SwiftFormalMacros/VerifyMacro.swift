import SwiftCompilerPlugin
import SwiftDiagnostics
import SwiftSyntax
import SwiftSyntaxBuilder
import SwiftSyntaxMacros

@main
struct SwiftFormalPlugin: CompilerPlugin {
    let providingMacros: [any Macro.Type] = [
        VerifyMacro.self, RequiresMacro.self, EnsuresMacro.self, FiniteMacro.self, ValuesMacro.self,
    ]
}

struct VerifyDiagnostic: DiagnosticMessage {
    let message: String
    var severity: DiagnosticSeverity = .error
    var diagnosticID: MessageID { MessageID(domain: "SwiftFormalMacros", id: "Verify") }
}

struct ContractError: Error, CustomStringConvertible {
    let description: String
    init(_ description: String) { self.description = description }
}

// MARK: - #requires / #ensures outside @Verify

/// `#requires(condition)` as a plain runtime check. Inside a `@Verify` function the body macro
/// reads these statements itself, so this expansion only runs for functions without `@Verify`.
package struct RequiresMacro: ExpressionMacro {
    package static func expansion(
        of node: some FreestandingMacroExpansionSyntax,
        in context: some MacroExpansionContext
    ) throws -> ExprSyntax {
        guard let condition = node.arguments.first?.expression else {
            throw ContractError("#requires needs a condition")
        }
        let text = condition.trimmedDescription
        return "SwiftFormal.Contract.requires(\(condition), \(literal: text))"
    }
}

/// `#ensures { result in ... }` needs the function's return value, so it only works in `@Verify`.
package struct EnsuresMacro: ExpressionMacro {
    package static func expansion(
        of node: some FreestandingMacroExpansionSyntax,
        in context: some MacroExpansionContext
    ) throws -> ExprSyntax {
        throw ContractError("#ensures only works inside a function marked @Verify")
    }
}

// MARK: - @Verify

/// `@Verify` rewrites the body (of a function, or of a computed property's getter) so `#requires` / `#ensures` run as
/// `Contract` checks, and adds the peers `<name>_requires` / `<name>_ensures`, which Scan proves. A function whose
/// parameters can be walked also gets `verify_<name>()`, which walks the input domain and returns a `Report`.
package struct VerifyMacro: PeerMacro, BodyMacro {
    // MARK: Body

    package static func expansion(
        of node: AttributeSyntax,
        providingBodyFor declaration: some DeclSyntaxProtocol & WithOptionalCodeBlockSyntax,
        in context: some MacroExpansionContext
    ) throws -> [CodeBlockItemSyntax] {
        let target = try VerifyTarget.forBody(declaration, in: context)
        let debugOnly = try checksAreDebugOnly(node)
        let parsed = ParsedBody(target.body)
        if parsed.requires.isEmpty && parsed.ensures.isEmpty { return parsed.statements }

        // Plain `if` checks rather than calls with autoclosures, so Scan reads the conditions from the compiled
        // function; it treats the `...Failed` calls as traps.
        var before: [CodeBlockItemSyntax] = parsed.requires.map { requirement in
            "if !(\(requirement.expression)) { SwiftFormal.Contract.requiresFailed(\(literal: requirement.text)) }"
        }
        // A `mutating` method keeps a copy of `self` as `__sf_old` for the `#ensures` closures. When no closure can
        // read it (each names its last parameter `_`), no copy is made and `self` is passed instead: a copy of a value
        // whose storage the body then changes in place would copy that storage on every call.
        let keepsOld = target.isMutating && !parsed.ensures.isEmpty && !ignoreTheirLastParameter(parsed.ensures)
        if keepsOld { before.append("let __sf_old = self") }
        let arguments = ensuresArguments(
            mutating: target.isMutating, returnsValue: target.returnsValue, old: keepsOld ? "__sf_old" : "self")
        let after: [CodeBlockItemSyntax] = parsed.ensures.map { ensure in
            "if !((\(ensure.closure))(\(raw: arguments))) { SwiftFormal.Contract.ensuresFailed(\(literal: ensure.text)) }"
        }

        var items = debugOnly ? onlyInDebugBuilds(before) : before
        if parsed.ensures.isEmpty {
            // A single expression after the `#requires` lines is the function's value, as it is without them.
            if target.returnsValue, isSingleExpression(parsed.statements) {
                items.append("return \(raw: resultClosure(target, parsed))")
            } else {
                items.append(contentsOf: parsed.statements)
            }
            return items
        }
        items.append("let __sf_result: \(raw: target.returnType) = \(raw: resultClosure(target, parsed))")
        items += debugOnly ? onlyInDebugBuilds(after) : after
        items.append("return __sf_result")
        return items
    }

    /// The body run in a closure that is called at once, `{ () -> T in … }()`, with `try` and the function's own
    /// throws clause, so `throws(MyError)` stays typed (a plain `throws` closure would throw `any Error`). A closure of
    /// one expression returns it, as the function body did.
    private static func resultClosure(_ target: VerifyTarget, _ parsed: ParsedBody) -> String {
        let tryKeyword = target.throwsClause != nil ? "try " : ""
        let throwsKeyword = target.throwsClause.map { $0 + " " } ?? ""
        let inner = CodeBlockItemListSyntax(parsed.statements).trimmedDescription
        return "\(tryKeyword){ () \(throwsKeyword)-> \(target.returnType) in\n\(inner)\n}()"
    }

    /// Whether `statements` is one expression (`x * 2`, or an `if` or `switch` used as one), which Swift returns from a
    /// function without `return`.
    private static func isSingleExpression(_ statements: [CodeBlockItemSyntax]) -> Bool {
        guard statements.count == 1, let item = statements.first?.item else { return false }
        return item.is(ExprSyntax.self) || item.is(ExpressionStmtSyntax.self)
    }

    /// `items` inside `#if DEBUG … #endif`. A declaration in it (`__sf_old`) stays visible after it: `#if` opens no scope.
    private static func onlyInDebugBuilds(_ items: [CodeBlockItemSyntax]) -> [CodeBlockItemSyntax] {
        guard !items.isEmpty else { return [] }
        return ["#if DEBUG\n\(raw: CodeBlockItemListSyntax(items).trimmedDescription)\n#endif"]
    }

    /// Whether the checks in the body compile only in builds that define `DEBUG` (the default, `checks: .debugOnly`)
    /// or in every build (`checks: .always`).
    static func checksAreDebugOnly(_ node: AttributeSyntax) throws -> Bool {
        guard case let .argumentList(arguments) = node.arguments,
            let argument = arguments.first(where: { $0.label?.text == "checks" })
        else { return true }
        if let member = argument.expression.as(MemberAccessExprSyntax.self) {
            switch member.declName.baseName.text {
            case "debugOnly": return true
            case "always": return false
            default: break
            }
        }
        let message = "write `checks: .debugOnly` or `checks: .always`; @Verify reads the choice from the source"
        throw DiagnosticsError(diagnostics: [Diagnostic(node: argument.expression, message: VerifyDiagnostic(message: message))])
    }

    // MARK: Peer

    package static func expansion(
        of node: AttributeSyntax,
        providingPeersOf declaration: some DeclSyntaxProtocol,
        in context: some MacroExpansionContext
    ) throws -> [DeclSyntax] {
        guard let target = try VerifyTarget.forPeers(declaration, in: context) else { return [] }
        if let generics = target.function?.genericParameterClause {
            // The peers would need the generic clause too, and a walk a concrete type: report every shape problem now.
            try rejectUnsupportedShapes(of: target, also: generics)
        }
        let parsed = ParsedBody(target.body)
        if target.hasInoutParameter, !parsed.ensures.isEmpty {
            let message =
                "Scan checks no #ensures of a function with an inout parameter (it would see the value before the call); "
                + "the check in the body still runs. Return the new value instead"
            context.diagnose(Diagnostic(node: declaration, message: VerifyDiagnostic(message: message, severity: .warning)))
        }
        var peers = specPeers(target, parsed)
        if let walk = try walkPeer(node, target, parsed) { peers.insert(walk, at: 0) }
        return peers
    }

    /// `verify_<name>()`, the walk over the input domain, or nil when there is nothing to walk: a getter, a function
    /// without parameters, a `mutating` method (a walk would need values of `self` to start from), or a function
    /// without `over:` whose parameters are surely not `Finite` (`String`, `Int`, an array, `inout`, …). Scan proves the
    /// contract of those for every input; a walk would only add an error.
    private static func walkPeer(_ node: AttributeSyntax, _ target: VerifyTarget, _ parsed: ParsedBody) throws -> DeclSyntax? {
        let over = domainArgument(of: node)
        if target.kind == .getter || target.parameters.isEmpty {
            guard let over else { return nil }
            let message = "@Verify(over:) needs a parameter to range over; without `over:`, Scan proves the contract"
            throw DiagnosticsError(diagnostics: [Diagnostic(node: over, message: VerifyDiagnostic(message: message))])
        }
        if target.isMutating { return nil }
        if over == nil, target.parameters.contains(where: \.isSurelyNotFinite) { return nil }
        try rejectUnsupportedShapes(of: target)
        let parameters = target.parameters
        let tuple = "(" + parameters.map(\.type).joined(separator: ", ") + ")"
        let inputType = parameters.count == 1 ? parameters[0].type : tuple
        let calls = parameters.enumerated().map { index, parameter in
            let argument = parameters.count == 1 ? "input" : "input.\(index)"
            return parameter.label.map { "\($0): \(argument)" } ?? argument
        }
        let tryKeyword = target.throwsClause != nil ? "try " : ""
        let domain = over?.trimmedDescription ?? typeDomain(parameters)

        var requiresClosure = ""
        if !parsed.requires.isEmpty {
            // Bind only what the conditions read: an unused binding is a warning in the user's code.
            let used = ReferencedNames.in(parsed.requires.map(\.expression))
            let names = parameters.map { used.contains($0.name) ? $0.name : "_" }
            let bind = names.count == 1 ? "let \(names[0]) = input" : "let (\(names.joined(separator: ", "))) = input"
            let condition = parsed.requires.map { "(\($0.text))" }.joined(separator: " && ")
            requiresClosure =
                ",\n        requires: { (input: \(inputType)) -> Bool in\n            \(bind)\n            return \(condition)\n        }"
        }

        let call = "\(tryKeyword)\(target.name)(\(calls.joined(separator: ", ")))"
        return """
            \(raw: target.peerPrefix)func verify_\(raw: target.name)(budget: SwiftFormal.Budget = .default) -> SwiftFormal.Report {
                SwiftFormal._verifyContracts(
                    \(literal: target.name),
                    \(raw: walkedCall(call, inputType: inputType, target: target, parsed: parsed)),
                    over: \(raw: domain),
                    budget: budget\(raw: requiresClosure)
                )
            }
            """
    }

    /// The closure the walk calls on each input. With `#ensures` it checks each one again on the result: the checks in
    /// the body exist only in builds that define `DEBUG` (by default), and a walk must find a broken contract in a
    /// release test build too. In a debug build both record the violation; the walk reports the first.
    private static func walkedCall(_ call: String, inputType: String, target: VerifyTarget, parsed: ParsedBody) -> String {
        guard !parsed.ensures.isEmpty else { return "{ (input: \(inputType)) in \(call) }" }
        let parameters = target.parameters
        var lines = ["let __sf_result: \(target.returnType) = \(call)"]
        // Bind only what the closures read: an unused binding is a warning in the user's code.
        let used = ReferencedNames.in(parsed.ensures.map(\.closure))
        let names = parameters.map { used.contains($0.name) ? $0.name : "_" }
        if names.contains(where: { $0 != "_" }) {
            lines.append(names.count == 1 ? "let \(names[0]) = input" : "let (\(names.joined(separator: ", "))) = input")
        }
        for ensure in parsed.ensures {
            lines.append(
                "if !((\(ensure.text))(__sf_result)) { SwiftFormal.Contract.ensuresFailed(\(stringLiteral(ensure.text))) }")
        }
        lines.append("return __sf_result")
        return "{ (input: \(inputType)) -> \(target.returnType) in\n" + lines.joined(separator: "\n") + "\n}"
    }

    /// A Swift string literal of `text`, as `\(literal:)` writes it into the body.
    private static func stringLiteral(_ text: String) -> String {
        StringLiteralExprSyntax(content: text).trimmedDescription
    }

    /// The domain from the parameter types: each one's `Finite` domain (`Domain.ofParameterType`, which gives a
    /// type that is not `Finite` an empty sample, so such a walk compiles and is never proved), in a product whose
    /// values are the flat tuple of the parameters. Past four parameters the product is nested pairs, mapped back to
    /// the flat tuple, as `@Finite` does for a struct.
    private static func typeDomain(_ parameters: [Parameter]) -> String {
        let domains = parameters.map { "SwiftFormal.Domain.ofParameterType((\($0.type)).self)" }
        guard parameters.count > 4 else {
            return domains.count == 1 ? domains[0] : "SwiftFormal.Domain.product(\(domains.joined(separator: ", ")))"
        }
        let flat = parameters.indices.map { FiniteMacro.nestedAccess($0, of: parameters.count) }.joined(separator: ", ")
        return "\(FiniteMacro.nestedProduct(domains)).map { (\(flat)) }"
    }

    /// `<name>_requires(params) -> Bool` and `<name>_ensures(params, result) -> Bool`: the same contract as plain
    /// functions next to the code, which is the form Scan proves for all inputs on the compiled function. A getter's
    /// are `<name>_requires()` and `<name>_ensures(_ result:)`. For a `mutating` method, `_ensures` also takes
    /// `old: Self` (the value before the call; `self` is the value after it), and a method that returns nothing has no
    /// result parameter. A function with an `inout` parameter gets no `_ensures`, as Scan would not pair it.
    private static func specPeers(_ target: VerifyTarget, _ parsed: ParsedBody) -> [DeclSyntax] {
        let list = target.parameters.map { "_ \($0.name): \($0.type)" }
        let (name, prefix) = (target.name, target.peerPrefix)
        var peers: [DeclSyntax] = []
        if !parsed.requires.isEmpty {
            let condition = parsed.requires.map { "(\($0.text))" }.joined(separator: " && ")
            peers.append("\(raw: prefix)func \(raw: name)_requires(\(raw: list.joined(separator: ", "))) -> Bool { \(raw: condition) }")
        }
        let mutating = target.isMutating
        let returnsValue = target.returnsValue
        if !parsed.ensures.isEmpty, returnsValue || mutating, !target.hasInoutParameter {
            let arguments = ensuresArguments(mutating: mutating, returnsValue: returnsValue, old: "old")
            let check = parsed.ensures.map { "(\($0.text))(\(arguments))" }.joined(separator: " && ")
            let result = returnsValue ? ["_ __sf_result: \(target.returnType)"] : []
            let all = (list + result + (mutating ? ["old: Self"] : [])).joined(separator: ", ")
            peers.append("\(raw: prefix)func \(raw: name)_ensures(\(raw: all)) -> Bool { \(raw: check) }")
        }
        return peers
    }

    /// The generated `verify_<name>()` calls the function with values from a domain. Shapes it cannot call that way
    /// are reported at the parameter or clause that causes them; otherwise the compiler reports a confusing error
    /// inside the expansion. `generics`: the generic clause, which is reported first.
    private static func rejectUnsupportedShapes(of target: VerifyTarget, also generics: GenericParameterClauseSyntax? = nil) throws {
        var problems: [Diagnostic] = []
        func reject(_ node: some SyntaxProtocol, _ message: String) {
            problems.append(Diagnostic(node: node, message: VerifyDiagnostic(message: message)))
        }
        if let generics {
            reject(generics, "@Verify cannot walk a generic function; verify a concrete wrapper instead")
        }
        for parameter in target.parameters.map(\.syntax) {
            if parameter.ellipsis != nil {
                reject(parameter, "@Verify cannot walk a variadic parameter; take an array instead")
            }
            if let attributed = parameter.type.as(AttributedTypeSyntax.self),
                attributed.specifiers.contains(where: { $0.trimmedDescription == "inout" })
            {
                reject(parameter.type, "@Verify cannot walk an inout parameter; return the new value instead")
            }
            if parameter.type.is(SomeOrAnyTypeSyntax.self), parameter.type.trimmedDescription.hasPrefix("some ") {
                reject(parameter.type, "@Verify cannot walk an opaque `some` parameter; name a concrete type")
            }
        }
        if !problems.isEmpty { throw DiagnosticsError(diagnostics: problems) }
    }

    /// Whether every closure is a literal whose last parameter is `_`, so that none can read the value passed there.
    private static func ignoreTheirLastParameter(_ ensures: [Ensurement]) -> Bool {
        ensures.allSatisfy { ensure in
            guard let closure = ensure.closure.as(ClosureExprSyntax.self), let clause = closure.signature?.parameterClause else {
                return false
            }
            switch clause {
            case .simpleInput(let names): return names.last?.name.tokenKind == .wildcard
            case .parameterClause(let list):
                guard let last = list.parameters.last else { return false }
                return (last.secondName ?? last.firstName).tokenKind == .wildcard
            }
        }
    }

    /// What each `#ensures` closure receives: the result (if any), then `self` before the call (if `mutating`).
    private static func ensuresArguments(mutating: Bool, returnsValue: Bool, old: String = "__sf_old") -> String {
        ((returnsValue || !mutating ? ["__sf_result"] : []) + (mutating ? [old] : [])).joined(separator: ", ")
    }

    private static func domainArgument(of node: AttributeSyntax) -> ExprSyntax? {
        guard case let .argumentList(arguments) = node.arguments else { return nil }
        return arguments.first { $0.label?.text == "over" }?.expression
    }
}

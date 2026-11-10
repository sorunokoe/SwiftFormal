@resultBuilder
public enum SpecBuilder {
    public static func buildBlock(_ parts: [Declaration]...) -> [Declaration] { parts.flatMap(\.self) }
    public static func buildExpression(_ decl: Declaration) -> [Declaration] { [decl] }
    public static func buildOptional(_ decls: [Declaration]?) -> [Declaration] { decls ?? [] }
    public static func buildEither(first: [Declaration]) -> [Declaration] { first }
    public static func buildEither(second: [Declaration]) -> [Declaration] { second }
    public static func buildArray(_ parts: [[Declaration]]) -> [Declaration] { parts.flatMap(\.self) }
}

public struct SpecModule: Sendable {
    public let name: String
    public let declarations: [Declaration]

    public init(_ name: String, @SpecBuilder _ content: () -> [Declaration]) {
        self.name = name
        self.declarations = content()
    }
}

/// `Function("f", ("x", .nat)) { x in ... }` – parameters are handed to the
/// closure as `Expr` variables so the body reads like ordinary Swift.
public func Function(
    _ name: String,
    _ params: (String, SpecType)...,
    returns: SpecType = .nat,
    body: ([Expr]) -> Expr
) -> Declaration {
    let ps = params.map { Param($0.0, $0.1) }
    return .function(name: name, params: ps, returns: returns, body: body(ps.map { .variable($0.name) }))
}

/// `Theorem("name", ("x", .nat)) { x in ... }` – a universally quantified claim.
/// Default proof is Lean's `grind` automation; an AI agent replaces it if needed.
public func Theorem(
    _ name: String,
    _ binders: (String, SpecType)...,
    proof: String = "by grind",
    statement: ([Expr]) -> Expr
) -> Declaration {
    let bs = binders.map { Param($0.0, $0.1) }
    return .theorem(name: name, binders: bs, statement: statement(bs.map { .variable($0.name) }), proof: proof)
}

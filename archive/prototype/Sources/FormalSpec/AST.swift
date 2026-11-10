/// A tiny, pure, total specification language embedded in Swift.
/// Deliberately small: natural numbers, booleans, if-then-else, and calls
/// to other spec functions. Everything here has an obvious Lean 4 meaning.
public enum SpecType: Sendable, Equatable {
    case nat
    case bool

    var lean: String {
        switch self {
        case .nat: "Nat"
        case .bool: "Bool"
        }
    }
}

public indirect enum Expr: Sendable, Equatable {
    case variable(String)
    case natLiteral(UInt64)
    case boolLiteral(Bool)
    case add(Expr, Expr)
    /// Truncated subtraction, exactly like Lean's `Nat` (5 - 7 = 0).
    case sub(Expr, Expr)
    case mul(Expr, Expr)
    /// Floor division, exactly like Lean's `Nat` (x / 0 = 0).
    case div(Expr, Expr)
    case min(Expr, Expr)
    case le(Expr, Expr)
    case lt(Expr, Expr)
    case eq(Expr, Expr)
    case and(Expr, Expr)
    case or(Expr, Expr)
    case not(Expr)
    case implies(Expr, Expr)
    case ifThenElse(Expr, Expr, Expr)
    case call(String, [Expr])
}

extension Expr: ExpressibleByIntegerLiteral, ExpressibleByBooleanLiteral {
    public init(integerLiteral value: UInt64) { self = .natLiteral(value) }
    public init(booleanLiteral value: Bool) { self = .boolLiteral(value) }
}

public struct Param: Sendable, Equatable {
    public let name: String
    public let type: SpecType
    public init(_ name: String, _ type: SpecType) {
        self.name = name
        self.type = type
    }
}

public enum Declaration: Sendable, Equatable {
    case function(name: String, params: [Param], returns: SpecType, body: Expr)
    /// `proof` is a Lean tactic script. It is the slot an AI agent fills in;
    /// the Lean kernel, not the agent, decides whether it is accepted.
    case theorem(name: String, binders: [Param], statement: Expr, proof: String)
}

// MARK: - Swift-flavoured syntax

public func variable(_ name: String) -> Expr { .variable(name) }
public func call(_ name: String, _ args: Expr...) -> Expr { .call(name, args) }
public func min(_ a: Expr, _ b: Expr) -> Expr { .min(a, b) }
public func ifThen(_ c: Expr, _ t: Expr, else e: Expr) -> Expr { .ifThenElse(c, t, e) }
public func equals(_ a: Expr, _ b: Expr) -> Expr { .eq(a, b) }

public func + (a: Expr, b: Expr) -> Expr { .add(a, b) }
public func - (a: Expr, b: Expr) -> Expr { .sub(a, b) }
public func * (a: Expr, b: Expr) -> Expr { .mul(a, b) }
public func / (a: Expr, b: Expr) -> Expr { .div(a, b) }
public func <= (a: Expr, b: Expr) -> Expr { .le(a, b) }
public func < (a: Expr, b: Expr) -> Expr { .lt(a, b) }
public func && (a: Expr, b: Expr) -> Expr { .and(a, b) }
public func || (a: Expr, b: Expr) -> Expr { .or(a, b) }
public prefix func ! (a: Expr) -> Expr { .not(a) }

infix operator ==>: LogicalDisjunctionPrecedence
public func ==> (a: Expr, b: Expr) -> Expr { .implies(a, b) }

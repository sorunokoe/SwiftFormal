/// Runs a spec inside Swift with the *same* semantics as the generated Lean
/// (truncated Nat subtraction, x / 0 = 0). This turns the proven model into an
/// executable oracle for differential testing of production Swift code.
public struct SpecInterpreter: Sendable {
    public enum Value: Sendable, Equatable, CustomStringConvertible {
        case nat(UInt64)
        case bool(Bool)

        public var description: String {
            switch self {
            case let .nat(n): "\(n)"
            case let .bool(b): "\(b)"
            }
        }
    }

    public enum Failure: Error, Equatable {
        case unknownFunction(String)
        case unboundVariable(String)
        case typeMismatch(String)
        case overflow
    }

    let functions: [String: (params: [Param], body: Expr)]

    public init(_ module: SpecModule) {
        var fs: [String: (params: [Param], body: Expr)] = [:]
        for case let .function(name, params, _, body) in module.declarations {
            fs[name] = (params, body)
        }
        functions = fs
    }

    public func call(_ name: String, _ args: [Value]) throws -> Value {
        guard let f = functions[name] else { throw Failure.unknownFunction(name) }
        let env = Dictionary(uniqueKeysWithValues: zip(f.params.map(\.name), args))
        return try eval(f.body, env)
    }

    public func eval(_ e: Expr, _ env: [String: Value]) throws -> Value {
        func nat(_ x: Expr) throws -> UInt64 {
            guard case let .nat(n) = try eval(x, env) else { throw Failure.typeMismatch("expected Nat") }
            return n
        }
        func bool(_ x: Expr) throws -> Bool {
            guard case let .bool(b) = try eval(x, env) else { throw Failure.typeMismatch("expected Bool") }
            return b
        }
        // Lean's Nat is unbounded; we refuse to silently wrap instead of pretending.
        func checked(_ r: (partialValue: UInt64, overflow: Bool)) throws -> Value {
            if r.overflow { throw Failure.overflow }
            return .nat(r.partialValue)
        }

        switch e {
        case let .variable(n):
            guard let v = env[n] else { throw Failure.unboundVariable(n) }
            return v
        case let .natLiteral(v): return .nat(v)
        case let .boolLiteral(b): return .bool(b)
        case let .add(a, b): return try checked(nat(a).addingReportingOverflow(nat(b)))
        case let .sub(a, b):
            let (x, y) = (try nat(a), try nat(b))
            return .nat(x >= y ? x - y : 0)
        case let .mul(a, b): return try checked(nat(a).multipliedReportingOverflow(by: nat(b)))
        case let .div(a, b):
            let (x, y) = (try nat(a), try nat(b))
            return .nat(y == 0 ? 0 : x / y)
        case let .min(a, b): return .nat(Swift.min(try nat(a), try nat(b)))
        case let .le(a, b): return .bool(try nat(a) <= nat(b))
        case let .lt(a, b): return .bool(try nat(a) < nat(b))
        case let .eq(a, b): return .bool(try eval(a, env) == eval(b, env))
        case let .and(a, b): return .bool(try bool(a) ? try bool(b) : false)
        case let .or(a, b): return .bool(try bool(a) ? true : try bool(b))
        case let .not(a): return .bool(!(try bool(a)))
        case let .implies(a, b): return .bool(try bool(a) ? try bool(b) : true)
        case let .ifThenElse(c, t, f): return try bool(c) ? eval(t, env) : eval(f, env)
        case let .call(name, args): return try call(name, args.map { try eval($0, env) })
        }
    }
}

/// Cedar-style differential random testing: compare a production function
/// against the spec on many random inputs and return the first disagreement.
public struct Mismatch: Sendable, CustomStringConvertible {
    public let inputs: [UInt64]
    public let spec: SpecInterpreter.Value
    public let production: SpecInterpreter.Value
    public var description: String { "inputs=\(inputs) spec=\(spec) production=\(production)" }
}

public func differentialTest(
    _ module: SpecModule,
    function name: String,
    arity: Int,
    iterations: Int = 10_000,
    range: ClosedRange<UInt64> = 0...10_000,
    edgeCases: [UInt64] = [0, 1],
    production: ([UInt64]) -> SpecInterpreter.Value
) throws -> Mismatch? {
    let interpreter = SpecInterpreter(module)
    var generator = SystemRandomNumberGenerator()
    for i in 0..<iterations {
        let inputs: [UInt64] = (0..<arity).map { _ in
            // Mix boundary values in with random ones: boundaries find most bugs.
            i % 4 == 0 ? edgeCases.randomElement(using: &generator)! : UInt64.random(in: range, using: &generator)
        }
        let expected = try interpreter.call(name, inputs.map { .nat($0) })
        let actual = production(inputs)
        if expected != actual { return Mismatch(inputs: inputs, spec: expected, production: actual) }
    }
    return nil
}

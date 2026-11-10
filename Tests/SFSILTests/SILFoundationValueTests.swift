import Foundation
import Testing

@testable import SFSIL

/// `Date` arithmetic and comparisons (`SILFoundationValues.swift`) against Foundation itself: for each operation and
/// pair of values, a function that overflows unless the operation gives what Foundation gives here, to the bit.
@Suite(.tags(.slow)) struct SILFoundationValueTests {
    /// An operation: its name, its code (a statement, or for a comparison the operator) and what Foundation computes.
    struct Pin<Native: Sendable>: Sendable {
        let name: String
        let code: String
        let native: Native
        init(_ name: String, _ code: String, _ native: Native) { (self.name, self.code, self.native) = (name, code, native) }
    }

    static let values: [Double] = [0.1, -0.0, 978_307_200.5, -1e300, .infinity, .nan]

    static func literal(_ x: Double) -> String { "Double(bitPattern: 0x\(String(x.bitPattern, radix: 16)))" }

    /// A statement list that leaves the operation's `Double` in `r`, and what Foundation computes for it.
    static let doubles: [Pin<@Sendable (Double, Double) -> Double>] = [
        Pin(
            "make1970", "let r = Date(timeIntervalSince1970: a).timeIntervalSinceReferenceDate",
            { a, _ in Date(timeIntervalSince1970: a).timeIntervalSinceReferenceDate }
        ),
        Pin(
            "since1970", "let r = Date(timeIntervalSinceReferenceDate: a).timeIntervalSince1970",
            { a, _ in Date(timeIntervalSinceReferenceDate: a).timeIntervalSince1970 }
        ),
        Pin(
            "adding", "let r = Date(timeIntervalSinceReferenceDate: a).addingTimeInterval(b).timeIntervalSinceReferenceDate",
            { a, b in Date(timeIntervalSinceReferenceDate: a).addingTimeInterval(b).timeIntervalSinceReferenceDate }
        ),
        Pin(
            "plus", "let r = (Date(timeIntervalSinceReferenceDate: a) + b).timeIntervalSinceReferenceDate",
            { a, b in (Date(timeIntervalSinceReferenceDate: a) + b).timeIntervalSinceReferenceDate }
        ),
        Pin(
            "minus", "let r = (Date(timeIntervalSinceReferenceDate: a) - b).timeIntervalSinceReferenceDate",
            { a, b in (Date(timeIntervalSinceReferenceDate: a) - b).timeIntervalSinceReferenceDate }
        ),
        Pin(
            "plusIs", "var d = Date(timeIntervalSinceReferenceDate: a); d += b; let r = d.timeIntervalSinceReferenceDate",
            { a, b in
                var d = Date(timeIntervalSinceReferenceDate: a)
                d += b
                return d.timeIntervalSinceReferenceDate
            }
        ),
        Pin(
            "minusIs", "var d = Date(timeIntervalSinceReferenceDate: a); d -= b; let r = d.timeIntervalSinceReferenceDate",
            { a, b in
                var d = Date(timeIntervalSinceReferenceDate: a)
                d -= b
                return d.timeIntervalSinceReferenceDate
            }
        ),
        Pin(
            "addTime", "var d = Date(timeIntervalSinceReferenceDate: a); d.addTimeInterval(b); let r = d.timeIntervalSinceReferenceDate",
            { a, b in
                var d = Date(timeIntervalSinceReferenceDate: a)
                d.addTimeInterval(b)
                return d.timeIntervalSinceReferenceDate
            }
        ),
        Pin(
            "since", "let r = Date(timeInterval: b, since: Date(timeIntervalSinceReferenceDate: a)).timeIntervalSinceReferenceDate",
            { a, b in Date(timeInterval: b, since: Date(timeIntervalSinceReferenceDate: a)).timeIntervalSinceReferenceDate }
        ),
        Pin(
            "between", "let r = Date(timeIntervalSinceReferenceDate: a).timeIntervalSince(Date(timeIntervalSinceReferenceDate: b))",
            { a, b in Date(timeIntervalSinceReferenceDate: a).timeIntervalSince(Date(timeIntervalSinceReferenceDate: b)) }
        ),
        Pin(
            "past", "let r = Date.distantPast.timeIntervalSinceReferenceDate + a * 0",
            { a, _ in Date.distantPast.timeIntervalSinceReferenceDate + a * 0 }
        ),
        Pin(
            "future", "let r = Date.distantFuture.timeIntervalSinceReferenceDate + a * 0",
            { a, _ in Date.distantFuture.timeIntervalSinceReferenceDate + a * 0 }
        ),
    ]

    static let comparisons: [Pin<@Sendable (Date, Date) -> Bool>] = [
        Pin("eq", "==", { $0 == $1 }), Pin("lt", "<", { $0 < $1 }), Pin("gt", ">", { $0 > $1 }), Pin("le", "<=", { $0 <= $1 }),
        Pin("ge", ">=", { $0 >= $1 }),
    ]

    /// `name` with the expected outcome of each generated function.
    static func source() -> (text: String, names: [String]) {
        var text = "import Foundation\n"
        var names: [String] = []
        for (i, a) in values.enumerated() {
            for (j, b) in values.enumerated() {
                let head = "let a = \(literal(a)); let b = \(literal(b)); _ = b"
                for op in doubles {
                    let expected = op.native(a, b)
                    let check = expected.isNaN ? "r != r" : "r.bitPattern == 0x\(String(expected.bitPattern, radix: 16))"
                    let name = "\(op.name)_\(i)_\(j)"
                    names.append(name)
                    text += "public func \(name)(_ x: Int8) -> Int8 { \(head); \(op.code); return \(check) ? x : x + 1 }\n"
                }
                for op in comparisons {
                    let expected = op.native(Date(timeIntervalSinceReferenceDate: a), Date(timeIntervalSinceReferenceDate: b))
                    let name = "\(op.name)_\(i)_\(j)"
                    names.append(name)
                    text +=
                        "public func \(name)(_ x: Int8) -> Int8 { \(head); let r = Date(timeIntervalSinceReferenceDate: a) "
                        + "\(op.code) Date(timeIntervalSinceReferenceDate: b); return r == \(expected) ? x : x + 1 }\n"
                }
            }
        }
        return (text, names)
    }

    @Test func dateArithmeticIsFoundations() throws {
        let (text, names) = Self.source()
        var module = try SILCompiler.module(source: text, name: "Pin", optimization: .none)
        module.confirmPackageTypes(["Date"])
        var wrong: [String] = []
        for name in names {
            let verdict = try SILVerifier.proveAggregate(try module.symbol(module: "Pin", name: name), in: module)
            if verdict != .proved { wrong.append("\(name): \(verdict)") }
        }
        #expect(wrong.isEmpty, "\(wrong)")
    }
}

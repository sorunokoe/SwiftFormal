// Built-in properties as static members of `Property`. Inside a builder, the types in PropertyTypes.swift
// (`Deterministic()`, `Matches(table: [...])`) read better; these members are for code that builds a `Property` value,
// and for a closure with a single property (`{ .deterministic() }`). With several, name the type, because Swift
// reads a line that starts with `.` as a continuation of the previous line.

extension Property where Output: Equatable {
    /// Evaluating the function twice on the same input gives the same output.
    public static func deterministic() -> Property {
        .custom("deterministic") {
            var observer = Observer(observe: { input, output, evaluate in
                do {
                    let again = try evaluate(input)
                    return again == output ? nil : "first \(show(output)), second \(show(again))"
                } catch {
                    return "second evaluation threw \(error)"
                }
            })
            observer.reevaluatesOnce = true
            return observer
        }
    }

    /// The function agrees with `oracle` on every input. `oracle` can be an independent statement of the
    /// intended mapping, a golden table, or the previous version of a Rule you are refactoring.
    public static func matches(_ oracle: @escaping (Input) throws -> Output) -> Property {
        matches("matches oracle", oracle)
    }

    /// A property that fails when the output differs from what `oracle` returns for the same input; `name` is used in the report.
    public static func matches(_ name: String, _ oracle: @escaping (Input) throws -> Output) -> Property {
        .perInput(name) { input, output in
            do {
                let expected = try oracle(input)
                return expected == output ? nil : "expected \(show(expected)), got \(show(output))"
            } catch {
                return "oracle threw \(error)"
            }
        }
    }
}

extension Property where Input: Equatable, Output: Equatable {
    /// A golden table written as `input: output` rows. It is exhaustive: an input of the domain with no
    /// row is a failure, so adding an enum case forces a decision about its row.
    ///
    /// ```swift
    /// Property.table([.anyone: "Everyone", .friends: "Friends", .nobody: "Only me"])
    /// ```
    public static func table(_ rows: KeyValuePairs<Input, Output>) -> Property {
        .perInput("matches table") { input, output in
            guard let row = rows.first(where: { $0.key == input }) else {
                return "no row for this input (the table must cover the whole domain)"
            }
            return row.value == output ? nil : "expected \(show(row.value)), got \(show(output))"
        }
    }
}

extension Property where Input: Hashable, Output: Equatable {
    /// A golden table written as `input: output` rows, as `table(_:)` for `Equatable` inputs, with each input's row found
    /// by hashing instead of a search of the rows. The first row of an input counts, as there.
    public static func table(_ rows: KeyValuePairs<Input, Output>) -> Property {
        let expected = Dictionary(rows.map { ($0.key, $0.value) }, uniquingKeysWith: { first, _ in first })
        return .perInput("matches table") { input, output in
            guard let value = expected[input] else {
                return "no row for this input (the table must cover the whole domain)"
            }
            return value == output ? nil : "expected \(show(value)), got \(show(output))"
        }
    }
}

extension Property where Output: Hashable {
    /// Different inputs never give the same output. The failure names the first collision.
    ///
    /// A sampled walk draws with replacement, so the same input can come twice. An earlier input that is provably the
    /// same value (equal by `Equatable`, or a tuple or struct whose stored parts are all equal) is not a collision.
    public static func injective() -> Property {
        .custom("injective") {
            var seen: [Output: Input] = [:]
            return .init(observe: { input, output, _ in
                if let earlier = seen[output], !isSameValue(earlier, input) {
                    return "\(show(earlier)) and \(show(input)) both give \(show(output))"
                }
                seen[output] = input
                return nil
            })
        }
    }

    /// The set of outputs is exactly `expected`: nothing outside it, and every member reached.
    /// Reaching every member can only be concluded when the whole domain was walked.
    public static func image(equals expected: Set<Output>) -> Property {
        .custom("image equals expected set") {
            var seen: Set<Output> = []
            return .init(
                observe: { _, output, _ in
                    seen.insert(output)
                    return expected.contains(output) ? nil : "unexpected output \(show(output))"
                },
                finish: { wholeDomain in
                    guard wholeDomain else { return nil }
                    let missing = expected.subtracting(seen)
                    return missing.isEmpty ? nil : "never produced: \(missing.map(show).sorted().joined(separator: ", "))"
                }
            )
        }
    }

    /// Every output is in `allowed`. Unlike `image(equals:)`, members may go unreached.
    public static func image(within allowed: Set<Output>) -> Property {
        .perInput("image within allowed set") { _, output in
            allowed.contains(output) ? nil : "unexpected output \(show(output))"
        }
    }
}

extension Property where Input: Equatable {
    /// `inverse` maps every output back to its input.
    public static func roundTrip(through inverse: @escaping (Output) throws -> Input) -> Property {
        .perInput("round trip") { input, output in
            do {
                let back = try inverse(output)
                return back == input ? nil : "\(show(input)) -> \(show(output)) -> \(show(back))"
            } catch {
                return "inverse threw \(error)"
            }
        }
    }
}

extension Property {
    /// A predicate over each input and its output, for example "an invalid password is never `.valid`".
    public static func satisfies(_ name: String, _ predicate: @escaping (Input, Output) -> Bool) -> Property {
        .perInput(name) { input, output in
            predicate(input, output) ? nil : "gave \(show(output))"
        }
    }

    /// Whenever `precondition` holds for the input, `predicate` holds for the output.
    public static func satisfies(
        _ name: String,
        when precondition: @escaping (Input) -> Bool,
        then predicate: @escaping (Output) -> Bool
    ) -> Property {
        .perInput(name) { input, output in
            !precondition(input) || predicate(output) ? nil : "gave \(show(output))"
        }
    }
}

func show<T>(_ value: T) -> String {
    let text = String(reflecting: value)
    return text.count > 200 ? String(text.prefix(200)) + "..." : text
}

/// Whether `a` and `b` are provably the same value. `false` when it cannot tell, so a real collision is never hidden:
/// classes, enums and parts that are not `Equatable` are not compared.
private func isSameValue(_ a: Any, _ b: Any) -> Bool {
    if let a = a as? any Equatable { return isEqual(a, b) }
    let left = Mirror(reflecting: a)
    let right = Mirror(reflecting: b)
    guard left.displayStyle == .tuple || left.displayStyle == .struct, left.displayStyle == right.displayStyle,
        left.subjectType == right.subjectType, left.children.count == right.children.count
    else { return false }
    return zip(left.children, right.children).allSatisfy { $0.label == $1.label && isSameValue($0.value, $1.value) }
}

private func isEqual<T: Equatable>(_ a: T, _ b: Any) -> Bool {
    guard let b = b as? T else { return false }
    return a == b
}

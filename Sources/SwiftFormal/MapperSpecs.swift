// Properties that say a mapper maps correctly, beyond one input at a time (mapper verification, Phase 2):
//
//     Prove("BandRule.body", it: { BandRule(input: $0).execute() }, over: ratings) {
//         Agrees(with: { LegacyBandRule(input: $0).execute() })
//         Injective(except: [(.unknown, .notSet)])
//         NeverOutputs("")
//     }
//
// `swiftformal check` also proves `Injective()`, `RoundTrip(through:)`, `Matches` and `Agrees(with:)` for every input
// with logic when it can read the closures (docs/guides/walk.md, "Relational claims"); the other forms here are walked only.

/// Two rules give the same output for every input: a sibling rule, a reference version, or the rule a refactor replaces.
public struct Agrees<Input, Output>: PropertyConvertible {
    /// The property this value stands for.
    public let property: Property<Input, Output>

    /// Checks that `other` gives the same output (by `==`) for every input.
    public init(with other: @escaping (Input) throws -> Output) where Output: Equatable {
        self.init("agrees with other rule", with: other)
    }

    /// Checks that `other` gives the same output (by `==`) for every input; `name` is used in the report.
    public init(_ name: String, with other: @escaping (Input) throws -> Output) where Output: Equatable {
        property = .matches(name, other)
    }

    /// Checks that `relation(output, otherOutput)` holds for every input: for two rules whose outputs have different
    /// types, or agree only up to a relation (`{ $0 == $1.rawValue }`). Walked only.
    public init<Other>(with other: @escaping (Input) throws -> Other, where relation: @escaping (Output, Other) -> Bool) {
        self.init("agrees with other rule (relation)", with: other, where: relation)
    }

    /// `init(with:where:)` with `name` in the report.
    public init<Other>(_ name: String, with other: @escaping (Input) throws -> Other, where relation: @escaping (Output, Other) -> Bool) {
        property = .perInput(name) { input, output in
            do {
                let expected = try other(input)
                return relation(output, expected) ? nil : "gave \(show(output)), the other rule \(show(expected))"
            } catch {
                return "the other rule threw \(error)"
            }
        }
    }
}

extension Injective where Input: Equatable {
    /// Checks that no two different inputs give the same output, except the pairs in `merges` (in either order): the
    /// merges a mapper is meant to make, written down so that any other merge fails. A listed pair that was walked and
    /// gives two different outputs fails too, so the list cannot go stale. Walked only.
    ///
    /// ```swift
    /// Injective(except: [(.unknown, .notSet)])  // both show "Not set"
    /// ```
    public init(except merges: [(Input, Input)]) {
        property = .custom("injective except listed merges") {
            var seen: [Output: [Input]] = [:]
            var walked: [(input: Input, output: Output)] = []
            func listed(_ a: Input, _ b: Input) -> Bool {
                merges.contains { ($0.0 == a && $0.1 == b) || ($0.0 == b && $0.1 == a) }
            }
            return .init(
                observe: { input, output, _ in
                    if merges.contains(where: { $0.0 == input || $0.1 == input }) { walked.append((input, output)) }
                    let earlier = seen[output, default: []]
                    seen[output, default: []].append(input)
                    guard let other = earlier.first(where: { $0 != input && !listed($0, input) }) else { return nil }
                    return "\(show(other)) and \(show(input)) both give \(show(output)), and the pair is not listed"
                },
                finish: { _ in
                    for (a, b) in merges {
                        guard let first = walked.first(where: { $0.input == a }), let second = walked.first(where: { $0.input == b }),
                            first.output != second.output
                        else { continue }
                        return "\(show(a)) and \(show(b)) are listed as merged but give \(show(first.output)) and \(show(second.output))"
                    }
                    return nil
                }
            )
        }
    }
}

/// Outputs a mapper must never give: an empty text, a raw localization key, a placeholder. Walked only.
public struct NeverOutputs<Input, Output>: PropertyConvertible {
    /// The property this value stands for.
    public let property: Property<Input, Output>

    /// Checks that no input gives one of `forbidden` (by `==`).
    ///
    /// ```swift
    /// NeverOutputs("", "TBD")
    /// ```
    public init(_ forbidden: Output...) where Output: Equatable {
        property = .perInput("never outputs \(forbidden.map(show).joined(separator: ", "))") { _, output in
            forbidden.contains(output) ? "gave \(show(output))" : nil
        }
    }

    /// Checks that `forbidden(input, output)` is false for every input; `name` says what is forbidden in the report.
    ///
    /// ```swift
    /// NeverOutputs("a raw key", where: { _, text in text.hasPrefix("weather.") })
    /// ```
    public init(_ name: String, where forbidden: @escaping (Input, Output) -> Bool) {
        property = .perInput("never outputs \(name)") { input, output in
            forbidden(input, output) ? "gave \(show(output))" : nil
        }
    }
}

import Foundation

/// A `witness_method` instruction: `%8 = witness_method $Square, #Shape.area : …` has id `%8`, type `Square` and
/// requirement `#Shape.area`.
package struct WitnessMethodLine: Equatable {
    /// The value the instruction defines.
    package let id: String
    /// The conforming type, without its `$`.
    package let type: String
    /// The requirement, with its `#`.
    package let requirement: String

    /// The instruction of `line`; nil for any other line.
    package init?(_ line: String) {
        guard let eq = line.range(of: " = witness_method $") else { return nil }
        let rest = line[eq.upperBound...]
        guard let comma = rest.range(of: ", #"), let colon = rest[comma.upperBound...].range(of: " : ") else { return nil }
        id = String(line[..<eq.lowerBound])
        type = String(rest[..<comma.lowerBound])
        requirement = "#" + rest[comma.upperBound..<colon.lowerBound]
    }
}

extension SILModule {
    /// The requirements whose witnesses the encoder looks up by type alone, with no `witness_method` in the code it
    /// reads (comparing, hashing, printing, raw values). The Scan proof cache keys every claim with their code, and
    /// a function with the witnesses of the requirements its own `witness_method`s name; `witness(type:requirement:)`
    /// asserts that it is asked for nothing else.
    package static let encoderWitnessRequirements: Set<String> = Set(
        [#"#Equatable."==""#, "#Hashable._rawHashValue", "#Hashable.hash", "#RawRepresentable.rawValue!getter"]
            + printingRequirements)

    /// The witness functions of the module's witness tables by requirement (`#Hashable.hash`), each list sorted.
    package var witnessSymbolsByRequirement: [String: [String]] {
        var result: [String: Set<String>] = [:]
        for (key, symbol) in witnesses {
            guard let at = key.range(of: ": #", options: .backwards) else { continue }
            result[String(key[key.index(after: at.lowerBound)...]).trimmingCharacters(in: .whitespaces), default: []].insert(symbol)
        }
        return result.mapValues { $0.sorted() }
    }

    /// `witness(type:requirement:)`, for one of `encoderWitnessRequirements`.
    func encoderWitness(type: String, requirement: String) -> String? {
        assert(
            Self.encoderWitnessRequirements.contains(requirement),
            "\(requirement): add it to encoderWitnessRequirements, which the Scan proof cache keys")
        return methodWitness(type: type, requirement: requirement)
    }

    /// The symbol implementing `requirement` for `type`, for a `witness_method` of the code.
    func methodWitness(type: String, requirement: String) -> String? {
        witnesses["\(type): \(requirement)"]
    }
}

// What Swift's default printer prints. A value whose type has no `description` or `debugDescription` of its own is
// printed by reflection: every stored field, the payload of the active enum case and every tuple element is printed in
// turn, each with its own description if it has one. Logic must run those descriptions too.

/// A stored part of a value that printing prints by its own type's rules.
struct PrintedPart: Equatable {
    /// The type of the part, as `describe` looks it up (`Inner`, `Optional<Inner>`, `Array<Inner>`).
    let type: String
    /// Its leaves within the printed value.
    let leaves: Range<Int>
    /// The enum cases that must be active for the part to exist: (tag leaf, case index), outermost first.
    let cases: [(tag: Int, index: Int)]

    static func == (l: Self, r: Self) -> Bool {
        l.type == r.type && l.leaves == r.leaves && l.cases.elementsEqual(r.cases) { $0 == $1 }
    }
}

/// A field of a struct or tuple, or the payload of an enum case (`enumCase`), and its leaves.
private struct StoredPart {
    let type: ValueType
    let leaves: Range<Int>
    let enumCase: Int?
}

extension ValueType {
    /// The parts that printing a value of this layout by reflection prints. Throws for an existential: printing it
    /// runs the description of the value inside, which logic does not know.
    func printedParts() throws -> [PrintedPart] {
        var parts: [PrintedPart] = []
        try collectPrintedParts(of: self, at: 0, cases: [], into: &parts, top: true)
        return parts
    }

    private func collectPrintedParts(
        of layout: ValueType, at start: Int, cases: [(tag: Int, index: Int)], into parts: inout [PrintedPart], top: Bool
    ) throws {
        let leaves = start..<(start + layout.leafWidths.count)
        switch layout {
        case .scalar: return
        case .opaque:
            guard layout != TypeContext.existential else {
                throw SILError.unsupported("printing an existential, which runs the description of the value inside")
            }
            guard layout != TypeContext.objectHandle else {
                throw SILError.unsupported("printing an Objective-C object, which runs its description")
            }
        case .array(let element): parts.append(PrintedPart(type: "Array<\(element.text)>", leaves: leaves, cases: cases))
        case .hashed(let collection): parts.append(PrintedPart(type: collection.description, leaves: leaves, cases: cases))
        case .aggregate(let name, _) where !name.isEmpty && !top, .enumeration(let name, _) where !top:
            parts.append(PrintedPart(type: name, leaves: leaves, cases: cases))
        case .aggregate, .enumeration:
            for part in layout.storedParts() {
                try collectPrintedParts(
                    of: part.type, at: start + part.leaves.lowerBound, cases: cases + (part.enumCase.map { [(start, $0)] } ?? []),
                    into: &parts, top: false)
            }
        }
    }

    /// The fields of a struct or tuple, or the payloads of an enum with the case each belongs to, with their leaves.
    private func storedParts() -> [StoredPart] {
        switch self {
        case .aggregate(_, let fields):
            fields.indices.compactMap { i in leafRange(ofField: i).map { StoredPart(type: fields[i].type, leaves: $0, enumCase: nil) } }
        case .enumeration(_, let cases):
            cases.indices.compactMap { i in cases[i].payload.map { StoredPart(type: $0, leaves: payloadLeafRange(ofCase: i), enumCase: i) }
            }
        case .scalar, .opaque, .array, .hashed: []
        }
    }
}

extension SILModule {
    /// True when `type` may have a witness for `requirement` that `witness(type:requirement:)` does not return: the
    /// conformance is generic (`<T> Box<T>: CustomStringConvertible`), or two linked modules disagree on it.
    package func mayHaveUnknownWitness(type: String, requirement: String) -> Bool {
        if conflictingWitnesses.contains("\(type): \(requirement)") { return true }
        let base = type.firstIndex(of: "<").map { String(type[..<$0]) } ?? type
        return genericWitnessRequirements.contains("\(base): \(requirement)")
    }

    /// `Box` for `sil_witness_table [linkage] <T …> Box<T>: Protocol module M {`; nil for a non-generic table.
    static func genericWitnessTableBase(_ line: String) -> String? {
        guard let open = line.firstIndex(of: "<"), let close = matchingClose(line[open...], open: "<", close: ">") else {
            return nil
        }
        let prefix = line[..<open].split(separator: " ").dropFirst()
        guard prefix.allSatisfy({ $0.hasPrefix("[") || $0.hasSuffix("]") || $0.allSatisfy { $0.isLetter || $0 == "_" } }) else {
            return nil
        }
        let base = line[line.index(after: close)...].drop { $0 == " " }.prefix { $0 != "<" && $0 != ":" && $0 != " " }
        return base.isEmpty ? nil : String(base)
    }
}

extension SILModule {
    /// The requirements whose witnesses Swift's printer may run.
    static let printingRequirements = [
        "#TextOutputStreamable.write", "#CustomStringConvertible.description!getter",
        "#CustomDebugStringConvertible.debugDescription!getter", "#CustomReflectable.customMirror!getter",
    ]
}

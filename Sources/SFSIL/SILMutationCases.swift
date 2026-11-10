import Foundation

// The `swappedCases` edits of `sfverify --mutate` (SILMutation.swift): two cases of a `switch_enum` go to each other's
// code.

extension MutationSite {
    /// One `case #E.c!enumelt: bbN` of a `switch_enum`: its position among the operands, the case and the target.
    private struct SwitchCase {
        let part: Int
        let name: String
        let target: String
    }

    /// `switch_enum %4, case #E.a!enumelt: bb1, case #E.b!enumelt: bb2` becomes `… #E.a!enumelt: bb2, … #E.b!enumelt:
    /// bb1`, for each two neighbouring cases whose targets take the same parameters.
    func swappedCases(_ index: Int, _ line: String, _ code: String) -> [SILMutant] {
        guard code.hasPrefix("switch_enum ") || code.hasPrefix("switch_enum_addr "), !inContractCheck(index) else { return [] }
        let head = String(code.prefix { $0 != " " })
        var parts = splitTopLevel(String(code.dropFirst(head.count)))
        let cases: [SwitchCase] = parts.indices.compactMap { position in
            let part = parts[position]
            guard part.hasPrefix("case #"), let mark = part.range(of: "!enumelt: ") else { return nil }
            let element = part[part.index(part.startIndex, offsetBy: "case #".count)..<mark.lowerBound]
            return SwitchCase(
                part: position, name: String(element.split(separator: ".").last ?? element), target: String(part[mark.upperBound...]))
        }
        let indent = String(line.prefix { $0 == " " })
        var result: [SILMutant] = []
        for (a, b) in zip(cases, cases.dropFirst()) {
            guard destination(a.target) != destination(b.target), let left = blockParameterTypes[a.target],
                left == blockParameterTypes[b.target],
                !callsContractFailure(a.target), !callsContractFailure(b.target)
            else { continue }
            let original = parts
            parts[a.part] = String(original[a.part].dropLast(a.target.count)) + b.target
            parts[b.part] = String(original[b.part].dropLast(b.target.count)) + a.target
            result.append(
                SILMutant(
                    symbol: symbol, line: index,
                    replacement: [indent + head + " " + parts.joined(separator: ", ") + MutationText.location(line)],
                    kind: .swappedCases, description: "the cases .\(a.name) and .\(b.name) are swapped", original: line,
                    anchor: parts.first))
            parts = original
        }
        return result
    }
}

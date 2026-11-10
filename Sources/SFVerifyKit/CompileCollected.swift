import Foundation
import SFSIL

extension SILText {
    /// Positions and messages of the places in one function body where it can trap.
    struct Collected {
        var condFails: [String: (location: SourceLocation, message: String)] = [:]
        var calls: [String: SourceLocation] = [:]
        var failureBlocks: [String: (location: SourceLocation?, message: String)] = [:]
        var parameterNames: [Int: String] = [:]
        /// Source position of each `%value` the function defines, for locating a refusal (plan item U7).
        var values: [String: SourceLocation] = [:]
        private var block = ""
        /// String literals and `cond_fail` messages of each block, in order.
        private var strings: [String: [String]] = [:]
        private var firstLocation: [String: SourceLocation] = [:]

        /// Where `%x = …` (or `(%x, %y) = …`) defines its first value.
        private mutating func recordValue(_ trimmed: Substring, at loc: SourceLocation?) {
            guard let loc, trimmed.hasPrefix("%") || trimmed.hasPrefix("(%"), trimmed.contains(" = ") else { return }
            values[String(trimmed.drop { $0 == "(" }.prefix { $0 != " " && $0 != "," })] = loc
        }

        mutating func record(_ line: String) {
            let trimmed = line.drop { $0 == " " }
            if trimmed.hasPrefix("bb"), let colon = trimmed.firstIndex(where: { $0 == ":" || $0 == "(" }) {
                block = String(trimmed[..<colon])
                return
            }
            let loc = SILText.location(in: line)
            if firstLocation[block] == nil, let loc { firstLocation[block] = loc }
            recordValue(trimmed, at: loc)
            if trimmed.hasPrefix("debug_value "), let n = trimmed.byteRange(of: ", name \""), let a = trimmed.byteRange(of: ", argno "),
                let index = Int(trimmed[a.upperBound...].prefix { $0.isNumber })
            {
                parameterNames[index] = String(trimmed[n.upperBound...].prefix { $0 != "\"" })
            } else if trimmed.hasPrefix("cond_fail "), let loc {
                let operand = trimmed.dropFirst("cond_fail ".count).prefix { $0 != "," && $0 != " " }
                var message = ""
                if let open = line.firstIndex(of: "\""), let close = line[line.index(after: open)...].firstIndex(of: "\"") {
                    message = String(line[line.index(after: open)..<close])
                }
                condFails[String(operand)] = (loc, message)
                strings[block, default: []].append(message)
            } else if trimmed.hasPrefix("%"), trimmed.bytesContain(" = apply "), let loc {
                calls[String(trimmed.prefix { $0 != " " })] = loc
            } else if trimmed.hasPrefix("(%"), trimmed.bytesContain(" = begin_apply "), let loc {
                calls[String(trimmed.dropFirst().prefix { $0 != "," && $0 != " " })] = loc
            } else if trimmed.bytesContain("string_literal utf8 \""),
                let open = line.firstIndex(of: "\""), let close = line[line.index(after: open)...].firstIndex(of: "\"")
            {
                strings[block, default: []].append(String(line[line.index(after: open)..<close]))
            } else if trimmed.bytesContain("Failed_4file4line"), let kind = ContractFailureCall.kind(of: trimmed) {
                // Both contract-failure symbols contain that text; every other line skips the search for a call.
                let text = strings[block]?.first { !$0.isEmpty && !$0.hasSuffix(".swift") } ?? ""
                failureBlocks[block] = (loc ?? firstLocation[block], text.isEmpty ? kind : "\(kind): \(text)")
            } else if trimmed.hasPrefix("unreachable") {
                // The failure call also passes the "Fatal error" prefix and the file path; the message is the rest.
                let message = strings[block]?.first { !$0.isEmpty && $0 != "Fatal error" && !$0.hasSuffix(".swift") } ?? ""
                failureBlocks[block] = (loc ?? firstLocation[block], message)
            }
        }
    }
}

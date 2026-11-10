import Foundation

/// How `swiftformal check` links a walk whose subject is a member of its input (`$0.label`) to a scanned function.
extension Check {
    /// `label` for a walk subject `$0.label`: a member of the walk's input, whose type the walk reports when it runs.
    public static func inputMember(_ subject: String) -> String? {
        guard subject.hasPrefix("$0.") else { return nil }
        let member = subject.dropFirst(3).prefix { $0.isLetter || $0.isNumber || $0 == "_" }
        return member.isEmpty ? nil : String(member)
    }

    /// `Outer.Surface` for `AppFeature.Outer.Surface`: the type as scanned function names write it, without the module,
    /// generic arguments or the `(unknown context at …)` of a private type.
    public static func typeKey(reflecting name: String) -> String {
        var plain = ""
        var depth = 0
        for character in name {
            if character == "<" || character == "(" { depth += 1 }
            if depth == 0 { plain.append(character) }
            if character == ">" || character == ")" { depth -= 1 }
        }
        let parts = plain.split(separator: ".").filter { !$0.isEmpty }
        return parts.dropFirst(parts.count > 1 ? 1 : 0).joined(separator: ".")
    }

    /// The argument labels of a scanned function name or a walk subject: `["from"]` for `LanguageOption.init(from:)`,
    /// `[]` for `execute()`, `nil` for a property (`Surface.label.getter`), a type, or labels that cannot be read.
    public static func argumentLabels(_ name: String) -> [String]? {
        var text = Substring(name)
        if text.hasPrefix("static ") { text = text.dropFirst(7) }
        let key = text.prefix { $0.isLetter || $0.isNumber || $0 == "_" || $0 == "." || $0 == "<" || $0 == ">" }
        let rest = text.dropFirst(key.count)
        guard rest.first == "(", let close = rest.firstIndex(of: ")") else { return nil }
        return referenceLabels(rest[rest.index(after: rest.startIndex)..<close])
    }

    /// Whether a walk with `subject` may cover the function with `functionKey` before it has run: what `covers` says,
    /// or, for `$0.member`, any function named `member` of some type.
    static func mayCover(subject: String, functionKey: String) -> Bool {
        if let member = inputMember(subject) { return functionKey.hasSuffix("." + member) }
        return covers(subjectKey: subjectKey(subject), functionKey: functionKey)
    }
}

/// Links walk subjects to scanned functions: by `Type.member`, and by argument labels when the subject has them, so a
/// walk over `init(from:)` never counts for `init(rawValue:)`. The labels must be the same (`*` matches any), or, when
/// no scanned function has exactly the subject's labels, contain them in order: a call may leave out defaulted
/// arguments, as `Formatter.text(for:)` calls `text(for:style:)`. A subject without labels covers every function of
/// its `Type.member`, or of its type. The labels are those of every function of the scans, also those a selector left
/// out: which overload a walk links to must not depend on which function is selected.
struct WalkLinker {
    private var labelsByKey: [String: [[String]]] = [:]

    init(scans: [ScanReport]) {
        for scan in scans {
            for function in scan.inventory {
                guard let labels = Check.argumentLabels(function.name) else { continue }
                labelsByKey[Check.functionKey(function.name), default: []].append(labels)
            }
        }
    }

    func covers(subject: String, functionName: String) -> Bool {
        let subjectKey = Check.subjectKey(subject)
        let functionKey = Check.functionKey(functionName)
        guard Check.covers(subjectKey: subjectKey, functionKey: functionKey) else { return false }
        guard let wanted = Check.argumentLabels(subject) else { return true }
        guard subjectKey == functionKey, let labels = Check.argumentLabels(functionName) else { return false }
        if Self.same(wanted, labels) { return true }
        let exact = labelsByKey[functionKey, default: []].contains { Self.same(wanted, $0) }
        return !exact && Self.contained(wanted, in: labels)
    }

    /// `covers`, or, for a `$0.member` walk whose input type is not known yet, any function named `member`.
    func mayCover(_ walk: WalkCheck, functionName: String, key: String) -> Bool {
        Check.inputMember(walk.subject) != nil
            ? Check.mayCover(subject: walk.subject, functionKey: key) : covers(subject: walk.subject, functionName: functionName)
    }

    /// Whether this subject names some scanned function.
    func linksToAny(subject: String, among names: [String]) -> Bool {
        names.contains { covers(subject: subject, functionName: $0) }
    }

    private static func same(_ wanted: [String], _ labels: [String]) -> Bool {
        wanted.count == labels.count && zip(wanted, labels).allSatisfy { $0 == "*" || $0 == $1 }
    }

    private static func contained(_ wanted: [String], in labels: [String]) -> Bool {
        var remaining = labels[...]
        for label in wanted {
            guard let index = remaining.firstIndex(where: { label == "*" || label == $0 }) else { return false }
            remaining = remaining[remaining.index(after: index)...]
        }
        return true
    }
}

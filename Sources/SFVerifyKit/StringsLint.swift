import Foundation

// Reading guide
// `swiftformal strings`: a check of localization catalogues that needs no solver. It reads `.strings`, `.stringsdict`
// (in `<language>.lproj` folders: one table per file name) and `.xcstrings` (one table per file), and reports for
// every key:
//
// - missing: a language of its table has no text for it (a `.xcstrings` key need not have one in the source
//   language unless it looks like an identifier, `club.driver`, since the key is then shown as it is);
// - format: a language's text reads more arguments than the reference language's, or reads one as another type
//   (`%d` where it is `%@`): `String(format:)` then reads memory it was not given. A plural form may use fewer;
// - the text is the key: a key that looks like an identifier is shown untranslated.
//
// With source folders, it also lists literal keys of `NSLocalizedString("…")`, `String(localized: "…")` and
// `"…".localized…` that no table has. The reference language of a table is the `.xcstrings` source language, else
// `en`, `Base` or the first one.

/// `swiftformal strings`: checks localization catalogues without a solver.
public enum StringsLint {
    /// What a problem is.
    public enum Kind: String, Codable, Sendable, CaseIterable { case missing, format, textIsKey, unknownKey, unreadable }

    /// One problem of one key, in one language when it is about one.
    public struct Problem: Codable, Equatable, Sendable {
        public var kind: Kind
        public var file: String
        public var key: String
        public var language: String?
        public var detail: String

        public var description: String {
            let place = language.map { " [\($0)]" } ?? ""
            return "\(file): \(key.debugDescription)\(place): \(detail)"
        }
    }

    /// What was read, and every problem found.
    public struct Report: Codable, Sendable {
        public var tables = 0
        public var keys = 0
        public var languages = 0
        public var problems: [Problem] = []

        public func count(_ kind: Kind) -> Int { problems.count { $0.kind == kind } }
    }

    /// One text of a key in one language: its formats (more than one for plural and device variations).
    struct Entry {
        var formats: [String]
        /// Whether some of the formats are variations, which may leave arguments out.
        var varies: Bool
        /// `argNum` and specifier of each `%#@name@` substitution.
        var substitutions: [String: (position: Int?, specifier: String)] = [:]
    }

    /// A table: a key's entry by language, the reference language and whether a missing source text shows the key.
    struct Table {
        var file: String
        var entries: [String: [String: Entry]] = [:]
        var languages: Set<String> = []
        var reference: String?
        var keyIsSourceText = false
        var skipped: Set<String> = []
    }

    /// Checks the catalogues under `paths` (files or folders), and the literal keys of the Swift files under `sources`.
    public static func run(paths: [String], sources: [String] = []) -> Report {
        var report = Report()
        var tables: [String: Table] = [:]
        for file in catalogueFiles(paths) {
            do {
                try read(file, into: &tables)
            } catch {
                report.problems.append(Problem(kind: .unreadable, file: file, key: "", language: nil, detail: "\(error)"))
            }
        }
        var allLanguages: Set<String> = []
        var allKeys: Set<String> = []
        for name in tables.keys.sorted() {
            guard let table = tables[name] else { continue }
            allLanguages.formUnion(table.languages)
            allKeys.formUnion(table.entries.keys)
            report.problems += check(table)
        }
        report.tables = tables.count
        report.keys = allKeys.count
        report.languages = allLanguages.count
        if !sources.isEmpty {
            for (file, key) in sourceKeys(sources) where !allKeys.contains(key) {
                report.problems.append(Problem(kind: .unknownKey, file: file, key: key, language: nil, detail: "no catalogue has this key"))
            }
        }
        return report
    }

    // MARK: checking

    /// A key that looks like an identifier rather than a sentence: no spaces, and a `.` or `_` between word characters.
    static func looksLikeIdentifier(_ key: String) -> Bool {
        !key.isEmpty && !key.contains(where: \.isWhitespace) && key.contains(/\w[._]\w/)
    }

    static func check(_ table: Table) -> [Problem] {
        table.entries.keys.sorted().flatMap { key in
            let byLanguage = table.entries[key] ?? [:]
            return presence(key, byLanguage, table) + formats(key, byLanguage, table)
        }
    }

    /// The languages missing a text of `key`, and those whose text is the key itself.
    static func presence(_ key: String, _ byLanguage: [String: Entry], _ table: Table) -> [Problem] {
        let identifier = looksLikeIdentifier(key)
        var found: [Problem] = []
        for language in table.languages.sorted() {
            if let entry = byLanguage[language] {
                if identifier, entry.formats.contains(key) {
                    found.append(
                        Problem(kind: .textIsKey, file: table.file, key: key, language: language, detail: "the text is the key itself"))
                }
            } else if !table.keyIsSourceText || language != table.reference || identifier {
                found.append(Problem(kind: .missing, file: table.file, key: key, language: language, detail: "no text in this language"))
            }
        }
        return found
    }

    /// The languages whose text of `key` reads other arguments than the reference language's.
    static func formats(_ key: String, _ byLanguage: [String: Entry], _ table: Table) -> [Problem] {
        let languages = table.languages.sorted()
        let reference = table.reference ?? languages.first
        func problem(_ language: String?, _ detail: String) -> Problem {
            Problem(kind: .format, file: table.file, key: key, language: language, detail: detail)
        }
        let expected: [Int: Character]
        if let reference, let entry = byLanguage[reference] {
            switch signature(entry) {
            case .success(let s): expected = s
            case .failure(let why): return [problem(reference, why.text)]
            }
        } else if table.keyIsSourceText, case .success(let s) = signature(Entry(formats: [key], varies: false)) {
            expected = s
        } else {
            return []
        }
        return languages.filter { $0 != reference }.flatMap { language in
            byLanguage[language].map { entry in
                compare(entry, with: expected, reference ?? "the reference").map { problem(language, $0) }
            } ?? []
        }
    }

    /// How the arguments `entry` reads differ from `expected`, the reference language's.
    static func compare(_ entry: Entry, with expected: [Int: Character], _ reference: String) -> [String] {
        let s: [Int: Character]
        switch signature(entry) {
        case .failure(let why): return [why.text]
        case .success(let read): s = read
        }
        var differences: [String] = []
        let (count, expectedCount) = ((s.keys.max() ?? -1) + 1, (expected.keys.max() ?? -1) + 1)
        if count > expectedCount || (count < expectedCount && !entry.varies) {
            differences.append("reads \(count) argument(s), \(reference) reads \(expectedCount)")
        }
        for (position, type) in s.sorted(by: { $0.key < $1.key }) {
            guard let want = expected[position], want != type, want != "?", type != "?" else { continue }
            differences.append("argument \(position + 1) is read as \(name(type)), \(reference) reads \(name(want))")
        }
        return differences
    }
}

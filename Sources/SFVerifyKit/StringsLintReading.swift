import Foundation

// Reading guide
// How `swiftformal strings` finds and reads catalogues (`StringsLint.swift`): `.strings` and `.stringsdict` as
// property lists, `.xcstrings` as JSON, and the literal keys of Swift sources.

extension StringsLint {
    static let skippedFolders: Set<String> = [".build", "build", "DerivedData", "SourcePackages", "Pods", "Carthage", "node_modules"]

    static func files(_ paths: [String], _ keep: (String) -> Bool) -> [String] {
        var out: [String] = []
        let fm = FileManager.default
        for path in paths {
            var isDirectory: ObjCBool = false
            guard fm.fileExists(atPath: path, isDirectory: &isDirectory) else { continue }
            guard isDirectory.boolValue else {
                if keep(path) { out.append(path) }
                continue
            }
            guard let walker = fm.enumerator(atPath: path) else { continue }
            while let relative = walker.nextObject() as? String {
                let name = (relative as NSString).lastPathComponent
                if name.hasPrefix(".") || skippedFolders.contains(name) {
                    walker.skipDescendants()
                    continue
                }
                let full = (path as NSString).appendingPathComponent(relative)
                if keep(full) { out.append(full) }
            }
        }
        return out.sorted()
    }

    static func catalogueFiles(_ paths: [String]) -> [String] {
        files(paths) { ["strings", "stringsdict", "xcstrings"].contains(($0 as NSString).pathExtension) }
    }

    enum ReadError: Error, CustomStringConvertible {
        case notAPropertyList, notJSON
        var description: String {
            switch self {
            case .notAPropertyList: "not a strings file or property list"
            case .notJSON: "not a string catalogue (JSON)"
            }
        }
    }

    static func read(_ file: String, into tables: inout [String: Table]) throws {
        let data = try Data(contentsOf: URL(fileURLWithPath: file))
        let ext = (file as NSString).pathExtension
        if ext == "xcstrings" {
            tables[file] = try catalogue(data, file: file)
            return
        }
        let folder = (file as NSString).deletingLastPathComponent
        guard (folder as NSString).pathExtension == "lproj" else {
            // A table outside an .lproj folder has one language: read for its keys only.
            var table = tables[file] ?? Table(file: file)
            for (key, entry) in try ext == "strings" ? strings(data) : stringsdict(data) { table.entries[key, default: [:]]["?"] = entry }
            tables[file] = table
            return
        }
        let language = ((folder as NSString).lastPathComponent as NSString).deletingPathExtension
        let name = ((folder as NSString).deletingLastPathComponent as NSString).appendingPathComponent(
            ((file as NSString).lastPathComponent as NSString).deletingPathExtension)
        var table = tables[name] ?? Table(file: name)
        table.languages.insert(language)
        for (key, entry) in try ext == "strings" ? strings(data) : stringsdict(data) {
            var merged = table.entries[key, default: [:]][language] ?? Entry(formats: [], varies: false)
            merged.formats += entry.formats
            merged.varies = merged.varies || entry.varies
            merged.substitutions.merge(entry.substitutions) { a, _ in a }
            table.entries[key, default: [:]][language] = merged
        }
        for candidate in ["en", "Base"] where table.languages.contains(candidate) {
            table.reference = candidate
            break
        }
        tables[name] = table
    }

    static func propertyList(_ data: Data) throws -> Any {
        if let list = try? PropertyListSerialization.propertyList(from: data, format: nil) { return list }
        for encoding in [String.Encoding.utf16, .utf8] {
            if let text = String(data: data, encoding: encoding), let utf8 = text.data(using: .utf8),
                let list = try? PropertyListSerialization.propertyList(from: utf8, format: nil)
            {
                return list
            }
        }
        throw ReadError.notAPropertyList
    }

    static func strings(_ data: Data) throws -> [String: Entry] {
        guard let list = try propertyList(data) as? [String: String] else { throw ReadError.notAPropertyList }
        return list.mapValues { Entry(formats: [$0], varies: false) }
    }

    static func stringsdict(_ data: Data) throws -> [String: Entry] {
        guard let list = try propertyList(data) as? [String: Any] else { throw ReadError.notAPropertyList }
        var out: [String: Entry] = [:]
        for (key, value) in list {
            guard let rule = value as? [String: Any], let format = rule["NSStringLocalizedFormatKey"] as? String else { continue }
            var entry = Entry(formats: [format], varies: true)
            for (name, variable) in rule {
                guard let variable = variable as? [String: Any] else { continue }
                if let specifier = variable["NSStringFormatValueTypeKey"] as? String {
                    entry.substitutions[name] = (nil, specifier)
                }
                // A form's own conversions print the variable's value; only positional ones (`%2$@`) read others.
                for (form, text) in variable where form != "NSStringFormatSpecTypeKey" && form != "NSStringFormatValueTypeKey" {
                    if let text = text as? String, text.contains("$") { entry.formats.append(text) }
                }
            }
            out[key] = entry
        }
        return out
    }

    static func catalogue(_ data: Data, file: String) throws -> Table {
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any], let strings = root["strings"] as? [String: Any]
        else { throw ReadError.notJSON }
        var table = Table(file: file)
        table.reference = root["sourceLanguage"] as? String
        table.keyIsSourceText = true
        if let source = table.reference { table.languages.insert(source) }
        for (key, value) in strings {
            guard let item = value as? [String: Any] else { continue }
            if item["shouldTranslate"] as? Bool == false || item["extractionState"] as? String == "stale" {
                table.skipped.insert(key)
                continue
            }
            table.entries[key] = [:]
            for case let (language, localization as [String: Any]) in item["localizations"] as? [String: Any] ?? [:] {
                table.languages.insert(language)
                table.entries[key, default: [:]][language] = entry(localization)
            }
        }
        return table
    }

    /// The entry of one language of an `.xcstrings` key.
    static func entry(_ localization: [String: Any]) -> Entry {
        var entry = Entry(formats: [], varies: false)
        collect(localization, into: &entry)
        for case let (name, substitution as [String: Any]) in localization["substitutions"] as? [String: Any] ?? [:] {
            let position = substitution["argNum"] as? Int
            let specifier = substitution["formatSpecifier"] as? String ?? "@"
            entry.substitutions[name] = (position, specifier)
            // A variation prints the substitution's value as `%arg`.
            var forms = Entry(formats: [], varies: true)
            collect(substitution, into: &forms)
            entry.varies = true
            guard let position else { continue }
            entry.formats += forms.formats.map { $0.replacingOccurrences(of: "%arg", with: "%\(position)$\(specifier)") }
        }
        return entry
    }

    /// The texts of a `stringUnit` and of every variation under `node`.
    static func collect(_ node: [String: Any], into entry: inout Entry) {
        if let unit = node["stringUnit"] as? [String: Any], let value = unit["value"] as? String { entry.formats.append(value) }
        guard let variations = node["variations"] as? [String: Any] else { return }
        entry.varies = true
        for case let kind as [String: Any] in variations.values {
            for case let variation as [String: Any] in kind.values { collect(variation, into: &entry) }
        }
    }

    // MARK: source keys

    static var keyPatterns: [Regex<(Substring, Substring)>] {
        [
            /NSLocalizedString\(\s*"((?:[^"\\]|\\.)*)"/,
            /String\(\s*localized:\s*"((?:[^"\\]|\\.)*)"/,
            /"((?:[^"\\]|\\.)*)"\s*\.localized\b/,
        ]
    }

    /// The literal keys the Swift files under `paths` localize, with the file: no interpolations, no escapes.
    static func sourceKeys(_ paths: [String]) -> [(file: String, key: String)] {
        var out: [(String, String)] = []
        var seen: Set<String> = []
        for file in files(paths, { $0.hasSuffix(".swift") }) {
            guard let text = try? String(contentsOfFile: file, encoding: .utf8) else { continue }
            for pattern in keyPatterns {
                for match in text.matches(of: pattern) {
                    let key = String(match.output.1)
                    guard !key.contains("\\"), seen.insert(key).inserted else { continue }
                    out.append((file, key))
                }
            }
        }
        return out
    }
}

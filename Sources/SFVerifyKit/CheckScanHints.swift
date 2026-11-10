import Foundation

extension Check {
    /// What would link the walks that were not linked: for each type (or free function) their subjects name, the
    /// `--scan <package>:<Target>` whose sources declare it, found by reading the sources of the SwiftPM targets under
    /// `packages` (no build). One line per group of walks; a general hint for the walks whose name no other target
    /// declares. Targets in `scanned` are never suggested.
    public static func scanHints(for walks: [WalkCheck], packages: [String], scanned: [(package: String, target: String)]) -> [String] {
        // `Type` (or a free function), and `Type.member` for a member of an extension (`Double.withFormat`).
        let names = walks.compactMap { walk -> (name: String, member: String?)? in
            let parts = subjectKey(walk.subject).split(separator: ".").map(String.init)
            guard let first = parts.first, !first.isEmpty else { return nil }
            return (first, parts.count > 1 ? first + "." + parts[1] : nil)
        }
        guard !names.isEmpty else { return [] }
        let scannedTargets = Set(scanned.map(\.target))
        var roots: [String] = []
        for root in packages where !roots.contains(where: { samePath($0, root) }) { roots.append(root) }
        let targets = roots.flatMap { sourceTargets(under: $0) }.filter { !scannedTargets.contains($0.name) }
        let declared = targets.map { declaredNames(in: $0.files) }

        // Walks grouped by the targets that declare their name, in the order the walks come.
        var groups: [HintGroup] = []
        for (name, member) in names {
            var owners = targets.indices.filter { declared[$0].contains(name) }
            var shown = name
            if owners.isEmpty, let member {
                owners = targets.indices.filter { declared[$0].contains(member) }
                if !owners.isEmpty { shown = member }
            }
            let scans = owners.map { "\(targets[$0].package):\(targets[$0].name)" }.sorted()
            if let index = groups.firstIndex(where: { $0.scans == scans }) {
                groups[index].walks += 1
                if !groups[index].names.contains(shown) { groups[index].names.append(shown) }
            } else {
                groups.append(HintGroup(scans: scans, walks: 1, names: [shown]))
            }
        }
        return groups.filter { !$0.scans.isEmpty }.map(\.line) + groups.filter(\.scans.isEmpty).map(\.line)
    }

    /// Walks whose names the same targets declare (none: no target does).
    private struct HintGroup {
        var scans: [String]
        var walks: Int
        var names: [String]

        var line: String {
            let one = walks == 1
            let count = one ? "1 walk" : "\(walks) walks"
            let listed = names.joined(separator: ", ")
            switch scans.count {
            case 0:
                return "\(count) name\(one ? "s" : "") no scanned function, and no other target under the given packages declares "
                    + "\(one ? "its type" : "their types") (\(listed)): start the subject with the `Type.member` of a scanned "
                    + "function, or add the `--scan <dir>:<Target>` whose sources declare it"
            case 1:
                return "add --scan \(scans[0]) to link \(count) (it declares \(listed))"
            default:
                return "add one of \(scans.map { "--scan \($0)" }.joined(separator: ", ")) to link \(count) (each declares \(listed))"
            }
        }
    }

    /// The type names, free-function names and extension members (`Double.withFormat`) that `files` declare.
    private static func declaredNames(in files: [String]) -> Set<String> {
        files.reduce(into: Set<String>()) { names, file in
            guard let text = try? String(contentsOfFile: file, encoding: .utf8) else { return }
            names.formUnion(UnlinkedModules.declaredTypes(in: text))
            // A free function's subject starts with its name: `func` names count, not properties.
            names.formUnion(text.matches(of: /\bfunc\s+([a-z_][A-Za-z0-9_]*)/).map { String($0.1) })
            let members = text.matches(of: /\b(?:func|var|let)\s+([A-Za-z_][A-Za-z0-9_]*)/).map { String($0.1) }
            // A member of an extension in this file, as `Type.member` (coarse: any member of the file).
            for extended in text.matches(of: /\bextension\s+([A-Za-z_][A-Za-z0-9_]*)/) {
                names.formUnion(members.map { "\(extended.1).\($0)" })
            }
        }
    }

    /// A SwiftPM target found under a folder: its package directory (as given, joined), name and Swift files.
    struct SourceTarget {
        var package: String
        var name: String
        var files: [String]
    }

    /// The non-test targets of every `Package.swift` under `root`, each with the Swift files of its folder (its
    /// `path:`, or `Sources/<name>`). The manifests are read as text, not evaluated: a target declared in an unusual
    /// way is missed, which only makes the hint general. With `extensions`, files of those kinds are listed too.
    static func sourceTargets(under root: String, extensions: Set<String> = ["swift"]) -> [SourceTarget] {
        let skipped: Set = [".build", ".git", ".swiftpm", "DerivedData", "node_modules", "Pods", "Carthage"]
        guard let walker = FileManager.default.enumerator(atPath: root) else { return [] }
        var manifests: [String] = FileManager.default.fileExists(atPath: root + "/Package.swift") ? [""] : []
        var swiftFiles: [String] = []
        while let relative = walker.nextObject() as? String {
            let last = (relative as NSString).lastPathComponent
            if skipped.contains(last) || last.hasPrefix(".") {
                walker.skipDescendants()
                continue
            }
            if last == "Package.swift" {
                manifests.append((relative as NSString).deletingLastPathComponent)
            } else if extensions.contains((relative as NSString).pathExtension) {
                swiftFiles.append(relative)
            }
        }
        var targets: [(target: SourceTarget, directory: String)] = []
        for manifest in Set(manifests).sorted() {
            let base = manifest.isEmpty ? "" : manifest + "/"
            guard let text = try? String(contentsOfFile: root + "/" + base + "Package.swift", encoding: .utf8) else { continue }
            let declarations = text.matches(of: /\.(target|executableTarget|macro|testTarget|plugin)\(\s*name:\s*"([^"]+)"/)
            for (index, declaration) in declarations.enumerated() where declaration.1 != "testTarget" && declaration.1 != "plugin" {
                let end = index + 1 < declarations.count ? declarations[index + 1].range.lowerBound : text.endIndex
                let path = text[declaration.range.upperBound..<end].firstMatch(of: /path:\s*"([^"]+)"/).map { String($0.1) }
                let name = String(declaration.2)
                let package = manifest.isEmpty ? root : root + "/" + manifest
                targets.append((SourceTarget(package: package, name: name, files: []), base + (path ?? "Sources/" + name)))
            }
        }
        for file in swiftFiles {
            // The innermost target folder holds the file (a nested package's targets are inside the outer folder).
            let owner = targets.indices.filter { file.hasPrefix(targets[$0].directory + "/") }.max {
                targets[$0].directory.count < targets[$1].directory.count
            }
            if let owner { targets[owner].target.files.append(root + "/" + file) }
        }
        return targets.map(\.target).filter { !$0.files.isEmpty }
    }

    private static func samePath(_ a: String, _ b: String) -> Bool {
        URL(fileURLWithPath: a).standardizedFileURL.path == URL(fileURLWithPath: b).standardizedFileURL.path
    }
}

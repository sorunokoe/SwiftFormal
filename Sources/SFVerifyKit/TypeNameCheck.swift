import Foundation
import SFSIL

/// SIL prints types without their module: `Foo` from this module and `Foo` from an imported module look the same.
/// Asks the compiler which of the declared names some other visible module also declares, so they are never resolved
/// to the wrong declaration.
enum TypeNameCheck {
    /// Marks the names of `module` that `imports` also declare as ambiguous, and confirms the package type names
    /// (`SILModule.packageTypeCandidates`) that mean the package's type.
    ///
    /// `sources` are the modules of the build the scan reads (or could not read) from source: never binary modules.
    static func check(_ module: inout SILModule, imports: [String], arguments: [String], sources: Set<String> = []) throws {
        // The two probes are independent (the candidates depend on the imports only): they compile at the same time,
        // and a run that asks the same again (the second build configuration) reuses the answers.
        let names = module.modelledTypeNames
        let candidates = module.packageTypeCandidates
        // The compiler is part of what a probe asks: a run of another `--scan` may compile with another one.
        let compiler = try ScanToolchain.current().swiftc
        let elsewhere = Background {
            try answers.answer(["names", compiler] + names + ["\u{0}"] + imports + ["\u{0}"] + arguments) {
                try declaredElsewhere(names, imports: imports, arguments: arguments)
            }
        }
        let confirmed = Result {
            let key = ["packages", compiler] + candidates.map { "\($0.module).\($0.name)" } + ["\u{0}"] + imports + ["\u{0}"] + arguments
            return try answers.answer(key) {
                try confirmedPackageTypes(candidates, imports: imports, arguments: arguments)
            }
        }
        module.markAmbiguous(try elsewhere.value())
        module.confirmPackageTypes(try confirmed.get())
        let swiftNames = try BinaryTypeCheck.check(&module, imports: imports, arguments: arguments, sources: sources)
        try ForeignTypeCheck.check(&module, imports: imports, arguments: arguments, swiftNames: swiftNames)
    }

    /// Probe answers of this process, by the compiler and everything a probe's file and command are made of. Failures
    /// are not kept.
    private static let answers = ProbeAnswers()

    /// The names in `names` that one of `imports` (or the standard library) also declares.
    ///
    /// Compiles a file that imports `imports` and refers to every name once. A name no imported module declares fails
    /// with "cannot find type"; anything else (the name resolves, is ambiguous, is generic, is inaccessible) counts as
    /// declared elsewhere. If the file cannot be checked at all (an import fails), this throws instead of guessing.
    static func declaredElsewhere(_ names: [String], imports: [String], arguments: [String]) throws -> Set<String> {
        guard !names.isEmpty else { return [] }
        let directory = NSTemporaryDirectory() + "sfverify-names-\(UUID().uuidString)"
        try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: directory) }
        let file = directory + "/SFNameProbe.swift"
        let header = imports.filter { $0 != "Builtin" }.map { "import \($0)" }
        let probes = names.enumerated().map { "typealias SFNameProbe\($0.offset) = \($0.element)" }
        try (header + probes).joined(separator: "\n").appending("\n").write(toFile: file, atomically: true, encoding: .utf8)

        let sdk = try ModuleCompiler.sdkArguments(arguments)
        let result = try ModuleCompiler.run(
            [
                "swiftc", "-frontend", "-typecheck", "-parse-as-library", "-module-name", "SFNameProbe", "-typo-correction-limit", "0",
                "-diagnostic-style", "llvm",
            ]
                + sdk.arguments + ModuleCompiler.withModuleCache(arguments) + ["-no-color-diagnostics", file])
        var cleared: Set<Int> = []
        let failed = SILError.compilerFailed("could not check that type names are unique:\n" + result.errors.prefix(4000))
        for line in result.errors.replacing(/\u{1B}\[[0-9;]*m/, with: "").split(separator: "\n") {
            guard let diagnostic = parse(line, file: file) else {
                if line.contains("error:") { throw failed }
                continue
            }
            let index = diagnostic.line - header.count - 1
            guard names.indices.contains(index) else { throw failed }
            let first = names[index].split(separator: ".").first.map(String.init) ?? names[index]
            if diagnostic.message == "cannot find type '\(first)' in scope" || diagnostic.message.contains("is not a member type of") {
                cleared.insert(index)
            }
        }
        return Set(names.indices.filter { !cleared.contains($0) }.map { names[$0] })
    }

    /// The names in `candidates` that, with `imports`, mean exactly the type of the same name in the given module.
    ///
    /// SIL prints `ObservationStateRegistrar`, not `ComposableArchitecture.ObservationStateRegistrar`. Each name gets
    /// two probe lines: a typealias to the bare name (fails when no module or several declare it) and a function that
    /// returns a bare-name value as the module's type (fails when the bare name means some other type). A name is
    /// confirmed only when neither line has an error; when the probe cannot be checked at all, none is.
    static func confirmedPackageTypes(_ candidates: [(name: String, module: String)], imports: [String], arguments: [String]) throws
        -> Set<String>
    {
        guard !candidates.isEmpty else { return [] }
        let directory = NSTemporaryDirectory() + "sfverify-packages-\(UUID().uuidString)"
        try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: directory) }
        let file = directory + "/SFPackageProbe.swift"
        let header = imports.filter { $0 != "Builtin" }.map { "import \($0)" }
        let probes = candidates.enumerated().flatMap { index, candidate in
            [
                "typealias SFPackageProbe\(index) = \(candidate.name)",
                "func sfPackageProbe\(index)(_ x: SFPackageProbe\(index)) -> \(candidate.module).\(candidate.name) { "
                    + (SILModule.packageProbeBody(candidate.name) ?? "x") + " }",
            ]
        }
        try (header + probes).joined(separator: "\n").appending("\n").write(toFile: file, atomically: true, encoding: .utf8)

        let sdk = try ModuleCompiler.sdkArguments(arguments)
        let result = try ModuleCompiler.run(
            [
                "swiftc", "-frontend", "-typecheck", "-parse-as-library", "-module-name", "SFPackageProbe", "-diagnostic-style", "llvm",
            ]
                + sdk.arguments + ModuleCompiler.withModuleCache(arguments) + ["-no-color-diagnostics", file])
        var failed: Set<Int> = []
        for line in result.errors.replacing(/\u{1B}\[[0-9;]*m/, with: "").split(separator: "\n") {
            guard let diagnostic = parse(line, file: file) else {
                if line.contains("error:") { return [] }
                continue
            }
            let index = (diagnostic.line - header.count - 1) / 2
            guard diagnostic.line > header.count, candidates.indices.contains(index) else { return [] }
            failed.insert(index)
        }
        guard result.status == 0 || !failed.isEmpty else { return [] }
        return Set(candidates.indices.filter { !failed.contains($0) }.map { candidates[$0].name })
    }

    /// `<file>:<line>:<column>: error: <message>`, for errors in `file` only.
    private static func parse(_ text: Substring, file: String) -> (line: Int, message: String)? {
        guard text.hasPrefix(file + ":") else { return nil }
        let parts = text.dropFirst(file.count + 1).split(separator: ":", maxSplits: 3)
        guard parts.count == 4, let line = Int(parts[0]), parts[2] == " error" else { return nil }
        return (line, parts[3].trimmingCharacters(in: .whitespaces))
    }
}

private final class ProbeAnswers: Sendable {
    private let stored = Guarded<[[String]: Set<String>]>([:])

    func answer(_ key: [String], _ probe: () throws -> Set<String>) throws -> Set<String> {
        if let known = stored.withLock({ $0[key] }) { return known }
        let found = try probe()
        stored.withLock { $0[key] = found }
        return found
    }
}

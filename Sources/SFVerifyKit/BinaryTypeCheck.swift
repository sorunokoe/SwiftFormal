import Foundation
import SFSIL

/// The enums and functions of the binary modules a scanned module imports (`SILBinaryTypes.swift`): a framework the scan
/// has no SIL bodies of, such as a Kotlin Multiplatform framework that SKIE exports. Every answer comes from the compiler
/// and the demangler; a step that cannot be done records nothing, so the types stay unsupported, never guessed.
///
/// 1. A typecheck of `switch e {}` per candidate type name: the compiler's "add missing case" notes list the cases of an
///    enum, and "handle unknown values using @unknown default" says that a client must allow cases added later. Its
///    `-Rmodule-loading` remarks say which modules were loaded from a file outside the SDK and the toolchain.
/// 2. SIL of a `switch` over every case: the module of each enum (its mangled name, demangled) and the type of each
///    payload (the destination block's argument).
/// 3. The demangler: the module and a readable name of each function declared without a body.
enum BinaryTypeCheck {
    /// Returns the Swift names of Objective-C classes that their API notes rename without a trace in the compiler's
    /// errors (`SwiftPrivate`: SKIE's `DomainSurface` is `__DomainSurface`), for `ForeignTypeCheck`.
    @discardableResult
    static func check(_ module: inout SILModule, imports: [String], arguments: [String], sources: Set<String>) throws
        -> [String: String]
    {
        let imports = imports.filter { $0 != "Builtin" }
        let toolchain = try ScanToolchain.current()
        let sdk = try ModuleCompiler.sdkArguments(arguments)
        let system = SystemLocations(sdk: sdk.path, toolchain: toolchain)
        guard imports.contains(where: { !system.providesModule($0) }) else { return [:] }
        let candidates = module.binaryEnumCandidates
        let externals = module.externalSymbols
        guard !candidates.isEmpty || !externals.isEmpty else { return [:] }
        let key = ["binary", toolchain.swiftc] + candidates + ["\u{0}"] + externals + ["\u{0}"] + imports + ["\u{0}"] + arguments
        let found =
            try answers.withLock { $0[key] }
            ?? {
                let found = try probe(candidates, externals: externals, imports: imports, arguments: arguments, system: system)
                answers.withLock { $0[key] = found }
                return found
            }()
        guard let found else { return [:] }
        var types = found.types
        types.modules.subtract(sources)
        types.enums = types.enums.filter { types.modules.contains($0.value.module) }
        types.calls = types.calls.filter { types.modules.contains($0.value.module) || SILModule.isOpaqueFoundationCall($0.key) }
        // A case the scanned code names that the compiler did not list means the two disagree: the enum is not read.
        let named = module.enumCaseReferences
        types.enums = types.enums.filter { name, declared in
            named[name, default: []].allSatisfy { reference in declared.cases.contains { $0.name == reference } }
        }
        module.recordBinaryTypes(types, foreignSymbols: found.foreignSymbols)
        return found.swiftNames
    }

    struct Found: Sendable {
        var types = BinaryTypes()
        var foreignSymbols: [String] = []
        /// Objective-C name -> the Swift name of a class the scanned code spells differently (`clangClass`).
        var swiftNames: [String: String] = [:]
    }

    private static let answers = Guarded<[[String]: Found?]>([:])

    /// Nil when a probe could not be read.
    static func probe(_ candidates: [String], externals: [String], imports: [String], arguments: [String], system: SystemLocations)
        throws -> Found?
    {
        let directory = NSTemporaryDirectory() + "sfverify-binary-\(UUID().uuidString)"
        try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: directory) }
        let header = imports.map { "import \($0)" }
        let sdk = try ModuleCompiler.sdkArguments(arguments)
        let common = try sdk.arguments + ModuleCompiler.withModuleCache(arguments) + ["-no-color-diagnostics"]

        let file = directory + "/SFBinaryProbe.swift"
        let probes = candidates.enumerated().map { "func sfbe_\($0.offset)(_ e: \($0.element)) { switch e {} }" }
        try (header + probes).joined(separator: "\n").appending("\n").write(toFile: file, atomically: true, encoding: .utf8)
        let typecheck = try ModuleCompiler.run(
            [
                "swiftc", "-frontend", "-typecheck", "-parse-as-library", "-module-name", "SFBinaryProbe", "-typo-correction-limit", "0",
                "-diagnostic-style", "llvm", "-Rmodule-loading",
            ] + common + [file])
        guard let (listed, plainTypes) = readCases(typecheck.errors, file: file, firstLine: header.count + 1, candidates: candidates)
        else { return nil }
        var found = Found()
        found.types.origins = binaryModules(typecheck.errors, system: system)
        found.types.modules = Set(found.types.origins.keys)
        guard !found.types.modules.isEmpty else { return found }

        if !listed.isEmpty || !plainTypes.isEmpty {
            let sil = try emitSIL(header, listed.sorted { $0.key < $1.key }, plainTypes, common: common, in: directory)
            guard let sil, read(sil, into: &found) else { return nil }
        }
        return readCalls(externals, into: &found) ? found : nil
    }

    private struct ProbeSIL {
        var text: SILFunctionTexts
        var enums: [(key: String, value: Listing)]
        var plainTypes: [String]
    }

    /// The probe of step 2: SIL of a function per enum (`sfbe_<i>`, a `switch` over every case) and per other type
    /// (`sfbt_<i>`, a parameter of the type). Nil when it does not compile.
    private static func emitSIL(
        _ header: [String], _ enums: [(key: String, value: Listing)], _ plainTypes: [String], common: [String], in directory: String
    ) throws -> ProbeSIL? {
        let silFile = directory + "/SFBinaryEnums.swift", output = directory + "/SFBinaryEnums.sil"
        try
            (header + ["@inline(never) func sfbpTake<V>(_ v: V, _ f: (V) -> Void) {}"]
            + enums.enumerated().map { switchSource($0.offset, $0.element.key, $0.element.value) }
            + plainTypes.enumerated().map { "func sfbt_\($0.offset)(_ x: \($0.element)) {}" })
            .joined(separator: "\n").appending("\n").write(toFile: silFile, atomically: true, encoding: .utf8)
        let sil = try ModuleCompiler.run(
            ["swiftc", "-frontend", "-emit-sil", "-parse-as-library", "-module-name", "SFBinaryEnums", "-Onone"] + common
                + [silFile, "-o", output])
        guard sil.status == 0, let text = try? String(contentsOfFile: output, encoding: .utf8) else { return nil }
        return ProbeSIL(text: SILFunctionTexts(text), enums: enums, plainTypes: plainTypes)
    }

    /// Reads the SIL of `emitSIL`: each enum's module and payload types, and the Swift names of renamed classes.
    /// False when the demangler fails.
    private static func read(_ sil: ProbeSIL, into found: inout Found) -> Bool {
        let functions = sil.text
        found.foreignSymbols = functions.symbols
        let symbols =
            sil.enums.indices.compactMap { functions.symbol(named: "sfbe_\($0)") }
            + sil.plainTypes.indices.compactMap { functions.symbol(named: "sfbt_\($0)") }
        guard let demangled = Demangler.spawned(symbols, simplified: false) else { return false }
        for (k, (name, listing)) in sil.enums.enumerated() {
            guard let symbol = functions.symbol(named: "sfbe_\(k)"), let text = demangled[symbol],
                let module = enumModule(text, name: name), found.types.modules.contains(module),
                let payloads = functions.payloads(of: symbol, enum: name)
            else { continue }
            let cases = listing.cases.map { k in
                BinaryTypes.Case(
                    name: k.name, payload: k.hasPayload ? payloads[k.name] : nil, payloadUnknown: k.hasPayload && payloads[k.name] == nil)
            }
            found.types.enums[name] = BinaryTypes.Enumeration(module: module, cases: cases, isOpen: listing.isOpen)
        }
        for (k, name) in sil.plainTypes.enumerated() {
            guard let symbol = functions.symbol(named: "sfbt_\(k)"), let text = demangled[symbol],
                let objectiveC = clangClass(text), objectiveC != name
            else { continue }
            found.swiftNames[objectiveC] = name
        }
        return true
    }

    /// Step 3: the module and label of each function declared without a body, kept when the module is a binary one.
    /// False when the demangler fails.
    private static func readCalls(_ externals: [String], into found: inout Found) -> Bool {
        guard !externals.isEmpty else { return true }
        guard let plain = Demangler.spawned(externals, simplified: false), let simple = Demangler.demangle(externals) else {
            return false
        }
        for symbol in externals {
            guard let text = plain[symbol], let module = functionModule(text),
                found.types.modules.contains(module) || SILModule.isOpaqueFoundationCall(symbol)
            else { continue }
            found.types.calls[symbol] = BinaryTypes.Call(module: module, label: label(simple[symbol] ?? text))
        }
        return true
    }

    // MARK: - reading the probes

    /// A case of an enum, as a note of the compiler lists it.
    struct ListedCase: Sendable, Equatable {
        var name: String
        var hasPayload: Bool
        /// The labels of the payload's elements (nil for an element without one), from the note's pattern.
        var labels: [String?]
    }

    struct Listing: Sendable, Equatable {
        var cases: [ListedCase] = []
        var isOpen = false
    }

    /// The cases of each candidate the compiler called an enum, and the candidates that are types but not enums (the
    /// only error on their line: a `switch` needs a case). Nil when an error is not about a candidate's line.
    static func readCases(_ errors: String, file: String, firstLine: Int, candidates: [String])
        -> (enums: [String: Listing], types: [String])?
    {
        var reader = CaseReader()
        for line in errors.replacing(/\u{1B}\[[0-9;]*m/, with: "").split(separator: "\n") {
            guard line.hasPrefix(file + ":") else {
                if line.contains("error:") { return nil }
                continue
            }
            let parts = line.dropFirst(file.count + 1).split(separator: ":", maxSplits: 3)
            guard parts.count == 4, let number = Int(parts[0]) else { continue }
            let kind = parts[2].trimmingCharacters(in: .whitespaces), message = parts[3].trimmingCharacters(in: .whitespaces)
            let index = number - firstLine
            guard candidates.indices.contains(index) else {
                if kind == "error" { return nil }
                continue
            }
            reader.read(index, kind: kind, message: message)
        }
        var result: [String: Listing] = [:]
        for (index, listing) in reader.listings where !reader.notEnums.contains(index) && !listing.cases.isEmpty {
            result[candidates[index]] = listing
        }
        let types = reader.emptySwitches.subtracting(reader.otherErrors).subtracting(reader.listings.keys).sorted()
        return (result, types.map { candidates[$0] })
    }

    /// What the diagnostics of `readCases` say about each probe line, by its index.
    private struct CaseReader {
        var listings: [Int: Listing] = [:]
        var notEnums: Set<Int> = []
        /// Lines whose error says only that a `switch` needs a case: a type that is not an enum.
        var emptySwitches: Set<Int> = []
        var otherErrors: Set<Int> = []

        mutating func read(_ index: Int, kind: String, message: String) {
            switch kind {
            case "error" where message == "switch must be exhaustive":
                listings[index] = listings[index] ?? Listing()
                otherErrors.insert(index)
            case "error" where message.hasPrefix("'switch' statement body must have at least one"):
                emptySwitches.insert(index)
                notEnums.insert(index)
            case "error":
                otherErrors.insert(index)
                notEnums.insert(index)
            case "note" where message.hasPrefix("add missing case: '.") && message.hasSuffix("'"):
                guard let k = listedCase(String(message.dropFirst("add missing case: '.".count).dropLast())) else {
                    notEnums.insert(index)
                    return
                }
                listings[index, default: Listing()].cases.append(k)
            case "note" where message.contains("@unknown default"): listings[index, default: Listing()].isOpen = true
            default: return
            }
        }
    }
}

import Foundation

// Reading guide
// Types and calls of binary modules (mapper verification, Phase 3): a module the scan imports but has no SIL bodies of,
// such as a Kotlin Multiplatform framework that SKIE exports or a closed-source Swift or Objective-C framework.
//
// - Enums: their cases and whether a client must allow cases added later come from the compiler (SFVerifyKit's
//   `BinaryTypeCheck` asks it), never from the uses in the scanned SIL. An open enum (not `@frozen`, in a module built
//   with library evolution) gets one more case, `unknownCase`, that no instruction names: `default` and
//   `@unknown default` reach it. A payload is read with the usual rules (a foreign object is an opaque handle).
// - Calls with no body into such a module (`Surface.ordinal.getter`, `onEnum(of:)`, a bridge to or from Objective-C)
//   are *opaque calls* (`SILOpaqueCalls.swift`): each returns a fresh value of its type, assumed not to trap. Each is an
//   assumption the report lists (`Assumptions`).
//
// Tests: Tests/SFVerifyKitTests/BinaryTypeScanTests.swift, PlantedBugScanTests (shape 11).

/// What the compiler said about the binary modules a scanned module imports (`SILModule.recordBinaryTypes`).
package struct BinaryTypes: Sendable, Equatable {
    /// An enum of a binary module: its cases in the order the compiler listed them, with the payload type text as SIL
    /// prints it (nil when the case has none), and whether a client must allow cases added later.
    package struct Enumeration: Sendable, Equatable {
        package var module: String
        package var cases: [Case]
        package var isOpen: Bool

        package init(module: String, cases: [Case], isOpen: Bool) {
            self.module = module
            self.cases = cases
            self.isOpen = isOpen
        }
    }

    package struct Case: Sendable, Equatable {
        package var name: String
        package var payload: String?
        /// The case has a payload whose type the compiler did not print: the enum is not read.
        package var payloadUnknown = false

        package init(name: String, payload: String? = nil, payloadUnknown: Bool = false) {
            self.name = name
            self.payload = payload
            self.payloadUnknown = payloadUnknown
        }
    }

    /// A function with no body that a binary module defines: its module and its name for reports (`Surface.ordinal`).
    package struct Call: Sendable, Equatable {
        package var module: String
        package var label: String

        package init(module: String, label: String) {
            self.module = module
            self.label = label
        }
    }

    /// By the name SIL prints (`Surface`, `Skie.Shot.__Sealed`).
    package var enums: [String: Enumeration] = [:]
    /// The modules the compiler loaded from a binary file that is not part of the SDK or the toolchain.
    package var modules: Set<String> = []
    /// Where each of `modules` comes from, as far as its file says (`ModuleOrigin`); absent: `unknown`.
    package var origins: [String: ModuleOrigin] = [:]
    /// By symbol.
    package var calls: [String: Call] = [:]
    /// The functions the SIL declares without a body (`sil @$s… : $@convention(…) …`), by symbol: the declaration line.
    var externals: [String: String] = [:]
    /// The Swift name the SIL gives each of `externals` in the comment above it (`// URL.path.getter`), by symbol.
    var externalNames: [String: String] = [:]
    /// What calls without a body may return (`SILOpaqueCalls.swift`); `Verifier` sets it from its options.
    var opaqueCalls = OpaqueCallMode.objectiveC

    package init() {}

    /// Adds what another module knows; this module's `opaqueCalls` stays.
    mutating func link(_ other: BinaryTypes) {
        enums.merge(other.enums) { first, _ in first }
        modules.formUnion(other.modules)
        origins.merge(other.origins) { first, _ in first }
        calls.merge(other.calls) { first, _ in first }
        externals.merge(other.externals) { first, _ in first }
        externalNames.merge(other.externalNames) { first, _ in first }
    }

    /// The declarations without a body among the top-level lines of a SIL file.
    static func externals(in lines: [String]) -> [String: String] {
        var found: [String: String] = [:]
        for line in lines where line.hasPrefix("sil ") && !line.hasSuffix("{") {
            guard let at = line.range(of: " @"), let end = line[at.upperBound...].range(of: " : ") else { continue }
            found[String(line[at.upperBound..<end.lowerBound])] = line
        }
        return found
    }
}

/// Where a module whose bodies a scan does not have comes from, for the reports' wording only (verdicts do not depend
/// on it): read from the file the compiler loaded it from (SFVerifyKit's `BinaryTypeCheck.origin(of:)`).
package enum ModuleOrigin: Sendable, Equatable {
    /// A prebuilt framework: its sources are not part of any build the scan can see.
    case binary
    /// Compiled from source by the build the scan reads, but not scanned or linked: scanning it checks its code.
    case notScanned
    /// Either; the file does not say.
    case unknown

    /// Why a call into `module` has no body, as a report says it after "has" (`no body: binary module SharedKt`); for a
    /// module that was not scanned, with how to check it instead.
    package func describe(_ module: String) -> String {
        switch self {
        case .binary: "no body: binary module \(module)"
        case .notScanned:
            "no body: not scanned (module \(module)); scan \(module) (`--scan <dir>:\(module)`) to check it instead of assuming"
        case .unknown: "no body available (module \(module))"
        }
    }

    /// `module` as a report names it after "of" (`enum Surface of the binary module SharedKt`).
    package func place(_ module: String) -> String {
        switch self {
        case .binary: "the binary module \(module)"
        case .notScanned: "module \(module) (not scanned)"
        case .unknown: "module \(module)"
        }
    }
}

extension BinaryTypes {
    /// Where `module` comes from, as far as the scan knows.
    package func origin(of module: String) -> ModuleOrigin { origins[module] ?? .unknown }
}

/// What a scan may assume about code it has no body of (`--no-opaque-calls`, `VerifyOptions.opaqueCalls`).
package enum OpaqueCallMode: Sendable, Equatable {
    /// Objective-C methods and String bridges return any value (plan item R6-1); nothing else. The default of every
    /// reader but `Verifier`, which says which of the two below it wants.
    case objectiveC
    /// Also calls into binary modules, `init(truncating:)` of an `NSNumber`, and `==` of Objective-C objects; each is a
    /// listed assumption.
    case all
    /// No call without a body is read: every free value is refused.
    case none
}

extension BinaryTypes.Enumeration {
    /// The name of the case an open enum gets for the values a later version of its module may add.
    package static let unknownCase = "@unknown"
}

extension TypeContext {
    /// The layout of `name` when it is an enum of a binary module; nil otherwise.
    func binaryEnum(_ name: String, depth: Int) throws(SILError) -> ValueType? {
        guard let declared = binary.enums[name] else { return nil }
        guard !declared.cases.isEmpty else { throw SILError.unsupported("enum \(name) has no cases (it has no values)") }
        var cases: [ValueType.Case] = []
        for k in declared.cases {
            if k.payloadUnknown {
                throw SILError.unsupported(
                    "enum \(name) of \(binary.origin(of: declared.module).place(declared.module)): the compiler did not show the payload "
                        + "type of case \(k.name)")
            }
            do {
                cases.append(
                    ValueType.Case(name: k.name, payload: try k.payload.map { (p) throws(SILError) in try resolve(p, depth: depth + 1) }))
            } catch {
                guard case .unsupported(let why) = error else { throw error }
                let place = binary.origin(of: declared.module).place(declared.module)
                throw SILError.unsupported("enum \(name) of \(place), case \(k.name): \(why)")
            }
        }
        if declared.isOpen { cases.append(ValueType.Case(name: BinaryTypes.Enumeration.unknownCase, payload: nil)) }
        return .enumeration(name: name, cases: cases)
    }
}

extension SILModule {
    /// The enums, modules and functions of the binary modules this SIL imports.
    package internal(set) var binary: BinaryTypes {
        get { types.binary }
        set { types.binary = newValue }
    }

    /// What calls without a body may return (`SILOpaqueCalls.swift`); `Verifier` sets it from its options.
    package var opaqueCalls: OpaqueCallMode {
        get { types.binary.opaqueCalls }
        set { types.binary.opaqueCalls = newValue }
    }

    private var externals: [String: String] { types.binary.externals }

    /// Every body, by symbol.
    private var allBodies: [(symbol: String, body: [String])] { symbols.compactMap { s in bodyLines(of: s).map { (s, $0) } } }

    /// Type names the scanned SIL uses that nothing here declares or reads: candidates for enums of binary modules. They
    /// come from enum case references (`#Surface.fast!enumelt`) and the types in function signatures; the compiler
    /// decides which are enums (`recordBinaryTypes`).
    package var binaryEnumCandidates: [String] {
        var names: Set<String> = []
        for (symbol, body) in allBodies {
            for line in body where line.contains("!enumelt") { Self.enumReferences(in: line, into: &names) }
            if let header = header(of: symbol), let type = header.range(of: " : $") {
                Self.typeNames(in: header[type.upperBound...], into: &names)
            }
        }
        for declaration in externals.values {
            if let type = declaration.range(of: " : $") { Self.typeNames(in: declaration[type.upperBound...], into: &names) }
        }
        return names.filter { name in
            !types.declaresName(name) && types.binary.enums[name] == nil && (try? types.resolve(name)) == nil
        }.sorted()
    }

    /// The symbols declared without a body (`sil @$s3Kit7SurfaceO7ordinals5Int32Vvg : $@convention(method) …`).
    package var externalSymbols: [String] { externals.keys.filter { !hasBody($0) }.sorted() }

    /// The declaration line of a function declared without a body.
    package func externalDeclaration(of symbol: String) -> String? { hasBody(symbol) ? nil : externals[symbol] }

    /// Records what the compiler said about the binary modules, and the symbols that name their Objective-C types (for
    /// `confirmForeignTypes`).
    package mutating func recordBinaryTypes(_ found: BinaryTypes, foreignSymbols: some Sequence<String>) {
        binary.link(found)
        types.foreign.symbols.formUnion(foreignSymbols.filter(ForeignTypes.mayNameClangTypes))
    }

    /// The cases each enum is named with in the bodies (`#Surface.fast!enumelt`), by enum name.
    package var enumCaseReferences: [String: Set<String>] {
        var cases: [String: Set<String>] = [:]
        for (_, body) in allBodies {
            for line in body where line.contains("!enumelt") {
                for match in line.matches(of: /#([A-Za-z0-9_.]+)\.([A-Za-z0-9_]+)!enumelt/) {
                    cases[String(match.output.1), default: []].insert(String(match.output.2))
                }
            }
        }
        return cases
    }

    /// `Double.init(truncating: NSNumber)` and the other numbers' (`Foundation`): no body in any SDK (G6), and a number
    /// of a Kotlin framework arrives as an `NSNumber`. The only system calls that `OpaqueCallMode.all` reads.
    package static func isOpaqueFoundationCall(_ symbol: String) -> Bool {
        symbol.contains("10FoundationE10truncating") && symbol.hasSuffix("So8NSNumberC_tcfC")
    }

    /// `#Skie.Shot.__Sealed.putt!enumelt` -> `Skie.Shot.__Sealed`.
    static func enumReferences(in line: String, into names: inout Set<String>) {
        var rest = Substring(line)
        while let end = rest.range(of: "!enumelt") {
            let before = rest[..<end.lowerBound]
            if let hash = before.lastIndex(of: "#") {
                let reference = before[before.index(after: hash)...]
                if let dot = reference.lastIndex(of: "."), reference.allSatisfy(Self.isNameCharacter) {
                    names.insert(String(reference[..<dot]))
                }
            }
            rest = rest[end.upperBound...]
        }
    }

    /// The plain (non-generic) type names of a SIL type text: `(Surface, @guaranteed KitPutt) -> Int32` -> `Surface`,
    /// `KitPutt`, `Int32`.
    static func typeNames(in text: Substring, into names: inout Set<String>) {
        var current = ""
        func flush(_ next: Character?) {
            defer { current = "" }
            guard let first = current.first, first.isUppercase || first == "_", next != "<" else { return }
            var name = current
            for suffix in [".Type", ".Protocol"] where name.hasSuffix(suffix) { name.removeLast(suffix.count) }
            if !name.hasSuffix("."), !name.contains("..") { names.insert(name) }
        }
        for character in text {
            if Self.isNameCharacter(character) {
                current.append(character)
            } else {
                flush(character)
            }
        }
        flush(nil)
    }

    private static func isNameCharacter(_ c: Character) -> Bool { c.isLetter || c.isNumber || c == "_" || c == "." }

    func hasBody(_ symbol: String) -> Bool { bodyLines(of: symbol) != nil }
}

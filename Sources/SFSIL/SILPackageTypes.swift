import Foundation

// Values that belong to code logic does not read, but that real app code passes around constantly:
//
// - Key paths (`\.count`). A key path is made and handed to a call; logic never reads through one, so it is one
//   opaque handle. Only key paths without captured subscript arguments are accepted: destroying one then releases
//   nothing of the read modules.
// - A short list of value types of well-known packages (`TypeContext.packageTypes`), such as the registrar that The
//   Composable Architecture's `@ObservableState` macro adds to every state struct. Their contents are opaque handles,
//   and only the calls in `StdlibSummary.table` that were reviewed against the package's source may touch them.
//   SIL prints these types without their module, so each name is used only after a compile probe confirms that, in
//   this build, the bare name means the package's type (`SILModule.confirmPackageTypes`).

extension TypeContext {
    /// The layout of every key path: one opaque handle. Its components are never read.
    static let keyPath = ValueType.opaque(name: "KeyPath")

    /// A value type of a package: the module that declares it and the layout logic gives it.
    package struct PackageType: Sendable {
        package let module: String
        let layout: ValueType
    }

    /// Reviewed against swift-composable-architecture 1.26 (`ObservationStateRegistrar.swift`,
    /// `ObservableState.swift`). The registrar's stored properties are `id` and `registrar`; state macros read `id`
    /// directly (`_$id`).
    package static let packageTypes: [String: PackageType] = [
        "ObservationStateRegistrar": PackageType(
            module: "ComposableArchitecture",
            layout: .aggregate(
                name: "ObservationStateRegistrar",
                fields: [
                    .init(name: "id", type: .opaque(name: "ObservableStateID")),
                    .init(name: "registrar", type: .opaque(name: "PerceptionRegistrar")),
                ])),
        "ObservableStateID": PackageType(module: "ComposableArchitecture", layout: .opaque(name: "ObservableStateID")),
    ]

    /// The layout of the package type `t`, if this build confirmed the name and no read module declares it.
    func packageType(_ t: String) -> ValueType? {
        guard confirmedPackageTypes.contains(t), let type = Self.packageTypes[t], !declaresHere(t) else { return nil }
        return type.layout
    }

    /// `keyPath` for `KeyPath<A, B>`, `WritableKeyPath<A, B>`, `any KeyPath<A, B> & Sendable`, and the type opened from
    /// such an existential (`@opened("…", any KeyPath<A, B> & Sendable) Self`); nil for anything else.
    func keyPathType(_ text: String) -> ValueType? {
        var t = text
        if t.hasPrefix("@opened(\""), t.hasSuffix(") Self"), let comma = t.range(of: "\", ") {
            t = String(t[comma.upperBound..<t.index(t.endIndex, offsetBy: -") Self".count)])
        }
        if t.hasPrefix("any ") {
            t.removeFirst(4)
            if t.hasSuffix(" & Sendable") { t.removeLast(" & Sendable".count) }
            if t.hasPrefix("Sendable & ") { t.removeFirst("Sendable & ".count) }
        }
        if t.hasPrefix("Swift.") { t.removeFirst(6) }
        let base = String(t.prefix { $0 != "<" })
        let generic = ["KeyPath", "WritableKeyPath", "ReferenceWritableKeyPath", "PartialKeyPath"]
        guard t == "AnyKeyPath" || generic.contains(base) && t.hasSuffix(">"), !declaresHere(base) else { return nil }
        return Self.keyPath
    }

    /// The handle for a key path, existential or Objective-C reference type (`SILForeign.swift`); nil for any other type.
    func referenceHandle(_ t: String) throws(SILError) -> ValueType? {
        if let object = try foreignObject(t) { return object }
        if let keyPath = keyPathType(t) { return try heldUnlessDeinitsRunCode(t, keyPath) }
        return try existentialType(t)
    }

    /// `layout`, for a type whose values hold references to things logic does not see: a key path holds the values its
    /// subscripts captured, and a registrar holds the closures observers registered. Destroying one may release the last
    /// reference to an object of a read module, so, as for closures, it is refused when some `deinit` there runs code.
    func heldUnlessDeinitsRunCode(_ t: String, _ layout: ValueType) throws(SILError) -> ValueType {
        guard acceptsUnknownReleases() else {
            throw SILError.unsupported(
                "type \(t): destroying it may run a deinit of this module that calls code or can trap\(deinitRefusalNote)")
        }
        return layout
    }

    /// True when a read module declares `name` itself, in which case a use means that declaration.
    private func declaresHere(_ name: String) -> Bool {
        structs[name] != nil || enums[name] != nil || generics[name] != nil || rejected[name] != nil || ambiguous.contains(name)
    }
}

extension SILModule {
    /// The package types (`TypeContext.packageTypes`) whose module this code imports: the names a compile probe must
    /// confirm before `confirmPackageTypes`.
    package var packageTypeCandidates: [(name: String, module: String)] {
        (TypeContext.packageTypes.filter { imports.contains($0.value.module) }.map { ($0.key, $0.value.module) }
            + opaqueValueCandidates + cgFloatCandidates).sorted { $0.name < $1.name }
    }

    /// Lets logic use these package type names: a probe showed that, with this code's imports, each bare name means
    /// the package's type and nothing else.
    package mutating func confirmPackageTypes(_ names: some Sequence<String>) {
        types.confirmedPackageTypes = Set(names).intersection(
            Set(TypeContext.packageTypes.keys).union(OpaqueValues.types.keys).union(["CGFloat"]))
    }

    /// True when some read body mentions IssueReporting's reporters (`IssueReporters.current`, `withIssueReporters`,
    /// `.fatalError`). Perception reports untracked state reads with `reportIssue`, which traps only under a
    /// fatal-error reporter.
    static func mayInstallIssueReporters(_ bodies: [String: [String]]) -> Bool {
        bodies.values.contains { body in body.contains { $0.containsText("IssueReporter") } }
    }
}

extension StdlibSummary {
    /// Calls into The Composable Architecture 1.26, reviewed against its source (see `TypeContext.packageTypes`).
    static func addComposableArchitecture(to t: inout [String: Entry]) {
        func add(_ symbol: String, _ name: String, _ summary: StdlibSummary = .unknown) {
            t[symbol] = Entry(name: name, summary: summary, isGeneric: summary == .recordsAccess)
        }
        let registrar = "$s22ComposableArchitecture25ObservationStateRegistrar"
        // `registrar.access(subject, keyPath:)`: Perception records the read for observers; nothing is returned.
        add(registrar + "V6access_7keyPathyx_s03KeyH0Cyxq_Gt0C010ObservableRzr0_lF", "ObservationStateRegistrar.access", .recordsAccess)
        add(registrar + "VACycfC", "ObservationStateRegistrar()")
        add(registrar + "V2eeoiySbAC_ACtFZ", "ObservationStateRegistrar.==")
        add(registrar + "V4hash4intoys6HasherVz_tF", "ObservationStateRegistrar.hash(into:)")
        add(registrar + "V12_$willModifyyyF", "ObservationStateRegistrar._$willModify()")
        add("$s22ComposableArchitecture17ObservableStateIDV2eeoiySbAC_ACtFZ", "ObservableStateID.==")
        add("$s22ComposableArchitecture17ObservableStateIDV4hash4intoys6HasherVz_tF", "ObservableStateID.hash(into:)")
    }
}

extension TypeContext {
    /// The type of `keypath $T, (root $R; …)`. A key path whose components capture values (`indices [...]`, then
    /// an operand list) or refer to another module's property descriptor (`external`) is rejected.
    func keyPathLiteral(_ rest: String, _ line: String) throws(SILError) -> ValueType {
        guard let comma = rest.range(of: ", ("), let type = keyPathType(String(rest[..<comma.lowerBound]).trimmingCharacters(in: ["$"])),
            let close = matchingClose(rest[rest.index(before: comma.upperBound)...], open: "(", close: ")"),
            close == rest.index(before: rest.endIndex)
        else {
            throw SILError.unsupported("keypath: \(line)")
        }
        let pattern = rest[comma.upperBound..<close]
        guard !pattern.contains(" indices "), !pattern.contains("indices ["), !pattern.contains("external #") else {
            throw SILError.unsupported("key path that captures values or uses another module's property: \(line)")
        }
        return type
    }

    /// True for `%k to $T` (or `%k : $S to $T`) where `T` is a key path type: a cast between key paths.
    func isKeyPathCast(_ operand: String) -> Bool {
        guard let to = operand.range(of: " to $", options: .backwards) else { return false }
        let source = operand.prefix { $0 != " " }
        return source.hasPrefix("%") && keyPathType(String(operand[to.upperBound...])) != nil
    }
}

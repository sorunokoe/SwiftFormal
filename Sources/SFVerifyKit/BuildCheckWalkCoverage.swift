import Foundation

/// What the gate knows of the walk (a `Prove` test) behind one function: nothing was asked for (no `--tests`), or the
/// walks were given and one is linked to the function, or none is.
struct WalkCoverage {
    private(set) var isRequired = false
    private(set) var linked: WalkCheck?

    init() {}

    /// With `walks` nil, no walk is required. Otherwise the first walk linked to `function` (same rule as
    /// `swiftformal check`) covers it, if any.
    init(_ walks: [WalkCheck]?, function: FunctionReport, linker: WalkLinker) {
        guard let walks else { return }
        isRequired = true
        let key = Check.functionKey(function.name)
        linked = walks.first { linker.mayCover($0, functionName: function.name, key: key) }
    }

    /// A walk was required and none is linked.
    var isMissing: Bool { isRequired && linked == nil }

    /// `the walk at File.swift:12 (Suite.test)` for a linked walk.
    var description: String? {
        guard let linked else { return nil }
        let test = [linked.suite, linked.test].compactMap { $0 }.joined(separator: ".")
        return "the walk at \((linked.file as NSString).lastPathComponent):\(linked.line)" + (test.isEmpty ? "" : " (\(test))")
    }
}

import Foundation

/// The one function `--at <file>:<line>` or `--symbol <name>` asks for. Only that function is verified and reported;
/// the module is still compiled whole, and every other function stays in the report's inventory
/// (`ScanReport.unselected`), so contracts pair and walks link exactly as without a selector.
///
/// A selector names exactly one function or fails: a position or name that fits several is an error that lists them,
/// one that fits a contract function (`f_requires`, `f_ensures`) says to select `f`, and one that fits nothing is
/// reported as such by the command, never as "nothing to prove". Several compiled copies of one function (the same
/// name at the same place, for example a generic function at each type it is called with) count as one.
public enum FunctionSelector: Sendable, Equatable, CustomStringConvertible {
    /// The function whose body holds `line` of `file`: the innermost one (a local function before the function it is
    /// in; a closure's code belongs to the function the closure is in).
    case at(file: String, line: Int)
    /// The function with this name as reports print it (`Score.clamp(_:)`, `static Surface.all.getter`), or, when no name
    /// is exactly that, with the same `Type.member` and, when given, the same argument labels.
    case symbol(String)

    /// One function a selector may pick.
    package struct Candidate: Sendable {
        package var name: String
        package var location: SourceLocation?
        /// A `_requires` or `_ensures` function: verified with the function it specifies, never on its own.
        package var isSpec: Bool

        package init(name: String, location: SourceLocation?, isSpec: Bool) {
            self.name = name
            self.location = location
            self.isSpec = isSpec
        }
    }

    /// `--at` text, `path:line` or `path:line:column` (the column is ignored: a line is one function). The file must exist.
    public init(at text: String) throws {
        var parts = text.split(separator: ":", omittingEmptySubsequences: false).map(String.init)
        if parts.count >= 3, Int(parts[parts.count - 1]) != nil, Int(parts[parts.count - 2]) != nil { parts.removeLast() }
        guard parts.count >= 2, let line = Int(parts[parts.count - 1]), line > 0 else {
            throw ScanUsageError("--at needs <file>:<line>, not '\(text)'")
        }
        let file = parts.dropLast().joined(separator: ":")
        guard FileManager.default.fileExists(atPath: file) else { throw ScanUsageError("--at: no file \(file)") }
        self = .at(file: file, line: line)
    }

    public var description: String {
        switch self {
        case .at(let file, let line): "--at \(file):\(line)"
        case .symbol(let name): "--symbol \(name)"
        }
    }

    /// Whether a module compiled from `files` can hold the function: the file of `--at` is one of them; any module
    /// for `--symbol`.
    package func mayMatch(files: [String]) -> Bool {
        guard case .at(let file, _) = self else { return true }
        let wanted = Self.canonical(file)
        return files.contains { Self.canonical($0) == wanted }
    }

    /// The indices of the candidates selected: one function, possibly compiled more than once. Empty when no
    /// candidate of this module fits; an error when several functions fit, when the function is a contract, or when
    /// `--at` names a file of this module at a line no function covers.
    package func resolve(_ candidates: [Candidate], module: String) throws -> [Int] {
        switch self {
        case .at(let file, let line): try Self.resolve(file: file, line: line, candidates, module: module)
        case .symbol(let name): try Self.resolve(symbol: name, candidates)
        }
    }

    private static func resolve(file: String, line: Int, _ candidates: [Candidate], module: String) throws -> [Int] {
        var canonicalPaths: [String: String] = [:]
        let wanted = canonical(file)
        let inFile = candidates.indices.filter { index in
            guard let path = candidates[index].location?.file else { return false }
            if canonicalPaths[path] == nil { canonicalPaths[path] = canonical(path) }
            return canonicalPaths[path] == wanted
        }
        guard !inFile.isEmpty else { return [] }
        guard let text = try? String(contentsOfFile: file, encoding: .utf8) else { throw ScanUsageError("--at: cannot read \(file)") }
        let ranges = SourceRanges(text)
        var containing: [(index: Int, lines: ClosedRange<Int>)] = []
        for index in inFile {
            guard let location = candidates[index].location else { continue }
            let lines = ranges.range(line: location.line, column: location.column)
            if lines.contains(line) { containing.append((index, lines)) }
        }
        guard let innermost = containing.map(\.lines.count).min() else {
            let distance = { (index: Int) in abs((candidates[index].location?.line ?? 0) - line) }
            let nearest = inFile.sorted { distance($0) < distance($1) }
            throw ScanUsageError(
                "--at \(file):\(line): no function of \(module) that Scan verifies covers that line; nearby: "
                    + list(Array(nearest.prefix(3)), candidates))
        }
        return try one(containing.filter { $0.lines.count == innermost }.map(\.index), candidates, hint: "pick one with --symbol")
    }

    private static func resolve(symbol: String, _ candidates: [Candidate]) throws -> [Int] {
        let plain = withoutStatic(symbol)
        let exact = candidates.indices.filter { withoutStatic(candidates[$0].name) == plain }
        let matches = exact.isEmpty ? candidates.indices.filter { sameFunction(candidates[$0].name, symbol) } : exact
        guard !matches.isEmpty else { return [] }
        return try one(matches, candidates, hint: "write the name as the report prints it, or pick one with --at <file>:<line>")
    }

    /// The candidates of exactly one function (one name at one place), or an error naming them all.
    private static func one(_ indices: [Int], _ candidates: [Candidate], hint: String) throws -> [Int] {
        var groups: [String: [Int]] = [:]
        var order: [String] = []
        for index in indices {
            let key = "\(candidates[index].name)@\(candidates[index].location?.description ?? "")"
            if groups[key] == nil { order.append(key) }
            groups[key, default: []].append(index)
        }
        guard order.count == 1, let chosen = groups[order[0]], let first = chosen.first else {
            let firsts = order.compactMap { groups[$0]?.first }
            throw ScanUsageError("\(order.count) functions fit: \(list(firsts, candidates)); \(hint)")
        }
        let name = candidates[first].name
        if candidates[first].isSpec {
            let specified = Check.functionKey(name).replacingOccurrences(of: "_requires", with: "").replacingOccurrences(
                of: "_ensures", with: "")
            throw ScanUsageError("\(name) is a contract of \(specified): it is verified with that function; select \(specified) instead")
        }
        return chosen
    }

    private static func list(_ indices: [Int], _ candidates: [Candidate]) -> String {
        indices.map { index in
            let place = candidates[index].location.map { " (\(URL(fileURLWithPath: $0.file).lastPathComponent):\($0.line))" } ?? ""
            return candidates[index].name + place
        }.joined(separator: ", ")
    }

    private static func withoutStatic(_ name: String) -> String { name.hasPrefix("static ") ? String(name.dropFirst(7)) : name }

    /// The same `Type.member`, and the same argument labels when `wanted` has them.
    private static func sameFunction(_ name: String, _ wanted: String) -> Bool {
        guard Check.functionKey(name) == Check.functionKey(wanted) else { return false }
        guard wanted.contains("(") else { return true }
        return Check.argumentLabels(name) == Check.argumentLabels(wanted)
    }

    private static func canonical(_ path: String) -> String {
        URL(fileURLWithPath: path).standardizedFileURL.resolvingSymlinksInPath().path
    }
}

extension Check {
    /// Throws unless exactly one of `scans` holds the function `selector` picked: none (no scanned module has it) or one
    /// in each of several modules is a usage error, never "nothing to prove".
    public static func requireOneSelected(_ scans: [ScanReport], by selector: FunctionSelector) throws {
        let picked = scans.filter { $0.selection?.function != nil }
        guard picked.count != 1 else { return }
        let names = picked.compactMap { scan in scan.selection?.function.map { "\($0) in \(scan.module)" } }
        throw ScanUsageError(
            names.isEmpty
                ? "\(selector): no function of \(scans.map(\.module).joined(separator: ", ")) that Scan verifies is there"
                : "\(selector): \(names.count) functions fit: \(names.joined(separator: ", ")); pick one with --at")
    }
}

extension ScanReport {
    /// What a selector asked for and the function it picked in this module (absent when it picked none here).
    public struct Selection: Codable, Sendable, Equatable {
        /// `--at <file>:<line>` or `--symbol <name>`.
        public var selector: String
        public var function: String?
    }

    /// A function of the module a selector did not pick: compiled, not verified, still linked to walks.
    public struct UnselectedFunction: Sendable {
        public var name: String
        public var location: SourceLocation?

        public init(name: String, location: SourceLocation?) {
            self.name = name
            self.location = location
        }
    }

    /// Every function of the module Scan verifies or would verify without a selector: what walks link to.
    package var inventory: [UnselectedFunction] {
        functions.map { UnselectedFunction(name: $0.name, location: $0.location) } + unselected
    }
}

/// What a selector picks in one compiled module: the symbols to verify, and the functions it leaves out.
struct SelectedFunctions {
    var symbols: Set<String>
    var selection: ScanReport.Selection
    var unselected: [ScanReport.UnselectedFunction]

    /// `files` are the files `compiled` was compiled from: `--at` a file that is not one of them (where a
    /// `#sourceLocation` puts a function) picks nothing here, as `FunctionSelector.mayMatch(files:)` says.
    init(_ selector: FunctionSelector, in compiled: CompiledModule, module: String, files: [String], options: VerifyOptions) throws {
        let specs = SpecIndex(compiled.functions)
        let targets = Verifier.targets(compiled, options: options, specs: specs)
        let contracts = compiled.functions.filter { specs.isSpec($0.symbol) }
        let candidates =
            targets.map { FunctionSelector.Candidate(name: $0.displayName, location: $0.location, isSpec: false) }
            + contracts.map { FunctionSelector.Candidate(name: $0.displayName, location: $0.location, isSpec: true) }
        let chosen = selector.mayMatch(files: files) ? try selector.resolve(candidates, module: module) : []
        // `resolve` refuses a contract function, so every index chosen is a target's.
        let symbols = Set(chosen.filter { $0 < targets.count }.map { targets[$0].symbol })
        self.symbols = symbols
        selection = ScanReport.Selection(selector: selector.description, function: chosen.first.map { candidates[$0].name })
        unselected = targets.filter { !symbols.contains($0.symbol) }.map {
            ScanReport.UnselectedFunction(name: $0.displayName, location: $0.location)
        }
    }
}

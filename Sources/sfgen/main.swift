import Foundation
import SFGenKit

// sfgen: writes SwiftFormal checks for every Rule, straight from the compiler's description of the input types.
//
//   sfgen symbols  --module SharedKt --framework-dir <dir> --out <dir> [--sdk iphonesimulator] [--target arm64-apple-ios17.0-simulator]
//                  [--access-level public|internal]
//   sfgen generate --sources <dir>... --symbols <dir|file>... --import <Module>... --testable-import <Module>...
//                  --out <file> [--exclude <file>] [--only A,B] [--manifest <file>] [--max-inputs N]
//   sfgen prune    --generated <file> --log <xcodebuild.log> --exclude <file>
//   sfgen domains  --symbols <dir|file>... --out <file> [--import <Module>...] [--exclude <file>] [--manifest <file>]

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data((message + "\n").utf8))
    exit(2)
}

/// The Rules in `sources`, read with swift-syntax: only with the `Generator` trait, which is on by default.
func indexRules(_ index: TypeIndex, appModule: String?, sources: [String]) -> (rules: [RuleInfo], filesParsed: Int) {
    #if Generator
        let indexer = SourceIndexer(index: index, appModule: appModule)
        for source in sources { indexer.indexDirectory(URL(fileURLWithPath: source)) }
        return (indexer.rules, indexer.filesParsed)
    #else
        fail(
            "sfgen generate reads Swift sources with swift-syntax, which this build left out: build sfgen with the Generator trait (on by default; --disable-default-traits turns it off)"
        )
    #endif
}

struct Arguments {
    var flags: [String: [String]] = [:]

    init(_ raw: [String]) {
        var key: String?
        for item in raw {
            if item.hasPrefix("--") {
                key = String(item.dropFirst(2)); flags[key!, default: []] = flags[key!] ?? []
            } else if let key {
                flags[key, default: []].append(item)
            }
        }
    }

    func values(_ name: String) -> [String] { flags[name] ?? [] }
    func value(_ name: String) -> String? { flags[name]?.first }
    func required(_ name: String) -> String {
        guard let found = value(name) else { fail("missing --\(name)") }
        return found
    }
}

func run(_ launch: String, _ arguments: [String]) throws -> (status: Int32, output: String) {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: launch)
    process.arguments = arguments
    let pipe = Pipe()
    process.standardOutput = pipe
    process.standardError = pipe
    try process.run()
    let data = pipe.fileHandleForReading.readDataToEndOfFile()
    process.waitUntilExit()
    return (process.terminationStatus, String(decoding: data, as: UTF8.self))
}

func symbolFiles(_ paths: [String]) -> [URL] {
    var urls: [URL] = []
    for path in paths {
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory) else { fail("no such path: \(path)") }
        if isDirectory.boolValue {
            let names = (try? FileManager.default.contentsOfDirectory(atPath: path)) ?? []
            // `Module@Other.symbols.json` files only extend other modules and carry no new types.
            urls += names.filter { $0.hasSuffix(".symbols.json") && !$0.contains("@") }.sorted()
                .map { URL(fileURLWithPath: path).appendingPathComponent($0) }
        } else {
            urls.append(URL(fileURLWithPath: path))
        }
    }
    return urls
}

let arguments = Array(CommandLine.arguments.dropFirst())
guard let command = arguments.first else { fail("usage: sfgen symbols|generate|prune|domains ...") }
let options = Arguments(Array(arguments.dropFirst()))

switch command {
case "symbols":
    let module = options.required("module")
    let output = options.required("out")
    let sdkName = options.value("sdk") ?? "iphonesimulator"
    let target = options.value("target") ?? "arm64-apple-ios17.0-simulator"
    let sdk = try run("/usr/bin/xcrun", ["--sdk", sdkName, "--show-sdk-path"]).output.trimmingCharacters(in: .whitespacesAndNewlines)
    try FileManager.default.createDirectory(atPath: output, withIntermediateDirectories: true)
    var extraction = [
        "swift-symbolgraph-extract", "-module-name", module, "-target", target, "-sdk", sdk,
        "-output-dir", output, "-minimum-access-level", options.value("access-level") ?? "public",
    ]
    for directory in options.values("framework-dir") { extraction += ["-F", directory] }
    for directory in options.values("include-dir") { extraction += ["-I", directory] }
    let started = Date()
    let result = try run("/usr/bin/xcrun", extraction)
    print(result.status == 0 ? "extracted \(module) in \(String(format: "%.1f", Date().timeIntervalSince(started))) s" : result.output)
    exit(result.status)

case "generate":
    let index = TypeIndex()
    let started = Date()
    let graphs = symbolFiles(options.values("symbols"))
    do { try SymbolGraphLoader.load(graphs, into: index) } catch { fail("cannot read symbol graphs: \(error)") }
    let kotlinTypes = index.types.count
    let indexer = indexRules(index, appModule: options.value("app-module"), sources: options.values("sources"))

    var excluded: Set<String> = []
    if let path = options.value("exclude"), let text = try? String(contentsOfFile: path, encoding: .utf8) {
        excluded = Set(text.split(separator: "\n").map { String($0.split(separator: "\t").first ?? "") })
    }
    let appRules = options.value("app-module").map { app in indexer.rules.filter { $0.module == app } } ?? indexer.rules
    let generation = RuleGenerator.generate(
        rules: appRules, index: index,
        options: GenerationOptions(
            imports: options.values("import"), testableImports: options.values("testable-import"),
            excluded: excluded, only: Set(options.value("only")?.split(separator: ",").map(String.init) ?? []),
            maxEvaluationsPerRule: options.value("max-inputs").flatMap(Int.init) ?? 500
        )
    )
    let out = options.required("out")
    try generation.source.write(toFile: out, atomically: true, encoding: .utf8)

    if let manifest = options.value("manifest") {
        var rows = ["rule\tstatus\treason"]
        rows += generation.generated.map { "\($0)\tgenerated\t" }
        rows += generation.skipped.map { "\($0.rule)\tskipped\t\($0.reason)" }
        try (rows.joined(separator: "\n") + "\n").write(toFile: manifest, atomically: true, encoding: .utf8)
    }
    let partial = generation.dropped.count
    print(
        """
        sfgen: \(indexer.rules.count) Rules in \(indexer.filesParsed) files, \(kotlinTypes) types from symbol graphs, \
        \(index.types.count - kotlinTypes) from sources
        sfgen: generated \(generation.generated.count), skipped \(generation.skipped.count), \
        \(partial) types with partly covered domains, in \(String(format: "%.1f", Date().timeIntervalSince(started))) s
        sfgen: wrote \(out)
        """)
    var reasons: [String: Int] = [:]
    for item in generation.skipped {
        let key = item.reason.replacingOccurrences(of: "\\b[A-Z]\\w*(\\.\\w+)*", with: "T", options: .regularExpression)
        reasons[key, default: 0] += 1
    }
    for (reason, count) in reasons.sorted(by: { $0.value > $1.value }).prefix(12) { print("  \(count)\t\(reason)") }

case "prune":
    let generatedPath = options.required("generated")
    guard let generated = try? String(contentsOfFile: generatedPath, encoding: .utf8) else { fail("cannot read \(generatedPath)") }
    guard let log = try? String(contentsOfFile: options.required("log"), encoding: .utf8) else { fail("cannot read the log") }
    let name = URL(fileURLWithPath: generatedPath).lastPathComponent
    var lines: [Int] = []
    for line in log.split(separator: "\n") where line.contains("\(name):") && line.contains(": error:") {
        let parts = line.components(separatedBy: "\(name):")
        if parts.count > 1, let number = Int(parts[1].prefix(while: \.isNumber)) { lines.append(number) }
    }
    let rules = Pruner.rulesToExclude(generated: generated, errorLines: lines)
    let excludePath = options.required("exclude")
    var existing = (try? String(contentsOfFile: excludePath, encoding: .utf8)) ?? ""
    let known = Set(existing.split(separator: "\n").map { String($0.split(separator: "\t").first ?? "") })
    for rule in rules.sorted() where !known.contains(rule) { existing += "\(rule)\tdoes not compile\n" }
    try existing.write(toFile: excludePath, atomically: true, encoding: .utf8)
    print("sfgen: \(lines.count) compiler errors; \(rules.count) Rules excluded (\(rules.subtracting(known).count) new)")

case "domains":
    let started = Date()
    let module: BinaryModule
    do { module = try BinaryModule.load(symbolFiles(options.values("symbols"))) } catch { fail("cannot read symbol graphs: \(error)") }
    var excluded: Set<String> = []
    if let path = options.value("exclude"), let text = try? String(contentsOfFile: path, encoding: .utf8) {
        excluded = Set(text.split(separator: "\n").map { String($0.split(separator: "\t").first ?? "") })
    }
    let result = BinaryDomainWriter.generate(module, imports: options.values("import"), excluded: excluded)
    let out = options.required("out")
    try result.source.write(toFile: out, atomically: true, encoding: .utf8)
    if let manifest = options.value("manifest") {
        let rows =
            ["type\tcategory\tstatus\treason"]
            + result.entries.map { "\($0.type)\t\($0.category.rawValue)\t\($0.status.rawValue)\t\($0.reason)" }
        try (rows.joined(separator: "\n") + "\n").write(toFile: manifest, atomically: true, encoding: .utf8)
    }
    print("sfgen: \(module.types.count) types in \(module.name), \(module.sealed.count) sealed hierarchies")
    for category in [BinaryDomainEntry.Category.enumeration, .sealed, .object, .initializer, .other] {
        let entries = result.entries.filter { $0.category == category }
        guard !entries.isEmpty else { continue }
        let counts = [BinaryDomainEntry.Status.exhaustive, .bounded, .skipped].map { status in
            "\(entries.filter { $0.status == status }.count) \(status.rawValue)"
        }
        print("  \(category.rawValue): \(counts.joined(separator: ", "))")
    }
    if module.sealedEnumsMissing > 0 {
        print("sfgen: \(module.sealedEnumsMissing) onEnum(of:) switches without their enum: extract with --access-level internal")
    }
    var reasons: [String: Int] = [:]
    for entry in result.entries where entry.status == .skipped {
        // The innermost reason: `init(a:): a: no public initializer` counts as `no public initializer`.
        let innermost = entry.reason.replacingOccurrences(of: "^(init\\([^)]*\\): [^ :]+: )+", with: "", options: .regularExpression)
        let key = innermost.replacingOccurrences(of: "\\b[A-Z]\\w*(\\.\\w+)*(<.*>)?", with: "T", options: .regularExpression)
        reasons[key, default: 0] += 1
    }
    for (reason, count) in reasons.sorted(by: { ($0.value, $1.key) > ($1.value, $0.key) }).prefix(12) {
        print("  \(count)\tskipped: \(reason)")
    }
    print("sfgen: wrote \(out) in \(String(format: "%.1f", Date().timeIntervalSince(started))) s")

default:
    fail("unknown command \(command)")
}

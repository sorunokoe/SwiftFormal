import Foundation
import SFVerifyKit

let stringsUsage = """
    swiftformal strings — check localization catalogues; no build and no solver.

    USAGE
      swiftformal strings <path> […] [--sources <dir> …] [--json]

    WHAT IT CHECKS
      Every .xcstrings, .strings and .stringsdict file under the paths (.strings and .stringsdict files in
      <language>.lproj folders make one table per file name). For every key:
      missing    a language of its table has no text for it (an .xcstrings key that is a sentence may lack one in
                 the source language, which then shows the key itself);
      format     a language's text reads more arguments than the reference language's, or reads one as another type
                 (%d where it is %@): String(format:) then reads memory it was not given. A plural or device
                 variation may read fewer;
      textIsKey  a key that looks like an identifier (club.driver, no spaces) has itself as its text.
      The reference language is the .xcstrings source language, else en, Base or the first one.

    OPTIONS
      --sources <dir>   Also list the literal keys of NSLocalizedString("…"), String(localized: "…") and
                        "…".localized… in the Swift files under dir that no catalogue has (unknownKey); repeatable.
      --json            Machine-readable report on stdout.

    Exit code 0 when no problem is found, 1 otherwise, 2 for a usage error.
    """

func runStrings(_ arguments: [String]) -> Never {
    let options = StringsOptions(arguments)
    let report = StringsLint.run(paths: options.paths, sources: options.sources)
    if options.json {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(report), let text = String(bytes: data, encoding: .utf8) else {
            fail("could not encode the report")
        }
        print(text)
    } else {
        for problem in report.problems { print("\(problem.kind.rawValue): \(problem.description)") }
        let counts = StringsLint.Kind.allCases.map { "\(report.count($0)) \($0.rawValue)" }.joined(separator: ", ")
        print("\(report.tables) table(s), \(report.keys) key(s), \(report.languages) language(s): \(counts)")
    }
    exit(report.problems.isEmpty ? 0 : 1)
}

/// The catalogue paths, the source folders and `--json` of `swiftformal strings`.
struct StringsOptions {
    var paths: [String] = []
    var sources: [String] = []
    var json = false

    init(_ arguments: [String]) {
        var rest = arguments[...]
        while let argument = rest.popFirst() {
            switch argument {
            case "-h", "--help":
                print(stringsUsage)
                exit(0)
            case "--json": json = true
            case "--sources":
                guard let dir = rest.popFirst() else { fail("--sources needs a folder") }
                sources.append(dir)
            case _ where argument.hasPrefix("-"): fail("unknown option \(argument)\n\n\(stringsUsage)")
            default: paths.append(argument)
            }
        }
        if paths.isEmpty { fail(stringsUsage) }
    }
}

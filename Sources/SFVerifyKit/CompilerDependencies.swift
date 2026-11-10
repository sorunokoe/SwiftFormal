import Foundation
import SFSIL

/// The files the compiler read, from the Make-style dependency file (`-emit-dependencies-path`) of each compile whose
/// options carry this (`CompileOptions.dependencies`): sources, Swift modules and interfaces, module maps, and the C
/// headers ClangImporter read (also those no argument names, such as `#include "../limits.h"` in a public header).
/// `swiftformal check --gate` stamps hash them (`VerifyStampCheck`).
package final class CompilerDependencies: @unchecked Sendable {
    private let lock = NSLock()
    private var collected: Set<String> = []
    private var failed = false

    package init() {}

    /// The absolute paths every compile so far read; nil when one could not tell (no dependency file, a relative path,
    /// a compile that failed).
    package var files: Set<String>? { lock.withLock { failed ? nil : collected } }

    /// Runs `compile` with the arguments that make the frontend write its dependency file, and records the file.
    func recording<T>(_ compile: (_ extraArguments: [String]) throws -> T) throws -> T {
        let file = NSTemporaryDirectory() + "sfverify-dependencies-\(UUID().uuidString).d"
        defer { try? FileManager.default.removeItem(atPath: file) }
        do {
            let result = try compile(["-emit-dependencies-path", file])
            record(try? String(contentsOfFile: file, encoding: .utf8))
            return result
        } catch {
            record(nil)
            throw error
        }
    }

    private func record(_ text: String?) {
        let paths = text.flatMap(Self.parse)
        lock.withLock {
            if let paths, paths.allSatisfy({ $0.hasPrefix("/") }) { collected.formUnion(paths) } else { failed = true }
        }
    }

    /// The prerequisites of the rules in `text` as the Swift frontend writes them (`<output> : <input> <input> …`,
    /// one line per output; a space and `#` escaped with `\`, a backslash run before a space doubled, `$` doubled);
    /// nil when a line is not a rule.
    static func parse(_ text: String) -> [String]? {
        var paths: [String] = []
        for line in text.replacingOccurrences(of: "\\\n", with: " ").split(separator: "\n") {
            let words = self.words(Array(line))
            guard !words.isEmpty else { continue }
            guard let colon = words.firstIndex(of: ":") else { return nil }
            paths += words[(colon + 1)...]
        }
        return paths
    }

    /// The words of a line, split at unescaped blanks, with the escapes undone.
    private static func words(_ characters: [Character]) -> [String] {
        var words: [String] = []
        var word = ""
        var index = 0
        func end() {
            if !word.isEmpty { words.append(word) }
            word = ""
        }
        while index < characters.count {
            let character = characters[index]
            if character == "\\" {
                var run = 0
                while index + run < characters.count, characters[index + run] == "\\" { run += 1 }
                let next = index + run < characters.count ? characters[index + run] : nil
                if next == " " {
                    // 2n + 1 backslashes: n of them and a space in the name; 2n: n of them, then a separator.
                    word += String(repeating: "\\", count: run / 2)
                    if run % 2 == 1 { word.append(" ") } else { end() }
                    index += run + 1
                } else if next == "#" && run == 1 {
                    word.append("#")
                    index += 2
                } else {
                    word += String(repeating: "\\", count: run)
                    index += run
                }
            } else if character == "$", index + 1 < characters.count, characters[index + 1] == "$" {
                word.append("$")
                index += 2
            } else if character == " " || character == "\t" {
                end()
                index += 1
            } else {
                word.append(character)
                index += 1
            }
        }
        end()
        return words
    }
}

extension ModuleCompiler {
    /// Runs `arguments` (`swiftc -frontend …` without `-o`) with the scan's compiler and returns what it writes to
    /// stdout; adds the files the compiler read to `dependencies`.
    static func output(of arguments: [String], dependencies: CompilerDependencies?, kind: String) throws -> String {
        // The output comes back on stdout (no temporary file), read while stderr is drained, so neither pipe can fill up.
        let run = { (extra: [String]) throws -> String in
            let arguments = arguments + extra + ["-o", "-"]
            // The scan's compiler (`ScanToolchain.current`, plan item K2), not whatever `xcrun` finds.
            let result = try Spawn.run(try ScanToolchain.current().swiftc, Array(arguments.dropFirst()))
            guard result.status == 0 else { throw SILError.compilerFailed(String(result.errorText.prefix(8000))) }
            guard let text = String(bytes: result.output, encoding: .utf8) else {
                throw SILError.invalid("the compiler's \(kind) output is not valid UTF-8")
            }
            return text
        }
        return try dependencies.map { try $0.recording(run) } ?? run([])
    }
}

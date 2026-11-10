import Foundation
import SFSIL

extension ModuleCompiler {
    struct LinkedImports {
        var linked: [String] = []
        var notLinked: [String: String] = [:]
        /// The source files of each module in `notLinked` whose compile options were known.
        var notLinkedFiles: [String: [String]] = [:]
        var compileSeconds = 0.0
        var parseSeconds = 0.0
    }

    /// Compiles every module `dependency` returns for the imports of `module` and links it in, following their
    /// imports in turn. Breadth first, one level of imports at a time: the level's modules are compiled and parsed at
    /// the same time, then linked in the order a one-at-a-time walk would link them, so the result does not depend on
    /// the threads.
    static func linkImports(
        into module: inout SILModule, options: CompileOptions, dependency: (String) throws -> CompileOptions?
    ) -> LinkedImports {
        var result = LinkedImports()
        var seen: Set<String> = [options.moduleName]
        var level = module.imports
        while !level.isEmpty {
            // `dependency` may run a `swift build`, so it is asked one module at a time.
            var wanted: [(name: String, options: CompileOptions)] = []
            for name in level where seen.insert(name).inserted {
                do {
                    guard var other = try dependency(name) else { continue }
                    other.optimization = options.optimization
                    other.configuration = options.configuration
                    other.verifiesCompilerSIL = options.verifiesCompilerSIL
                    wanted.append((name, other))
                } catch {
                    result.notLinked[name] = "\(error)"
                }
            }
            let compileStart = Date()
            let jobs = wanted
            let parsed = Slots<Result<SILModule, any Error>>(count: jobs.count)
            DispatchQueue.concurrentPerform(iterations: jobs.count) { index in
                let (name, other) = jobs[index]
                parsed.set(index, Result { try SILModule(text: SILText.prepare(try emitSIL(other), module: name, demangle: nil).clean) })
            }
            result.compileSeconds += Date().timeIntervalSince(compileStart)
            let linkStart = Date()
            level = []
            for (index, (name, other)) in jobs.enumerated() {
                do {
                    let parsedModule = try parsed.value(index).get()
                    module.link(parsedModule)
                    result.linked.append(name)
                    level += parsedModule.imports
                } catch {
                    result.notLinked[name] = "\(error)"
                    result.notLinkedFiles[name] = other.files
                }
            }
            result.parseSeconds += Date().timeIntervalSince(linkStart)
        }
        return result
    }
}

/// One result per index, written by the threads of a `concurrentPerform` and read after it returns.
private final class Slots<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [Value?]

    init(count: Int) { storage = Array(repeating: nil, count: count) }

    func set(_ index: Int, _ value: Value) {
        lock.lock()
        storage[index] = value
        lock.unlock()
    }

    /// The value set at `index`; every index is set before this is called.
    func value(_ index: Int) -> Value {
        lock.lock()
        defer { lock.unlock() }
        guard let value = storage[index] else { preconditionFailure("no value at \(index)") }
        return value
    }
}

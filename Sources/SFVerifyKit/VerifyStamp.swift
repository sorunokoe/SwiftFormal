import Foundation
import SFSIL

/// What `swiftformal check --gate` keeps for a target that passed, so that the next run can skip it while nothing the check
/// read has changed (`VerifyStampCheck`).
package struct VerifyStamp: Codable, Equatable {
    /// The file format; another one is not read.
    package static let currentFormat = 2

    /// See `currentFormat`.
    package var format = currentFormat
    /// The digest of everything the check read (`VerifyStampCheck`).
    package var fingerprint: String
    /// Every module the check asked to link, and whether it was a local target (whose files and arguments are in the
    /// fingerprint); asked again, each must still be what it was.
    package var dependencies: [String: Bool]
    /// Every file the compiler said it read (`CompilerDependencies`), outside the compiler's and the SDK's directories,
    /// with the digest of its contents; read again, each must still be what it was.
    package var files: [String: String]
    /// The diagnostics the check printed on stdout, printed again when the target is skipped.
    package var output: [String]
    /// The notes it printed on stderr (warnings about the run), printed again too.
    package var notes: [String]
    /// The counts of the check's last line (`1 of 1 promises proved by logic, …`).
    package var summary: String
}

/// Whether a target of `swiftformal check --gate` is unchanged since it last passed, and the stamp that says so.
///
/// The fingerprint covers what the check reads: the tool (`ScanToolIdentity`), the compiler, SDK and target triple,
/// the flags that change an outcome (`settings`), the target's frontend arguments with the contents of every file and
/// directory they name (sources, search paths, module maps, macro plugins; the compiler's own directories and the
/// SDK, with its stat cache, are covered by their versions), the manifests (`Package.swift`, `Package.resolved`) of
/// each package involved, the same for every local module the check linked, and every file the compiles said they
/// read (`CompilerDependencies`: also the C headers no argument names, such as `#include "../limits.h"`; files in the
/// compiler's and the SDK's directories are covered by their versions). An argument naming a path it cannot hash
/// (relative, or a VFS overlay that points elsewhere), or a compile that cannot tell what it read, gives no stamp.
///
/// The target is hashed before anything reads it: its promises are read from the bytes hashed (`source`). Each file
/// hashed keeps what `stat` said of it (device, inode, size, modification and change times, in nanoseconds). After
/// the check ran, everything is hashed again; a stamp is written only when the contents agree, no file's `stat`
/// changed, and every file first hashed then (the compiler's list) last changed before the check started, so an edit
/// made while the check ran is checked next time, even one undone again. Stamps are read and written like proof
/// cache entries (`TrustedFiles`), one file per tool, package and target.
package final class VerifyStampCheck: @unchecked Sendable {
    private let directory: String
    private let path: String
    private let identity: [String]
    private let compile: CompileOptions
    private let target: String
    private let toolchain: ScanToolchain
    private let inputs: VerifyInputs
    /// When the check started: a file first hashed after the check ran must have changed before.
    private let started: FileStatus.Time
    /// What the check's compiles read.
    private let read = CompilerDependencies()
    private let lock = NSLock()
    /// The digest of each module the check asked for when it asked (nil: not a local module).
    private var asked: [String: String?] = [:]
    private var unstampable = false

    /// A check of `target` of the package at `package`, whose stamps are in `directory`; nil when part of what the
    /// check reads cannot be hashed, or the tool is not known.
    package init?(
        directory: String, package: String, target: String, settings: String, compile: CompileOptions,
        tool: String? = ScanToolIdentity.current, toolchain: ScanToolchain?
    ) {
        guard let tool, let toolchain else { return nil }
        started = FileStatus.Time.now
        let inputs = VerifyInputs(toolchain: toolchain, keeping: compile.files)
        guard let digest = inputs.module(compile) else { return nil }
        self.directory = URL(fileURLWithPath: directory).standardizedFileURL.path
        // One stamp per tool too: two builds of swiftformal used on one package (release and debug, two checkouts) do
        // not overwrite each other's.
        path =
            self.directory + "/" + ProofDigest.hash(tool + "\n" + package + "\n" + target).replacingOccurrences(of: ":", with: "-")
            + ".json"
        identity = [
            "format=\(VerifyStamp.currentFormat)", "tool=\(tool)", "swiftc=\(toolchain.swiftc)",
            "version=\(toolchain.toolchain.swiftcVersion)", "sdkVersion=\(toolchain.toolchain.sdkVersion)",
            "sdk=\(toolchain.sdk ?? "-")", "triple=\(toolchain.triple)", "resources=\(toolchain.resourceDirectory ?? "-")",
            "settings=\(settings)", "package=\(package)", "target=\(target)",
        ]
        self.compile = compile
        self.target = digest
        self.toolchain = toolchain
        self.inputs = inputs
    }

    /// The stamp of the last passing check when nothing it read has changed; nil otherwise, or when the stamp is not
    /// trusted. `resolve` answers like the check's `linking`.
    package func unchanged(resolve: (String) throws -> CompileOptions?) -> VerifyStamp? {
        guard TrustedFiles.isTrustedDirectory(directory), case .data(let data) = TrustedFiles.read(path, limit: 1 << 24),
            let stamp = try? JSONDecoder().decode(VerifyStamp.self, from: data), stamp.format == VerifyStamp.currentFormat
        else { return nil }
        var dependencies: [String: String?] = [:]
        for (name, local) in stamp.dependencies {
            guard let digest = Self.digest(of: name, resolve: resolve, inputs: inputs), (digest != nil) == local else { return nil }
            dependencies[name] = digest
        }
        var files: [String: String] = [:]
        for path in stamp.files.keys {
            guard let digest = inputs.readFile(path) else { return nil }
            files[path] = digest
        }
        return fingerprint(target: target, dependencies: dependencies, files: files) == stamp.fingerprint ? stamp : nil
    }

    /// The text of a file of the target as it was hashed (nil when it is not one, or not UTF-8): what the check reads
    /// its promises from.
    package func source(_ path: String) -> String? { inputs.kept(path).flatMap { String(data: $0, encoding: .utf8) } }

    /// `compile`, recording what its compiles read.
    package func recording(_ compile: CompileOptions) -> CompileOptions {
        var compile = compile
        compile.dependencies = read
        return compile
    }

    /// `resolve`, recording each module asked for and the digest of what it was then.
    package func recording(_ resolve: @escaping (String) throws -> CompileOptions?) -> (String) throws -> CompileOptions? {
        { [self] name in
            do {
                var options = try resolve(name)
                options?.dependencies = read
                let digest = options.map { inputs.module($0) }
                lock.withLock {
                    if digest == .some(nil) || asked[name].map({ $0 != digest.flatMap { $0 } }) == true { unstampable = true }
                    asked[name] = digest.flatMap { $0 }
                }
                return options
            } catch {
                lock.withLock { unstampable = true }
                throw error
            }
        }
    }

    /// Writes the stamp of a check that passed and printed `output` and `notes`, unless a module it asked for could
    /// not be linked (`unlinked`) or hashed, a compile could not tell what it read, or anything it read changed since
    /// the check started. Returns whether it was written.
    @discardableResult
    package func store(
        output: [String], notes: [String], summary: String, unlinked: [String], resolve: (String) throws -> CompileOptions?
    ) -> Bool {
        let (asked, unstampable) = lock.withLock { (self.asked, self.unstampable) }
        // The target's own compile said what it read (it names the target's files).
        guard !unstampable, unlinked.isEmpty, let paths = read.files, paths.isSuperset(of: compile.files) else { return false }
        // Everything again, from the files as they are now.
        let now = VerifyInputs(toolchain: toolchain)
        guard now.module(compile) == target else { return false }
        for (name, digest) in asked {
            guard Self.digest(of: name, resolve: resolve, inputs: now) == .some(digest) else { return false }
        }
        var files: [String: String] = [:]
        for path in paths where !now.isCovered(path) {
            guard let digest = now.readFile(path) else { return false }
            files[path] = digest
        }
        guard now.unchanged(since: inputs, started: started) else { return false }
        let stamp = VerifyStamp(
            fingerprint: fingerprint(target: target, dependencies: asked, files: files), dependencies: asked.mapValues { $0 != nil },
            files: files, output: output, notes: notes, summary: summary)
        guard TrustedFiles.createDirectory(directory), TrustedFiles.isTrustedDirectory(directory),
            let data = try? JSONEncoder().encode(stamp)
        else { return false }
        return TrustedFiles.write(data, to: path)
    }

    private func fingerprint(target: String, dependencies: [String: String?], files: [String: String]) -> String {
        let modules = dependencies.sorted { $0.key < $1.key }.map { "import \($0.key) \($0.value ?? "not local")" }
        let read = files.sorted { $0.key < $1.key }.map { "read \($0.value)" }
        return ProofDigest.hash((identity + ["module=" + target] + modules + read).joined(separator: "\n"))
    }

    /// The digest of module `name` as `resolve` gives it (`.some(nil)` when it is not local); nil when it cannot be
    /// resolved or hashed.
    private static func digest(of name: String, resolve: (String) throws -> CompileOptions?, inputs: VerifyInputs) -> String?? {
        do {
            guard let options = try resolve(name) else { return .some(nil) }
            return inputs.module(options).map { .some($0) }
        } catch {
            return nil
        }
    }
}

import Foundation
import SFSIL

extension ModuleCompiler {
    /// The frontend invocation of `emitSIL` up to the SDK, plugin and file arguments: Scan's flags for `options`.
    package static func frontendArguments(_ options: CompileOptions) -> [String] {
        var arguments = [
            "swiftc", "-frontend", "-emit-sil", options.optimization.rawValue,
            "-module-name", options.moduleName, "-g", "-Xllvm", "-sil-print-debuginfo",
        ]
        if options.optimization == .none, options.configuration == .release { arguments += ["-assert-config", "Release"] }
        if !options.files.contains(where: { ($0 as NSString).lastPathComponent == "main.swift" }) {
            arguments.append("-parse-as-library")
        }
        if options.verifiesCompilerSIL { arguments.append("-sil-verify-all") }
        return arguments
    }

    /// The compiler, SDK, target, every argument the module's SIL was made with (the files, the optimization and
    /// assert configuration among them) and the modules linked in: one line each. Nil without a scan compiler.
    static func identity(_ options: CompileOptions, arguments: [String], linked: [String], unlinked: [String: String]) -> String? {
        func json(_ value: some Encodable) -> String? {
            (try? JSONEncoder().encode(value)).flatMap { String(bytes: $0, encoding: .utf8) }
        }
        guard let toolchain = try? ScanToolchain.current(), let argumentsJSON = json(arguments),
            let unlinkedJSON = json(unlinked.sorted { $0.key < $1.key }.map { [$0.key, $0.value] })
        else { return nil }
        return [
            "swiftc=\(toolchain.swiftc)", "version=\(toolchain.toolchain.swiftcVersion)", "sdkVersion=\(toolchain.toolchain.sdkVersion)",
            "sdk=\(toolchain.sdk ?? "-")", "triple=\(toolchain.triple)", "resources=\(toolchain.resourceDirectory ?? "-")",
            "module=\(options.moduleName)", "optimization=\(options.optimization)", "configuration=\(options.configuration)",
            "paranoid=\(options.verifiesCompilerSIL)", "arguments=" + argumentsJSON, "linked=\(linked.sorted())",
            "unlinked=" + unlinkedJSON,
        ].joined(separator: "\n")
    }
}

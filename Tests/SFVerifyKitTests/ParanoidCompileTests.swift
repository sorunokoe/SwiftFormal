import SFVerifyKit
import Testing

/// Plan item L12: `sfverify --paranoid` asks the compiler to verify its own SIL after every pass (`-sil-verify-all`).
@Suite struct ParanoidCompileTests {
    @Test func paranoidAddsTheCompilersSILVerifierAndNothingElse() {
        var options = CompileOptions(files: ["a.swift"], moduleName: "M")
        let plain = ModuleCompiler.frontendArguments(options)
        #expect(!plain.contains("-sil-verify-all"))
        #expect(Array(plain.prefix(4)) == ["swiftc", "-frontend", "-emit-sil", "-Onone"])

        options.verifiesCompilerSIL = true
        let paranoid = ModuleCompiler.frontendArguments(options)
        #expect(paranoid.filter { $0 != "-sil-verify-all" } == plain)
        #expect(paranoid.filter { $0 == "-sil-verify-all" }.count == 1)
    }
}

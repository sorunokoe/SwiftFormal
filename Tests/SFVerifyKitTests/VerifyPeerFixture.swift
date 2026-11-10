/// `declarations` where the compiler puts the peers `@Verify` writes next to `name`: in the expansion buffer of its peer
/// role, `@__swiftmacro_<module><name>6VerifyfMp_.swift`. Scan reads a contract only from there
/// (`FunctionInfo.isVerifyPeer`), so a fixture that stands for what `@Verify` writes, without building the macro,
/// places its `_requires` / `_ensures` this way; the same text without it is a hand-written contract, which is not read.
func verifyPeers(of name: String, module: String = "App", _ declarations: String) -> String {
    "#sourceLocation(file: \"@__swiftmacro_\(module.utf8.count)\(module)\(name.utf8.count)\(name)6VerifyfMp_.swift\", line: 1)\n"
        + declarations + "\n#sourceLocation()"
}

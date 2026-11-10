# SwiftFormalMacros: the code writer inside the compiler

**Job (Inspector view):** the clerk who fills in the paperwork. It writes the `Finite` conformance, `@Verify` checks and `#requires` / `#ensures` code for you, while the compiler runs.
**Raw input → typed → result:** Swift source syntax (swift-syntax) → macro expansion → generated Swift code, or a compiler diagnostic.
**Depends on:** nothing in this package (only swift-syntax). **Must not depend on:** any other target of this package.
**Fast loop:** `Scripts/sandbox.py SwiftFormalMacros`. **Connected loop:** `Scripts/sandbox.py SwiftFormalMacros --connect`
**Real consumers:** `SwiftFormal`, which declares the macros; its tests use them in real code (`swift test --filter SwiftFormalTests`).
**Platforms (verified):** macOS only. It is a compiler plugin and runs on the Mac that builds your app; it is never shipped inside an app.
**Known gaps:** the first build compiles swift-syntax (slow on a clean machine). Its fast-loop test target uses swift-syntax's macro test support, so it checks the expansion text, not that the result compiles in a user's module.

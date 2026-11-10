# 0002: One vocabulary, three tools

## Context

The package grew three ways to check a function, built at different times: running the real function over a finite domain (`verify`), proving claims over whole integer ranges with a SAT solver (`SFProve`), and reading compiler SIL to find possible traps (`sfverify`). Each one used its own words. The same idea was called a proof, a verdict, a result or a report depending on the file, and a reader could not tell how strong a given "proved" was.

## Decision

- Describe SwiftFormal with one picture: a building inspector for your real function. See [MENTAL-MODEL.md](../MENTAL-MODEL.md).
- Name the three tools **Walk** (`verify`), **Prove** (`SFProve`) and **Scan** (`sfverify`). Use these names in docs, errors and reports.
- Every message follows one order: the tool, then the verdict, then the evidence.
- Verdict words stay as they are in the code (`proved`, `bounded`, `counterexample`, `unknown`; for Scan `safe`, `mayTrap`, `contractHolds`, `contractFails`, `undecided`, `unsupported`). We name them in one place, the glossary, and do not rename them to match the analogy.
- `unsupported` and `unknown` always mean "SwiftFormal declined to answer". They are never a pass.

## Consequences

- A reader learns one analogy and can place any feature in it.
- Later phases that rename types or add an evidence line to reports have a fixed target to aim at.
- The analogy is a teaching aid, not an API. If it ever misleads, the glossary and [TRUST.md](../TRUST.md) win.

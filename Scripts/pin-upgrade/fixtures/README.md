# Pin-upgrade self-test fixtures

Inputs for `python3 Scripts/pin-upgrade/selftest.py`. Guide: [pin upgrade](../../../docs/guides/pin-upgrade.md).

## Third-party excerpts

`old/` and `new/` hold short excerpts of the Swift compiler sources, from the swiftlang/swift repository
(<https://github.com/swiftlang/swift>). That code is Copyright (c) Apple Inc. and the Swift project authors, and is
licensed under the Apache License, Version 2.0 with the Runtime Library Exception
(<https://swift.org/LICENSE.txt>). The excerpts are shortened. Long helper functions are reduced to their signature
with an empty body. Each file names its source in its first line.

| Folder | Source | Files |
|---|---|---|
| `old/` | `swift-6.3-RELEASE` (aa782beb23b8bd83bd16fca831532a05dd6cea39) | `include/swift/SIL/SILNodes.def` (the entries of the instructions named in it and their abstract classes; the `INST_RANGE` ends are shortened to match), `include/swift/AST/Builtins.def` (lines 37, 110-113, 118, 148-149), `lib/SIL/IR/SILPrinter.cpp` (the visitors and helpers named in it), `lib/SIL/Parser/ParseSIL.cpp` (the `static` and `dynamic` attribute checks), `lib/AST/ASTPrinter.cpp` (`getStringForParameterConvention`), `lib/AST/Builtins.cpp` (the `getBuiltinBaseName` signature) |
| `new/` | `swift-6.4.0-RELEASE` (b8189d766d86ad7fc8106787d6ce9e402f38dd72); `visitCondBranchInst` from `main` (9691209cd1612a7163f8f23327d021bd5a227898) | the same files |

## Known differences between `old/` and `new/`

The self-test checks that the gates find exactly these:

- `SILNodes.def`: `unchecked_inplace_enum_data_addr` is new (real, 6.4.0). `unchecked_take_enum_data_addr` moved under
  `UncheckedEnumDataAddrInstBase` (real, 6.4.0). `make_borrow` is new (real, 6.4.0; the reader does not use it).
- `Builtins.def`: `makeBorrow` is new (real, 6.4.0; the reader does not use it).
- `SILPrinter.cpp`: `visitCondBranchInst` no longer prints branch arguments (real, `main`).
  `visitUncheckedInPlaceEnumDataAddrInst` is new (real, 6.4.0). `visitRefCountingInst` has a comment and different
  indentation only. This edit was made for the self-test and is not in any release. Its fingerprint must not change.
- `ParseSIL.cpp`: a `non_nested` keyword. This edit was made for the self-test.

## Our files

`reader/` is not compiler code. It holds a few lines in the shape of `Sources/SFSIL/SILParser.swift` and
`Sources/SFSemantics/S0.swift`, so the reader-vocabulary derivation has a fixed input. These files are never compiled.

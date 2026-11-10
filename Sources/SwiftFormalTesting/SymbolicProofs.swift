// The third tool comes with the test library: `import SwiftFormalTesting` also gives SFProve's symbolic integer proofs
// (`proveSigned(widths:requires:_:)`, `SymbolicInt`, `ProofVerdict`), so a test target needs one product. SFProve is no
// product of its own any more (one way to depend on SwiftFormal).
@_exported public import SFProve

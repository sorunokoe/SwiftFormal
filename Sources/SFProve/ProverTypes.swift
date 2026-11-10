import SFBV
import SFCNF
import SFCheck
import SFSAT

/// A type defined in each module of the prover (this one, the SAT solver, the LRAT checker, the CNF and bit-vector
/// layers). The image that holds a type's metadata is the image the module was linked into, so a proof cache can name
/// the code that made and checked its answers (`ScanToolImages`).
package enum ProverTypes {
    /// One type of each module, in no particular order.
    package static func all() -> [Any.Type] {
        [ProofVerdict.self, Solver.self, LRATChecker.self, CNF.self, CNFBuilder.self]
    }
}

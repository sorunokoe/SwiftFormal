/// One `Rule` found in the sources, with the literal values used in its own code.
/// Those literals are where a Rule changes behaviour, so they become the interesting input values.
public struct RuleInfo: Sendable {
    public var name: String
    public var file: String
    public var line: Int
    public var isPrivate: Bool
    public var isGeneric: Bool
    public var ints: [Int] = []
    public var doubles: [Double] = []
    public var strings: [String] = []
    /// The module the Rule lives in and the modules its file imports: together they decide which declaration
    /// a type name means when two modules declare the same one.
    public var module: String?
    public var imports: [String] = []
}

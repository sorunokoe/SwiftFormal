/// A position in a source file, as the compiler's debug info gives it.
public struct SourceLocation: Codable, Sendable, Equatable, CustomStringConvertible {
    public var file: String
    public var line: Int
    public var column: Int
    public var description: String { "\(file):\(line):\(column)" }

    public init(file: String, line: Int, column: Int) {
        self.file = file
        self.line = line
        self.column = column
    }
}

// swift-format-ignore-file
// (swift-format would strip the spaces in the `#sourceLocation` markers below.)
// Planted-bug suite, shape 9: a wrong arm in a mapper over an enum from a binary framework.
//
// The enum stands in for one a Kotlin Multiplatform framework exports: the compiler synthesizes its `allCases`, and
// it is not `Finite`. The walk takes it as it is, with no `extension SignalStrength: Finite {}`.

enum SignalStrength: CaseIterable {
    case none, weak, fair, strong
}

/// Bars on the status bar: none 0, weak 1, fair 2, strong 3. The planted bug shows a fair signal as full.
func barsBuggy(_ signal: SignalStrength) -> Int {
    switch signal {
    case .none: 0
    case .weak: 1
    case .fair: 3
    case .strong: 3
    }
}

func barsFixed(_ signal: SignalStrength) -> Int {
    switch signal {
    case .none: 0
    case .weak: 1
    case .fair: 2
    case .strong: 3
    }
}

// Only a strong signal shows every bar, and only no signal shows none.
#sourceLocation(file: "@__swiftmacro_11PlantedBugs9barsBuggy6VerifyfMp_.swift", line: 1)
func barsBuggy_ensures(_ signal: SignalStrength, _ bars: Int) -> Bool {
    (bars == 3) == (signal == .strong) && (bars == 0) == (signal == .none)
}
#sourceLocation()
#sourceLocation(file: "@__swiftmacro_11PlantedBugs9barsFixed6VerifyfMp_.swift", line: 1)
func barsFixed_ensures(_ signal: SignalStrength, _ bars: Int) -> Bool {
    (bars == 3) == (signal == .strong) && (bars == 0) == (signal == .none)
}
#sourceLocation()

// A hand-written `allCases` that forgets `.high`: a generated domain checks the list and falls back to a sample.
enum Volume: CaseIterable {
    case mute, low, high
    static var allCases: [Volume] { [.mute, .low] }
}

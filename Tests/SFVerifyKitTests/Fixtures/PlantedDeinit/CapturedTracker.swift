// swift-format-ignore-file
// (swift-format would strip the spaces in the `#sourceLocation` markers below.)
// Planted-bug suite, shape 12b: a closure whose capture's deinit traps. A row holds a tap handler; the handler may
// capture the last reference to a tracker, and destroying the row then runs the tracker's deinit, which traps when the
// tracker is left with a negative count. A mapper that only reads the row's score destroys the row too: it may never
// be a pass that does not say so.

final class TapTracker {
    var pending: Int8 = 0
    deinit { precondition(pending >= 0, "a tap was counted twice") }
}

struct TappableRow {
    var score: Int8
    var onTap: () -> Void
}

/// The score a row shows.
func rowScore(_ row: TappableRow) -> Int8 { row.score }

#sourceLocation(file: "@__swiftmacro_3App8rowScore6VerifyfMp_.swift", line: 1)
func rowScore_ensures(_ row: TappableRow, _ shown: Int8) -> Bool { shown == row.score }
#sourceLocation()

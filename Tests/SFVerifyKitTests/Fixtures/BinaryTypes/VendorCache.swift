// swift-format-ignore-file
// (swift-format would strip the spaces in the `#sourceLocation` markers below.)
// Planted-bug suite, shape 12b, a superclass of a binary module: destroying a row may release the last reference to a
// cache, whose deinit calls its superclass's in `Seasons`. Scan has no body of that deinit, so it may never be a pass
// that does not say so.

import Seasons

final class Cache: VendorBase {}

struct CachedRow {
    var score: Int8
    var onTap: () -> Void
}

/// The score a row shows.
func cachedScore(_ row: CachedRow) -> Int8 { row.score }

#sourceLocation(file: "@__swiftmacro_3App11cachedScore6VerifyfMp_.swift", line: 1)
func cachedScore_ensures(_ row: CachedRow, _ shown: Int8) -> Bool { shown == row.score }
#sourceLocation()

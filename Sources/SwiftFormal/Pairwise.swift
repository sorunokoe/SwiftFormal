/// All-pairs covering arrays: a short list of rows such that, for every two factors, every combination
/// of their values appears in at least one row. Bugs that need two fields to line up are found with far
/// fewer inputs than the full product (about 25 rows for 8 factors of 3 values, against 6 561).
/// Bugs that need three or more fields to line up can be missed, so a pairwise domain is never `complete`.
public enum Pairwise {
    /// Rows of value indices. `levels[i]` is the number of values of factor `i`.
    /// Deterministic: the same `levels` always give the same rows.
    public static func rows(levels: [Int]) -> [[Int]] {
        rows(levels: levels, limit: Int.max)
    }

    /// The most rows `Domain.combinations` asks for. The cover is built greedily, so the first rows cover the
    /// most pairs; a larger cover costs seconds to build and is never evaluated in full.
    static let combinationRowLimit = 4096

    /// The most value pairs the greedy cover tracks (one byte each).
    private static let pairTableLimit = 4_000_000

    /// `count` rows in which factor `i` walks through all its values in turn, each pass shifted by a seeded
    /// offset, so every value appears and the factors do not move in lockstep.
    private static func spread(levels: [Int], count: Int) -> [[Int]] {
        let total = min(count, 1 << 20)
        var shifts: [[Int]] = levels.map { _ in [] }
        var rng = SplitMix64(seed: 0x5F0F_A117)
        return (0..<total).map { row in
            levels.indices.map { factor in
                let pass = row / levels[factor]
                while shifts[factor].count <= pass { shifts[factor].append(Int(rng.next() % UInt64(levels[factor]))) }
                return (row + shifts[factor][pass]) % levels[factor]
            }
        }
    }

    /// The first `limit` rows of the cover. With a limit the cover may leave some pairs uncovered.
    /// When the pairs are too many to track (`pairTableLimit`), the rows are a deterministic spread instead:
    /// every value of every factor still appears, but pairs are only sampled.
    static func rows(levels: [Int], limit: Int) -> [[Int]] {
        precondition(levels.allSatisfy { $0 >= 0 })
        if levels.isEmpty { return [[]] }
        if levels.contains(0) { return [] }
        if levels.count == 1 { return (0..<levels[0]).map { [$0] } }

        if limit < Int.max {
            var pairSpace = 0
            for i in levels.indices {
                for j in levels.indices where j > i { pairSpace = saturatingAdd(pairSpace, saturatingMultiply(levels[i], levels[j])) }
            }
            if pairSpace > pairTableLimit { return spread(levels: levels, count: limit) }
        }

        let factorCount = levels.count
        var covered: [[[Bool]]] = Array(repeating: [], count: factorCount * factorCount)
        for i in 0..<factorCount {
            for j in (i + 1)..<factorCount {
                covered[i * factorCount + j] = Array(
                    repeating: Array(repeating: false, count: levels[j]), count: levels[i]
                )
            }
        }

        var rows: [[Int]] = []
        var cursor = (i: 0, j: 1, a: 0, b: 0)

        func nextUncovered() -> (i: Int, j: Int, a: Int, b: Int)? {
            while cursor.i < factorCount - 1 {
                while cursor.j < factorCount {
                    while cursor.a < levels[cursor.i] {
                        while cursor.b < levels[cursor.j] {
                            if !covered[cursor.i * factorCount + cursor.j][cursor.a][cursor.b] { return cursor }
                            cursor.b += 1
                        }
                        cursor.b = 0
                        cursor.a += 1
                    }
                    cursor.a = 0
                    cursor.j += 1
                }
                cursor.i += 1
                cursor.j = cursor.i + 1
            }
            return nil
        }

        while rows.count < limit, let start = nextUncovered() {
            var row = Array(repeating: -1, count: factorCount)
            row[start.i] = start.a
            row[start.j] = start.b
            for factor in 0..<factorCount where row[factor] < 0 {
                var best = 0
                var bestGain = -1
                for value in 0..<levels[factor] {
                    var gain = 0
                    for other in 0..<factorCount where row[other] >= 0 {
                        let (low, high) = other < factor ? (other, factor) : (factor, other)
                        let (a, b) = other < factor ? (row[other], value) : (value, row[other])
                        if !covered[low * factorCount + high][a][b] { gain += 1 }
                    }
                    if gain > bestGain { bestGain = gain; best = value }
                }
                row[factor] = best
            }
            for i in 0..<factorCount {
                for j in (i + 1)..<factorCount { covered[i * factorCount + j][row[i]][row[j]] = true }
            }
            rows.append(row)
        }
        return rows
    }
}

extension Domain {
    /// Combinations of several fields, given only by how many values each field has.
    ///
    /// When the full product has at most `fullProductLimit` values, every combination is produced and the
    /// domain is `complete` if `complete` is true. Otherwise an all-pairs cover is produced and the domain is
    /// a sample of at most 4,096 rows. `build` receives one value index per field.
    ///
    /// ```swift
    /// let inputs = Domain<Input>.combinations(levels: [flags.count, names.count, scores.count], complete: true) {
    ///     Input(flag: flags[$0[0]], name: names[$0[1]], score: scores[$0[2]])
    /// }
    /// ```
    public static func combinations(
        levels: [Int],
        complete: Bool,
        fullProductLimit: Int = 1024,
        build: @escaping ([Int]) -> Value
    ) -> Domain {
        let product = levels.reduce(1, saturatingMultiply)
        if product <= fullProductLimit {
            return Domain(
                count: product,
                complete: complete,
                element: { index in
                    var remaining = index
                    var picks = Array(repeating: 0, count: levels.count)
                    for factor in levels.indices.reversed() {
                        picks[factor] = remaining % levels[factor]
                        remaining /= levels[factor]
                    }
                    return build(picks)
                },
                random: { rng in build(levels.map { Int(rng.next() % UInt64($0)) }) }
            )
        }
        let rows = Pairwise.rows(levels: levels, limit: Pairwise.combinationRowLimit)
        return Domain(
            count: rows.count,
            complete: false,
            element: { build(rows[$0]) },
            random: { rng in build(rows[Int(rng.next() % UInt64(rows.count))]) }
        )
    }
}

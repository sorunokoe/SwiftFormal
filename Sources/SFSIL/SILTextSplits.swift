import SFBV

// The text of a concatenation whose parts are not all known (`a + b`, an interpolation, `String(format:)`): when it
// is a recorded text, which parts it was made of.
//
// Swift compares strings by canonical equivalence: two strings are equal when their NFD forms are. Every recorded
// text is ASCII, and every ASCII character is a starter that NFD leaves alone. The NFD form of `a + b` is the NFD
// forms of `a` and `b` joined and then reordered, and reordering only moves combining marks, of which an ASCII text
// has none. So `a + b` equals the ASCII text `t` exactly when, for some byte position `i`, `a` equals `t[..<i]` and
// `b` equals `t[i...]`; by induction, `p1 + … + pn` equals `t` exactly when `t` cuts into pieces each part equals.
// A concatenation is kept as its parts (its skeleton: known texts and unknown handles, `CNFBuilder.textSkeletons`),
// and for every recorded text (`forEveryText`) the ways `t` matches the skeleton are listed: the known parts anchor
// them. These are facts true of every string. A piece an unknown part must equal is recorded too, while there is
// room, so the facts of the call that made the part (the decimal text of an integer) apply to it. A skeleton with
// no known part, or a text with too many matches, gets no facts: the result is then any text, which is sound.
//
// `hasPrefix(_:)` compares characters (grapheme clusters), not bytes: `"-" + "\u{301}"` does not start with "-". A
// string that starts with the bytes of the ASCII text `A` starts with every ASCII `P` shorter than `A` that `A` starts
// with: the break between two ASCII characters is fixed (the one exception, CR LF, is checked), so the characters of
// `P` are the first characters of the string. It does not start with an ASCII `P` that differs from `A` before `A`'s
// last byte.

extension StdlibSummary.Text {
    /// A part of a concatenation: a known text, or an unknown handle.
    enum Part {
        case known(String)
        case unknown(BV)
    }

    /// How many parts a skeleton may have, how many ways a text may match it, and how many handles with a known start
    /// are kept.
    static let (partLimit, matchLimit, startLimit) = (16, 32, 256)

    /// The parts of `h`: its skeleton, or `h` itself.
    func parts(_ h: BV) -> [Part] {
        if let x = known(h) { return x.isEmpty ? [] : [.known(x)] }
        if let skeleton = c.textSkeletons[h.bits] {
            return skeleton.map { part in
                if case .some(let id) = part.text, let x = StringIdentity.text(of: id) { return .known(x) }
                return .unknown(part.handle)
            }
        }
        return [.unknown(h)]
    }

    /// Adds the facts above for `r`, the handle of `a + b`, when the result is not exact.
    func relateParts(_ r: BV, _ a: BV, _ b: BV) {
        guard let skeleton = Self.skeleton(parts(a) + parts(b)) else { return }
        c.textSkeletons[r.bits] = skeleton.map { part in
            switch part {
            case .known(let x): (c.constant(StringIdentity.id(of: x) ?? 0, width: 64), StringIdentity.id(of: x))
            case .unknown(let h): (h, nil)
            }
        }
        if case .known(let start) = skeleton[0], c.textStarts.count < Self.startLimit { c.textStarts.append((r, start)) }
        forEveryText { c, id in Self(c: c).relate(r, skeleton, toText: id) }
    }

    /// `parts` with adjacent known texts joined; nil unless it has a known part, every known part is ASCII and it has at
    /// most `partLimit` parts.
    static func skeleton(_ parts: [Part]) -> [Part]? {
        var skeleton: [Part] = []
        for part in parts {
            if case .known(let y) = part, case .known(let x) = skeleton.last {
                skeleton[skeleton.count - 1] = .known(x + y)
            } else {
                skeleton.append(part)
            }
        }
        let knownParts = skeleton.compactMap { if case .known(let x) = $0 { x } else { nil } }
        guard skeleton.count <= partLimit, !knownParts.isEmpty, knownParts.allSatisfy({ $0.utf8.allSatisfy { $0 < 0x80 } })
        else { return nil }
        return skeleton
    }

    /// `r` (made of `skeleton`) is the recorded text `id` exactly when one of the ways the text matches the skeleton
    /// holds: each unknown part equals its piece.
    private func relate(_ r: BV, _ skeleton: [Part], toText id: UInt64) {
        guard let t = StringIdentity.text(of: id), t.utf8.allSatisfy({ $0 < 0x80 }), let matches = Self.matches(Array(t.utf8), skeleton)
        else { return }
        let records = c.textHandles.count < Self.recorded / 2
        var ways: [Int32] = []
        for match in matches {
            var way = c.trueLit
            for (h, piece) in match {
                let x = String(piece.map { Character(Unicode.Scalar($0)) })
                guard let p = records ? handle(x) : StringIdentity.id(of: x).map({ c.constant($0, width: 64) }) else { return }
                way = c.and(way, c.eq(h, p))
            }
            ways.append(way)
        }
        let isText = c.eq(r, c.constant(id, width: 64))
        c.addClause([-isText] + ways)
        for way in ways { c.addClause([isText, -way]) }
    }

    /// The ways the bytes `t` match `skeleton`: for each, the piece every unknown part equals; nil past `matchLimit`.
    static func matches(_ t: [UInt8], _ skeleton: [Part]) -> [[(BV, ArraySlice<UInt8>)]]? {
        var found: [[(BV, ArraySlice<UInt8>)]] = []
        var steps = 0
        func walk(_ k: Int, _ at: Int, _ pieces: [(BV, ArraySlice<UInt8>)]) -> Bool {
            steps += 1
            guard steps <= 4096 else { return false }
            guard k < skeleton.count else {
                if at == t.count { found.append(pieces) }
                return found.count <= matchLimit
            }
            switch skeleton[k] {
            case .known(let x):
                let bytes = Array(x.utf8)
                guard t[at...].starts(with: bytes) else { return true }
                return walk(k + 1, at + bytes.count, pieces)
            case .unknown(let h):
                for end in at...t.count where !walk(k + 1, end, pieces + [(h, t[at..<end])]) { return false }
                return true
            }
        }
        return walk(0, 0, []) ? found : nil
    }

    /// `s.hasPrefix(part)` for a known `part`, when `s` is one of the handles known to start with an ASCII text that
    /// decides it: `value` where that is not so, and the condition under which the answer is exact.
    func knownPrefix(of s: BV, _ part: BV, otherwise value: BV, exact: Int32) -> (value: BV, exact: Int32) {
        guard let p = known(part) else { return (value, exact) }
        var (value, exact) = (value, exact)
        for (handle, start) in c.textStarts {
            guard let starts = Self.starts(start, with: p) else { continue }
            let same = c.eq(s, handle)
            if same == c.falseLit { continue }
            (value, exact) = (c.select(same, BV(bits: [starts ? c.trueLit : c.falseLit]), value), c.or(exact, same))
        }
        return (value, exact)
    }

    /// Whether a string that starts with the bytes of `start` has the prefix `p`, when that decides it.
    static func starts(_ start: String, with p: String) -> Bool? {  // swiftlint:disable:this discouraged_optional_boolean
        let (a, q) = (Array(start.utf8), Array(p.utf8))
        guard a.allSatisfy({ $0 < 0x80 }), q.allSatisfy({ $0 < 0x80 }) else { return nil }
        if q.count < a.count, a.starts(with: q) {
            // A break after `part` unless it ends with CR and LF follows.
            return q.last == 0x0D && a[q.count] == 0x0A ? nil : true
        }
        if let j = a.indices.first(where: { $0 < q.count && a[$0] != q[$0] }), j < a.count - 1 { return false }
        return nil
    }
}

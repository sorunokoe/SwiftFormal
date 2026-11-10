extension StringProtocol {
    /// `contains(needle)` for an ASCII `needle`, without comparing characters on every line: a search of the UTF-8
    /// bytes finds every place `contains` can match (and possibly a few more, next to combining characters), and
    /// `contains` confirms a hit, so the answer is exactly `contains`'s. Used where whole modules are searched.
    func containsText(_ needle: String) -> Bool { utf8Contains(needle) && contains(needle) }

    private func utf8Contains(_ needle: String) -> Bool {
        let bytes = utf8
        let pattern = needle.utf8
        guard let first = pattern.first else { return true }
        var start = bytes.startIndex
        while let candidate = bytes[start...].firstIndex(of: first) {
            var position = candidate
            var matched = true
            for byte in pattern {
                guard position != bytes.endIndex, bytes[position] == byte else {
                    matched = false
                    break
                }
                bytes.formIndex(after: &position)
            }
            if matched { return true }
            start = bytes.index(after: candidate)
        }
        return false
    }
}

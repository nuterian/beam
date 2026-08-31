import Foundation

/// Find (PLAN.md §5.8).
///
/// An editor without find is not an editor, and Beam did not have one: the
/// command table had eighteen entries and none of them searched. This is the
/// smallest thing that fixes that honestly — a literal substring search over
/// the buffer's bytes, every match on screen highlighted, one of them current.
///
/// **Not a regex, and that is a decision rather than a shortcut.** A regex
/// engine is a dependency and a parser on the keystroke path, and the failure
/// mode of a bad one is a pathological backtrack that hangs the editor
/// mid-keystroke — in the one product whose entire claim is that a keystroke
/// costs 0.3 ms. Literal search is what people use ninety-nine times in a
/// hundred; regex joins the named list in §1 of things we signed up to build
/// and have not, rather than being smuggled in unbudgeted.
public struct FindState: Equatable {
    /// What was typed, as bytes. Bytes rather than a `String` because the
    /// buffer is bytes and the match offsets it produces have to be buffer
    /// offsets — converting per keystroke would be a second representation of
    /// the same thing, and the two would eventually disagree about a multi-byte
    /// character the way `InstanceWriter.text` once did (PLAN.md §5.3).
    public private(set) var query: [UInt8] = []
    /// Byte offset of every match, ascending.
    public private(set) var matches: [Int] = []
    /// Index into `matches`, or -1 when there are none.
    public private(set) var current = -1

    public init() {}

    public var isEmpty: Bool { query.isEmpty }
    public var count: Int { matches.count }
    /// 1-based, for the readout. People count matches from one.
    public var currentDisplayIndex: Int { current < 0 ? 0 : current + 1 }

    /// The match the caret is on, as a range.
    public var currentRange: Range<Int>? {
        guard current >= 0, current < matches.count else { return nil }
        return matches[current]..<(matches[current] + query.count)
    }

    /// **Smart case**: a lowercase query matches either case, a query with any
    /// uppercase in it matches exactly. It is what every modern editor does and
    /// it is the only case rule that needs no control to explain it — the
    /// alternative is a toggle, and a toggle is chrome for a decision the query
    /// already contains.
    public var caseSensitive: Bool { query.contains { $0 >= 65 && $0 <= 90 } }

    @inline(__always) private static func fold(_ b: UInt8, _ sensitive: Bool) -> UInt8 {
        // ASCII only, deliberately: case folding beyond ASCII is locale-shaped
        // (Turkish dotless i, German ß) and belongs with the Unicode work §1
        // already names. A non-ASCII query is matched exactly, which is
        // predictable, rather than approximately, which is not.
        (!sensitive && b >= 65 && b <= 90) ? b + 32 : b
    }

    /// Re-scan the whole buffer for `query`.
    ///
    /// **Whole-buffer, on the keystroke path, on purpose.** The count is part
    /// of the answer — "3 of 47" is what tells you whether to keep typing — and
    /// a count that has not counted is a lie. So it is budgeted instead of
    /// avoided: `find_keystroke_to_commit_p99_ms` is the row, and the scan is
    /// one pass of byte compares over `withRaw`, allocating nothing but the
    /// match array. If that row ever breaches, the fix is on the shelf and is
    /// not being pre-applied: matches of "ab" are a subset of matches of "a",
    /// so a query that only grew can filter the previous result instead of
    /// re-scanning. This project does not merge unmeasured optimisations.
    public mutating func rescan(_ buffer: TextBuffer, near caret: Int) {
        matches.removeAll(keepingCapacity: true)
        current = -1
        let n = query.count
        guard n > 0, buffer.count >= n else { return }
        let sensitive = caseSensitive
        let first = Self.fold(query[0], sensitive)
        let limit = buffer.count - n
        query.withUnsafeBufferPointer { q in
            buffer.withRaw { base, gapStart, gapLength in
                @inline(__always) func byte(_ i: Int) -> UInt8 {
                    base[i < gapStart ? i : i + gapLength]
                }
                var i = 0
                while i <= limit {
                    if Self.fold(byte(i), sensitive) == first {
                        var k = 1
                        while k < n, Self.fold(byte(i + k), sensitive)
                                        == Self.fold(q[k], sensitive) { k += 1 }
                        if k == n {
                            matches.append(i)
                            // Overlapping matches are not reported: stepping
                            // through "aa" in "aaaa" three times, where two of
                            // the three share bytes with the one before, is not
                            // what anybody means by "next".
                            i += n
                            continue
                        }
                    }
                    i += 1
                }
            }
        }
        // The first match at or after the caret, so ⌘F from where you are
        // searches forward from where you are — never from the top of the file,
        // which is the thing that makes people scroll back to where they were.
        current = matches.firstIndex { $0 >= caret } ?? (matches.isEmpty ? -1 : 0)
    }

    public mutating func setQuery(_ q: [UInt8], buffer: TextBuffer, caret: Int) {
        query = q
        rescan(buffer, near: caret)
    }

    /// Step to the next match, wrapping. Wrapping rather than stopping: a find
    /// that stops at the end makes you look at the screen to find out whether
    /// it did, and there is nothing else it could sensibly do.
    public mutating func step(_ delta: Int) {
        guard !matches.isEmpty else { current = -1; return }
        if current < 0 { current = delta > 0 ? 0 : matches.count - 1; return }
        current = ((current + delta) % matches.count + matches.count) % matches.count
    }

    /// Matches whose start falls inside a visible byte range, for the frame.
    ///
    /// The highlight is bounded by the VIEWPORT, exactly as the lexer is
    /// (PLAN.md §5.3): the frame draws only what is on screen, so a file with
    /// ten thousand matches costs the same frame as one with three. `matches`
    /// is ascending, so this is two binary searches and a slice.
    public func matches(in range: Range<Int>) -> ArraySlice<Int> {
        guard !matches.isEmpty else { return matches[0..<0] }
        let lo = lowerBound(range.lowerBound - query.count + 1)
        let hi = lowerBound(range.upperBound)
        return matches[lo..<hi]
    }

    private func lowerBound(_ value: Int) -> Int {
        var lo = 0, hi = matches.count
        while lo < hi {
            let mid = (lo + hi) / 2
            if matches[mid] < value { lo = mid + 1 } else { hi = mid }
        }
        return lo
    }
}

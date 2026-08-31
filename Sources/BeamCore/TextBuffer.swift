import Foundation

/// One edit, in **exactly the shape a CRDT delta has**: a position, the bytes
/// that left, the bytes that arrived.
///
/// This is the seam Phase 3 slides `yrs` into (PLAN.md §5.3). Everything above
/// the storage — the line index, the undo stack, the highlighter's dirty set,
/// the render path — is updated only from this triple, never by reaching into
/// the bytes. A CRDT hands you deltas and not ownership, so anything that
/// needed ownership would have to be rewritten; nothing here does.
public struct Edit: Equatable {
    /// Logical byte offset the edit applies at.
    public let offset: Int
    public let removed: [UInt8]
    public let inserted: [UInt8]

    public init(offset: Int, removed: [UInt8], inserted: [UInt8]) {
        self.offset = offset
        self.removed = removed
        self.inserted = inserted
    }

    /// The edit that puts the document back. Undo is this, and nothing else.
    public var inverse: Edit {
        Edit(offset: offset, removed: inserted, inserted: removed)
    }
}

/// The document's bytes: a **gap buffer**, with the newline positions kept in
/// *raw* buffer coordinates (PLAN.md §5.3).
///
/// ## Why raw coordinates
///
/// The buffer is `[0, gapStart)` document, `[gapStart, gapEnd)` empty,
/// `[gapEnd, raw.count)` document. Typing at the caret is `raw[gapStart] = b;
/// gapStart += 1` — and because the newline index stores *raw* indices, that
/// insert **changes no stored index at all**: the newlines below the gap are
/// still below it, and the ones above it are untouched while their logical
/// positions shift by exactly the one byte the gap lost. Typing therefore costs
/// the line index nothing, in a 1 MB file exactly as in an empty one.
///
/// The obvious alternative — storing *logical* line starts — makes every single
/// keystroke an O(lines) fixup of every entry after the caret. On a 30k-line
/// file that is ~10 µs a keystroke: comfortably inside the commit budget, and
/// the wrong shape, because it makes document size visible in typing latency.
/// `L2.keystroke_to_commit_1mb_doc_p99_ms` shares the empty-document budget
/// precisely so that claim is measured rather than asserted.
///
/// ## Why newline positions and not line starts
///
/// A line *start* at the caret is ambiguous — it can be read as sitting on
/// either side of the gap, and the two readings disagree about which way the
/// line moves when you type. A newline is a real byte with a real raw index; it
/// is never inside the gap, and there is nothing to decide. The ambiguity that
/// disappears is the one every gap-buffer line index gets wrong.
///
/// Not thread-safe, deliberately: edits arrive on the main thread from input
/// and from the session's op handler, which already hops to main.
public final class TextBuffer {
    private var raw: ContiguousArray<UInt8>
    private var gapStart: Int
    private var gapEnd: Int
    /// Raw indices of every `\n` byte, ascending. `lineCount == newlines.count + 1`.
    private var newlines: [Int]

    /// Smallest gap re-opened on a grow. Big enough that a burst of typing does
    /// not reallocate, small enough to be invisible next to the document.
    private static let minGap = 4096

    public init() {
        raw = ContiguousArray(repeating: 0, count: Self.minGap)
        gapStart = 0
        gapEnd = Self.minGap
        newlines = []
    }

    /// Loads a whole file's bytes. One allocation, one scan for newlines, and
    /// the gap opens at the end — which is where a caret starts and where an
    /// append-heavy first minute of editing wants it.
    public init(bytes: [UInt8]) {
        raw = ContiguousArray(bytes)
        raw.append(contentsOf: repeatElement(0, count: Self.minGap))
        gapStart = bytes.count
        gapEnd = raw.count
        newlines = []
        newlines.reserveCapacity(bytes.count / 32 + 8)
        for (i, b) in bytes.enumerated() where b == 0x0A { newlines.append(i) }
    }

    public var gapLength: Int { gapEnd - gapStart }
    /// Document length in bytes.
    public var count: Int { raw.count - gapLength }
    public var isEmpty: Bool { count == 0 }

    @inline(__always) private func rawIndex(_ logical: Int) -> Int {
        logical < gapStart ? logical : logical + gapLength
    }
    @inline(__always) private func logicalIndex(_ raw: Int) -> Int {
        raw < gapStart ? raw : raw - gapLength
    }

    public func byte(at logical: Int) -> UInt8 {
        guard logical >= 0, logical < count else { return 0 }
        return raw[rawIndex(logical)]
    }

    /// Reads a logical range without allocating. The closure gets the raw base,
    /// the gap start and the gap length; a caller walking `[lo, hi)` resolves
    /// each index with one compare and one add, which for the ~3500 bytes a
    /// full screen of code contains is far below the noise floor of the frame.
    public func withRaw<R>(_ body: (UnsafePointer<UInt8>, Int, Int) throws -> R) rethrows -> R {
        try raw.withUnsafeBufferPointer { try body($0.baseAddress!, gapStart, gapLength) }
    }

    public func bytes(in range: Range<Int>) -> [UInt8] {
        let lo = max(0, range.lowerBound), hi = min(count, range.upperBound)
        guard lo < hi else { return [] }
        var out = [UInt8](); out.reserveCapacity(hi - lo)
        for i in lo..<hi { out.append(raw[rawIndex(i)]) }
        return out
    }

    public func string(in range: Range<Int>) -> String {
        String(decoding: bytes(in: range), as: UTF8.self)
    }

    public var wholeText: String { string(in: 0..<count) }

    // MARK: - Lines

    public var lineCount: Int { newlines.count + 1 }

    /// Logical byte range of a line, **excluding** its terminating newline.
    public func lineRange(_ line: Int) -> Range<Int> {
        guard line >= 0, line < lineCount else { return 0..<0 }
        let start = line == 0 ? 0 : logicalIndex(newlines[line - 1]) + 1
        let end = line == newlines.count ? count : logicalIndex(newlines[line])
        return start..<max(start, end)
    }

    /// The line a logical offset falls on. Binary search over the newline
    /// index, so a click anywhere in a 1 MB file is ~15 comparisons.
    public func line(ofOffset offset: Int) -> Int {
        let o = min(max(0, offset), count)
        var lo = 0, hi = newlines.count
        while lo < hi {
            let mid = (lo + hi) / 2
            if logicalIndex(newlines[mid]) < o { lo = mid + 1 } else { hi = mid }
        }
        return lo
    }

    /// Line + byte-column of an offset. Column is in BYTES, not cells: the
    /// caller maps bytes to cells through the UTF-8 walk it is doing anyway.
    public func position(ofOffset offset: Int) -> (line: Int, byteColumn: Int) {
        let l = line(ofOffset: offset)
        return (l, min(max(0, offset), count) - lineRange(l).lowerBound)
    }

    public func offset(line: Int, byteColumn: Int) -> Int {
        let r = lineRange(min(max(0, line), lineCount - 1))
        return min(r.lowerBound + max(0, byteColumn), r.upperBound)
    }

    // MARK: - Editing

    /// Applies an edit and returns it, so callers can push it onto an undo
    /// stack or put it on the wire without re-deriving anything. The single
    /// funnel every local and remote change goes through (PLAN.md §5.3).
    @discardableResult
    public func apply(_ edit: Edit) -> Edit {
        if !edit.removed.isEmpty { removeBytes(edit.offset..<(edit.offset + edit.removed.count)) }
        if !edit.inserted.isEmpty { insertBytes(edit.inserted, at: edit.offset) }
        return edit
    }

    /// Convenience: build the edit for an insert (capturing nothing removed).
    public func insert(_ bytes: [UInt8], at offset: Int) -> Edit {
        apply(Edit(offset: offset, removed: [], inserted: bytes))
    }

    /// Convenience: build the edit for a delete, capturing the removed bytes so
    /// the edit is invertible before it is applied.
    public func remove(_ range: Range<Int>) -> Edit {
        let lo = max(0, range.lowerBound), hi = min(count, range.upperBound)
        guard lo < hi else { return Edit(offset: lo, removed: [], inserted: []) }
        return apply(Edit(offset: lo, removed: bytes(in: lo..<hi), inserted: []))
    }

    private func insertBytes(_ bytes: [UInt8], at offset: Int) {
        moveGap(to: min(max(0, offset), count))
        ensureGap(bytes.count)
        // Every inserted byte lands below the gap, so its raw index IS its
        // position here and the newline entries can be spliced in directly.
        var added: [Int] = []
        for b in bytes {
            if b == 0x0A { added.append(gapStart) }
            raw[gapStart] = b
            gapStart += 1
        }
        if !added.isEmpty {
            // The caret's own line index is where the run belongs; everything
            // after it is already correct because those entries are above the
            // gap and were never touched.
            let at = lowerBound(ofRaw: added[0])
            newlines.insert(contentsOf: added, at: at)
        }
    }

    private func removeBytes(_ range: Range<Int>) {
        let lo = max(0, range.lowerBound), hi = min(count, range.upperBound)
        guard lo < hi else { return }
        moveGap(to: lo)
        // Swallow the bytes into the gap. They are the suffix side's first
        // (hi - lo) bytes, at raw [gapEnd, gapEnd + n).
        let n = hi - lo
        let from = gapEnd, to = gapEnd + n
        if !newlines.isEmpty {
            let start = lowerBound(ofRaw: from)
            var end = start
            while end < newlines.count && newlines[end] < to { end += 1 }
            if end > start { newlines.removeSubrange(start..<end) }
        }
        gapEnd = to
    }

    /// First index into `newlines` whose value is >= a raw position.
    private func lowerBound(ofRaw r: Int) -> Int {
        var lo = 0, hi = newlines.count
        while lo < hi {
            let mid = (lo + hi) / 2
            if newlines[mid] < r { lo = mid + 1 } else { hi = mid }
        }
        return lo
    }

    /// Moves the gap to a logical position, shifting only the newline entries
    /// that actually crossed it. This is the one operation whose cost scales
    /// with distance, and it happens on a caret *jump*, never on a keystroke.
    private func moveGap(to logical: Int) {
        if logical == gapStart { return }
        let len = gapLength
        if logical < gapStart {
            let d = gapStart - logical
            raw.withUnsafeMutableBufferPointer { p in
                let base = p.baseAddress!
                // memmove, not update(from:): a gap smaller than the distance
                // moved makes source and destination overlap, and
                // UnsafeMutablePointer.update requires that they do not.
                memmove(base + gapEnd - d, base + logical, d)
            }
            // Entries in [logical, gapStart) moved up by the gap length.
            var i = lowerBound(ofRaw: logical)
            while i < newlines.count && newlines[i] < gapStart {
                newlines[i] += len
                i += 1
            }
            gapStart = logical
            gapEnd -= d
        } else {
            let d = logical - gapStart
            raw.withUnsafeMutableBufferPointer { p in
                let base = p.baseAddress!
                memmove(base + gapStart, base + gapEnd, d)
            }
            var i = lowerBound(ofRaw: gapEnd)
            while i < newlines.count && newlines[i] < gapEnd + d {
                newlines[i] -= len
                i += 1
            }
            gapStart += d
            gapEnd += d
        }
    }

    private func ensureGap(_ n: Int) {
        guard gapLength < n else { return }
        let grow = max(n - gapLength, max(Self.minGap, raw.count / 2))
        let oldEnd = gapEnd
        let suffix = raw.count - oldEnd
        raw.append(contentsOf: repeatElement(0, count: grow))
        if suffix > 0 {
            raw.withUnsafeMutableBufferPointer { p in
                let base = p.baseAddress!
                memmove(base + oldEnd + grow, base + oldEnd, suffix)
            }
        }
        // Every newline above the gap moved by exactly the growth.
        var i = lowerBound(ofRaw: oldEnd)
        while i < newlines.count { newlines[i] += grow; i += 1 }
        gapEnd = oldEnd + grow
    }

    // MARK: - Invariants (checked by --bench-text, never in the hot path)

    /// Recomputes the newline index from scratch and compares. The whole design
    /// rests on the incremental index staying identical to the ground truth, so
    /// that equality is asserted rather than believed.
    public func indexMatchesScan() -> Bool {
        var scanned: [Int] = []
        for i in 0..<count where raw[rawIndex(i)] == 0x0A { scanned.append(i) }
        return scanned == newlines.map { logicalIndex($0) }
    }
}

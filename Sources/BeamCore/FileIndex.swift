import Foundation

/// The candidate list behind `⌘O`, and the fuzzy filter over it.
///
/// Beam has no project concept and is not acquiring one: the root is the
/// directory holding the current file, or the process's working directory when
/// there is no file yet. That is enough to open the thing next to the thing you
/// are editing, which is what ⌘O is actually for.
///
/// The scan runs off the main thread the first time the overlay opens — not at
/// launch, which would put a directory walk inside `launch_to_typeable_ms`, and
/// not on the keystroke, which would put it inside
/// `overlay_keystroke_to_commit_p99_ms`. Filtering, which *is* on the keystroke
/// path because there is nowhere else for it, runs over a prebuilt lowercase
/// byte array rather than over Strings.
public final class FileIndex {
    /// Directories that are never worth walking and are always enormous.
    /// Anything starting with `.` is skipped too.
    private static let skipped: Set<String> = [
        "node_modules", "target", "build", "dist", "vendor", "Pods",
        "DerivedData", "__pycache__", "venv", ".venv",
    ]
    /// Hard cap. A finder that walks a home directory forever is a finder that
    /// hangs; 20k paths is far past the point where fuzzy search is the right
    /// interface anyway.
    public static let maxPaths = 20_000

    public private(set) var root: String = ""
    /// Display paths, relative to the root. **Never open one of these** — they
    /// are relative to the scanned directory, not to the process's working
    /// directory, so opening one reads the wrong file or none at all. Use
    /// `absolute(_:)`. Shipped once as `cannot read Commands.swift`.
    public private(set) var paths: [String] = []
    /// Same paths, lowercased UTF-8, for matching without allocating per key.
    private var haystacks: [[UInt8]] = []
    public private(set) var isScanning = false
    public private(set) var didScan = false
    /// True when the walk stopped at `maxPaths` — the status line says so
    /// rather than silently offering a partial list.
    public private(set) var truncated = false

    public init() {}

    /// Walks `root` on the calling thread. Callers put it on a background queue
    /// and hand the result back to main.
    public func scan(root r: String) {
        root = r
        var found: [String] = []
        let fm = FileManager.default
        var stack = [r]
        outer: while let dir = stack.popLast() {
            guard let entries = try? fm.contentsOfDirectory(atPath: dir) else { continue }
            for name in entries.sorted() {
                if name.hasPrefix(".") || Self.skipped.contains(name) { continue }
                let full = (dir as NSString).appendingPathComponent(name)
                var isDir: ObjCBool = false
                guard fm.fileExists(atPath: full, isDirectory: &isDir) else { continue }
                if isDir.boolValue {
                    stack.append(full)
                } else {
                    found.append(String(full.dropFirst(r.count + (r.hasSuffix("/") ? 0 : 1))))
                    if found.count >= Self.maxPaths { truncated = true; break outer }
                }
            }
        }
        found.sort()
        paths = found
        haystacks = found.map { Array($0.lowercased().utf8) }
        didScan = true
    }

    /// The path to actually open, for a display path from `paths`.
    public func absolute(_ relative: String) -> String {
        (root as NSString).appendingPathComponent(relative)
    }

    public func beginScan() { isScanning = true }
    public func endScan() { isScanning = false }

    /// Subsequence fuzzy match, ranked. Returns indices into `paths`.
    ///
    /// Scoring is three rules, in the order people actually think: a match that
    /// starts a path segment beats one in the middle, a run of consecutive
    /// characters beats a scattered one, and a shorter path beats a longer one.
    /// That is enough to put `src/renderer.rs` above `docs/rendering.md` for
    /// "rend", which is the only judgement this has to get right.
    ///
    /// **This runs on the keystroke path**, because there is nowhere else to
    /// put it, so it is written like a hot loop and gated
    /// (`L2.overlay_keystroke_to_commit_p99_ms`). The first version scored every
    /// candidate, sorted the whole array, and used `paths[i].count` as the
    /// tie-break — and `String.count` is O(length), inside a comparator, called
    /// n log n times. It measured **12.3 ms p50 against a 4 ms budget and an
    /// 8 ms gate** on a 9,728-file tree: over the gate on its first run, which
    /// is exactly what the budget was written to catch. What replaced it keeps
    /// only the best `limit` results in one pass — no full sort — and compares
    /// precomputed byte lengths.
    public func filter(_ query: String, limit: Int) -> [Int] {
        let q = Array(query.lowercased().utf8)
        if q.isEmpty { return Array(paths.indices.prefix(limit)) }
        guard limit > 0 else { return [] }

        // A bounded insertion sort over `limit` entries: for a ten-row overlay
        // that is at most ten comparisons per surviving candidate, against
        // n log n for a full sort of thousands.
        var bestScore = [Int](repeating: Int.min, count: limit)
        var bestIndex = [Int](repeating: -1, count: limit)
        var filled = 0

        for (i, hay) in haystacks.enumerated() {
            guard let s = score(q, hay) else { continue }
            if filled == limit && s <= bestScore[filled - 1] { continue }
            var slot = filled < limit ? filled : limit - 1
            while slot > 0, better(s, i, than: bestScore[slot - 1], bestIndex[slot - 1]) {
                bestScore[slot] = bestScore[slot - 1]
                bestIndex[slot] = bestIndex[slot - 1]
                slot -= 1
            }
            bestScore[slot] = s
            bestIndex[slot] = i
            if filled < limit { filled += 1 }
        }
        return Array(bestIndex.prefix(filled))
    }

    /// Higher score wins; equal scores go to the shorter path. The length comes
    /// from the prebuilt byte array, never from `String.count`.
    @inline(__always)
    private func better(_ s: Int, _ i: Int, than otherScore: Int, _ otherIndex: Int) -> Bool {
        if otherIndex < 0 { return true }
        if s != otherScore { return s > otherScore }
        return haystacks[i].count < haystacks[otherIndex].count
    }

    /// How well `q` matches `hay`, or nil if it does not match at all.
    ///
    /// **The match is tried from every path segment, not just from the front.**
    /// A single greedy left-to-right subsequence scan is the obvious
    /// implementation and it has one specific, very visible failure: an early
    /// stray letter eats the query's first character and destroys the run that
    /// follows. Typing `rend` ranked `docs/rendering.md` above
    /// `src/renderer.rs`, because the `r` in `src` matched first and left
    /// `enderer` to be found one character at a time. The unit test that
    /// asserts otherwise had been in the repository the whole time and had
    /// never run — SwiftPM is broken on the dev machine, so `swift test` only
    /// started running when CI did.
    ///
    /// Restarting at each segment boundary fixes it for the price of a handful
    /// of extra passes over a short string: a path has two or three segments,
    /// and the loop stops at the first character that cannot be matched at all.
    /// Measured over the repository tree the whole filter stayed inside its
    /// budget (`overlay_keystroke_to_commit_p99_ms`), which is the row that
    /// decides whether a ranking idea is affordable.
    private func score(_ q: [UInt8], _ hay: [UInt8]) -> Int? {
        var best: Int?
        var start = 0
        while true {
            if let s = greedyScore(q, hay, from: start) {
                if best == nil || s > best! { best = s }
            }
            // The next segment start, if there is one.
            guard let slash = hay[start...].firstIndex(of: 0x2F), slash + 1 < hay.count else { break }
            start = slash + 1
        }
        // **Length breaks ties, finely.** Match quality is scaled up so it
        // always dominates, and the raw length is subtracted at unit weight —
        // so between two equally good matches the shorter path wins, which is
        // what "renderer.rs before rendering.md" actually means. The old
        // `- count / 8` was too coarse to separate them at all.
        return best.map { $0 * 8 - hay.count }
    }

    private func greedyScore(_ q: [UInt8], _ hay: [UInt8], from start: Int) -> Int? {
        var qi = 0, total = 0, run = 0
        var i = start
        while i < hay.count && qi < q.count {
            if hay[i] == q[qi] {
                run += 1
                total += run * 2
                // A match right after a separator is what a person meant.
                if i == 0 || hay[i - 1] == 0x2F || hay[i - 1] == 0x5F || hay[i - 1] == 0x2D
                    || hay[i - 1] == 0x2E { total += 8 }
                qi += 1
            } else {
                run = 0
            }
            i += 1
        }
        return qi == q.count ? total : nil
    }
}

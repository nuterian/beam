import Foundation

/// Scalar → atlas slot, with on-demand rasterization and LRU eviction.
///
/// Through Phase 2 the atlas was exactly printable ASCII, and `InstanceWriter`
/// dropped anything outside it *while still advancing the column* — so a single
/// `é` in a comment slid the rest of the line one cell left and every column
/// arithmetic downstream (the caret, a click, a selection) was quietly wrong.
/// Beam could not open a real file without that being a corruption bug, so this
/// is one of the two correctness cliffs the file view had to cross (PLAN.md
/// §5.3; the other is the text model itself).
///
/// **The ASCII path is unchanged and does not come through here.** Callers test
/// `32...126` inline and index the atlas directly; a full screen of code is
/// ~3500 characters, and putting a dictionary lookup on each of them would have
/// cost more than the entire measured commit path (0.34 ms p50). This class is
/// the *miss* path: it is consulted for the characters ASCII does not cover,
/// which on real source is a handful per screen and usually none.
///
/// **Single-threaded by construction.** Instance building is the only caller —
/// the main thread inside the window, the only thread in `--screenshot` and
/// `--dump-scene` — so there is no lock and there must not be a second caller.
final class GlyphCache {
    static let shared = GlyphCache()

    /// Set once a Metal atlas exists. `--dump-scene` has no GPU context at all,
    /// so the cache still hands out slots there and simply cannot fill them;
    /// the dump reverse-maps slot → scalar through `scalar(forSlot:)` and prints
    /// the character, which is exactly what a structural view should show.
    weak var atlas: GlyphAtlas?

    private let dynamicCount = GlyphAtlas.atlasCols * GlyphAtlas.atlasRows - GlyphAtlas.firstDynamicSlot
    private var slotForScalar: [UInt32: UInt16] = [:]
    private var scalarForSlot: [UInt32]
    private var lastUsed: [UInt64]
    private var frame: UInt64 = 1
    /// Counters for the bench: how often the cache had to rasterize, and how
    /// often it ran out of slots inside one frame.
    private(set) var misses = 0
    private(set) var overflows = 0

    private init() {
        scalarForSlot = [UInt32](repeating: 0, count: dynamicCount)
        lastUsed = [UInt64](repeating: 0, count: dynamicCount)
        slotForScalar.reserveCapacity(dynamicCount * 2)
    }

    /// Called once per frame, before any instance is written. Eviction is
    /// scoped by it: a slot touched during the frame being built is never
    /// reused inside that frame, so a glyph can never be replaced out from
    /// under an instance that already points at it.
    func beginFrame() { frame &+= 1 }

    /// The glyph slot for a scalar the ASCII fast path did not handle.
    ///
    /// Never fails: an unmappable scalar, a font with no glyph for it, or an
    /// atlas with every dynamic slot already used in this frame all resolve to
    /// the replacement box. Drawing *something* in the cell is the invariant —
    /// the bug being fixed was a character that occupied no cell.
    func glyph(forNonASCII scalar: UnicodeScalar) -> UInt16 {
        let v = scalar.value
        // Control characters have no business on the grid; the text model
        // expands tabs and splits on newlines before it gets here, so anything
        // left is genuinely unprintable.
        if v < 32 || (v >= 0x7F && v <= 0x9F) { return GlyphAtlas.replacementGlyphIndex }

        if let slot = slotForScalar[v] {
            lastUsed[Int(slot) - GlyphAtlas.firstDynamicSlot] = frame
            return slot
        }

        guard let index = claimSlot() else {
            overflows += 1
            return GlyphAtlas.replacementGlyphIndex
        }
        let slot = UInt16(GlyphAtlas.firstDynamicSlot + index)
        misses += 1
        if let atlas, !atlas.rasterize(scalar, into: Int(slot)) {
            // This machine has no glyph for it in any installed face. Remember
            // the verdict so the failed CoreText cascade is paid once, not once
            // per frame for as long as the character is on screen.
            release(index)
            slotForScalar[v] = GlyphAtlas.replacementGlyphIndex
            return GlyphAtlas.replacementGlyphIndex
        }
        if scalarForSlot[index] != 0 { slotForScalar.removeValue(forKey: scalarForSlot[index]) }
        scalarForSlot[index] = v
        lastUsed[index] = frame
        slotForScalar[v] = slot
        return slot
    }

    /// Least-recently-used dynamic slot that this frame has not already drawn
    /// with, or nil when every one of them is in use right now — 156 distinct
    /// non-ASCII characters on one screen, which Latin source never reaches and
    /// a screen of CJK does. The overflow is counted, not hidden.
    private func claimSlot() -> Int? {
        var best = -1
        var bestStamp = UInt64.max
        for i in 0..<dynamicCount {
            if scalarForSlot[i] == 0 { return i }      // never used: take it
            if lastUsed[i] < frame && lastUsed[i] < bestStamp {
                bestStamp = lastUsed[i]
                best = i
            }
        }
        return best >= 0 ? best : nil
    }

    private func release(_ index: Int) {
        if scalarForSlot[index] != 0 { slotForScalar.removeValue(forKey: scalarForSlot[index]) }
        scalarForSlot[index] = 0
        lastUsed[index] = 0
    }

    /// Inverse map, for `--dump-scene`: the character a dynamic slot is
    /// standing for. Structure is reviewable in a diff only if the dump prints
    /// the character rather than the slot number.
    func scalar(forSlot slot: UInt16) -> UnicodeScalar? {
        let i = Int(slot) - GlyphAtlas.firstDynamicSlot
        guard i >= 0, i < dynamicCount, scalarForSlot[i] != 0 else { return nil }
        return UnicodeScalar(scalarForSlot[i])
    }

    /// The glyph for any scalar — ASCII fast path included. Correctness-first
    /// entry point for callers that are not the hot loop.
    @inline(__always)
    func glyph(for scalar: UnicodeScalar) -> UInt16 {
        let v = scalar.value
        if v >= 32 && v < 127 { return UInt16(v - 32) }
        return glyph(forNonASCII: scalar)
    }
}

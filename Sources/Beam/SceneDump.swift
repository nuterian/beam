import Foundation
import BeamCore

/// `--dump-scene` renders each surface to ASCII on stdout, with no Metal, no
/// window and no screen.
///
/// Beam's entire UI is instance data — (col, row, glyph, ink) — so the layout
/// can be inspected exactly as the GPU will receive it. On a machine whose
/// display cycles (and in CI, which has no display at all) this is the only way
/// to look at the product's *structure*; it also makes layout reviewable in a
/// diff, which a screenshot never is. `--screenshot` is the companion that
/// shows the pixels; both draw the same states from `SceneStates` (PLAN.md §5.2).
enum SceneDump {
    static func run() -> Never {
        for state in SceneStates.all() {
            dump(state)
        }
        exit(0)
    }

    /// Runs a Scene builder over a plain buffer and prints what it wrote.
    private static func dump(_ state: SceneStates.State) {
        let (cols, rows) = SceneStates.referenceGrid
        let cap = Renderer.maxInstances
        let buf = UnsafeMutablePointer<Renderer.Instance>.allocate(capacity: cap)
        defer { buf.deallocate() }
        var w = InstanceWriter(buf, cap: cap)
        // A time far past every fade, so the dump shows the settled frame.
        let m = GlyphAtlas.Metrics(pointSize: 14, scale: 2)
        _ = state.build(&w, monotonicNow() + 10, cols, rows, cols * m.cellWidthPx)

        var grid = [[Character]](repeating: [Character](repeating: " ", count: cols), count: rows)
        for i in 0..<w.count {
            let inst = buf[i]
            let col = Int(inst.col), row = Int(inst.row)
            guard row >= 0, row < rows, col >= 0, col < cols else { continue }
            if let ch = character(for: inst.glyph, ink: Renderer.Ink(rawValue: inst.color & 0xFF) ?? .fg) {
                grid[row][col] = ch
            }
        }

        print("\n\u{001B}[1m\(state.title)\u{001B}[0m")
        print("+" + String(repeating: "-", count: cols) + "+")
        for line in grid {
            print("|" + String(line).replacingOccurrences(of: "\\s+$", with: "", options: .regularExpression)
                    .padding(toLength: cols, withPad: " ", startingAt: 0) + "|")
        }
        print("+" + String(repeating: "-", count: cols) + "+")
    }

    /// Glyph plus ink, because the block glyph is now four different things.
    ///
    /// Filled surfaces are what most separates a GUI from a TUI (PLAN.md §5.3),
    /// and they are all the same solid-block glyph — so a dump that printed
    /// them all as `#` would replace the entire editor with a wall. What a
    /// *structural* view wants is: the extent of a panel and a selection, and
    /// nothing at all for a lit row or a scrim, which are lighting rather than
    /// structure. Text is written after its fill, so it survives either way.
    /// nil means "this instance changes nothing here" — the scrim dims the
    /// document, it does not erase it, and a structural view that blanked
    /// everything behind an overlay would be describing a different app.
    private static func character(for glyph: UInt16, ink: Renderer.Ink) -> Character? {
        if glyph == GlyphAtlas.blockGlyphIndex {
            switch ink {
            case .scrim: return nil
            case .activeLine: return " "
            case .surface: return "."
            case .selection: return "~"
            case .hover: return "-"
            case .edge: return "|"
            default: return "#"     // a caret, or a join-code pixel
            }
        }
        switch glyph {
        case GlyphAtlas.blockGlyphIndex: return "#"
        case GlyphAtlas.dotGlyphIndex: return "."
        case GlyphAtlas.ruleGlyphIndex: return "-"
        case GlyphAtlas.barGlyphIndex: return "|"
        case GlyphAtlas.chipGlyphIndex: return "\u{25AA}"
        case GlyphAtlas.replacementGlyphIndex: return "\u{FFFD}"
        // A rail icon is two cells wide; both halves print the same letter, so
        // the rail is one glance in a diff rather than two mystery slots.
        case GlyphAtlas.filesIconIndex, GlyphAtlas.filesIconIndex + 1: return "f"
        case GlyphAtlas.peersIconIndex, GlyphAtlas.peersIconIndex + 1: return "p"
        case GlyphAtlas.caretGlyphIndex: return "|"
        case GlyphAtlas.dividerHIndex: return "\u{2500}"
        case GlyphAtlas.dividerVIndex: return "\u{2502}"
        default:
            if glyph < 95 { return Character(UnicodeScalar(UInt8(glyph) + 32)) }
            // A demand-rasterized slot: print the character it stands for, not
            // its slot number. The dump is only reviewable in a diff if a file
            // with an accent in it reads as that accent.
            if let s = GlyphCache.shared.scalar(forSlot: glyph) { return Character(s) }
            return "?" 
        }
    }
}

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
        state.build(&w, monotonicNow() + 10, cols, rows)

        var grid = [[Character]](repeating: [Character](repeating: " ", count: cols), count: rows)
        for i in 0..<w.count {
            let inst = buf[i]
            let col = Int(inst.col), row = Int(inst.row)
            guard row >= 0, row < rows, col >= 0, col < cols else { continue }
            grid[row][col] = character(for: inst.glyph)
        }

        print("\n\u{001B}[1m\(state.title)\u{001B}[0m")
        print("+" + String(repeating: "-", count: cols) + "+")
        for line in grid {
            print("|" + String(line).replacingOccurrences(of: "\\s+$", with: "", options: .regularExpression)
                    .padding(toLength: cols, withPad: " ", startingAt: 0) + "|")
        }
        print("+" + String(repeating: "-", count: cols) + "+")
    }

    private static func character(for glyph: UInt16) -> Character {
        switch glyph {
        case GlyphAtlas.blockGlyphIndex: return "#"
        case GlyphAtlas.dotGlyphIndex: return "."
        case GlyphAtlas.ruleGlyphIndex: return "-"
        case GlyphAtlas.barGlyphIndex: return "|"
        case GlyphAtlas.chipGlyphIndex: return "\u{25AA}"
        default:
            guard glyph < 95 else { return "?" }
            return Character(UnicodeScalar(UInt8(glyph) + 32))
        }
    }
}

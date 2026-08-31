import Foundation
import Network
import BeamCore

/// `--dump-scene` renders each surface to ASCII on stdout, with no Metal, no
/// window and no screen.
///
/// Beam's entire UI is instance data — (col, row, glyph, ink) — so the layout
/// can be inspected exactly as the GPU will receive it. On a machine whose
/// display cycles (and in CI, which has no display at all) this is the only way
/// to look at the product; it also makes the roster's layout reviewable in a
/// diff, which a screenshot never is.
enum SceneDump {
    static func run() -> Never {
        let cols = 78, rows = 20

        let alone = AppModel(localName: "studio-mbp-4021")
        dump("roster — alone on the network (a designed state, not an empty list)",
             cols: cols, rows: rows) { w, now in
            Scene.roster(alone, into: &w, now: now, cols: cols)
        }

        let denied = AppModel(localName: "studio-mbp-4021")
        denied.debugSetPresence(.localNetworkDenied)
        dump("roster — Local Network permission denied (never a silent empty list)",
             cols: cols, rows: rows) { w, now in
            Scene.roster(denied, into: &w, now: now, cols: cols)
        }

        let peopled = AppModel(localName: "studio-mbp-4021")
        peopled.debugSetPeers(["marlowe-air-1180", "atlas-mini-9042", "kestrel-studio-3311"])
        dump("roster — three peers nearby", cols: cols, rows: rows) { w, now in
            Scene.roster(peopled, into: &w, now: now, cols: cols)
        }

        let pairing = AppModel(localName: "studio-mbp-4021")
        pairing.debugSetPeers(["marlowe-air-1180"])
        pairing.debugSetPairing(host: true)
        dump("join code — host side (guest side reads 'waiting for ...')",
             cols: cols, rows: 22) { w, now in
            Scene.pairing(pairing, sas: "472913", into: &w, now: now)
        }

        let doc = "fn render(&mut self) {\nlet frame = self.next();\n}"

        let typing = AppModel(localName: "studio-mbp-4021")
        typing.debugSetEditing(text: doc, peer: "marlowe-air-1180", peerCursor: (24, 1))
        dump("editor — their caret at the end of their line, so their name trails it",
             cols: cols, rows: 12) { w, now in
            Scene.editor(typing, into: &w, now: now, cols: cols, rows: 10)
            Scene.hud(into: &w, text: "p50 25.8  p99 33.8 ms   marlowe-air 0.4 ms",
                      ink: .green, cols: cols, rows: 11)
        }

        let inside = AppModel(localName: "studio-mbp-4021")
        inside.debugSetEditing(text: doc, peer: "marlowe-air-1180", peerCursor: (12, 1))
        dump("editor — their caret inside text: the label is suppressed rather than drawn over code",
             cols: cols, rows: 12) { w, now in
            Scene.editor(inside, into: &w, now: now, cols: cols, rows: 10)
            Scene.hud(into: &w, text: "p50 25.8  p99 33.8 ms   marlowe-air 0.4 ms",
                      ink: .green, cols: cols, rows: 11)
        }
        exit(0)
    }

    /// Runs a Scene builder over a plain buffer and prints what it wrote.
    private static func dump(_ title: String, cols: Int, rows: Int,
                             _ build: (inout InstanceWriter, Double) -> Void) {
        let cap = Renderer.maxInstances
        let buf = UnsafeMutablePointer<Renderer.Instance>.allocate(capacity: cap)
        defer { buf.deallocate() }
        var w = InstanceWriter(buf, cap: cap)
        // A time far past every fade, so the dump shows the settled frame.
        build(&w, monotonicNow() + 10)

        var grid = [[Character]](repeating: [Character](repeating: " ", count: cols), count: rows)
        for i in 0..<w.count {
            let inst = buf[i]
            let col = Int(inst.col), row = Int(inst.row)
            guard row >= 0, row < rows, col >= 0, col < cols else { continue }
            grid[row][col] = character(for: inst.glyph)
        }

        print("\n\u{001B}[1m\(title)\u{001B}[0m")
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
        default:
            guard glyph < 95 else { return "?" }
            return Character(UnicodeScalar(UInt8(glyph) + 32))
        }
    }
}

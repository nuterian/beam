import Foundation
import BeamCore

/// The seeded states every visual tool shows. `--dump-scene` renders them to
/// ASCII and `--screenshot` renders them to PNG, so the structural view and the
/// pixel view are the same states by construction and cannot drift apart
/// (PLAN.md §5.2).
///
/// The document these states type is deliberately real code with descenders,
/// punctuation and mixed case in it — a lorem-ipsum grid hides exactly the
/// typography problems this exists to find.
enum SceneStates {
    struct State {
        /// `--surface` name and PNG filename.
        let key: String
        let title: String
        let build: (inout InstanceWriter, Double, Int, Int) -> Void
    }

    /// The grid the shipping window produces: AppDelegate's 980x640 content at
    /// 2x, through the same cell metrics and the same arithmetic GridView
    /// applies to `drawableSize`. Both `--dump-scene` and `--screenshot` lay
    /// out on this, so the ASCII view and the PNGs are the same layout rather
    /// than two approximations of it. Needs CoreText only — no Metal, no
    /// window, no display.
    static let referenceGrid: (cols: Int, rows: Int) = {
        let m = GlyphAtlas.Metrics(pointSize: 14, scale: 2)
        return (m.cols(forWidthPx: 1960), m.rows(forHeightPx: 1280))
    }()

    /// The HUD as GridView builds it — labels faint, values coloured, units
    /// quiet — so the dump and the screenshot show the real thing.
    static func hudSample(peer: String, ink: Int) -> [Scene.Span] {
        [Scene.Span("p50 ", .faint), Scene.Span("25.8", .green),
         Scene.Span("  p99 ", .faint), Scene.Span("33.8", .green),
         Scene.Span(" ms", .faint), Scene.Span("   ", .faint),
         Scene.Span(glyph: GlyphAtlas.chipGlyphIndex, .peer(ink)),
         Scene.Span(" ", .faint), Scene.Span(peer, .dim),
         Scene.Span(" 0.4", .fg), Scene.Span(" ms", .faint)]
    }
    private static let doc = "fn render(&mut self) {\nlet frame = self.next();\n}"

    static func all() -> [State] {
        let alone = AppModel(localName: "studio-mbp-4021")

        let denied = AppModel(localName: "studio-mbp-4021")
        denied.debugSetPresence(.localNetworkDenied)

        let peopled = AppModel(localName: "studio-mbp-4021")
        peopled.debugSetPeers(["marlowe-air-1180", "atlas-mini-9042", "kestrel-studio-3311"])

        let pairing = AppModel(localName: "studio-mbp-4021")
        pairing.debugSetPeers(["marlowe-air-1180"])
        pairing.debugSetPairing(host: true)

        let typing = AppModel(localName: "studio-mbp-4021")
        typing.debugSetEditing(text: doc, peer: "marlowe-air-1180", peerCursor: (24, 1))

        let inside = AppModel(localName: "studio-mbp-4021")
        inside.debugSetEditing(text: doc, peer: "marlowe-air-1180", peerCursor: (12, 1))

        return [
            State(key: "roster", title: "roster — three peers nearby",) { w, now, cols, rows in
                Scene.roster(peopled, into: &w, now: now, cols: cols, rows: rows)
            },
            State(key: "roster-alone",
                  title: "roster — alone on the network (a designed state, not an empty list)",) { w, now, cols, rows in
                Scene.roster(alone, into: &w, now: now, cols: cols, rows: rows)
            },
            State(key: "denied",
                  title: "roster — Local Network permission denied (never a silent empty list)",) { w, now, cols, rows in
                Scene.roster(denied, into: &w, now: now, cols: cols, rows: rows)
            },
            State(key: "pairing",
                  title: "join code — host side (guest side reads 'waiting for ...')",) { w, now, cols, rows in
                Scene.pairing(pairing, sas: "472913", into: &w, now: now, cols: cols, rows: rows)
            },
            // Editor states call editor() and hud() with the same extent
            // GridView does, so the dump and the screenshot show the frame the
            // window would have built, not an approximation of it.
            State(key: "editor",
                  title: "editor — their caret at the end of their line, so their name trails it",) { w, now, cols, rows in
                Scene.editor(typing, into: &w, now: now, cols: cols, rows: rows)
                Scene.hud(into: &w, spans: hudSample(peer: "marlowe-air", ink: Peer.ink(of: "marlowe-air-1180")),
                          cols: cols, rows: rows)
            },
            State(key: "editor-inline",
                  title: "editor — their caret inside text: the label is suppressed rather than drawn over code",) { w, now, cols, rows in
                Scene.editor(inside, into: &w, now: now, cols: cols, rows: rows)
                Scene.hud(into: &w, spans: hudSample(peer: "marlowe-air", ink: Peer.ink(of: "marlowe-air-1180")),
                          cols: cols, rows: rows)
            },
        ]
    }
}

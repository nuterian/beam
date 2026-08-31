import Foundation
import BeamCore

/// The seeded states every visual tool shows. `--dump-scene` renders them to
/// ASCII and `--screenshot` renders them to PNG through the same
/// `Scene.frame(...)` the window calls, so the structural view, the pixel view
/// and the shipping layout are one thing rather than three that agree
/// (PLAN.md §5.2, §5.3).
///
/// The document these states carry is deliberately real code — descenders,
/// punctuation, mixed case, a tab, a multi-byte character and a block comment.
/// A lorem-ipsum grid hides exactly the typography and correctness problems
/// this exists to find, and the accented character in it is the one that used
/// to slide every column after it one cell left.
enum SceneStates {
    struct State {
        /// `--surface` name and PNG filename.
        let key: String
        let title: String
        /// Writes the frame and returns its planes, exactly as the window does.
        let build: (inout InstanceWriter, Double, Int, Int, Int) -> [Renderer.Plane]
    }

    /// The grid the shipping window produces: AppDelegate's 980x640 content at
    /// 2x, through the same cell metrics and the same arithmetic GridView
    /// applies to `drawableSize`.
    static let referenceGrid: (cols: Int, rows: Int) = {
        let m = GlyphAtlas.Metrics(pointSize: 14, scale: 2)
        return (m.cols(forWidthPx: 1960), m.rows(forHeightPx: 1280))
    }()

    /// The status line's latency run, as GridView builds it — labels faint,
    /// values coloured, units quiet.
    static func hudSample(peer: String? = nil, ink: Int = 0) -> [Scene.Span] {
        var spans: [Scene.Span] = [
            Scene.Span("p50 ", .faint), Scene.Span("25.8", .green),
            Scene.Span("  p99 ", .faint), Scene.Span("33.7", .green),
            Scene.Span(" ms", .faint),
        ]
        if let peer {
            spans = [Scene.Span(glyph: GlyphAtlas.chipGlyphIndex, .peer(ink)),
                     Scene.Span(" ", .faint), Scene.Span(peer, .dim),
                     Scene.Span(" 0.4", .fg), Scene.Span(" ms", .faint),
                     Scene.Span("   ", .faint)] + spans
        }
        return spans
    }

    private static let doc = """
    use std::sync::Arc;

    /// Encode one frame — the hot path.
    pub struct Renderer {
    \tdevice: Device,
    \tatlas: GlyphAtlas,
    }

    impl Renderer {
        pub fn render(&mut self, n: usize) -> Result<()> {
            let frame = self.next_frame()?;
            for i in 0..n {
                frame.push(self.atlas.glyph(i), 0xFF);
            }
            /* the caret's line is lit, and this
               block comment carries its state across */
            Ok(())
        }
    }
    """

    private static func seeded(peers: [String] = [], file: String = "renderer.rs",
                              tabs: [String] = ["main.rs", "render_loop.rs"]) -> AppModel {
        let app = AppModel(localName: "studio-mbp-4021")
        app.debugOpen(text: doc, name: file)
        app.debugAddTabs(tabs, modified: ["render_loop.rs"])
        if !peers.isEmpty { app.debugSetPeers(peers) }
        return app
    }

    static func all() -> [State] {
        // The launch state: an empty untitled buffer, alone on the network.
        let launch = AppModel(localName: "studio-mbp-4021")

        let editing = seeded(peers: ["marlowe-air-1180", "atlas-mini-9042"])
        editing.doc.caret = editing.doc.offset(line: 10, cellColumn: 12)
        editing.doc.anchor = editing.doc.offset(line: 10, cellColumn: 33)

        let alone = seeded()
        alone.doc.caret = alone.doc.offset(line: 4, cellColumn: 8)

        let shared = seeded(peers: ["marlowe-air-1180"])
        shared.doc.caret = shared.doc.offset(line: 9, cellColumn: 16)
        shared.debugSetRemote(offset: shared.doc.offset(line: 11, cellColumn: 33),
                              peer: "marlowe-air-1180")

        let opening = seeded(peers: ["marlowe-air-1180"])
        opening.debugSetOverlay(.files, query: "rend",
                                files: ["src/renderer.rs", "src/render_loop.rs",
                                        "docs/rendering.md", "tests/render_test.rs"],
                                selection: 0)

        let nearby = seeded(peers: ["marlowe-air-1180", "atlas-mini-9042", "kestrel-studio-3311"])
        nearby.debugSetOverlay(.peers, query: "", files: [], selection: 0)

        let noPeers = seeded()
        noPeers.debugSetOverlay(.peers, query: "", files: [], selection: 0)

        let denied = seeded()
        denied.debugSetPresence(.localNetworkDenied)
        denied.debugSetOverlay(.peers, query: "", files: [], selection: 0)

        let palette = seeded(peers: ["marlowe-air-1180"])
        palette.debugSetOverlay(.commands, query: "", files: [], selection: 0)

        let pairing = seeded(peers: ["marlowe-air-1180"])
        pairing.debugSetPairing(host: true)

        func state(_ key: String, _ title: String, _ app: AppModel,
                   _ hud: [Scene.Span] = hudSample()) -> State {
            State(key: key, title: title) { w, now, cols, rows, widthPx in
                app.cellWidthPx = GlyphAtlas.Metrics(pointSize: 14, scale: 2).cellWidthPx
                app.cellHeightPx = GlyphAtlas.Metrics(pointSize: 14, scale: 2).cellHeightPx
                return Scene.frame(app, into: &w, now: now, cols: cols, rows: rows,
                                   widthPx: widthPx, hud: hud)
            }
        }

        return [
            state("editor", "editor — tabs in the traffic-light band, the rail on the left, a selection, the caret's line lit", editing),
            state("launch", "launch — an empty untitled buffer, alone on the network (there is no launch SCREEN any more)", launch),
            state("editor-alone", "editor — a file open with nobody nearby: the status line carries only the instrument", alone),
            state("editor-shared", "editor — in a session: their caret in their colour, their name trailing it, their RTT on the line",
                  shared, hudSample(peer: "marlowe-air", ink: Peer.ink(of: "marlowe-air-1180"))),
            state("palette", "⇧⌘P — every command Beam has, from the same table the menu bar is built from", palette),
            state("open", "⌘O — the open overlay over a scrimmed document: selection on the first row, hover on none", opening),
            state("peers", "⌘K — the same overlay listing peers; a number joins, which is §5.1's gesture one layer in", nearby),
            state("peers-alone", "⌘K — alone on the network: a designed state with its own words, not a blank list", noPeers),
            state("denied", "⌘K — Local Network permission denied; the status line says so in red too, never a silent empty list", denied),
            state("pairing", "join code — host side (the guest side reads 'waiting for ...')", pairing),
        ]
    }
}

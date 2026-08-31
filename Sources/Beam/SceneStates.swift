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
        let build: (inout InstanceWriter, Double, Int, Int, Int, Int) -> [Renderer.Plane]
        /// Animation phases to render this state at. A screenshot is normally
        /// the *settled* frame — every phase at rest — but a hover state has
        /// nothing to look at when it is at rest, so a state may pin the slots
        /// it is about (PLAN.md §5.6).
        var phases: [Renderer.Ink: Float] = [:]
    }

    /// The point size the seeded states lay themselves out at.
    ///
    /// **It is a var because `--screenshot --point-size` exists**, and the
    /// first thing that flag did was catch this: the states published
    /// `Zoom.defaultPointSize` cell metrics into the model while the renderer
    /// drew at 24 pt, so the scroll arithmetic and the viewport row count
    /// belonged to an 18x36 cell and the glyphs to a 30x60 one. The document
    /// stopped eight lines short of its own viewport. Exactly the drift the
    /// point size being owned in one place is meant to prevent, one level up in
    /// the tools rather than in the product.
    static var pointSize = Zoom.defaultPointSize

    /// The backing scale the seeded states publish into the model.
    ///
    /// **It has to be the scale the renderer is about to draw with.** §5.7
    /// caught this exact drift once already with `--point-size`: the states
    /// published default cell metrics while the renderer drew at another size,
    /// so the scroll arithmetic belonged to one cell and the glyphs to another
    /// and the document stopped short of its own viewport. A hardcoded 2 here
    /// would reintroduce it the moment `--scale` was used.
    static var scale: CGFloat = 2

    /// The grid the shipping window produces: AppDelegate's 980x640 content at
    /// 2x, through the same cell metrics and the same arithmetic GridView
    /// applies to `drawableSize`.
    static let referenceGrid: (cols: Int, rows: Int) = {
        let m = GlyphAtlas.Metrics(pointSize: Zoom.defaultPointSize, scale: 2)
        return (m.cols(forWidthPx: 1960), m.rows(forHeightPx: 1280))
    }()

    /// The status line's latency run, as GridView builds it — labels faint,
    /// values coloured, units quiet.
    static func hudSample(peer: String? = nil, ink: Int = 0) -> [Scene.Span] {
        var spans: [Scene.Span] = [
            Scene.Span(glyph: GlyphAtlas.boltGlyphIndex, .green),
            Scene.Span(" ", .faint), Scene.Span("25.8", .green),
            Scene.Span(" · ", .faint), Scene.Span("33.7", .green),
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

    /// The seeded document. **Deliberately longer than the viewport**, so
    /// every screenshot shows a full screen of code with the scroll indicator
    /// on it rather than a third of a screen over empty ground — a review
    /// surface that is mostly nothing hides exactly the density and typography
    /// questions §5.2 built these tools to answer. Real code, with descenders,
    /// punctuation, mixed case, a tab, a multi-byte character and a block
    /// comment whose carry state the lexer has to get right.
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

        /// A glyph the atlas does not have is rasterized on demand and
        /// evicted at the end of the frame that stopped needing it.
        fn glyph_or_miss(&mut self, c: char) -> Slot {
            match self.atlas.slot(c) {
                Some(slot) => slot,
                None => self.cache.rasterize(c, self.cell),
            }
        }

        pub fn present(&mut self, layer: &Layer) -> Result<()> {
            let drawable = layer.next_drawable()?;   // may be None while occluded
            let pass = self.encoder(&drawable, 2);   // two planes: document, chrome
            pass.set_scissor(self.viewport);
            pass.draw_instanced(0..self.instances.len(), 1);
            pass.end();
            self.commit(drawable, |presented_at| {
                self.recorder.presented(presented_at);   // NEVER a mean — p50/p99
            })
        }
    }

    #[cfg(test)]
    mod tests {
        use super::*;

        #[test]
        fn accented_scalars_advance_one_cell() {
            assert_eq!(columns("café — naïve"), 12);
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

        let hoverTab = seeded(peers: ["marlowe-air-1180", "atlas-mini-9042"])
        hoverTab.hover = .tab(2)

        let hoverRail = seeded(peers: ["marlowe-air-1180", "atlas-mini-9042"])
        hoverRail.hover = .rail(0)

        let palette = seeded(peers: ["marlowe-air-1180"])
        palette.debugSetOverlay(.commands, query: "", files: [], selection: 0)

        // §5.7's two status-line pickers. They are the same overlay mechanism
        // as the other three, which is the whole reason a status segment could
        // become a control without adding chrome — and they are seeded here so
        // the ASCII dump and the pixels both show them, per §5.2's rule that a
        // surface the tools cannot draw is a surface nobody reviews.
        let language = seeded(peers: ["marlowe-air-1180"])
        language.debugSetOverlay(.language, query: "", files: [], selection: 7)

        let indent = seeded(peers: ["marlowe-air-1180"])
        indent.debugSetOverlay(.indent, query: "", files: [], selection: 4)

        // §5.8's two data-loss guards. Both are drawn in the grid rather than
        // in an AppKit sheet, so both are surfaces the tools must be able to
        // show — a designed state nobody can review is a designed state that
        // rots.
        let closing = seeded(peers: ["marlowe-air-1180"])
        closing.doc.debugMarkModified()
        closing.confirm("save changes to renderer.rs before closing?", choices: [
            ("save", {}), ("discard changes", {}),
        ])

        let conflict = seeded(peers: ["marlowe-air-1180"])
        conflict.doc.debugMarkModified()
        conflict.doc.hasDiskConflict = true
        conflict.doc.caret = conflict.doc.offset(line: 9, cellColumn: 16)

        // Find, with the query row on the status line and every match on
        // screen filled — the surface §5.8 added, and the one that has to be
        // reviewable by eye because its whole job is where the eye goes.
        let finding = seeded(peers: ["marlowe-air-1180"])
        finding.startFind()
        finding.findType("frame")

        let pairing = seeded(peers: ["marlowe-air-1180"])
        pairing.debugSetPairing(host: true)

        func state(_ key: String, _ title: String, _ app: AppModel,
                   _ hud: [Scene.Span] = hudSample(),
                   phases: [Renderer.Ink: Float] = [:]) -> State {
            State(key: key, title: title, build: { w, now, cols, rows, widthPx, heightPx in
                let m = GlyphAtlas.Metrics(pointSize: pointSize, scale: scale)
                app.cellWidthPx = m.cellWidthPx
                app.cellHeightPx = m.cellHeightPx
                app.originXPx = m.originX(forWidthPx: widthPx)
                app.originYPx = m.originY(forHeightPx: heightPx)
                return Scene.frame(app, into: &w, now: now, cols: cols, rows: rows,
                                   widthPx: widthPx, hud: hud)
            }, phases: phases)
        }

        return [
            state("editor", "editor — tabs in the traffic-light band, the rail on the left, a selection, the caret's line lit", editing),
            state("launch", "launch — an empty untitled buffer, alone on the network (there is no launch SCREEN any more)", launch),
            state("editor-alone", "editor — a file open with nobody nearby: the status line carries only the instrument", alone),
            state("editor-shared", "editor — in a session: their caret in their colour, their name trailing it, their RTT on the line",
                  shared, hudSample(peer: "marlowe-air", ink: Peer.ink(of: "marlowe-air-1180"))),
            state("hover-tab", "hover — the pointer over an inactive tab: the tile fades in AND the label warms up",
                  hoverTab, hudSample(), phases: [.hover: 1, .hoverText: 1]),
            state("hover-rail", "hover — the pointer over a rail icon: the same two things, on a square tile",
                  hoverRail, hudSample(), phases: [.hover: 1, .hoverText: 1]),
            state("palette", "⇧⌘P — every command Beam has, from the same table the menu bar is built from", palette),
            state("language", "the status line's language segment, clicked — the same list the lexer is built from", language),
            state("indent", "the status line's indent segment, clicked — tabs or spaces, and how wide", indent),
            state("open", "⌘O — the open overlay over a scrimmed document: selection on the first row, hover on none", opening),
            state("peers", "⌘K — the same overlay listing peers; a number joins, which is §5.1's gesture one layer in", nearby),
            state("peers-alone", "⌘K — alone on the network: a designed state with its own words, not a blank list", noPeers),
            state("denied", "⌘K — Local Network permission denied; the status line says so in red too, never a silent empty list", denied),
            state("find", "⌘F — the query on the status line, every visible match filled, the current one selected: no bar, no panel, the document never covered", finding),
            state("closing", "⌘W with unsaved changes — a confirmation is a question and two rows in the overlay Beam already has, never a sheet", closing),
            state("conflict", "the file changed on disk while it had unsaved edits: the status line says so in red, and ⌘S asks", conflict),
            state("pairing", "join code — host side (the guest side reads 'waiting for ...')", pairing),
        ]
    }
}

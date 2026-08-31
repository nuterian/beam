import AppKit
import CoreText
import CoreGraphics
import Metal

/// Rasterizes printable ASCII (32...126) plus a small set of hand-drawn shape
/// glyphs into one grayscale Metal texture, laid out as a fixed 16x7 grid of
/// equal cells so the shader derives UVs from the glyph index alone. CoreText
/// shapes and rasterizes; the GPU only samples — the Zed/GPU-terminal approach
/// (PLAN.md §2). All metrics are in device pixels.
///
/// Beam draws its entire UI from this atlas — the document, the gutter, the
/// overlays, the join code, the carets and the status line.
/// "No AppKit controls" is only affordable because adding a UI element means
/// adding a glyph here, not adding a view.
///
/// **Every metric here is a whole device pixel, deliberately** (PLAN.md §5.2).
/// A grid is the one layout where fractional metrics are visible as blur: a
/// fractional baseline softens every horizontal stem, and a fractional cell
/// origin makes the shader sample across an atlas cell boundary — which showed
/// up as a 1-pixel dark seam cutting through the join code's block digits, the
/// single most-looked-at pixels in the product. Cell size, baseline and the
/// grid origin are integers from here down.
final class GlyphAtlas {
    static let atlasCols = 16
    /// 16x16 = 256 slots. Through Phase 2 this was 16x7 — exactly the 95
    /// printable ASCII codes plus five hand-drawn shapes — which was honest
    /// while Beam's only text was its own chrome, and is a corruption bug the
    /// moment a real file is opened (PLAN.md §5.3). 100 slots stay static and
    /// the remaining 156 are filled on demand by `GlyphCache`. The texture is
    /// 288x576 px at 2x: an atlas is not where this product spends memory.
    static let atlasRows = 16

    /// Solid cell — the text cursor, and the "pixel" the join code is drawn from.
    static let blockGlyphIndex: UInt16 = 95
    /// Small centered disc — also the "unsaved" mark beside a filename.
    static let dotGlyphIndex: UInt16 = 96
    /// Thin full-width rule on the cell's baseline — separators.
    static let ruleGlyphIndex: UInt16 = 97
    /// Thin left-edge bar — a peer's remote caret (distinct from your own block).
    static let barGlyphIndex: UInt16 = 98
    /// Rounded colour chip — a peer's identity in the presence line and the HUD.
    /// Wider than it is tall on purpose: a circle small enough to be tasteful was
    /// too small to carry a hue, and widening it into a pill buys the colour more
    /// than twice the area inside the same single cell.
    static let chipGlyphIndex: UInt16 = 99
    /// Hollow box — a scalar this machine has no glyph for, or an atlas that
    /// ran out of slots. Beam draws it rather than nothing: a character that is
    /// *visibly* missing is honest, and one that silently occupies no cell
    /// slides the rest of the line and is not.
    static let replacementGlyphIndex: UInt16 = 100
    /// Rail icons. A cell is 1:2, so a **square** icon — the only shape an icon
    /// can be — spans `2k` cells across by `k` rows down. §5.4 took `k = 1`: a
    /// 36x36 mark in two adjacent atlas cells.
    ///
    /// **§5.7 takes `k = 2`** — a 72x72 box across four cells and two rows, so
    /// the icon inside it is set at ~26 pt against VS Code's ~24, instead of
    /// the 18 pt `k = 1` allowed. There is no size in between: the ratio is
    /// what makes an icon square at all, so the only sizes available are the
    /// ones it admits, and 18 pt was the smaller of the two.
    ///
    /// Slots are the top-left cell of the block; the rest are `+1...+3` across
    /// and `+atlasCols` down, which is why each icon needs a run of four free
    /// slots in one row with four free beneath it. They start at a row boundary
    /// (112 and 116 are row 7) so that stays true by inspection.
    static let iconCols = 4
    static let iconRows = 2
    static let filesIconIndex: UInt16 = 112      // 112...115 + 128...131
    static let peersIconIndex: UInt16 = 116      // 116...119 + 132...135
    /// The text caret: a thin vertical bar on the cell's left edge, full cell
    /// height. Distinct from `barGlyphIndex` (a peer's caret) because yours is
    /// an insertion point and theirs is a presence mark, and yours is the one
    /// pixel in the product you are always looking for.
    static let caretGlyphIndex: UInt16 = 105
    /// **Hairlines.** Exactly one device pixel, on the cell's bottom edge and
    /// its left edge respectively. One pixel is the modern Mac divider — at 2x
    /// it is half a point, which reads as a seam in the surface rather than as
    /// a drawn line. `ruleGlyphIndex` sits on the *baseline* and is a rule
    /// through text; these sit on cell *edges* and are structure.
    static let dividerHIndex: UInt16 = 106
    static let dividerVIndex: UInt16 = 107
    /// Two device pixels on the cell's **top** edge — the accent bar that marks
    /// the active tab. Every modern tab strip has one; without it the front tab
    /// is just text on the ground with no container, which is exactly what
    /// "the tabs look weird" was.
    static let tabAccentIndex: UInt16 = 108
    /// First slot `GlyphCache` may assign. Everything below is static and is
    /// never evicted, so the chrome can never lose its own glyphs to a file
    /// full of mathematical symbols.
    ///
    /// §5.7's larger rail icons cost twelve slots, so the demand-filled pool
    /// goes 147 -> 120. That is still far past what Latin source reaches (a
    /// handful of non-ASCII characters per screen, usually none) and the
    /// overflow is counted rather than hidden either way — see `GlyphCache`.
    static let firstDynamicSlot = 136

    /// Line height as a multiple of the em — **an output now, not an input**
    /// (PLAN.md §5.7). `Metrics` derives the cell height as twice its width and
    /// this reports what that came to, so the number a design conversation
    /// wants is still available and can still be checked.
    ///
    /// The history is worth keeping, because it is the argument for the change.
    /// Menlo's own box is 1.16 em and SF Mono's 1.18 — typing-terminal tight.
    /// Beam's grid carries the overlays and the join screen as well as code, so
    /// it was set to a designed **1.30**: enough air that a list reads as a
    /// list, still dense enough to be an editor. **1.36 was tried against Zed's
    /// and VS Code's 1.4...1.5 and rejected** — at the shipping em it rounds to
    /// a 38 px cell against 36, which bought a barely perceptible amount of air
    /// for 5.6% of the editing rows on screen, the scarcest resource in the
    /// product.
    ///
    /// What that rejection *actually* turned on is the thing §5.7 promoted to a
    /// rule: 1.30 is the value that makes the cell exactly 18x36, a clean 1:2,
    /// and at 18x38 a two-cell span is 36x38 so the only shape an icon can be
    /// no longer fits its own box. The ratio was doing the work; the line
    /// height was how it happened to be reached. Derived, the implied value
    /// ranges 1.25-1.33 across the zoom ladder — a narrower spread than the
    /// decision this replaces — and lands on 1.286 at the shipping size, which
    /// rounds to the same 36 px cell 1.30 always produced.
    static func lineHeightEm(_ m: Metrics, pointSize: CGFloat) -> CGFloat {
        CGFloat(m.cellHeightPx) / (pointSize * m.scale).rounded()
    }

    /// The grid's metrics, computed from CoreText alone — no Metal, no window,
    /// no display. Split out so `--dump-scene` can lay out the shipping grid
    /// on a machine with no GPU context: the ASCII view and the pixels then
    /// describe the same layout by construction rather than by agreement.
    /// **Where the window's traffic lights end**, in points, measured on a
    /// `fullSizeContentView` window: device pixels x 20...140, y 25...50 at 2x
    /// (PLAN.md §5.4). They are a fixed size in *device* pixels no matter what
    /// Beam's own text is set at, which is why this is a point constant rather
    /// than anything derived from the cell.
    static let trafficLightsBottomPt: CGFloat = 25

    struct Metrics {
        let cellWidthPx: Int
        let cellHeightPx: Int
        /// Distance from a cell's top edge down to the text baseline, in whole
        /// pixels. It is the number that decides whether the grid looks drawn
        /// or smeared.
        let baselinePx: Int
        let fontName: String
        let scale: CGFloat

        init(pointSize: CGFloat, scale: CGFloat) {
            self.scale = scale
            let em = (pointSize * scale).rounded()
            // SF Mono, the system's own monospace face — modern, native, and
            // shipped with every macOS 10.15+. It is only reachable through
            // this API: CTFontCreateWithName("SF Mono") silently substitutes
            // *Helvetica*, a proportional font, with no error (verified on this
            // machine), which would turn Beam's grid into gibberish on any box
            // without the Xcode font installed. `userFixedPitch` resolves to
            // Menlo and is the fallback.
            let font: CTFont = NSFont.monospacedSystemFont(ofSize: em, weight: .regular)
            fontName = CTFontCopyPostScriptName(font) as String

            // Cell width: the advance, widened if any glyph's ink overflows it —
            // SF Mono's '%' is 17.31 px wide against a 17.31 px advance, so a
            // cell that merely rounded the advance would shave its right edge.
            var mChar: UniChar = 0x4D
            var mGlyph: CGGlyph = 0
            CTFontGetGlyphsForCharacters(font, &mChar, &mGlyph, 1)
            var advance = CGSize.zero
            CTFontGetAdvancesForGlyphs(font, .horizontal, &mGlyph, &advance, 1)

            var inkAbove: CGFloat = 0, inkBelow: CGFloat = 0, inkRight: CGFloat = 0
            for code in 32...126 {
                var ch = UniChar(code)
                var g: CGGlyph = 0
                guard CTFontGetGlyphsForCharacters(font, &ch, &g, 1) else { continue }
                let r = CTFontGetBoundingRectsForGlyphs(font, .horizontal, &g, nil, 1)
                guard !r.isNull, !r.isEmpty else { continue }
                inkAbove = max(inkAbove, r.maxY)
                inkBelow = max(inkBelow, -r.minY)
                inkRight = max(inkRight, r.maxX)
            }

            let ascent = CTFontGetAscent(font)
            let descent = CTFontGetDescent(font)
            cellWidthPx = Int(ceil(max(advance.width, inkRight)))

            // **The cell is 1:2 by derivation** (PLAN.md §5.7). The height is
            // twice the width, and the line height it implies is a checked
            // consequence rather than the input it used to be.
            //
            // It used to be `em * lineHeightEm` with a designed 1.30, and at
            // the shipping em that lands on exactly 36 against an 18 px width —
            // 1:2 by luck. Every shape glyph in Beam is built on that: the rail
            // icons are square paths drawn across *two adjacent cells* because
            // a cell is half a square (§5.4), and the join code's block pixels
            // are square as `2s` cells by `s` rows (§5.2), on the one screen
            // where the security model is a human comparing digits. Measured
            // across 9-24 pt, only four sizes keep 1:2 under the old rule — so
            // a zoom control built on it would have broken the rail, the caret
            // and the join code at nine steps in thirteen, silently, because
            // nothing in the pipeline asserts the ratio.
            //
            // The ink guard below is unchanged and stays for the same reason it
            // was written: ascent/descent are typographic promises, not
            // measurements, and SF Mono's deepest descender ('|', 6.60 px)
            // falls outside its own 5.91 px descent. Measured, it never binds
            // for SF Mono between 9 and 24 pt — at 24 pt the ink wants 50 px
            // and the derivation gives 60 — so 1:2 holds at every step rather
            // than usually. It is a guard against the Menlo fallback and any
            // face with a deeper descender, and it fails the safe way: by
            // making a cell taller, never by clipping a glyph.
            var height = 2 * cellWidthPx
            height = max(height, Int(ceil(inkAbove + inkBelow)))
            var baseline = Int((ascent + (CGFloat(height) - (ascent + descent)) / 2).rounded())
            baseline = max(baseline, Int(ceil(inkAbove)))
            if height - baseline < Int(ceil(inkBelow)) { height = baseline + Int(ceil(inkBelow)) }
            cellHeightPx = height
            baselinePx = baseline
        }

        /// Grid extent for a drawable of this pixel size — the same arithmetic
        /// GridView applies to `drawableSize`.
        func cols(forWidthPx w: Int) -> Int { max(1, w / cellWidthPx - 2) }
        func rows(forHeightPx h: Int) -> Int { max(1, h / cellHeightPx - 1) }

        /// Where the grid starts, in whole device pixels.
        ///
        /// The origin used to be the constant `(cellWidth, cellHeight/2)`,
        /// which meant the truncation remainder of `cols`/`rows` landed
        /// **entirely on the right and bottom edges** — measured 18 px left
        /// against 34 right, and 18 top against 38 bottom. In a window that is
        /// nothing but content, every edge inherits that, and the whole
        /// composition reads as floating up and to the left without any single
        /// element being wrong. Centring splits the remainder evenly.
        ///
        /// Integer division keeps both on whole device pixels, which §5.2
        /// requires: a fractional origin makes every quad sample across its
        /// atlas cell's edge, and that shipped once as a one-pixel seam through
        /// the join code.
        func originX(forWidthPx w: Int) -> Int {
            max(0, (w - cols(forWidthPx: w) * cellWidthPx) / 2)
        }

        /// **Vertically the remainder is no longer split, and that is a design
        /// decision rather than a regression of the one above** (PLAN.md §5.7).
        ///
        /// Centring was right when both vertical edges were ground. They are
        /// not any more: §5.4 put the **tab strip** on row 0 and the **status
        /// band** on the last row, so both ends of the window are full-bleed
        /// chrome. Splitting the remainder then buys nothing at the bottom —
        /// the status band already overdraws past the last row it claims and
        /// the GPU clips it — while at the top it deposits a strip of ground
        /// *above* the tab strip that nothing chose: 28 device pixels of it at
        /// the shipping size. §5.4 was already working around that strip rather
        /// than owning it (the tab recess is laid under the tabs instead of
        /// across the row, precisely so a full-width band would not leave a
        /// lighter line along the top edge).
        ///
        /// So the top inset is **derived from the only thing that actually
        /// constrains it**: row 0 has to contain the traffic lights, because
        /// that is what "the tabs sit level with the lights" means in pixels.
        /// It is the smallest inset for which the lights fit inside row 0, and
        /// nothing more — 14 px at the shipping cell, against 28 before. The
        /// rest of the remainder goes to the bottom, where the status band is
        /// already built to absorb it.
        ///
        /// It behaves correctly under zoom for the same reason it is written
        /// this way: the lights do not scale with Beam's text, so zooming in
        /// past a 50 px cell drives the inset to 0 and the strip goes flush to
        /// the top, and zooming out grows it so the lights never overlap the
        /// first line of code.
        func originY(forHeightPx h: Int) -> Int {
            let lightsBottom = Int((GlyphAtlas.trafficLightsBottomPt * scale).rounded())
            return max(0, min(lightsBottom - cellHeightPx, h - rows(forHeightPx: h) * cellHeightPx))
        }
    }

    let texture: MTLTexture
    let metrics: Metrics
    /// The face every glyph — static or demand-rasterized — is drawn from.
    private let font: CTFont
    /// One cell's worth of grayscale bitmap, reused for every demand raster so
    /// an atlas miss allocates nothing. Not thread-safe, and does not need to
    /// be: instance building (the only caller) is single-threaded by
    /// construction — the main thread in the window, the only thread in
    /// `--screenshot` and `--dump-scene`.
    private let scratch: CGContext
    var cellWidthPx: Int { metrics.cellWidthPx }
    var cellHeightPx: Int { metrics.cellHeightPx }
    var baselinePx: Int { metrics.baselinePx }
    var fontName: String { metrics.fontName }

    init(device: MTLDevice, pointSize: CGFloat, scale: CGFloat) throws {
        metrics = Metrics(pointSize: pointSize, scale: scale)
        let cellWidthPx = metrics.cellWidthPx
        let cellHeightPx = metrics.cellHeightPx
        let baselinePx = metrics.baselinePx
        let font: CTFont = NSFont.monospacedSystemFont(
            ofSize: (pointSize * scale).rounded(), weight: .regular)
        self.font = font
        guard let scratch = CGContext(
            data: nil, width: cellWidthPx, height: cellHeightPx,
            bitsPerComponent: 8, bytesPerRow: cellWidthPx,
            space: CGColorSpaceCreateDeviceGray(),
            bitmapInfo: CGImageAlphaInfo.none.rawValue
        ) else { throw BeamError("cannot create glyph scratch context") }
        scratch.setShouldAntialias(true)
        scratch.setShouldSmoothFonts(false)
        scratch.setShouldSubpixelPositionFonts(false)
        scratch.setShouldSubpixelQuantizeFonts(false)
        scratch.setFillColor(CGColor(gray: 1, alpha: 1))
        self.scratch = scratch
        let atlasW = cellWidthPx * Self.atlasCols
        let atlasH = cellHeightPx * Self.atlasRows
        guard let ctx = CGContext(
            data: nil, width: atlasW, height: atlasH,
            bitsPerComponent: 8, bytesPerRow: atlasW,
            space: CGColorSpaceCreateDeviceGray(),
            bitmapInfo: CGImageAlphaInfo.none.rawValue
        ) else { throw BeamError("cannot create atlas bitmap context") }
        ctx.setAllowsAntialiasing(true)
        ctx.setShouldAntialias(true)
        // Subpixel (LCD) smoothing is off deliberately and stays off: the atlas
        // is a single grayscale channel, so there is nowhere to put the R/G/B
        // coverage triplet, and asking for it only applies Apple's contrast
        // adjustment to a value we want as plain geometric coverage — which is
        // exactly what the linear blend in Renderer's shader consumes.
        ctx.setShouldSmoothFonts(false)
        ctx.setShouldSubpixelPositionFonts(false)
        ctx.setShouldSubpixelQuantizeFonts(false)
        ctx.setFillColor(CGColor(gray: 1, alpha: 1))

        for code in 32...126 {
            let index = code - 32
            var ch = UniChar(code)
            var glyph: CGGlyph = 0
            guard CTFontGetGlyphsForCharacters(font, &ch, &glyph, 1) else { continue }
            let col = index % Self.atlasCols
            let row = index / Self.atlasCols
            // CGContext origin is bottom-left; atlas row 0 is the top strip.
            // Both coordinates are whole pixels, so every horizontal stem lands
            // on a pixel row instead of being split across two.
            var position = CGPoint(x: CGFloat(col * cellWidthPx),
                                   y: CGFloat(atlasH - (row * cellHeightPx + baselinePx)))
            CTFontDrawGlyphs(font, &glyph, &position, 1, ctx)
        }

        // --- Shape glyphs, drawn rather than shaped: no font on the system has
        // these at exactly our cell metrics, and a mismatched box-drawing glyph
        // is the one thing that would make the grid look accidental. ---
        let w = CGFloat(cellWidthPx), h = CGFloat(cellHeightPx)
        /// Bottom-left origin of a glyph cell, from its index.
        func cellOrigin(_ index: Int) -> CGPoint {
            let col = index % Self.atlasCols, row = index / Self.atlasCols
            return CGPoint(x: CGFloat(col) * w, y: CGFloat(atlasH) - CGFloat(row + 1) * h)
        }

        // 95 — solid block. Fills the cell exactly: the join code's digits are
        // built from these, and with whole-pixel cell metrics they tile without
        // a seam.
        var o = cellOrigin(Int(Self.blockGlyphIndex))
        ctx.fill(CGRect(x: o.x, y: o.y, width: w, height: h))

        // 96 — centered disc, on whole pixels so it is a circle and not an
        // oval-with-one-soft-side.
        o = cellOrigin(Int(Self.dotGlyphIndex))
        let r = (w * 0.22).rounded()
        ctx.fillEllipse(in: CGRect(x: (o.x + w / 2 - r).rounded(), y: (o.y + h / 2 - r).rounded(),
                                   width: r * 2, height: r * 2))

        // 97 — thin full-width rule, sitting on the baseline.
        o = cellOrigin(Int(Self.ruleGlyphIndex))
        let ruleH = max(1, (scale).rounded())
        ctx.fill(CGRect(x: o.x, y: (o.y + h - CGFloat(baselinePx)).rounded(), width: w, height: ruleH))

        // 98 — thin left-edge bar, full height.
        o = cellOrigin(Int(Self.barGlyphIndex))
        ctx.fill(CGRect(x: o.x, y: o.y, width: max(1, (scale * 1.5).rounded()), height: h))

        // 99 — the identity chip: a rounded SQUARE, optically centred on the
        // x-height rather than on the cell, so it sits on the same line as the
        // name beside it instead of floating.
        //
        // It used to be a 14x7 fully-rounded pill, which is a 2:1 horizontal
        // dash — and it is drawn immediately before hostnames like
        // `marlowe-air`, where it read as punctuation rather than as a person.
        // A square of the same ink area carries the hue just as well (that was
        // the original worry) and cannot be mistaken for an en dash.
        o = cellOrigin(Int(Self.chipGlyphIndex))
        let chipW = (w * 0.56).rounded(), chipH = chipW
        let chipY = (o.y + CGFloat(cellHeightPx - baselinePx) + (CGFloat(baselinePx) * 0.22)).rounded()
        ctx.beginPath()
        ctx.addPath(CGPath(roundedRect: CGRect(x: (o.x + (w - chipW) / 2).rounded(), y: chipY,
                                               width: chipW, height: chipH),
                           cornerWidth: (chipW * 0.3).rounded(), cornerHeight: (chipW * 0.3).rounded(),
                           transform: nil))
        ctx.fillPath()

        // 100 — replacement: a hollow box, inset and a whole pixel thick, so it
        // reads as "no glyph" rather than as a character somebody chose.
        o = cellOrigin(Int(Self.replacementGlyphIndex))
        let inset = (w * 0.18).rounded(), stroke = max(1, scale.rounded())
        ctx.setLineWidth(stroke)
        ctx.setStrokeColor(CGColor(gray: 1, alpha: 1))
        ctx.stroke(CGRect(x: o.x + inset, y: (o.y + CGFloat(cellHeightPx - baselinePx)).rounded() + inset,
                          width: w - 2 * inset, height: CGFloat(baselinePx) - 2 * inset).insetBy(dx: stroke / 2, dy: stroke / 2))

        // --- Rail icons (PLAN.md §5.7).
        //
        // **They are filled silhouettes now, not line drawings.** They were
        // outlines at a 3 device-pixel stroke inside a 36 px box, and at that
        // size a 3 px outline reads as dithering rather than as a mark: the one
        // element in the window whose entire job is to be a target was the
        // faintest thing in it. Weight, not size, was the larger half of that
        // problem — but both are fixed here, because the box doubled to 72 px
        // and an outline scaled up with it would have read as an outline twice
        // as large rather than as a heavier mark.
        //
        // Detail inside a silhouette is **knocked out** rather than drawn: the
        // atlas is one alpha channel, so clearing to zero shows whatever is
        // behind the icon, which is the ground. That is how a filled mark gets
        // interior structure without needing a second colour, and it is the
        // same trick the old peers icon already used for its seam.
        /// Bottom-left origin and size of an icon block: `iconCols` cells
        /// across, `iconRows` rows down from `index`.
        func iconBox(_ index: Int) -> CGRect {
            let o = cellOrigin(index + Self.atlasCols * (Self.iconRows - 1))
            return CGRect(x: o.x, y: o.y,
                          width: w * CGFloat(Self.iconCols), height: h * CGFloat(Self.iconRows))
        }
        ctx.setFillColor(CGColor(gray: 1, alpha: 1))
        /// The mark inside its box. Not the full box: an icon that touched its
        /// own edges would sit hard against the active tile behind it, and the
        /// tile is what says "this is where you are".
        let iconInk: CGFloat = 0.72
        /// Knock-outs are a fixed fraction of the mark rather than a pixel
        /// count, so they stay legible at every zoom step instead of closing up
        /// at the small end and yawning open at the large one.
        func knockOut(_ r: CGRect) {
            ctx.setBlendMode(.clear)
            ctx.fill(r)
            ctx.setBlendMode(.normal)
            ctx.setFillColor(CGColor(gray: 1, alpha: 1))
        }

        // files — a filled page, with three lines of text knocked out of it.
        // The page is 3:4 and its corners are rounded against the SHAPE rather
        // than against a stroke width: deriving the radius from a stroke is
        // what once turned this into a capsule, which read as a battery.
        var box = iconBox(Int(Self.filesIconIndex))
        let mark = (box.height * iconInk).rounded()
        let pageW = (mark * 0.78).rounded(), pageH = mark
        let page = CGRect(x: (box.midX - pageW / 2).rounded(), y: (box.midY - pageH / 2).rounded(),
                          width: pageW, height: pageH)
        ctx.beginPath()
        ctx.addPath(CGPath(roundedRect: page, cornerWidth: (pageW * 0.14).rounded(),
                           cornerHeight: (pageW * 0.14).rounded(), transform: nil))
        ctx.fillPath()
        // Three lines, the middle one full and the last one short — the ragged
        // last line is what makes a stack of bars read as *text* rather than as
        // a list or a barcode.
        let lineH = (pageH * 0.09).rounded()
        let lineX = (page.minX + pageW * 0.20).rounded()
        for (k, frac) in [(1, 0.60), (2, 0.60), (3, 0.36)] {
            let y = (page.minY + pageH * (0.72 - CGFloat(k - 1) * 0.20)).rounded()
            knockOut(CGRect(x: lineX, y: y, width: (pageW * CGFloat(frac)).rounded(), height: lineH))
        }

        // peers — two overlapping filled discs, the same metaphor the identity
        // chip already uses, so the rail's language and the status line's agree
        // (§5.2, the identity set).
        box = iconBox(Int(Self.peersIconIndex))
        let r2 = (box.height * iconInk * 0.34).rounded()
        // The seam is a fraction of the disc, not a stroke width: at the old
        // 1.4 px it was thinner than the ink around it and the two discs fused
        // into one blob.
        let seam = max(2, (r2 * 0.22).rounded())
        let back = CGRect(x: (box.midX - r2 * 1.85).rounded(), y: (box.midY - r2).rounded(),
                          width: r2 * 2, height: r2 * 2)
        let front = CGRect(x: (box.midX - r2 * 0.15).rounded(), y: (box.midY - r2).rounded(),
                           width: r2 * 2, height: r2 * 2)
        ctx.fillEllipse(in: back)
        ctx.setBlendMode(.clear)
        ctx.fillEllipse(in: front.insetBy(dx: -seam, dy: -seam))
        ctx.setBlendMode(.normal)
        ctx.setFillColor(CGColor(gray: 1, alpha: 1))
        ctx.fillEllipse(in: front)

        // 105 — the caret. 2 points wide (4 device pixels at 2x), which is the
        // width macOS uses and which reads as a caret rather than as a hairline
        // or as a block. Whole pixels, hard edges, full cell height.
        o = cellOrigin(Int(Self.caretGlyphIndex))
        ctx.fill(CGRect(x: o.x, y: o.y, width: max(2, (scale * 2).rounded()), height: h))

        // 106/107 — hairlines, one device pixel each.
        o = cellOrigin(Int(Self.dividerHIndex))
        ctx.fill(CGRect(x: o.x, y: o.y, width: w, height: 1))
        o = cellOrigin(Int(Self.dividerVIndex))
        ctx.fill(CGRect(x: o.x, y: o.y, width: 1, height: h))
        // 108 — the active tab's accent bar, on the cell's TOP edge.
        o = cellOrigin(Int(Self.tabAccentIndex))
        ctx.fill(CGRect(x: o.x, y: o.y + h - max(2, scale.rounded()), width: w,
                        height: max(2, scale.rounded())))

        let desc = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .r8Unorm, width: atlasW, height: atlasH, mipmapped: false)
        desc.usage = .shaderRead
        // Shared storage so `--screenshot --surface atlas` can read it straight
        // back; the GPU only ever samples it, so this costs nothing at runtime.
        desc.storageMode = .shared
        guard let tex = device.makeTexture(descriptor: desc),
              let bytes = ctx.data else { throw BeamError("cannot create atlas texture") }
        tex.replace(region: MTLRegionMake2D(0, 0, atlasW, atlasH),
                    mipmapLevel: 0, withBytes: bytes, bytesPerRow: atlasW)
        texture = tex
    }

    /// Grid glyph index for an ASCII code, or nil if not renderable.
    static func glyphIndex(forAscii c: UInt8) -> UInt16? {
        guard c >= 32 && c < 127 else { return nil }
        return UInt16(c - 32)
    }

    /// Rasterizes one scalar into one atlas slot, replacing whatever was there.
    /// Returns false if this machine has no glyph for it at all, in which case
    /// the caller uses the replacement box.
    ///
    /// **Cost is budgeted** (`L2.atlas_miss_rasterize_us`). It runs on the
    /// keystroke path the first time a character is seen and never again, so it
    /// is a one-shot spike rather than a per-frame tax — but a spike inside the
    /// commit budget is still a spike, which is why it is measured rather than
    /// assumed. `BEAM_SABOTAGE_ATLAS_MISS_US` proves the gate can go red.
    @discardableResult
    func rasterize(_ scalar: UnicodeScalar, into slot: Int) -> Bool {
        if Sabotage.atlasMissUs > 0 { usleep(UInt32(Sabotage.atlasMissUs)) }
        guard slot >= 0, slot < Self.atlasCols * Self.atlasRows else { return false }
        var glyph: CGGlyph = 0
        var chars = Array(String(scalar).utf16)
        var drawFont = font
        if !CTFontGetGlyphsForCharacters(font, &chars, &glyph, chars.count) || glyph == 0 {
            // The system face does not have it. CoreText's cascade list does
            // this properly (it is how any CJK or emoji character resolves at
            // all); the substitute will not be monospace, which the fit below
            // handles.
            let cf = CTFontCreateForString(font, String(scalar) as CFString,
                                           CFRangeMake(0, chars.count))
            guard CTFontGetGlyphsForCharacters(cf, &chars, &glyph, chars.count), glyph != 0 else {
                return false
            }
            drawFont = cf
        }

        scratch.setFillColor(CGColor(gray: 0, alpha: 1))
        scratch.fill(CGRect(x: 0, y: 0, width: cellWidthPx, height: cellHeightPx))
        scratch.setFillColor(CGColor(gray: 1, alpha: 1))
        scratch.saveGState()
        // A glyph wider than the cell — every East Asian character, and most
        // emoji — is squashed to fit rather than clipped. Both are wrong; only
        // one is still *readable*, and neither can slide the rest of the line,
        // which is the property that actually matters. One cell per scalar is
        // Phase 1's documented limit; East Asian width joins bidi and IME on
        // PLAN.md §1's list of things the web gave us and we signed up to
        // rebuild (the design is two atlas slots and a width-aware column map).
        var advance = CGSize.zero
        CTFontGetAdvancesForGlyphs(drawFont, .horizontal, &glyph, &advance, 1)
        if advance.width > CGFloat(cellWidthPx) + 0.5 {
            scratch.translateBy(x: 0, y: 0)
            scratch.scaleBy(x: CGFloat(cellWidthPx) / advance.width, y: 1)
        }
        var position = CGPoint(x: 0, y: CGFloat(cellHeightPx - baselinePx))
        CTFontDrawGlyphs(drawFont, &glyph, &position, 1, scratch)
        scratch.restoreGState()

        guard let bytes = scratch.data else { return false }
        // CGContext is bottom-up and the atlas row 0 is the top strip, but the
        // scratch cell and the atlas cell have the same orientation, so this is
        // a straight copy of one cell-sized rectangle.
        let col = slot % Self.atlasCols, row = slot / Self.atlasCols
        texture.replace(
            region: MTLRegionMake2D(col * cellWidthPx, row * cellHeightPx, cellWidthPx, cellHeightPx),
            mipmapLevel: 0, withBytes: bytes, bytesPerRow: cellWidthPx)
        return true
    }
}

struct BeamError: Error, CustomStringConvertible {
    let description: String
    init(_ d: String) { description = d }
}

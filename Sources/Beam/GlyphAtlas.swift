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
    /// Rail icons, each **two cells wide** (PLAN.md §5.4, change 1). A cell is
    /// 1:2, so an icon that is square — the only shape an icon can be — spans
    /// two of them. The pair is drawn as one 36x36 path across two adjacent
    /// atlas cells, which works because these indices are adjacent within a row.
    static let filesIconIndex: UInt16 = 101      // and 102
    static let peersIconIndex: UInt16 = 103      // and 104
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
    /// First slot `GlyphCache` may assign. Everything below is static and is
    /// never evicted, so the chrome can never lose its own glyphs to a file
    /// full of mathematical symbols.
    static let firstDynamicSlot = 108

    /// Line height as a multiple of the em. Menlo's own box is 1.16 em and SF
    /// Mono's 1.18 — typing-terminal tight. Beam's grid carries the overlays and
    /// the join screen as well as code, so it is set to a designed 1.30: enough
    /// air that a list reads as a list, still dense enough to be an editor. It is
    /// a whole-pixel number after rounding, by construction.
    ///
    /// **1.36 was tried against Zed's and VS Code's 1.4...1.5 and rejected.** At
    /// the shipping em (28 px at 2x) it rounds to a 38 px cell against 36, which
    /// on the screenshots bought a barely perceptible amount of air — the block
    /// comment read marginally more like a paragraph — for 5.6% of the editing
    /// rows on screen, the scarcest resource in the product. It also costs
    /// something the number does not show: 1.30 is the value that makes the cell
    /// exactly **18x36, a clean 1:2**, and §5.4's rail icons are square paths
    /// drawn across *two* adjacent cells precisely because a cell is half a
    /// square. At 18x38 a two-cell span is 36x38 and the only shape an icon can
    /// be no longer fits its own box. A line-height change here is a geometry
    /// change over in the chrome, and the air it buys is not worth it.
    static let lineHeightEm: CGFloat = 1.30

    /// The grid's metrics, computed from CoreText alone — no Metal, no window,
    /// no display. Split out so `--dump-scene` can lay out the shipping grid
    /// on a machine with no GPU context: the ASCII view and the pixels then
    /// describe the same layout by construction rather than by agreement.
    struct Metrics {
        let cellWidthPx: Int
        let cellHeightPx: Int
        /// Distance from a cell's top edge down to the text baseline, in whole
        /// pixels. It is the number that decides whether the grid looks drawn
        /// or smeared.
        let baselinePx: Int
        let fontName: String

        init(pointSize: CGFloat, scale: CGFloat) {
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

            // Line height is designed, then the baseline is centred inside it
            // and rounded to a whole pixel — and then *checked against the real
            // ink*, because ascent/descent are typographic promises, not
            // measurements: SF Mono's deepest descender ('|', 6.60 px) falls
            // outside its own 5.91 px descent, so a cell sized from the metrics
            // alone clips it.
            var height = Int((em * GlyphAtlas.lineHeightEm).rounded())
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
        func originY(forHeightPx h: Int) -> Int {
            max(0, (h - rows(forHeightPx: h) * cellHeightPx) / 2)
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

        // --- Rail icons. Each spans two cells, so the drawable box is square.
        /// Bottom-left origin and size of a two-cell icon box.
        func iconBox(_ index: Int) -> CGRect {
            let o = cellOrigin(index)
            return CGRect(x: o.x, y: o.y, width: w * 2, height: h)
        }
        ctx.setStrokeColor(CGColor(gray: 1, alpha: 1))
        ctx.setFillColor(CGColor(gray: 1, alpha: 1))
        // **A rail icon's stroke is 1.5 points, not 1 device pixel.** At one
        // device pixel a 36 px icon on a dark ground reads as dithering rather
        // than as a drawn mark — it is below the weight the surrounding text is
        // set at, so the one element in the window whose whole job is to be a
        // target was the faintest thing in it.
        let iconStroke = max(2, (scale * 1.5).rounded())

        // 101/102 — files: a page outline with three lines of text in it. A
        // folded corner is illegible at this size; three strokes are not.
        var box = iconBox(Int(Self.filesIconIndex))
        // 3:4 with a small radius. At 0.46 wide and a radius of two strokes it
        // came out a capsule — a battery, not a page — which is what happens
        // when a corner radius is derived from the stroke instead of from the
        // shape it is rounding.
        let pageW = (box.width * 0.58).rounded(), pageH = (box.height * 0.74).rounded()
        let page = CGRect(x: (box.midX - pageW / 2).rounded(), y: (box.midY - pageH / 2).rounded(),
                          width: pageW, height: pageH)
        ctx.setLineWidth(iconStroke)
        ctx.addPath(CGPath(roundedRect: page.insetBy(dx: iconStroke / 2, dy: iconStroke / 2),
                           cornerWidth: scale * 1.5, cornerHeight: scale * 1.5, transform: nil))
        ctx.strokePath()
        for k in 1...3 {
            let y = (page.minY + page.height * CGFloat(k) / 4).rounded()
            ctx.fill(CGRect(x: (page.minX + pageW * 0.24).rounded(), y: y,
                            width: (pageW * 0.52).rounded(), height: iconStroke))
        }

        // 103/104 — peers: two overlapping discs, the same metaphor the peer
        // chip already uses, so the rail's language and the roster's agree.
        box = iconBox(Int(Self.peersIconIndex))
        let r2 = (box.height * 0.26).rounded()
        let back = CGRect(x: (box.midX - r2 * 1.9).rounded(), y: (box.midY - r2).rounded(),
                          width: r2 * 2, height: r2 * 2)
        let front = CGRect(x: (box.midX - r2 * 0.1).rounded(), y: (box.midY - r2).rounded(),
                           width: r2 * 2, height: r2 * 2)
        ctx.fillEllipse(in: back)
        // The front disc is knocked out of the back one so they read as two
        // people rather than as one blob. The knock-out is the front disc grown
        // by a whole stroke on every side: at the old 1.4 px the seam was
        // thinner than the ink around it and the two discs fused.
        ctx.setBlendMode(.clear)
        ctx.fillEllipse(in: front.insetBy(dx: -iconStroke, dy: -iconStroke))
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

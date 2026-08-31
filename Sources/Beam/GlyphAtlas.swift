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
/// Beam draws its entire UI from this atlas — roster, join code, cursors, HUD.
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
    static let atlasRows = 7

    /// Solid cell — the text cursor, and the "pixel" the join code is drawn from.
    static let blockGlyphIndex: UInt16 = 95
    /// Small centered disc — the peer chip in the roster.
    static let dotGlyphIndex: UInt16 = 96
    /// Thin full-width rule on the cell's baseline — separators.
    static let ruleGlyphIndex: UInt16 = 97
    /// Thin left-edge bar — a peer's remote caret (distinct from your own block).
    static let barGlyphIndex: UInt16 = 98
    /// Rounded colour chip — a peer's identity in the roster and the HUD. Wider
    /// than it is tall on purpose: a circle small enough to be tasteful was too
    /// small to carry a hue, and widening it into a pill buys the colour more
    /// than twice the area inside the same single cell.
    static let chipGlyphIndex: UInt16 = 99

    /// Line height as a multiple of the em. Menlo's own box is 1.16 em and SF
    /// Mono's 1.18 — typing-terminal tight. Beam's grid carries the roster and
    /// the join screen as well as code, so it is set to a designed 1.30: enough
    /// air that a list of peers reads as a list, still dense enough to be an
    /// editor. It is a whole-pixel number after rounding, by construction.
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
    }

    let texture: MTLTexture
    let metrics: Metrics
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

        // 99 — rounded chip, ~60% of the cell wide and a third of it tall,
        // optically centred on the x-height rather than on the cell, so it sits
        // on the same line as the name beside it instead of floating.
        o = cellOrigin(Int(Self.chipGlyphIndex))
        let chipW = (w * 0.78).rounded(), chipH = (h * 0.20).rounded()
        let chipY = (o.y + CGFloat(cellHeightPx - baselinePx) + (CGFloat(baselinePx) * 0.30)).rounded()
        ctx.beginPath()
        ctx.addPath(CGPath(roundedRect: CGRect(x: (o.x + (w - chipW) / 2).rounded(), y: chipY,
                                               width: chipW, height: chipH),
                           cornerWidth: chipH / 2, cornerHeight: chipH / 2, transform: nil))
        ctx.fillPath()

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
}

struct BeamError: Error, CustomStringConvertible {
    let description: String
    init(_ d: String) { description = d }
}

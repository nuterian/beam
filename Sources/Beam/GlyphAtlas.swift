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

    let texture: MTLTexture
    let cellWidthPx: Int
    let cellHeightPx: Int

    init(device: MTLDevice, pointSize: CGFloat, scale: CGFloat) throws {
        let font = CTFontCreateUIFontForLanguage(.userFixedPitch, pointSize * scale, nil)
            ?? CTFontCreateWithName("Menlo" as CFString, pointSize * scale, nil)

        // Monospace cell metrics from the advance of 'M'.
        var mChar: UniChar = 0x4D
        var mGlyph: CGGlyph = 0
        CTFontGetGlyphsForCharacters(font, &mChar, &mGlyph, 1)
        var advance = CGSize.zero
        CTFontGetAdvancesForGlyphs(font, .horizontal, &mGlyph, &advance, 1)
        let ascent = CTFontGetAscent(font)
        let descent = CTFontGetDescent(font)
        let leading = CTFontGetLeading(font)
        cellWidthPx = Int(ceil(advance.width))
        cellHeightPx = Int(ceil(ascent + descent + leading))

        let atlasW = cellWidthPx * Self.atlasCols
        let atlasH = cellHeightPx * Self.atlasRows
        guard let ctx = CGContext(
            data: nil, width: atlasW, height: atlasH,
            bitsPerComponent: 8, bytesPerRow: atlasW,
            space: CGColorSpaceCreateDeviceGray(),
            bitmapInfo: CGImageAlphaInfo.none.rawValue
        ) else { throw BeamError("cannot create atlas bitmap context") }
        ctx.setAllowsAntialiasing(true)
        ctx.setShouldSmoothFonts(false)
        ctx.setFillColor(CGColor(gray: 1, alpha: 1))

        for code in 32...126 {
            let index = code - 32
            var ch = UniChar(code)
            var glyph: CGGlyph = 0
            guard CTFontGetGlyphsForCharacters(font, &ch, &glyph, 1) else { continue }
            let col = index % Self.atlasCols
            let row = index / Self.atlasCols
            // CGContext origin is bottom-left; atlas row 0 is the top strip.
            let baselineY = CGFloat(atlasH) - (CGFloat(row) * CGFloat(cellHeightPx) + ascent)
            var position = CGPoint(x: CGFloat(col * cellWidthPx), y: baselineY)
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

        // 95 — solid block.
        var o = cellOrigin(Int(Self.blockGlyphIndex))
        ctx.fill(CGRect(x: o.x, y: o.y, width: w, height: h))

        // 96 — centered disc, ~40% of the cell width.
        o = cellOrigin(Int(Self.dotGlyphIndex))
        let r = w * 0.20
        ctx.fillEllipse(in: CGRect(x: o.x + w / 2 - r, y: o.y + h / 2 - r, width: r * 2, height: r * 2))

        // 97 — thin full-width rule, vertically centered.
        o = cellOrigin(Int(Self.ruleGlyphIndex))
        ctx.fill(CGRect(x: o.x, y: o.y + h / 2, width: w, height: max(1, scale)))

        // 98 — thin left-edge bar, full height.
        o = cellOrigin(Int(Self.barGlyphIndex))
        ctx.fill(CGRect(x: o.x, y: o.y, width: max(1, scale * 1.5), height: h))

        let desc = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .r8Unorm, width: atlasW, height: atlasH, mipmapped: false)
        desc.usage = .shaderRead
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

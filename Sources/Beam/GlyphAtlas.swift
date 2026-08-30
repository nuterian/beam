import CoreText
import CoreGraphics
import Metal

/// Rasterizes printable ASCII (32...126) plus a solid block (index 95, used as
/// the cursor) into one grayscale Metal texture, laid out as a fixed 16x6 grid
/// of equal cells so the shader derives UVs from the glyph index alone.
/// CoreText shapes and rasterizes; the GPU only samples — the Zed/GPU-terminal
/// approach (PLAN.md §2). All metrics are in device pixels.
final class GlyphAtlas {
    static let atlasCols = 16
    static let atlasRows = 6
    static let blockGlyphIndex: UInt16 = 95

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

        // Solid block cell for the cursor at index 95 (atlas col 15, row 5).
        ctx.fill(CGRect(x: CGFloat(15 * cellWidthPx), y: 0,
                        width: CGFloat(cellWidthPx), height: CGFloat(cellHeightPx)))

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

import CoreGraphics
import Foundation
import ImageIO
import Metal
import UniformTypeIdentifiers
import BeamCore

/// `--screenshot [--surface <key>|all] [--out dir]` — the eyes (PLAN.md §5.2).
///
/// Renders each surface into an **offscreen** Metal texture at 2x and writes a
/// PNG. There is no window, no `NSApplication` and no display involved, which
/// is the whole point: this machine's screen cycles off and yields to nothing
/// programmatic, so every photon bench can abort while this still works — and
/// it runs in CI, which has no display at all.
///
/// It is not a golden-image test and must never become one (§5.2): pixels are
/// reviewed by eye, structure is gated by `--dump-scene`.
enum Screenshot {
    /// The default window's content size, so a shot is framed exactly as the
    /// product is (AppDelegate's contentRect).
    static let pointSize = CGSize(width: 980, height: 640)
    /// Shots are always 2x regardless of the host's display, so they are
    /// reproducible on any machine and comparable across sessions.
    static let scale: CGFloat = 2

    static func run(surface: String, outDir: String) -> Never {
        let states = SceneStates.all()
        let wanted = surface == "all" ? states : states.filter { $0.key == surface }
        guard !wanted.isEmpty || surface == atlasKey else {
            FileHandle.standardError.write(
                "unknown --surface '\(surface)'. known: all, \(atlasKey), \(states.map(\.key).joined(separator: ", "))\n"
                    .data(using: .utf8)!)
            exit(2)
        }

        let renderer: Renderer
        do {
            renderer = try Renderer(pointSize: 14, scale: scale)
        } catch {
            FileHandle.standardError.write("screenshot: \(error)\n".data(using: .utf8)!)
            exit(1)
        }

        do {
            try FileManager.default.createDirectory(
                atPath: outDir, withIntermediateDirectories: true)
        } catch {
            FileHandle.standardError.write("cannot create \(outDir): \(error)\n".data(using: .utf8)!)
            exit(4)
        }

        // The typography this session is judged on, printed where it can be
        // read without opening a PNG.
        print(String(format: "atlas: %@  cell %dx%d px  baseline %d  grid origin (%d, %d)",
                     renderer.atlas.fontName, renderer.atlas.cellWidthPx, renderer.atlas.cellHeightPx,
                     renderer.atlas.baselinePx, renderer.atlas.cellWidthPx,
                     renderer.atlas.cellHeightPx / 2))

        let widthPx = Int(pointSize.width * scale)
        let heightPx = Int(pointSize.height * scale)
        // The same arithmetic GridView does on drawableSize, and the same grid
        // --dump-scene lays out on (SceneStates.referenceGrid).
        let cols = renderer.atlas.metrics.cols(forWidthPx: widthPx)
        let rows = renderer.atlas.metrics.rows(forHeightPx: heightPx)

        if surface == atlasKey || surface == "all" {
            let path = (outDir as NSString).appendingPathComponent("\(atlasKey).png")
            if writeGray(renderer.atlas.texture, to: path) {
                print("\(path)  \(renderer.atlas.texture.width)x\(renderer.atlas.texture.height)  — the glyph atlas itself")
            }
        }

        for state in wanted {
            let staging = renderer.acquireInstanceStaging()
            var w = InstanceWriter(staging, cap: Renderer.maxInstances)
            // Far past every fade: a screenshot shows the settled frame, never
            // a frame caught mid-arrival.
            state.build(&w, monotonicNow() + 10, cols, rows)
            guard let texture = renderer.renderOffscreen(
                    width: widthPx, height: heightPx, instanceCount: w.count) else {
                FileHandle.standardError.write("offscreen render failed for \(state.key)\n".data(using: .utf8)!)
                exit(1)
            }
            let path = (outDir as NSString).appendingPathComponent("\(state.key).png")
            guard writePNG(texture, to: path) else {
                FileHandle.standardError.write("cannot write \(path)\n".data(using: .utf8)!)
                exit(4)
            }
            print("\(path)  \(widthPx)x\(heightPx)  \(w.count) instances  — \(state.title)")
        }
        exit(0)
    }

    /// The atlas is not a UI surface, but it is the first thing to look at when
    /// the grid goes soft: every typography decision — baseline, cell size,
    /// descender clearance, antialiasing — is visible in it directly.
    static let atlasKey = "atlas"

    /// R8 coverage texture -> gray PNG, for the atlas.
    private static func writeGray(_ texture: MTLTexture, to path: String) -> Bool {
        let width = texture.width, height = texture.height
        var bytes = [UInt8](repeating: 0, count: width * height)
        bytes.withUnsafeMutableBytes { raw in
            texture.getBytes(raw.baseAddress!, bytesPerRow: width,
                             from: MTLRegionMake2D(0, 0, width, height), mipmapLevel: 0)
        }
        guard let provider = CGDataProvider(data: Data(bytes) as CFData),
              let space = CGColorSpace(name: CGColorSpace.linearGray),
              let image = CGImage(
                width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 8,
                bytesPerRow: width, space: space,
                bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.none.rawValue),
                provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent),
              let dest = CGImageDestinationCreateWithURL(
                URL(fileURLWithPath: path) as CFURL, UTType.png.identifier as CFString, 1, nil)
        else { return false }
        CGImageDestinationAddImage(dest, image, nil)
        return CGImageDestinationFinalize(dest)
    }

    /// BGRA8 texture -> PNG. The layer is opaque and the clear is alpha 1, so
    /// alpha is skipped rather than carried; the file is tagged sRGB, which is
    /// what the untagged `bgra8Unorm` values mean on a standard display.
    private static func writePNG(_ texture: MTLTexture, to path: String) -> Bool {
        let width = texture.width, height = texture.height
        let bytesPerRow = width * 4
        var bytes = [UInt8](repeating: 0, count: bytesPerRow * height)
        bytes.withUnsafeMutableBytes { raw in
            texture.getBytes(raw.baseAddress!, bytesPerRow: bytesPerRow,
                             from: MTLRegionMake2D(0, 0, width, height), mipmapLevel: 0)
        }
        guard let provider = CGDataProvider(data: Data(bytes) as CFData),
              let space = CGColorSpace(name: CGColorSpace.sRGB),
              let image = CGImage(
                width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32,
                bytesPerRow: bytesPerRow, space: space,
                bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipFirst.rawValue
                                            | CGBitmapInfo.byteOrder32Little.rawValue),
                provider: provider, decode: nil, shouldInterpolate: false,
                intent: .defaultIntent),
              let dest = CGImageDestinationCreateWithURL(
                URL(fileURLWithPath: path) as CFURL, UTType.png.identifier as CFString, 1, nil)
        else { return false }
        CGImageDestinationAddImage(dest, image, nil)
        return CGImageDestinationFinalize(dest)
    }
}

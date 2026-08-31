import Metal
import QuartzCore
import BeamCore

/// Metal renderer for the monospace grid: one instanced draw of textured quads
/// over a cleared background. Runtime-compiles its shader (works with Command
/// Line Tools only; the cost lives inside the L1 launch budget where it is
/// measured). maximumDrawableCount = 2 is configured by GridView on the layer.
///
/// Present modes (BEAM_PRESENT_MODE, chosen by measurement — see PLAN.md §5-L2):
///   normal      commandBuffer.present(drawable); commit
///   scheduled   commit; waitUntilScheduled; drawable.present()
///   transaction scheduled + layer.presentsWithTransaction = true
final class Renderer {
    enum PresentMode: String {
        case normal, scheduled, transaction
    }
    // Default stays 'normal' (the only mode with a full validated run) until
    // scripts/present-matrix.sh has been run on a visible screen and the
    // numbers pick a winner. Changing this default requires that data.
    static let presentMode: PresentMode = PresentMode(
        rawValue: ProcessInfo.processInfo.environment["BEAM_PRESENT_MODE"] ?? "normal") ?? .normal

    /// Palette slots. Beam has no color picker and no theme file: every colour
    /// in the product is one of these, which is what keeps the whole UI one
    /// instanced draw call.
    enum Ink: UInt16 {
        case fg = 0        // primary text
        case red = 1       // over budget / error
        case green = 2     // under budget / connected
        case dim = 3       // secondary text
        case faint = 4     // tertiary hints
        case accent = 5    // Beam's own mark, the join code
        case peer0 = 6, peer1 = 7, peer2 = 8, peer3 = 9, peer4 = 10, peer5 = 11

        static let peerCount = 6
        static func peer(_ i: Int) -> Ink {
            Ink(rawValue: UInt16(6 + ((i % peerCount) + peerCount) % peerCount)) ?? .peer0
        }
    }

    struct Instance {
        var col: UInt16
        var row: UInt16
        var glyph: UInt16
        /// Packed: low 4 bits = Ink slot, high 8 bits = alpha 0...255. Alpha
        /// lives here so fades cost the hot path exactly nothing — the shader
        /// multiplies a value it was already reading.
        var color: UInt16

        init(col: Int, row: Int, glyph: UInt16, ink: Ink, alpha: UInt8 = 255) {
            self.col = UInt16(truncatingIfNeeded: col)
            self.row = UInt16(truncatingIfNeeded: row)
            self.glyph = glyph
            self.color = (UInt16(alpha) << 8) | (ink.rawValue & 0xF)
        }
    }
    private struct Uniforms {
        var viewportPx: SIMD2<Float>
        var cellPx: SIMD2<Float>
        var atlasCells: SIMD2<Float>
        var originPx: SIMD2<Float>
    }

    static let maxInstances = 200 * 120 + 512
    private static let ringDepth = 3

    let device: MTLDevice
    let atlas: GlyphAtlas
    /// Shader runtime-compile cost, for the launch breakdown (ms).
    let shaderCompileMs: Double
    private let queue: MTLCommandQueue
    private let pipeline: MTLRenderPipelineState
    /// Instance buffers form a ring so the CPU never writes a buffer the GPU
    /// may still be reading (single-buffer writes race under burst input).
    private let instanceRing: [MTLBuffer]
    private var ringIndex = 0
    private let inflight = DispatchSemaphore(value: ringDepth)

    /// Deterministic counter, gated: draw calls issued for the last frame.
    private(set) var drawCallsLastFrame = 0
    /// --flash-on-key camera-calibration mode: render N all-white frames.
    var flashFramesRemaining = 0

    /// The ground, in **sRGB** — the colour a designer would name.
    /// **#0D1117**, OKLCH L 0.175 / C 0.014 / H 258. Not neutral: a trace of
    /// the same blue the text hierarchy is built from, so the whole surface
    /// reads as one material rather than as grey with colours on it.
    ///
    /// It is not in the shader palette because nothing is ever *drawn* in it —
    /// it is the clear colour, the one value that is the absence of ink. It
    /// lives beside the palette because it is what every contrast step there
    /// is measured against.
    static let groundSRGB = SIMD3<Float>(0.050, 0.066, 0.089)

    /// The same ground, linearised. The render target is `bgra8Unorm_srgb`, so
    /// Metal encodes on write and every value handed to the GPU — clear colour
    /// included — has to arrive linear or the ground and the text disagree
    /// about what space they are in.
    static let ground: MTLClearColor = {
        let l = linearFromSRGB(groundSRGB)
        return MTLClearColor(red: Double(l.x), green: Double(l.y), blue: Double(l.z), alpha: 1)
    }()

    /// The exact sRGB transfer function (not the 2.2 approximation — the toe
    /// matters at exactly the near-black values this UI is built from).
    static func linearFromSRGB(_ c: SIMD3<Float>) -> SIMD3<Float> {
        SIMD3(c.indices.map { i -> Float in
            let v = c[i]
            return v <= 0.04045 ? v / 12.92 : pow((v + 0.055) / 1.055, 2.4)
        })
    }

    /// The render target's pixel format. `_srgb` is the whole gamma story in
    /// one token: the GPU decodes the destination and encodes the result, so
    /// the blend in between happens in **linear light**, which is the only
    /// space in which a glyph's antialiased edge coverage means what it says.
    /// Blended in non-linear sRGB — the default, and what Beam shipped through
    /// Phase 2 — light text on a dark ground comes out too dark at the edges
    /// and reads thin and slightly grubby. See PLAN.md §5.2.
    static let pixelFormat: MTLPixelFormat = .bgra8Unorm_srgb

    private static let shaderSource = """
    #include <metal_stdlib>
    using namespace metal;

    struct Uniforms {
        float2 viewportPx;
        float2 cellPx;
        float2 atlasCells;
        float2 originPx;
    };
    struct Inst { ushort col; ushort row; ushort glyph; ushort color; };
    struct VSOut { float4 pos [[position]]; float2 uv; float3 rgb [[flat]]; float alpha [[flat]]; };

    // The palette is written in sRGB — the numbers a designer reasons about —
    // and linearised here, once per vertex (four per glyph, flat-interpolated),
    // so the fragment shader blends in linear light without the design system
    // becoming a table of unreadable magic constants.
    inline float3 linearFromSRGB(float3 c) {
        return select(pow((c + 0.055) / 1.055, 2.4), c / 12.92, c <= 0.04045);
    }

    // ---- Beam's design system. This table IS it; there is no theme file and
    // no colour picker, which is what keeps the whole UI one draw call. ----
    //
    // Designed in OKLCH and converted here, so the numbers below are the
    // *result* of a decision rather than the decision itself. Every entry
    // carries its hex, its OKLCH coordinates and its measured WCAG contrast
    // against the ground (#0D1117), because "is this legible" is a
    // measurement and "is this pretty" is not.
    //
    // Two rules the table enforces by construction:
    //   * fg / dim / faint are one hue (258, the ground's own) at deliberate
    //     lightness steps — 0.930 / 0.700 / 0.505 — so the text hierarchy is a
    //     scale a reader can feel, not three greys someone typed.
    //   * The six peer colours share an identical L (0.760) and C (0.120) and
    //     differ ONLY in hue, 60 degrees apart. That is the whole trick: at
    //     equal perceived lightness they read as one set, and no peer is
    //     louder than another. The ring is offset 30 degrees from the accent's
    //     hue, which is the furthest six evenly spaced hues can stay from it.
    //
    // 16 entries because the ink index is 4 bits wide: a future palette slot
    // must not be able to read past the end of this array.
    constant float4 palette[16] = {
        float4(0.890, 0.911, 0.941, 1.0),  // fg     #E3E8F0  L0.930 C0.012 H258  15.4:1 — primary text — the thing you are reading
        float4(0.966, 0.311, 0.267, 1.0),  // red    #F64F44  L0.660 C0.205 H28    5.5:1 — over budget, and the two roster failure states
        float4(0.383, 0.838, 0.568, 1.0),  // green  #62D691  L0.790 C0.145 H155  10.4:1 — under budget: the HUD's resting state
        float4(0.598, 0.623, 0.661, 1.0),  // dim    #989FA9  L0.700 C0.016 H258   7.1:1 — secondary text — labels, prompts, your own caret
        float4(0.370, 0.397, 0.436, 1.0),  // faint  #5E656F  L0.505 C0.018 H258   3.2:1 — tertiary hints; recessive on purpose, still legible
        float4(0.137, 0.789, 0.985, 1.0),  // accent #23C9FB  L0.780 C0.142 H225   9.8:1 — reserved: the "beam" mark and the join code, nothing else
        float4(0.954, 0.566, 0.598, 1.0),  // peer 0 #F39098  L0.760 C0.120 H15    8.4:1 — a warm red
        float4(0.869, 0.649, 0.322, 1.0),  // peer 1 #DDA552  L0.760 C0.120 H75    8.7:1 — amber
        float4(0.563, 0.762, 0.451, 1.0),  // peer 2 #90C273  L0.760 C0.120 H135   9.2:1 — leaf
        float4(0.192, 0.786, 0.786, 1.0),  // peer 3 #31C8C9  L0.760 C0.120 H195   9.3:1 — teal
        float4(0.485, 0.706, 0.988, 1.0),  // peer 4 #7CB4FC  L0.760 C0.120 H255   8.8:1 — cornflower
        float4(0.807, 0.601, 0.900, 1.0),  // peer 5 #CE99E5  L0.760 C0.120 H315   8.4:1 — orchid
        // 12-15 reserved; alias fg so an out-of-range slot degrades to text.
        float4(0.890, 0.911, 0.941, 1.0),
        float4(0.890, 0.911, 0.941, 1.0),
        float4(0.890, 0.911, 0.941, 1.0),
        float4(0.890, 0.911, 0.941, 1.0),
    };

    vertex VSOut grid_vs(uint vid [[vertex_id]], uint iid [[instance_id]],
                         const device Inst* inst [[buffer(0)]],
                         constant Uniforms& u [[buffer(1)]]) {
        Inst g = inst[iid];
        float2 corner = float2(vid & 1u, vid >> 1u);
        float2 px = u.originPx + (float2(g.col, g.row) + corner) * u.cellPx;
        VSOut o;
        o.pos = float4(px.x / u.viewportPx.x * 2.0 - 1.0,
                       1.0 - px.y / u.viewportPx.y * 2.0, 0.0, 1.0);
        float2 cell = float2(g.glyph % 16u, g.glyph / 16u);
        o.uv = (cell + corner) / u.atlasCells;
        o.rgb = linearFromSRGB(palette[g.color & 0xFu].rgb);
        o.alpha = float(g.color >> 8) / 255.0;
        return o;
    }

    fragment float4 grid_fs(VSOut v [[stage_in]],
                            texture2d<float> atlas [[texture(0)]]) {
        constexpr sampler s(coord::normalized, filter::nearest);
        // Coverage is a geometric area, so it is a legitimate linear-light
        // blend weight — which is precisely why the target is sRGB-encoded.
        float a = atlas.sample(s, v.uv).r * v.alpha;
        return float4(v.rgb * a, a);
    }
    """

    init(pointSize: CGFloat, scale: CGFloat) throws {
        guard let dev = MTLCreateSystemDefaultDevice() else { throw BeamError("no Metal device") }
        device = dev
        guard let q = dev.makeCommandQueue() else { throw BeamError("no command queue") }
        queue = q
        atlas = try GlyphAtlas(device: dev, pointSize: pointSize, scale: scale)

        let compileStart = monotonicNow()
        let library = try dev.makeLibrary(source: Self.shaderSource, options: nil)
        let desc = MTLRenderPipelineDescriptor()
        desc.vertexFunction = library.makeFunction(name: "grid_vs")
        desc.fragmentFunction = library.makeFunction(name: "grid_fs")
        let att = desc.colorAttachments[0]!
        att.pixelFormat = Self.pixelFormat
        att.isBlendingEnabled = true
        att.sourceRGBBlendFactor = .one              // shader outputs premultiplied
        att.destinationRGBBlendFactor = .oneMinusSourceAlpha
        att.sourceAlphaBlendFactor = .one
        att.destinationAlphaBlendFactor = .oneMinusSourceAlpha
        pipeline = try dev.makeRenderPipelineState(descriptor: desc)
        shaderCompileMs = (monotonicNow() - compileStart) * 1000

        var ring: [MTLBuffer] = []
        for _ in 0..<Self.ringDepth {
            guard let buf = dev.makeBuffer(length: Self.maxInstances * MemoryLayout<Instance>.stride,
                                           options: .storageModeShared) else {
                throw BeamError("no instance buffer")
            }
            ring.append(buf)
        }
        instanceRing = ring
    }

    /// Zero-copy frame prep: the caller writes instances straight into the
    /// current ring slot (no intermediate array, no per-frame allocation).
    /// Blocks (briefly) only if all ring slots are still in flight.
    func acquireInstanceStaging() -> UnsafeMutablePointer<Instance> {
        inflight.wait()
        return instanceRing[ringIndex].contents().bindMemory(to: Instance.self, capacity: Self.maxInstances)
    }

    /// The one encode path: clear to the ground, then a single instanced draw
    /// of every glyph in the frame. Shared by the window's present path and by
    /// `--screenshot`'s offscreen render, so a screenshot cannot drift from
    /// what actually reaches the glass. Returns draw calls issued, or nil if
    /// the encoder could not be created (caller must not present a texture
    /// that was never cleared).
    private func encodeGrid(into cb: MTLCommandBuffer, target: MTLTexture,
                            buffer: MTLBuffer, instanceCount: Int, flashing: Bool) -> Int? {
        let rpd = MTLRenderPassDescriptor()
        let color = rpd.colorAttachments[0]!
        color.texture = target
        color.loadAction = .clear
        color.storeAction = .store
        color.clearColor = flashing ? MTLClearColor(red: 1, green: 1, blue: 1, alpha: 1) : Self.ground
        guard let enc = cb.makeRenderCommandEncoder(descriptor: rpd) else { return nil }

        var drawCalls = 0
        let count = min(instanceCount, Self.maxInstances)
        if count > 0 && !flashing {
            var uniforms = Uniforms(
                viewportPx: SIMD2(Float(target.width), Float(target.height)),
                cellPx: SIMD2(Float(atlas.cellWidthPx), Float(atlas.cellHeightPx)),
                atlasCells: SIMD2(Float(GlyphAtlas.atlasCols), Float(GlyphAtlas.atlasRows)),
                // Whole pixels. `cellHeightPx / 2` is integer division on
                // purpose: a half-pixel grid origin is what put a one-pixel
                // seam through the join code's digits.
                originPx: SIMD2(Float(atlas.cellWidthPx), Float(atlas.cellHeightPx / 2))
            )
            enc.setRenderPipelineState(pipeline)
            enc.setVertexBuffer(buffer, offset: 0, index: 0)
            enc.setVertexBytes(&uniforms, length: MemoryLayout<Uniforms>.stride, index: 1)
            enc.setFragmentTexture(atlas.texture, index: 0)
            enc.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4, instanceCount: count)
            drawCalls = 1
        }
        enc.endEncoding()
        return drawCalls
    }

    /// Encodes and commits one frame from the staged instances. onCommit fires
    /// synchronously when the present is fully handed off (the end of the pure
    /// software path); onPresented fires with the drawable's presentedTime.
    func renderStaged(layer: CAMetalLayer,
                      instanceCount: Int,
                      onCommit: ((Double) -> Void)? = nil,
                      onPresented: ((Double) -> Void)? = nil) {
        let buffer = instanceRing[ringIndex]
        ringIndex = (ringIndex + 1) % Self.ringDepth

        guard let drawable = layer.nextDrawable() else {
            inflight.signal()
            return
        }

        let flashing = flashFramesRemaining > 0
        if flashing { flashFramesRemaining -= 1 }

        guard let cb = queue.makeCommandBuffer(),
              let drawCalls = encodeGrid(into: cb, target: drawable.texture, buffer: buffer,
                                         instanceCount: instanceCount, flashing: flashing) else {
            inflight.signal()
            return
        }

        if let onPresented {
            drawable.addPresentedHandler { d in onPresented(d.presentedTime) }
        }
        cb.addCompletedHandler { [inflight] _ in inflight.signal() }

        switch Self.presentMode {
        case .normal:
            cb.present(drawable)
            cb.commit()
        case .scheduled, .transaction:
            // Commit first, wait for GPU scheduling, then present directly —
            // Apple's low-latency present recipe. Measured, not assumed:
            // see PLAN.md §5-L2 for the mode matrix numbers.
            cb.commit()
            cb.waitUntilScheduled()
            drawable.present()
        }
        onCommit?(monotonicNow())
        drawCallsLastFrame = drawCalls
    }

    /// Offscreen render of the staged instances into a fresh texture — the
    /// eyes for `--screenshot`. Same instances, same shader, same blend, no
    /// window and no drawable, so it works on a machine whose display has
    /// cycled off and in CI, which has no display at all (PLAN.md §5.2).
    /// Synchronous: the texture is readable when this returns.
    func renderOffscreen(width: Int, height: Int, instanceCount: Int) -> MTLTexture? {
        let buffer = instanceRing[ringIndex]
        ringIndex = (ringIndex + 1) % Self.ringDepth
        defer { inflight.signal() }

        let desc = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: Self.pixelFormat, width: width, height: height, mipmapped: false)
        desc.usage = [.renderTarget, .shaderRead]
        desc.storageMode = .shared
        guard let target = device.makeTexture(descriptor: desc),
              let cb = queue.makeCommandBuffer(),
              encodeGrid(into: cb, target: target, buffer: buffer,
                         instanceCount: instanceCount, flashing: false) != nil else { return nil }
        cb.commit()
        cb.waitUntilCompleted()
        return target
    }
}

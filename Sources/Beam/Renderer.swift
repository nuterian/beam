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

    struct Instance {
        var col: UInt16
        var row: UInt16
        var glyph: UInt16
        var color: UInt16  // palette index: 0 fg, 1 red, 2 green, 3 dim
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
    struct VSOut { float4 pos [[position]]; float2 uv; ushort color [[flat]]; };

    constant float4 palette[4] = {
        float4(0.86, 0.87, 0.90, 1.0),
        float4(0.95, 0.30, 0.30, 1.0),
        float4(0.35, 0.85, 0.45, 1.0),
        float4(0.52, 0.54, 0.58, 1.0),
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
        o.color = g.color;
        return o;
    }

    fragment float4 grid_fs(VSOut v [[stage_in]],
                            texture2d<float> atlas [[texture(0)]]) {
        constexpr sampler s(coord::normalized, filter::nearest);
        float a = atlas.sample(s, v.uv).r;
        float4 c = palette[v.color];
        return float4(c.rgb * a, a);
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
        att.pixelFormat = .bgra8Unorm
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

        let rpd = MTLRenderPassDescriptor()
        let color = rpd.colorAttachments[0]!
        color.texture = drawable.texture
        color.loadAction = .clear
        color.storeAction = .store
        color.clearColor = flashing
            ? MTLClearColor(red: 1, green: 1, blue: 1, alpha: 1)
            : MTLClearColor(red: 0.075, green: 0.08, blue: 0.10, alpha: 1)

        guard let cb = queue.makeCommandBuffer(),
              let enc = cb.makeRenderCommandEncoder(descriptor: rpd) else {
            inflight.signal()
            return
        }

        var drawCalls = 0
        let count = min(instanceCount, Self.maxInstances)
        if count > 0 && !flashing {
            var uniforms = Uniforms(
                viewportPx: SIMD2(Float(drawable.texture.width), Float(drawable.texture.height)),
                cellPx: SIMD2(Float(atlas.cellWidthPx), Float(atlas.cellHeightPx)),
                atlasCells: SIMD2(Float(GlyphAtlas.atlasCols), Float(GlyphAtlas.atlasRows)),
                originPx: SIMD2(Float(atlas.cellWidthPx), Float(atlas.cellHeightPx) / 2)
            )
            enc.setRenderPipelineState(pipeline)
            enc.setVertexBuffer(buffer, offset: 0, index: 0)
            enc.setVertexBytes(&uniforms, length: MemoryLayout<Uniforms>.stride, index: 1)
            enc.setFragmentTexture(atlas.texture, index: 0)
            enc.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4, instanceCount: count)
            drawCalls = 1
        }
        enc.endEncoding()

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
}

import Foundation
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

    /// Palette slots. Beam has no colour picker and no theme file: every colour
    /// in the product is one of these, which is what keeps the whole UI one
    /// (now two) instanced draw calls.
    ///
    /// **The ink field is a full byte** (`Instance.color` bits 0...7; alpha is
    /// bits 8...15). Through Phase 2 it was four bits, because twelve colours
    /// was the whole product. A file view needs filled *surfaces* and a syntax
    /// theme needs token colours, and widening the field costs exactly nothing:
    /// bits 4...7 of the same `UInt16` were already sitting unused. The shader
    /// table is `paletteSlots` entries and masks to it, so an unassigned slot
    /// degrades to plain text rather than reading past the end of an array.
    enum Ink: UInt16, CaseIterable {
        // --- Text. One hue (258, the ground's own) at deliberate lightness steps.
        case fg = 0        // primary text
        case red = 1       // over budget / error
        case green = 2     // under budget / connected
        case dim = 3       // secondary text
        case faint = 4     // tertiary hints
        case accent = 5    // Beam's own mark, the join code
        // --- Identity. Equal OKLCH L and C, hue 60 degrees apart: one set.
        case peer0 = 6, peer1 = 7, peer2 = 8, peer3 = 9, peer4 = 10, peer5 = 11

        // --- Surfaces (PLAN.md §5.3). These are never text; they are the
        // full-cell block glyph written BEFORE the text in the same buffer, so
        // a filled background costs one instance and no draw call. Filled
        // surfaces are the single thing that most separates a GUI from a TUI,
        // and on a glyph grid they are nearly free.
        case surface = 12     // an overlay panel's own plane
        case scrim = 13       // the dim laid over the document behind an overlay
        case selection = 14   // selected text
        case activeLine = 15  // the row the caret is on
        case hover = 16       // the pointer is over this row
        case edge = 17        // hairlines, the scroll indicator
        /// **Your caret.** Its own slot, and not merely for theming: the shader
        /// recognises this ink and modulates its alpha from a time uniform, so
        /// the blink is a GPU-side function of one float rather than anything
        /// the model, the scene or the instance buffer knows about
        /// (PLAN.md §5.5).
        case caret = 18
        /// Content brightened under the pointer. It exists as its OWN slot,
        /// rather than as a different ink chosen at draw time, so that it can
        /// be *animated*: the label or icon is drawn twice — once at rest, once
        /// in this — and the animation phase cross-fades the bright copy in
        /// over the resting one. A hover that only fills a rectangle is a
        /// rectangle appearing; a hover where the content itself brightens is
        /// what reads as modern.
        case hoverText = 19

        // --- Syntax (PLAN.md §5.3). Deliberately a DIFFERENT band from the
        // peer hues: peers sit at L 0.760 / C 0.120, tokens at L 0.78...0.83
        // and roughly two thirds the chroma. Code then reads as text with a
        // tint rather than as a set of labels, and a peer's caret or name can
        // never be mistaken for a keyword.
        case synKeyword = 20
        case synType = 21
        case synString = 22
        case synNumber = 23
        case synComment = 24
        case synFunction = 25
        case synPunct = 26
        case synOperator = 27

        static let peerCount = 6
        static func peer(_ i: Int) -> Ink {
            Ink(rawValue: UInt16(6 + ((i % peerCount) + peerCount) % peerCount)) ?? .peer0
        }
    }

    /// Token kind to palette slot. The whole theme, in one function: a token
    /// kind IS an ink, an ink is a byte in a word the instance already carried,
    /// so colouring a character costs zero extra instances and zero extra draw
    /// calls (PLAN.md §5.3).
    static func ink(for kind: TokenKind) -> Ink {
        switch kind {
        case .plain: return .fg
        case .keyword: return .synKeyword
        case .type: return .synType
        case .string: return .synString
        case .number: return .synNumber
        case .comment: return .synComment
        case .function: return .synFunction
        case .punct: return .synPunct
        case .oper: return .synOperator
        }
    }

    /// Size of the shader's palette table. A power of two so the shader can
    /// mask instead of clamp; the mask is derived from it, so growing the
    /// palette means changing this one number. The instance field is a byte, so
    /// this can reach 256 without touching the wire format or the buffer.
    static let paletteSlots = 64

    struct Instance {
        var col: UInt16
        var row: UInt16
        var glyph: UInt16
        /// Packed: low **8** bits = Ink slot, high 8 bits = alpha 0...255. Alpha
        /// lives here so fades cost the hot path exactly nothing — the shader
        /// multiplies a value it was already reading, and widening ink from 4
        /// bits to 8 (Phase 1, for surfaces and a syntax theme) cost the same
        /// nothing: bits 4...7 were already unused.
        var color: UInt16

        init(col: Int, row: Int, glyph: UInt16, ink: Ink, alpha: UInt8 = 255) {
            self.col = UInt16(truncatingIfNeeded: col)
            self.row = UInt16(truncatingIfNeeded: row)
            self.glyph = glyph
            self.color = (UInt16(alpha) << 8) | (ink.rawValue & 0xFF)
        }
    }
    /// One draw's worth of instances, with its own grid origin and its own
    /// clip. Beam has exactly two (PLAN.md §5.3): the **document**, whose
    /// origin carries the sub-cell scroll offset and whose scissor is the text
    /// viewport, and the **chrome** — gutter, filename, status line, overlay —
    /// which sits on the whole-pixel grid and never moves. They cannot share a
    /// draw because they disagree about where the grid starts, and that
    /// disagreement is exactly what pixel-quantized scrolling is.
    ///
    /// `draw_calls_per_frame` was budgeted at 2 in Phase 0 while measuring 1.
    /// This is the budget being spent, on the thing it was reserved for.
    struct Plane {
        var count = 0
        /// Added to the grid origin for this plane only. Whole pixels: a
        /// fractional origin makes every quad sample across its atlas cell's
        /// edge, which is the bug §5.2 found in the join code.
        var originOffsetPx = SIMD2<Float>(0, 0)
        /// Clip in device pixels (x, y, width, height), or nil for the whole
        /// target. A line scrolled halfway out of the viewport is clipped here
        /// rather than allowed to run under the filename.
        var scissorPx: (x: Int, y: Int, width: Int, height: Int)?
    }

    private struct Uniforms {
        var viewportPx: SIMD2<Float>
        var cellPx: SIMD2<Float>
        var atlasCells: SIMD2<Float>
        var originPx: SIMD2<Float>
    }

    /// Where the caret's blink is evaluated: the CPU passes elapsed time and
    /// the GPU shapes it. Two things fall out of that. The instance buffer does
    /// not change between blink frames, so a pulse can be re-presented without
    /// rebuilding anything; and the curve is a full-precision float in the
    /// shader rather than a value quantized into the 8-bit per-instance alpha
    /// field, so a slow ramp has no steps in it.
    static let caretPeriod: Float = 1.2

    /// How hard the blink's cosine is shaped before it is clamped. It decides
    /// the whole feel of the caret, and it decides the bench row: the curve is
    /// flat wherever the clamp bites, and §5.5's tick sleeps through flat
    /// stretches, so **gain is inversely proportional to the number of presents
    /// a blinking caret costs.**
    ///
    /// It exists as a named constant because **the two evaluations of this
    /// curve had drifted apart.** The blink is computed twice on purpose: the
    /// shader draws it, and `GridView.caretAlpha` re-derives it on the CPU as a
    /// *change detector*, so a tick that would look identical presents nothing
    /// and `GridView.secondsUntilCurveMoves` can sleep through the flat parts.
    /// Both CPU functions are written for a gain of **6** —
    /// `clamp(c * 3 + 0.5)` is `c · 6 · 0.5 + 0.5`, and the sleep threshold is
    /// spelled `acos(1.0 / 6.0)`. The shader was written for **3**. They were
    /// two different curves.
    ///
    /// The arithmetic, since a number this load-bearing should not be a guess.
    /// `s` saturates where `|cos| >= 1/g`, so a period is flat for
    /// `2·acos(1/g)/π` of its length and ramps for the rest:
    ///
    ///     g = 3.0   clamps at |cos| > 1/3   flat 78%   ramp 130 ms
    ///     g = 6.0   clamps at |cos| > 1/6   flat 89%   ramp  64 ms
    ///
    /// So the CPU slept through stretches — everything between |cos| = 1/6 and
    /// 1/3 — in which the shader's alpha was still climbing, and the ramp the
    /// user saw was drawn in coarse steps rather than over four frames. The
    /// second row is also what §5.5 describes in prose ("flat for 89% of its
    /// period", "about 64 ms", "roughly seven presents a second rather than
    /// sixty"), and it is strictly *less* work than the first — fewer presents,
    /// longer sleeps — which is the only direction `caret_blink_cpu_pct_core`
    /// can move. Making the shader agree with the scheduler is therefore both
    /// the correctness fix and the cheap one. 64 ms is still four frames: a
    /// ramp, not a square wave, so it settles rather than flickers.
    static let caretGain: Float = 6.0
    /// The dimmest the caret ever gets. Never zero, for the same reason a fade
    /// never starts at zero (PLAN.md §5.2): the caret is the pixel you are
    /// hunting for, and one that is genuinely invisible for half a second is
    /// one you lose.
    static let caretFloor: Float = 0.12

    static let maxInstances = 200 * 120 + 512
    private static let ringDepth = 3

    let device: MTLDevice
    /// **A `var`, because zoom rebuilds it** (PLAN.md §5.7). Every metric the
    /// layout derives from — cell size, baseline, grid origin, the shape
    /// glyphs' geometry — comes out of this object, so changing the point size
    /// at runtime means replacing it wholesale rather than adjusting anything.
    private(set) var atlas: GlyphAtlas
    /// The backing scale the atlas was built at, kept so a rebuild happens at
    /// the same scale rather than at whatever a caller remembers.
    private let scale: CGFloat
    /// Shader runtime-compile cost, for the launch breakdown (ms).
    let shaderCompileMs: Double
    private let queue: MTLCommandQueue
    private let pipeline: MTLRenderPipelineState
    /// Instance buffers form a ring so the CPU never writes a buffer the GPU
    /// may still be reading (single-buffer writes race under burst input).
    private let instanceRing: [MTLBuffer]
    private var ringIndex = 0
    private let inflight = DispatchSemaphore(value: ringDepth)
    /// The last frame's instances, kept so a blink can be re-presented without
    /// rebuilding them. Re-reading a buffer another command buffer is also
    /// reading is safe; only WRITES need the semaphore, and a blink writes
    /// nothing.
    private var lastPlanes: [Plane] = []
    private var lastBufferIndex = 0

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

    /// **Beam's design system.** This table IS it: there is no theme file and
    /// no colour picker, which is what keeps the whole UI two draw calls.
    ///
    /// Designed in OKLCH and converted here, so the numbers are the *result* of
    /// a decision rather than the decision itself. Every entry carries its hex,
    /// its OKLCH coordinates and its measured WCAG contrast against the ground
    /// (#0D1117), because "is this legible" is a measurement and "is this
    /// pretty" is not. Colours are written in **sRGB** — the numbers a designer
    /// reasons about — and linearised once per vertex in the shader.
    ///
    /// Rules the table enforces by construction:
    ///   * `fg`/`dim`/`faint` are one hue (258, the ground's own) at deliberate
    ///     lightness steps, so the text hierarchy is a scale a reader can feel.
    ///   * The six peer colours share an identical L (0.760) and C (0.120) and
    ///     differ ONLY in hue, 60 degrees apart: at equal perceived lightness
    ///     they read as one set and no peer is louder than another.
    ///   * The **surface** entries are never text. Their contrast against the
    ///     ground is deliberately low (1.1...1.6:1) — a background that competes
    ///     with its own text is a background that failed. What matters for them
    ///     is the contrast of `fg` ON them, which is annotated instead.
    ///   * The **syntax** entries sit at L 0.78...0.83 and about two thirds the
    ///     peer chroma — a different band from identity, so code reads as text
    ///     with a tint and a peer's caret can never be read as a keyword.
    ///
    /// A slot with no entry aliases `fg`, so an out-of-range ink degrades to
    /// plain text instead of to a random colour.
    static let palette: [(ink: Ink, srgb: SIMD3<Float>, note: String)] = [
        (.fg,        SIMD3(0.890, 0.911, 0.941), "#E3E8F0  L0.930 C0.012 H258  15.4:1 — primary text: the thing you are reading"),
        (.red,       SIMD3(0.939, 0.450, 0.424), "#EF736C  L0.700 C0.155 H25    6.6:1 — over budget, and the presence line's failure states"),
        (.green,     SIMD3(0.359, 0.722, 0.563), "#5CB890  L0.715 C0.108 H163   7.9:1 — under budget: the HUD's RESTING state, and resting is the operative word. At the old 10.4:1 a latency readout was the loudest non-fg thing in an idle editor, which is exactly how a HUD comes to look like debug output (PLAN.md §5.2). It now sits beside dim (7.1:1) instead of above it"),
        (.dim,       SIMD3(0.598, 0.623, 0.661), "#989FA9  L0.700 C0.016 H258   7.1:1 — secondary text: labels, the filename, your own caret"),
        (.faint,     SIMD3(0.460, 0.488, 0.528), "#757C87  L0.585 C0.018 H258   4.5:1 — tertiary: the line-number gutter, an inactive tab, the caret position, the shortcut column. Lifted from #5E656F/3.2:1, which was BELOW AA on a slot doing seven jobs — an inactive tab label was dimmer than a code comment, and the gutter was 4.8x dimmer than the code it indexes. 4.5:1 is exactly AA and still four steps under fg"),
        (.accent,    SIMD3(0.400, 0.830, 0.989), "#66D4FC  L0.820 C0.115 H225  11.2:1 — reserved: the \"beam\" mark and the join code, nothing else"),
        (.peer0,     SIMD3(0.954, 0.566, 0.598), "#F39098  L0.760 C0.120 H15    8.4:1 — a warm red"),
        (.peer1,     SIMD3(0.869, 0.649, 0.322), "#DDA552  L0.760 C0.120 H75    8.7:1 — amber"),
        (.peer2,     SIMD3(0.563, 0.762, 0.451), "#90C273  L0.760 C0.120 H135   9.2:1 — leaf"),
        (.peer3,     SIMD3(0.192, 0.786, 0.786), "#31C8C9  L0.760 C0.120 H195   9.3:1 — teal"),
        (.peer4,     SIMD3(0.485, 0.706, 0.988), "#7CB4FC  L0.760 C0.120 H255   8.8:1 — cornflower"),
        (.peer5,     SIMD3(0.807, 0.601, 0.900), "#CE99E5  L0.760 C0.120 H315   8.4:1 — orchid"),

        // Surfaces. Contrast quoted is fg ON the surface, which is the number
        // that decides whether text over a fill stays readable.
        (.surface,   SIMD3(0.137, 0.160, 0.194), "#232931  L0.278 C0.018 H258  fg on it 12.0:1 — an overlay's own plane, and the active tab's fill. Measured off the pixels: the scrim composites the document down to #030508, and the old #1C2128 panel cleared that by only 1.26:1 — with no border, the code the panel truncates read as BROKEN text rather than as occluded text. Now 1.39:1"),
        (.scrim,     SIMD3(0.009, 0.013, 0.022), "#020306  L0.100 C0.010 H258  — laid over the document at ~72% so the overlay is the only lit thing"),
        (.selection, SIMD3(0.170, 0.273, 0.345), "#2B4658  L0.380 C0.045 H240  fg on it  8.1:1 — selection: the accent's hue at a THIRD the chroma of the old #043C5A. A saturated fill behind text is the single most dated thing a dark editor does; a lighter, greyer slate reads as the text being lifted rather than as the text being painted over"),
        (.activeLine,SIMD3(0.093, 0.110, 0.135), "#181C22  L0.225 C0.014 H258  fg on it 13.9:1 — the caret's row: barely there, and that is the point"),
        (.hover,     SIMD3(0.180, 0.201, 0.232), "#2E333B  L0.320 C0.016 H258  fg on it 10.3:1 — the pointer is over this row. Hover is always drawn ON surface, never on the ground, so it has to clear surface, and it has to stay clearly under selection: the old pair sat 0.04 apart in L and read as the same weight in two tints"),
        (.edge,      SIMD3(0.225, 0.241, 0.265), "#393D44  L0.360 C0.012 H258   1.9:1 vs the ground, 1.35:1 on surface — hairlines and the scroll indicator: structure, not ink, so the number that matters is contrast against what it DIVIDES, not fg on it. One device pixel has to work harder than a fill to be seen at all, which is why edge sits above every surface it separates"),
        (.hoverText, SIMD3(0.890, 0.911, 0.941), "#E3E8F0  L0.930 C0.012 H258  15.4:1 — fg's value in an animatable slot: what a tab label or a rail icon becomes under the pointer"),
        (.caret,     SIMD3(0.765, 0.965, 1.000), "#C3F6FF  L0.940 C0.053 H210  16.2:1 — your caret. The old #B1F3FF was **out of gamut**: its declared L0.930 C0.075 H225 clipped the blue channel and actually rendered as L0.925 C0.067 H210, so the table documented a colour the GPU never drew, and at 15.5:1 against fg's 15.4:1 it was not in any measurable sense brighter than body text. This is the largest chroma reachable at L0.940 on H210 — the hue the old one really landed on — which keeps the caret findable by HUE (on a screen of near-white text a near-white caret is findable only by shape, which was tried and looked worse) while making it, for the first time, genuinely the brightest value in the frame. Shape, width, hard edges and the absence of position easing are untouched: those were already right"),

        // Syntax. One band, low chroma, plain `fg` still the majority colour on
        // any real screen of code — colour is a modifier here, not a rainbow.
        (.synKeyword,  SIMD3(0.706, 0.636, 0.923), "#B4A2EB  L0.755 C0.105 H295   8.4:1 — keywords: the one token kind allowed to be a colour"),
        (.synType,    SIMD3(0.677, 0.863, 0.776), "#ADDCC6  L0.855 C0.058 H165  12.5:1 — types: the keyword hue at LESS THAN A THIRD its chroma. Types are the most frequent coloured token in typed code, so they get the least chroma — the old #D9C284 inverted that and made the commonest thing the loudest"),
        (.synString,  SIMD3(0.921, 0.690, 0.588), "#EBB096  L0.805 C0.078 H45   10.1:1 — strings and characters: the literal voice"),
        (.synNumber,  SIMD3(0.945, 0.769, 0.692), "#F1C4B0  L0.855 C0.058 H45   12.0:1 — numbers: the SAME hue as strings, half the chroma. A number and a string are both literal data; the old table put them 35 degrees apart, which is far enough to be noise and close enough to be indistinguishable"),
        (.synComment, SIMD3(0.412, 0.442, 0.486), "#69717C  L0.545 C0.020 H258   3.8:1 — comments: the one token type that recedes, now in the GROUND's own hue rather than a teal-grey that read as a sixth colour"),
        (.synFunction, SIMD3(0.856, 0.849, 0.970), "#DAD9F7  L0.895 C0.042 H288  13.7:1 — a name being called: the SAME hue as a keyword at a much lighter weight, so the pair reads as one family with two roles. They were 0.045 L apart and indistinguishable; 0.140 apart they are obvious without spending a second hue"),
        (.synPunct,   SIMD3(0.506, 0.528, 0.560), "#81878F  L0.620 C0.014 H258   5.2:1 — brackets and separators step back"),
        (.synOperator,SIMD3(0.655, 0.691, 0.744), "#A7B0BE  L0.755 C0.022 H258   8.7:1 — operators sit just under body text"),
    ]

    /// The palette table as a Metal `constant` array. Generated rather than
    /// hand-written since the table outgrew a screen: 64 slots of hand-aligned
    /// `float4` is a wall nobody proofreads, and the Swift table above is the
    /// thing a person should be reading. Built once, at Renderer init.
    private static func paletteSource() -> String {
        var slots = [String](repeating: "", count: paletteSlots)
        let fg = palette[0]
        for i in 0..<paletteSlots {
            slots[i] = String(format: "        float4(%.3f, %.3f, %.3f, 1.0),  // %d unassigned — aliases fg",
                              fg.srgb.x, fg.srgb.y, fg.srgb.z, i)
        }
        for e in palette {
            let i = Int(e.ink.rawValue)
            guard i < paletteSlots else { continue }
            let name = String(describing: e.ink).padding(toLength: 11, withPad: " ", startingAt: 0)
            slots[i] = String(format: "        float4(%.3f, %.3f, %.3f, 1.0),  // ", e.srgb.x, e.srgb.y, e.srgb.z)
                + name + " " + e.note
        }
        return "constant float4 palette[\(paletteSlots)] = {\n" + slots.joined(separator: "\n") + "\n    };"
    }

    private static var shaderSource: String { """
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
    // becoming a table of unreadable magic constants. See Renderer.palette.
    inline float3 linearFromSRGB(float3 c) {
        return select(pow((c + 0.055) / 1.055, 2.4), c / 12.92, c <= 0.04045);
    }

    \(paletteSource())

    vertex VSOut grid_vs(uint vid [[vertex_id]], uint iid [[instance_id]],
                         const device Inst* inst [[buffer(0)]],
                         constant Uniforms& u [[buffer(1)]],
                         constant float* phase [[buffer(2)]]) {
        Inst g = inst[iid];
        float2 corner = float2(vid & 1u, vid >> 1u);
        float2 px = u.originPx + (float2(g.col, g.row) + corner) * u.cellPx;
        VSOut o;
        o.pos = float4(px.x / u.viewportPx.x * 2.0 - 1.0,
                       1.0 - px.y / u.viewportPx.y * 2.0, 0.0, 1.0);
        float2 cell = float2(g.glyph % \(GlyphAtlas.atlasCols)u, g.glyph / \(GlyphAtlas.atlasCols)u);
        o.uv = (cell + corner) / u.atlasCells;
        // The ink field is a byte; the table is paletteSlots entries and this
        // masks to it, so an unassigned slot degrades to fg instead of reading
        // past the end of the array.
        ushort ink = g.color & \(paletteSlots - 1)u;
        o.rgb = linearFromSRGB(palette[ink].rgb);
        // **The animation engine, in one multiply.** Every palette slot carries
        // a phase in 0...1 that the CPU owns (BeamCore.Animator); fading a
        // thing is a property of the colour it is drawn in, so it costs no
        // bytes per instance and no branch here. This replaces a special case
        // for the caret and is cheaper than the special case was.
        o.alpha = float(g.color >> 8) / 255.0 * phase[ink];
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
    """ }

    init(pointSize: CGFloat, scale: CGFloat) throws {
        guard let dev = MTLCreateSystemDefaultDevice() else { throw BeamError("no Metal device") }
        device = dev
        guard let q = dev.makeCommandQueue() else { throw BeamError("no command queue") }
        queue = q
        self.scale = scale
        atlas = try GlyphAtlas(device: dev, pointSize: pointSize, scale: scale)
        // One atlas per process, so one cache. Beyond this line any scalar the
        // ASCII fast path does not cover can actually be drawn.
        GlyphCache.shared.atlas = atlas

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

    /// Rebuilds the atlas at a new point size.
    ///
    /// **Evicting the glyph cache is not housekeeping here, it is the
    /// correctness half of the operation.** `GlyphCache` maps a scalar to an
    /// atlas slot and remembers, per slot, which scalar is in it. Those slots
    /// are positions in a texture that no longer exists, and the new texture
    /// has nothing in them — so a cache carried across a rebuild hands out
    /// slots that draw blanks, silently, for every non-ASCII character on
    /// screen. The ASCII fast path is unaffected either way: it indexes the
    /// atlas directly and never comes through the cache, which is exactly why
    /// it would have hidden this.
    ///
    /// The pipeline state, the shader and the instance ring are all
    /// independent of the point size and are deliberately NOT rebuilt: a zoom
    /// step is budgeted like a keystroke (`zoom_step_to_presented_60hz_p99_ms`)
    /// and recompiling a shader inside that budget would be absurd.
    func setPointSize(_ pointSize: CGFloat) throws {
        if Sabotage.zoomDelayMs > 0 { usleep(UInt32(Sabotage.zoomDelayMs) * 1000) }
        atlas = try GlyphAtlas(device: device, pointSize: pointSize, scale: scale)
        GlyphCache.shared.reset(atlas: atlas)
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
                            buffer: MTLBuffer, planes: [Plane], flashing: Bool,
                            phase: UnsafePointer<Float>) -> Int? {
        let rpd = MTLRenderPassDescriptor()
        let color = rpd.colorAttachments[0]!
        color.texture = target
        color.loadAction = .clear
        color.storeAction = .store
        color.clearColor = flashing ? MTLClearColor(red: 1, green: 1, blue: 1, alpha: 1) : Self.ground
        guard let enc = cb.makeRenderCommandEncoder(descriptor: rpd) else { return nil }

        var drawCalls = 0
        if !flashing {
            enc.setRenderPipelineState(pipeline)
            enc.setFragmentTexture(atlas.texture, index: 0)
            let full = MTLScissorRect(x: 0, y: 0, width: target.width, height: target.height)
            var first = 0
            for plane in planes {
                let count = min(plane.count, Self.maxInstances - first)
                guard count > 0 else { first += max(0, plane.count); continue }
                var uniforms = Uniforms(
                    viewportPx: SIMD2(Float(target.width), Float(target.height)),
                    cellPx: SIMD2(Float(atlas.cellWidthPx), Float(atlas.cellHeightPx)),
                    atlasCells: SIMD2(Float(GlyphAtlas.atlasCols), Float(GlyphAtlas.atlasRows)),
                    // Centred, in whole pixels — see GlyphAtlas.Metrics.originX.
                    originPx: SIMD2(Float(atlas.metrics.originX(forWidthPx: target.width)),
                                    Float(atlas.metrics.originY(forHeightPx: target.height)))
                        + plane.originOffsetPx)
                if let s = plane.scissorPx {
                    let x = max(0, min(s.x, target.width)), y = max(0, min(s.y, target.height))
                    enc.setScissorRect(MTLScissorRect(
                        x: x, y: y,
                        width: max(0, min(s.width, target.width - x)),
                        height: max(0, min(s.height, target.height - y))))
                } else {
                    enc.setScissorRect(full)
                }
                enc.setVertexBuffer(buffer, offset: first * MemoryLayout<Instance>.stride, index: 0)
                enc.setVertexBytes(&uniforms, length: MemoryLayout<Uniforms>.stride, index: 1)
                enc.setVertexBytes(phase, length: Self.paletteSlots * MemoryLayout<Float>.stride,
                                   index: 2)
                enc.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4,
                                   instanceCount: count)
                drawCalls += 1
                first += count
            }
        }
        enc.endEncoding()
        return drawCalls
    }

    /// Encodes and commits one frame from the staged instances. onCommit fires
    /// synchronously when the present is fully handed off (the end of the pure
    /// software path); onPresented fires with the drawable's presentedTime.
    func renderStaged(layer: CAMetalLayer,
                      planes: [Plane],
                      phase: [Float],
                      onCommit: ((Double) -> Void)? = nil,
                      onPresented: ((Double) -> Void)? = nil) {
        let buffer = instanceRing[ringIndex]
        lastBufferIndex = ringIndex
        lastPlanes = planes
        ringIndex = (ringIndex + 1) % Self.ringDepth

        guard let drawable = layer.nextDrawable() else {
            inflight.signal()
            return
        }

        let flashing = flashFramesRemaining > 0
        if flashing { flashFramesRemaining -= 1 }

        var phaseCopy = phase
        let phasePtr = UnsafeMutablePointer<Float>.allocate(capacity: Self.paletteSlots)
        defer { phasePtr.deallocate() }
        for i in 0..<Self.paletteSlots { phasePtr[i] = i < phaseCopy.count ? phaseCopy[i] : 1 }
        _ = phaseCopy

        guard let cb = queue.makeCommandBuffer(),
              let drawCalls = encodeGrid(into: cb, target: drawable.texture, buffer: buffer,
                                         planes: planes, flashing: flashing,
                                         phase: phasePtr) else {
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

    /// Re-presents the **previous** frame with a new caret phase.
    ///
    /// This is what makes an animated caret affordable in a product whose idle
    /// loop is a feature. A blink frame changes exactly one float, so it skips
    /// instance building entirely — measured at 57 µs of a ~340 µs frame — and
    /// more importantly it skips every model read that would otherwise happen
    /// sixty times a second while nobody is typing. The rest of the frame's
    /// cost (encode, commit, present) is irreducible: a pulse is frames, and
    /// frames are the price. What keeps the price bounded is that the blink is
    /// **finite** — see `GridView.caretTime`.
    @discardableResult
    func rePresentPhases(layer: CAMetalLayer, phase: [Float]) -> Bool {
        guard !lastPlanes.isEmpty else { return false }
        inflight.wait()
        let rePtr = UnsafeMutablePointer<Float>.allocate(capacity: Self.paletteSlots)
        defer { rePtr.deallocate() }
        for i in 0..<Self.paletteSlots { rePtr[i] = i < phase.count ? phase[i] : 1 }
        let buffer = instanceRing[lastBufferIndex]
        guard let drawable = layer.nextDrawable(),
              let cb = queue.makeCommandBuffer(),
              let drawCalls = encodeGrid(into: cb, target: drawable.texture, buffer: buffer,
                                         planes: lastPlanes, flashing: false,
                                         phase: rePtr) else {
            inflight.signal()
            return false
        }
        cb.addCompletedHandler { [inflight] _ in inflight.signal() }
        cb.present(drawable)
        cb.commit()
        drawCallsLastFrame = drawCalls
        return true
    }

    /// Offscreen render of the staged instances into a fresh texture — the
    /// eyes for `--screenshot`. Same instances, same shader, same blend, no
    /// window and no drawable, so it works on a machine whose display has
    /// cycled off and in CI, which has no display at all (PLAN.md §5.2).
    /// Synchronous: the texture is readable when this returns.
    func renderOffscreen(width: Int, height: Int, planes: [Plane],
                         phase: [Float] = []) -> MTLTexture? {
        let buffer = instanceRing[ringIndex]
        ringIndex = (ringIndex + 1) % Self.ringDepth
        defer { inflight.signal() }

        let offPtr = UnsafeMutablePointer<Float>.allocate(capacity: Self.paletteSlots)
        defer { offPtr.deallocate() }
        for i in 0..<Self.paletteSlots { offPtr[i] = i < phase.count ? phase[i] : 1 }

        let desc = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: Self.pixelFormat, width: width, height: height, mipmapped: false)
        desc.usage = [.renderTarget, .shaderRead]
        desc.storageMode = .shared
        guard let target = device.makeTexture(descriptor: desc),
              let cb = queue.makeCommandBuffer(),
              encodeGrid(into: cb, target: target, buffer: buffer,
                         planes: planes, flashing: false, phase: offPtr) != nil else { return nil }
        cb.commit()
        cb.waitUntilCompleted()
        return target
    }
}

import Foundation

/// **Beam's animation engine, in one array of floats.**
///
/// Every palette slot has a *phase* in `0...1` that the shader multiplies into
/// the alpha of every instance drawn in that ink. Fading a thing is therefore
/// not a property of the thing at all — it is a property of the **colour it is
/// drawn in** — and that buys three things that matter here:
///
/// - **Zero bytes per instance.** `Instance` is eight bytes and both halves of
///   its `color` word are spoken for (8 bits of ink, 8 of alpha). An animation
///   id would have had to widen it, on the keystroke path, forever. Keying off
///   the ink costs nothing because the ink is already there.
/// - **Zero branches in the shader.** One array index and one multiply,
///   replacing the special case the caret used to need. It is strictly cheaper
///   than what it generalises.
/// - **One implementation of every curve.** The caret's blink was previously
///   evaluated in the shader *and* mirrored on the CPU as a change detector,
///   and the two desynced twice in a single day (PLAN.md §5.5). The easing now
///   lives here, on the CPU, and the GPU is told a number.
///
/// **Finite by construction**, which is the rule the whole idle-CPU budget
/// rests on (§5.1): a transition has a duration, `step` reports when nothing is
/// moving any more, and the render loop stops. Nothing here can animate
/// forever unless a caller re-arms it every frame, which is what the caret does
/// deliberately and under its own finite window.
public struct Animator {
    /// One per palette slot. Matches the shader's table so an ink can index it
    /// directly with no mapping to keep in step.
    public static let slots = 64
    /// How long a transition takes. Short enough to feel like a response rather
    /// than an effect — a hover that takes longer than this reads as lag on the
    /// pointer, which is the opposite of the intent.
    public static let duration = 0.12

    /// What the shader is handed. Index by ink raw value.
    public private(set) var phase: [Float]
    private var from: [Float]
    private var to: [Float]
    private var startedAt: [Double]
    /// Slots currently in transition, so `step` costs nothing when nothing is
    /// moving — which is almost always.
    private var moving: Set<Int> = []

    public init() {
        phase = [Float](repeating: 1, count: Self.slots)
        from = phase
        to = phase
        startedAt = [Double](repeating: 0, count: Self.slots)
    }

    /// Eases a slot toward a value. Re-targeting mid-flight starts from wherever
    /// the phase actually is, so a pointer moving in and straight back out never
    /// snaps.
    public mutating func ease(_ slot: Int, to value: Float, now: Double) {
        guard slot >= 0, slot < Self.slots else { return }
        guard to[slot] != value else { return }
        from[slot] = phase[slot]
        to[slot] = value
        startedAt[slot] = now
        moving.insert(slot)
    }

    /// Sets a slot with no transition — for a phase that is itself a continuous
    /// function of time, like the caret's blink, where easing toward a moving
    /// target would be easing an easing.
    public mutating func hold(_ slot: Int, at value: Float) {
        guard slot >= 0, slot < Self.slots else { return }
        phase[slot] = value
        from[slot] = value
        to[slot] = value
        moving.remove(slot)
    }

    /// Advances every moving slot. Returns whether anything is still moving, so
    /// the render loop knows whether it may go back to sleep.
    @discardableResult
    public mutating func step(now: Double) -> Bool {
        guard !moving.isEmpty else { return false }
        var settled: [Int] = []
        for slot in moving {
            let t = (now - startedAt[slot]) / Self.duration
            if t >= 1 {
                phase[slot] = to[slot]
                settled.append(slot)
            } else {
                // Ease-out: fast to mostly-there, so it reads as a response and
                // not as motion. The same curve the peer fade uses (§5.2).
                let e = Float(t <= 0 ? 0 : 1 - (1 - t) * (1 - t))
                phase[slot] = from[slot] + (to[slot] - from[slot]) * e
            }
        }
        for slot in settled { moving.remove(slot) }
        return !moving.isEmpty
    }

    public var isAnimating: Bool { !moving.isEmpty }
    public func phase(_ slot: Int) -> Float {
        slot >= 0 && slot < Self.slots ? phase[slot] : 1
    }
}

# Beam — the beauty session: Zed-level finish, by precision, not decoration

You are continuing **Beam** (`/Users/jugalmanjeshwar/Files/code/colab`), a native macOS app whose entire product thesis is input-to-photon latency on a LAN. Before writing anything: read `PLAN.md` end to end (settled measured facts + the process), skim `perf/budgets.json`, `perf/harness-proof.md`, and your project memory.

Phases 0–2 are done and validated (gate **30 pass / 0 fail**, commits `30e02cd..5ab0661`): Metal glyph-atlas grid, hybrid event/display-link render loop, the radical-minimal shell (roster = launch screen, six-digit SAS join, editor with peer cursors and live RTT), X25519 + ChaChaPoly transport, and screen-free `--verify-session` / `--dump-scene` tooling. The UI *works* and its layout is sound. It does not yet look like a product someone would screenshot.

## The mission for this session

Make Beam **visually excellent — at the level of Zed or Linear, or beyond it** — while it remains exactly what it is: one window, one Metal grid, one instanced draw call, every pixel from the glyph atlas, zero chrome. Beauty here is not decoration; it is *precision*: text rendered perfectly, a palette that was designed rather than typed, layouts with rhythm and confidence, a window that is nothing but content. Beam's look must stay fast and fluid by construction — nothing in this session may cost the keystroke hot path a microsecond, the frame a draw call, or the idle loop a wakeup. The gates decide, as always. The distinctive move no other editor can make: the latency numbers *are* the brand — set them like jewelry, not like debug output.

## First, build the eyes (blocking everything else)

**`beam --screenshot [--surface roster|denied|pairing|editor|all] [--out dir]`** — render each surface headlessly into an offscreen Metal texture at 2× and write PNGs. Offscreen rendering needs **no window and no display**, so this is immune to the machine's screen-cycling problem (see quirks) and runs in CI. This is the session's first deliverable because visual iteration is impossible without it: screenshot → Read the PNG → adjust → screenshot again. Reuse `SceneDump`'s seeded `AppModel`s so the same states are shown; keep `--dump-scene` in sync with any layout change (it is the structural, diffable view; PNGs are for the pixels). Take a full "before" set on the current code and keep it — every workstream ends with a before/after pair.

## The workstreams, in order (each lands only with the full suite green)

1. **Typography — the single biggest visible lever.** The atlas is rasterized with `setShouldSmoothFonts(false)` and blended without gamma awareness; light-on-dark text blended in non-linear sRGB reads wrong (this is the thing Zed, terminals, and every serious text renderer handle deliberately — research "gamma-correct text blending" and macOS "font smoothing" behavior, then *measure and look*, don't cargo-cult). Also: cell metrics must land on whole device pixels end to end (`contentsScale`, drawableSize, cell width/height — any fractional accumulation blurs a grid); check descenders aren't clipped by the cell; evaluate SF Mono against the current `userFixedPitch` face; consider stroke weight on the dark ground. Atlas/font work bills to the L1 launch budget — it is gated, so a heavier atlas has to earn its cost or precompile.
2. **The window is all content.** Hide the title bar: `fullSizeContentView` + transparent titlebar + `isMovableByWindowBackground`, traffic lights overlaying the already-generous left margin (design their hover/inactive states — don't leave AppKit defaults floating on the grid). Corner radius comes free from the system. This is the change that moves it from "AppKit demo" to "product" in one diff. Verify the launch and typeable benches still hold and that bench windows still float/order correctly.
3. **A designed palette.** The current entries are programmer-picked RGB in the shader source. Design a real scale: a background with a trace of hue instead of neutral gray; fg/dim/faint as deliberate, measured contrast steps; the six peer hues equalized for perceived lightness on the dark ground (they must feel like a set); accent reserved for "beam" and the join code only. The palette lives in `Renderer.shaderSource` — annotate each entry with its intent, because that file *is* the design system. Consider whether the palette should be gamma/linear-space aware together with workstream 1 — they interact.
4. **Composition.** Roster, join code, and editor as *designed* layouts: consistent alignment grid, breathing room used with intent, the six digits centered and scaled as the typographic centerpiece of the whole product (this screen is the one users show each other). The HUD line gets designed, not appended: it is the only ornament Beam has. `--dump-scene` review + screenshot review for every layout change.
5. **Motion, only where it is free.** The fade-in machinery exists (per-instance alpha, finite by rule). Use it where arrival deserves softness; add nothing infinite, nothing that blinks, and **no easing on the caret — instant is the aesthetic**, and a sliding cursor manufactures perceived latency in the one product that exists to delete it. Anything that repaints on a recurring signal will pin the display link awake (this exact mistake cost 3.4% idle CPU in Phase 2 and was caught by the gate — read that harness-proof section before writing any animation).

## Non-negotiable process (proven three times; do not soften it)

Aesthetics aren't gateable, but regressions are: **every workstream ends with `scripts/bench.sh` fully green** — draw calls/frame, malloc/keystroke, idle CPU (foreground *and* connected), L1 launch, every L2 row unchanged or better. Where a change is measurable, budget it first in `perf/budgets.json` and prove the bench red (`BEAM_SABOTAGE_*`, `scripts/prove-red.sh`) before trusting it. Never merge red, never gate on garbage, never move a budget after seeing the data. Do not add golden-image tests — they're brittle; structure is checked by `--dump-scene`, pixels are reviewed by eye via `--screenshot`.

## Facts you must not re-derive (measured; PLAN.md has details)

- Pipeline depth is **17 ms** on the 60 Hz dev panel (Phase 1's standing target). Commit p50 ~0.4–0.7 ms — the renderer has never been the bottleneck; do not "optimize" it in the name of polish, and do not regress it either.
- The hybrid render loop in `GridView.swift` (immediate-first-input, in-frame coalescing, wake-double-present, occlusion pause, status renders that don't extend the warm window) is measured and validated — extend it, never bypass it.
- `NSWindow.occlusionState` is not a visibility oracle (never `.visible` for a non-activated app; ground truth is `presentedTime > 0`). Relevant if you touch window styling near the bench plumbing.
- Idle CPU 0.017% alone / 0.52% connected and RSS ~66 MB are *features with gates*. Nothing in Beam blinks, for this reason.
- Present mode `normal` stands; `scheduled`/`presentsWithTransaction` failed under load. Don't revisit without `scripts/present-matrix.sh` evidence.

## Environment quirks (session-blocking if forgotten)

- **The display cycles off aggressively and yields to nothing programmatic**; photon benches abort with exit 5/6 (correct behavior). `--screenshot` makes visual work immune to this — build it first. For the final gating run, wrap `scripts/bench.sh` in a retry loop and use `set -o pipefail` (piping into `tee` otherwise reports tee's status and fakes a pass).
- Build with `scripts/build.sh` (→ `.build/bin/`). Local SwiftPM is broken (CLT ManifestAPI mismatch; stale modulemap masked via VFS overlay in build.sh). CI uses SwiftPM fine.
- `NWListener` on an ephemeral port needs `allowLocalEndpointReuse = true` **and** a `newConnectionHandler`, or EINVAL.
- Local Network TCC denial has a designed UI state — keep it designed through any restyle.
- Check free disk before big work.

First actions: read the files above; write this session's plan (the workstreams + what each is gated by) into PLAN.md as §5.2 "Visual quality — design of record"; build `--screenshot` and capture the full "before" set; then typography first — it is the lever everything else sits on.

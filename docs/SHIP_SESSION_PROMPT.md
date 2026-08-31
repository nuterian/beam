# Beam — the shipping session: make it a product you could hand to a stranger

You are continuing **Beam** (`/Users/jugalmanjeshwar/Files/code/colab`), a native macOS
editor whose entire product thesis is input-to-photon latency on a LAN. Read `PLAN.md` end to
end before writing anything — especially §3 (the benchmark-driven process), §5.1–§5.7 (the
seven design-of-record sections) and §6 (phases) — then skim `perf/budgets.json`,
`perf/harness-proof.md`, `docs/shots/` and your project memory.

This prompt supersedes `PRODUCTION_SESSION_PROMPT.md` and `PHASE3_SESSION_PROMPT.md`, which are
retired with it. Where they disagree with this file, this file is right: parts of both are now
stale, and the stale parts are called out below so they are not re-derived.

## The honest position

Beam is an excellent **engine** with an excellent **shell**, and it is **not a product**. Two
sentences say why, and they fail for different reasons:

- **You cannot ship it,** because the only mode the product has does not work. §1 says "shared
  code editing is the only mode", and `AppModel.apply` says of the current implementation:
  *"That is still not a CRDT and is not pretending to be one — `yrs` lands in Phase 3."* Two
  people typing at once diverge, silently.
- **You cannot market it,** because the headline claim has never been measured. Pillar 3 is
  *"verified by camera, not just software timestamps"*; `conventions.cameraOffsetMs` is `null`,
  and `budgets.json` says in as many words that photon metrics cannot be claimed until it is
  set. Every L0 row, every L6 wired/Wi-Fi row and every 120 Hz row is **no data**. There is no
  rig. The only end-to-end numbers are loopback, which the plan correctly and repeatedly calls
  *a software floor, not a LAN number*.

Marketing is the harder half and no amount of code closes it: it is two machines, a switch, and
a calibration session.

## What has changed since the last prompt (do not re-derive these)

- **§5.7 landed** — density, weight and information. The cell is now **1:2 by derivation**
  (`cellHeight = 2 × cellWidth`, ink guard retained), zoom ships on ⌘+/⌘−/⌘0 over an eleven-step
  ladder, the rail carries filled 72 px icons, and the status line carries language, indent,
  line ending and encoding with two of them clickable. **The point size is no longer hardcoded**
  and `lineHeightEm` is an output, not an input. The old prompts' "font size is hardcoded in six
  places" and "changing the point size breaks the icon geometry" are both **resolved** —
  `--bench-text` now asserts the 1:2 cell at every zoom step and it has been proved red.
- **IME is implemented, not missing.** `GridView` conforms to `NSTextInputClient` with
  `insertText` / `setMarkedText` / `unmarkText`. The old prompts say it does not exist; that is
  stale. What is still missing is the **gate** — §7 lists "IME marked-text correctness +
  latency" and nothing measures it. Verify dead keys and a CJK composition by hand before
  trusting it.
- **`perf/results/` no longer holds the occluded-run fiction** the production prompt warned
  about. It holds valid runs at 98–99.6% present delivery.
- **The editor bench works now**, and that is why four rows are newly red — see below.
- `scripts/bench.sh` settles **3 s** between cold launches, not 1 s.

## Start here, and do not skip it: the four red rows

`scripts/gate.sh` currently reports **39 pass, 4 fail**. All four come from `--bench-editor`,
which had **never completed a run in the history of this branch** — it aborted on a path bug
before `perf-gate` ever saw these rows. Fixing the bench did not create four failures; it
revealed them. They are **not** regressions from §5.7, and that is measured, not assumed: the
numbers are identical on the pre-§5.7 commit.

```
row                              budget / gate   measured (3 independent runs)
scroll_wheel_to_presented          34 / 38       48.82  49.00  49.12
selection_drag_to_presented        34 / 38       41.63  45.62  49.15
tab_switch_to_presented            34 / 38       41.61  41.62  42.38
overlay_keystroke_to_commit         4 /  8       12.71  12.72  12.78
```

**Nothing else may merge until this is resolved, because the rule is no merge red.**

The three presented rows share one cause and it is methodological, not a slow path. Those
passes drive input **faster than the display refreshes** — scroll at 8 ms (125 Hz), drag at
16 ms, tabs at 23 ms — and the render loop coalesces within a frame and then charges that frame
its **oldest** pending input, which is the worst-case-honest accounting §5-L2 chose on purpose.
Input arriving faster than 60 Hz therefore adds close to a whole frame, systematically. That is
exactly what `burst_125hz_presented_p99_60hz_ms` exists to measure, and why it carries 44/60
instead of 34/38. The rows were given the keystroke budget on the reasoning that scrolling "is
the same present path" — true, and it quietly assumed scroll and drag arrive at keystroke rates.
A trackpad delivers 120 Hz.

Two honest options, and **argue it on the merits before looking at a number again**:

1. **Pace the passes at a rate a human generates**, and keep the budgets. Defensible for the
   tab and drag passes; harder for scroll, because 120 Hz *is* what a trackpad sends.
2. **Re-specify the rows**, the way §5.3 re-specified `launch_to_typeable_ms` — stating what
   they now mean and why, in `budgets.json`, with no budget loosened.

`overlay_keystroke_to_commit` is a different animal and is **not** about the candidate set: it
measured 12.68 against 94 candidates and 12.71 against 2,001, so filtering is not the cost. The
pass closes and reopens the overlay every eighth keystroke; look there first.

Whatever you decide, **§5.3's rule stands**: a metric is re-specified *before* numbers move and
never loosened. Write the decision into PLAN.md.

## Then, in this order

### 1. It must be impossible to lose the user's work

Still true, still unfixed, and still the worst bug in the product:

- **`AppModel.closeDocument` never looks at `isModified`.** ⌘W on a modified tab discards the
  edits with no prompt. ⌘Q likewise.
- **There is no external-modification detection.** `Document.save()` writes atomically over
  whatever is on disk; a `git checkout` or another editor's write is destroyed silently.

Both guards get **drawn in the grid, not with an AppKit sheet** — §5.4's load-bearing rule is
that no AppKit control lives inside the window, and a confirmation is a two-item list in the
overlay mechanism that already exists. Record modification date and size on open and save;
check before writing and on window activation.

### 2. `yrs` — Phase 3, and the reason there is no product without it

The L4 budgets are already written. `Edit(offset, removed, inserted)` in
`BeamCore/TextBuffer.swift` is the seam it slides into, and everything above the bytes already
updates only from that triple — local keystrokes and remote ops take the identical path, which
is what makes this a substitution rather than a second implementation.

- **Hold `yrs` to the L4 budgets before committing to it.** The predecessor's Yjs numbers —
  encode 30 µs / 18 B, apply 11 µs — are the bar. If `yrs` cannot reproduce them, that is a
  finding, not a rounding error.
- **Keep the wire budget.** Phase 2 sends 30 bytes/keystroke against a gate of 64, including an
  8-byte originating timestamp that exists so peers can display true one-way latency. A `yrs`
  update must fit the same budget; `--verify-session` is where that counter comes from.
- **Separate channels.** Doc sync over TCP (`noDelay`, already enforced everywhere); awareness
  over UDP, latest-state-wins. The op layer is already split at the type level.
- **Relay on its own thread**, with the stall-immunity bench as its regression detector
  (predecessor: ≤1.3 ms max RTT during 200 ms host main-thread stalls).
- **The occluded-peer correctness bench.** A hidden window must keep *applying* remote ops and
  repaint within one frame on reveal. Beam already renders nothing while occluded — prove the
  sync half is unaffected.
- **Awareness at 60 Hz is the obvious next thing to break idle CPU.** Anything repainting on a
  recurring signal pins the display link awake; that cost 3.4% of a core once already. Budget it
  before you build it.

### 3. The wall a real user hits in the first hour

- **There is no find.** No ⌘F, no ⌘G, no replace — `Commands.all` has eighteen entries and none
  of them search. An editor without find is not an editor. Highlight-all-matches is nearly free:
  matches are fills in an ink, and the animation engine can fade them in.
- **IME is built but unproven.** Gate it (§7 already lists the row) and try a real CJK
  composition and a dead key by hand.
- **No soft wrap** — long lines clip, horizontal scrolling exists with no affordance saying so.
  A named gap in §5.3, not an oversight: soft wrap changes what a "row" means for the caret, the
  click map and the selection at once.
- **One window, no ⌘N.**

### 4. Make the claim provable

- **The extra frame is still there.** `keystroke_to_presented_60hz_min_ms` is ~17 ms — a whole
  frame of pipeline depth between commit and glass. Cutting it has been "Phase 1's headline
  objective" since §5-L2 and **has never been attempted**. Commit p50 is 0.2–0.5 ms, so this is
  entirely present-path engineering: display-link-aligned presents timed to the compositor
  deadline, `presentsWithTransaction`, direct-to-display, ProMotion. Each lever accepted or
  rejected **by measurement**; `scripts/present-matrix.sh` exists for this. Until it lands,
  ~25 ms presented p50 on a 60 Hz panel is not a number anyone switches editors for.
- **Camera calibration.** One rig session, a 240 fps camera and `beam --flash-on-key`; see
  `docs/camera-calibration.md`. Until `cameraOffsetMs` is set, **no photon claim may be made**.
- **The rig.** Two machines, a dedicated unmanaged GbE switch, one Wi-Fi AP. Nothing has ever
  run on two machines; every collaboration number is loopback.

### 5. Make it installable

`scripts/package_app.sh` signs ad-hoc (`-`) by default with notarization behind an unset
`BEAM_NOTARIZE_PROFILE`. There is **no app icon**, no auto-update and no first-run experience. A
person handed `Beam.app` today gets a Gatekeeper warning and an untitled buffer with no idea
what to do.

## Non-negotiable process (proven six times; do not soften it)

Budget before building, prove the bench red with a `BEAM_SABOTAGE_*` hook before trusting it,
**never merge red**, **never gate on garbage**, and never move a budget after seeing the data.
If a metric's *meaning* changes, re-specify it in `budgets.json` with the reason — legitimate,
done four times; silent drift is not.

**Two loops, and use the right one.** `scripts/check.sh` is the fast one: build, headless
correctness, every surface through `--dump-scene`, every screenshot — under a minute, **no
display needed**. `scripts/gate.sh` is what you run before merging.

Keep `--dump-scene` and `--screenshot` in sync with every layout change, add each new surface to
`SceneStates`, and leave a before/after pair in `docs/shots/`. **Do not add golden-image tests.**
`--screenshot --point-size <pt>` renders any surface at any zoom step and needs no display.

## Facts you must not re-derive

- **Pipeline depth is ~17 ms**; commit p50 is **0.2–0.5 ms**. The renderer has never been the
  bottleneck. Do not "optimize" it; do not regress it.
- **`NSWindow.occlusionState` is not a visibility oracle** — it has lied five times. Ground truth
  is the present-delivery ratio (`presentedTime > 0`), and every timed bench refuses to publish
  below 90%. **Any new timed bench must do the same**: a dropped present is re-rendered carrying
  its *original* `t0`, so an occluded run looks like a regression rather than an aborted one.
- **`draw_calls_per_frame` is budget 2, gate 4, and both are spent** — the document plane (which
  carries the sub-cell scroll offset plus §5.7's tab-strip inset, and a scissor rect) and the
  chrome plane. A third plane breaches it.
- **The ASCII fast path must never go through `GlyphCache`** — a screen of code is ~3500
  characters. The cache is the *miss* path only, and zoom must evict it: its slots index a
  texture that no longer exists after a rebuild.
- **The animation engine (§5.6):** every palette slot carries a phase in `0…1` that the shader
  multiplies into alpha. Fading is a property of the *ink*. Do not add a second mechanism and
  never duplicate a curve — one curve implemented twice desynced twice in a day.
- **`malloc_bytes_per_keystroke` is noise-dominated** (−81 … +117 for identical code). Do not
  chase it.
- **Colours are designed in OKLCH, written as sRGB, and checked for gamut clipping.** `.caret`
  once documented a hue the GPU had never drawn.
- Present mode `normal` stands; `scheduled` stalled under sustained typing.
- **`DiscoveryService.pauseBrowsing()` is written and deliberately unwired** — the leading lever
  for the last ~0.1% of connected idle CPU, unmeasured, and this project does not merge
  unmeasured optimisations.

## Environment quirks (session-blocking if forgotten)

- **A macOS 14+ screensaver is rendered by `WallpaperAgent`**, so `pgrep ScreenSaverEngine` finds
  nothing while every present is dropped. Diagnose with `screencapture -x` and *look at the
  image*.
- **`caffeinate` cannot dismiss a running screensaver, and does not reliably prevent one
  either.** `gate.sh` now renews a `caffeinate -u` assertion across its own gaps, which took
  complete timed-bench runs from 0/4 to 2/4 — but a screencapture taken while that assertion was
  held caught the screensaver running anyway. **A photon bench needs an attended screen and
  there is no substitute.** Say so early rather than burning a session on retries.
- **The machine must be genuinely idle, not merely awake.** Measured on identical code minutes
  apart: presented p50 **26.16** on a quiet machine and **43.03** on a busy one, and the
  *headless* micro-benchmarks degraded with it (atlas-miss p50 7.2 → 22.4 µs). **Stop making
  tool calls while a timed bench runs** — whatever app is driving the session competes with Beam
  for activation, and activation is exclusive.
- **The idle bench's failure message is misleading.** It reports a delivery *ratio* when its real
  guard is `total < 10` presents, and it gets too few because the caret settles solid whenever
  the window is not key — so any focus steal makes it fail while blaming occlusion. Fixing that
  message is a ten-minute job that will save an hour.
- **Two Beam instances cannot both render** (activation is exclusive). Quit the app before gating.
- **Git worktrees branch from a COMMIT** — parallel agents see nothing uncommitted.
- Build with `scripts/build.sh`. Local SwiftPM is broken; `touch .build/swiftpm-broken` in a
  fresh worktree to skip the slow failing attempt.
- `NWListener` on an ephemeral port needs `allowLocalEndpointReuse = true` **and** a
  `newConnectionHandler`, or EINVAL.

## Write it down

Every decision this session makes goes into PLAN.md as **§5.8**, saying what it amends, exactly
as §5.3–§5.7 do. The plan is the product's memory; a decision that is not written there will be
re-litigated.

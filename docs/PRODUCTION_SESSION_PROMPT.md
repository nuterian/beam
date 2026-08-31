# Beam — the production session: make it trustworthy, complete, and provable

You are continuing **Beam** (`/Users/jugalmanjeshwar/Files/code/colab`), a native macOS
editor whose entire product thesis is input-to-photon latency on a LAN. Before writing
anything: read `PLAN.md` end to end — especially §3 (the benchmark-driven process), §5.1–§5.6
(the six design-of-record sections), §6 (phases) and §7 (the benchmark roadmap) — then skim
`perf/budgets.json`, `perf/harness-proof.md`, `docs/shots/`, and your project memory.

**Current branch: `phase1-editor-shell`. It has never passed the gate.** Eight commits sit on
it unvalidated, because this machine's screensaver reclaimed the display for the whole of the
previous session. That is the first thing to fix and it gates everything else (see "Start
here").

## Where Beam actually is

It is a genuinely good *engine* with a genuinely good *shell*, and it is **not yet an editor a
stranger could use for an hour without losing work or hitting a wall.** Both halves of that
sentence are true and the session is about closing the gap.

What works: a gap-buffer text model with a raw-coordinate line index (typing costs nothing at
any file size), real selection, pixel-quantized scrolling, mouse editing, undo with coalescing,
an incremental line lexer, a demand-filled glyph atlas, document tabs, a left icon rail, a
system menu bar and command palette from one command table, an animation engine, and one-gesture
X25519+SAS encrypted pairing over Bonjour.

What is missing is the subject of this prompt.

## The three changes, in priority order

### 1. It must be impossible to lose the user's work — and the gate must be green

**Beam can currently destroy a file's worth of work in one keystroke, silently.** Verified,
not guessed:

- `⌘W` (`AppModel.closeDocument`) and `⌘Q` never look at `isModified`. Close a modified tab
  and the edits are gone with no prompt.
- There is **no external-modification detection**. `Document.save()` writes atomically over
  whatever is on disk; if the file changed underneath (a `git checkout`, another editor), that
  change is destroyed with no warning.
- A remote peer's edits apply **last-writer-wins on a rope**. Two people typing in the same
  region do not converge — they corrupt. §5.1 says this honestly ("not a CRDT and not
  pretending to be one") but it is now shipping under a UI that invites collaboration.

Do all of:
- Unsaved-work guards on tab close, window close and quit. **Drawn in the grid, not with an
  AppKit sheet** — §5.4's one load-bearing rule is that no AppKit control lives inside the
  window. The overlay mechanism already exists and a confirmation is a two-item list.
- External-change detection: record the file's modification date and size on open and save;
  check before writing and on window activation; a changed file gets a designed state, never a
  silent clobber.
- **`yrs` (Phase 3).** This is where it belongs, because it is a *correctness* feature before
  it is a collaboration feature. The L4 budgets are already written; `Edit(offset, removed,
  inserted)` in `BeamCore/TextBuffer.swift` is the seam it slides into and everything above the
  bytes already updates only from that triple. Hold it to the L4 budgets before committing to it.
- **A green `scripts/gate.sh`, and replace the garbage in `perf/results/`.** The committed
  `perf/results/l2-typing.json` is from an **occluded, invalid run** — presented p99 55.04 ms
  against a validated 33.74, jitter 27.74 against 7.92, commit p99 22.94 against ~0.6. Those
  numbers are fiction, they predate the validity check that would now reject them, and the HUD
  and CI both read that file.

### 2. The wall a real user hits in the first hour

- **There is no `NSTextInputClient`.** `GridView.keyDown` reads `event.characters` directly, so
  there is no marked text, no dead keys and no IME. Option-e-é does not work. CJK is impossible.
  §1 has called this "a correctness cliff, not a nicety" since the first plan and it is now the
  single largest population of users who literally cannot type in Beam. Implement the protocol
  properly — marked text must at minimum be *correct*, even if compositions render plainly —
  and gate it (`§7` already lists "IME marked-text correctness + latency").
- **There is no find.** No `⌘F`, no `⌘G`, no replace. An editor without find is not an editor.
  It also wants the highlight-all-matches treatment, which is nearly free: matches are fills in
  an ink, and the animation engine can fade them in.
- **Font size is hardcoded `14` in six places** and there are no preferences at all. A user
  cannot make the text bigger. Note the constraint before changing it: `lineHeightEm = 1.30` is
  what makes the cell exactly **18×36 — a clean 1:2** — and the rail's icons are square paths
  drawn across *two adjacent cells* because a cell is half a square. Changing the point size
  must keep that relationship or the icon geometry breaks.
- **One window.** No `⌘N`. And no soft wrap — long lines clip; there is horizontal scrolling
  but no affordance that says so.

### 3. Make the claim provable, and make it installable

Beam's marketing is one sentence — *the fastest editor, and you can share it with the person
beside you in one gesture with nothing leaving your network* — and **neither half is currently
provable**.

- **The extra frame is still there.** `keystroke_to_presented_60hz_min_ms` is **16.6 ms**:
  a whole frame of pipeline depth between commit and glass. Cutting it has been "Phase 1's
  headline objective" since §5-L2 and has never been attempted. Commit p50 is 0.34 ms — the
  renderer has never been the bottleneck — so this is entirely present-path engineering:
  display-link-aligned presents timed to the compositor deadline, `presentsWithTransaction`,
  direct-to-display, ProMotion. Each lever accepted or rejected **by measurement**;
  `scripts/present-matrix.sh` exists for exactly this. Until this lands, 25.8 ms presented p50
  on a 60 Hz panel is not a number anyone would switch editors for.
- **`conventions.cameraOffsetMs` is still `null`,** so no photon claim can be made at all. It
  needs one rig session with a 240 fps camera and `beam --flash-on-key` (see
  `docs/camera-calibration.md`).
- **Nothing has ever run on two machines.** Every collaboration number is loopback. §8's rig is
  still hypothetical, and the L6 wired/Wi-Fi rows have never been measured.
- **It is not distributable.** `scripts/package_app.sh` has signing and notarization scaffolding
  behind `BEAM_SIGN_IDENTITY` / `BEAM_NOTARIZE_PROFILE`, but nothing is signed, there is **no
  app icon**, no auto-update, and no first-run experience. A user who is handed `Beam.app`
  today gets a Gatekeeper warning and an untitled buffer with no idea what to do.

## Non-negotiable process (proven five times; do not soften it)

Budget before building, prove the bench red with a `BEAM_SABOTAGE_*` hook before trusting it,
**never merge red**, **never gate on garbage**, and never move a budget after seeing the data.
If a metric's *meaning* changes, re-specify it in `budgets.json` with a note saying why —
that is legitimate and has been done four times; silent drift is not.

**Two loops, and use the right one.** `scripts/check.sh` is the fast one for interface and
model work: build, headless correctness, every surface laid out, every screenshot written,
under a minute, **no display needed**. `scripts/gate.sh` is what you run before merging; it
needs a visible screen and takes minutes.

Keep `--dump-scene` and `--screenshot` in sync with every layout change, add each new surface
to `SceneStates` so both tools show it, and leave a before/after pair in `docs/shots/`.
**Do not add golden-image tests.**

## Facts you must not re-derive

- **Pipeline depth is ~17 ms** on the 60 Hz dev panel — one extra frame between commit and
  glass. Commit p50 is **0.34 ms**: the renderer has never been the bottleneck. Do not
  "optimize" it; do not regress it.
- **`NSWindow.occlusionState` is not a visibility oracle.** It has now lied four times. Ground
  truth is the **present-delivery ratio** (`presentedTime > 0`); `--bench-typing`, `--bench-join`,
  `--bench-editor` and `--bench-idle` all refuse to publish below 90%. **Any new timed bench
  must do the same** — an occluded run does not merely lose samples, because a dropped present
  is re-rendered carrying its *original* `t0`, so the run looks like a regression rather than
  like an aborted run.
- **The animation engine (§5.6)**: every palette slot carries a phase in `0…1` and the shader
  multiplies it into alpha. Fading is a property of the *ink*, not of the thing. Zero bytes per
  instance, zero branches. Easing lives on the CPU (`BeamCore/Animator.swift`); the GPU is
  handed a number. Do not add a second animation mechanism, and do not duplicate a curve — one
  curve implemented twice desynced twice in a single day.
- **The ASCII fast path must never go through `GlyphCache`.** A screen of code is ~3500
  characters and a dictionary lookup on each costs more than the entire commit path. The cache
  is the *miss* path only.
- **`draw_calls_per_frame` is budget 2, gate 4, and both are spent** — the document plane
  (which carries the sub-cell scroll offset and a scissor rect) and the chrome plane. A third
  plane breaches the budget.
- **`malloc_bytes_per_keystroke` is noise-dominated**: the same code has measured −81, −1.4,
  +8.6, +29, −25 and +117. Do not chase a hundred-byte "regression"; it cannot be resolved.
- Present mode `normal` stands. `scheduled` stalled under sustained typing; don't revisit
  without `scripts/present-matrix.sh` evidence.
- **Palette entries must be checked for gamut clipping.** `.caret` declared L 0.930 / C 0.075 /
  H 225 and actually rendered at H 210 because `#B1F3FF` clips blue — the design table
  documented a colour the GPU had never drawn.

## Environment quirks (session-blocking if forgotten)

- **Run the gate with `scripts/gate.sh`, never `bench.sh`.** It pre-flights with
  `beam --verify-launch` (cheap: exits the instant a frame is presented), retries only
  screen-aborted runs (exit 5/6) with a cool-down, and fails immediately on anything else.
- **On macOS 14+ a screensaver is rendered by `WallpaperAgent`, not `ScreenSaverEngine`**, so
  `pgrep ScreenSaverEngine` finds nothing while every present is dropped. `caffeinate`,
  `killall WallpaperAgent` and synthetic input do **not** dismiss one that has already started —
  only a human at the machine does. Diagnose with `screencapture -x` and *look at the image*.
  **If the screen is unavailable, say so early and loudly rather than burning the session on
  retries** — `scripts/check.sh` needs no display and covers most work.
- **Two Beam instances on one machine cannot both render** (activation is exclusive). Quit any
  running app before gating.
- **Git worktrees branch from a COMMIT** — parallel agents see nothing uncommitted. Commit
  before fanning out.
- Cold relaunches are throttled: five `--bench-launch` processes back to back land 1–3 and time
  out on 4. `bench.sh` has a 1 s settle gap for this.
- Build with `scripts/build.sh` (→ `.build/bin/`). Local SwiftPM is broken (CLT ManifestAPI
  mismatch; stale modulemap masked via VFS overlay). CI uses SwiftPM fine. `touch
  .build/swiftpm-broken` to skip the slow failing attempt in a fresh worktree.
- `NWListener` on an ephemeral port needs `allowLocalEndpointReuse = true` **and** a
  `newConnectionHandler`, or EINVAL.
- Check free disk before big work.

## Start here

1. **Get the gate green before writing a line of feature code.** Ask the human to keep the
   screen awake, run `scripts/gate.sh`, and read every row. Some rows *will* have moved —
   `draw_calls_per_frame` is 1 → 2 deliberately, and `caret_blink_cpu_pct_core` measured 0.731%
   against a 0.5% budget and a 1.0% gate. Report what moved; do not re-budget anything.
2. Then change 1, then 2, then 3 — each landing only with the full suite green.
3. Write the session's decisions into PLAN.md as **§5.7** and say what they amend, exactly as
   §5.3–§5.6 do. The plan is the product's memory; a decision that is not written down there
   will be re-litigated.

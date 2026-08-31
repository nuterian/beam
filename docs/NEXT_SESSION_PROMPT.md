# Beam — the UI session: make it read like a mature editor

You are continuing **Beam** (`/Users/jugalmanjeshwar/Files/code/colab`), a native macOS
editor whose product thesis is input-to-photon latency on a LAN. Read `PLAN.md` end to end
first — especially §3 (the benchmark-driven process) and §5.2–§5.6, the six design-of-record
sections — then skim `perf/budgets.json`, `perf/harness-proof.md` and `docs/shots/`.

**Branch: `phase1-editor-shell`. It has never passed the gate** (see "Start here"). The
broader production work is shelved under `docs/PRODUCTION_SESSION_PROMPT.md` and is still the
right list *after* this one — this session is narrower and is about how the product reads.

## The brief

The owner put Beam side by side with VS Code and asked for four things, in these words:
**proper use of whitespace, zoom in/out support on content, larger/bolder menu icons, a more
meaningful status bar below.** The underlying complaint is that Beam currently looks like a
very clean *prototype* next to something that looks like a *tool*.

Beam is not trying to become VS Code — §5.3 and §5.4 are explicit that it removes chrome and
keeps the window all content. The gap to close is **density, weight and information**, not
panels.

## The load-bearing constraint you must resolve first

**The cell is 18×36 device pixels at 14 pt / 2×, which is exactly 1:2 — and the rail's icons
are square paths drawn across *two adjacent cells* precisely because a cell is half a square.**
That ratio is an accident of the point size. Measured:

```
11pt: cell 14x29   2w=28 != h   BREAKS
12pt: cell 15x31   2w=30 != h   BREAKS
13pt: cell 17x34   2w=34 == h   holds
14pt: cell 18x36   2w=36 == h   holds     <- today
15pt: cell 19x39   2w=38 != h   BREAKS
16pt: cell 20x42   2w=40 != h   BREAKS
18pt: cell 23x47   2w=46 != h   BREAKS
```

So **zoom cannot ship until this is decided**, and it is a real design decision, not a
detail. Two honest options:

1. **Derive `cellHeightPx = 2 * cellWidthPx`** and let `lineHeightEm` become a *checked
   consequence* rather than an input. Every size keeps the 1:2 grid, every icon keeps working,
   and line height varies slightly with size. Note §5.2's rule survives either way: the cell
   must still clear the font's real ink extents (SF Mono's `|` overshoots its own declared
   descent), so the derived height needs the same `max(...)` guard.
2. **Stop assuming 1:2 in the icon geometry** — draw icons into `min(2 * cellW, cellH)`
   centred in the two-cell box. Simpler, but icons then shrink relative to the text at some
   sizes and the rail's rhythm drifts.

Pick one, write down why in PLAN.md, and be aware that whichever you pick, **every shape glyph
is affected** — the dividers, the caret, the chip, the rail icons and the tab accent bar are
all drawn from `scale`-derived sizes in `GlyphAtlas.init`.

## The four changes

### 1. Zoom the content (⌘+ / ⌘− / ⌘0)

`pointSize: 14` is hardcoded in **six** places: `AppDelegate`, `Screenshot`, `SceneDump`,
`SceneStates` (×2) and `TextBench`. Make it one owned value.

Changing it at runtime means **rebuilding the glyph atlas** — all 95 ASCII glyphs, every shape
glyph, and evicting every demand-filled slot in `GlyphCache` (its `scalarForSlot` map becomes
stale garbage the moment the cell size changes; that is a correctness bug, not a cosmetic one).
Then every layout constant re-derives, the scroll offset must be rescaled so the same line
stays under the caret, and the tracking areas must be rebuilt.

Budget it before you build it, per §3: **`zoom_step_to_presented_ms`**, and hold the L2
keystroke rows unchanged at every zoom level — a bigger font must not make typing slower.
Sensible steps are the ones above; consider snapping to sizes the 1:2 grid likes if you take
option 1's alternative.

### 2. Larger, bolder rail icons

They are outlines at `iconStroke = max(2, scale * 1.5)` = 3 device px inside a 26 px box, in a
72 px (36 pt) column. VS Code's activity bar is **48 pt wide with ~24 pt icons**, and its icons
read as solid marks rather than as line drawings. At Beam's size a 3 px outline reads as
dithering.

Widen the rail (5–6 cells), make the icons substantially heavier — consider **filled silhouettes
rather than strokes**, which is what actually reads at this scale — and re-check them in
`--screenshot --surface atlas`, which draws the atlas itself. Keep the peer-colour treatment:
the peers icon takes a *peer's* colour when someone is nearby, which is how the rail carries
presence in the same language as the status line (§5.2's identity set).

### 3. Whitespace

The screenshot comparison is mostly about air. Concretely: the gap between the gutter and the
code, the padding inside a tab, the inset of the status line's contents, the rail's margins,
and the overlay's row rhythm. Beam sets almost all of these to 1 or 2 cells because a cell was
the only unit available — but a **sub-cell inset is available now**: a plane can carry a
whole-pixel origin offset (that is how pixel-quantized scrolling works), so chrome can be
inset by pixels rather than by whole cells. Use it, and keep every offset a whole device pixel.

### 4. A status bar that means something

Today: `7:3  2 selected` on the left, live latency on the right. That is two facts. VS Code
shows line/column, indentation, encoding, language, and problem counts, and **every one of them
is a button**.

Add what Beam actually knows and is currently hiding: the **language** (the lexer already
resolved it), the **encoding**, the **indentation** (tabs vs spaces and the width — `Document`
knows `tabWidth`), and the **line ending**. Make the segments clickable where clicking means
something, using the overlay mechanism that already exists for pickers. Keep the latency
readout exactly where it is and exactly as prominent — **it is the brand, and no other editor
can print it.**

Give the bar a real rhythm: today's spacing is 1/2/3 cells with no system, which §5.2 already
calls out as the difference between an instrument and debug output.

## How to work

**Use `scripts/check.sh`, not the gate, for the loop.** Build, headless correctness, every
surface laid out through `--dump-scene`, every screenshot written — under a minute, **no display
needed**. Change → build → screenshot → *look* → judge → change again, and take many turns.
`--screenshot` renders offscreen with no window, so it works even when the machine's screen is
unavailable, which it frequently is.

Then `scripts/gate.sh` before merging, and only then.

Add any new surface or state to `SceneStates` so both tools show it. A state may pin animation
phases (that is how `hover-tab` and `hover-rail` are visible at all). **Do not add golden-image
tests** — pixels are reviewed by eye, structure is gated by `--dump-scene`.

## Invariants that are load-bearing, not stylistic

- **No AppKit control inside the window.** The menu bar and the right-click `NSMenu` are the
  only exceptions, and only because a menu is its own window. Everything drawn inside is
  instances from one glyph atlas. This is what keeps the UI two draw calls and idle CPU at
  0.004% of a core.
- **`draw_calls_per_frame` is budget 2, gate 4, and both are spent** — the document plane
  (sub-cell scroll offset plus a scissor rect) and the chrome plane. A third breaches it.
- **Whole device pixels everywhere.** A fractional origin makes every quad sample across its
  atlas cell's edge; that shipped once as a one-pixel seam through the join code.
- **The animation engine (§5.6):** every palette slot carries a phase in `0…1` that the shader
  multiplies into alpha. Fading is a property of the *ink*. Zero bytes per instance, zero
  branches, easing on the CPU in `BeamCore/Animator.swift`. Use it for anything that moves; do
  not add a second mechanism, and never duplicate a curve constant — one curve implemented
  twice desynced twice in a single day.
- **The ASCII fast path must never go through `GlyphCache`** — a screen of code is ~3500
  characters and a dictionary lookup on each costs more than the whole commit path.
- **Colours are designed in OKLCH, written as sRGB, annotated with measured contrast, and
  checked for gamut clipping.** `.caret` once declared H 225 and actually rendered H 210
  because the hex clipped blue — the table documented a colour the GPU never drew.

## Facts you must not re-derive

- Pipeline depth is ~17 ms on the 60 Hz dev panel (one extra frame between commit and glass);
  commit p50 is 0.34 ms. The renderer has never been the bottleneck.
- **`NSWindow.occlusionState` is not a visibility oracle** — it has lied four times. Ground
  truth is the present-delivery ratio; all five timed benches refuse to publish below 90%. Any
  new timed bench must do the same.
- `malloc_bytes_per_keystroke` is noise-dominated (−81 … +117 for identical code). Do not
  chase it.
- The live HUD reads the same `perf/budgets.json` CI does, which is why it turns red — a
  recent screenshot showed p50 46.6 / p99 49.8 against a 34 ms budget. Find out whether that
  is the occluded-screen drop-recovery or a real regression **before** changing anything
  visual, because it will confuse every judgement you make if it is real.

## Environment (session-blocking if forgotten)

- **A macOS 14+ screensaver is rendered by `WallpaperAgent`.** `caffeinate`, `killall` and
  synthetic input do not dismiss one that has started — only a human at the machine. Diagnose
  with `screencapture -x` and *look at the image*. If the screen is gone, say so early and work
  through `scripts/check.sh`, which needs no display.
- `scripts/gate.sh` pre-flights with `beam --verify-launch` and retries only exit 5/6.
- **Two Beam instances cannot both render** (activation is exclusive) — quit the app before gating.
- **Git worktrees branch from a COMMIT**; parallel agents see nothing uncommitted.
- Build with `scripts/build.sh`. Local SwiftPM is broken; `touch .build/swiftpm-broken` in a
  fresh worktree to skip the slow failing attempt.

## Start here

1. **Run `scripts/gate.sh` and get it green before any visual work.** Eight-plus commits are
   unvalidated. Expect two rows to have moved deliberately: `draw_calls_per_frame` 1 → 2, and
   `caret_blink_cpu_pct_core` at 0.731% against a 0.5% budget and a 1.0% gate. **Report what
   moved; do not re-budget anything.**
2. Resolve the 1:2 cell question above, in writing, before touching zoom.
3. Then 1 → 2 → 3 → 4, each landing with `scripts/check.sh` clean and the gate green.
4. Write the session's decisions into PLAN.md as **§5.7**, saying what they amend, exactly as
   §5.3–§5.6 do. A decision that is not written there will be re-litigated.

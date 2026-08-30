# Beam — Phase 2: the radical-minimal shell and one-gesture collaboration

You are continuing **Beam** (`/Users/jugalmanjeshwar/Files/code/colab`), a native macOS app whose entire product thesis is input-to-photon latency on a LAN. Before writing anything: read `PLAN.md` end to end (it holds the settled measured facts and the process), skim `perf/budgets.json`, `perf/harness-proof.md`, and your project memory. Phase 0 is done and validated (gate 22 pass / 0 fail, commits `30e02cd..42283a5`): Metal glyph-atlas grid, hybrid event/display-link render loop, Bonjour presence, TCP/discovery benches, packaged-app verification, live HUD.

## The mission for this session

Build the **radical-minimal UI and one-gesture secure collaboration** (PLAN Phase 2, pulling in whatever slice of Phase 1 editing it needs) — the app should make two macOS users on the same network collaborating on code feel *inevitable*: launch → see each other → one gesture → typing together. Add delight, but Beam's kind of delight: speed you can feel, softness nowhere, zero chrome.

**Design brief (hard constraints):**
- No menus (beyond ⌘Q), no toolbars, no panels, no preferences window. It should look *wrong* next to VS Code clones.
- The launch screen IS the peer list: your identity + everyone nearby, rendered on the same Metal grid aesthetic (glyph-atlas everything; the atlas supports what you add to it). Alone on the network is a designed state, not an empty state.
- **One-gesture join:** click a peer (or press their number) → a short human-verifiable code appears on both screens (host confirms / guest types it — design this well; it derives the session PSK → encrypted transport via Network.framework TLS-PSK or Noise). Target: discovery → connected & editing ≤ 1 s wired (budget exists, L5).
- Delight ideas to consider (each must survive the perf gates): cursor/peer colors with names that fade in softly, a connection moment that *feels* instant (sub-frame visual acknowledgment), latency-as-UI (each peer's live RTT shown subtly — we're the only app confident enough to display it), keystroke-perfect remote cursors. Animations only if they cost zero on the keystroke hot path and idle CPU stays ≤ 0.1% (gated).
- Local editing improvements as needed (cursor movement, selection, scrolling on the grid) — but full rope/file-IO is Phase 1 territory; don't gold-plate it before the collaboration gesture works. Hardware-keyboard Latin input only; IME correctness is a planned later milestone.

## Non-negotiable process (proven twice now; do not soften it)

Benchmark-driven development, exactly as PLAN.md §3: budget first in `perf/budgets.json` → prove the bench can go **red** (sabotage hooks `BEAM_SABOTAGE_*`; record in `perf/harness-proof.md`) → build → gate. Never merge red, never gate on garbage. New work this session needs at minimum: join-gesture time bench (gesture → encrypted session → first shared keystroke rendered both sides), peer-list appearance bench (launch → peers visible, L1 budget exists), and deterministic counters for anything new on the hot path. Percentiles and max, never averages. `scripts/bench.sh` is the one command; keep it that way.

## Facts you must not re-derive (measured; PLAN.md has details)

- Pipeline depth is **17 ms** on the 60 Hz dev panel (one extra frame between commit and glass) — the standing Phase-1 target. Don't chase render-side micro-wins; commit p50 is 0.72 ms.
- WindowServer **drops all presents from occluded windows** and drop callbacks arrive late; the hybrid render loop in `GridView.swift` (immediate-first-input, in-frame coalescing, wake-double-present, occlusion pause + instant reveal) already handles this — extend it, don't bypass it.
- `scheduled`/`presentsWithTransaction` present modes: tried, failed/unproven under load; default `normal` stands until `scripts/present-matrix.sh` on new evidence.
- Transport is never the LAN bottleneck (43 µs loopback echo, 0 Nagle spikes) — but every new socket gets `noDelay` and rides the existing gates. Doc sync = TCP, awareness = UDP, separate channels (Phase 3 wiring, but don't preclude it).
- Idle CPU 0.026% / RSS 65.6 MB are *features* with gates; the display link pauses when quiet — keep it that way through all UI work.
- Benches need a visible screen; this machine's screensaver cycles aggressively and yields to nothing programmatic — the occlusion guards (exit 5/6) are correct behavior, not bugs.

## Environment quirks (session-blocking if forgotten)

- Build with `scripts/build.sh` (→ `.build/bin/`). Local SwiftPM is broken (mismatched CLT ManifestAPI; also a stale `module.modulemap` masked via VFS overlay inside build.sh). CI uses SwiftPM fine. Durable fix needs sudo: reinstall Command Line Tools.
- `NWListener` on an ephemeral port needs `allowLocalEndpointReuse = true` **and** a `newConnectionHandler` set, or it fails EINVAL.
- Local Network TCC permission gates discovery; denial must surface in the UI, never look like an empty network.
- Disk was nearly full on 2026-08-30 — check before big work.

First actions: read the files above, then write this session's plan (UI/gesture design + its budgets + bench list) into PLAN.md as the Phase 2 section detail, prove the first new benchmark red, and build.

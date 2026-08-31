# Beam — Phase 3: multiplayer editing that survives the rig

You are continuing **Beam** (`/Users/jugalmanjeshwar/Files/code/colab`), a native macOS app whose entire product thesis is input-to-photon latency on a LAN. Before writing anything: read `PLAN.md` end to end (settled measured facts + the process), skim `perf/budgets.json`, `perf/harness-proof.md`, and your project memory.

Phases 0–2 are done and validated (gate **30 pass / 0 fail**, commits `30e02cd..5ab0661`): Metal glyph-atlas grid, hybrid event/display-link render loop, Bonjour presence, the radical-minimal shell (roster = launch screen, six-digit SAS join, editor with peer cursors and live RTT), X25519 + ChaChaPoly transport, packaged-app verification, and a screen-free `--verify-session` / `--dump-scene` pair that runs in CI.

## The mission for this session

**Real multiplayer editing** (PLAN Phase 3): `yrs` over TCP for the document, awareness over UDP, relay on its own thread, and the correctness benches that make a hidden or slow peer a non-event. The Phase 2 grid is a deliberate placeholder — last-writer-wins on a cell, one session at a time — and replacing it is this phase's job, without moving any L2 number.

Priorities, in order:

1. **`yrs` via C FFI, held to the L4 budgets before it is committed to.** The predecessor's Yjs numbers (encode 30 µs / 18 B, apply 11 µs) are the bar; if `yrs` cannot reproduce them, that is a finding, not a rounding error.
2. **Keep the wire budget.** Phase 2 sends 30 bytes/keystroke (gate 64) including an 8-byte originating timestamp that exists so peers can display true one-way latency. A `yrs` update must stay inside the same budget, and `--verify-session` is where that counter comes from.
3. **Separate channels.** Doc sync = TCP (`noDelay`, already enforced on every socket); awareness = UDP, latest-state-wins. The op layer is already split at the type level; the transport split is yours.
4. **Relay on its own thread/event loop**, with the stall-immunity bench as its regression detector (predecessor: ≤1.3 ms max RTT during 200 ms host main-thread stalls).
5. **The occluded-peer correctness bench.** A hidden window must keep *applying* remote ops and repaint within one frame on reveal. Beam already renders nothing while occluded — prove the sync half is unaffected.
6. **N-peer**, if the above holds: Phase 2 accepts one session and rejects the rest.

## Non-negotiable process (proven three times now; do not soften it)

Budget first in `perf/budgets.json` → prove the bench can go **red** (`BEAM_SABOTAGE_*`; `scripts/prove-red.sh`) → build → gate. Percentiles and max, never averages. Never merge red, never gate on garbage, and never move a budget after seeing the data — two rows currently sit inside their gate and above their design budget, and they stay that way (PLAN §5.1) precisely because that ordering is the point.

## Facts you must not re-derive (measured; PLAN.md has details)

- **Pipeline depth is 17 ms** on the 60 Hz dev panel — one extra frame between commit and glass, still the standing Phase-1 target. Commit p50 is 0.4–0.7 ms; the renderer has never been the bottleneck. The loopback E2E p99 (40.5 ms) is *this same extra frame showing up a second time* — it will come down when pipeline depth does, not by touching transport.
- **Transport and crypto are not measurable next to frame quantization.** Loopback echo 43 µs; handshake 0.47 ms; keystroke → remote presented is within single-digit ms of the *local* present path. Hold transport to its gates so it never regresses into mattering; do not gold-plate it.
- **`NSWindow.occlusionState` is not a visibility oracle** — macOS only reports `.visible` for a window whose app has *activated*, and activation is exclusive, so in any multi-process bench the inactive side reports itself occluded forever and renders nothing. Ground truth is `presentedTime > 0`; `GridView.assumeVisible` plus a present-delivery ratio is how the join bench stays honest. You will need this again for a three-process bench.
- **Anything that repaints on a recurring signal will pin the display link awake and destroy idle CPU** (measured 3.4% before fixing; now 0.52%). Status repaints must not extend the loop's warm window. Nothing in Beam blinks, for this reason. Awareness at 60 Hz is the obvious next thing to violate this — budget it before you build it.
- **The leading lever for the last ~0.1% of connected idle CPU** is stopping `NWBrowser` while a session is live. `DiscoveryService.pauseBrowsing()/resumeBrowsing()` exist and are deliberately not wired up, because the display went dark before it could be measured.
- `scheduled` / `presentsWithTransaction` present modes: tried, failed/unproven under load; default `normal` stands until `scripts/present-matrix.sh` produces new evidence.

## Environment quirks (session-blocking if forgotten)

- **The display cycles off aggressively and yields to nothing programmatic** (`caffeinate`, IOPMAssertion, synthetic input — none of it works). Photon benches then abort with exit 5/6, which is *correct behavior, not a bug*. Wrap `scripts/bench.sh` in a retry loop, and use `set -o pipefail` — piping into `tee` reports tee's status and will cheerfully report a failed suite as passing.
- Build with `scripts/build.sh` (→ `.build/bin/`). Local SwiftPM is broken (mismatched CLT ManifestAPI; a stale `module.modulemap` is masked via VFS overlay inside build.sh). CI uses SwiftPM fine. Durable fix needs sudo: reinstall Command Line Tools.
- `NWListener` on an ephemeral port needs `allowLocalEndpointReuse = true` **and** a `newConnectionHandler`, or it fails EINVAL.
- Local Network TCC permission gates discovery; denial must surface in the UI, never look like an empty network (there is a designed state for it — keep it).
- Check free disk before big work.

First actions: read the files above, write this session's plan (the `yrs` evaluation gates + the awareness/relay budgets + the bench list) into PLAN.md as the Phase 3 section detail, prove the first new benchmark red, and build.

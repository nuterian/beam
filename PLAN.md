# Beam — Plan

**Beam** is a native macOS app for LAN collaboration on code, obsessed with input-to-photon latency. Two or more people on the same network open the app, see each other within a second, connect in one gesture, and type on a shared document with latency so low it feels like one machine.

Beam is the successor to Collev (`/Users/jugalmanjeshwar/Files/code/collev`, Electron + CodeMirror 6 + Yjs). Collev produced real measurements; Beam inherits them as settled facts (§4) and goes where Electron cannot: the present path, frame scheduling, and the commit→photon tail.

**Two non-negotiable theses:**

1. **Performance is the product.** A deep, unreasonable obsession with latency at every layer yields a product that feels categorically different from anything cloud-based. A regression is a bug, not a tradeoff.
2. **Benchmark-driven.** Every layer has a measured budget, every budget has a CI gate, and no feature is built before the benchmark that measures it exists and has been proven to fail. (§3)

## 1. Product pillars

1. **Instant presence.** Launch → other Beam devices on the LAN appear within ~1 s. No accounts, no cloud, no sign-in. Works air-gapped.
2. **One-gesture secure connection.** One action plus a short human-verifiable confirmation (short join code shown on the host, typed or confirmed on the guest → PSK-derived encrypted transport). No certificates, nothing leaves the network.
3. **Input-to-photon supremacy.** Every keystroke, cursor move, and selection renders locally and on every peer faster than any competing product can physically achieve — verified by camera, not just software timestamps.
4. **Radical UI minimalism.** Beam removes UI. No menus/toolbars/panels. Collaborating within seconds of launch. It should look *wrong* in a lineup of VS Code clones.

Shared code editing is the only mode. The architecture must not preclude future surfaces (canvas, other collaboration modes), but nothing speculative is built for them.

**Scope honesty (the price of leaving the browser, accepted deliberately):** start monospace-grid, LTR, hardware-keyboard Latin input. IME (dead keys, CJK) is an *early, planned milestone* — it is a correctness cliff, not a nicety. Bidi and accessibility are explicit later milestones. Anything that isn't the hot monospace grid goes through a CoreText shaping path. Non-macOS platforms are out of scope, in writing, forever-until-revisited; in exchange we exploit every Apple-specific advantage: Metal, ProMotion, Network.framework, Bonjour, AWDL, `NSEvent.timestamp` (IOHID-derived), `powermetrics`.

## 2. Stack (defaults; each falsifiable only by benchmark)

| Concern | Choice | Notes |
|---|---|---|
| Language/UI | Swift, minimal AppKit shell | No storyboard/xib. One window, one Metal layer. |
| Rendering | Metal into `CAMetalLayer`; glyph-atlas monospace grid (Zed/GPU-terminal approach); CoreText shapes/rasterizes into the atlas | `maximumDrawableCount = 2`, `framebufferOnly`. Presents-with-transaction and direct-to-display are *camera-decided*, not blog-decided. Event-driven rendering while idle (no display link ⇒ idle CPU ≈ 0); refresh-rate-aware loop with late input sampling once continuous animation exists. |
| Input | `NSEvent.timestamp` (IOHID-derived, mach/`systemUptime` domain) as t0 | Captures pre-app queueing the predecessor couldn't see. Same clock domain as `CAMetalDrawable.presentedTime` — directly comparable. |
| CRDT | `yrs` via C FFI | Same wire format and proven costs as Yjs; held to the predecessor's L4 budgets *before* commitment. |
| Networking | Network.framework. `NWListener`/`NWBrowser` + Bonjour (`_beam._tcp`) for discovery; TCP + `noDelay = true` for doc sync; UDP for awareness | AWDL (`includePeerToPeer`) evaluated for AP-less sessions **only after** measuring its latency variance. |
| Security | Join code → PSK → TLS-PSK (or Noise) on Network.framework | Human-verifiable, no certificates, no accounts. |
| macOS gotcha owned in Phase 0 | Local Network TCC permission | Trigger the prompt intentionally at first launch, detect denial, degrade with a "fix in Settings" path. Otherwise: "discovery silently finds nothing" on exactly one tester's machine. |

Toolchain reality: built with SwiftPM + Command Line Tools (no full Xcode required); Metal shaders are runtime-compiled from source — cost is inside the launch budget, so it's measured, and precompiled `metallib` is the known fix if it ever breaches.

## 3. Process: benchmark-driven development (proven on Collev; followed exactly)

For every unit of work, in this order:

1. **Write the benchmark and its budget** into `perf/budgets.json` (machine-readable; human digest in this plan).
2. **Prove the harness works**: run against a stub or deliberately slowed implementation (`BEAM_SABOTAGE_*` env vars exist for exactly this) and confirm it **fails**. A benchmark that has never gone red is not a benchmark.
3. **Build the feature.**
4. **Gate it in CI** from that commit forward. No merge with a red gate.

Phase 0 is a *walking skeleton* — window + Metal grid + keystroke echo + Bonjour + TCP echo — that exists solely to be measured. The harness is built against it before any feature work.

### 3.1 Measurement rules (validated on the predecessor; verbatim)

- **Percentiles and max, never averages.** p50 / p95 / p99 / p99.9 / max. The tail is the user experience.
- **Clock-sync-free cross-machine latency** via round-trip decomposition: sender measures RTT wholly on its own clock; receiver measures receive→frame-commit (`d_B`) wholly on its own clock and acks it; `E2E ≈ RTT/2 + d_B`. Never compare timestamps across machines.
- **Camera calibration, once per rig.** Software sees "committed/presented," not photons. Film both screens with a 240 fps phone camera during scripted typing (`beam --flash-on-key` exists for this), count frames, derive the constant software→photon offset, record it in `budgets.json` (`conventions.cameraOffsetMs`), then trust software numbers. On a native app the compositor→scanout tail is exactly the territory we compete in, so this matters more, not less.
- **Deterministic counters first** — exact, flake-free: bytes on wire per keystroke, allocations per keystroke on the hot path (budget 0 steady-state), draw calls per frame, syscalls per keystroke, dylibs linked, binary size.
- **Statistical discipline:** N ≥ 1000 micro / ≥ 300 E2E, warmup discarded, median-of-runs, baseline-commit comparison (catch 5% creep) *and* absolute thresholds. Timing gates only on dedicated hardware; shared CI runners get wide-tolerance 2×-regression gates only.
- **Loopback is a software floor, not a LAN number.** Real numbers need the rig: two machines on a dedicated unmanaged GbE switch + one Wi-Fi AP. Measure the L0 floor per rig (`ping`/`irtt`, `iperf3`); everything above it is reported as *our overhead*.
- **Living instrumentation:** the in-app HUD reads the same `perf/budgets.json` as CI and shows live p50/p99 input latency, per-peer E2E/RTT, bytes/s, dropped frames — red the moment a live number exceeds budget. Regressions are *felt during development*.

### 3.2 Harness mechanics

- `perf/budgets.json` is the single source of truth (gate script + HUD both read it).
- Benchmarks only measure; they emit flat `{"Lx_group.metric": value}` JSON into `perf/results/`. The gate (`swift run perf-gate`) is the one place that judges. `--require-all` once a phase is fully instrumented.
- `scripts/bench.sh` runs every Phase-0 bench and the gate in one command.
- Sabotage hooks (each proves a gate can go red): `BEAM_SABOTAGE_KEY_DELAY_MS` (keystroke hot path), `BEAM_SABOTAGE_NO_NODELAY=1` (disables `noDelay` → Nagle/delayed-ACK spikes), `BEAM_SABOTAGE_LAUNCH_DELAY_MS` (launch path), `BEAM_SABOTAGE_JOIN_DELAY_MS` (stalls the pairing handshake after key agreement), `BEAM_SABOTAGE_PEER_LIST_DELAY_MS` (delays putting a discovered peer on the glass). `scripts/prove-red.sh` re-runs the proofs on demand — a gate's sensitivity should be re-checkable, not just attested once. Proof runs are recorded in `perf/harness-proof.md`.
- `beam --dump-scene` prints every UI surface as ASCII (no Metal, no window, no display): the UI is instance data, so its layout is inspectable in CI and reviewable in a diff.
- `beam --verify-session` is the headless half of Phase 2: it checks that honest peers derive the same six digits, that a machine-in-the-middle's two legs derive *different* ones, that ops survive the ChaChaPoly round trip intact, and it is the deterministic source of `bytes_per_keystroke_on_wire`. No screen required, so unlike every timing bench it runs on a shared CI runner.
- **Packaged-app verification from Phase 0, in CI:** `scripts/package_app.sh` builds `Beam.app`; `scripts/verify_app.sh` executes the binary *directly* (captures the stderr a GUI launch swallows) and requires the `BEAM_LAUNCH_OK` sentinel. The predecessor's packaged build silently failed to boot for weeks; never again. Codesign/notarize scaffolding behind `BEAM_SIGN_IDENTITY` / `BEAM_NOTARIZE_*` env vars early.

### 3.3 CI topology

- **Tier 1 — every PR** (GitHub-hosted mac runner): build, deterministic counters (binary size, linked dylibs, draw calls, bytes/keystroke), pairing + encrypted-transport verification (`--verify-session`, headless), packaged-launch verification, gate over committed results with wide 2× tolerances only.
- **Tier 2 — pre-merge + nightly** (self-hosted rig): full timing matrix wired + Wi-Fi, absolute gates, trend dashboard.
- **Tier 3 — weekly**: soak, energy (`powermetrics`), N-peer load.

## 4. Settled empirical facts (from Collev; do not re-litigate without new measurements)

1. **Frame quantization dominates.** 60 Hz keystroke→paint floor was 8.7 ms ≈ half a frame, ~92% of total latency; CodeMirror cost 0.7 ms. The renderer was never the bottleneck below the frame boundary. ⇒ Beam's native rewrite is justified only by what native uniquely controls — present path, 120 Hz scheduling, input sampling, commit→photon tail. Instrument those first.
2. **The display is the biggest lever and it's free.** 120 Hz halves quantization (~8.3 → ~4.2 ms) — ~8–16× any renderer-rewrite win. Target ProMotion day one; the dev machine (M4 Air) is 60 Hz, so 120 Hz budgets gate on the rig.
3. **Transport never bottlenecks a LAN.** Loopback WS RTT 0.10 ms p50 / 0.30 p99; wired adds 0.15–0.5 ms. Hold transport to gates so it never regresses into mattering; don't gold-plate it before the render path is world-class.
4. **CRDT cost is negligible when binary.** Yjs: 1-char insert 30 µs / 18 bytes; remote apply 11 µs; 400-line paste converged remotely in one frame. CRDTs are not a latency excuse. `yrs` must prove the same numbers against the same budgets.
5. **Number to beat:** E2E keystroke → remote frame commit p50 **10.05 ms** / p99 14.55 ms (loopback, 60 Hz). Beam native + 120 Hz targets roughly half, photon-verified.
6. **The OS sabotages background real-time work.** Occluded windows must keep syncing (never tie network receive/apply to the render loop; catch up instantly on reveal). App Nap: `NSProcessInfo.beginActivity(.latencyCritical)` while a session has peers, released when idle (idle-CPU budget still applies). Wi-Fi power save injects 10–50 ms spikes: detect, surface in HUD, recommend wired. Nagle + delayed ACK produce 40 ms+ spikes: `noDelay` on every socket, gated by a zero-spikes-in-10k bench.
7. **Relay on its own thread/event loop.** No UI stall may delay peer relay; the "RTT under host main-thread stall" bench (predecessor: ≤1.3 ms max during 200 ms stalls) is the regression detector.
8. **Separate channels for doc updates vs. awareness.** Awareness is loss-tolerant latest-state-wins → UDP.
9. **Never debounce, never throttle by default; binary everywhere; no JSON on the hot path; spend LAN bandwidth freely** (full snapshot on join, prefetch everything).
10. **Idle CPU is a feature.** ≤0.1% hidden / ≤0.5% connected. Verified with `powermetrics`.
11. **Verify the packaged app by executing the binary directly**, from Phase 0, in CI.
12. **The web gave us shaping/IME/bidi/a11y for free; we signed up to rebuild them** — deliberately, scoped as in §1.

## 5. Budgets — human digest

Machine-readable source of truth: [`perf/budgets.json`](perf/budgets.json). "Budget" is the design target; "(gate)" is the CI failure threshold. Photon and 120 Hz rows gate on the rig; 60 Hz software rows gate on the dev machine now. All to be tightened after L0 + camera calibration.

**L1 — Lifecycle:** launch → visible & typeable ≤ 300 ms (500); launch → peers visible ≤ 1 s (2); binary size ≤ 5 MB (10); linked dylibs ≤ 40 (60).

**L2 — Local render:** keystroke → present-commit (software) p50 ≤ 4 ms (6); keystroke → presented, 60 Hz dev panel, p50 ≤ 26 ms (30) / p99 ≤ 34 ms (38) — *measured floor of the naive present path, see finding below*; keystroke → presented, 120 Hz rig, p50 ≤ 6 (9) / p99 ≤ 10 (14); keystroke → local photons, 120 Hz camera-verified, p50 ≤ 8 ms (12) / p99 ≤ 12 ms (18); draw calls/frame ≤ 2 (4); steady-state allocations per keystroke 0 (0).

**Render-loop architecture (implemented 2026-08-30, forced by measurement):** a *hybrid* event/display-link loop. A keystroke arriving with the pipeline cold renders immediately (event-driven, lowest latency); while the link is warm, input coalesces to the tick — exactly one render per frame, so burst input can never starve the 2-deep drawable queue (per-keystroke presents at 125 Hz measured p99 40.5 ms from starvation; coalescing exists to kill exactly that). The link pauses after ~1.5 s of quiet, so idle CPU stays ~0. Presents can be **dropped** (`presentedTime == 0`) and the drop callback is *untrustworthy* — it can arrive seconds late, only firing when a later present flushes the queue — so every accounted render carries a ~50 ms confirm deadline; an unconfirmed, unsuperseded frame re-renders via the tick **carrying the original NSEvent timestamp**, so the recorded latency honestly includes the drop penalty. An occluded window renders nothing (WindowServer drops all its presents — measured, screensaver included): the loop pauses, keeps the dirty bit, and repaints instantly on the occlusion-state notification — the same rule that will keep a hidden peer syncing with 0 ms reveal (§4.6).

**Present-mode matrix, first pass (2026-08-30, partial — screensaver interrupted):** `normal` completed; `scheduled` (commit → waitUntilScheduled → drawable.present()) **stalled under sustained typing** (zero presented frames for 6 s) despite working for single launch frames — a failed experiment, recorded here so nobody retries it without new evidence. `presentsWithTransaction` untested under load. Default remains `normal`. The same run measured the cost of my first coalescing design (all input deferred to the tick): paced commit p50 went 0.31 → 9.56 ms — a half-frame tax on ordinary typing. Fix, now implemented: immediate render for the first input of each frame, coalescing only within a frame (burst), and *wake-double-present* on cold input (immediate render + one follow-up tick render carrying the same t0, recorder deduped) so idle-first-keystroke recovery costs ~1 frame instead of the 50 ms confirm deadline (measured 91.8 ms deadline-driven). **Validated 2026-08-30 (second run, gate 22 pass / 0 fail):** the hybrid loop holds paced latency (presented p50 25.84 / p99 33.8; commit p50 0.72) while improving jitter 13.0 → **7.96 ms**, bounding burst honestly (p99 48.6 with worst-case-per-frame accounting, zero starvation), and cutting first-keystroke-after-idle to **59.5 ms p50 / 62.9 max** (from 91.8 deadline-driven / 1735 broken). Idle CPU **0.026%** of a core, RSS 65.6 MB. malloc per keystroke net **−81 bytes** (zero-allocation hot path holds).

**Second measured finding (2026-08-30, Phase 2): `NSWindow.occlusionState` is not a visibility oracle.** Building the two-process join bench surfaced this: macOS only ever reports `.visible` for a window whose *app has activated*, and activation is exclusive — so with two Beam processes running side by side, whichever one is not the active app reports itself permanently occluded (`raw=8192`, `appActive=false`, from the very first tick, with nothing covering it). Beam's render loop then correctly renders nothing for it (§4.6), and the peer's frames never reach the glass. The fix is not to weaken the rule but to *replace the proxy with the ground truth*: `GridView.assumeVisible` lets the two bench processes keep rendering, and the join bench's validity check is that presents actually landed — the host reports one `presentedTime > 0` per keystroke it put on the glass, and the run refuses to publish below a 90% delivery ratio. That is a **stronger** check than the occlusion proxy, because a genuinely covered window drops every present and fails loudly, whereas an inactive-but-visible window passes honestly. The single-window benches keep the occlusionState guard, which is correct and proven for them.

**Bench-validity rule (learned the hard way):** latency numbers from an occluded window are fiction. The typing bench aborts (`exit 5`) if the window was ever occluded mid-run; bench windows float on all Spaces (`.canJoinAllSpaces + .fullScreenAuxiliary`) and declare user activity against display sleep — but an already-running screensaver does not yield to synthetic input on macOS 15, so photon-path benches require an attended screen or a rig machine with the screensaver disabled. `beam --probe-presents` is the microscope for present-path behavior (steady/quiet/one-shot phases, per-present ok/drop + visibility).

**First measured finding (2026-08-30, M4 Air 60 Hz, phase-uniform typing bench):** keystroke→commit p50 **0.31 ms** (entire software path: event → model → instance build → Metal encode → commit; CM6 was 0.7 ms — the predecessor's claim that the renderer is never the bottleneck holds natively too). keystroke→presented = uniform vsync phase (0–16.7 ms) **plus a constant ~17 ms**: a one-shot present from an idle window misses the imminent vsync and lands a *full extra frame* later. With `displaySyncEnabled=false` (tearing; experiment lever `BEAM_NO_DISPLAY_SYNC=1`, not a product config) p50 collapses to **4.96 ms** — so ~20 ms of the naive path is vsync *scheduling*, not machinery. This is precisely the commit→photon territory the native bet is about (§4.1: the predecessor's 9.5 ms "keystroke→paint" stopped at Chromium frame commit and never saw this tail — its true photon latency was almost certainly in the same ~25 ms band). The 60 Hz budget above holds the measured line; **cutting the extra frame is Phase 1's headline objective** — candidate levers, camera-decided: display-link-aligned presents timed to the compositor deadline, `presentsWithTransaction`, direct-to-display/fullscreen path, ProMotion.

**L3 — Transport:** loopback TCP echo 64 B p50 ≤ 0.15 ms (0.3), p99 ≤ 0.4 ms (0.8); Nagle/delayed-ACK spikes in 10k msgs 0 (0); LAN overhead above L0 floor p99 ≤ 0.5 ms (1); UDP awareness ≥ 60 Hz (30).

**L4 — CRDT (yrs):** encode 1-char insert ≤ 50 µs / ≤ 40 B (100 µs / 64 B); apply remote ≤ 100 µs (200); awareness encode ≤ 120 B (200); 1000-op reconnect diff ≤ 5 ms / ≤ 20 KB (10 / 40); load 100k-op doc ≤ 200 ms (350).

**L5 — Presence & session:** browse → peer found ≤ 1 s (2); discovery → connected & editing, 5 MB workspace, wired ≤ 1 s (2); **join gesture → code visible on both screens ≤ 150 ms (350); host confirm → guest editing ≤ 120 ms (300); join gesture → first shared keystroke presented on the peer's screen ≤ 400 ms (800)**; handshake crypto CPU ≤ 3 ms (10).

**L6 — End-to-end (headline):** keystroke → remote *presented*, loopback software floor, p99 ≤ 36 ms (45) — *not a LAN number; it gates the send/receive/apply/render delta on every PR, floored by the 33.8 ms local present path*; keystroke → remote present-commit, wired GbE, p50 ≤ 6 ms (9) / p99 ≤ 12 ms (16); remote cursor → remote paint p99 ≤ 12 ms (16); awareness streamed ≥ 60 Hz; 4 typists degrade p99 ≤ 20% vs. 2 (40%); relay RTT under 200 ms host main-thread stall: max ≤ 5 ms (15); bytes/keystroke on wire ≤ 48 (64).

**L7 — Steady state:** idle CPU connected ≤ 0.5% core (1%) — *measurable on loopback from Phase 2, no longer rig-only*, hidden ≤ 0.1% (0.5%); RSS ≤ 80 MB (120); packaged-app launch verification passes (hard gate); soak/energy gates from Phase 4.

## 5.1 Phase 2 design of record — the shell and the join gesture

The whole app is **one window, one Metal grid, three surfaces, and a keymap that fits in a line**.
Everything below is drawn from the glyph atlas; there is no AppKit control anywhere in Beam, and
there will not be one.

The entire keymap: **a number or a click** joins that peer · **return** confirms · **esc** cancels or
leaves · **arrows** move your cursor · **⌘Q** quits. That is the whole thing, and ⌘Q is the only
reason a menu exists at all.

**Surface 1 — the roster (this IS the launch screen).** Your identity, then everyone nearby, one
numbered row each. Alone on the network is a *designed* state with its own copy, not an empty
list: Beam says it is listening and tells you what to do about it. A Local Network (TCC) denial is
a third designed state naming the exact Settings path — per §2 it must never be mistakable for an
empty network, and it is the only place Beam ever mentions System Settings.

**Surface 2 — the join code.** Six digits, both screens, described under "the gesture" below.

**Surface 3 — the editor.** The Phase-0/1 grid, plus remote cursors in per-peer colors with the
peer's name beside them, and each peer's live RTT in the HUD line. Arrow keys move your cursor and
publish it, so a peer's view of your caret is keystroke-accurate rather than only updating when you
type. Selection and scrolling are deliberately absent: they belong with the Phase-1 rope, not bolted
onto a fixed cell array.

**The gesture.** Click a peer row, or press its number. That is the entire join UI. What happens:

1. Guest opens a TCP connection (`noDelay`) and sends a 32-byte X25519 ephemeral public key.
2. Host replies with its own. Both derive the shared secret and, via HKDF-SHA256, three things:
   two directional ChaChaPoly session keys and a **6-digit short authentication string (SAS)**.
3. Both screens show the same 6 digits, rendered as block-glyph pixel digits on the grid.
   The guest already made its gesture; the **host presses return** — one keypress each, total.
   Either side's `esc` cancels.
4. Return → the editor surface, encrypted from the first byte of content.

**What the SAS does and does not do,** stated plainly so nobody over-claims it later: an ephemeral
ECDH gives confidentiality against a passive listener for free, but by itself it is wide open to an
active machine-in-the-middle. The 6 digits are derived from *both* public keys, so a MITM cannot
make both screens agree — a human comparing them is the authentication, and one in a million is the
attacker's odds per attempt. That is the same bargain as Bluetooth numeric comparison and Signal's
safety numbers, and it is why the code is shown large enough to read across a desk. No certificates,
no accounts, nothing leaves the network. Session keys are ephemeral per join (forward secrecy by
construction); nonces are per-direction counters, so an in-session replay is rejected.

**Authorization is one-directional, by construction.** Only the side that *asked* to join can be let
in by the other: a host that received an `accept` frame would be joining itself, so the session is
dropped instead. The host's return keypress is the whole authorization in this scheme, and it must
not be reachable from the wire. Symmetrically, a guest is never dropped into the editor before the
six digits have actually been **presented** on its own screen — the guest is the side doing the
comparing, so an acceptance that arrives first is held until the code is on the glass.

**Why not TLS-PSK.** §2 offered "TLS-PSK **or** Noise" and this is the Noise-shaped branch. Once the
ECDH exists for the SAS, running a TLS handshake on top of it would add round-trips to the exact
gesture the phase is budgeted on, to re-derive a secret we already hold. The wire is
`[u32 length][ChaChaPoly ciphertext‖tag]` over the same TCP connection. Revisit only with a measurement.

**Delight, and what it costs (nothing, by construction).**
- *Sub-frame acknowledgment.* The gesture repaints on the same frame it arrives on, before a single
  network byte moves — the connection **feels** instant because the acknowledgment is local, and
  then the code lands 100 ms later. The `join_gesture_to_code_visible_ms` budget is what keeps that
  honest rather than a claim.
- *Soft fade-in.* Peer names and cursors fade over ~200 ms. Alpha is an 8-bit field packed into the
  existing per-instance `color` word — the shader multiplies, so the hot path pays zero — and the
  animation is *finite*: the display link pauses when it ends, exactly as after typing.
- *Latency as UI.* Each connected peer's live RTT sits in the HUD. We are the only editor confident
  enough to publish it, which is only true while it stays cheap: the roster repaints when a displayed
  value **changes**, not on a timer, and `idle_cpu_connected_pct_core` is the gate that proves it.
- *Nothing blinks.* A blinking cursor is an infinite animation; it would pin the display link awake
  forever and put a permanent floor under idle CPU. Beam's cursor is solid. This is a performance
  decision before it is a taste one, and the idle gate enforces it.

**Validated 2026-08-30 (gate 30 pass / 0 fail — the committed `perf/results/` are this run),
two real processes finding each other over Bonjour and pairing over loopback TCP:**
launch → peer row *presented* **530.6 ms**; gesture → six digits on **both** screens **64.6 ms**
(the acknowledgment is local and lands the same frame as the gesture, so the only thing the network
delays is the code itself); host confirm → guest editing **49.4 ms**; gesture → first shared
keystroke presented *on the peer's screen* **214.6 ms**. Discovery + join together is **745 ms**,
inside the Phase-2 exit criterion of 1 s. Handshake crypto **0.469 ms**; **30 bytes** per keystroke
on the wire (budget 48). No L2 regression from any of the UI work (presented p50 25.6, pipeline
depth 16.9, jitter 8.1, malloc −1.4 B/keystroke), and first-keystroke-after-idle improved to
**51.3 ms** from 59.5.

**Two rows sit inside their gate but above their design budget, and are left that way rather than
re-budgeted after the fact.** `keystroke_to_remote_present_loopback_p99` measured 40.5 ms against a
36 ms budget (gate 45), ranging 32.9–44.9 across runs — that spread is the *local* present path's
tail, not transport's: the local p99 is 33.6 ms and the whole remote round trip adds single-digit
milliseconds on top of frame-boundary luck. It is the same extra frame Phase 1 is chasing, showing up
a second time, and it will come down when pipeline depth does. `idle_cpu_connected_pct_core` measured
0.524% against a 0.5% budget (gate 1.0); see below. Budgets were written before any of this was
measured, which is the order §3 requires, and moving them now to make a chart green is precisely what
that ordering exists to prevent.

**Connected idle CPU: measured, and sitting on its design budget.** 0.20–0.63% of a
core across runs, 0.524% in the committed one (gate 1.0, budget 0.5), split guest 0.27 / host 0.52 — so it is not the render loop:
the display link demonstrably pauses (0 renders, 58 ticks in a 3.1 s window) and `BEAM_NO_RTT=1`
shows the RTT probe is not the cost either. Getting here took fixing two real regressions this
phase's own features introduced, both caught by the gate on its first run at 3.4% (see
`perf/harness-proof.md`). The remaining ~0.5% is the post-typing display-link wind-down plus
Network.framework and mDNS background work in the *host* process. **The next lever, identified but
deliberately not merged:** stop `NWBrowser` while a session is live — nobody is looking at the roster
from inside the editor. `DiscoveryService.pauseBrowsing()/resumeBrowsing()` exist for it; they are
not wired up because the dev machine's display went dark before the change could be measured, and an
unmeasured optimisation is not something this project merges.

**Seeing the UI without a screen.** `beam --dump-scene` renders every surface to ASCII on stdout —
no Metal, no window, no display. Beam's entire UI is instance data, so the layout can be inspected
exactly as the GPU receives it; on a machine whose display cycles (and in CI, which has none) this is
the only way to look at the product, and unlike a screenshot it is reviewable in a diff. It earned
itself immediately: it showed the peer's name label being drawn straight over the line above the
caret. The fix is that the label trails the caret on its own row and only where the row is actually
empty — a typing caret sits at the end of its text, and when it doesn't, the coloured caret alone
says enough. Beam would rather draw nothing than draw over a character somebody wrote.

**Deliberately not built yet.** Phase 2 ships a shared *grid* with per-peer cursors — remote inserts
apply at the sender's cursor, last writer wins on a cell. That is not a CRDT and is not pretending to
be one; `yrs` lands in Phase 3 and inherits the L4 budgets and the L6 wire budget unchanged. Phase 2
also keeps the doc channel and the (Phase-3) awareness channel separate at the op level so the UDP
split in §4.8 stays available.

## 6. Phases (each ships its benchmarks first; no merge red)

**Phase 0 — Skeleton + harness.** Nothing else starts until green.
- Metal window rendering a monospace grid via glyph atlas; keystroke echo; block cursor; HUD v0 (live p50/p99 vs budgets.json).
- Bonjour advertise + browse behind the TCC prompt; TCP echo between two processes with `noDelay`.
- `perf/budgets.json`; benches: launch, typing latency, TCP echo/Nagle, discovery, deterministic counters — one command (`scripts/bench.sh`), JSON out, gate judges.
- Every timing bench proven able to go red via sabotage hooks; proof recorded in `perf/harness-proof.md`.
- Packaged-.app build + direct-binary launch verification; CI tier 1.
- `--flash-on-key` calibration mode; camera calibration of the render path (rig session; offset recorded in budgets.json).
- *Exit: all of the above runs on one command, publishes JSON, gates in CI, and has been proven red.*

**Phase 1 — The editor that types faster than anything.**
- **Present-path engineering first** (the §5-L2 finding): recover the extra frame the naive one-shot present pays — display-link-aligned presents, `presentsWithTransaction`, direct-to-display — each lever accepted or rejected by measurement, photon-verified by camera. Target: 60 Hz presented p50 back under ~13 ms, then ProMotion.
- Rope/gap-buffer text storage; real editing on the glyph grid (selection, scrolling, mouse); single file open/save.
- Camera-verified local latency beating every L2 budget on the rig.
- Syntax highlighting only if it survives the latency gate (tree-sitter is the candidate; it merges only with L2 still green).
- IME milestone begins here (marked-text protocol correct even if compositions render plainly).
- *Exit: L1/L2/L7 green; camera offset documented; typing feels instant and measures it.*

**Phase 2 — Presence + one-gesture secure session.** Design of record: §5.1.
- Instant peer list (the launch screen *is* the peer list); X25519 + SAS pairing → ChaChaPoly-encrypted transport; TCC denial UX.
- The radical-minimal shell: no menus, no toolbars; launch → collaborating in seconds.
- Benches first: `--bench-peers` (launch → a peer row presented) and `--bench-join` (a real two-process host+guest pair over Bonjour + loopback TCP, measuring the gesture, the code, the confirm, the first shared keystroke, bytes/keystroke on the wire, and connected idle CPU).
- Sabotage hooks proving those gates red: `BEAM_SABOTAGE_JOIN_DELAY_MS`, `BEAM_SABOTAGE_PEER_LIST_DELAY_MS`.
- *Exit: **met** 2026-08-30 — L5 green, discovery→editing 653 ms on loopback; the wired rig number is Phase 3's to confirm.*

**Phase 3 — Multiplayer editing.**
- `yrs` sync over TCP (noDelay), awareness over UDP, relay on a dedicated thread with the stall-immunity bench; collab undo; host save.
- Occluded-window sync correctness bench (hidden peer keeps applying; instant catch-up on reveal).
- *Exit: L3/L4/L6 green **on the two-machine rig**, wired and Wi-Fi.*

**Phase 4 — Groups + polish.**
- N-peer sessions; reconnect via state-vector diff; soak + energy gates; notarized distributable.
- *Exit: L6 4-typist and L7 soak green; notarized build passes packaged verification.*

## 7. Novel benchmark roadmap

Benchmarks are designed ahead of the features they gate, per §3. Each lands with its phase, budget-first, proven red before trusted. The ones already running are in `budgets.json`; this is the forward book. What makes these novel is that they gate on what users *feel* but editors never measure: minimum latency (pipeline depth), jitter, the first keystroke after a pause, behavior under occlusion and system pressure.

**Running now (Phase 0/1):**
- **Pipeline depth** — *min* keystroke→presented; the direct score for present-path engineering.
- **Jitter gate** — presented p99−p50; smoothness as a first-class budget.
- **Burst @125 Hz** — input faster than key repeat; catches coalescing pathologies and drawable starvation.
- **First keystroke after idle** — the cold-pipeline tax, including present-drop recovery; the keystroke users actually judge the app by.
- **malloc bytes/keystroke** — net allocation on the hot path (design target 0; ratcheting budget).
- **Idle CPU foreground / RSS** — event-driven idle must measure ~0; `--bench-idle`.
- **Present-mode matrix** (`scripts/present-matrix.sh`) — normal vs. scheduled vs. presents-with-transaction; the data picks `Renderer.presentMode`.

**Phase 1 (editor):** queue-transit segment (NSEvent.timestamp → keyDown entry — real IOHID input only; the segment no web editor can see; HUD + camera sessions); open-1 MB-file→first paint; full-speed scroll dropped-frames and wheel→photon; syntax-highlight merge gate (tree-sitter merges only if every L2 gate stays green); IME marked-text correctness + latency; undo at 10k depth.

**Phase 2 (presence/session):** *running now* — launch → peer row presented; join gesture → code on both screens; confirm → editing; gesture → first shared keystroke presented on the peer's screen; bytes/keystroke on the wire; connected idle CPU (the gate that keeps live-RTT-in-the-UI honest). *Still ahead:* discovery under mDNS-hostile APs (broadcast-fallback path); TCC-denial UX correctness (denied permission must surface in ≤1 s, never an empty peer list).

**Phase 3 (multiplayer):** occluded-peer catch-up — hidden window keeps applying remote ops (bytes applied while hidden ≥ sender's bytes sent), reveal repaint ≤ 1 frame; AI-scale paste (400-line insert → remote presented ≤ 2 frames, the predecessor's measured basis); typing-under-sync-storm (local p99 while receiving 10k ops/s); relay stall-immunity (≤5 ms under 200 ms host main-thread stall); Wi-Fi power-save spike detector (continuous RTT histogram, spike-count gate); AWDL vs. infrastructure variance matrix before trusting AWDL.
- **Cross-machine, clock-free:** all E2E via RTT/2 + d_remote (§3.1); camera verifies the constant.

**Phase 4 (groups/polish):** join-storm (N guests connect simultaneously → all editable ≤ 2 s); reconnect diff after 60 s partition; thermal soak (p99 after 30 min sustained collab vs. cold — throttling detection); battery-vs-plugged latency delta; external/multi-display present path (the compositor behaves differently per display); 8 h soak (RSS, FDs).

## 8. Rig

Two machines on a dedicated unmanaged GbE switch (isolated), one Wi-Fi AP for the wireless matrix, one 240 fps phone camera. L0 floor measured per rig with `ping`/`irtt` + `iperf3` and recorded in `perf/results/l0-floor.json` before any rig gate is trusted. The 120 Hz (ProMotion) machine hosts the photon gates. Until the rig exists, rig-tier metrics report "missing" (not failing) in the gate; the dev machine gates the 60 Hz software rows.

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

## 5.2 Visual quality — design of record

Beam works and its layout is sound; it does not yet *look* like a product. This section is the
design of record for making it visually excellent at the level of Zed or Linear, under a hard
constraint: **beauty here is precision, not decoration.** Beam stays one window, one Metal grid, one
instanced draw call, every pixel from the glyph atlas, zero chrome. Nothing in this work may cost the
keystroke hot path a microsecond, the frame a draw call, or the idle loop a wakeup — and because
aesthetics are not gateable but regressions are, **every workstream lands only with `scripts/bench.sh`
fully green**: draw calls/frame, malloc/keystroke, idle CPU (foreground and connected), L1 launch, and
every L2 row unchanged or better. Where a change is measurable it is budgeted in `budgets.json`
first and proven red before it is trusted (§3). No budget moves after seeing the data.

**No golden-image tests.** Pixel-diffing a renderer is brittle and would make every deliberate
improvement a test failure. Structure is checked by `--dump-scene` (diffable, in CI); pixels are
reviewed by eye through `--screenshot`. The two are kept in sync by rule: a layout change updates both.

### The eyes: `beam --screenshot`

`beam --screenshot [--surface roster|denied|pairing|editor|all] [--out dir]` renders each surface into
an **offscreen** Metal texture at 2× and writes PNGs. No window, no display, no `NSApplication` — so
unlike every photon bench it is immune to this machine's display cycling (§ environment quirks) and
it runs in CI. It reuses `SceneDump`'s seeded `AppModel`s, so the ASCII dump and the PNGs show the
same states and cannot drift apart. This is built first because visual iteration without it is
guesswork: screenshot → look → adjust → screenshot. A "before" set is captured on the pre-session
code and kept; every workstream below reports a before/after pair.

### The workstreams

1. **Typography — the single biggest visible lever.** The atlas rasterizes with
   `setShouldSmoothFonts(false)` and the shader blends in non-linear sRGB; light-on-dark text blended
   without gamma awareness reads wrong (thin, or muddy at the edges) — this is the thing every serious
   text renderer handles deliberately. Also: cell metrics must land on whole device pixels end to end
   (`contentsScale` → `drawableSize` → cell width/height); any fractional accumulation blurs a grid
   that is otherwise pixel-exact. Descenders must not be clipped by the cell. SF Mono is evaluated
   against the current `userFixedPitch` face, and stroke weight is judged *on the dark ground*, not in
   the abstract. Atlas and font work bills to the **L1 launch budget**, which is gated: a heavier
   atlas earns its cost or gets precompiled.
2. **The window is all content.** `fullSizeContentView` + transparent titlebar +
   `isMovableByWindowBackground`; traffic lights overlay the already-generous left margin with
   designed hover/inactive states rather than AppKit defaults floating on the grid. Corner radius
   comes free from the system. Gated by: L1 launch and typeable still hold, and the bench windows
   still float and order correctly (the two-process join bench depends on that plumbing).
3. **A designed palette.** Today's entries are programmer-picked RGB in the shader source. They get
   replaced by a designed scale: a background carrying a trace of hue rather than neutral gray;
   fg/dim/faint as measured contrast steps; the six peer hues equalized for *perceived* lightness on
   the dark ground so they read as a set; accent reserved for "beam" and the join code alone. The
   palette lives in `Renderer.shaderSource` and each entry is annotated with its intent — that file
   *is* Beam's design system. Palette and workstream 1 interact (gamma/linear space is one decision
   across both) and are decided together.
4. **Composition.** Roster, join code and editor as designed layouts: one alignment grid, breathing
   room used with intent, and the six digits set as the typographic centerpiece of the product — that
   screen is the one users show each other across a desk. The HUD line is designed, not appended: it
   is the only ornament Beam has, and the latency numbers *are* the brand, so they are set like
   jewelry, not like debug output. Every layout change gets a `--dump-scene` review and a screenshot
   review.
5. **Motion, only where it is free.** The fade machinery already exists (per-instance alpha in the
   existing `color` word; finite by rule). It is used where arrival deserves softness. Nothing
   infinite, nothing that blinks, and **no easing on the caret** — instant is the aesthetic, and a
   sliding cursor manufactures perceived latency in the one product that exists to delete it. Anything
   repainting on a recurring signal pins the display link awake; that exact mistake cost 3.4% idle CPU
   in Phase 2 and was caught by the gate (`perf/harness-proof.md`), which is why this workstream is
   last and smallest.

### What the eyes found, and what changed (2026-08-30)

`--screenshot` earned itself on its first run, the way `--dump-scene` did in Phase 2: the
"before" set of the shipping code showed a **one-pixel dark seam cutting horizontally through
every digit of the join code** — the most-looked-at pixels in the product, and invisible in the
ASCII dump because the dump has no pixels. The cause was `originPx.y = cellHeightPx / 2` with an
odd cell height: a half-pixel grid origin makes every quad sample across its atlas cell's edge,
and for the solid-block glyph the neighbouring cell is empty. Whole-pixel metrics end to end fixed
it. That is the argument for this tool in one bug: structure is diffable, pixels are not, and Beam
needed both.

**Typography.** The face is now **SF Mono** (`.AppleSystemUIFontMonospaced-Regular`), reached
through `NSFont.monospacedSystemFont` — the only way to get it. `CTFontCreateWithName("SF Mono")`
silently returns **Helvetica**, a proportional font, with no error; a monospace grid rendered in
Helvetica is the kind of thing that ships. `userFixedPitch` (Menlo) remains the documented
fallback. Cell metrics are whole device pixels throughout — cell 18x36, baseline 29, grid origin
(18, 18) at 2x — and the line height is a designed 1.30 em rather than whatever
`ascent + descent + leading` happened to sum to. The cell is then checked against the *real ink
extents* rather than the font's own metrics, because they disagree: SF Mono's deepest descender
('|', 6.60 px at 28 px) falls outside its declared 5.91 px descent, so a cell sized from the
metrics alone clips it. `--screenshot --surface atlas` writes the atlas itself; a scan of it
confirms every glyph clears its cell.

**Gamma.** The render target is now `bgra8Unorm_srgb` with an explicitly sRGB layer colourspace,
and the palette is linearised per vertex, so the blend happens in **linear light**. This is not a
subtle change: an edge pixel at half coverage was being composited as sRGB 119 and is now 160 —
**34% brighter** — which is why light-on-dark text blended in non-linear sRGB reads thin and
slightly grubby. Fully-covered and zero-coverage pixels are unchanged to within rounding (verified
against the design values in the PNGs), which is the proof the transform is right: only the
antialiased edges moved, which is exactly what gamma-correct blending is.

**Palette.** Designed in OKLCH and converted, so the numbers in `Renderer.shaderSource` are the
*result* of a decision. Ground **#0D1117** (L 0.175 / C 0.014 / H 258) — not neutral; the same
blue the text hierarchy is built from. fg / dim / faint are one hue at deliberate lightness steps
(0.930 / 0.700 / 0.505 → 15.4:1 / 7.1:1 / 3.2:1 against the ground). The six peer colours share an
**identical L (0.760) and C (0.120)** and differ only in hue, 60° apart, which is the whole trick:
at equal perceived lightness they read as one set and no peer is louder than another. Their ring
is offset 30° from the accent's hue — the furthest six evenly spaced hues can stay from it — and
the accent (#23C9FB) is reserved for the "beam" mark and the join code, nothing else.

The first roster screenshot then showed a **different** bug the palette had been hiding: two of
three peers were the same colour. The hash-to-six-slots assignment collides at the rate the
birthday paradox says it will, and six hues designed as a set is the design failing when two rows
share one. `Peer.assignInks` keeps the hash as the preferred slot and probes forward on a
collision, over a name-sorted list so the outcome depends only on which peers are present and a
roster never reshuffles as it fills.

**Composition.** One alignment grid, obeyed by all three surfaces: left margin 6 cells (63 pt at
2x — exactly past the traffic lights' right edge, so the chrome sits in a margin the design
already reserved), first content row 3 (rows 0–2 are the band the lights occupy). Two spacing
rules do most of the work: list items get air (peers every *other* row, with the blank row as the
second half of the click target), paragraph lines do not (an empty or denied state is one
sentence and stays adjacent). Each page is anchored at both ends — a block at the top, one quiet
line along the bottom.

The join code is now the largest thing in the product by a wide margin: block "pixels" are square
by construction (cells are 1:2, so a pixel is 2s cells by s rows), the code is scaled to the
largest whole step the window allows, and it is **grouped 3+3**. That grouping is a correctness
feature rather than styling — the entire security model is a human comparing six digits with
another human, and people compare 3+3 far more reliably than a run of six.

The HUD is set like a caption on an instrument instead of like debug output: labels faint, values
carrying the budget colour, units quiet again, the peer's chip inline in their own colour. The
latency numbers are the brand, so they are the brightest thing on the line and everything around
them gets out of their way.

**The window** is `fullSizeContentView` with a transparent, title-less titlebar; corner radius and
shadow come free from the system, the appearance is pinned to `darkAqua` so the traffic lights use
their dark variant instead of sitting on the grid as three bright dots, and the window background
is Beam's own ground so a live resize and the instant before the first frame are the same colour.
Because the grid consumes `mouseDown` to make the roster clickable, `isMovableByWindowBackground`
would never fire — so **the grid is the drag handle**: any press that is not a peer row calls
`performDrag`, and a press without movement still does nothing.

**Motion: one change, and a list of deliberate refusals.** Fades now start from a **40% floor**
rather than from nothing, and the second reason is the serious one. `L1.launch_to_peers_visible_ms`
is marked on the presented frame that first carries a peer row — and with a fade from zero that
frame is *blank*. Beam was quietly crediting itself with up to a fade's worth of latency it had
not delivered. A fade must not be able to make a "visible" claim true before a human could read the
thing. It also simply feels faster: the row is legible on frame one and the fade reads as settling
rather than as loading.

Nothing else was added, and the refusals are the design:
- **The join code does not fade in.** It is measured (`join_gesture_to_code_visible_ms`) and, more
  importantly, the guest is held out of the editor until the code has actually been *presented* on
  its own screen. A fade would make both claims softer in exchange for prettiness on the one screen
  where the product is making a security promise. The code lands.
- **The caret has no easing, and does not blink.** A sliding cursor manufactures perceived latency
  in the one product that exists to delete it, and a blink is an infinite animation that would pin
  the display link awake and put a permanent floor under idle CPU. *(§5.5 revisits this: the first
  half stands, the second was wrong — a blink that **stops** is finite, and finite was all the rule
  ever required.)*
- **The launch screen does not fade in.** Fading the first frame would make the app feel slower
  than the 148 ms it measures.

**Validated 2026-08-30 — gate 30 pass / 0 fail**, the same count Phase 2 exited on, with every L2
row unchanged or better and nothing given up for the visual work. Presented p50 **25.82** / p99
**33.74**, pipeline depth **17.05**, jitter **7.92** (from 8.1), commit p50 **0.336** (from 0.72),
burst p99 49.08, first-keystroke-after-idle **45.8 p50 / 54.5 max** (from 51.3), draw calls **1**,
malloc/keystroke **−25 B**. Idle CPU **0.012%** foreground alone (from 0.026) and **0.206%**
connected (from 0.524 — comfortably back under its 0.5 design budget), RSS **65.5 MB**. Launch to
first frame **181 ms**; the binary grew 526 → **551 KB** and still links **36** dylibs, so the
screenshot path added no framework. On the join path: gesture → code on both screens **48.7 ms**
(from 64.6), confirm → editing 66.2, gesture → first shared keystroke **182.1 ms** (from 214.6),
crypto 0.162 ms, 30 bytes/keystroke.

Two rows moved the wrong way and are reported rather than explained away.
`L1.launch_to_peers_visible_ms` measured 736 ms against Phase 2's 531 (budget 1000, gate 2000);
the same run's cold `browse_to_peer_found` was 1001 ms, so this is mDNS variance rather than
anything in the render path — the mechanism that marks the row is unchanged, and the fade floor
above changes only whether that instant is *truthful*, not when it occurs.
`keystroke_to_remote_present_loopback_p99_ms` measured 43.2 against a 36 ms budget (gate 45),
inside the 32.9–44.9 range §5.1 already records for it and still floored by the local present path.

**One thing was measured, believed, and then un-believed.** A mid-session run read
`malloc_bytes_per_keystroke` at +8.6 against a design target of zero, so the HUD's per-frame span
array was given a reused buffer. The next run read +29; the run after read −25; the recorded history
is −81, −1.4, +8.6, +29, −25. A ~110-byte spread cannot resolve the ~10 bytes eleven spans cost, so
the "regression" was noise and the fix was an **unmeasured optimisation** — which this project does
not merge, for the same reason `DiscoveryService.pauseBrowsing()` is still sitting unwired (§5.1).
It was reverted, and the reason is now a comment on `hudSpans()` so the next person does not
re-discover it. A separate run during that stretch went red (presented p99 41.6, jitter 15.8) on a
machine that had just failed five bench attempts in a row; a clean re-run measured 33.7 / 7.9, which
is what "never gate on garbage" means in practice.

## 5.3 Phase 1 design of record — a real editor that is still not a TUI

Phases 0–2 built something that *works* and, since §5.2, looks excellent. It is also
unmistakably a **terminal application**: a fixed 200×120 ASCII cell array, no file, no
selection, no scrolling, no mouse past a click target, and the only way in is a list of
machines. This section is the design of record for making Beam an editor you would open a
file in, and for making it read as a **GUI** while keeping the chrome as minimal as §5.1
left it. It **amends Pillar 4 and §5.1**; where it does, it says so and why.

### What is actually being amended

**Pillar 4 said "Beam removes UI. No menus/toolbars/panels."** That is kept, and sharpened:
Beam removes **chrome**, not **capability**. The distinction the original wording could not
make, and that this phase forces:

> *Chrome* is UI whose job is to host commands — menus, toolbars, sidebars, tab bars,
> inspectors. It is permanently on screen, it is about the application, and Beam has none.
> *Capability* is UI that **is** the document or is directly manipulating it — a gutter, a
> selection, a scroll position, a caret, a hover state. It is about the user's own text, and
> an editor without it is not minimal, it is unfinished.

A file tree pinned to the left edge is chrome. A file *finder* that exists only while you are
finding a file is not — it is a transient, in the same family as the join-code screen Beam
already has. **Every list in Beam is now a transient overlay, and there are exactly two of
them: files and peers.** That is the amendment, and the lineup test still passes: §5.3's
editor next to five VS Code clones is the one with no sidebar, no tab bar, no toolbar, no
title bar and no status bar — one document, one line of instrument readout, and a window
whose entire surface is content.

**§5.1 said "the launch screen IS the peer list."** That is amended: **Beam launches into a
document.** Single player is not a mode, it is the ground state, and collaboration is an
*action* taken from inside the document. Two things make that affordable rather than a
retreat from Pillar 1:

- **Presence moves onto the one line Beam already had.** The HUD becomes the **status line**,
  and its left half carries presence: each nearby machine's chip in its own colour, a count,
  and the key that opens the list — `▪▪ 2 nearby ⌘K`. A peer arriving is still visible within
  a second, without a screen dedicated to it, and now it is visible *while you are working*,
  which the roster-as-launch-screen never was. Presence got more continuous, not less.
- **The TCC-denial and cannot-advertise states stay on the glass.** §2 requires that a
  permission denial can never be mistaken for an empty network, and a designed state hidden
  behind a keypress would break that. When discovery reports a problem the presence line says
  so directly, in red, and the overlay carries the full sentence and the Settings path. This
  is a correctness property, not a courtesy, and it is why presence could not simply be moved
  into the overlay wholesale.

**§5.1's one-line keymap is replaced, and gets longer.** It was one line because there was
nothing to do. The new one is longer because there is now a document — and every key in it
except one is a binding macOS already taught the user:

> **⌘O** open · **⌘S** save · **⌘K** who's nearby · **⌘Z / ⇧⌘Z** undo · **⌘A** select all ·
> **⌘Q** quit · **esc** closes an overlay, cancels a join, leaves a session ·
> **return** confirms the join code · **arrows** move, **⇧arrows** select ·
> **click** places the caret, **drag** selects, **wheel** scrolls

Beam invents exactly one binding, `⌘K`. A GUI is in large part an application you do not have
to learn a keymap for, so the correct number of invented bindings is as close to zero as the
product allows.

### Where Beam sits on the TUI/GUI seam

"TUI" and "minimal" are not the same axis, and conflating them is what produced a beautiful
terminal. The decision, stated as two lists:

**Kept from the terminal, because it is why Beam is fast:** one monospace grid, one glyph
atlas, one instanced draw per plane, cell-quantized *layout*, no AppKit control anywhere, a
palette rather than a colour picker.

**Taken from the GUI, because it is what an editor is:** filled surfaces (selection, the
caret's row, an overlay's plane, the scrim behind it, hover); real scrolling, quantized to
**device pixels, not to cells**; mouse-first affordances — click to place, drag to select,
wheel to scroll, hover to preview a choice; a gutter; focus states; and a document that is a
file rather than a fixed array.

The seam runs through *scrolling*, and that is the sharpest single decision here. A terminal
scrolls by whole lines because a cell is its atom. Beam scrolls by whole **pixels**: the
document plane's origin carries the sub-cell remainder, so a two-finger flick moves the text
continuously and every glyph still lands on whole device pixels (§5.2's invariant is about
the *cell metrics*, and it is untouched — a whole-pixel origin offset preserves it exactly).
That costs a **second draw call** — the document plane scrolls, the chrome plane does not —
which is why `draw_calls_per_frame` was budgeted at 2 with a gate of 4 while measuring 1. The
budget written in Phase 0 is being spent on the thing it was reserved for, and the document
plane additionally gets a scissor rect, so a half-scrolled line is clipped by the viewport
instead of running under the filename.

### The surfaces

**One surface, one layer, one takeover.**

- **The editor (always).** Row 1 carries the filename, in the band the traffic lights occupy
  — Beam has no title bar, so the document's name sits exactly where a title would be, past
  the lights, on the §5.2 margin. The document starts at row 3. **Line numbers hang to the
  left of the text margin**, right-aligned, in `faint`, with the caret's own line in `dim`;
  the *code* keeps the 6-cell margin every other surface obeys, so the gutter lives in the
  space the design already reserved for chrome instead of pushing the text right. The last
  row is the status line: caret position on the left, presence and live latency on the right.
  A scroll indicator sits in the last column when the document is taller than the viewport —
  drawn, never animated, so it costs the idle loop nothing.
- **The overlay (a layer over the editor).** One mechanism, two lists. `⌘O` fuzzy-finds files;
  `⌘K` lists peers. A `scrim` over the whole viewport, a `surface` panel, a query row, a rule,
  and rows with selection and hover fills. It is a *layer*, not a surface: the document stays
  behind it, dimmed, because you are choosing something to do *to* the document and losing
  sight of it would be a worse answer.
- **The join code (a full takeover).** Unchanged from §5.1. It is a security ritual and it
  must dominate the screen: six digits, both machines, one keypress each. It is the one place
  in Beam where the document is not the point.

The `.roster` surface is deleted. Its three designed states — the list, alone-on-the-network,
and the Local Network denial — move into the peers overlay with their copy intact, and the
denial additionally surfaces on the status line as described above.

### Rejected, and why

- **A persistent file rail** (a 26-column pane, a tree, a divider). Sketched and rendered
  before it was rejected, which is the only honest way to reject something: `--screenshot`
  showed a screen that could be any of a dozen editors, which is precisely the lineup test
  Pillar 4 exists to fail. It also permanently spends a quarter of the window on navigation
  you do a few times an hour, pushes the code right, and puts the traffic lights on top of the
  tree. The overlay does the same job in the same number of keystrokes and costs zero pixels
  when you are not using it.
- **Keeping the roster as the launch screen, with the editor behind it** (sketch C). It
  preserves §5.1 exactly and it is the option that changes least — but it makes single player
  a second-class destination reached *through* a list of machines you may not have, and Beam
  would still launch into something that is not a document. An editor whose launch screen is
  a network browser is not an editor you would open a file in, which was the whole mission.
- **`NSOpenPanel` for ⌘O.** It is the "real editor" answer and it is wrong twice: it is an
  AppKit control in an app whose entire claim is that it has none, and it is a process-hosted
  panel with latency Beam does not control and cannot measure. Beam's own palette is faster,
  is drawn from the same atlas as everything else, and is gated (`overlay_keystroke_to_commit`).
- **Mixing files and peers into one list.** Tempting, and one fewer binding — but nobody
  fuzzy-searches across "a file to edit" and "a person to work with", and the merged list
  would have to explain itself in a way neither list does.
- **Editor-wide hover tracking.** Mouse-move events would wake the render loop on every
  motion, which is the exact shape of the 3.4%-idle-CPU regression Phase 2 caught. Hover
  exists only while an overlay is open, where there is something to hover *over*; the
  tracking area is installed with the overlay and removed with it.
- **tree-sitter, for now.** See "Syntax" below. It stays the candidate on record for
  structural features; it is not what colours the first screen of code.

### The text model

`GridModel` — a flat 200×120 ASCII array with last-writer-wins — cannot hold a file and was
never meant to. It is replaced by `TextBuffer`: **a gap buffer over the file's bytes, plus a
line index stored in raw-buffer coordinates.**

The line index is the part worth designing rather than discovering. Line starts are stored as
offsets into the *raw* buffer, gap included, so an insert at the caret advances `gapStart` and
**changes no stored offset at all** — the offsets below the gap are still below it and the
ones above are untouched. Typing therefore costs no line-index work whatever, in a 1 MB file
as in an empty one; the array only moves when a newline is inserted or deleted, and offsets
only shift when the gap itself moves, proportional to what moved. The obvious design — logical
offsets — makes every keystroke an O(lines) fixup, which is inside the commit budget and still
the wrong shape.

**It is built to be replaced.** Phase 3 puts `yrs` underneath, and the L4/L6 budgets are
already written. So the split is: `TextBuffer` owns the *bytes*, `LineIndex` owns the
*structure*, and `LineIndex` is updated only from `(offset, insertedBytes, deletedByteCount)`
— which is exactly the shape of a CRDT delta, not a privilege of owning the storage. Every
edit, local or remote, goes through one `apply(_ edit:)` funnel that emits that triple, so
Phase 3 swaps the storage and keeps the index, the undo stack, the highlighter invalidation
and the render path unchanged.

**Two correctness cliffs, owned rather than discovered.** `InstanceWriter.text` iterated UTF-8
*bytes* and advanced a column for each one, so a two-byte `é` drew nothing and consumed two
cells and every column downstream — the caret, a click, a selection — was silently wrong. It
now draws one cell per Unicode scalar. And the atlas was a fixed 16×7 grid of ASCII 32–126;
it is now 16×16, with 100 static slots and 156 filled on demand by `GlyphCache` with LRU
eviction scoped to the frame being built, so a glyph can never be evicted out from under an
instance that already points at it. **The ASCII fast path does not go through the cache**: a
full screen of code is ~3500 characters and a dictionary lookup on each would have cost more
than Beam's entire measured commit path (0.34 ms p50), so callers test `32...126` inline and
the cache is the *miss* path only. A scalar this machine has no glyph for draws a replacement
box — visibly missing is honest; invisibly missing shifts the line.

**One cell per scalar is Phase 1's documented limit.** A glyph wider than the cell (every East
Asian character, most emoji) is squashed to fit rather than clipped: both are wrong, only one
is still readable, and neither can slide the rest of the line, which is the property that
actually matters. **East Asian width joins bidi, IME and accessibility on §1's list** of what
the web gave us for free and we signed up to rebuild — the design is two atlas slots per wide
scalar and a width-aware column map, and it is not this phase.

### Syntax highlighting — and why it is not tree-sitter yet

The classic way to destroy a typing latency is to highlight on the keystroke path, so the
architecture matters more than the parser:

- Tokens are cached **per line**, as spans, and a line is re-lexed only when its own bytes
  change or when the carry state arriving from the line above it changes.
- The lexer never runs between `keyDown` and the frame. An edit marks lines dirty; the frame
  lexes only the dirty lines that are actually *visible*, which is bounded by the viewport
  and not by the file.
- The palette is already the interface: a token kind is an `Ink`, an `Ink` is 8 bits in a
  word the instance already carried, and colouring a character therefore costs zero extra
  instances, zero extra bytes and zero extra draw calls.

Inside that architecture the parser is a swappable detail, and Phase 1 ships **a line-based
incremental lexer** driven by a small per-language table, not tree-sitter. The reasons, since
§6 named tree-sitter as the candidate:

1. It is a C dependency and a compiled grammar — roughly 1.5 MB against a **551 KB** binary —
   bought for a screen of colour that a lexer with a carry state gets right.
2. Phase 3 has to keep the parse in sync with `yrs` deltas. A per-line carry state is
   reconstructed from a byte range; a syntax tree needs every edit translated into
   `ts_tree_edit` and would double the incremental-update surface at exactly the moment that
   surface gets a second writer.
3. What tree-sitter is genuinely better at — folding, expand-selection, structural
   navigation, correct nesting in raw strings and generics — Beam does not have and is not
   adding this phase.

So tree-sitter is not rejected, it is **not yet earned**: it stays the candidate for the
structural features that need it, and it will be measured against these same budgets when
there is a feature that justifies it. A lexer that mis-colours a nested raw string is a
mis-coloured token; that is the failure mode being accepted, in writing.

`syntax_highlight_line_us` gates the lexer, and the enforcement that matters is that
`keystroke_to_commit`, the presented rows and `malloc_bytes_per_keystroke` do not move.
**§6's commitment stands unchanged: highlighting merges only with every L2 row green, and is
reverted if they move.**

### What the eyes and the benches found (2026-08-30)

**`--dump-scene` caught a designed state running off its own panel.** The Local
Network denial's second line — the Settings path, the one string in Beam that
cannot be shortened without making it less useful — is 59 cells, and the overlay
panel was 56. In the ASCII dump it visibly spilled past the panel edge onto the
scrim. The panel is now 64 cells wide and both designed empty states are back to
§5.1's two-line paragraphs, word for word. That is the third time a structural,
diffable view has found something a screenshot would not have made obvious, and
it is why the dump is kept in sync by rule.

**The dump also had to change to stay useful.** Filled surfaces are all the same
solid-block glyph, so a dump that printed them as `#` replaced the whole editor
with a wall — the first run of the new editor state was 3,600 hash marks. It now
maps *glyph plus ink*: a panel is `.`, a selection `~`, a hover `-`, the scroll
indicator `|`, a lit row nothing at all, and the scrim **nothing** rather than
blanks, because a scrim dims the document and does not erase it. A structural
view that blanked everything behind an overlay would be describing a different
application.

**The overlay's own gate caught the overlay on its first run.** `⌘O`'s filter
runs on the keystroke path because there is nowhere else to put it, which is
exactly why `overlay_keystroke_to_commit_p99_ms` was written before the overlay
was. The first implementation scored every candidate, sorted the whole array,
and used `paths[i].count` as the tie-break — and `String.count` is O(length),
called from inside a comparator, n log n times. It measured **12.3 ms p50
against a 4 ms budget and an 8 ms gate** on a 9,728-file tree. What replaced it
keeps only the best `limit` results in a single pass, with no full sort and with
lengths read from the prebuilt byte arrays. The *fix* stands on its own — a
String's length is not O(1) and a comparator is the worst place to ask for it —
but the *number* does not: see the validity finding below.

**`NSWindow.occlusionState` is not a visibility oracle, a second time, and this
time it cost a set of numbers.** Phase 2 found it lying about a window whose app
had not activated (§5-L2). Here it reported `.visible` for a floating bench
window while a screensaver was dropping most of its presents — and the editor
bench happily published. The numbers were wrong in a specific, instructive way:
a dropped present is re-rendered carrying its **original** `t0`, so the recorded
latency correctly includes the drop penalty, and just as correctly stops being a
measurement of Beam. Scroll and selection-drag both read ~16 ms — one whole
frame — above what the paced typing bench measures under the same code.

The fix is the same one Phase 2 landed and for the same reason: **replace the
proxy with the ground truth.** `--bench-editor` now counts presents that
actually reached the glass and refuses to publish below 90% delivery, exactly as
`--bench-join` does. It also refuses any sample over a second outright — a
synthesized `CGEvent` carries a raw mach tick count where `NSEvent.timestamp`
expects nanoseconds-since-boot, which produced a single scroll sample of
**366,811,454 ms** and would otherwise have been averaged into a percentile. A
bench that cannot tell a broken clock domain from a latency is not a bench.

**Two things measured cheaper than expected, and are recorded so nobody
optimises them.** Building a frame with the overlay open — a full-viewport
scrim, a panel, and the document behind them, about 4,900 instances — costs
**58 µs**, against **57 µs** for the document alone: filled surfaces really are
nearly free on a glyph grid, which is the whole premise of §5.3's GUI
vocabulary. And the fuzzy filter itself, after the fix, is **2.4 µs p50** over
the repository tree. Neither is where an overlay keystroke spends its time.

### What re-specifying a metric means, and what it does not

Two gated L1 rows change *meaning* in this phase, which §3 permits and silent drift does not:

- **`launch_to_typeable_ms`** meant "first frame presented with a first responder accepting
  keystrokes", on a screen that was a peer list. It now means typeable **in a document** —
  a stricter claim, and the reason Beam launches into an *empty untitled buffer* rather than
  restoring a file: reading a file would put I/O inside a launch budget in exchange for
  nothing a user asked for. `beam <path>` opens that path; `⌘O` is one key away.
- **`launch_to_peers_visible_ms`** was premised on the roster being the launch screen. It now
  means: process exec → the first frame **presented** carrying a peer's chip in the status
  line. The instrument is unchanged (a `presentedTime`, not a model callback) and §5.2's fade
  floor still applies, so the frame that claims the number is a frame a human could read.

A third row changes what it *measures*, in the same spirit:

- **`idle_cpu_foreground_alone_pct_core`** ran a bench that never started discovery. That was
  a fair proxy while Beam idled on a roster whose whole job was discovery; it is not one now
  that Beam idles on a **document** with discovery running behind it. `--bench-idle` starts
  discovery, so the bench measures the state the product actually has. This is a strictly
  *harder* measurement on the same instrument — measured 0.085% of a core without it and
  0.101–0.118% with, so background discovery costs about 0.02–0.03% of a core, and the row
  sits on its 0.1% design budget well inside its 0.5% gate.

All three are re-specified in `budgets.json` with the reason, **before** any number moved, and
no budget is loosened. A fourth, `join_gesture_to_code_visible_ms`, keeps its meaning exactly:
reaching the peer list is a keypress now, but *the gesture is still the peer's number*, and the
mark still starts there — opening a list is navigation, and the time a human spends reading one
is not ours to budget.

## 5.4 Phase 1.5 design of record — version control first, and a shell that earns its chrome

§5.3 made Beam an editor. This section makes it a **version-control tool that you
happen to edit in**, and gives it the modern shell that implies. It is the second
deliberate amendment to Pillar 4, it is larger than the first, and it is written
down for the same reason: the plan is only useful if it says what the product is
*now*.

### What is being amended, and the one line that is not

**Pillar 4's "no menus/toolbars/panels" is retired as a rule and kept as a
budget.** §5.3 already replaced it with *chrome vs. capability*; §5.4 goes
further and admits chrome — a menu bar, document tabs, a left icon rail, a
changes list, a diff view. The lineup test is retired with it: Beam will look
like a modern Mac editor, because a tool people are supposed to run their
version control in has to be legible on sight, and "it looks wrong next to VS
Code" was a proxy for *fast and uncluttered*, never a goal in itself.

**What is not amended, and must not be:** *no AppKit control anywhere inside the
window.* This is the one constraint that is load-bearing rather than aesthetic —
it is why the entire UI is instanced draw calls out of one glyph atlas, why the
idle loop is at 0.1% of a core, and why `keystroke_to_commit` is 0.34 ms. Tabs,
the icon rail, the changes list, the diff view and the commit sheet are all
**instances in the grid**, drawn from the atlas, exactly like the join code is.
The single exception is the **system menu bar**, which lives outside the window,
costs zero window pixels and zero draw calls, and is where discoverability
belongs on macOS.

Every budget in §3–§5 still applies unchanged, and the same rule governs: budget
first, prove the bench red, never merge red.

### Change 1 — The shell: chrome that costs no vertical space

The insight that makes this free: **rows 0–2 are already empty**, reserved for
the traffic lights, and §5.3 put only the filename in row 1. Vertical space is
won, not spent.

- **Document tabs live in the title-bar band** (rows 0–2), starting past the
  traffic lights on the §5.2 margin. They replace the filename row, so the
  editable area *grows* by two rows while gaining tabs.
- **A left icon rail**, three cells wide, drawn as atlas glyphs: files, changes,
  history, peers. It is vertical, so it costs **zero** editing rows — the one
  place chrome is genuinely free on a wide screen. The gutter's line numbers
  shift right by the rail's width and the code margin follows.
- **The system menu bar** carries every command, grouped and with its key
  equivalents shown. It is the answer to "I want menus" that costs no window
  space at all. The **command palette (⌘⇧P)** is the same command table rendered
  in the grid, so there is one list of what Beam can do and two ways to reach it.
- **One status row** absorbs the branch, the ahead/behind counts, the dirty file
  count, presence and the latency readout.

Net: two more editing rows than §5.3, with tabs, a rail and menus added.

**Landed 2026-08-30.** The accounting, exactly: §5.3 spent five rows on
non-document chrome — row 0 blank, row 1 the filename, row 2 blank, a blank
above the status line, and the status line. §5.4 spends three — row 0 blank,
row 1 the **tab strip**, and the status line. The document now starts at row 2
and runs to the status line with nothing between. **+2 editing rows, with tabs,
a rail and a full menu bar added**, which is the whole argument that this chrome
pays for itself.

Details worth not re-deriving:
- **A rail icon is two cells wide.** A cell is 1:2, so the only way to draw a
  square icon — and an icon is square — is across two of them; each is one path
  rendered over two adjacent atlas slots. The rail is 4 cells and the icons are
  centred in it.
- **The gutter moved, the code column did not move much.** Line numbers now hang
  between the rail and the text, so `codeCol` is `max(railCols + 4, digits +
  railCols + 2)` — column 8 for any file under 100,000 lines. Horizontal is the
  axis Beam has to spare; vertical is the one it does not.
- **The peers rail icon takes a peer's colour when someone is nearby**, rather
  than merely brightening. The rail then carries presence in the same language
  the status line and the peer overlay already use instead of inventing a second
  one (§5.2, the identity set).
- **`--dump-scene` prints an icon's two cells as the same letter** (`ff`, `pp`),
  so the rail is one glance in a diff rather than two mystery slots.

*Budgeted first, and gated:* `tab_switch_to_presented_60hz_p99_ms`, at the same
budget as a keystroke — **a command is input**, so undo, tab switching and
opening the palette all enter the same hybrid render loop and are accounted like
typing. `draw_calls_per_frame` stays at budget 2: the rail and the tabs are
chrome-plane instances and earn no third draw.

### Change 2 — Version control as documents, not as a panel

The design rule that keeps this from becoming an IDE: **a diff is a document.**
It opens as a tab, it lives in the same grid, it scrolls and selects with the
same code, and the peer-presence machinery works in it unchanged because it is
not a special surface.

- **The diff ribbon is always on**, in the gutter beside the line numbers:
  added / modified / deleted against the index, in three palette slots. Zero
  chrome, and it is the single highest-value git affordance in any editor.
- **Staging is selection.** Select lines in a diff (or in the editor) and stage
  them with one key. There is no hunk widget, no checkbox column, no "stage
  hunk" button — the selection you already have *is* the granularity, which is
  the simplest interaction any git GUI has ever offered for the hardest part of
  using git well.
- **Changes** in the rail is a list of modified files; choosing one opens its
  diff tab. **History** is a commit graph rendered in the grid; choosing a commit
  opens *its* diff tab. Everything funnels into the same viewer.
- **Where git comes from, decided by measurement, not by preference.** Start by
  shelling out to `git` off the main thread with cached results — no dependency,
  no binary growth on a 551 KB binary, and nothing on the keystroke path.
  `libgit2` is the fallback and it is taken only if a budget demands it, exactly
  as `yrs` and tree-sitter are handled elsewhere in this plan.

*Budgets first:* `git_status_to_ribbon_ms` (repository → gutter ribbons on the
glass); `diff_10k_line_file_to_first_paint_ms`; `stage_selection_to_presented_ms`;
`keystroke_to_commit_p50_ms` **unchanged** — git work never touches the
keystroke path, and that row is the enforcement.

### Change 3 — The novel one: a commit is something two people make together

Every git GUI in existence is single-player. You commit your work, they commit
theirs, and you meet at a merge. Beam is the only tool where two people are in
the same document at the same instant, so it is the only tool that can make the
*commit* a shared act rather than the place where sharing stops. This is the
part that is actually new, and it is built almost entirely from machinery Beam
already has.

- **The staging area is shared while a session is live.** Both people see the
  same staged lines, tinted in each other's peer colours: you can watch someone
  stage lines 40–60 of `renderer.rs` as they do it. Awareness already streams;
  a staged range is awareness.
- **A commit is *proposed*, then confirmed on both screens.** One person writes
  the message, both see it live, and it lands when both confirm. This is exactly
  the join code's shape — a thing that requires two screens to agree, one
  keypress each — reused rather than reinvented, and the same reasoning applies:
  the confirmation is what makes the shared act real.
- **Line-level authorship, captured live instead of reconstructed.** Beam already
  knows who typed which bytes, at the keystroke, in the session. A co-authored
  commit can therefore carry true per-line attribution — not `git blame`'s
  guess-by-last-toucher, but who actually wrote it, recorded as it happened.
  `Co-authored-by:` trailers make it legible to every other git tool; the
  in-Beam history view colours each line by its real author.
- **Shared diff reading.** Because a diff is a document, opening one in a session
  shows your peer that you are reading it, and shows your cursor in it. Reviewing
  together stops being a screen share.

*Budgets first:* `staged_range_to_peer_presented_ms` (an awareness row, gated
like the cursor row); `commit_proposal_to_both_screens_ms` (the join code's
budget, reused); `bytes_per_staged_range_on_wire`; and the L7 idle row, because
a shared staging area is exactly the kind of feature that starts repainting on a
timer.

### Order, and what it depends on

1 → 2 → 3, and **not before Phase 1's gate is green**: the shell change moves the
layout every §5.3 bench measures, so it needs a validated baseline to move
against. Change 3 also wants Phase 3's `yrs` and its awareness channel to exist
before shared staging is built on top of the Phase-2 op stream; the parts of it
that do not (the proposal/confirm gesture, authorship capture) can land earlier.

## 5.5 The caret — what §5.1 got right, and what it got wrong

§5.1 refused to blink, and §5.2 refused to ease. Both refusals were argued from
performance, both were written into the plan as principle, and **one of them was
wrong**. Separating them is the whole of this section, because the wrong one was
costing Beam the single most recognisable "this is a terminal" signal in the
product: a fat block sitting on top of the character you are about to type.

### The refusal that stands

**Position never animates.** A caret that slides to where you typed manufactures
perceived latency in the one product that exists to delete it, and it does so on
the exact path — keystroke to glass — that every budget in §5 is about. The caret
lands. It has always landed and it always will.

### The refusal that was wrong, and why

§5.1 said: *"A blinking cursor is an infinite animation; it would pin the display
link awake forever and put a permanent floor under idle CPU."* Every clause of
that is true, and the conclusion does not follow. The rule the project actually
needs — stated correctly two paragraphs earlier in the same section, about fades
— is that **nothing may animate forever**. A blink that *stops* is finite, and
finite was all the rule ever required.

So the caret now: rests solid while you type and for half a second after, pulses
while you are still, and **stops pulsing after ten seconds** and rests solid
again. The display link pauses, idle CPU returns to zero, and the rule is intact.
It also happens to be better behaviour than a caret that blinks forever — a blink
means "waiting for you", and after ten seconds of stillness that is no longer
information.

### The shape

A **thin vertical bar**, two points wide, on the cell's left edge, full cell
height, in its own palette slot. Three things were wrong with the block:

- It **covers the character it sits on**, which is the character you are about to
  type over — the one you most need to see.
- It reads as a *selection*, because on this grid a filled cell is what a
  selection is. The caret and the selection were the same shape in different
  colours.
- It is a terminal's caret, and it is drawn that way because a terminal cannot
  address anything narrower than a cell. Beam can: the bar is a glyph in the
  atlas like everything else, so a sub-cell shape costs exactly what a full-cell
  one costs.

Your caret and a peer's caret are now different glyphs as well as different
colours — yours is an insertion point, theirs is a presence mark, and they should
not be the same object in two hues.

### The mechanism, and where the cost actually is

The blink is a **shader function of one uniform**. The CPU passes elapsed time;
the fragment path recognises the caret's palette slot and multiplies its alpha by
a shaped cosine. Nothing in the model, the scene or the instance buffer knows
that the caret is blinking, which means a blink frame does not have to rebuild
anything — `Renderer.rePresentCaret` re-encodes the *previous* frame's instances
with a new uniform.

That was the easy part, and it was not where the cost was. Three measured
lessons, in the order they were learned:

1. **A pulse is frames, and frames are the price.** No GPU trick avoids that; a
   blinking caret means presenting. What bounds the price is making the animation
   finite, and making each frame skip work it does not need.
2. **The curve is flat for 89% of its period**, by construction: the cosine is
   shaped by a gain and clamped, so it dwells fully on, dwells nearly off, and
   ramps between them over about 64 ms. Only the ramps need frames — roughly
   seven presents a second rather than sixty.
3. **The 60 Hz tick was the real cost, not the presents.** The first
   implementation skipped the *present* during the flat portions but still ran
   the display-link callback sixty times a second for ten seconds, doing
   trigonometry and asking AppKit whether the window was key. Measured **2.0% of
   a core against a 0.5% budget**. The fix is to sleep: the tick computes when
   the curve will next move, pauses the display link, and sets a one-shot timer
   for the ramp. The loop then runs only while something is actually moving.

`caret_blink_cpu_pct_core` (budget 0.5% of a core, gate 1.0%) is the row that
keeps all of this honest, and `idle_cpu_foreground_alone_pct_core` keeps its
original meaning because `--bench-idle` now measures a *second* window, after the
blink has finished. Measuring only the first would have quietly redefined the
idle gate into a caret gate; measuring only the second would have left the
caret's cost ungated entirely.

### The finding: an idle bench is not exempt from validity

`--bench-idle` was the last timed bench in the project with no validity check,
and it looked like the one that could justify not having one — it measures a
process doing nothing, so what is there to see? Exactly the wrong way round. **On
an occluded screen every present is dropped, and a dropped present makes the
render loop recover, which wakes the display link — which is precisely the thing
being measured.** Occluded, it reported **1.3% of a core** for code that measures
0.1%, and it published the number, because nothing stopped it.

It now counts presents that reached the glass and refuses below 90% delivery,
the same ground-truth check `--bench-join` and `--bench-editor` use. That is the
third time `NSWindow.occlusionState` has been believed and the third time the
answer was to replace the proxy with the ground truth (§5-L2, §5.3, here). The
rule is now general enough to state once: **a bench that reports a timing without
proving its frames reached the glass is reporting fiction, whatever it is
measuring.**

## 6. Phases (each ships its benchmarks first; no merge red)

**Phase 0 — Skeleton + harness.** Nothing else starts until green.
- Metal window rendering a monospace grid via glyph atlas; keystroke echo; block cursor; HUD v0 (live p50/p99 vs budgets.json).
- Bonjour advertise + browse behind the TCC prompt; TCP echo between two processes with `noDelay`.
- `perf/budgets.json`; benches: launch, typing latency, TCP echo/Nagle, discovery, deterministic counters — one command (`scripts/bench.sh`), JSON out, gate judges.
- Every timing bench proven able to go red via sabotage hooks; proof recorded in `perf/harness-proof.md`.
- Packaged-.app build + direct-binary launch verification; CI tier 1.
- `--flash-on-key` calibration mode; camera calibration of the render path (rig session; offset recorded in budgets.json).
- *Exit: all of the above runs on one command, publishes JSON, gates in CI, and has been proven red.*

**Phase 1 — The editor that types faster than anything.** Design of record: §5.3.
- **Present-path engineering** (the §5-L2 finding): recover the extra frame the naive one-shot present pays — display-link-aligned presents, `presentsWithTransaction`, direct-to-display — each lever accepted or rejected by measurement, photon-verified by camera. Target: 60 Hz presented p50 back under ~13 ms, then ProMotion. **Still open** — the render-loop rework landed (§5-L2) but the extra frame itself has not been cut, and it remains the headline objective.
- **Done:** gap-buffer text storage with a raw-coordinate line index; real editing on the glyph grid — selection, pixel-quantized scrolling, mouse, undo/redo at depth; single file open/save; a dynamic glyph atlas with LRU eviction and correct one-cell-per-scalar UTF-8; the GUI vocabulary (filled surfaces, gutter, hover, focus, scroll indicator) on two draw calls; the file and peer overlays; presence moved onto the status line.
- Camera-verified local latency beating every L2 budget on the rig.
- Syntax highlighting only if it survives the latency gate. **Landed as an incremental line lexer, not tree-sitter** — the reasoning is in §5.3, and §6's original commitment is unchanged: it merges only with L2 still green and is reverted if the L2 rows move.
- IME milestone begins here (marked-text protocol correct even if compositions render plainly). **Still open.**
- East Asian width joins bidi and accessibility on §1's named list (§5.3): one cell per scalar is Phase 1's documented limit.
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

**Phase 1 (editor):** *running now* — open-1 MB-file→first paint; typing inside a 1 MB document (the same budget as an empty one, so document size cannot hide in latency); full-speed scroll wheel→presented and dropped frames; selection-drag→presented; the overlay's per-keystroke filter cost; one line of syntax lexing; one atlas miss; undo at 10k depth. *Still ahead:* queue-transit segment (NSEvent.timestamp → keyDown entry — real IOHID input only; the segment no web editor can see; HUD + camera sessions); scroll→photon on the rig; IME marked-text correctness + latency.

**Phase 2 (presence/session):** *running now* — launch → peer row presented; join gesture → code on both screens; confirm → editing; gesture → first shared keystroke presented on the peer's screen; bytes/keystroke on the wire; connected idle CPU (the gate that keeps live-RTT-in-the-UI honest). *Still ahead:* discovery under mDNS-hostile APs (broadcast-fallback path); TCC-denial UX correctness (denied permission must surface in ≤1 s, never an empty peer list).

**Phase 3 (multiplayer):** occluded-peer catch-up — hidden window keeps applying remote ops (bytes applied while hidden ≥ sender's bytes sent), reveal repaint ≤ 1 frame; AI-scale paste (400-line insert → remote presented ≤ 2 frames, the predecessor's measured basis); typing-under-sync-storm (local p99 while receiving 10k ops/s); relay stall-immunity (≤5 ms under 200 ms host main-thread stall); Wi-Fi power-save spike detector (continuous RTT histogram, spike-count gate); AWDL vs. infrastructure variance matrix before trusting AWDL.
- **Cross-machine, clock-free:** all E2E via RTT/2 + d_remote (§3.1); camera verifies the constant.

**Phase 4 (groups/polish):** join-storm (N guests connect simultaneously → all editable ≤ 2 s); reconnect diff after 60 s partition; thermal soak (p99 after 30 min sustained collab vs. cold — throttling detection); battery-vs-plugged latency delta; external/multi-display present path (the compositor behaves differently per display); 8 h soak (RSS, FDs).

## 8. Rig

Two machines on a dedicated unmanaged GbE switch (isolated), one Wi-Fi AP for the wireless matrix, one 240 fps phone camera. L0 floor measured per rig with `ping`/`irtt` + `iperf3` and recorded in `perf/results/l0-floor.json` before any rig gate is trusted. The 120 Hz (ProMotion) machine hosts the photon gates. Until the rig exists, rig-tier metrics report "missing" (not failing) in the gate; the dev machine gates the 60 Hz software rows.

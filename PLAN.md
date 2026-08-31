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

### What the design passes found (2026-08-30)

Change 1 was explored by **three agents working in parallel** — one critiquing
the rendered screenshots without touching code, two building in isolated git
worktrees on separate lanes (chrome/layout, and typography/colour) so their
edits could not collide. Everything below came out of that and is recorded
because most of it is not taste.

**Four defects that were shipping, none of them visible as "a bug".**

- **The window was never centred.** `cols` and `rows` truncate, and the grid
  origin was the constant `(cellWidth, cellHeight/2)` — so the entire truncation
  remainder landed on the right and bottom edges: measured **18 px left against
  34 right, 18 top against 38 bottom**. In a window that is nothing but content,
  every edge inherits that. It is the diffuse "floats up and to the left" that no
  single element explains, and it survived two visual sessions because nothing
  was *wrong*, only unbalanced.
- **§5.3's "one alignment grid" was false on every real file.** `tabCol` was
  pinned at 8 while `codeCol` grew with the line count; they agreed only under
  100 lines, which is exactly the size of the sample document every screenshot
  used. The gutter is now a fixed five-cell *field* rather than a fixed column.
  A seeded state that hides the failure it was built to catch is worse than no
  seeded state, and the sample document is now the wrong size on purpose.
- **The caret's palette entry was out of gamut.** It declared L 0.930 / C 0.075 /
  H 225; `#B1F3FF` clips the blue channel and actually renders at **H 210**. The
  design table documented a colour the GPU has never drawn. Every OKLCH entry in
  that table is now checked for clipping, because a design system whose numbers
  are aspirational is a design system that lies.
- **`.faint` (3.2:1) was below AA on seven jobs**, including the gutter and
  inactive tab labels — so an inactive **tab** was dimmer than a code
  **comment**. One slot had accumulated every "secondary" role in the product.

**The tonal inversion, and why it needed no new colour.** The active tab was a
*lighter* fill on the ground, which is the silhouette of a selected row in a
list. Modern editors invert it: the frame recedes and the front tab *is* the
page. Beam's ground was already its darkest ink, so the recess is `scrim` at
partial coverage and **the active tab is the absence of it** — literally the
same pixels as the document one row below, with the ground never named twice.
Two hairlines were then deleted rather than kept, because the recess already
drew those boundaries.

**One curve, three implementations, two desyncs in one day.** The caret's blink
is evaluated in the shader, mirrored on the CPU as a change detector, and
inverted again to predict when to wake the render loop. The prediction used the
moments a ramp *ends* as if they were where one *begins* (caught by a bench that
samples the prediction against the curve — 326 violations); and the shader and
the CPU disagreed about the gain, so the CPU slept through stretches where the
alpha was still climbing. Both are the same mistake. The gain, floor and period
are now single constants the shader interpolates and the CPU reads.

**A process note worth more than any of the above.** Git worktrees branch from a
**commit**, so an agent given one sees nothing uncommitted. The first pair were
quietly iterating on the *pre-Phase-1* codebase — spotted only because a build
log listed a file that had been deleted hours earlier. Parallel exploration on
uncommitted work is exploration of the wrong thing; commit first, always.

**What the critique protected, which matters as much as what it changed.** Three
things were named as already good and not to be traded away in a redesign: the
gamma-correct pipeline and whole-pixel grid; the deliberate separation between
the syntax band and the peer-identity band, which is why a collaborator's caret
can never read as a keyword (most editors get this wrong by giving collaborators
theme colours); and the caret itself. A design pass that only knows what to
change will regress the things nobody thought to defend.

**One trade declined.** Bleeding the recessed chrome to the window's edge needs a
per-row ground fill beneath the document — about 3,500 extra instances every
frame, on the keystroke path, roughly doubling a 0.34 ms commit — to reclaim a
26 px inset that reads as window padding. In this product that is the wrong way
round, and it is recorded here so it is not re-proposed as an oversight.

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

## 5.6 Animation, as an engine capability

Beam needed hover states, and hover states need a fade. Rather than add a
second animation mechanism beside the caret's, both now run on one:

> **Every palette slot carries a phase in `0...1`, and the shader multiplies it
> into the alpha of every instance drawn in that ink.**

Fading a thing is therefore not a property of the thing at all — it is a
property of **the colour it is drawn in**. Three consequences, and they are the
whole argument:

- **Zero bytes per instance.** `Instance` is eight bytes and both halves of its
  `color` word are already spoken for: eight bits of ink, eight of alpha. An
  animation id would have had to widen it — on the keystroke path, forever, for
  every glyph on screen. Keying off the ink costs nothing, because the ink is
  already there.
- **Zero branches in the shader.** One array index and one multiply. It replaces
  the special case the caret used to need and is *strictly cheaper than what it
  generalises*.
- **One implementation of every curve.** The easing lives on the CPU
  (`BeamCore.Animator`) and the GPU is handed a number. The caret's blink was
  previously evaluated in the shader *and* mirrored on the CPU as a change
  detector, and those two desynced twice in a single day (§5.5). There is now
  one place a curve can be wrong.

**Finite by construction**, which is what the entire idle-CPU budget rests on
(§5.1). A transition has a duration, `step` reports when nothing is moving, and
the render loop goes back to sleep. Nothing can animate forever unless a caller
re-arms it every frame — which the caret does, deliberately, inside its own
finite window.

### What hover costs, and why it is nearly nothing

The rule §5.3 set — *no editor-wide mouse tracking, because it wakes the render
loop on every motion* — is kept, by making it precise instead of absolute. The
tracking areas cover **the tab strip row and the rail column, and nothing else.**
A pointer moving across code generates no events at all. A pointer moving across
chrome generates one event per motion and a **repaint only when the target
changes**, not per pixel. Between transitions the phase is pinned at 0 or 1 and
no frames are needed at all.

### What makes it read as modern rather than as a rectangle

Two things happen together, and the second is the one most implementations
skip: the tile fades in, **and the content itself brightens**. A tab's label and
a rail's icon are drawn twice — once at rest, once in `hoverText` — and the
phase cross-fades the bright copy in over the resting one. A hover where only a
rectangle appears is a rectangle appearing; a hover where the thing you are
pointing at *warms up* is what the eye reads as responsive.

Two calibrations that are not taste:

- **The hover tile is drawn at partial alpha on recessed chrome.** At full
  strength a hovered background tab came out *lighter than the front tab*,
  which inverts the hierarchy: the thing under the pointer must never outrank
  the thing you actually have open. Alpha and the animation phase multiply, so
  that is one lever rather than two.
- **Moving between two adjacent targets keeps the phase.** The highlight travels
  at full strength and fades only at the edges of the strip — which is what a
  good tab bar does, and what a cross-fade between neighbours would get wrong.

### The fast loop

`scripts/check.sh` is the companion to `scripts/gate.sh` and exists because most
interface work does not need the photon benches: it builds, runs the headless
correctness suite, lays out every surface through `--dump-scene`, and writes
every screenshot — in well under a minute, with **no display at all**. The gate
stays what you run before merging. A design loop that costs minutes per look is
a design loop nobody takes enough turns of.

`--screenshot` renders the *settled* frame, so a hover state has nothing to show
at rest; a `SceneStates.State` may therefore pin the phases it is about. That is
why `hover-tab` and `hover-rail` are surfaces the tools can draw at all.

## 5.7 Density, weight and information — design of record

Beam was put beside VS Code and four things came back: **whitespace, zoom,
heavier menu icons, a status bar that means something.** The complaint under all
four is that Beam reads as a very clean *prototype* next to something that reads
as a *tool*.

This section amends §5.2's composition and §5.4's shell. It does **not** amend
§5.3's chrome/capability rule: nothing here adds a panel, a sidebar or a
toolbar, and the lineup test in §5.3 still passes. The gap being closed is
**density, weight and information** — three things a product acquires when it
stops being afraid of its own pixels — not chrome.

### The cell is 1:2 by *derivation* now, not by luck

Zoom could not ship until this was decided, because it is not a detail.

`lineHeightEm = 1.30` was chosen in §5.2 as a designed number, and at the
shipping em (28 px at 2×) it happens to produce a cell of **18×36** — exactly
1:2. Every shape glyph in Beam is built on that accident:

- **the rail icons**, which are square paths drawn across *two adjacent cells*
  precisely because a cell is half a square (§5.4);
- **the join code's block "pixels"**, which are square by construction as `2s`
  cells by `s` rows (§5.2) — the screen the entire security model rests on;
- and, less visibly, the chip, the caret and the accent bar, all sized from
  `scale` and a cell edge.

Measured across the range a zoom control would reach (SF Mono, 2×, the shipping
`max(...)` ink guard applied):

```
 pt   em   cellW   cellH @1.30em   2·cellW   1:2 ?
  9   18     12         23           24      BREAKS
 10   20     13         26           26      holds
 11   22     14         29           28      BREAKS
 12   24     15         31           30      BREAKS
 13   26     17         34           34      holds
 14   28     18         36           36      holds      <- today
 15   30     19         39           38      BREAKS
 16   32     20         42           40      BREAKS
 17   34     22         44           44      holds
 18   36     23         47           46      BREAKS
 20   40     25         52           50      BREAKS
 22   44     28         57           56      BREAKS
 24   48     30         62           60      BREAKS
```

Four sizes out of thirteen hold. A zoom control built on `lineHeightEm` as an
*input* would therefore break the rail, the join code and the caret at nine of
every thirteen steps — silently, because nothing in the pipeline asserts it.

**The decision: `cellHeightPx` is derived as `2 × cellWidthPx`, and
`lineHeightEm` becomes a checked consequence rather than an input.**

The alternative was to stop assuming 1:2 in the icon geometry — draw icons into
`min(2·cellW, cellH)` centred in their two-cell box. It was rejected for a
reason that is structural rather than aesthetic: **it only fixes the rail.** The
join code's square pixel is the same assumption, on the one screen in the
product that is making a security promise, and "the digits are slightly oblong
at 15 pt" is not a trade this product gets to make. One derivation fixes every
shape glyph at once; the alternative fixes one of them and leaves the rest to be
rediscovered.

Three things make the derivation cheap rather than a compromise:

- **At 14 pt it is a no-op.** 1.30 em rounds to 36 and 2·cellW *is* 36, so the
  shipping cell is byte-identical and this session's zoom work introduces no
  visual change at the default size. The design of §5.2 is not being reopened;
  it is being generalised through the size it was designed at.
- **§5.2's ink rule survives unchanged.** The cell must still clear the font's
  *real* ink extents, because SF Mono's `|` overshoots its own declared descent
  — so the derived height keeps the same `max(...)` guard. Measured, that guard
  **never binds** for SF Mono between 9 and 24 pt (worst case 24 pt: ink needs
  50 px, the derivation gives 60), so 1:2 holds at every step rather than
  holding "usually". The guard stays because it is a guard: it is what catches
  the Menlo fallback, or a face with a deeper descender, and it must fail loudly
  by making a cell taller rather than quietly by clipping a glyph.
- **The line height it implies stays inside the designed band.** Across the
  ladder it ranges 1.25–1.33 em, against §5.2's chosen 1.30, its rejected 1.36
  and the terminal-tight 1.16–1.18 it was chosen over. The variation is smaller
  than the decision §5.2 already made and lands on 1.286 at the shipping size.

**The zoom ladder** is therefore free to be chosen for how it *feels* rather
than for which sizes the grid tolerates: **10, 11, 12, 13, 14, 15, 16, 18, 20,
22, 24**, default 14. Fine steps around the default, where people actually
adjust, and coarser at the ends.

### Zoom, and what it costs

`⌘+` / `⌘−` / `⌘0`, over the ladder above. `pointSize: 14` was a literal in six
places — `AppDelegate`, `Screenshot`, `SceneDump`, `SceneStates` (twice) and
`TextBench` — which is survivable while a number is a constant and is exactly
the shape of bug that appears the moment it stops being one. It is `Zoom` now,
and the tools read it from there.

**A zoom step is input, and is budgeted like input.** It enters the same hybrid
render loop as a keystroke, through the same `perform`, and
`zoom_step_to_presented_60hz_p99_ms` is set at **34 ms / gate 38** — the
keystroke budget and the tab-switch budget, for §5.4's reason: *a command is
input*, and a zoom slower than typing is a zoom people stop using. It is the
most expensive command Beam has, and the budget says that being expensive is not
the same as being allowed to be slow. The number was written before the first
measurement, per §3, and `BEAM_SABOTAGE_ZOOM_DELAY_MS` proves it can go red.

Four things happen together and none are optional:

1. **The atlas is rebuilt** — 95 ASCII glyphs and every shape glyph, at the new
   cell. The pipeline state, the shader and the instance ring are deliberately
   *not* rebuilt: recompiling a shader inside a keystroke budget would be absurd.
2. **The glyph cache is evicted, and that is the correctness half.** `GlyphCache`
   maps a scalar to an atlas *slot* and remembers which scalar is in each one.
   Those slots index a texture that no longer exists, and the new texture has
   nothing in them — so a cache carried across a rebuild hands out slots that
   draw blanks, silently, for every non-ASCII character on screen. The ASCII
   fast path never consults the cache, which is precisely why it would have
   hidden this rather than exposed it.
3. **The scroll is rescaled in lines, not pixels.** `scrollPx` is device pixels
   against the *old* cell; carried over it would move the document by the ratio
   of the two cell heights.
4. **The tracking areas are rebuilt**, because the tab strip and the rail are in
   different pixels now.

And a second row, because the risk a zoom feature actually carries is not that
the step is slow but that it leaves something behind: **`keystroke_to_commit_zoomed_p99_ms`,
at the same budget as the unzoomed row.** Point size must not be visible in
typing latency. The commit path builds the same instances at any size, so a
regression there means a stale cache is being consulted per character, or a
metric is being recomputed where it should be read.

**`--screenshot --point-size <pt>`** renders any surface at any step, so the
ladder is reviewed by eye rather than trusted. It earned itself immediately: the
first run showed the seeded states publishing *default* cell metrics into the
model while the renderer drew at 24 pt, so the scroll arithmetic belonged to an
18×36 cell and the glyphs to a 30×60 one, and the document stopped eight lines
short of its own viewport. That is the same drift the owned point size exists to
prevent, one level up in the tools rather than in the product.

### What the gate found when the editor bench finally published

The bench had never completed a run in the history of this branch, so
`perf-gate` had never seen four of its rows. Fixing it did not create four
failures; it revealed them. **They are not regressions from this section's
work** — the numbers are the same on the pre-§5.7 commit, measured in this
session's first gate run before anything visual had changed:

```
row                              pre-§5.7   §5.7    budget / gate
scroll_wheel_to_presented          49.13   49.12      34 / 38
overlay_keystroke_to_commit        12.68   12.71       4 /  8
tab_switch_to_presented            42.38   41.62      34 / 38
selection_drag_to_presented        41.55   45.62      34 / 38
```

The three presented rows share a cause, and it is methodological rather than a
slow path. **They drive input faster than the display refreshes** — the scroll
pass at 8 ms (125 Hz), the drag at 16 ms, the tab pass at 23 ms — and the render
loop coalesces within a frame and then charges that frame its *oldest* pending
input, which is the worst-case-honest accounting §5-L2 chose deliberately. Input
arriving faster than 60 Hz therefore adds close to a frame, systematically. That
is exactly what `burst_125hz_presented_p99_60hz_ms` exists to measure, and why
it carries 44/60 rather than 34/38.

The rows were given the keystroke budget on the reasoning that scrolling "is the
same present path", which is true, and which quietly assumed scroll and drag
arrive at keystroke rates. A trackpad delivers 120 Hz. The two §5.7 rows paced
at 23 ms — `zoom_step_to_presented` at **33.4** and `keystroke_to_commit_zoomed`
at **0.76** — pass, which is consistent with the same explanation.

**No budget was moved.** §5.3's rule is that a metric is re-specified *before*
any number moves and never loosened, and these numbers are now on the table, so
the decision belongs to a session that has not seen them. The two honest options
are to pace the passes at a rate a human actually generates, or to re-specify
the rows the way §5.3 re-specified `launch_to_typeable_ms` — argued on the
merits, not against a measurement.

`overlay_keystroke_to_commit` is a different animal and is **not** about the
candidate set: it measured 12.68 against 94 candidates and 12.71 against 2,001,
so the filter is not what costs. The pass closes and reopens the overlay every
eighth keystroke, and that is the part to look at first.

### Whitespace: the top of the window belongs to the tab strip

§5.4 fixed a real defect — the grid's truncation remainder landed entirely on
the right and bottom edges, so the whole composition read as floating up and to
the left — and the fix was to **centre** the grid, splitting the remainder
evenly. Vertically that has since become the wrong answer, and §5.7 amends it.

Centring is right when both vertical edges are ground. They are not: §5.4 put
the **tab strip** on row 0 and the **status band** on the last row, so both ends
are full-bleed chrome. Splitting then buys nothing at the bottom — the status
band already overdraws past the row it claims and the GPU clips it — while at
the top it deposits 28 device pixels of ground *above* the tab strip that
nothing chose. §5.4 was already working around that strip rather than owning it:
the tab recess is laid under the tabs instead of across the row precisely so a
full-width band would not leave a lighter line along the top edge.

So the top inset is **derived from the only thing that constrains it**: row 0
has to contain the traffic lights, which occupy y 25…50 device px on a
`fullSizeContentView` window. That is `max(0, lightsBottom − cellHeight)` — 14 px
at the shipping size against 28 before, **0 from 20 pt up**, where the cell is
finally taller than the lights and the strip goes flush to the top on its own,
and larger when zoomed out so the lights can never overlap the first line of
code. The rest of the remainder goes to the bottom; the status band's overhang
goes from one row to two, because the slack there is now `h mod cellH` plus a
whole cell, which is strictly less than two.

**And the air goes where it was missing: under the tabs, for no editing row.**
The document began in the row immediately below the strip with nothing between
them. The row that would fix it is the scarcest thing in the layout — but the
**document plane already carries a whole-pixel origin offset**, which is the
machinery pixel-quantized scrolling is built on (§5.3), so the document is inset
from its own viewport by a third of a cell instead. The bottom-most row gives up
the same third, which is the same partial row any pixel-quantized scroll already
shows. `GridView.offset(atCol:row:)` applies the identical offset, because a gap
applied on one side of that pair and not the other is an editor whose clicks
land on the wrong line.

### The rail: filled silhouettes, and the only larger size there is

The icons were outlines at a 3 device-pixel stroke in a 36 px box, and at that
size a 3 px outline reads as dithering rather than as a mark — the one element
in the window whose entire job is to be a target was the faintest thing in it.
Weight was the larger half of the problem and **filled silhouettes** are the
fix; interior detail is **knocked out** of the fill rather than stroked, which
works because the atlas is one alpha channel and clearing to zero shows the
ground behind.

Size is the other half, and here the 1:2 ratio decides rather than taste. A
square icon spans `2k` cells across by `k` rows down, so the available sizes are
36 px and 72 px and **nothing in between**. §5.4 took `k = 1`; §5.7 takes
`k = 2` — a ~26 pt mark against VS Code's ~24, in a rail widened from four cells
to six (108 px / 54 pt against VS Code's 48). The row pitch follows to three
rows, so the icon sits in 72-in-108 vertically exactly as it does horizontally:
a column of square targets on a square pitch, which is what an activity bar is.
`--dump-scene` prints the whole block as one letter, computed from the block's
extent rather than listed — the list was written when an icon was two cells and
silently stopped covering it.

The peer-colour treatment is untouched: the peers icon takes a *peer's* colour
when someone is nearby, so the rail carries presence in the same language as the
status line (§5.2's identity set).

### A status bar that means something

The line carried two facts. The lexer had already resolved the **language**, the
open path knew the **encoding**, and `Document` knew its own **indentation** and
**line endings**. None of it was hidden on purpose; it was hidden because
nothing had ever asked for it.

- **Two are controls and two are readouts, and the difference is visible.**
  Language and indent open a picker on the same overlay mechanism ⌘O and ⌘K
  already use — which is the whole reason a status segment could become a
  control without adding any chrome — and are set in `dim`. The encoding and the
  line ending cannot currently be changed, so they stay `faint` and do not light
  up under the pointer. Colouring a readout as if it were a control is how a
  status bar teaches people to stop clicking it.
- **One gap, everywhere.** Three cells between every segment, against the old
  1/2/3 with no system behind it — which §5.2 already names as the difference
  between an instrument and debug output.
- **The left run yields; the right run never does.** When the two collide the
  left one drops segments from the right, so the order is a priority order — and
  it is deliberately not VS Code's, which puts the language at the far right
  where a right-truncating run would lose the most informative fact first. The
  encoding goes first here: it is the one segment that can only ever say one
  thing.
- **Indentation is detected, not assumed**, from a bounded sample off the top of
  the buffer — it runs on the budgeted open path, and indentation is consistent
  within a file or it is not a property of it at all. **Tab now inserts what the
  file already indents with.** It always inserted a literal tab, which in a
  space-indented file put an invisible mixed indent into somebody else's source
  on the first keystroke; a readout the editor's own behaviour contradicts is
  worse than no readout.

**The latency readout keeps its place and its prominence, and loses its field
labels.** It read `p50 25.8  p99 33.7 ms` — twenty-one cells, five of them spent
naming two percentiles in the vocabulary of a benchmark harness. It is now a
filled **bolt** glyph, the median, a thin separator, the tail, and the unit:
sixteen cells, the same ink, and the mark carries the budget colour with the
values so the whole readout goes red as one object rather than as two numbers
beside a label. An instrument names its quantity with a mark and a scale; only
debug output names it with a field label. Nothing about what is *measured*
changed — `budgets.json` still gates on p50 and p99 by name and §3.1 still
forbids a mean anywhere near either — and the five cells it gave back are
exactly what let all six left-hand segments fit at the default window size.

## 5.8 The four red rows, and the two things an editor may never do

§5.7 left the gate at 39 pass / 4 fail, with the decision deliberately handed to
a session that had not yet argued it. This section is that argument, plus the
two product gaps that outrank every latency number in this plan: **an editor
may not lose your work, and an editor without find is not an editor.**

### The four rows were three different problems wearing one costume

The rows were red together and were assumed to share a cause — input arriving
faster than the display refreshes. A percentile cannot confirm that. It says a
number is high; it cannot say which branch of the render loop produced it. So
the first thing built was an instrument rather than a fix: **per-pass input
accounting** in `GridView` (bench-only, behind `recorder.collectAll`), counting
for each pass how many inputs were rendered *immediately* and how many were
*coalesced* to a later tick. One run at 99.7% present delivery settled it:

```
pass                inputs  immediate  coalesced   what it means
typing @23 ms          300        300          0   the baseline: every key rendered on arrival
scroll @8 ms           239          1        238   genuinely 2x the refresh — physics
tab switch @23 ms       60         27         33   should have been 0
select drag @16 ms     201        182         19   should have been 0
overlay @20 ms         120         31         89   should have been 0
```

Three of the four were not the stated cause at all.

### The defect: an animation frame was closing the frame's input fast path

§5-L2's hybrid loop renders **the first input of each frame** immediately and
coalesces the rest, which is what keeps ordinary typing off the half-frame tax
that full coalescing measured (commit p50 0.31 → 9.56 ms). The flag that
recognises "the first input of each frame" was set by *any* render — including a
tick that fired only because an animation was running.

So the fast path switched itself off for the whole duration of any animation. A
keystroke arriving in a frame an animation had already painted was deferred to
the next tick and charged the wait. The file overlay is where this is worst,
because its open fade runs for 200 ms and the pass re-arms it faster than it can
finish: **commit p50 5.24 ms, against 0.33 ms for the identical keystroke pass
in the document.** The exact tax the hybrid design exists to prevent, in the one
surface that animates, invisible because no row measured a keystroke *during* an
animation.

`renderedThisFrame` is now `renderedInputThisFrame` and only an input render
sets it. The bound that matters is unchanged: sustained input faster than the
display still produces exactly one input render per frame, so burst coalescing
and the 2-deep drawable queue are untouched — at most one animation frame and
one input frame, which is the same pair `wake-double-present` already presents.

After it: tab switch 60/60 immediate, overlay 120/120, drag 198/201, scroll
(paced) 118/119. **This is a product fix, not a measurement fix** — three rows
go green because typing during an animation actually got a frame faster.

### Scroll: one row was answering two questions, so it is two rows

Scrolling is the one row where the original diagnosis holds. At 8 ms (125 Hz)
roughly half of all wheel events *cannot* be first-in-frame, because on a 60 Hz
panel there is no frame for them. The loop coalesces them — correctly, since
every delta is applied and the picture on the glass is complete — and charges
the frame its oldest pending input, which is §5-L2's worst-case-honest
accounting.

The row's own note says what it is for: *"same budget as the keystroke row
because it is the same present path"*. That claim is only testable at a rate the
display can serve. Above it, the number stops describing Beam and starts
describing the refresh rate. So:

- **`scroll_wheel_to_presented_60hz_p99_ms` keeps its budget — 34 / 38,
  untouched — and its pass is re-paced to one event per display frame** (23 ms,
  the pacing every other presented row uses). This is a re-specification in
  §5.3's sense: the instrument is unchanged, the budget is unchanged, and what
  the row *claims* is stated correctly instead of being assumed.
- **`pointer_burst_125hz_presented_60hz_p99_ms` is new**, at 8 ms, and its
  budget and gate — 44 / 60 — are **inherited verbatim from
  `burst_125hz_presented_p99_60hz_ms`** rather than chosen. It is the same
  phenomenon, the same loop, the same accounting and the same panel, differing
  only in which event drove it, and this project decided what that phenomenon is
  worth before it had any of these numbers. It exists as its own row because the
  pointer path is not the key path: the document plane carries the scroll offset
  in its origin plus a scissor rect (§5.3), so "scrolling falls apart under a
  real trackpad" deserves measuring rather than assuming.

Nothing is given up by the split, which is the whole argument. Smooth scrolling
under a real trackpad is two properties: no skipped frames — gated at zero by
`scroll_dropped_frames_pct`, now measured on the burst pass where a skip could
actually happen — and the coalesced tail, which is now a gated row instead of
being averaged into a claim about the present path. Coverage strictly increases
and no budget moved.

**The selection drag was a bench bug, not a design question.** 16 ms against a
16.7 ms refresh drifts 0.7 ms a step, so about one drag in twenty-four landed in
a frame that already carried one — 182 immediate against 19 coalesced, with the
entire p99 coming from those 19. That is a beat frequency between the bench and
the display. It is paced at 23 ms now, and the budget did not move.

### A validity rule applied to itself

`--bench-editor` and `--bench-typing` both refused to publish if
`NSWindow.occlusionState` had *ever* reported occluded, **or** if present
delivery fell below 90%. The first half is a proxy this plan has discredited
three times (§5-L2, §5.3, §5.5) and it aborted a valid run mid-session at **99%
delivery** (1011 of 1017 presents).

Both directions of the lie matter and only one is dangerous. The proxy reports
*occluded* for any window whose app has not activated — most runs on a machine
somebody is using — and it reported *visible* while a screensaver dropped every
present. The delivery ratio catches the dangerous direction by construction: an
occluded window's presents are dropped by WindowServer, so fiction cannot reach
90%. Partial occlusion is bounded by the same number, since a pass that ran
occluded contributes all of its presents as drops — 90% caps how much of a
published run could be fiction at a tenth of it.

So **ground truth decides and the proxy is reported, never believed.** §5.5
already states the general rule; this is that rule applied to the benches that
were still hedging it.

**And `--bench-idle`'s failure message was lying about which guard tripped.** It
printed a delivery ratio whichever of its two guards failed, so its far more
common failure — "the caret never pulsed, so there were fewer than ten presents"
— was reported as *0% of presents reached the glass* and read as occlusion. It
is not: the caret pulses only while the window is **key** (§5.5), so any focus
steal produces zero presents in a perfectly visible window. The two guards now
say different things, and the focus-steal one names the cause.

### It must be impossible to lose the user's work

Two holes, both of which discard work with no prompt and nothing to recover
from. Both guards are **drawn in the grid**, because §5.4's one load-bearing
constraint is that no AppKit control lives inside the window — and the reason a
sheet is especially wrong here is not purity: an alert is a second event loop,
drawn by another process, whose latency Beam does not control and cannot
measure, in front of the one product that exists to be measured. A confirmation
is a question and a short list of answers, which is the overlay mechanism §5.3
already built. `.confirm` is its fifth kind.

- **⌘W and ⌘Q.** `closeDocument` never looked at `isModified`. ⌘Q is the harder
  half, because quitting passes through no document's own code path — an editor
  that guards ⌘W and forgets ⌘Q has guarded the smaller door — so
  `applicationShouldTerminate` returns `.terminateLater` while the question is
  on the glass and answers on Beam's own event loop.
- **Somebody else wrote the file.** `Document.save()` wrote atomically over
  whatever was there, and atomic only means the write cannot be torn; it says
  nothing about whether the bytes being replaced are the bytes the document was
  opened from. A `git checkout`, a rebase, a formatter or the same file open
  elsewhere replaces them silently. This is the one data loss a user cannot
  undo, because the losing edit is a legitimate save they asked for.

  Identity is **(modification date, size)**, recorded on open and on save.
  Not a hash: hashing is O(file) on a path checked on every window activation
  and before every save, and the pair catches every case that occurs. `save()`
  refuses when they differ, and `force` — which only the user's own answer
  grants — is the sole way past.

Three things about the shape of the questions are decisions rather than wording.
**The safe answer is first**, because it is what `return` takes and what someone
hitting keys without reading gets; `esc` does nothing at all, which is safer
still. **The answers are numbered**, so a question is answered by the gesture
§5.1 already taught for the peer list. And on a disk conflict the first answer
is **"keep both — save mine beside it"**, which is the only resolution that
cannot lose anything: every other one throws a version away, and a conflict is
precisely the moment when the person does not yet know which version they want.
The document keeps its original path, because the copy is a rescue, not a
rename.

**On window activation, a clean document reloads silently and a modified one is
not interrupted.** A clean reload can lose nothing and the file on screen would
otherwise be a lie. A question thrown up on activation would eat the keystroke
you came back to type — so the conflict goes to the status line in red, which is
where §5.3 requires a Local Network denial to appear and for the same reason,
and the question is asked at ⌘S, which is the moment it is actually about.
Nothing can be lost in between, because `saveDocument` is the only way to the
disk. The status line reads a **stored flag**, never `stat`: `diskState` is a
syscall and the status line is drawn on the keystroke path.

**Proven red the way §3 requires.** The guards are asserted in `--bench-text`,
the headless suite that runs everywhere; removing the check from `save()` makes
the suite report *"save REFUSES when the file changed underneath it"* and *"the
refusal left their bytes on disk untouched"*. A correctness gate that has never
caught the bug it is about is not a gate.

### Find — and why it is not a bar

`Commands.all` had eighteen entries and none of them searched. An editor without
find is not an editor.

**Find is a transient mode on the status line, not an overlay and not a bar.**
An overlay dims the document behind it, which is right when you are choosing
something to do *to* the document (§5.3) and exactly wrong when the thing you
are looking for is *in* it — the whole value of highlight-all is seeing where
the matches are, and a scrim over them defeats it. So the query replaces the
left-hand run of the one line Beam already had, the count sits beside it because
"3 of 47" is part of the answer, every visible match fills in a new ink, and
`esc` leaves. Zero editing rows, zero chrome, zero draw calls, and the document
is never covered — which is what a find bar spends its whole existence trying to
get back to and cannot, because it is a bar.

Decisions worth not re-deriving:

- **The current match is the selection**, not a third state. It genuinely is
  selected, so every key that already works on a selection — type over it, copy
  it, delete it — works on a search result with no new code and nothing to
  learn. The other matches get one new palette slot, `#1A3040` (L 0.300 /
  C 0.040 / H 240, checked for gamut clipping like every entry): selection's own
  hue one clear lightness step down, so a screen of matches reads as one set
  with one of them in front.
- **Highlighting is bounded by the viewport**, exactly as the lexer is (§5.3).
  The match list is ascending, so a frame takes two binary searches per line and
  a file with ten thousand matches costs the same frame as one with three.
- **Literal, not regex.** A regex engine is a dependency and a parser on the
  keystroke path, and a bad one's failure mode is a pathological backtrack that
  hangs the editor mid-keystroke — in the product whose entire claim is that a
  keystroke costs 0.3 ms. Regex joins §1's named list rather than being smuggled
  in unbudgeted.
- **Smart case**: a lowercase query matches either case, any uppercase makes it
  exact. It is the only case rule that needs no control to explain it, and the
  alternative is a toggle — chrome for a decision the query already contains.
- **The whole buffer is re-scanned per keystroke, on purpose.** The count is
  part of the answer and a count that has not counted is a lie. So it is
  budgeted rather than avoided: `find_keystroke_to_commit_p99_ms` at 4 / 8, the
  overlay row's numbers, because it is the same class of problem — work with
  nowhere to live but the keystroke path. Measured in isolation the scan is
  **869 µs p99 for 1 MB**, one pass of byte compares over `TextBuffer.withRaw`
  allocating only the match array. The optimisation is on the shelf and
  deliberately not pre-applied: matches of `ab` are a subset of matches of `a`,
  so a growing query can filter the previous result instead of re-scanning.
  Unmeasured optimisations are not something this project merges (§5.1, §5.2).

### What the clean run measured, and the one thing still unexplained

A gate attempt on a quiet machine reached the end of both present-timed
benches — **98.2% and 99.6% present delivery**, with every headless micro at its
clean value (lex one line 0.6 µs p50, atlas miss 7.5, find scan 807 µs) — before
`--bench-idle` aborted on a focus steal and said so in its new words. Those two
benches are therefore real measurements and are recorded here; the gate as a
whole is **not green**, and this section does not pretend otherwise.

**Two of the four rows are green, and the loop fix is why.**

```
row                              budget / gate   before      after
selection_drag_to_presented        34 / 38       41.63       37.38   PASS
scroll_wheel_to_presented          34 / 38       48.82       37.33   PASS  (re-specified, paced)
pointer_burst_125hz_presented      44 / 60         —         48.96   PASS  (new; above budget, as burst_125hz is)
tab_switch_to_presented            34 / 38       41.61       41.62   FAIL
overlay_keystroke_to_commit         4 /  8       12.78       13.30   FAIL
find_keystroke_to_commit            4 /  8         —          9.90   FAIL  (new row, new feature)
```

The accounting confirms the mechanism it was built to test: every pass now
renders its input on arrival — typing 300/300, scroll (paced) 119/119, tab 60/60,
overlay 120/120, find 100/100, drag 199/201 — against 27/60 and 31/120 before.
Nothing else in L2 moved: commit p50 **0.34** (from 0.41), pipeline depth
**16.12** (from 16.85), burst 49.07, draw calls 2, RSS 81.3 MB.

**The three failing rows share one signature, and it is not any of the usual
suspects.** Their distributions are flat — tab switch p50 41.59 against p99
41.62, overlay commit p50 12.34 against p99 13.30, find commit p50 9.46 against
p99 9.90. A flat distribution is not frame-quantization luck and not a loaded
machine; it is a **fixed quantity of work**, about 10–15 ms, on every one of
those inputs and on none of the others.

Four candidates were measured headlessly, in one run, and all four are
eliminated:

```
building a frame over a 1 MB document          11 µs
   the same frame with the overlay open        16 µs
   the same frame with find open               25 µs
the find model call itself (scan + reveal)  1,007 µs
the highlighter's whole-file state pass      5,900 µs   (not called on any of these paths)
```

So it is not the model, not the scene build, not the fuzzy filter (§5.7 already
showed it is the same at 94 candidates and 2,001), and not the whole-file lex.
The remaining candidate — **untested, and named here so the next session starts
from it rather than from scratch** — is the *number of frames these paths
present*. Each of them changes the model through `onNeedsRender`, which sets the
dirty bit, and then the view calls `noteInput`, which renders immediately; the
tick that follows therefore renders again, unaccounted. Two presents per input
against a 2-deep drawable queue would make the next accounted render block in
`nextDrawable()` for the remainder of a frame, which is exactly the shape and
size of the constant being measured. `GridView.InputAccounting` now counts
renders and how many carry no `t0`; one editor-bench run on an attended screen
either confirms that or eliminates it too.

**`zoom_step_to_presented` measured 38.48 against a gate of 38** in the same run,
having measured 33.4 in §5.7. It is not treated as a finding: the pass has
**n = 24**, so its p99 is its maximum and one unlucky frame decides it. The row
needs more samples before it can say anything, which is itself a defect in the
bench rather than in the product.

### The rule this session did not break

**None of this is merged.** §3 says no merge with a red gate, and the gate is
red: three rows fail and one is too thin to judge. What has been established is
that the three failures are a single unexplained constant rather than three
problems, that it is none of the four things it most plausibly could have been,
and that the instrument to identify it already exists.

The garbage run made earlier in the same session — a machine at load average
5.9, with lex-one-line max at 1954 µs against a clean 8.9 and atlas-miss max at
4317 against 1267 — is recorded nowhere, compared to nothing, and used for no
decision here. `perf/results/` still holds the last clean gate run, and CI now
writes its own numbers to a scratch directory so a shared runner can never
overwrite that record.

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
- **Find (⌘F / ⌘G), and the two data-loss guards.** Design of record: §5.8.
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

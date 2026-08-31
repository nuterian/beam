# Harness proof — every gate has gone red

PLAN.md §3: *a benchmark that has never gone red is not a benchmark.* Each Phase-0
bench was run against a deliberately slowed implementation (the `BEAM_SABOTAGE_*`
hooks), its results written to a scratch results dir, and `perf-gate` run over
them. Recorded 2026-08-30 on the M4 Air dev machine (60 Hz panel).

## Sabotage runs and gate verdicts

| Bench | Sabotage | Sabotaged value | Gate | Verdict |
|---|---|---|---|---|
| bench-tcp-echo p50/p99 | `BEAM_SABOTAGE_ECHO_DELAY_US=40000` (n=200) | p50 44.39 ms / p99 45.45 ms | 0.3 / 0.8 ms | ✗ red |
| bench-tcp-echo Nagle spikes | same run | 200 spikes >35 ms | 0 | ✗ red |
| beam --bench-typing commit p50/p99 | `BEAM_SABOTAGE_KEY_DELAY_MS=10` (n=100) | p50 11.24 ms / p99 312.6 ms | 6 / 9 ms | ✗ red |
| beam --bench-typing presented p50/p99 | same run | p50 44.2 ms / p99 59.9 ms | 30 / 38 ms | ✗ red |
| beam --bench-launch | `BEAM_SABOTAGE_LAUNCH_DELAY_MS=600` | 839.0 ms | 500 ms | ✗ red |
| bench-discovery | `BEAM_SABOTAGE_DISCOVERY_DELAY_MS=3000` (delays the advertise after the browser starts, so the measurement honestly includes it) | 3970.7 ms | 2000 ms | ✗ red |

Gate output over the sabotaged results: `9 metric(s) breached their gate.` → exit 1.

`verify_app.sh` red path: running it without `dist/Beam.app` writes
`packaged_launch_ok: 0` and exits 1 (deterministic; exercised before first packaging).

## Round 2 (2026-08-30, benchmark-expansion pass)

- **Occlusion validity guard, proven red on a real event:** during the render-loop
  rework the macOS screensaver engaged on the unattended dev machine; WindowServer
  dropped every present (`presentedTime == 0`) and the typing bench refused to
  publish, exiting 5 with "window was occluded during the run". The launch/verify
  watchdog similarly exits 6 (`BEAM_LAUNCH_TIMEOUT`) instead of hanging. This is
  the guard working as designed — garbage is never gated.
- `beam --probe-presents` characterized the failure: steady-cadence presents ok
  (296/299) while visible; 100% drops (830/830) once occluded, with `vis=0`.
- `BEAM_SABOTAGE_IDLE_SPIN=1` proof: RED as expected (idle-CPU gate breached
  under the 20%-duty spin timer; clean run measures 0.026%).
- New L2 metrics validated 2026-08-30 (min 17.0, spread 7.96, burst 48.6,
  first-key-after-idle 59.5/62.9, malloc −81 B/key) and promoted to gated.
  Their red-proofs ride the existing BEAM_SABOTAGE_KEY_DELAY_MS hook, which
  inflates all of them (proven in round 1).

## Phase 2 (2026-08-30, presence + one-gesture secure session)

New hooks: `BEAM_SABOTAGE_JOIN_DELAY_MS` (stalls the pairing handshake *before*
key agreement, so the code cannot be shown until it clears) and
`BEAM_SABOTAGE_PEER_LIST_DELAY_MS` (the peer IS on the network; we are simply
slow to put its row on the glass). Re-runnable at any time with
`scripts/prove-red.sh phase2` — proofs should be re-checkable, not attested once.

| Bench | Sabotage | Sabotaged value | Gate | Verdict |
|---|---|---|---|---|
| join gesture → code visible on both screens | `BEAM_SABOTAGE_JOIN_DELAY_MS=700` (both peers) | 748.9 ms (guest 748.9, host 748.9) | 350 ms | ✗ red |
| join gesture → first shared keystroke | same run | 898.9 ms | 800 ms | ✗ red |
| launch → peer row presented | `BEAM_SABOTAGE_PEER_LIST_DELAY_MS=2500` | 3470.5 ms | 2000 ms | ✗ red |

Two things this proof pass caught that no clean run would have:

- **The hook was in the wrong place at first.** Sleeping *after* the SAS was
  derived left `join_gesture_to_code_visible_ms` green at 230 ms under a 700 ms
  sabotage, because the code had already been published to the model and painted.
  A hook that stalls the notification instead of the work proves nothing; it now
  sleeps before the key agreement.
- **Sabotaging one side only was also wrong.** With just the guest slowed, the
  fast host derived, displayed and *confirmed* before the guest had drawn
  anything — and the guest went straight to the editor having never shown the
  code. That is a real security-UX defect, not a bench artifact: the guest is the
  side doing the comparing. Fixed in the product — `AppModel` now holds an
  acceptance until the six digits have actually been **presented** on this side
  (`codePresented` is set from the present handler, so it means "on the glass",
  not "in the model").

A third defect came out of reviewing the same code rather than running it, and is recorded here
because it is the same class: **`accept` was honoured from either direction**, so a guest could have
sent one and moved the *host* into the session without its human ever pressing return — the host's
keypress being the entire authorization. A responder now drops the session instead.

### The connected-idle gate earned its place immediately

`L7.idle_cpu_connected_pct_core` went red on its very first real run at **3.4% of
a core** against a 1.0% gate — a regression introduced by this phase's own
latency-as-UI feature, caught before it was ever committed. Two causes, both
measured rather than guessed:

1. The host's CPU window started when *editing* began, so it charged the host for
   all 120 keystrokes of the E2E pass and reported it as idle. The two peers now
   measure the same window (a `quietStart` mark).
2. Every 2 Hz RTT update marked the frame dirty, and the display-link tick reset
   the 1.5 s idle countdown each time — so the loop never paused and ran at 60 Hz
   forever. Status repaints now ride the next tick without extending the warm
   window.

After both: **0.43–0.52%** of a core, inside the gate and at the design budget.
Attribution run (`BEAM_NO_RTT=1`) shows the RTT probe itself is not the cost
(0.43% with it, 0.48% without) — the remainder is the display-link wind-down and
an open Network.framework connection, against a 0.026% no-session baseline.

`beam --verify-session` is the headless companion (no screen, runs on any CI
runner): honest peers derive the same six digits, a machine-in-the-middle's two
legs derive **different** ones (asserted, not assumed), 100 ops survive the
ChaChaPoly round trip intact, and bytes/keystroke on the wire measures 30.

## Notes

- Sabotage env vars are permanent fixtures, re-runnable any time a gate's
  sensitivity is in doubt: `BEAM_SABOTAGE_ECHO_DELAY_US`, `BEAM_SABOTAGE_NO_NODELAY`,
  `BEAM_SABOTAGE_KEY_DELAY_MS`, `BEAM_SABOTAGE_LAUNCH_DELAY_MS`,
  `BEAM_SABOTAGE_DISCOVERY_DELAY_MS`, `BEAM_SABOTAGE_JOIN_DELAY_MS`,
  `BEAM_SABOTAGE_PEER_LIST_DELAY_MS`, plus `BEAM_BENCH_N` to shorten proof runs.
  `scripts/prove-red.sh [phase2|all]` runs them. Diagnostic levers that are not
  sabotage: `BEAM_NO_RTT=1` (drop the RTT probe, to attribute idle CPU),
  `BEAM_QUIET_SECONDS` (length of the connected-idle window),
  `BEAM_OCCLUSION_POLL=1` (watch a bench window's visibility evolve — the
  two-process failure mode in PLAN.md §5-L2).
- The typing sabotage run also demonstrated a real failure mode worth keeping in
  mind: a stalled main thread causes presented-frame starvation (n=8 presented of
  100 sent) because keystrokes coalesce behind the blocked drawable — visible in
  the numbers, exactly as it should be.

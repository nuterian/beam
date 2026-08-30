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

## Notes

- Sabotage env vars are permanent fixtures, re-runnable any time a gate's
  sensitivity is in doubt: `BEAM_SABOTAGE_ECHO_DELAY_US`, `BEAM_SABOTAGE_NO_NODELAY`,
  `BEAM_SABOTAGE_KEY_DELAY_MS`, `BEAM_SABOTAGE_LAUNCH_DELAY_MS`,
  `BEAM_SABOTAGE_DISCOVERY_DELAY_MS`, plus `BEAM_BENCH_N` to shorten proof runs.
- The typing sabotage run also demonstrated a real failure mode worth keeping in
  mind: a stalled main thread causes presented-frame starvation (n=8 presented of
  100 sent) because keystrokes coalesce behind the blocked drawable — visible in
  the numbers, exactly as it should be.

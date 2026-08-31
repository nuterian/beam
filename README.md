# Beam

LAN-native collaboration on code, obsessed with input-to-photon latency. Native
macOS: Swift + AppKit shell, Metal glyph-atlas rendering, Network.framework +
Bonjour. No accounts, no cloud; code never leaves the network.

**Read [PLAN.md](PLAN.md) first** — the theses, the measured facts inherited
from the predecessor (Collev), the budgets, and the phase plan. Performance is
the product; every change ships behind a benchmark and a CI gate.

## Commands

```bash
scripts/build.sh        # release build -> .build/bin (SwiftPM, or direct swiftc fallback)
scripts/bench.sh        # every bench + the gate, one command
scripts/gate.sh         # bench.sh, retried past screen-aborted runs (exit 5/6 only)
.build/bin/perf-gate    # judge perf/results/*.json against perf/budgets.json
scripts/package_app.sh  # build dist/Beam.app (ad-hoc signed; env vars for real signing)
scripts/verify_app.sh   # execute the packaged binary directly, require BEAM_LAUNCH_OK
.build/bin/beam         # run the app (also: --bench-typing, --bench-launch,
                        #   --bench-idle, --bench-join, --flash-on-key, --probe-presents)
.build/bin/beam --dump-scene   # every surface as ASCII — structure, diffable, no screen
.build/bin/beam --screenshot   # every surface as a PNG — pixels, offscreen, no screen
                               #   [--surface roster|denied|pairing|editor|atlas|all] [--out dir]
scripts/present-matrix.sh  # compare present strategies; the data picks the default
```

Benchmarks only measure and write flat JSON into `perf/results/`;
`perf-gate` is the one place that judges, reading `perf/budgets.json` — the
same file the in-app HUD reads. Sabotage hooks (`BEAM_SABOTAGE_*`, see
`perf/harness-proof.md`) exist to prove any gate can go red.

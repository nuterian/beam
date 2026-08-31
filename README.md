# Beam

LAN-native collaboration on code, obsessed with input-to-photon latency. Native
macOS: Swift + AppKit shell, Metal glyph-atlas rendering, Network.framework +
Bonjour. No accounts, no cloud; code never leaves the network.

Beam is an editor: open files, type in them, scroll, select, save — alone, or
with whoever is on the network with you. Document tabs sit in the traffic-light
band and the icon rail runs down the left, so the chrome costs **no** editing
rows; the menus live in the system menu bar, outside the window entirely. Every
pixel inside the window is drawn from one glyph atlas — there is no AppKit
control in there, which is why it renders in two draw calls and idles at a tenth
of a percent of a core.

    ⌘O open · ⌘S save · ⌘W close tab · ⇧⌘P command palette · ⌘K who's nearby
    ⌘Z / ⇧⌘Z undo · ⌘A select all · ⇧⌘] / ⇧⌘[ next / previous tab · ⌘Q quit
    esc closes an overlay, cancels a join, leaves a session · return confirms the join code
    arrows move, ⇧arrows select · click places · drag selects · wheel scrolls

Every command is in one table (`Commands.all`), and the menu bar, the palette and
the keyboard are three views of it — a command cannot exist in one and not the
others, or carry two different shortcuts.

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
                        #   --bench-idle, --bench-join, --bench-editor, --bench-text,
                        #   --flash-on-key, --probe-presents)
.build/bin/beam <path>         # open a file; with no argument, an empty untitled buffer
.build/bin/beam --dump-scene   # every surface as ASCII — structure, diffable, no screen
.build/bin/beam --screenshot   # every surface as a PNG — pixels, offscreen, no screen
                               #   [--surface editor|launch|palette|open|peers|denied|pairing|atlas|all]
                               #   [--out dir]
scripts/present-matrix.sh  # compare present strategies; the data picks the default
```

`--bench-text` is headless — no window, no display — so it runs on any CI
runner and carries the text model's correctness assertions as well as its
micro-budgets. `--bench-editor` needs a visible screen, like every present-timed
bench.

Benchmarks only measure and write flat JSON into `perf/results/`;
`perf-gate` is the one place that judges, reading `perf/budgets.json` — the
same file the in-app HUD reads. Sabotage hooks (`BEAM_SABOTAGE_*`, see
`perf/harness-proof.md`) exist to prove any gate can go red.

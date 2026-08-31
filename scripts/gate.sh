#!/bin/bash
# scripts/bench.sh, retried — the dev machine's display cycles off aggressively
# and yields to nothing programmatic, so a photon-path bench can abort with
# exit 5/6 through no fault of the code (PLAN.md environment quirks). Retrying
# is legitimate ONLY for that failure: a run that completes and fails the gate
# is a red gate and stays red.
#
# `set -o pipefail` is load-bearing: piping into tee otherwise reports tee's
# exit status and turns every failure into a pass.
set -uo pipefail
cd "$(dirname "$0")/.."

ATTEMPTS=${BEAM_GATE_ATTEMPTS:-6}
# Cool-down between attempts. A screen-aborted run leaves WindowServer in a
# state where the next run aborts too; a few seconds is not enough to clear it,
# a real pause is (measured 2026-08-30 — five back-to-back retries all aborted,
# the same bench passed first try after the machine sat idle).
COOLDOWN=${BEAM_GATE_COOLDOWN:-45}
LOG=${BEAM_GATE_LOG:-.build/gate.log}
for attempt in $(seq 1 "$ATTEMPTS"); do
  echo "== gate attempt $attempt/$ATTEMPTS ==" >&2
  scripts/bench.sh 2>&1 | tee "$LOG"
  status=${PIPESTATUS[0]}
  case "$status" in
    0) echo "gate: PASS (attempt $attempt)" >&2; exit 0 ;;
    5|6) echo "gate: aborted by an occluded/asleep screen (exit $status) — cooling down ${COOLDOWN}s" >&2; sleep "$COOLDOWN" ;;
    *)  echo "gate: FAILED with exit $status — not a screen problem, not retried" >&2; exit "$status" ;;
  esac
done
echo "gate: gave up after $ATTEMPTS attempts; the screen never stayed awake" >&2
exit 6

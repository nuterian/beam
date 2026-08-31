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

# **Hold the idle timer off for the WHOLE run, gaps included.**
#
# Every bench already declares user activity and takes an
# `idleDisplaySleepDisabled` assertion — but only for as long as that bench's
# own process lives. The gate spends minutes *between* processes: five cold
# launches with a 3 s settle each, a 45 s cooldown after every retry, a package
# and verify step. Nothing held an assertion across any of that, so the
# screensaver started in a gap and the next bench aborted — measured 2026-08-31,
# four attempts in a row, each one dying at the first present-timed bench after
# a clean L1 and a clean headless suite.
#
# `-u` declares user activity and `-t` bounds each assertion so a crashed gate
# cannot leave the machine awake forever; the loop renews it.
#
# **It helps and it is not sufficient, and the difference was measured.** Before
# it: four attempts, zero that reached the end of a timed bench. After it: four
# attempts, two that completed the typing bench AND the editor bench at 98-99.6%
# present delivery. But the fifth aborted anyway, and a screencapture taken
# while `pmset -g assertions` showed our own `UserIsActive` assertion held
# caught the screensaver running regardless. So a UserIsActive assertion does
# not reliably hold off the screensaver on macOS 15, and PLAN.md's rule stands
# unchanged: a photon bench needs an attended screen, and no amount of
# `caffeinate` substitutes for one. This raises the odds of a clean run; it does
# not make one certain, and the pre-flight below is still what catches the case
# where it did not work.
#
# It changes nothing that is measured: it removes an invalid condition rather
# than affecting a number, which is the same argument the benches' own
# assertions already rest on.
if [ "${BEAM_GATE_KEEP_AWAKE:-1}" = 1 ]; then
  ( while :; do caffeinate -u -t 70 >/dev/null 2>&1 || sleep 70; done ) &
  KEEP_AWAKE=$!
  trap 'kill "$KEEP_AWAKE" 2>/dev/null || true' EXIT INT TERM
fi

ATTEMPTS=${BEAM_GATE_ATTEMPTS:-6}
# Cool-down between attempts. A screen-aborted run leaves WindowServer in a
# state where the next run aborts too; a few seconds is not enough to clear it,
# a real pause is (measured 2026-08-30 — five back-to-back retries all aborted,
# the same bench passed first try after the machine sat idle).
COOLDOWN=${BEAM_GATE_COOLDOWN:-45}
LOG=${BEAM_GATE_LOG:-.build/gate.log}
BIN=.build/bin

# Pre-flight, so a screen-aborted attempt costs seconds rather than minutes.
# `--verify-launch` exits the instant the first frame is PRESENTED, which is
# exactly the question every timing bench is about to ask; without it the loop
# discovers an occluded display only after a full rebuild, five cold launches
# and part of the bench suite. Same ground truth every bench uses — a presented
# frame, never occlusionState (PLAN.md §5-L2).
screen_is_awake() {
  [ -x "$BIN/beam" ] || return 0        # nothing built yet: let the run build it
  "$BIN/beam" --verify-launch >/dev/null 2>&1
}

for attempt in $(seq 1 "$ATTEMPTS"); do
  if ! screen_is_awake; then
    echo "gate attempt $attempt/$ATTEMPTS: the display is not accepting presents (screensaver?) — waiting ${COOLDOWN}s" >&2
    sleep "$COOLDOWN"
    continue
  fi
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

#!/bin/bash
# Executes the packaged binary DIRECTLY (captures the stderr a GUI launch
# swallows) and requires the BEAM_LAUNCH_OK sentinel + exit 0. The predecessor
# shipped a silently-broken .app for weeks; this gate exists so that can never
# happen again (PLAN.md §4.11). Writes the result as a gated metric.
set -uo pipefail
cd "$(dirname "$0")/.."

APP_BIN=dist/Beam.app/Contents/MacOS/Beam
# CI points this at a scratch directory: a shared runner's numbers must never
# overwrite the committed record of a real gate run (PLAN.md §3.1, §3.3).
RESULTS_DIR=${BEAM_RESULTS_DIR:-perf/results}
RESULT="$RESULTS_DIR/l7-packaged.json"
mkdir -p "$RESULTS_DIR"

if [ ! -x "$APP_BIN" ]; then
  echo "verify_app: $APP_BIN missing — run scripts/package_app.sh first" >&2
  echo '{ "L7_steady_state.packaged_launch_ok": 0 }' > "$RESULT"
  exit 1
fi

out=$("$APP_BIN" --verify-launch 2>&1)
code=$?
echo "$out"
if [ $code -eq 0 ] && echo "$out" | grep -q "BEAM_LAUNCH_OK"; then
  echo '{ "L7_steady_state.packaged_launch_ok": 1 }' > "$RESULT"
  echo "packaged launch verified"
else
  echo '{ "L7_steady_state.packaged_launch_ok": 0 }' > "$RESULT"
  echo "packaged launch FAILED (exit $code)" >&2
  exit 1
fi

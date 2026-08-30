#!/bin/bash
# Executes the packaged binary DIRECTLY (captures the stderr a GUI launch
# swallows) and requires the BEAM_LAUNCH_OK sentinel + exit 0. The predecessor
# shipped a silently-broken .app for weeks; this gate exists so that can never
# happen again (PLAN.md §4.11). Writes the result as a gated metric.
set -uo pipefail
cd "$(dirname "$0")/.."

APP_BIN=dist/Beam.app/Contents/MacOS/Beam
RESULT=perf/results/l7-packaged.json
mkdir -p perf/results

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

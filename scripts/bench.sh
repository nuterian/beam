#!/bin/bash
# Runs every Phase-0 benchmark and then the gate — the one command (PLAN.md §6).
# Benchmarks write flat JSON into perf/results/; perf-gate judges.
set -euo pipefail
cd "$(dirname "$0")/.."

echo "== build (release) =="
scripts/build.sh
BIN=.build/bin
RESULTS=perf/results
mkdir -p "$RESULTS"

echo
echo "== L1: launch (5 cold runs, median) =="
launch_vals=()
typeable_vals=()
for i in 1 2 3 4 5; do
  # Settle between cold launches. Relaunching back-to-back, macOS stops putting
  # the new window on the glass within the bench's 15 s timeout — measured
  # 2026-08-30: runs 1-3 land, run 4 times out, every time; a 1 s gap makes six
  # consecutive runs land. It is WindowServer/activation throttling, not the
  # display cycling and not the app. The pause costs the measurement nothing:
  # L1 is timed from process exec, so it starts after this sleep is over.
  #
  # Raised 1 s -> 3 s (2026-08-30, §5.7 session). With a different app holding
  # activation — the desktop Claude app rather than Terminal — 1 s stopped
  # being enough and run 2 failed on every attempt: `window visible=false`,
  # which is §5.1's finding that occlusionState only ever reports .visible for
  # a window whose app has ACTIVATED. Measured directly: at a 1 s gap, run 2
  # took 9.3 s and run 3 timed out; at 3 s, six consecutive runs landed in
  # 220-336 ms. The gap is an environment accommodation and not a measurement
  # knob — it is outside the timed window by construction, which is why it can
  # be tuned without touching what the row means.
  [ "$i" = 1 ] || sleep 3
  out=$("$BIN/beam" --bench-launch)
  l=$(echo "$out" | sed -n 's/launch_to_first_frame_ms=//p')
  t=$(echo "$out" | sed -n 's/launch_to_typeable_ms=//p')
  echo "  run $i: first frame ${l} ms"
  launch_vals+=("$l"); typeable_vals+=("$t")
done
launch_med=$(printf '%s\n' "${launch_vals[@]}" | sort -n | awk 'NR==3')
typeable_med=$(printf '%s\n' "${typeable_vals[@]}" | sort -n | awk 'NR==3')

echo "== L1: deterministic counters =="
size_kb=$(( $(stat -f%z "$BIN/beam") / 1024 ))
dylibs=$(otool -L "$BIN/beam" | tail -n +2 | wc -l | tr -d ' ')
echo "  binary ${size_kb} KB, ${dylibs} linked dylibs"

cat > "$RESULTS/l1-lifecycle.json" <<EOF
{
  "L1_lifecycle.launch_to_first_frame_ms": ${launch_med},
  "L1_lifecycle.launch_to_typeable_ms": ${typeable_med},
  "L1_lifecycle.binary_size_kb": ${size_kb},
  "L1_lifecycle.linked_dylibs": ${dylibs}
}
EOF
echo "wrote $RESULTS/l1-lifecycle.json"

echo
echo "== L2: text model + undo + lexer (headless: correctness first, then micro-budgets) =="
"$BIN/beam" --bench-text --out "$RESULTS/l2-text.json"

echo
echo "== L2: typing latency (needs a visible screen — screensaver/occlusion aborts the run) =="
"$BIN/beam" --bench-typing --out "$RESULTS/l2-typing.json"

echo
echo "== L2: editor — open a 1 MB file, type in it, scroll it, select in it =="
"$BIN/beam" --bench-editor --out "$RESULTS/l2-editor.json"

echo
echo "== L7: idle CPU + RSS =="
"$BIN/beam" --bench-idle --seconds 5 --out "$RESULTS/l7-idle.json"

echo
echo "== L3: loopback TCP echo =="
"$BIN/bench-tcp-echo" --out "$RESULTS/l3-tcp-echo.json"

echo
echo "== L6: pairing + encrypted transport (headless, no screen needed) =="
"$BIN/beam" --verify-session --out "$RESULTS/l6-session.json"

echo
echo "== L5: Bonjour discovery =="
"$BIN/bench-discovery" --out "$RESULTS/l5-discovery.json" || true

echo
echo "== L5/L6/L7: join gesture (two real Beam processes, host + guest) =="
# The host is started FIRST and must be advertising before the guest is
# cold-launched, so the guest's launch_to_peers_visible number is honest: a peer
# is already on the network when it starts, and it is never charged for the
# host's startup. Both windows are visible and side by side — WindowServer drops
# every present from an occluded window.
HOSTLOG=.build/join-host.log
rm -f "$HOSTLOG"
"$BIN/beam" --bench-join --role host > "$HOSTLOG" 2>&1 &
HOST_PID=$!
trap 'kill $HOST_PID 2>/dev/null || true' EXIT
ready=0
for _ in $(seq 1 200); do
  if grep -q BEAM_HOST_READY "$HOSTLOG" 2>/dev/null; then ready=1; break; fi
  sleep 0.1
done
if [ "$ready" != 1 ]; then
  echo "join bench: host never advertised — log follows" >&2
  cat "$HOSTLOG" >&2
  exit 1
fi
"$BIN/beam" --bench-join --role guest --out "$RESULTS/l5-join.json"
kill $HOST_PID 2>/dev/null || true
trap - EXIT

echo
echo "== L7: packaged-app launch verification =="
scripts/package_app.sh >/dev/null
scripts/verify_app.sh

echo
echo "== gate =="
"$BIN/perf-gate"

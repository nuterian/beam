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
echo "== L2: typing latency =="
"$BIN/beam" --bench-typing --out "$RESULTS/l2-typing.json"

echo
echo "== L3: loopback TCP echo =="
"$BIN/bench-tcp-echo" --out "$RESULTS/l3-tcp-echo.json"

echo
echo "== L5: Bonjour discovery =="
"$BIN/bench-discovery" --out "$RESULTS/l5-discovery.json" || true

echo
echo "== L7: packaged-app launch verification =="
scripts/package_app.sh >/dev/null
scripts/verify_app.sh

echo
echo "== gate =="
"$BIN/perf-gate"

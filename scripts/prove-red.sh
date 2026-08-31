#!/bin/bash
# PLAN.md §3: "a benchmark that has never gone red is not a benchmark."
# Runs each sabotage hook against its bench in a scratch results dir and shows
# the gate's verdict, so every gate's sensitivity is re-checkable on demand
# rather than only at the moment it was first written. Records nothing — copy
# the numbers it prints into perf/harness-proof.md.
#
# Usage: scripts/prove-red.sh [phase2|all]     (default: phase2)
set -uo pipefail
cd "$(dirname "$0")/.."

WHICH="${1:-phase2}"
BIN=.build/bin
SCRATCH=.build/prove-red
scripts/build.sh >/dev/null

# Each proof runs a bench into an EMPTY results dir, so the gate judges only
# the sabotaged metrics and cannot be rescued by a stale green result.
proof() {
  local name="$1"; shift
  rm -rf "$SCRATCH"; mkdir -p "$SCRATCH"
  echo
  echo "=== $name"
  echo "--- $*"
  ( "$@" ) 2>&1 | sed 's/^/    /'
  echo "--- gate verdict:"
  "$BIN/perf-gate" --results "$SCRATCH" 2>&1 | grep -E "^Beam perf gate|✗|breached|Gate passed" | sed 's/^/    /'
  local rc=${PIPESTATUS[0]}
  if [ "$rc" -eq 0 ]; then
    echo "    !! GATE STILL PASSED — this hook no longer proves anything" >&2
  fi
}

start_host() {
  rm -f "$SCRATCH/host.log"
  # Sabotage applies to BOTH peers via HOST_ENV: a slow handshake is slow at
  # both ends, and slowing only one lets the fast side race ahead of it.
  env ${HOST_ENV:-} "$BIN/beam" --bench-join --role host > "$SCRATCH/host.log" 2>&1 &
  HOST_PID=$!
  for _ in $(seq 1 200); do
    grep -q BEAM_HOST_READY "$SCRATCH/host.log" 2>/dev/null && return 0
    sleep 0.1
  done
  echo "    host never advertised" >&2
  return 1
}
stop_host() { kill "${HOST_PID:-0}" 2>/dev/null; wait "${HOST_PID:-0}" 2>/dev/null; sleep 1; }

if [ "$WHICH" = "all" ]; then
  proof "L3 transport — Nagle/delayed-ACK spikes + echo latency" \
    env BEAM_SABOTAGE_ECHO_DELAY_US=40000 BEAM_BENCH_N=200 "$BIN/bench-tcp-echo" --out "$SCRATCH/l3.json"
  proof "L2 typing — keystroke hot path" \
    env BEAM_SABOTAGE_KEY_DELAY_MS=10 "$BIN/beam" --bench-typing --n 100 --out "$SCRATCH/l2.json"
  proof "L1 launch" \
    env BEAM_SABOTAGE_LAUNCH_DELAY_MS=600 "$BIN/beam" --bench-launch
  proof "L5 discovery" \
    env BEAM_SABOTAGE_DISCOVERY_DELAY_MS=3000 "$BIN/bench-discovery" --out "$SCRATCH/l5.json"
  proof "L7 idle CPU" \
    env BEAM_SABOTAGE_IDLE_SPIN=1 "$BIN/beam" --bench-idle --seconds 5 --out "$SCRATCH/l7.json"
fi

# --- Phase 2 ---
# The join gates. BEAM_SABOTAGE_JOIN_DELAY_MS stalls the pairing handshake right
# after key agreement — exactly what a heavier pairing scheme would feel like —
# so the code lands late on both screens and every downstream join number
# inflates with it.
rm -rf "$SCRATCH"; mkdir -p "$SCRATCH"
echo
echo "=== L5 join gesture — slow pairing handshake"
echo "--- BEAM_SABOTAGE_JOIN_DELAY_MS=700 beam --bench-join (both peers)"
if HOST_ENV=BEAM_SABOTAGE_JOIN_DELAY_MS=700 start_host; then
  BEAM_SABOTAGE_JOIN_DELAY_MS=700 "$BIN/beam" --bench-join --role guest --out "$SCRATCH/l5-join.json" 2>&1 | sed 's/^/    /'
  stop_host
  echo "--- gate verdict:"
  "$BIN/perf-gate" --results "$SCRATCH" 2>&1 | grep -E "^Beam perf gate|✗|breached|Gate passed" | sed 's/^/    /'
fi

# The peer-list gate. The peer IS on the network; we are simply slow to put it
# on the glass — which is the failure a user would actually experience, and it
# cannot be faked by breaking discovery itself.
rm -rf "$SCRATCH"; mkdir -p "$SCRATCH"
echo
echo "=== L1 peer list — slow to put a discovered peer on the glass"
echo "--- BEAM_SABOTAGE_PEER_LIST_DELAY_MS=2500 beam --bench-join"
if start_host; then
  BEAM_SABOTAGE_PEER_LIST_DELAY_MS=2500 "$BIN/beam" --bench-join --role guest --out "$SCRATCH/l5-join.json" 2>&1 | sed 's/^/    /'
  stop_host
  echo "--- gate verdict:"
  "$BIN/perf-gate" --results "$SCRATCH" 2>&1 | grep -E "^Beam perf gate|✗|breached|Gate passed" | sed 's/^/    /'
fi

echo
echo "done. Copy the numbers above into perf/harness-proof.md."

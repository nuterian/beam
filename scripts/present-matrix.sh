#!/bin/bash
# Present-mode experiment matrix (PLAN.md §5-L2): runs the typing bench under
# each present strategy and prints the comparison. The numbers pick the
# default in Renderer.presentMode — never a blog post.
#
# REQUIRES A VISIBLE SCREEN: WindowServer drops every present from an occluded
# window (screensaver included), and the bench refuses to publish garbage.
set -euo pipefail
cd "$(dirname "$0")/.."
scripts/build.sh
OUT=${1:-/tmp/beam-present-matrix}
mkdir -p "$OUT"
for mode in normal scheduled transaction; do
  echo "===== BEAM_PRESENT_MODE=$mode ====="
  BEAM_PRESENT_MODE=$mode .build/bin/beam --bench-typing --n 300 --out "$OUT/l2-$mode.json"
  echo
done
echo "results in $OUT — compare keystroke_to_presented p50/min/spread, burst p99, first-key-after-idle."

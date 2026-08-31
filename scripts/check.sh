#!/bin/bash
# The FAST loop, for UX and layout work: build, correctness, structure, pixels.
#
# Deliberately NOT the gate. `scripts/gate.sh` runs the photon benches, needs a
# visible screen, takes minutes and is what you run before merging. This runs in
# well under a minute, needs no display at all, and answers the only questions
# an interface change usually raises: does it still build, is the text model
# still correct, did the layout move somewhere absurd, and what does it look
# like now.
set -uo pipefail
cd "$(dirname "$0")/.."
BIN=.build/bin
OUT=${1:-.build/shots}

echo "== build =="
scripts/build.sh || exit 1

echo
echo "== correctness (headless: buffer, utf-8, undo, lexer, shell states, caret curve) =="
"$BIN/beam" --bench-text --out .build/check-text.json || exit 1

echo
echo "== structure =="
if ! "$BIN/beam" --dump-scene > .build/check-dump.txt 2>&1; then
  echo "  --dump-scene FAILED" >&2; exit 1
fi
echo "  $(grep -c '^+---' .build/check-dump.txt) surface frames laid out -> .build/check-dump.txt"

echo
echo "== pixels =="
"$BIN/beam" --screenshot --out "$OUT" || exit 1

echo
echo "check: OK — look at $OUT, then run scripts/gate.sh before merging."

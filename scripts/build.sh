#!/bin/bash
# Release build -> .build/bin/. Prefers SwiftPM; falls back to driving swiftc
# directly when SwiftPM is unusable (some Command Line Tools installs ship a
# ManifestAPI whose swiftmodule and dylib disagree, so *no* manifest links —
# CI runners with full Xcode always take the SwiftPM path).
set -euo pipefail
cd "$(dirname "$0")/.."

BIN=.build/bin
mkdir -p "$BIN"
EXES=(beam bench-tcp-echo bench-discovery perf-gate)

# A failed SwiftPM attempt is slow, so remember the verdict (delete the marker
# to retry after fixing the toolchain).
MARKER=.build/swiftpm-broken
if [ ! -f "$MARKER" ]; then
  if swift build -c release >/dev/null 2>&1; then
    for e in "${EXES[@]}"; do cp ".build/release/$e" "$BIN/$e"; done
    echo "built via SwiftPM -> $BIN"
    exit 0
  fi
  touch "$MARKER"
fi

echo "SwiftPM unavailable (broken CLT ManifestAPI?) — building with swiftc directly" >&2
OUT=.build/direct
mkdir -p "$OUT"
SWIFTC=(swiftc -O -swift-version 5)

# Some CLT updates leave a stale usr/include/swift/module.modulemap behind that
# redefines SwiftBridging (bridging.modulemap is the current one), breaking any
# Foundation rebuild-from-interface. Mask the stale file with a VFS overlay —
# no sudo, no mutation of the root-owned toolchain. Durable fix:
#   sudo rm /Library/Developer/CommandLineTools/usr/include/swift/module.modulemap
STALE=/Library/Developer/CommandLineTools/usr/include/swift/module.modulemap
if [ -f "$STALE" ] && grep -q SwiftBridging "$STALE"; then
  touch "$OUT/empty.modulemap"
  cat > "$OUT/overlay.yaml" <<EOF
{
  "version": 0,
  "use-external-names": false,
  "roots": [
    { "type": "file", "name": "$STALE", "external-contents": "$PWD/$OUT/empty.modulemap" }
  ]
}
EOF
  SWIFTC+=(-vfsoverlay "$PWD/$OUT/overlay.yaml")
fi

"${SWIFTC[@]}" -module-name BeamCore \
  -emit-module -emit-module-path "$OUT/BeamCore.swiftmodule" \
  -emit-library -static -o "$OUT/libBeamCore.a" \
  Sources/BeamCore/*.swift

build_exe() {
  local name=$1; shift
  "${SWIFTC[@]}" -module-name "${name//-/_}" -I "$OUT" -L "$OUT" -lBeamCore "$@" -o "$BIN/$name"
}
build_exe beam Sources/Beam/*.swift
build_exe bench-tcp-echo Sources/bench-tcp-echo/main.swift
build_exe bench-discovery Sources/bench-discovery/main.swift
build_exe perf-gate Sources/perf-gate/main.swift
echo "built via swiftc -> $BIN"

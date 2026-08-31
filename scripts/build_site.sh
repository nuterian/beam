#!/bin/bash
# Assembles site/ for GitHub Pages: the page, the icon, and the screenshots.
#
# **The screenshots are generated, never committed.** They are renders of the
# product at a known window size, so keeping them in git would mean a page that
# can silently disagree with the app it is advertising — the same drift rule
# PLAN.md §5.2 applies to `--dump-scene` and `--screenshot` inside the project.
# CI runs this on a macOS runner and uploads the result; `site/shots/` is
# gitignored.
#
# The window is a real one: 1160x750 points, which at the product's fixed 2x
# gives 2320x1500 device pixels. The page displays them at 1160 CSS pixels, so
# on a retina screen every pixel is exact and nothing is upscaled. That is the
# whole reason the size is written down in one place rather than guessed at
# either end.
set -euo pipefail
cd "$(dirname "$0")/.."

WINDOW=${BEAM_SITE_WINDOW:-1160x750}
OUT=site/shots

scripts/build.sh >/dev/null

rm -rf "$OUT"
mkdir -p "$OUT"
.build/bin/beam --screenshot --window "$WINDOW" --out "$OUT" >/dev/null

# Only the surfaces the page actually uses. Everything else is a design-review
# artifact and belongs in docs/shots, not in a published bundle.
keep="editor find palette pairing"
for f in "$OUT"/*.png; do
  name=$(basename "$f" .png)
  case " $keep " in *" $name "*) ;; *) rm -f "$f" ;; esac
done

# The icon, from the same source the .icns is built from.
sips -Z 256 resources/icon-1024.png --out site/icon.png >/dev/null

echo "site: $(ls "$OUT" | wc -l | tr -d ' ') screenshots at $WINDOW points (2x), icon, page"
ls -la "$OUT"

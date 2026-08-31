# Shots

Regenerate with:

```bash
.build/bin/beam --screenshot --out docs/shots
```

Every surface, rendered offscreen at 2x with no window and no display (PLAN.md
§5.2). These are **not** golden images and must never become a test: pixels are
reviewed by eye, structure is checked by `beam --dump-scene`, and both lay out on
the same grid so they cannot disagree. `atlas.png` is the glyph atlas itself —
the first thing to look at when the grid goes soft.

`before/` is the pre-§5.2 baseline, kept as the other half of the pair: same
surfaces, same seeded states, before the typography, palette, window and
composition work. It is frozen on purpose and will not be regenerated.

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

Three frozen baselines are kept as the other halves of their pairs, and none
will be regenerated:

- `before/` — before §5.2's typography, palette, window and composition work.
- `before-editor/` — before §5.3. This is the "it looks excellent and it is
  unmistakably a TUI" set: a peer list as the launch screen, a fixed 200x120
  ASCII cell array with no file, no gutter, no selection and no scrolling.
- `before-density/` — before §5.7. The set that was put beside VS Code and read
  as a very clean *prototype*: 28 device pixels of unchosen ground above the tab
  strip and none below it, a four-cell rail carrying two 18 pt outline icons
  that read as dithering, and a status line with two facts on it while the
  lexer, the open path and `Document` between them knew four more.

`--screenshot` also takes `--point-size <pt>`, which renders any surface at any
zoom step. It is how §5.7's derived 1:2 cell is checked by eye rather than
trusted: the rail icons and the join code's block digits have to stay square at
every step, and that claim is worth looking at as well as asserting.

`rejected/` holds the two §5.3 candidates that were drawn before being turned
down, because the honest way to reject a design is to render it and look at it:
`sketch-b-rail.png` is the persistent file rail (a screen that could be any of a
dozen editors — the lineup test Pillar 4 exists to fail), and
`sketch-c-editor.png` is keeping the peer list as the launch screen.

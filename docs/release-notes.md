Built from `__SHA__` on __DATE__. Apple silicon, macOS 14+.

**This build is ad-hoc signed and not notarized.** macOS will refuse the first
double-click: right-click (or Control-click) Beam in Applications and choose
**Open**, then confirm. You only have to do it once.

Before trusting it with anything, read
[what Beam is not, yet](https://jugalm.com/beam/#honest) — in particular,
collaborative editing is an early shared-grid model with last-writer-wins on a
cell, **not** a CRDT, so two people typing in the same place at the same moment
will diverge. No photon latency is claimed: the camera-calibration constant is
unset, so every published number is a software timestamp.

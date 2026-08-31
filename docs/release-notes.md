Built from `__SHA__` on __DATE__. Apple silicon, macOS 14+.

**This build is ad-hoc signed and not notarized** — there is no Apple Developer
certificate behind it — so macOS will refuse to open it.

On **macOS 15** the old Control-click → Open shortcut no longer works. Open Beam once,
let it be blocked, then go to **System Settings → Privacy & Security** and click
**Open Anyway**. You only have to do it once.

Or remove the download flag yourself:
`xattr -dr com.apple.quarantine /Applications/Beam.app`. Building from source avoids the
question entirely.

Before trusting it with anything, read
[what Beam is not, yet](https://jugalm.com/beam/#honest) — in particular,
collaborative editing is an early shared-grid model with last-writer-wins on a
cell, **not** a CRDT, so two people typing in the same place at the same moment
will diverge. No photon latency is claimed: the camera-calibration constant is
unset, so every published number is a software timestamp.

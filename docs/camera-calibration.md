# Camera calibration — software timestamp → photons

Software sees `CAMetalDrawable.presentedTime`, not photons. Once per rig,
derive the constant offset between the two and record it as
`conventions.cameraOffsetMs` in `perf/budgets.json`. Until it is set, no
photon-latency claim may be made (the L2 `keystroke_to_photon_*` metrics stay
"missing").

## Procedure (one afternoon, per PLAN.md §3.1)

1. Rig: the target machine, an external hardware keyboard, and a phone camera
   at 240 fps framing both the keyboard and the screen.
2. Run `beam --flash-on-key`. Every keypress renders one all-white frame, then
   returns to normal — an unmistakable event on camera; the app logs each
   keystroke's `NSEvent.timestamp` and the flash frame's `presentedTime`.
3. Film ≥50 scripted keypresses. In the footage, count frames from key-bottom
   to first white on screen: that is true input-to-photon, at ~4.2 ms
   resolution.
4. `offset = median(camera_ms − (presentedTime − NSEvent.timestamp) × 1000)`.
   Also note the spread — if it is not roughly constant (± a frame), something
   in the pipeline is unstable and must be investigated before trusting any
   software number.
5. Record the offset and the measurement date in `budgets.json`; keep the
   footage summary in `perf/results/` alongside a note of panel refresh rate
   and display settings (ProMotion on/off matters).

Recalibrate whenever the present path changes materially (displaySync
strategy, presentsWithTransaction, direct-to-display, new OS major).

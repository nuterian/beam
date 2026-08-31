import AppKit

// Beam — LAN-native collaboration, obsessed with input-to-photon.
// Modes: (none) normal · --bench-typing [--n N] [--out path] · --bench-launch
//        · --bench-idle · --bench-join --role host|guest · --probe-presents
//        · --verify-launch · --flash-on-key (camera calibration)
//        · --bench-editor (open/scroll/select/overlay in a 1 MB document)
//        · --bench-text (headless: buffer/undo/lexer correctness + micro-budgets)
//        · --dump-scene (ASCII) · --screenshot [--surface k] [--out dir] (PNG)

let config = AppConfig.parse(CommandLine.arguments)

// Headless, screen-independent, and exits before any window exists.
if case .verifySession(let out) = config.mode { SessionVerify.run(outPath: out) }
if case .benchText(let out) = config.mode { TextBench.run(outPath: out) }
if case .dumpScene = config.mode { SceneDump.run() }
if case .screenshot(let surface, let out) = config.mode { Screenshot.run(surface: surface, outDir: out) }

let app = NSApplication.shared
let delegate = AppDelegate(config: config)
app.delegate = delegate
app.setActivationPolicy(.regular)

// The menu bar is built from `Commands.all` — the same table the command
// palette and GridView's key handling read (PLAN.md §5.4). It lives outside the
// window, so every command and its shortcut is discoverable for zero window
// pixels and zero draw calls, which is the only reason a chrome-less app can
// afford menus at all.
app.mainMenu = Commands.mainMenu()

app.run()

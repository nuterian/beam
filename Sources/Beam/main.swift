import AppKit

// Beam — LAN-native collaboration, obsessed with input-to-photon.
// Modes: (none) normal · --bench-typing [--n N] [--out path] · --bench-launch
//        · --verify-launch · --flash-on-key (camera calibration)

let config = AppConfig.parse(CommandLine.arguments)
let app = NSApplication.shared
let delegate = AppDelegate(config: config)
app.delegate = delegate
app.setActivationPolicy(.regular)

// Minimal menu: just enough for ⌘Q to work from the menu bar. No other chrome.
let mainMenu = NSMenu()
let appMenuItem = NSMenuItem()
mainMenu.addItem(appMenuItem)
let appMenu = NSMenu()
appMenu.addItem(withTitle: "Quit Beam", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
appMenuItem.submenu = appMenu
app.mainMenu = mainMenu

app.run()

import AppKit

/// **Everything Beam can do, once.**
///
/// The system menu bar, the command palette (⇧⌘P) and `GridView`'s own key
/// handling are all built from this one table (PLAN.md §5.4, change 1). One
/// table means a command cannot exist in the palette but not the menu, cannot
/// have two different shortcuts, and cannot be renamed in one place.
///
/// The menu bar is the one piece of AppKit §5.4 admits, and it is admitted for
/// a specific reason: it lives *outside* the window, so it costs zero window
/// pixels and zero draw calls while carrying every command and its key
/// equivalent where macOS has trained people to look. Everything drawn inside
/// the window is still instances from the glyph atlas.
struct Command {
    enum Group: Int, CaseIterable {
        case file, edit, go, session

        var title: String {
            switch self {
            case .file: return "File"
            case .edit: return "Edit"
            case .go: return "Go"
            case .session: return "Session"
            }
        }
    }

    let id: String
    let title: String
    let group: Group
    /// Key equivalent character, lowercase. nil = no shortcut.
    let key: String?
    let modifiers: NSEvent.ModifierFlags
    let run: (GridView) -> Void

    /// The shortcut as a person reads it — the palette right-aligns this the
    /// same way a menu does.
    var shortcut: String {
        guard let key else { return "" }
        var s = ""
        if modifiers.contains(.control) { s += "⌃" }
        if modifiers.contains(.option) { s += "⌥" }
        if modifiers.contains(.shift) { s += "⇧" }
        if modifiers.contains(.command) { s += "⌘" }
        return s + key.uppercased()
    }
}

enum Commands {
    static let all: [Command] = [
        Command(id: "file.new", title: "New Tab", group: .file, key: "n", modifiers: [.command]) {
            $0.app.newDocument()
        },
        Command(id: "file.open", title: "Open…", group: .file, key: "o", modifiers: [.command]) {
            $0.app.openOverlay(.files)
        },
        Command(id: "file.save", title: "Save", group: .file, key: "s", modifiers: [.command]) { view in
            _ = view.app.doc.save()
            view.app.doc.undo.breakCoalescing()
            view.requestRender()
        },
        Command(id: "file.close", title: "Close Tab", group: .file, key: "w", modifiers: [.command]) {
            $0.app.closeDocument(at: $0.app.activeIndex)
        },

        // The clipboard. Its absence was the single most obvious "this is not a
        // real editor" gap in the product: there was no way to get text OUT of
        // Beam at all.
        Command(id: "edit.cut", title: "Cut", group: .edit, key: "x", modifiers: [.command]) {
            $0.cutSelection()
        },
        Command(id: "edit.copy", title: "Copy", group: .edit, key: "c", modifiers: [.command]) {
            $0.copySelection()
        },
        Command(id: "edit.paste", title: "Paste", group: .edit, key: "v", modifiers: [.command]) {
            $0.paste()
        },
        Command(id: "edit.undo", title: "Undo", group: .edit, key: "z", modifiers: [.command]) {
            $0.applyHistory(redo: false)
        },
        Command(id: "edit.redo", title: "Redo", group: .edit, key: "z", modifiers: [.command, .shift]) {
            $0.applyHistory(redo: true)
        },
        Command(id: "edit.selectAll", title: "Select All", group: .edit, key: "a", modifiers: [.command]) { view in
            guard view.app.overlay == nil, view.app.surface == .editor else { return }
            view.app.doc.selectAll()
            view.requestRender()
        },

        Command(id: "go.palette", title: "Command Palette…", group: .go, key: "p",
                modifiers: [.command, .shift]) {
            $0.app.openOverlay(.commands)
        },
        Command(id: "go.nextTab", title: "Next Tab", group: .go, key: "]",
                modifiers: [.command, .shift]) {
            $0.app.cycleDocument(1)
        },
        Command(id: "go.prevTab", title: "Previous Tab", group: .go, key: "[",
                modifiers: [.command, .shift]) {
            $0.app.cycleDocument(-1)
        },

        Command(id: "session.peers", title: "Who's Nearby…", group: .session, key: "k",
                modifiers: [.command]) {
            $0.app.openOverlay(.peers)
        },
        Command(id: "session.leave", title: "Leave Session", group: .session, key: nil, modifiers: []) {
            $0.app.leaveSession()
        },
    ]

    static func command(id: String) -> Command? { all.first { $0.id == id } }

    /// The command a key event names, if any. `GridView` consults this so a
    /// shortcut behaves identically whether it arrived through the menu bar or
    /// straight through the window — which benches depend on, since
    /// `window.sendEvent` never reaches the menu.
    static func matching(_ event: NSEvent) -> Command? {
        guard let chars = event.charactersIgnoringModifiers?.lowercased(), !chars.isEmpty else { return nil }
        let mods = event.modifierFlags.intersection([.command, .shift, .option, .control])
        return all.first { $0.key == chars && $0.modifiers == mods }
    }

    /// The menu bar, built from the table. ⌘Q is AppKit's own and is added
    /// beside it rather than duplicated into the table.
    static func mainMenu() -> NSMenu {
        let main = NSMenu()

        let appItem = NSMenuItem()
        let appMenu = NSMenu()
        appMenu.addItem(withTitle: "About Beam", action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)),
                        keyEquivalent: "")
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Hide Beam", action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        appMenu.addItem(withTitle: "Quit Beam", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        appItem.submenu = appMenu
        main.addItem(appItem)

        for group in Command.Group.allCases {
            let item = NSMenuItem()
            let menu = NSMenu(title: group.title)
            for (i, c) in all.enumerated() where c.group == group {
                let mi = NSMenuItem(title: c.title,
                                    action: #selector(AppDelegate.runCommand(_:)),
                                    keyEquivalent: c.key ?? "")
                mi.keyEquivalentModifierMask = c.modifiers
                mi.tag = i
                menu.addItem(mi)
            }
            item.submenu = menu
            item.title = group.title
            main.addItem(item)
        }
        return main
    }
}

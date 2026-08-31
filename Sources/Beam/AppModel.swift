import Foundation
import Network
import BeamCore

/// A peer discovered on the LAN.
struct Peer {
    /// Advertised Bonjour name — unique, used for identity and self-exclusion.
    let name: String
    let endpoint: NWEndpoint
    /// When it first appeared, for the fade-in.
    let appearedAt: Double
    /// The palette slot this peer is actually shown in. Starts at the hash of
    /// the name and moves only to break a tie — see `assignInks`.
    var inkIndex: Int

    var display: String { Peer.display(of: name) }

    /// The name a human reads. The advertised name carries a `-<pid>` suffix so
    /// two instances on one machine stay distinguishable to the protocol; the
    /// presence line and the peer overlay show the machine.
    static func display(of name: String) -> String {
        guard let dash = name.lastIndex(of: "-"),
              !name[name.index(after: dash)...].isEmpty,
              name[name.index(after: dash)...].allSatisfy(\.isNumber) else { return name }
        return String(name[..<dash])
    }

    /// Deterministic from the name, so both ends pick the same colour for each
    /// other without negotiating anything.
    static func ink(of name: String) -> Int {
        var h: UInt64 = 0xcbf29ce484222325
        for b in name.utf8 { h = (h ^ UInt64(b)) &* 0x100000001b3 }
        return Int(h % UInt64(Renderer.Ink.peerCount))
    }

    /// The hash alone gives two of three peers the same colour often enough to
    /// see it in a three-peer list (six slots, birthday paradox — measured on
    /// the very first roster screenshot of this session). The six peer hues are
    /// designed as a *set*, so two rows sharing one is the design failing, not
    /// a cosmetic near-miss.
    ///
    /// So: the hash is the preferred slot, and collisions probe forward to the
    /// next free one. Sorting by name first makes the outcome depend only on
    /// *which* peers are present, never on discovery order, so a peer list does
    /// not reshuffle its colours as it fills in. Past six peers slots have to
    /// repeat, and they do, in a defined order rather than at random.
    ///
    /// Phase 4 (N-peer) needs colours that agree across machines; that is a
    /// negotiation, and it is not this. In a 1:1 session each side colours only
    /// the *other* peer, so nothing has to agree yet.
    static func assignInks(_ peers: inout [Peer]) {
        var taken = Set<Int>()
        for i in peers.indices.sorted(by: { peers[$0].name < peers[$1].name }) {
            var slot = Peer.ink(of: peers[i].name)
            var probes = 0
            while taken.contains(slot) && probes < Renderer.Ink.peerCount {
                slot = (slot + 1) % Renderer.Ink.peerCount
                probes += 1
            }
            taken.insert(slot)
            peers[i].inkIndex = slot
        }
    }
}

/// A peer's caret in the shared document. An offset, plus the line and column
/// it resolves to, cached so instance building does not re-derive them.
struct RemoteCursor {
    var offset = 0
    var line = 0
    var cellColumn = 0
    var name = ""
    var inkIndex = 0
    var since = monotonicNow()
}

/// The whole shell: **a document, an overlay over it, and the join code**
/// (PLAN.md §5.3). Everything a frame needs to draw hangs off this; GridView
/// owns only the render loop and input.
///
/// This replaces §5.1's three surfaces. Beam launches into a document, single
/// player is the ground state, and collaboration is an action taken from inside
/// it — presence lives on the status line and the peer list is one of the two
/// things the overlay can be.
final class AppModel {
    enum Surface {
        case editor      // always; the launch screen IS a document
        case pairing     // six digits on both screens, awaiting the host's return
    }

    /// What the pointer is over. Only chrome is hoverable: the document has
    /// nothing to hover, and tracking it would wake the render loop on every
    /// mouse motion — the shape of the 3.4%-idle-CPU regression Phase 2 caught
    /// (PLAN.md §5.3).
    enum HoverTarget: Equatable {
        case tab(Int)
        case rail(Int)
        case overlayRow(Int)
    }

    /// The overlay is one mechanism with two lists. It is a LAYER over the
    /// editor, not a surface: the document stays behind it, dimmed.
    enum Overlay {
        case files
        case peers
        /// Everything Beam can do, as a list. The same table the system menu
        /// bar is built from, so there is one answer to "what can this do" and
        /// two ways to reach it (PLAN.md §5.4).
        case commands
    }

    /// One row in whichever list the overlay is showing.
    struct OverlayItem {
        let title: String
        /// The digit that selects it, when the list is short enough to number.
        var number: Int?
        var ink: Renderer.Ink?
        /// What choosing it does — a path to open, a peer to join, or a command.
        var path: String?
        var peerIndex: Int?
        var commandID: String?
        /// The key equivalent, shown right-aligned the way a menu shows it.
        var shortcut: String?
    }

    /// Why the network might be quiet. Never conflated: a permission denial
    /// that looks like an empty network is the exact failure §2 forbids, which
    /// is why it also reaches the status line and not only this list.
    enum PresenceState {
        case searching
        case ok
        case localNetworkDenied
        case advertiseFailed
    }

    private(set) var surface: Surface = .editor
    private(set) var overlay: Overlay?
    private(set) var peers: [Peer] = []
    private(set) var presence: PresenceState = .searching
    private(set) var session: Session?
    private(set) var joiningName = ""
    private(set) var joiningInk = 0
    private(set) var isHost = false
    private(set) var remote: RemoteCursor?
    private(set) var codePresented = false
    private var acceptPending = false

    /// The open documents, and which one is in front.
    ///
    /// §5.3 had exactly one, on the grounds that tabs are chrome and Beam had
    /// none. §5.4 admits chrome that pays for itself in vertical space, and
    /// tabs pay: they sit in the traffic-light band, which was already empty
    /// (PLAN.md §5.4, change 1).
    private(set) var documents: [Document] = [Document()]
    private(set) var activeIndex = 0
    /// The document in front. Everything that was written against a single
    /// `doc` keeps working unchanged, which is why this stayed a property.
    var doc: Document { documents[min(activeIndex, documents.count - 1)] }
    /// The document a live session is editing. Tab switching does not move a
    /// session: a peer is in the file you joined them in, and a remote op
    /// applies there whatever you are looking at. Phase 3 is where more than
    /// one shared document becomes a real question.
    private var sessionDocIndex = 0
    private var sessionDoc: Document { documents[min(sessionDocIndex, documents.count - 1)] }
    let fileIndex = FileIndex()
    let localName: String
    var discovery: DiscoveryService?

    /// Cell metrics, published by GridView from the atlas so the scene's scroll
    /// and hit-test arithmetic does not need a GPU context — which is what lets
    /// `--dump-scene` lay out the shipping grid with no Metal at all.
    var cellWidthPx = 18
    var cellHeightPx = 36
    /// Where the grid starts in the drawable, in whole device pixels. Centred
    /// rather than fixed, so the truncation remainder does not all land on the
    /// right and bottom edges (GlyphAtlas.Metrics.originX).
    var originXPx = 18
    var originYPx = 18
    /// Viewport extent in cells, likewise published by the view. The model
    /// needs it for page movement and for keeping the caret on screen.
    var viewportRows = 30
    var viewportCols = 100

    // MARK: - Overlay state

    private(set) var overlayQuery = ""
    private(set) var overlaySelection = 0
    /// What the pointer is over, or what it *was* over while the fade-out
    /// still has something to draw. It is cleared by the view when the hover
    /// phase reaches zero, not on the way out — otherwise the highlight would
    /// vanish instantly and there would be nothing left to fade.
    var hover: HoverTarget?

    /// Row the pointer is over, or -1. Mouse tracking is installed WITH the
    /// overlay and removed with it: editor-wide hover would wake the render
    /// loop on every mouse motion, which is the shape of the 3.4%-idle-CPU
    /// regression Phase 2 caught (PLAN.md §5.3).
    var overlayHover = -1
    private(set) var overlayItems: [OverlayItem] = []
    /// A designed empty state, as its own paragraph — never a blank list.
    private(set) var overlayEmptyLines: [(String, Renderer.Ink)] = []

    var onNeedsRender: (() -> Void)?
    var onNeedsStatusRender: (() -> Void)?
    var onRemoteEdit: ((Double) -> Void)?
    /// The overlay opened or closed. GridView installs and removes its mouse
    /// tracking area on this, so hover costs nothing when nothing is hoverable.
    var onOverlayChanged: (() -> Void)?
    /// The palette picked a command. GridView runs it, because a command needs
    /// the view and the model must not know about the view.
    var onRunCommand: ((String) -> Void)?

    // Bench hooks (main queue) — the benches observe, they never drive.
    var onPeersChanged: (() -> Void)?
    var onPairingReady: (() -> Void)?
    var onEditingReady: (() -> Void)?
    var onSessionOp: ((Session.Inbound) -> Void)?

    /// Fades run for this long and then stop. Finite by rule: an animation that
    /// never ends would pin the display link awake and put a permanent floor
    /// under idle CPU (PLAN.md §5.1, "nothing blinks").
    static let fadeSeconds = 0.20

    init(localName: String) {
        self.localName = localName
    }

    // MARK: - Lifecycle

    /// `beam <path>`. Launching with no argument opens an empty untitled
    /// buffer on purpose: reading a file would put disk I/O inside
    /// `launch_to_typeable_ms` in exchange for nothing the user asked for, and
    /// ⌘O is one key away (PLAN.md §5.3).
    func openAtLaunch(_ path: String?) {
        if let path { openDocument(path: path) }
    }

    // MARK: - Tabs

    /// Opens a path in a tab. Already open ⇒ switch to it, because a second tab
    /// on the same file is a thing editors do and nobody wants. An untitled,
    /// unmodified, empty buffer is *replaced* rather than left behind — the
    /// launch state should not become a stray tab the first time you open a file.
    func openDocument(path: String) {
        if let i = documents.firstIndex(where: { $0.path == path }) {
            selectDocument(i)
            return
        }
        let scratch = doc
        if documents.count == 1, scratch.path == nil, !scratch.isModified, scratch.buffer.isEmpty {
            scratch.open(path: path)
        } else {
            let d = Document()
            d.open(path: path)
            documents.append(d)
            activeIndex = documents.count - 1
        }
        onNeedsRender?()
    }

    /// What a tab is labelled. Two `mod.rs` tabs are useless, so when a name is
    /// ambiguous it grows its parent directory — the smallest thing that makes
    /// the answer unique, which is what every editor eventually learns to do.
    func tabTitle(_ i: Int) -> String {
        guard i >= 0, i < documents.count else { return "" }
        let name = documents[i].displayName
        let ambiguous = documents.enumerated().contains { $0.offset != i && $0.element.displayName == name }
        guard ambiguous, let path = documents[i].path else { return name }
        let parent = ((path as NSString).deletingLastPathComponent as NSString).lastPathComponent
        return parent.isEmpty ? name : parent + "/" + name
    }

    func selectDocument(_ i: Int) {
        guard i >= 0, i < documents.count, i != activeIndex else { return }
        activeIndex = i
        onNeedsRender?()
    }

    func cycleDocument(_ delta: Int) {
        guard documents.count > 1 else { return }
        selectDocument((activeIndex + delta + documents.count) % documents.count)
    }

    /// Closes a tab. The last one is never closed — it is emptied, so Beam
    /// always has a document, which is what "the launch screen is a document"
    /// means when you close the last file.
    func closeDocument(at i: Int) {
        guard i >= 0, i < documents.count else { return }
        if documents.count == 1 {
            documents = [Document()]
            activeIndex = 0
        } else {
            documents.remove(at: i)
            if sessionDocIndex > i { sessionDocIndex -= 1 }
            else if sessionDocIndex == i { sessionDocIndex = 0 }
            activeIndex = min(activeIndex > i ? activeIndex - 1 : activeIndex, documents.count - 1)
        }
        onNeedsRender?()
    }

    func startDiscovery() {
        let d = DiscoveryService(ownName: localName)
        d.onPeersChanged = { [weak self] peers in
            guard let self else { return }
            var peers = peers
            Peer.assignInks(&peers)
            self.peers = peers
            if case .searching = self.presence, !peers.isEmpty { self.presence = .ok }
            if self.overlay == .peers { self.rebuildOverlayItems() }
            self.onNeedsRender?()
            self.onPeersChanged?()
        }
        d.onPresenceProblem = { [weak self] state in
            guard let self else { return }
            self.presence = state
            if self.overlay == .peers { self.rebuildOverlayItems() }
            self.onNeedsRender?()
        }
        d.onInboundConnection = { [weak self] conn in
            self?.hostReceived(conn)
        }
        d.start()
        discovery = d
    }

    // MARK: - The overlay

    func openOverlay(_ kind: Overlay) {
        overlay = kind
        overlayQuery = ""
        overlaySelection = 0
        overlayHover = -1
        if kind == .files, !fileIndex.didScan, !fileIndex.isScanning {
            // Off the main thread, and only on first use: at launch it would
            // land inside the L1 budget, and on the keystroke it would land
            // inside `overlay_keystroke_to_commit_p99_ms`.
            fileIndex.beginScan()
            let root = doc.path.map { ($0 as NSString).deletingLastPathComponent }
                ?? FileManager.default.currentDirectoryPath
            DispatchQueue.global(qos: .userInitiated).async { [weak self] in
                self?.fileIndex.scan(root: root)
                DispatchQueue.main.async {
                    guard let self else { return }
                    self.fileIndex.endScan()
                    if self.overlay == .files { self.rebuildOverlayItems(); self.onNeedsRender?() }
                }
            }
        }
        rebuildOverlayItems()
        onOverlayChanged?()
        onNeedsRender?()
    }

    func closeOverlay() {
        guard overlay != nil else { return }
        overlay = nil
        overlayHover = -1
        onOverlayChanged?()
        onNeedsRender?()
    }

    func overlayType(_ s: String) {
        overlayQuery += s
        overlaySelection = 0
        rebuildOverlayItems()
        onNeedsRender?()
    }

    func overlayBackspace() {
        guard !overlayQuery.isEmpty else { return }
        overlayQuery.removeLast()
        overlaySelection = 0
        rebuildOverlayItems()
        onNeedsRender?()
    }

    func overlayMove(_ delta: Int) {
        guard !overlayItems.isEmpty else { return }
        overlaySelection = min(max(0, overlaySelection + delta), overlayItems.count - 1)
        onNeedsRender?()
    }

    func overlaySelect(_ index: Int) {
        guard index >= 0, index < overlayItems.count else { return }
        overlaySelection = index
        onNeedsRender?()
    }

    /// Commits the highlighted row. Returns whether anything happened, so the
    /// caller can leave the keystroke alone if nothing did.
    @discardableResult
    func overlayCommit() -> Bool {
        guard let kind = overlay, overlaySelection < overlayItems.count else { return false }
        let item = overlayItems[overlaySelection]
        switch kind {
        case .files:
            guard let p = item.path else { return false }
            closeOverlay()
            doc.open(path: p)
            onNeedsRender?()
            return true
        case .peers:
            guard let i = item.peerIndex else { return false }
            closeOverlay()
            return join(peerIndex: i)
        case .commands:
            guard let id = item.commandID else { return false }
            closeOverlay()
            onRunCommand?(id)
            return true
        }
    }

    private func rebuildOverlayItems() {
        if Sabotage.overlayDelayMs > 0 { usleep(UInt32(Sabotage.overlayDelayMs) * 1000) }
        switch overlay {
        case .files:
            let matches = fileIndex.filter(overlayQuery, limit: Scene.overlayMaxRows)
            // The row SHOWS the path relative to the scan root and OPENS the
            // absolute one. Conflating the two shipped as "cannot read
            // Commands.swift" the first time a file was opened from a directory
            // that was not the working directory.
            overlayItems = matches.map {
                OverlayItem(title: fileIndex.paths[$0], path: fileIndex.absolute(fileIndex.paths[$0]))
            }
            let where_ = (fileIndex.root as NSString).lastPathComponent
            if fileIndex.isScanning {
                overlayEmptyLines = [("looking through \(where_)...", .dim)]
            } else if fileIndex.paths.isEmpty {
                overlayEmptyLines = [("nothing to open in \(where_).", .dim),
                                     ("beam opens the folder your file is in.", .faint)]
            } else {
                overlayEmptyLines = [("nothing matches.", .dim)]
            }
        case .peers:
            // §5.1's three designed roster states, kept word for word. Alone on
            // the network is a designed state with its own copy, not a blank
            // area where a list would be, and a Local Network denial names the
            // exact Settings path and is the only place Beam mentions System
            // Settings (PLAN.md §5.3 moved them here; it did not water them down).
            switch presence {
            case .localNetworkDenied:
                overlayItems = []
                overlayEmptyLines = [
                    ("local network access is off.", .red),
                    ("system settings > privacy & security > local network > beam", .faint),
                ]
            case .advertiseFailed:
                overlayItems = []
                overlayEmptyLines = [
                    ("cannot advertise on this network.", .red),
                    ("beam can still see peers, but they cannot see you.", .faint),
                ]
            case .searching, .ok:
                overlayItems = peers.prefix(9).enumerated().map { i, peer in
                    OverlayItem(title: peer.display, number: i + 1,
                                ink: .peer(peer.inkIndex), peerIndex: i)
                }
                overlayEmptyLines = [
                    ("no one else here yet.", .dim),
                    ("beam is listening. open beam on another mac.", .faint),
                ]
            }
        case .commands:
            // The same table the menu bar is built from, filtered. A command
            // palette that could drift from the menu would be two products.
            let q = overlayQuery.lowercased()
            overlayItems = Commands.all
                .filter { q.isEmpty || $0.title.lowercased().contains(q)
                          || $0.group.title.lowercased().contains(q) }
                .map { c in
                    // The group is padded to a fixed width so the titles line
                    // up in a column, the way a menu's do.
                    let group = c.group.title.padding(toLength: 9, withPad: " ", startingAt: 0)
                    return OverlayItem(title: group + c.title, commandID: c.id, shortcut: c.shortcut)
                }
            overlayEmptyLines = [("no command matches.", .dim)]
        case .none:
            overlayItems = []
        }
        overlaySelection = min(overlaySelection, max(0, overlayItems.count - 1))
    }

    // MARK: - The gesture

    /// Guest side. Returns false if the index does not name a peer — the caller
    /// (a number key or a click) then does nothing at all, silently.
    @discardableResult
    func join(peerIndex: Int) -> Bool {
        guard surface == .editor, peerIndex >= 0, peerIndex < peers.count else {
            if ProcessInfo.processInfo.environment["BEAM_DEBUG"] == "1" {
                FileHandle.standardError.write("join(\(peerIndex)) refused: peers=\(peers.count)\n".data(using: .utf8)!)
            }
            return false
        }
        let peer = peers[peerIndex]
        isHost = false
        codePresented = false
        acceptPending = false
        joiningName = peer.display
        joiningInk = peer.inkIndex
        surface = .pairing
        overlay = nil
        onOverlayChanged?()
        // Repaint FIRST: the acknowledgment is local, so the connection feels
        // instant even though the code is still a round trip away.
        onNeedsRender?()

        let s = Session(connectingTo: peer.endpoint, localName: localName)
        wire(s)
        session = s
        s.start()
        return true
    }

    /// Host side: someone made the gesture at us.
    private func hostReceived(_ conn: NWConnection) {
        guard surface == .editor, session == nil else {
            conn.cancel()  // one session at a time in Phase 2; N-peer is Phase 4
            return
        }
        isHost = true
        codePresented = false
        acceptPending = false
        joiningName = "a peer"
        surface = .pairing
        overlay = nil
        onNeedsRender?()

        let s = Session(accepting: conn, localName: localName)
        wire(s)
        session = s
        s.start()
    }

    private func wire(_ s: Session) {
        s.onPaired = { [weak self, weak s] in
            guard let self, let s else { return }
            if !s.peerName.isEmpty {
                self.joiningName = Peer.display(of: s.peerName)
                self.joiningInk = Peer.ink(of: s.peerName)
            }
            self.onNeedsRender?()
            self.onPairingReady?()
        }
        s.onAccepted = { [weak self] in
            guard let self else { return }
            // Hold the acceptance until this side has shown the code.
            if self.codePresented { self.enterEditor() } else { self.acceptPending = true }
        }
        s.onClosed = { [weak self] _ in self?.leaveSession() }
        s.onOp = { [weak self] inbound in
            self?.apply(inbound)
            self?.onSessionOp?(inbound)
        }
    }

    /// The join code reached the glass on this side.
    func noteCodePresented() {
        guard !codePresented else { return }
        codePresented = true
        if acceptPending { acceptPending = false; enterEditor() }
    }

    /// Host confirms the six digits match. One keypress; the whole security
    /// model rests on a human having compared them.
    func confirmJoin() {
        guard surface == .pairing, isHost, let s = session, !s.sas.isEmpty else { return }
        s.send(.accept)
        enterEditor()
    }

    /// Either side, at any time. Leaving a session returns you to your
    /// document, which you never left — it was behind the code the whole time.
    func leaveSession() {
        session?.cancel()
        session = nil
        remote = nil
        codePresented = false
        acceptPending = false
        joiningName = ""
        surface = .editor
        onNeedsRender?()
    }

    private func enterEditor() {
        guard surface == .pairing, let s = session else { return }
        surface = .editor
        remote = RemoteCursor(name: joiningName, inkIndex: joiningInk, since: monotonicNow())
        s.startRTTProbe()
        sessionDocIndex = activeIndex
        s.send(.hello, Session.offsetBytes(doc.caret))
        onNeedsRender?()
        onEditingReady?()
    }

    // MARK: - Editing

    /// Local edit already applied to the document — mirror it to the peer.
    /// Called from the keystroke hot path, after the local render is under way.
    func publishLocal(_ op: Session.Op, _ payload: [UInt8] = []) {
        guard surface == .editor else { return }
        session?.send(op, payload)
    }

    /// Publishes the caret so a peer's view of it stays keystroke-accurate
    /// rather than only updating when you type.
    func publishCaret() {
        publishLocal(.cursor, Session.offsetBytes(doc.caret))
    }

    private func apply(_ inbound: Session.Inbound) {
        if inbound.op == .pong { onNeedsRenderIfRTTChanged(); return }
        guard surface == .editor, var r = remote else { return }
        let doc = sessionDoc
        // Phase 2's ops, applied to the rope instead of to the cell array: a
        // remote insert lands at the SENDER's caret and the local caret shifts
        // if it was after it. That is still not a CRDT and is not pretending to
        // be one — `yrs` lands in Phase 3 and inherits this exact funnel
        // (PLAN.md §5.1 "deliberately not built yet", §5.3 the Edit seam).
        var edit: Edit?
        switch inbound.op {
        case .insert:
            guard inbound.bytes.count >= 9 else { return }
            edit = Edit(offset: min(r.offset, doc.buffer.count), removed: [], inserted: [inbound.bytes[8]])
        case .newline:
            edit = Edit(offset: min(r.offset, doc.buffer.count), removed: [], inserted: [0x0A])
        case .backspace:
            let at = min(r.offset, doc.buffer.count)
            guard at > 0 else { return }
            var start = at - 1
            while start > 0, doc.buffer.byte(at: start) & 0xC0 == 0x80 { start -= 1 }
            edit = Edit(offset: start, removed: doc.buffer.bytes(in: start..<at), inserted: [])
        case .cursor, .hello:
            r.offset = min(Session.readOffset(inbound.bytes, 0), doc.buffer.count)
            refresh(&r)
            remote = r
            onNeedsRender?()
            return
        default:
            return
        }
        guard let edit else { return }
        let localCaret = doc.caret
        let localAnchor = doc.anchor
        // A remote edit is not part of your undo run, and it is not yours to
        // undo — it goes onto the buffer through the same funnel and breaks
        // your coalescing so ⌘Z takes back your last word, not theirs.
        doc.undo.breakCoalescing()
        doc.perform(edit, recordUndo: false)
        let delta = edit.inserted.count - edit.removed.count
        doc.caret = localCaret >= edit.offset ? max(edit.offset, localCaret + delta) : localCaret
        doc.anchor = localAnchor.map { $0 >= edit.offset ? max(edit.offset, $0 + delta) : $0 }
        r.offset = edit.offset + edit.inserted.count
        refresh(&r)
        remote = r
        let t0 = Session.readDouble(inbound.bytes, 0)
        onRemoteEdit?(t0 > 0 ? t0 : monotonicNow())
    }

    private func refresh(_ r: inout RemoteCursor) {
        let d = sessionDoc
        r.offset = min(r.offset, d.buffer.count)
        r.line = d.buffer.line(ofOffset: r.offset)
        r.cellColumn = d.cellColumn(ofOffset: r.offset)
    }

    /// Whether the document in front is the one the session is in — the peer's
    /// caret is only drawn where it actually is.
    var remoteIsInFrontDocument: Bool { sessionDocIndex == activeIndex }

    /// Edit-op payload: the originating keystroke's timestamp, then the op's
    /// own bytes. Eight bytes per keystroke buys the peer a true one-way
    /// latency number to display — the whole latency-as-UI idea — and it is
    /// inside the 48-byte L6 wire budget with room to spare.
    static func editPayload(t0: Double, _ tail: [UInt8] = []) -> [UInt8] {
        Session.doubleBytes(t0) + tail
    }

    /// Live RTT is in the status line, so it must not cost anything to display:
    /// repaint only when the number a human would read actually changes, never
    /// on a timer. `idle_cpu_connected_pct_core` is the gate that enforces this.
    private var lastShownRTT = ""
    private func onNeedsRenderIfRTTChanged() {
        let now = rttText
        guard now != lastShownRTT else { return }
        lastShownRTT = now
        onNeedsStatusRender?()
    }

    var rttText: String {
        guard let rtt = session?.rttMs else { return "" }
        return String(format: "%.1f ms", rtt)
    }

    /// True while any fade is still in flight — the display link stays awake
    /// exactly this long and not one tick more.
    func isAnimating(_ now: Double) -> Bool {
        switch surface {
        case .pairing:
            return false
        case .editor:
            if let r = remote, now - r.since < Self.fadeSeconds { return true }
            return peers.contains { now - $0.appearedAt < Self.fadeSeconds }
        }
    }

    // MARK: - Seams for --dump-scene and --screenshot (see SceneStates)

    func debugSetPresence(_ p: PresenceState) { presence = p }

    func debugSetPeers(_ names: [String]) {
        peers = names.map {
            Peer(name: $0,
                 endpoint: .service(name: $0, type: "_beam._tcp", domain: "local.", interface: nil),
                 appearedAt: 1, inkIndex: Peer.ink(of: $0))
        }
        Peer.assignInks(&peers)
        presence = .ok
    }

    /// A join code with no session behind it, so the six digits can be looked
    /// at without a network.
    private(set) var debugSAS: String?

    func debugSetPairing(host: Bool, sas: String = "472913") {
        surface = .pairing
        isHost = host
        debugSAS = sas
        joiningName = peers.first.map(\.display) ?? "a peer"
        joiningInk = peers.first?.inkIndex ?? 0
    }

    func debugOpen(text: String, name: String) {
        doc.debugLoad(text: text, name: name)
    }

    /// Extra tabs, so the strip can be looked at.
    func debugAddTabs(_ names: [String], modified: Set<String> = []) {
        for n in names {
            let d = Document()
            d.debugLoad(text: "// \(n)\n", name: n)
            if modified.contains(n) { _ = d.insert([0x20]) }
            documents.append(d)
        }
    }

    func debugSetRemote(offset: Int, peer: String) {
        var r = RemoteCursor(offset: offset, name: Peer.display(of: peer),
                             inkIndex: Peer.ink(of: peer), since: 1)
        refresh(&r)
        remote = r
    }

    /// Feeds a remote insert through the real `apply` path, without a session.
    func debugApplyRemoteInsert(byte: UInt8) {
        surface = .editor
        apply(Session.Inbound(op: .insert, bytes: Session.doubleBytes(monotonicNow()) + [byte], t0: monotonicNow()))
    }

    func debugSetOverlay(_ kind: Overlay, query: String, files: [String], selection: Int) {
        overlay = kind
        overlayQuery = query
        overlaySelection = selection
        switch kind {
        case .files:
            overlayItems = files.map { OverlayItem(title: $0, path: $0) }
            overlayEmptyLines = [("nothing matches.", .dim)]
        case .peers, .commands:
            rebuildOverlayItems()
        }
    }

    /// A fade never starts from nothing. Two reasons, and the second is the
    /// serious one (PLAN.md §5.2, motion):
    ///
    /// 1. Starting at zero makes arrival feel *slower* than it is — the first
    ///    frame after a peer is discovered shows an empty space where the peer
    ///    is. From 40% the chip is legible on frame one and the fade reads as
    ///    settling rather than as loading.
    /// 2. **A fade must not be able to make a "visible" claim true before a
    ///    human could see the thing.** `L1.launch_to_peers_visible_ms` is marked
    ///    on the presented frame that first carries a peer's chip; with a fade
    ///    from zero that frame is blank, and Beam would be quietly crediting
    ///    itself with up to a fade's worth of latency it had not delivered. The
    ///    floor is what makes the metric honest, which is why it is a constant
    ///    here and not a taste knob.
    static let fadeFloor = 0.40

    static func alpha(since: Double, now: Double) -> UInt8 {
        guard since > 0 else { return 255 }
        let t = (now - since) / fadeSeconds
        if t >= 1 { return 255 }
        // Ease-out: fast to mostly-there, so it reads as arrival, not as motion.
        let eased = t <= 0 ? 0 : 1 - (1 - t) * (1 - t)
        let a = fadeFloor + (1 - fadeFloor) * eased
        return UInt8(max(0, min(255, a * 255)))
    }
}

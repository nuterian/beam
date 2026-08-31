import AppKit
import BeamCore

/// **The native text-input path.**
///
/// Beam used to read `event.characters` straight out of `keyDown` and act on
/// key codes. That is a toy input path, and it fails in ways a Mac user reads
/// as brokenness rather than as a missing feature:
///
/// - `⌃D`, `⌃A`, `⌃E`, `⌃K`, `⌃B`, `⌃F`, `⌃H`, `⌥←`, `⌥→`, `⌥⌫` and every other
///   standard binding did nothing. These are not emacs affectations — they are
///   in `StandardKeyBinding.dict` and work in every Cocoa text surface on the
///   machine, including Spotlight and a Finder rename field.
/// - Dead keys did nothing: `⌥e` then `e` produced `e`, not `é`.
/// - IME was impossible, which is most of the world's writing systems.
///
/// All three have one cause and one fix: hand the event to AppKit
/// (`interpretKeyEvents`) and let it dispatch to `insertText` and
/// `doCommandBySelector` the way it does for `NSTextView`. The key map is then
/// the *system's*, including whatever the user has customised, and it stays
/// correct without Beam maintaining a table of key codes.
///
/// Marked text is stored as a live range in the document and replaced in place
/// as the composition changes, so a composition is *correct* even though it
/// renders as plain text (PLAN.md §1 scoped it exactly that way).
extension GridView: NSTextInputClient {

    // MARK: - Entry

    /// Called from `keyDown` for anything the command table did not claim.
    func handleTextInput(_ event: NSEvent) {
        inputT0 = event.timestamp
        inputDidChange = false
        interpretKeyEvents([event])
        if inputDidChange { noteInput(t0: inputT0 ?? event.timestamp, remote: false) }
        inputT0 = nil
    }

    /// Everything below funnels through here so a single keystroke produces a
    /// single accounted frame, whatever AppKit decided it meant.
    private func changed(reveal: Bool = true, publishCaret: Bool = true) {
        if reveal { revealCaret() }
        if publishCaret { app.publishCaret() }
        inputDidChange = true
    }

    // MARK: - NSTextInputClient

    func insertText(_ string: Any, replacementRange: NSRange) {
        let text = (string as? NSAttributedString)?.string ?? (string as? String) ?? ""
        guard app.surface == .editor, app.overlay == nil else { return }
        // A composition committing replaces the marked run rather than
        // appending to it.
        replaceMarked(with: text, marked: false)
        changed()
    }

    override func doCommand(by selector: Selector) {
        guard app.surface == .editor, app.overlay == nil else { return }
        let doc = app.doc
        let name = NSStringFromSelector(selector)
        let extend = name.hasSuffix("AndModifySelection:")

        switch name {
        // --- Insertion
        case "insertNewline:", "insertLineBreak:", "insertNewlineIgnoringFieldEditor:":
            _ = doc.insert([0x0A])
            app.publishLocal(.newline, AppModel.editPayload(t0: inputT0 ?? monotonicNow()))
            changed(publishCaret: false)
        case "insertTab:", "insertBacktab:":
            // **Tab inserts what the file already indents with** (PLAN.md
            // §5.7). It used to always insert a literal tab, which in a
            // space-indented file put an invisible mixed indent into somebody
            // else's source on the first keystroke. The status line now says
            // which it is, and the key agrees with what it says — a readout the
            // editor's own behaviour contradicts is worse than no readout.
            // Spaces advance to the next stop rather than inserting a fixed
            // run, which is what a tab does and therefore what replacing one
            // has to do.
            let bytes: [UInt8] = doc.indentsWithTabs
                ? [0x09]
                : [UInt8](repeating: 0x20,
                          count: doc.tabWidth - (doc.cellColumn(ofOffset: doc.caret) % doc.tabWidth))
            _ = doc.insert(bytes)
            app.publishLocal(.insert, AppModel.editPayload(t0: inputT0 ?? monotonicNow(), bytes))
            changed(publishCaret: false)

        // --- Deletion
        case "deleteBackward:", "deleteBackwardByDecomposingPreviousCharacter:":
            guard doc.deleteBackward() != nil else { return }
            app.publishLocal(.backspace, AppModel.editPayload(t0: inputT0 ?? monotonicNow()))
            changed(publishCaret: false)
        case "deleteForward:":
            guard doc.deleteForward() != nil else { return }
            changed()
        case "deleteWordBackward:":
            guard doc.deleteWordBackward() != nil else { return }
            changed()
        case "deleteWordForward:":
            guard doc.deleteWordForward() != nil else { return }
            changed()
        case "deleteToEndOfLine:", "deleteToEndOfParagraph:":
            guard doc.deleteToLineEnd() != nil else { return }
            changed()
        case "deleteToBeginningOfLine:", "deleteToBeginningOfParagraph:":
            guard doc.deleteToLineStart() != nil else { return }
            changed()

        // --- Movement. AppKit names the selector; the model names the motion.
        case _ where name.hasPrefix("moveLeft"), _ where name.hasPrefix("moveBackward"):
            doc.move(.left, extend: extend, pageRows: app.viewportRows); changed()
        case _ where name.hasPrefix("moveRight"), _ where name.hasPrefix("moveForward"):
            doc.move(.right, extend: extend, pageRows: app.viewportRows); changed()
        case _ where name.hasPrefix("moveUp"):
            doc.move(.up, extend: extend, pageRows: app.viewportRows); changed()
        case _ where name.hasPrefix("moveDown"):
            doc.move(.down, extend: extend, pageRows: app.viewportRows); changed()
        case _ where name.hasPrefix("moveWordLeft"), _ where name.hasPrefix("moveWordBackward"):
            doc.move(.wordLeft, extend: extend, pageRows: app.viewportRows); changed()
        case _ where name.hasPrefix("moveWordRight"), _ where name.hasPrefix("moveWordForward"):
            doc.move(.wordRight, extend: extend, pageRows: app.viewportRows); changed()
        case _ where name.contains("BeginningOfLine"), _ where name.contains("LeftEndOfLine"),
             _ where name.contains("BeginningOfParagraph"):
            doc.move(.lineStart, extend: extend, pageRows: app.viewportRows); changed()
        case _ where name.contains("EndOfLine"), _ where name.contains("RightEndOfLine"),
             _ where name.contains("EndOfParagraph"):
            doc.move(.lineEnd, extend: extend, pageRows: app.viewportRows); changed()
        case _ where name.contains("BeginningOfDocument"):
            doc.move(.docStart, extend: extend, pageRows: app.viewportRows); changed()
        case _ where name.contains("EndOfDocument"):
            doc.move(.docEnd, extend: extend, pageRows: app.viewportRows); changed()
        case _ where name.contains("PageUp"):
            doc.move(.pageUp, extend: extend, pageRows: app.viewportRows); changed()
        case _ where name.contains("PageDown"):
            doc.move(.pageDown, extend: extend, pageRows: app.viewportRows); changed()

        // --- Selection
        case "selectAll:": doc.selectAll(); changed(reveal: false)
        case "selectWord:": doc.selectWord(); changed()
        case "selectLine:", "selectParagraph:": doc.selectLine(); changed()

        case "cancelOperation:":
            if app.session != nil { app.leaveSession() }
            else if doc.selection != nil { doc.placeCaret(at: doc.caret, extend: false) }
            else { return }
            changed(reveal: false, publishCaret: false)

        default:
            // Unhandled selectors are not an error — AppKit sends plenty Beam
            // has no opinion about (`noop:`, `complete:`, `transpose:`). Doing
            // nothing quietly is the correct response.
            return
        }
    }

    // MARK: - Marked text (composition)

    func setMarkedText(_ string: Any, selectedRange: NSRange, replacementRange: NSRange) {
        let text = (string as? NSAttributedString)?.string ?? (string as? String) ?? ""
        guard app.surface == .editor, app.overlay == nil else { return }
        replaceMarked(with: text, marked: !text.isEmpty)
        inputDidChange = true
        revealCaret()
    }

    func unmarkText() {
        markedByteRange = nil
        inputDidChange = true
    }

    func hasMarkedText() -> Bool { markedByteRange != nil }

    func markedRange() -> NSRange {
        guard let r = markedByteRange else { return NSRange(location: NSNotFound, length: 0) }
        return NSRange(location: r.lowerBound, length: r.count)
    }

    func selectedRange() -> NSRange {
        let doc = app.doc
        if let sel = doc.selection { return NSRange(location: sel.lowerBound, length: sel.count) }
        return NSRange(location: doc.caret, length: 0)
    }

    func attributedSubstring(forProposedRange range: NSRange,
                             actualRange: NSRangePointer?) -> NSAttributedString? {
        let doc = app.doc
        let lo = min(max(0, range.location), doc.buffer.count)
        let hi = min(lo + max(0, range.length), doc.buffer.count)
        actualRange?.pointee = NSRange(location: lo, length: hi - lo)
        return NSAttributedString(string: doc.buffer.string(in: lo..<hi))
    }

    func validAttributesForMarkedText() -> [NSAttributedString.Key] { [] }

    /// Where the input method should put its candidate window: on the caret, in
    /// screen coordinates. Without this a CJK candidate list appears in the
    /// corner of the display instead of under what you are typing.
    func firstRect(forCharacterRange range: NSRange, actualRange: NSRangePointer?) -> NSRect {
        let doc = app.doc
        let scale = window?.backingScaleFactor ?? 2
        let m = renderer.atlas.metrics
        let L = Scene.EditorLayout(cols: visibleCols, rows: visibleRows,
                                   lineCount: doc.buffer.lineCount)
        let line = doc.buffer.line(ofOffset: range.location)
        let topLine = doc.scrollPx / max(1, m.cellHeightPx)
        let col = L.codeCol + doc.cellColumn(ofOffset: range.location)
            - doc.scrollXPx / max(1, m.cellWidthPx)
        let x = CGFloat(m.originX(forWidthPx: Int(metalLayer.drawableSize.width))
                        + col * m.cellWidthPx) / scale
        let yTop = CGFloat(m.originY(forHeightPx: Int(metalLayer.drawableSize.height))
                           + L.row(ofLine: line, topLine: topLine) * m.cellHeightPx) / scale
        let local = NSRect(x: x, y: bounds.height - yTop - CGFloat(m.cellHeightPx) / scale,
                           width: CGFloat(m.cellWidthPx) / scale,
                           height: CGFloat(m.cellHeightPx) / scale)
        guard let window else { return local }
        return window.convertToScreen(convert(local, to: nil))
    }

    func characterIndex(for point: NSPoint) -> Int {
        guard let window else { return app.doc.caret }
        let local = convert(window.convertPoint(fromScreen: point), from: nil)
        return offsetForPoint(local)
    }

    /// Replaces the current marked run (or the selection, or nothing) with text,
    /// and remembers the new run when the composition is still live.
    private func replaceMarked(with text: String, marked: Bool) {
        let doc = app.doc
        let bytes = Array(text.utf8)
        if let r = markedByteRange, r.lowerBound <= doc.buffer.count {
            let hi = min(r.upperBound, doc.buffer.count)
            doc.undo.breakCoalescing()
            doc.perform(Edit(offset: r.lowerBound,
                             removed: doc.buffer.bytes(in: r.lowerBound..<hi),
                             inserted: bytes))
        } else {
            _ = doc.insert(bytes)
        }
        markedByteRange = marked && !bytes.isEmpty
            ? (doc.caret - bytes.count)..<doc.caret
            : nil
        if !marked {
            // A committed composition goes on the wire as its bytes, in order,
            // exactly as typed ASCII does. Phase 3 replaces the op entirely.
            for b in bytes {
                app.publishLocal(.insert, AppModel.editPayload(t0: inputT0 ?? monotonicNow(), [b]))
            }
        }
    }
}

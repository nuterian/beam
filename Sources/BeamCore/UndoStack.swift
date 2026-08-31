import Foundation

/// Undo, as a stack of invertible `Edit`s and nothing else.
///
/// Because an `Edit` already knows its own inverse, undo needs no knowledge of
/// the storage underneath it — which is the property Phase 3 needs when `yrs`
/// replaces `TextBuffer` (PLAN.md §5.3). A step also carries the caret before
/// and after, because putting the text back and leaving the caret somewhere
/// else is the thing that makes undo feel broken.
public final class UndoStack {
    public struct Step {
        public let edit: Edit
        public let caretBefore: Int
        public let caretAfter: Int
    }

    /// Steps kept. `L2.undo_10k_depth_p99_us` gates that a step's cost does not
    /// depend on how many are behind it.
    public let depth: Int
    /// Trimming in blocks rather than one at a time: `removeFirst()` on a 10k
    /// array is an 80 KB memmove, and it would land on the KEYSTROKE path once
    /// per keystroke forever once the stack is full. In blocks it amortizes to
    /// a few nanoseconds, which is the difference between a design and a leak.
    private static let trimBlock = 256

    private var undoSteps: [Step] = []
    private var redoSteps: [Step] = []
    /// Set by anything that should end a run of coalesced typing: a caret move,
    /// a save, a remote edit, undo itself.
    private var coalescingBroken = true

    /// Deliberate-slowdown hook: makes one undo step expensive, which is what
    /// an undo that scanned its own history would feel like at depth. Proves
    /// `L2.undo_10k_depth_p99_us` can go red.
    public static let sabotageUs = Int(ProcessInfo.processInfo.environment["BEAM_SABOTAGE_UNDO_US"] ?? "") ?? 0

    public init(depth: Int = 10_000) {
        self.depth = depth
        undoSteps.reserveCapacity(min(depth, 1024))
    }

    public var canUndo: Bool { !undoSteps.isEmpty }
    public var canRedo: Bool { !redoSteps.isEmpty }
    public var count: Int { undoSteps.count }

    /// A keystroke should not be its own undo step — nobody wants to press ⌘Z
    /// forty times to take back one word. Consecutive single-byte inserts at
    /// advancing offsets merge, and so do consecutive backspaces; a newline, a
    /// caret move or any other edit shape ends the run.
    public func record(_ edit: Edit, caretBefore: Int, caretAfter: Int) {
        redoSteps.removeAll(keepingCapacity: true)
        if !coalescingBroken, let top = undoSteps.last, let merged = merge(top, edit) {
            undoSteps[undoSteps.count - 1] = Step(edit: merged, caretBefore: top.caretBefore,
                                                  caretAfter: caretAfter)
            return
        }
        undoSteps.append(Step(edit: edit, caretBefore: caretBefore, caretAfter: caretAfter))
        coalescingBroken = false
        if undoSteps.count > depth + Self.trimBlock {
            undoSteps.removeFirst(undoSteps.count - depth)
        }
    }

    private func merge(_ top: Step, _ next: Edit) -> Edit? {
        let t = top.edit
        // Typing: single byte appended exactly where the last one ended.
        if t.removed.isEmpty, next.removed.isEmpty, next.inserted.count == 1,
           next.inserted[0] != 0x0A,
           next.offset == t.offset + t.inserted.count {
            return Edit(offset: t.offset, removed: [], inserted: t.inserted + next.inserted)
        }
        // Backspace: single byte removed immediately before the last one.
        if t.inserted.isEmpty, next.inserted.isEmpty, next.removed.count == 1,
           next.removed[0] != 0x0A,
           next.offset + 1 == t.offset {
            return Edit(offset: next.offset, removed: next.removed + t.removed, inserted: [])
        }
        return nil
    }

    /// Ends the current run. Cheap and idempotent; call it liberally.
    public func breakCoalescing() { coalescingBroken = true }

    public func undo() -> Step? {
        if Self.sabotageUs > 0 { usleep(UInt32(Self.sabotageUs)) }
        guard let step = undoSteps.popLast() else { return nil }
        redoSteps.append(step)
        coalescingBroken = true
        return step
    }

    public func redo() -> Step? {
        guard let step = redoSteps.popLast() else { return nil }
        undoSteps.append(step)
        coalescingBroken = true
        return step
    }

    public func clear() {
        undoSteps.removeAll(keepingCapacity: true)
        redoSteps.removeAll(keepingCapacity: true)
        coalescingBroken = true
    }
}

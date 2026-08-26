import Foundation

/// Undo/redo over edit-document snapshots. Documents are small value types,
/// so whole-document snapshots are cheap and make every edit — sliders,
/// zoom drags, preset applies, trims — undoable with one mechanism and no
/// per-operation inverse logic.
///
/// Coalescing: slider drags emit dozens of edits per second; pushes within
/// `coalescingWindowNs` collapse into the first snapshot of the burst, so
/// one drag is one undo step. Pure value type — unit-tested without the app.
public struct EditHistory: Sendable {
    public private(set) var undoStack: [EditDocument] = []
    public private(set) var redoStack: [EditDocument] = []

    /// Monotonic timestamps come from the caller so tests control time.
    /// nil = no burst in progress (subtracting from a sentinel like
    /// Int64.min overflows — it trapped on the very first edit).
    private var lastPushNs: Int64?
    private var lastPushKind: String?
    private let coalescingWindowNs: Int64
    private let capacity: Int

    public init(coalescingWindowNs: Int64 = 700_000_000, capacity: Int = 200) {
        self.coalescingWindowNs = coalescingWindowNs
        self.capacity = capacity
    }

    public var canUndo: Bool { !undoStack.isEmpty }
    public var canRedo: Bool { !redoStack.isEmpty }

    /// Record the state that existed BEFORE an edit is applied. Edits
    /// coalesce into one undo step only when they share a `kind` inside the
    /// window — a slider drag is one step, but a split followed quickly by
    /// a delete stays two.
    public mutating func recordBeforeEdit(
        _ current: EditDocument, nowNs: Int64, kind: String = "general"
    ) {
        redoStack.removeAll()
        // Coalesce bursts: the first snapshot of the burst already captures
        // the pre-drag state; replacing it would lose it.
        if let last = lastPushNs, nowNs - last < coalescingWindowNs,
            kind == lastPushKind, !undoStack.isEmpty
        {
            lastPushNs = nowNs
            return
        }
        lastPushNs = nowNs
        lastPushKind = kind
        undoStack.append(current)
        if undoStack.count > capacity {
            undoStack.removeFirst(undoStack.count - capacity)
        }
    }

    /// Withdraw the most recent snapshot — for when the edit it preceded
    /// failed to persist, so undo never replays a no-op.
    public mutating func discardLastPush() {
        guard !undoStack.isEmpty else { return }
        undoStack.removeLast()
        lastPushNs = nil
        lastPushKind = nil
    }

    /// Returns the document to restore, exchanging `current` onto redo.
    public mutating func undo(current: EditDocument) -> EditDocument? {
        guard let previous = undoStack.popLast() else { return nil }
        redoStack.append(current)
        // An undo ends any coalescing burst.
        lastPushNs = nil
        lastPushKind = nil
        return previous
    }

    public mutating func redo(current: EditDocument) -> EditDocument? {
        guard let next = redoStack.popLast() else { return nil }
        undoStack.append(current)
        lastPushNs = nil
        lastPushKind = nil
        return next
    }
}

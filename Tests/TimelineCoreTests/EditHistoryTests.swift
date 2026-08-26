import Foundation
import XCTest

@testable import TimelineCore

/// Undo/redo semantics: every edit undoable, slider bursts coalesce into
/// one step, redo dies on a fresh edit, capacity bounds memory.
final class EditHistoryTests: XCTestCase {

    private func document(padding: Double) -> EditDocument {
        EditDocument(style: FrameStyle(padding: padding))
    }

    func testUndoRestoresPreEditStateAndRedoReapplies() {
        var history = EditHistory()
        let original = document(padding: 0.05)
        let edited = document(padding: 0.10)
        history.recordBeforeEdit(original, nowNs: 0)

        let undone = history.undo(current: edited)
        XCTAssertEqual(undone, original)
        XCTAssertTrue(history.canRedo)

        let redone = history.redo(current: original)
        XCTAssertEqual(redone, edited)
        XCTAssertTrue(history.canUndo)
        XCTAssertFalse(history.canRedo)
    }

    func testSliderBurstCoalescesIntoOneUndoStep() {
        var history = EditHistory(coalescingWindowNs: 700_000_000)
        // 20 drag ticks, 50 ms apart: one undo step back to the start.
        var current = document(padding: 0.05)
        for tick in 0..<20 {
            history.recordBeforeEdit(current, nowNs: Int64(tick) * 50_000_000)
            current = document(padding: 0.05 + Double(tick + 1) * 0.002)
        }
        XCTAssertEqual(history.undoStack.count, 1)
        let undone = history.undo(current: current)
        XCTAssertEqual(undone, document(padding: 0.05))
    }

    func testSeparatedEditsAreSeparateSteps() {
        var history = EditHistory(coalescingWindowNs: 700_000_000)
        history.recordBeforeEdit(document(padding: 0.05), nowNs: 0)
        history.recordBeforeEdit(document(padding: 0.06), nowNs: 1_000_000_000)
        history.recordBeforeEdit(document(padding: 0.07), nowNs: 2_000_000_000)
        XCTAssertEqual(history.undoStack.count, 3)
    }

    func testFreshEditClearsRedo() {
        var history = EditHistory()
        history.recordBeforeEdit(document(padding: 0.05), nowNs: 0)
        _ = history.undo(current: document(padding: 0.10))
        XCTAssertTrue(history.canRedo)
        history.recordBeforeEdit(document(padding: 0.05), nowNs: 5_000_000_000)
        XCTAssertFalse(history.canRedo, "a new edit invalidates the redo branch")
    }

    func testUndoEndsCoalescingBurst() {
        var history = EditHistory(coalescingWindowNs: 700_000_000)
        history.recordBeforeEdit(document(padding: 0.05), nowNs: 0)
        _ = history.undo(current: document(padding: 0.10))
        // Immediately record again (same wall window): must be a NEW step,
        // not coalesced into a stack that just changed shape.
        history.recordBeforeEdit(document(padding: 0.05), nowNs: 100_000_000)
        XCTAssertEqual(history.undoStack.count, 1)
    }

    func testCapacityBoundsTheStack() {
        var history = EditHistory(coalescingWindowNs: 0, capacity: 50)
        for step in 0..<300 {
            history.recordBeforeEdit(
                document(padding: Double(step) * 0.0001),
                nowNs: Int64(step) * 2_000_000_000)
        }
        XCTAssertEqual(history.undoStack.count, 50)
        // Oldest retained step is 250, not 0.
        XCTAssertEqual(history.undoStack.first, document(padding: 0.025))
    }

    func testUndoOnEmptyIsNil() {
        var history = EditHistory()
        XCTAssertNil(history.undo(current: document(padding: 0.05)))
        XCTAssertNil(history.redo(current: document(padding: 0.05)))
    }
}

extension EditHistoryTests {
    /// Different edit kinds never coalesce, even inside the burst window:
    /// a split immediately followed by a delete stays two undo steps.
    func testDifferentKindsDoNotCoalesce() {
        var history = EditHistory()
        var doc = EditDocument()

        history.recordBeforeEdit(doc, nowNs: 0, kind: "clip-split")
        doc.trimStartNs = 1
        history.recordBeforeEdit(doc, nowNs: 100_000_000, kind: "clip-delete")
        doc.trimStartNs = 2

        // Two undos land on the two distinct pre-states.
        let afterFirstUndo = history.undo(current: doc)
        XCTAssertEqual(afterFirstUndo?.trimStartNs, 1)
        let afterSecondUndo = history.undo(current: afterFirstUndo!)
        XCTAssertEqual(afterSecondUndo?.trimStartNs, nil)
    }

    func testSameKindStillCoalescesInsideWindow() {
        var history = EditHistory()
        var doc = EditDocument()
        history.recordBeforeEdit(doc, nowNs: 0, kind: "style")
        doc.trimStartNs = 1
        history.recordBeforeEdit(doc, nowNs: 100_000_000, kind: "style")
        doc.trimStartNs = 2
        // One undo step: straight back to the original.
        XCTAssertEqual(history.undo(current: doc)?.trimStartNs, nil)
        XCTAssertFalse(history.canUndo)
    }

    /// A failed save withdraws its history push so ⌘Z never replays a no-op.
    func testDiscardLastPushRemovesTheStep() {
        var history = EditHistory()
        let doc = EditDocument()
        history.recordBeforeEdit(doc, nowNs: 0, kind: "style")
        XCTAssertTrue(history.canUndo)
        history.discardLastPush()
        XCTAssertFalse(history.canUndo)
        XCTAssertNil(history.undo(current: doc))
    }
}

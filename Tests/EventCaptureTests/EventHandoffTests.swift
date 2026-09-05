import XCTest
import ProjectModel
@testable import EventCapture

final class EventHandoffTests: XCTestCase {
    func testStalledConsumerHasBoundedBacklogAndExactLossCount() async {
        let handoff = EventHandoff(capacity: 16)
        for index in 0..<10_000 {
            handoff.yield(EventRecord(sequence: UInt64(index), timeNs: Int64(index), type: .cursorMove))
        }
        handoff.finish()
        var received: [Int64] = []
        for await record in handoff.stream { received.append(record.timeNs) }
        XCTAssertEqual(received, Array(0..<16).map(Int64.init))
        XCTAssertEqual(handoff.droppedEvents, 9984)
        // A late callback after stop is terminated, not reported as loss.
        handoff.yield(EventRecord(sequence: 0, timeNs: 0, type: .cursorMove))
        XCTAssertEqual(handoff.droppedEvents, 9984)
    }
}

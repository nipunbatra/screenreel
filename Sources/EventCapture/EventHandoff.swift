import ProjectModel
import Synchronization

/// The event-tap callback must return immediately, even when journal IO
/// stalls. A bounded stream prevents high-rate mice from growing an
/// unlimited backlog. Loss is counted and included in capture diagnostics.
public final class EventHandoff: Sendable {
    public static let defaultCapacity = 4096
    public let stream: AsyncStream<EventRecord>
    private let continuation: AsyncStream<EventRecord>.Continuation
    private let dropped = Atomic<Int>(0)

    public var droppedEvents: Int { dropped.load(ordering: .relaxed) }

    public init(capacity: Int = EventHandoff.defaultCapacity) {
        precondition(capacity > 0)
        let (stream, continuation) = AsyncStream.makeStream(
            of: EventRecord.self, bufferingPolicy: .bufferingOldest(capacity))
        self.stream = stream
        self.continuation = continuation
    }

    public func yield(_ event: EventRecord) {
        if case .dropped = continuation.yield(event) {
            dropped.add(1, ordering: .relaxed)
        }
    }

    public func finish() { continuation.finish() }
}

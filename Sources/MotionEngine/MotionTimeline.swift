import Foundation
import ProjectModel

/// Preprocessed input-event streams for deterministic motion evaluation.
/// Coordinates are converted from recorded display-local pixels to captured
/// source pixels once, on construction (`docs/MOTION_ENGINE.md` §1-2).
public struct MotionTimeline: Sendable {
    public struct Move: Sendable, Equatable {
        public let timeNs: Int64
        public let position: SIMD2<Double>
        public let buttons: Int
    }

    public struct Click: Sendable, Equatable {
        public let timeNs: Int64
        public let position: SIMD2<Double>
    }

    public struct KeyPress: Sendable, Equatable {
        public let timeNs: Int64
        public let keyCode: Int
        public let modifiers: [EventModifier]

        public init(timeNs: Int64, keyCode: Int, modifiers: [EventModifier]) {
            self.timeNs = timeNs
            self.keyCode = keyCode
            self.modifiers = modifiers
        }
    }

    public let moves: [Move]
    public let downs: [Click]
    public let ups: [Click]
    public let keyPresses: [KeyPress]
    public let shapes: [(timeNs: Int64, cursorID: String)]

    /// - Parameter coordinateScale: captured source pixels per recorded event
    ///   pixel (1.0 when the capture is the full display at native size).
    public init(events: [EventRecord], coordinateScale: Double = 1.0) {
        var moves: [Move] = []
        var downs: [Click] = []
        var ups: [Click] = []
        var keyPresses: [KeyPress] = []
        var shapes: [(Int64, String)] = []
        for event in events.sorted(by: { ($0.timeNs, $0.sequence) < ($1.timeNs, $1.sequence) }) {
            switch event.type {
            case .cursorMove:
                guard let x = event.xPx, let y = event.yPx else { continue }
                moves.append(Move(
                    timeNs: event.timeNs,
                    position: SIMD2(x, y) * coordinateScale,
                    buttons: event.buttons ?? 0))
            case .mouseDown:
                guard let x = event.xPx, let y = event.yPx else { continue }
                downs.append(Click(timeNs: event.timeNs, position: SIMD2(x, y) * coordinateScale))
            case .mouseUp:
                guard let x = event.xPx, let y = event.yPx else { continue }
                ups.append(Click(timeNs: event.timeNs, position: SIMD2(x, y) * coordinateScale))
            case .keyDown:
                guard let code = event.keyCode else { continue }
                keyPresses.append(KeyPress(
                    timeNs: event.timeNs, keyCode: code,
                    modifiers: event.modifiers ?? []))
            case .cursorShapeChanged:
                if let id = event.cursorID { shapes.append((event.timeNs, id)) }
                // (debounced below once all events are collected)
            default:
                break
            }
        }
        self.moves = moves
        self.downs = downs
        self.ups = ups
        self.keyPresses = keyPresses
        // Cursor-shape debounce: beam↔pointer flicker during fast text
        // selection produces sub-100 ms shape blips that strobe the
        // rendered cursor. Blips shorter than the threshold are coalesced
        // into their surrounding shape — in this derived timeline only;
        // events on disk are never touched.
        var debounced: [(timeNs: Int64, cursorID: String)] = []
        for (index, entry) in shapes.enumerated() {
            if let last = debounced.last, last.cursorID == entry.1 {
                continue  // consecutive duplicate
            }
            var nextChangeNs: Int64?
            for later in shapes[(index + 1)...] where later.1 != entry.1 {
                nextChangeNs = later.0
                break
            }
            let lifetime = (nextChangeNs ?? Int64.max) - entry.0
            if nextChangeNs != nil, lifetime < 100_000_000, !debounced.isEmpty {
                continue  // sub-threshold flicker: keep surrounding shape
            }
            debounced.append((entry.0, entry.1))
        }
        self.shapes = debounced
    }

    public var isEmpty: Bool { moves.isEmpty && downs.isEmpty }

    /// Index of the last move at or before `timeNs`, or nil.
    public func lastMoveIndex(at timeNs: Int64) -> Int? {
        var low = 0
        var high = moves.count - 1
        var result: Int?
        while low <= high {
            let mid = (low + high) / 2
            if moves[mid].timeNs <= timeNs {
                result = mid
                low = mid + 1
            } else {
                high = mid - 1
            }
        }
        return result
    }

    /// Cursor target position at `timeNs`: last move at/before it, or the
    /// first recorded position before any movement.
    public func targetPosition(at timeNs: Int64) -> SIMD2<Double>? {
        if let index = lastMoveIndex(at: timeNs) {
            return moves[index].position
        }
        return moves.first?.position ?? downs.first?.position
    }

    /// True while any mouse button is held at `timeNs`.
    public func isButtonDown(at timeNs: Int64) -> Bool {
        let downCount = countAtOrBefore(downs, timeNs)
        let upCount = countAtOrBefore(ups, timeNs)
        return downCount > upCount
    }

    /// Time of the most recent mouseDown at or before `timeNs`, if any.
    public func lastDown(at timeNs: Int64) -> Int64? {
        var result: Int64?
        for click in downs {
            if click.timeNs <= timeNs { result = click.timeNs } else { break }
        }
        return result
    }

    public func cursorID(at timeNs: Int64) -> String? {
        var result: String?
        for (time, id) in shapes {
            if time <= timeNs { result = id } else { break }
        }
        return result ?? shapes.first?.cursorID
    }

    private func countAtOrBefore(_ clicks: [Click], _ timeNs: Int64) -> Int {
        var low = 0
        var high = clicks.count
        while low < high {
            let mid = (low + high) / 2
            if clicks[mid].timeNs <= timeNs { low = mid + 1 } else { high = mid }
        }
        return low
    }
}

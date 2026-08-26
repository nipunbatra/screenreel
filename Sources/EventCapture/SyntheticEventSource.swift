import Foundation
import ProjectModel

/// Deterministic cursor/click stream for tests: the cursor follows a
/// Lissajous path sampled at a fixed rate, a click fires on a fixed period,
/// and the cursor shape alternates arrow/iBeam. Everything is a pure
/// function of time, so fixtures can assert exact positions and counts.
public final class SyntheticEventSource: @unchecked Sendable {
    private let durationNs: Int64
    private let sampleRateHz: Double
    private let displayID: Int
    private let widthPx: Double
    private let heightPx: Double
    private let clickPeriodNs: Int64
    private let shapePeriodNs: Int64
    private let pace: Double

    private var task: Task<Void, Never>?

    public init(
        durationNs: Int64,
        sampleRateHz: Double = 60,
        displayID: Int = 1,
        widthPx: Double = 1920,
        heightPx: Double = 1080,
        clickPeriodNs: Int64 = 2_000_000_000,
        shapePeriodNs: Int64 = 5_000_000_000,
        pace: Double = 0,
        emitKeystrokes: Bool = false
    ) {
        self.durationNs = durationNs
        self.sampleRateHz = sampleRateHz
        self.displayID = displayID
        self.widthPx = widthPx
        self.heightPx = heightPx
        self.clickPeriodNs = clickPeriodNs
        self.shapePeriodNs = shapePeriodNs
        self.pace = pace
        self.emitKeystrokes = emitKeystrokes
    }

    private let emitKeystrokes: Bool

    /// Expected record counts, mirroring the integer-step emission loop
    /// exactly so tests can assert precise totals.
    public var stepNs: Int64 { Int64(1_000_000_000 / sampleRateHz) }

    public var expectedMoveCount: Int {
        Int((durationNs - 1) / stepNs) + 1  // samples at k*step for k*step < duration
    }

    /// Number of click periods reached by the last emitted sample (each adds
    /// one mouseDown and one mouseUp).
    public var expectedClickCount: Int {
        let lastSampleNs = Int64(expectedMoveCount - 1) * stepNs
        return Int(lastSampleNs / clickPeriodNs)
    }

    public static func position(atNs timeNs: Int64, widthPx: Double, heightPx: Double) -> (x: Double, y: Double) {
        let t = Double(timeNs) / 1_000_000_000
        let x = (sin(t * 0.7) * 0.45 + 0.5) * widthPx
        let y = (sin(t * 1.1 + 1.0) * 0.45 + 0.5) * heightPx
        return (x.rounded(toPlaces: 1), y.rounded(toPlaces: 1))
    }

    public func start(_ handler: @escaping @Sendable (EventRecord) -> Void) {
        let durationNs = self.durationNs
        let sampleRateHz = self.sampleRateHz
        let displayID = self.displayID
        let widthPx = self.widthPx
        let heightPx = self.heightPx
        let clickPeriodNs = self.clickPeriodNs
        let shapePeriodNs = self.shapePeriodNs
        let pace = self.pace
        let emitKeystrokes = self.emitKeystrokes
        task = Task.detached(priority: .utility) {
            let stepNs = Int64(1_000_000_000 / sampleRateHz)
            var timeNs: Int64 = 0
            var nextClickNs = clickPeriodNs
            var nextShapeNs = shapePeriodNs
            var cursorID = "arrow-default"
            let wallStart = DispatchTime.now().uptimeNanoseconds
            var index = 0
            while timeNs < durationNs {
                if Task.isCancelled { return }
                let position = SyntheticEventSource.position(
                    atNs: timeNs, widthPx: widthPx, heightPx: heightPx)
                handler(EventRecord(
                    sequence: 0, timeNs: timeNs, type: .cursorMove,
                    displayID: displayID, xPx: position.x, yPx: position.y,
                    cursorID: cursorID, buttons: 0))
                if timeNs >= nextClickNs {
                    nextClickNs += clickPeriodNs
                    handler(EventRecord(
                        sequence: 0, timeNs: timeNs + 1_000_000, type: .mouseDown,
                        displayID: displayID, xPx: position.x, yPx: position.y,
                        cursorID: cursorID, button: .left, clickCount: 1, modifiers: []))
                    handler(EventRecord(
                        sequence: 0, timeNs: timeNs + 80_000_000, type: .mouseUp,
                        displayID: displayID, xPx: position.x, yPx: position.y,
                        cursorID: cursorID, button: .left, clickCount: 1, modifiers: []))
                    if emitKeystrokes {
                        // A deterministic shortcut per click period: ⌘C.
                        handler(EventRecord(
                            sequence: 0, timeNs: timeNs + 40_000_000,
                            type: .keyDown, modifiers: [.command], keyCode: 8))
                    }
                }
                if timeNs >= nextShapeNs {
                    nextShapeNs += shapePeriodNs
                    cursorID = cursorID == "arrow-default" ? "ibeam-default" : "arrow-default"
                    handler(EventRecord(
                        sequence: 0, timeNs: timeNs + 2_000_000, type: .cursorShapeChanged,
                        cursorID: cursorID))
                }
                timeNs += stepNs
                index += 1
                if pace > 0 {
                    let targetWall = wallStart + UInt64(Double(timeNs) / pace)
                    let now = DispatchTime.now().uptimeNanoseconds
                    if targetWall > now {
                        try? await Task.sleep(nanoseconds: targetWall - now)
                    }
                }
            }
        }
    }

    public func stop() async {
        task?.cancel()
        await task?.value
    }

    public func waitUntilFinished() async {
        await task?.value
    }
}

extension Double {
    fileprivate func rounded(toPlaces places: Int) -> Double {
        let factor = pow(10.0, Double(places))
        return (self * factor).rounded() / factor
    }
}

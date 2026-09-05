import AppKit
import CoreGraphics
import Foundation
import ProjectModel

/// Real cursor/click capture via a listen-only CGEvent tap plus a cursor
/// shape poller. Requires the Accessibility (input monitoring) permission,
/// which is requested separately from Screen Recording
/// (`docs/TECHNICAL_DESIGN.md` §3). Keyboard capture (for the shortcut
/// overlay) exists but is STRICTLY per-recording opt-in and off by
/// default: only keycode + modifier flags are recorded — never the typed
/// characters — and the renderer additionally refuses to draw anything
/// that is not a chorded shortcut.
///
/// Coordinates: Quartz event locations (global points) are converted to
/// **display-local physical pixels** — `(location − displayBounds.origin) ×
/// backingScale` — plus the display ID (ADR 0004). The per-display geometry
/// stored in the manifest `capture` block maps them to captured source pixels.
public final class EventTapSource: @unchecked Sendable {
    public typealias Handler = @Sendable (EventRecord) -> Void
    /// Host-time (mach_absolute) nanoseconds → session-normalized time.
    public typealias Normalizer = @Sendable (Int64) -> Int64

    private let normalizer: Normalizer
    private let handler: Handler
    private var tapPort: CFMachPort?
    private var runLoopThread: Thread?
    private var runLoop: CFRunLoop?
    private var shapeTimer: Timer?
    private let descriptorStore: CursorDescriptorStore

    // Cursor-shape state crosses the tap thread, the main-thread poller, and
    // descriptor-store tasks; all access goes through this lock.
    private let cursorLock = NSLock()
    private var lastPolledPNG: Data?
    private var lastCursorID: String?
    private var currentCursorIDLocked = "arrow-unknown"

    private var currentCursorID: String {
        cursorLock.lock()
        defer { cursorLock.unlock() }
        return currentCursorIDLocked
    }

    /// Tap-callback health. The tap sits in WindowServer's event delivery
    /// path: even a listen-only tap delays every app's input until its
    /// callback returns, and macOS disables a tap whose callback stalls.
    /// These counters make that visible in the recording's diagnostics.
    public struct Stats: Sendable, Equatable {
        public var events = 0
        public var maxCallbackNs: Int64 = 0
        public var totalCallbackNs: Int64 = 0
        /// Times macOS disabled the tap (timeout / user input) and we
        /// re-enabled it. Each one is a gap in cursor data.
        public var reenables = 0
        public var averageCallbackNs: Int64 {
            events > 0 ? totalCallbackNs / Int64(events) : 0
        }
        public init() {}
    }
    private let statsLock = NSLock()
    private var statsLocked = Stats()

    public func stats() -> Stats {
        statsLock.lock()
        defer { statsLock.unlock() }
        return statsLocked
    }

    /// Stats as perf-trace counters (`diagnostics/perf.jsonl` fields).
    public func perfCounters() -> [String: JSONValue] {
        let s = stats()
        return [
            "tapEvents": .integer(Int64(s.events)),
            "tapMaxCallbackUs": .integer(s.maxCallbackNs / 1000),
            "tapAvgCallbackUs": .integer(s.averageCallbackNs / 1000),
            "tapReenables": .integer(Int64(s.reenables)),
        ]
    }

    private func noteCallback(ns: Int64) {
        statsLock.lock()
        statsLocked.events += 1
        statsLocked.totalCallbackNs += ns
        if ns > statsLocked.maxCallbackNs { statsLocked.maxCallbackNs = ns }
        statsLock.unlock()
    }

    /// macOS turned the tap off (callback too slow, or a secure-input
    /// transition). Turn it back on: a silently dead tap records nothing
    /// for the rest of the session, which is far worse than a gap.
    private func reenableTap() {
        // Lifecycle under one lock: a disabled-notification arriving on the
        // tap thread while stop() runs must not re-enable a tap that is
        // being torn down.
        lifecycleLock.lock()
        defer { lifecycleLock.unlock() }
        guard !stopRequested, let tap = tapPort else { return }
        CGEvent.tapEnable(tap: tap, enable: true)
        statsLock.lock()
        statsLocked.reenables += 1
        statsLock.unlock()
    }

    private let lifecycleLock = NSLock()

    /// Display geometry for the last event, reused while the pointer stays
    /// on that display (refreshed every 2 s in case of reconfiguration).
    /// Only the tap thread touches it. Keeps the per-event work to a
    /// bounds check instead of three Quartz display queries.
    private var cachedDisplay: (id: CGDirectDisplayID, bounds: CGRect, scale: Double, atNs: Int64)?

    /// `scaleOverride` replaces the display's backing scale in the
    /// points→pixels conversion. Pass the *capture* scale when recording at
    /// non-native resolution (for example 1 when capturing at 1×), so event
    /// pixels land in the same space as the recorded frames.
    public init(
        descriptorStore: CursorDescriptorStore,
        normalizer: @escaping Normalizer,
        handler: @escaping Handler,
        scaleOverride: Double? = nil,
        captureKeyboard: Bool = false
    ) {
        self.descriptorStore = descriptorStore
        self.normalizer = normalizer
        self.handler = handler
        self.scaleOverride = scaleOverride
        self.captureKeyboard = captureKeyboard
    }

    private let scaleOverride: Double?
    /// Records keyDown/flagsChanged events (for the shortcut overlay).
    /// STRICTLY opt-in: keystrokes can spell out passwords, so nothing is
    /// captured unless the user enabled it for this recording.
    private let captureKeyboard: Bool

    public static func hasPermission() -> Bool {
        CGPreflightListenEventAccess()
    }

    public static func requestPermission() -> Bool {
        CGRequestListenEventAccess()
    }

    public func start() throws {
        let interestingTypes: [CGEventType] = [
            .mouseMoved,
            .leftMouseDown, .leftMouseUp,
            .rightMouseDown, .rightMouseUp,
            .otherMouseDown, .otherMouseUp,
            .leftMouseDragged, .rightMouseDragged, .otherMouseDragged,
            .scrollWheel,
        ]
        var keyboardTypes: [CGEventType] = []
        if captureKeyboard {
            keyboardTypes = [.keyDown, .flagsChanged]
        }
        var mask: CGEventMask = 0
        for type in keyboardTypes {
            mask |= CGEventMask(1) << CGEventMask(type.rawValue)
        }
        for type in interestingTypes {
            mask |= CGEventMask(1) << CGEventMask(type.rawValue)
        }

        let context = Unmanaged.passRetained(self).toOpaque()
        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .listenOnly,
            eventsOfInterest: mask,
            callback: { _, type, event, userInfo in
                guard let userInfo else { return Unmanaged.passUnretained(event) }
                let source = Unmanaged<EventTapSource>.fromOpaque(userInfo).takeUnretainedValue()
                if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
                    source.reenableTap()
                    return Unmanaged.passUnretained(event)
                }
                let startNs = Int64(clock_gettime_nsec_np(CLOCK_UPTIME_RAW))
                source.handle(type: type, event: event)
                source.noteCallback(
                    ns: Int64(clock_gettime_nsec_np(CLOCK_UPTIME_RAW)) - startNs)
                return Unmanaged.passUnretained(event)
            },
            userInfo: context)
        else {
            Unmanaged<EventTapSource>.fromOpaque(context).release()
            throw ScreenreelError.invariantViolated(
                "Could not create event tap. Grant Input Monitoring/Accessibility permission "
                    + "to the invoking terminal in System Settings → Privacy & Security.")
        }
        tapPort = tap

        let thread = Thread { [weak self] in
            guard let self, let tap = self.tapPort else { return }
            let source = CFMachPortCreateRunLoopSource(nil, tap, 0)
            self.runLoop = CFRunLoopGetCurrent()
            CFRunLoopAddSource(CFRunLoopGetCurrent(), source, .commonModes)
            CGEvent.tapEnable(tap: tap, enable: true)
            CFRunLoopRun()
        }
        thread.name = "screenreel.event-tap"
        // The callback gates WindowServer's event delivery for EVERY app;
        // on a loaded machine a default-priority thread gets starved and
        // the whole system's pointer stutters (and the tap times out).
        thread.qualityOfService = .userInteractive
        thread.start()
        runLoopThread = thread

        // Cursor shape poller (10 Hz) on the main run loop. A stop() that
        // wins the race against this block must not leave an orphan timer.
        DispatchQueue.main.async { [weak self] in
            guard let self, !self.stopRequested else { return }
            let timer = Timer(timeInterval: 0.1, repeats: true) { [weak self] _ in
                self?.pollCursorShape()
            }
            RunLoop.main.add(timer, forMode: .common)
            self.shapeTimer = timer
        }
    }

    private var stopRequested = false

    public func stop() {
        lifecycleLock.lock()
        // Idempotent: the coordinator's self-stop path and its normal stop
        // may both arrive.
        if stopRequested {
            lifecycleLock.unlock()
            return
        }
        stopRequested = true
        let tap = tapPort
        tapPort = nil
        lifecycleLock.unlock()
        if let tap {
            CGEvent.tapEnable(tap: tap, enable: false)
        }
        if let runLoop {
            CFRunLoopStop(runLoop)
        }
        // Timers must be invalidated on the thread whose run loop holds
        // them (main, where start() installed it); stop() is called from an
        // actor thread. stopRequested also closes the race with a pending
        // install block.
        let timer = shapeTimer
        shapeTimer = nil
        DispatchQueue.main.async {
            timer?.invalidate()
        }
        if tap != nil {
            Unmanaged.passUnretained(self).release()  // balance tapCreate context retain
        }
    }

    // MARK: - Event conversion

    private func handle(type: CGEventType, event: CGEvent) {
        let timeNs = normalizer(Int64(bitPattern: event.timestamp))
        if type == .keyDown || type == .flagsChanged {
            guard captureKeyboard else { return }
            // Auto-repeat spams identical downs; the overlay wants presses.
            if type == .keyDown,
                event.getIntegerValueField(.keyboardEventAutorepeat) != 0
            {
                return
            }
            handler(EventRecord(
                sequence: 0, timeNs: timeNs,
                type: type == .keyDown ? .keyDown : .flagsChanged,
                modifiers: Self.modifiers(from: event.flags),
                keyCode: Int(event.getIntegerValueField(.keyboardEventKeycode))))
            return
        }
        let location = event.location
        let display: CGDirectDisplayID
        let bounds: CGRect
        let scale: Double
        if let cached = cachedDisplay, cached.bounds.contains(location),
            timeNs - cached.atNs < 2_000_000_000
        {
            display = cached.id
            bounds = cached.bounds
            scale = cached.scale
        } else {
            guard let found = Self.display(containing: location) else { return }
            display = found
            bounds = CGDisplayBounds(found)
            scale = scaleOverride ?? Self.backingScale(of: found)
            cachedDisplay = (found, bounds, scale, timeNs)
        }
        // Display-local physical pixels (ADR 0004): subtract the display
        // origin before scaling, or coordinates on any non-origin display
        // would be permanently wrong.
        let xPx = (location.x - bounds.origin.x) * scale
        let yPx = (location.y - bounds.origin.y) * scale
        let displayID = Int(display)

        switch type {
        case .mouseMoved, .leftMouseDragged, .rightMouseDragged, .otherMouseDragged:
            let buttons = Self.pressedButtonMask(for: type)
            handler(EventRecord(
                sequence: 0, timeNs: timeNs, type: .cursorMove,
                displayID: displayID, xPx: xPx, yPx: yPx,
                cursorID: currentCursorID, buttons: buttons))
        case .leftMouseDown, .rightMouseDown, .otherMouseDown:
            handler(EventRecord(
                sequence: 0, timeNs: timeNs, type: .mouseDown,
                displayID: displayID, xPx: xPx, yPx: yPx,
                cursorID: currentCursorID,
                button: Self.button(for: type),
                clickCount: Int(event.getIntegerValueField(.mouseEventClickState)),
                pressure: event.getDoubleValueField(.mouseEventPressure),
                modifiers: Self.modifiers(from: event.flags)))
        case .leftMouseUp, .rightMouseUp, .otherMouseUp:
            handler(EventRecord(
                sequence: 0, timeNs: timeNs, type: .mouseUp,
                displayID: displayID, xPx: xPx, yPx: yPx,
                cursorID: currentCursorID,
                button: Self.button(for: type),
                clickCount: Int(event.getIntegerValueField(.mouseEventClickState)),
                modifiers: Self.modifiers(from: event.flags)))
        case .scrollWheel:
            handler(EventRecord(
                sequence: 0, timeNs: timeNs, type: .scrollWheel,
                displayID: displayID, xPx: xPx, yPx: yPx,
                cursorID: currentCursorID,
                deltaX: event.getDoubleValueField(.scrollWheelEventDeltaAxis2),
                deltaY: event.getDoubleValueField(.scrollWheelEventDeltaAxis1)))
        default:
            break
        }
    }

    private func pollCursorShape() {
        guard let cursor = NSCursor.currentSystem else { return }
        // `NSCursor.currentSystem` hands back a NEW cursor and image object
        // on every call (measured), so object identity never short-circuits.
        // The PNG of a cursor is ~1 KB and encodes in ~50 µs; comparing the
        // bytes to the last poll is the cheap way to run the hash/actor path
        // only on real shape changes, not 10× per second.
        let snapshot = CursorDescriptorStore.snapshot(of: cursor)
        cursorLock.lock()
        let unchanged = snapshot.pngData != nil && snapshot.pngData == lastPolledPNG
        lastPolledPNG = snapshot.pngData
        cursorLock.unlock()
        if unchanged { return }

        let family = CursorDescriptorStore.family(matching: cursor)
        let normalizer = self.normalizer
        let handler = self.handler
        let hostNowNs = Int64(clock_gettime_nsec_np(CLOCK_UPTIME_RAW))
        Task { [weak self] in
            guard let self else { return }
            guard let id = try? await self.descriptorStore.descriptorID(
                pngData: snapshot.pngData,
                family: family,
                widthPx: snapshot.widthPx,
                heightPx: snapshot.heightPx,
                backingScale: snapshot.backingScale,
                hotspotXPx: snapshot.hotspotXPx,
                hotspotYPx: snapshot.hotspotYPx)
            else { return }
            if self.registerCursorID(id) {
                handler(EventRecord(
                    sequence: 0, timeNs: normalizer(hostNowNs),
                    type: .cursorShapeChanged, cursorID: id))
            }
        }
    }

    /// Synchronous lock-guarded update; returns true when the ID changed.
    private func registerCursorID(_ id: String) -> Bool {
        cursorLock.lock()
        defer { cursorLock.unlock() }
        guard id != lastCursorID else { return false }
        lastCursorID = id
        currentCursorIDLocked = id
        return true
    }

    // MARK: - Static helpers

    private static func display(containing point: CGPoint) -> CGDirectDisplayID? {
        var display: CGDirectDisplayID = 0
        var count: UInt32 = 0
        guard CGGetDisplaysWithPoint(point, 1, &display, &count) == .success, count > 0 else {
            return CGMainDisplayID()
        }
        return display
    }

    private static func backingScale(of display: CGDirectDisplayID) -> Double {
        let bounds = CGDisplayBounds(display)
        guard bounds.width > 0 else { return 1 }
        return Double(CGDisplayPixelsWide(display)) / bounds.width
    }

    private static func button(for type: CGEventType) -> MouseButton {
        switch type {
        case .leftMouseDown, .leftMouseUp: return .left
        case .rightMouseDown, .rightMouseUp: return .right
        default: return .other
        }
    }

    private static func pressedButtonMask(for type: CGEventType) -> Int {
        switch type {
        case .leftMouseDragged: return 1
        case .rightMouseDragged: return 2
        case .otherMouseDragged: return 4
        default: return 0
        }
    }

    private static func modifiers(from flags: CGEventFlags) -> [EventModifier] {
        var result: [EventModifier] = []
        if flags.contains(.maskAlphaShift) { result.append(.capsLock) }
        if flags.contains(.maskShift) { result.append(.shift) }
        if flags.contains(.maskControl) { result.append(.control) }
        if flags.contains(.maskAlternate) { result.append(.option) }
        if flags.contains(.maskCommand) { result.append(.command) }
        if flags.contains(.maskSecondaryFn) { result.append(.fn) }
        return result
    }
}

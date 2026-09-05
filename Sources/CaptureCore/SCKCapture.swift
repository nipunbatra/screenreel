import AVFoundation
import CoreMedia
import Foundation
import ProjectModel
import Synchronization
@preconcurrency import ScreenCaptureKit

/// Real capture through one ScreenCaptureKit stream (macOS 15+, ADR 0001):
/// screen, system audio, and microphone share the SCStream session, so every
/// sample carries a host-clock timestamp normalized through the shared
/// `SessionClock`. The raw screen is captured with `showsCursor = false` —
/// the cursor is event data, never baked into the raw asset.
public final class SCKCapture: NSObject, @unchecked Sendable {

    public struct DisplayInfo: Sendable {
        public let displayID: UInt32
        public let widthPx: Int
        public let heightPx: Int
        public let widthPoints: Int
        public let heightPoints: Int
    }

    private let configuration: CaptureConfiguration
    private let clock: SessionClock
    /// Exclude this process's own windows (recorder UI) from the capture.
    private let excludeOwnWindows: Bool

    private var stream: SCStream?
    private let outputQueue = DispatchQueue(label: "screenreel.sck.output", qos: .userInitiated)
    // One converter per audio stream (each holds per-format state); both are
    // only ever touched on outputQueue.
    private let micConverter = SampleBufferAudioConverter()
    private let systemConverter = SampleBufferAudioConverter()

    private struct Handlers: Sendable {
        var screen: (@Sendable (VideoFrame) -> Void)?
        var mic: (@Sendable (AudioChunk) -> Void)?
        var system: (@Sendable (AudioChunk) -> Void)?
        var started = false
    }
    private let state = Mutex(Handlers())

    public init(
        configuration: CaptureConfiguration,
        clock: SessionClock,
        excludeOwnWindows: Bool = false
    ) {
        self.configuration = configuration
        self.clock = clock
        self.excludeOwnWindows = excludeOwnWindows
    }

    /// Enumerate capturable displays with their physical pixel sizes.
    /// `CGDisplayPixelsWide` returns POINTS on HiDPI displays; the true
    /// backing pixels come from the current display mode. Capturing at
    /// points quarters the resolution on Retina panels (the "blurry
    /// recording" bug found in real use).
    public static func availableDisplays() async throws -> [DisplayInfo] {
        let content = try await SCShareableContent.excludingDesktopWindows(
            false, onScreenWindowsOnly: true)
        return content.displays.map { display in
            let mode = CGDisplayCopyDisplayMode(display.displayID)
            let pixelsWide = mode?.pixelWidth ?? CGDisplayPixelsWide(display.displayID)
            let pixelsHigh = mode?.pixelHeight ?? CGDisplayPixelsHigh(display.displayID)
            return DisplayInfo(
                displayID: display.displayID,
                widthPx: pixelsWide,
                heightPx: pixelsHigh,
                widthPoints: display.width,
                heightPoints: display.height)
        }
    }

    public struct WindowInfo: Sendable, Identifiable {
        public var id: UInt32 { windowID }
        public let windowID: UInt32
        public let appName: String
        public let title: String
        public let displayID: UInt32?
        /// Window frame in global points.
        public let frame: CGRect
        /// Pixel size at the containing display's scale.
        public let widthPx: Int
        public let heightPx: Int
    }

    public struct AppInfo: Sendable, Identifiable {
        public var id: String { bundleID }
        public let bundleID: String
        public let name: String
    }

    /// One preview frame of what the given selection will record — the
    /// start screen shows this so "what am I about to capture" is never a
    /// guess. Cursor included (it is reality); scaled to `maxWidth`.
    public static func previewImage(
        kind: CaptureSourceKind,
        displayID: UInt32,
        windowID: UInt32?,
        appBundleID: String?,
        maxWidth: Int = 720
    ) async throws -> CGImage {
        let content = try await SCShareableContent.excludingDesktopWindows(
            false, onScreenWindowsOnly: true)
        guard let display = content.displays.first(where: { $0.displayID == displayID })
            ?? content.displays.first
        else {
            throw ScreenreelError.invariantViolated("no display to preview")
        }
        let ownPID = ProcessInfo.processInfo.processIdentifier
        let ownWindows = content.windows.filter {
            $0.owningApplication?.processID == ownPID
        }

        let filter: SCContentFilter
        var sourceWidth = display.width
        var sourceHeight = display.height
        switch kind {
        case .display, .area:
            filter = SCContentFilter(display: display, excludingWindows: ownWindows)
        case .window:
            guard let windowID,
                let window = content.windows.first(where: { $0.windowID == windowID })
            else {
                throw ScreenreelError.invariantViolated("selected window is gone")
            }
            filter = SCContentFilter(desktopIndependentWindow: window)
            sourceWidth = Int(window.frame.width)
            sourceHeight = Int(window.frame.height)
        case .application:
            guard let appBundleID,
                let app = content.applications.first(where: {
                    $0.bundleIdentifier == appBundleID
                })
            else {
                throw ScreenreelError.invariantViolated("selected app is not running")
            }
            filter = SCContentFilter(
                display: display, including: [app], exceptingWindows: ownWindows)
        }

        let configuration = SCStreamConfiguration()
        let scale = min(1.0, Double(maxWidth) / Double(max(1, sourceWidth)))
        configuration.width = max(2, Int(Double(sourceWidth) * scale))
        configuration.height = max(2, Int(Double(sourceHeight) * scale))
        configuration.showsCursor = true
        configuration.colorSpaceName = CGColorSpace.sRGB
        return try await SCScreenshotManager.captureImage(
            contentFilter: filter, configuration: configuration)
    }

    /// Capturable windows: on-screen, titled, reasonably sized.
    public static func availableWindows() async throws -> [WindowInfo] {
        let content = try await SCShareableContent.excludingDesktopWindows(
            true, onScreenWindowsOnly: true)
        let ownPID = ProcessInfo.processInfo.processIdentifier
        return content.windows.compactMap { window in
            guard let app = window.owningApplication,
                app.processID != ownPID,
                let title = window.title, !title.isEmpty,
                window.frame.width >= 200, window.frame.height >= 150
            else { return nil }
            let display = content.displays.first { $0.frame.intersects(window.frame) }
            let scale = display.map {
                Double(CGDisplayCopyDisplayMode($0.displayID)?.pixelWidth
                    ?? CGDisplayPixelsWide($0.displayID)) / Double($0.width)
            } ?? 2
            return WindowInfo(
                windowID: window.windowID,
                appName: app.applicationName,
                title: title,
                displayID: display?.displayID,
                frame: window.frame,
                widthPx: Int((window.frame.width * scale / 2).rounded()) * 2,
                heightPx: Int((window.frame.height * scale / 2).rounded()) * 2)
        }
        .sorted { ($0.appName, $0.title) < ($1.appName, $1.title) }
    }

    /// Running apps with capturable windows.
    public static func availableApps() async throws -> [AppInfo] {
        let content = try await SCShareableContent.excludingDesktopWindows(
            true, onScreenWindowsOnly: true)
        let ownPID = ProcessInfo.processInfo.processIdentifier
        let appsWithWindows = Set(content.windows.compactMap {
            $0.owningApplication?.bundleIdentifier
        })
        return content.applications
            .filter {
                $0.processID != ownPID && appsWithWindows.contains($0.bundleIdentifier)
                    && !$0.applicationName.isEmpty
            }
            .map { AppInfo(bundleID: $0.bundleIdentifier, name: $0.applicationName) }
            .sorted { $0.name < $1.name }
            .reduce(into: [AppInfo]()) { result, app in
                if result.last?.bundleID != app.bundleID { result.append(app) }
            }
    }

    // MARK: - Source facades for CaptureSession

    public func screenSource() -> some ScreenFrameSource { ScreenFacade(capture: self) }
    public func microphoneSource() -> some AudioChunkSource { AudioFacade(capture: self, kind: .microphone) }
    public func systemAudioSource() -> some AudioChunkSource { AudioFacade(capture: self, kind: .system) }

    private struct ScreenFacade: ScreenFrameSource {
        let capture: SCKCapture
        func start(_ handler: @escaping @Sendable (VideoFrame) -> Void) async throws {
            capture.setScreenHandler(handler)
            try await capture.startIfNeeded()
        }
        func stop() async { await capture.stopStream() }
    }

    private enum AudioKind { case microphone, system }

    private struct AudioFacade: AudioChunkSource {
        let capture: SCKCapture
        let kind: AudioKind
        func start(_ handler: @escaping @Sendable (AudioChunk) -> Void) async throws {
            capture.setAudioHandler(handler, kind: kind)
            try await capture.startIfNeeded()
        }
        func stop() async {}  // the stream stops once, via the screen facade
    }

    private func setScreenHandler(_ handler: @escaping @Sendable (VideoFrame) -> Void) {
        state.withLock { $0.screen = handler }
    }

    private func setAudioHandler(_ handler: @escaping @Sendable (AudioChunk) -> Void, kind: AudioKind) {
        state.withLock {
            switch kind {
            case .microphone: $0.mic = handler
            case .system: $0.system = handler
            }
        }
    }

    // MARK: - Stream lifecycle

    private func startIfNeeded() async throws {
        let alreadyStarted = state.withLock { handlers in
            let was = handlers.started
            handlers.started = true
            return was
        }
        guard !alreadyStarted else { return }
        do {
            try await startStream()
        } catch {
            // Reset the latch so a caller can retry instead of "succeeding"
            // against a dead stream.
            state.withLock { $0.started = false }
            self.stream = nil
            throw error
        }
    }

    private func startStream() async throws {
        let content = try await SCShareableContent.excludingDesktopWindows(
            false, onScreenWindowsOnly: true)
        guard let display = content.displays.first(where: {
            Int($0.displayID) == configuration.displayID
        }) ?? content.displays.first else {
            throw ScreenreelError.invariantViolated("no capturable display found")
        }

        var excludedWindows: [SCWindow] = []
        if excludeOwnWindows {
            let ownPID = ProcessInfo.processInfo.processIdentifier
            excludedWindows = content.windows.filter {
                $0.owningApplication?.processID == ownPID
            }
        }

        // Build the content filter for the requested source kind.
        let filter: SCContentFilter
        switch configuration.sourceKind {
        case .display, .area:
            filter = SCContentFilter(display: display, excludingWindows: excludedWindows)
        case .window:
            guard let windowID = configuration.windowID,
                let window = content.windows.first(where: { $0.windowID == windowID })
            else {
                throw ScreenreelError.invariantViolated(
                    "the selected window is gone; pick another window and retry")
            }
            filter = SCContentFilter(desktopIndependentWindow: window)
        case .application:
            guard let bundleID = configuration.appBundleID,
                let app = content.applications.first(where: { $0.bundleIdentifier == bundleID })
            else {
                throw ScreenreelError.invariantViolated(
                    "the selected application is not running; launch it and retry")
            }
            filter = SCContentFilter(
                display: display, including: [app], exceptingWindows: excludedWindows)
        }

        let streamConfiguration = SCStreamConfiguration()
        streamConfiguration.width = configuration.widthPx
        streamConfiguration.height = configuration.heightPx
        if configuration.sourceKind == .area, let area = configuration.areaRect {
            // sourceRect is in display points; output stays at pixel size.
            streamConfiguration.sourceRect = CGRect(
                x: area.x, y: area.y, width: area.width, height: area.height)
        }
        streamConfiguration.minimumFrameInterval = CMTime(
            value: 1, timescale: CMTimeScale(configuration.nominalFrameRate))
        streamConfiguration.showsCursor = false
        // NV12 straight from the compositor: the encoder consumes it
        // as-is, so capture→encode is zero-copy and skips the BGRA→YUV
        // conversion entirely.
        streamConfiguration.pixelFormat = kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
        // Capture in sRGB so downstream encoding can tag BT.709 coherently;
        // untagged output made players guess and wash the colors out.
        streamConfiguration.colorSpaceName = CGColorSpace.sRGB
        // Zero-copy pins SCK's own IOSurfaces through the handoff stream
        // and the encoder; the pool must be at least as deep as everything
        // we can pin at once or SCK silently stops delivering (no callback,
        // no counted drop). 8 surfaces vs a 6-slot handoff + ~2 in-flight.
        streamConfiguration.queueDepth = 8
        if configuration.systemAudioEnabled {
            streamConfiguration.capturesAudio = true
            streamConfiguration.sampleRate = Int(configuration.audioSampleRate)
            streamConfiguration.channelCount = 2
        }
        if configuration.microphoneEnabled {
            streamConfiguration.captureMicrophone = true
            if let uid = configuration.microphoneDeviceUID {
                streamConfiguration.microphoneCaptureDeviceID = uid
            }
        }

        let stream = SCStream(filter: filter, configuration: streamConfiguration, delegate: nil)
        try stream.addStreamOutput(self, type: .screen, sampleHandlerQueue: outputQueue)
        if configuration.systemAudioEnabled {
            try stream.addStreamOutput(self, type: .audio, sampleHandlerQueue: outputQueue)
        }
        if configuration.microphoneEnabled {
            try stream.addStreamOutput(self, type: .microphone, sampleHandlerQueue: outputQueue)
        }
        self.stream = stream
        try await stream.startCapture()
    }

    private func stopStream() async {
        guard let stream else { return }
        self.stream = nil
        try? await stream.stopCapture()
    }
}

// MARK: - SCStreamOutput

extension SCKCapture: SCStreamOutput {
    public func stream(
        _ stream: SCStream,
        didOutputSampleBuffer sampleBuffer: CMSampleBuffer,
        of type: SCStreamOutputType
    ) {
        switch type {
        case .screen:
            handleScreen(sampleBuffer)
        case .audio:
            let handler = state.withLock { $0.system }
            if let handler, let chunk = systemConverter.chunk(from: sampleBuffer, clock: clock) {
                handler(chunk)
            }
        case .microphone:
            let handler = state.withLock { $0.mic }
            if let handler, let chunk = micConverter.chunk(from: sampleBuffer, clock: clock) {
                handler(chunk)
            }
        @unknown default:
            break
        }
    }

    private func handleScreen(_ sampleBuffer: CMSampleBuffer) {
        guard sampleBuffer.isValid,
            let attachments = CMSampleBufferGetSampleAttachmentsArray(
                sampleBuffer, createIfNecessary: false) as? [[SCStreamFrameInfo: Any]],
            let statusRaw = attachments.first?[.status] as? Int,
            let status = SCFrameStatus(rawValue: statusRaw),
            status == .complete,
            let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer)
        else { return }
        guard let handler = state.withLock({ $0.screen }) else { return }
        let pts = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
        // An invalid PTS (display reconfiguration) yields NaN seconds, and
        // Int64(nan) traps — drop the sample instead of dying mid-capture.
        guard pts.isNumeric else { return }
        let hostNs = Int64(pts.seconds * 1_000_000_000)
        handler(VideoFrame(
            pixelBuffer: pixelBuffer,
            ptsNs: clock.normalizeHostNs(hostNs),
            sourceNs: hostNs,
            sampleBuffer: sampleBuffer))
    }
}

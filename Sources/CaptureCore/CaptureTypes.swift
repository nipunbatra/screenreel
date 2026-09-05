import CoreMedia
import CoreVideo
import Foundation
import ProjectModel

/// One captured (or synthesized) screen frame with a session-normalized
/// presentation time. The pixel buffer is transferred, not shared: sources
/// hand each frame to exactly one consumer.
public struct VideoFrame: @unchecked Sendable {
    public let pixelBuffer: CVPixelBuffer
    /// Session-normalized presentation time.
    public let ptsNs: Int64
    /// Original host-clock timestamp before normalization.
    public let sourceNs: Int64
    /// The capture's original sample buffer, when available. Writers append
    /// it zero-copy (re-timed) instead of going through a pixel-buffer
    /// adaptor — the capture→encode path then never touches pixels
    ///.
    public let sampleBuffer: CMSampleBuffer?

    public init(
        pixelBuffer: CVPixelBuffer, ptsNs: Int64, sourceNs: Int64? = nil,
        sampleBuffer: CMSampleBuffer? = nil
    ) {
        self.pixelBuffer = pixelBuffer
        self.ptsNs = ptsNs
        self.sourceNs = sourceNs ?? ptsNs
        self.sampleBuffer = sampleBuffer
    }
}

/// A run of interleaved float32 PCM with a session-normalized start time.
public struct AudioChunk: Sendable {
    public let samples: [Float]  // interleaved, frameCount * channels values
    public let frameCount: Int
    public let channels: Int
    public let sampleRate: Double
    /// Session-normalized presentation time of the first frame.
    public let ptsNs: Int64
    /// Original host-clock timestamp before normalization.
    public let sourceNs: Int64

    public init(
        samples: [Float], frameCount: Int, channels: Int,
        sampleRate: Double, ptsNs: Int64, sourceNs: Int64? = nil
    ) {
        precondition(samples.count == frameCount * channels)
        self.samples = samples
        self.frameCount = frameCount
        self.channels = channels
        self.sampleRate = sampleRate
        self.ptsNs = ptsNs
        self.sourceNs = sourceNs ?? ptsNs
    }
}

extension AudioChunk {
    /// Downmix (average) or upmix (duplicate) to a target channel count.
    public func adapted(toChannels target: Int) -> AudioChunk {
        guard target != channels else { return self }
        var out = [Float](repeating: 0, count: frameCount * target)
        for frame in 0..<frameCount {
            if target < channels {
                var sum: Float = 0
                for c in 0..<channels { sum += samples[frame * channels + c] }
                let mixed = sum / Float(channels)
                for c in 0..<target { out[frame * target + c] = mixed }
            } else {
                for c in 0..<target {
                    out[frame * target + c] = samples[frame * channels + min(c, channels - 1)]
                }
            }
        }
        return AudioChunk(
            samples: out, frameCount: frameCount, channels: target,
            sampleRate: sampleRate, ptsNs: ptsNs, sourceNs: sourceNs)
    }
}

public protocol ScreenFrameSource: Sendable {
    func start(_ handler: @escaping @Sendable (VideoFrame) -> Void) async throws
    func stop() async
}

public protocol AudioChunkSource: Sendable {
    func start(_ handler: @escaping @Sendable (AudioChunk) -> Void) async throws
    func stop() async
}

/// What gets captured: a whole display, one window, a display area, or one
/// application's windows on a display.
public enum CaptureSourceKind: String, Codable, Sendable {
    case display, window, area, application
}

/// Area rectangle in display points (top-left origin, display-local).
public struct AreaRect: Codable, Sendable, Equatable {
    public var x: Double
    public var y: Double
    public var width: Double
    public var height: Double

    public init(x: Double, y: Double, width: Double, height: Double) {
        self.x = x
        self.y = y
        self.width = width
        self.height = height
    }
}

/// Session-level configuration persisted into `manifest.capture` and used to
/// shape writers. Segment duration is clamped to the accepted 2–5 s range
/// (ADR 0002).
public struct CaptureConfiguration: Codable, Sendable {
    public var widthPx: Int
    public var heightPx: Int
    public var nominalFrameRate: Double
    public var videoCodec: MediaCodec
    public var displayID: Int
    public var sourceKind: CaptureSourceKind
    /// Window capture: the CGWindowID.
    public var windowID: UInt32?
    /// Application capture: the app's bundle identifier.
    public var appBundleID: String?
    /// Area capture: rect in display points.
    public var areaRect: AreaRect?
    /// Pixels-per-point of the captured display, for event mapping.
    public var displayScale: Double
    /// Offset subtracted from display-local event pixels to reach source
    /// pixels (nonzero for area/window capture).
    public var eventOffsetXPx: Double
    public var eventOffsetYPx: Double
    public var microphoneEnabled: Bool
    public var microphoneDeviceUID: String?
    public var microphoneDeviceName: String?
    public var systemAudioEnabled: Bool
    public var cameraEnabled: Bool
    public var cameraDeviceID: String?
    public var audioSampleRate: Double
    public var segmentDurationSeconds: Double
    /// Average encode bitrate as bits per pixel per frame; 0.1 ≈ 25 Mb/s
    /// for 4K30. Lossy compression; native dimensions preserve text detail.
    public var bitsPerPixelPerFrame: Double
    /// Record keyDown/flagsChanged events for the shortcut overlay.
    /// Optional so old manifests decode unchanged; nil/false = off. OFF by
    /// default: keystrokes can spell out passwords.
    public var captureKeystrokes: Bool?
    public var captureKeystrokesEnabled: Bool { captureKeystrokes ?? false }

    public var segmentDurationNs: Int64 {
        Int64(min(5.0, max(2.0, segmentDurationSeconds)) * 1_000_000_000)
    }

    public init(
        widthPx: Int,
        heightPx: Int,
        nominalFrameRate: Double = 30,
        videoCodec: MediaCodec = .hevc,
        displayID: Int = 0,
        sourceKind: CaptureSourceKind = .display,
        windowID: UInt32? = nil,
        appBundleID: String? = nil,
        areaRect: AreaRect? = nil,
        displayScale: Double = 1,
        eventOffsetXPx: Double = 0,
        eventOffsetYPx: Double = 0,
        microphoneEnabled: Bool = true,
        microphoneDeviceUID: String? = nil,
        microphoneDeviceName: String? = nil,
        systemAudioEnabled: Bool = false,
        cameraEnabled: Bool = false,
        cameraDeviceID: String? = nil,
        captureKeystrokes: Bool? = nil,
        audioSampleRate: Double = 48_000,
        segmentDurationSeconds: Double = 4,
        bitsPerPixelPerFrame: Double = 0.1
    ) {
        self.widthPx = widthPx
        self.heightPx = heightPx
        self.nominalFrameRate = nominalFrameRate
        self.videoCodec = videoCodec
        self.displayID = displayID
        self.sourceKind = sourceKind
        self.windowID = windowID
        self.appBundleID = appBundleID
        self.areaRect = areaRect
        self.displayScale = displayScale
        self.eventOffsetXPx = eventOffsetXPx
        self.eventOffsetYPx = eventOffsetYPx
        self.microphoneEnabled = microphoneEnabled
        self.microphoneDeviceUID = microphoneDeviceUID
        self.microphoneDeviceName = microphoneDeviceName
        self.systemAudioEnabled = systemAudioEnabled
        self.cameraEnabled = cameraEnabled
        self.cameraDeviceID = cameraDeviceID
        self.captureKeystrokes = captureKeystrokes
        self.audioSampleRate = audioSampleRate
        self.segmentDurationSeconds = segmentDurationSeconds
        self.bitsPerPixelPerFrame = bitsPerPixelPerFrame
    }

    // Manifests written before source kinds / camera / event offsets existed
    // must keep decoding (CLAUDE.md: old projects remain readable). Every
    // field added after v1 decodes with its default when absent.
    private enum CodingKeys: String, CodingKey {
        case widthPx, heightPx, nominalFrameRate, videoCodec, displayID
        case sourceKind, windowID, appBundleID, areaRect, displayScale
        case eventOffsetXPx, eventOffsetYPx
        case microphoneEnabled, microphoneDeviceUID, microphoneDeviceName
        case systemAudioEnabled, cameraEnabled, cameraDeviceID
        case audioSampleRate, segmentDurationSeconds, bitsPerPixelPerFrame
        case captureKeystrokes
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.widthPx = try c.decode(Int.self, forKey: .widthPx)
        self.heightPx = try c.decode(Int.self, forKey: .heightPx)
        self.nominalFrameRate = try c.decode(Double.self, forKey: .nominalFrameRate)
        self.videoCodec = try c.decode(MediaCodec.self, forKey: .videoCodec)
        self.displayID = try c.decode(Int.self, forKey: .displayID)
        self.sourceKind =
            try c.decodeIfPresent(CaptureSourceKind.self, forKey: .sourceKind) ?? .display
        self.windowID = try c.decodeIfPresent(UInt32.self, forKey: .windowID)
        self.appBundleID = try c.decodeIfPresent(String.self, forKey: .appBundleID)
        self.areaRect = try c.decodeIfPresent(AreaRect.self, forKey: .areaRect)
        self.displayScale = try c.decodeIfPresent(Double.self, forKey: .displayScale) ?? 1
        self.eventOffsetXPx = try c.decodeIfPresent(Double.self, forKey: .eventOffsetXPx) ?? 0
        self.eventOffsetYPx = try c.decodeIfPresent(Double.self, forKey: .eventOffsetYPx) ?? 0
        self.microphoneEnabled = try c.decode(Bool.self, forKey: .microphoneEnabled)
        self.microphoneDeviceUID = try c.decodeIfPresent(String.self, forKey: .microphoneDeviceUID)
        self.microphoneDeviceName = try c.decodeIfPresent(String.self, forKey: .microphoneDeviceName)
        self.systemAudioEnabled = try c.decode(Bool.self, forKey: .systemAudioEnabled)
        self.cameraEnabled = try c.decodeIfPresent(Bool.self, forKey: .cameraEnabled) ?? false
        self.cameraDeviceID = try c.decodeIfPresent(String.self, forKey: .cameraDeviceID)
        self.audioSampleRate = try c.decode(Double.self, forKey: .audioSampleRate)
        self.segmentDurationSeconds = try c.decode(Double.self, forKey: .segmentDurationSeconds)
        self.bitsPerPixelPerFrame = try c.decode(Double.self, forKey: .bitsPerPixelPerFrame)
        self.captureKeystrokes = try c.decodeIfPresent(Bool.self, forKey: .captureKeystrokes)
    }
}

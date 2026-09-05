import Foundation

// Swift mirror of `Schemas/project-manifest-v1.schema.json`. Decoding is
// strict for required fields; unknown extra fields are tolerated (additive
// minor changes), and a `schemaVersion` above `ProjectSchema.currentVersion`
// must be rejected by callers via `Manifest.checkReadable`.

public struct Manifest: Codable, Sendable, Equatable {
    public var format: String
    public var schemaVersion: Int
    public var projectID: UUID
    public var appVersion: String
    public var createdAt: String
    public var modifiedAt: String
    public var state: ProjectState
    public var clock: ClockAnchor
    public var capture: JSONValue?
    public var tracks: [TrackDescriptor]
    public var timeline: String?
    public var durationNs: Int64?
    public var generation: Int

    public init(
        projectID: UUID = UUID(),
        createdAt: String = RFC3339.now(),
        state: ProjectState,
        clock: ClockAnchor,
        capture: JSONValue? = nil,
        tracks: [TrackDescriptor] = [],
        timeline: String? = nil,
        durationNs: Int64? = nil,
        generation: Int = 1
    ) {
        self.format = ProjectSchema.formatIdentifier
        self.schemaVersion = ProjectSchema.currentVersion
        self.projectID = projectID
        self.appVersion = ProjectSchema.toolVersion
        self.createdAt = createdAt
        self.modifiedAt = createdAt
        self.state = state
        self.clock = clock
        self.capture = capture
        self.tracks = tracks
        self.timeline = timeline
        self.durationNs = durationNs
        self.generation = generation
    }

    /// Throws `schemaTooNew` / `manifestInvalid` for documents this build
    /// must not interpret. Raw media stays reachable either way.
    public func checkReadable(at path: String) throws {
        guard ProjectSchema.isKnownFormat(format) else {
            throw ScreenreelError.manifestInvalid(path: path, reason: "unknown format discriminator '\(format)'")
        }
        guard schemaVersion <= ProjectSchema.currentVersion else {
            throw ScreenreelError.schemaTooNew(
                found: schemaVersion, supported: ProjectSchema.currentVersion, path: path)
        }
    }
}

public enum ProjectState: String, Codable, Sendable {
    case recording
    case recoverable
    case ready
}

/// One monotonic host clock for all streams (`docs/TECHNICAL_DESIGN.md` §3).
/// `originContinuousTicks`/`originAbsoluteTicks` are `mach_continuous_time()`
/// and `mach_absolute_time()` sampled at the same instant; tick→ns conversion
/// uses `timebaseNumer/timebaseDenom`.
public struct ClockAnchor: Codable, Sendable, Equatable {
    public var originContinuousTicks: UInt64
    public var originAbsoluteTicks: UInt64
    public var timebaseNumer: UInt32
    public var timebaseDenom: UInt32
    public var originWallTime: String
    public var firstStreamTimestamps: [String: Int64]?

    public init(
        originContinuousTicks: UInt64,
        originAbsoluteTicks: UInt64,
        timebaseNumer: UInt32,
        timebaseDenom: UInt32,
        originWallTime: String,
        firstStreamTimestamps: [String: Int64]? = nil
    ) {
        self.originContinuousTicks = originContinuousTicks
        self.originAbsoluteTicks = originAbsoluteTicks
        self.timebaseNumer = timebaseNumer
        self.timebaseDenom = timebaseDenom
        self.originWallTime = originWallTime
        self.firstStreamTimestamps = firstStreamTimestamps
    }
}

public enum TrackType: String, Codable, Sendable, CaseIterable {
    case screen
    case microphone
    case systemAudio
    case camera
    case cursorEvents
    case clickEvents
    case keyboardEvents

    public var isMedia: Bool {
        switch self {
        case .screen, .microphone, .systemAudio, .camera: return true
        case .cursorEvents, .clickEvents, .keyboardEvents: return false
        }
    }
}

public struct TrackDescriptor: Codable, Sendable, Equatable {
    public var id: UUID
    public var type: TrackType
    public var displayID: Int?
    public var deviceUID: String?
    public var deviceName: String?
    public var cursorBaked: Bool?
    public var enabled: Bool?
    public var offsetNs: Int64?
    public var segments: [SegmentDescriptor]?
    public var eventChunks: [EventChunkDescriptor]?
    public var discontinuities: [Discontinuity]?

    public init(
        id: UUID = UUID(),
        type: TrackType,
        displayID: Int? = nil,
        deviceUID: String? = nil,
        deviceName: String? = nil,
        cursorBaked: Bool? = nil,
        enabled: Bool? = true,
        offsetNs: Int64? = nil,
        segments: [SegmentDescriptor]? = nil,
        eventChunks: [EventChunkDescriptor]? = nil,
        discontinuities: [Discontinuity]? = nil
    ) {
        self.id = id
        self.type = type
        self.displayID = displayID
        self.deviceUID = deviceUID
        self.deviceName = deviceName
        self.cursorBaked = cursorBaked
        self.enabled = enabled
        self.offsetNs = offsetNs
        self.segments = segments
        self.eventChunks = eventChunks
        self.discontinuities = discontinuities
    }
}

public struct Discontinuity: Codable, Sendable, Equatable {
    public var startNs: Int64
    public var endNs: Int64?
    public var reason: String

    public init(startNs: Int64, endNs: Int64? = nil, reason: String) {
        self.startNs = startNs
        self.endNs = endNs
        self.reason = reason
    }
}

public enum MediaContainer: String, Codable, Sendable {
    case mov
    case caf
}

public enum MediaCodec: String, Codable, Sendable {
    case hevc
    case h264
    case pcmFloat32
    case pcmInt16
    case pcmInt24
}

public struct VideoFormatInfo: Codable, Sendable, Equatable {
    public var widthPx: Int
    public var heightPx: Int
    public var nominalFrameRate: Double?
    public var frameCount: Int?

    public init(widthPx: Int, heightPx: Int, nominalFrameRate: Double? = nil, frameCount: Int? = nil) {
        self.widthPx = widthPx
        self.heightPx = heightPx
        self.nominalFrameRate = nominalFrameRate
        self.frameCount = frameCount
    }
}

public struct AudioFormatInfo: Codable, Sendable, Equatable {
    public var sampleRate: Double
    public var channels: Int
    public var layout: String?
    public var bitsPerSample: Int?
    public var floatingPoint: Bool?
    public var sampleCount: Int?

    public init(
        sampleRate: Double, channels: Int, layout: String? = nil,
        bitsPerSample: Int? = nil, floatingPoint: Bool? = nil, sampleCount: Int? = nil
    ) {
        self.sampleRate = sampleRate
        self.channels = channels
        self.layout = layout
        self.bitsPerSample = bitsPerSample
        self.floatingPoint = floatingPoint
        self.sampleCount = sampleCount
    }
}

/// A committed raw media segment (`docs/PROJECT_FORMAT.md` §3).
public struct SegmentDescriptor: Codable, Sendable, Equatable {
    public var id: UUID
    public var trackID: UUID
    public var trackType: TrackType
    public var path: String
    public var sequenceInTrack: Int
    public var container: MediaContainer
    public var codec: MediaCodec
    public var video: VideoFormatInfo?
    public var audio: AudioFormatInfo?
    public var sourceStartNs: Int64
    public var sourceEndNs: Int64
    public var normalizedStartNs: Int64
    public var normalizedEndNs: Int64
    public var byteSize: Int64
    public var sha256: String
    public var droppedFrames: Int?
    public var droppedBuffers: Int?
    public var discontinuityBefore: Bool?
    /// True when the time range was reconstructed (e.g. an orphan tail
    /// attached during recovery) rather than measured at capture.
    public var timingEstimated: Bool?
    public var commitSequence: UInt64
    public var toolVersion: String

    public init(
        id: UUID = UUID(),
        trackID: UUID,
        trackType: TrackType,
        path: String,
        sequenceInTrack: Int,
        container: MediaContainer,
        codec: MediaCodec,
        video: VideoFormatInfo? = nil,
        audio: AudioFormatInfo? = nil,
        sourceStartNs: Int64,
        sourceEndNs: Int64,
        normalizedStartNs: Int64,
        normalizedEndNs: Int64,
        byteSize: Int64,
        sha256: String,
        droppedFrames: Int? = nil,
        droppedBuffers: Int? = nil,
        discontinuityBefore: Bool? = nil,
        timingEstimated: Bool? = nil,
        commitSequence: UInt64,
        toolVersion: String = ProjectSchema.toolVersion
    ) {
        self.id = id
        self.trackID = trackID
        self.trackType = trackType
        self.path = path
        self.sequenceInTrack = sequenceInTrack
        self.container = container
        self.codec = codec
        self.video = video
        self.audio = audio
        self.sourceStartNs = sourceStartNs
        self.sourceEndNs = sourceEndNs
        self.normalizedStartNs = normalizedStartNs
        self.normalizedEndNs = normalizedEndNs
        self.byteSize = byteSize
        self.sha256 = sha256
        self.droppedFrames = droppedFrames
        self.droppedBuffers = droppedBuffers
        self.discontinuityBefore = discontinuityBefore
        self.timingEstimated = timingEstimated
        self.commitSequence = commitSequence
        self.toolVersion = toolVersion
    }
}

public enum EventChunkKind: String, Codable, Sendable {
    case cursor
    case clicks
    case keyboard
}

public enum ChunkCompression: String, Codable, Sendable {
    case none
    case zstd
}

/// A committed event chunk (`docs/PROJECT_FORMAT.md` §4, ADR 0003).
public struct EventChunkDescriptor: Codable, Sendable, Equatable {
    public var id: UUID
    public var trackID: UUID
    public var kind: EventChunkKind
    public var path: String
    public var sequenceInTrack: Int
    public var compression: ChunkCompression
    public var firstEventSequence: UInt64
    public var lastEventSequence: UInt64
    public var startNs: Int64
    public var endNs: Int64
    public var recordCount: Int
    public var byteSize: Int64
    public var sha256: String
    public var commitSequence: UInt64
    public var toolVersion: String

    public init(
        id: UUID = UUID(),
        trackID: UUID,
        kind: EventChunkKind,
        path: String,
        sequenceInTrack: Int,
        compression: ChunkCompression = .none,
        firstEventSequence: UInt64,
        lastEventSequence: UInt64,
        startNs: Int64,
        endNs: Int64,
        recordCount: Int,
        byteSize: Int64,
        sha256: String,
        commitSequence: UInt64,
        toolVersion: String = ProjectSchema.toolVersion
    ) {
        self.id = id
        self.trackID = trackID
        self.kind = kind
        self.path = path
        self.sequenceInTrack = sequenceInTrack
        self.compression = compression
        self.firstEventSequence = firstEventSequence
        self.lastEventSequence = lastEventSequence
        self.startNs = startNs
        self.endNs = endNs
        self.recordCount = recordCount
        self.byteSize = byteSize
        self.sha256 = sha256
        self.commitSequence = commitSequence
        self.toolVersion = toolVersion
    }
}

extension Manifest {
    /// Append a committed segment to its track, keeping segments ordered.
    public mutating func appendSegment(_ segment: SegmentDescriptor) {
        guard let index = tracks.firstIndex(where: { $0.id == segment.trackID }) else { return }
        var segments = tracks[index].segments ?? []
        segments.append(segment)
        segments.sort { $0.sequenceInTrack < $1.sequenceInTrack }
        tracks[index].segments = segments
        if segment.trackType.isMedia {
            durationNs = max(durationNs ?? 0, segment.normalizedEndNs)
        }
    }

    /// Append a committed event chunk to its track, keeping chunks ordered.
    public mutating func appendEventChunk(_ chunk: EventChunkDescriptor) {
        guard let index = tracks.firstIndex(where: { $0.id == chunk.trackID }) else { return }
        var chunks = tracks[index].eventChunks ?? []
        chunks.append(chunk)
        chunks.sort { $0.sequenceInTrack < $1.sequenceInTrack }
        tracks[index].eventChunks = chunks
    }

    /// Just the fields needed to decide readability, so a future-schema
    /// document (with enum cases this build has never heard of) reports
    /// "schema too new" instead of an opaque DecodingError.
    private struct VersionProbe: Decodable {
        var format: String
        var schemaVersion: Int
    }

    public static func decode(from data: Data, path: String) throws -> Manifest {
        if let probe = try? JSONDecoder().decode(VersionProbe.self, from: data) {
            guard ProjectSchema.isKnownFormat(probe.format) else {
                throw ScreenreelError.manifestInvalid(
                    path: path, reason: "unknown format discriminator '\(probe.format)'")
            }
            guard probe.schemaVersion <= ProjectSchema.currentVersion else {
                throw ScreenreelError.schemaTooNew(
                    found: probe.schemaVersion,
                    supported: ProjectSchema.currentVersion, path: path)
            }
        }
        let manifest: Manifest
        do {
            manifest = try JSONDecoder().decode(Manifest.self, from: data)
        } catch {
            throw ScreenreelError.manifestInvalid(path: path, reason: "\(error)")
        }
        try manifest.checkReadable(at: path)
        return manifest
    }

    /// Enforce the relative-path rule for every referenced asset.
    public func validatePaths() -> [String] {
        var problems: [String] = []
        for track in tracks {
            for segment in track.segments ?? [] where !Self.isSafeRelativePath(segment.path) {
                problems.append("segment path is not a safe relative path: \(segment.path)")
            }
            for chunk in track.eventChunks ?? [] where !Self.isSafeRelativePath(chunk.path) {
                problems.append("event chunk path is not a safe relative path: \(chunk.path)")
            }
        }
        return problems
    }

    public static func isSafeRelativePath(_ path: String) -> Bool {
        guard !path.isEmpty else { return false }
        var candidate = path
        for _ in 0..<3 {
            guard isSafeDecodedRelativePath(candidate) else { return false }
            guard let decoded = candidate.removingPercentEncoding else { return false }
            if decoded == candidate { return true }
            candidate = decoded
        }
        return isSafeDecodedRelativePath(candidate)
    }

    private static func isSafeDecodedRelativePath(_ path: String) -> Bool {
        let normalized = path.replacingOccurrences(of: "\\", with: "/")
        guard !normalized.hasPrefix("/") else { return false }
        let components = normalized.split(separator: "/")
        return !components.contains("..") && !components.isEmpty
    }
}

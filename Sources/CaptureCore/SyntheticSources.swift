import CoreVideo
import Foundation
import Synchronization

/// Deterministic delivery pathologies for the synthetic sources (sync-matrix
/// stress tests): seeded PTS jitter, periodic frame drops, and a mid-stream
/// delivery gap. All fields default to a steady stream, so existing call
/// sites are unaffected.
public struct SyntheticDelivery: Sendable {
    /// Maximum |PTS jitter| in nanoseconds. Each emission's nominal PTS is
    /// shifted by a seeded deterministic offset in ±amplitude; the first
    /// emission's jitter is clamped non-negative so streams never start
    /// before 0. Callers must keep the amplitude under half the emission
    /// spacing when strict monotonicity matters (video).
    public var jitterAmplitudeNs: Int64
    /// Seed for the deterministic jitter sequence (SplitMix64).
    public var jitterSeed: UInt64
    /// Video: drop every Nth frame (indices n-1, 2n-1, …) — the frame is
    /// simply never delivered. 0 disables.
    public var dropEveryNth: Int
    /// Half-open window [start, start+duration) of nominal stream time in
    /// which nothing is delivered — a stall/sleep shaped hole. Later
    /// emissions keep their true (later) timestamps.
    public var gapStartNs: Int64?
    public var gapDurationNs: Int64

    public init(
        jitterAmplitudeNs: Int64 = 0,
        jitterSeed: UInt64 = 0x9E37_79B9_7F4A_7C15,
        dropEveryNth: Int = 0,
        gapStartNs: Int64? = nil,
        gapDurationNs: Int64 = 0
    ) {
        self.jitterAmplitudeNs = jitterAmplitudeNs
        self.jitterSeed = jitterSeed
        self.dropEveryNth = dropEveryNth
        self.gapStartNs = gapStartNs
        self.gapDurationNs = gapDurationNs
    }

    public static let steady = SyntheticDelivery()

    func inGap(_ nominalPtsNs: Int64) -> Bool {
        guard let gapStartNs, gapDurationNs > 0 else { return false }
        return nominalPtsNs >= gapStartNs && nominalPtsNs < gapStartNs + gapDurationNs
    }
}

/// What a synthetic source actually emitted, for sent-vs-muxed assertions.
/// `frames` counts video frames or audio sample frames; PTS fields are the
/// (possibly jittered) timestamps of the first and last emission.
public struct SyntheticSentStats: Sendable {
    public var frames: Int = 0
    public var firstPtsNs: Int64?
    public var lastPtsNs: Int64?
}

/// Small deterministic RNG for reproducible jitter sequences.
struct SplitMix64 {
    private var state: UInt64
    init(seed: UInt64) { state = seed }
    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }

    /// Uniform value in ±amplitude (inclusive).
    mutating func jitter(amplitudeNs: Int64) -> Int64 {
        guard amplitudeNs > 0 else { return 0 }
        let span = UInt64(2 * amplitudeNs + 1)
        return Int64(next() % span) - amplitudeNs
    }
}

/// Deterministic screen source for tests and fixtures: BGRA frames whose
/// content is a pure function of the frame index (moving bar + changing
/// background), so runs are reproducible and the encoder does real work.
/// `pace` 1.0 generates in real time; 0 generates flat out (synthetic
/// ten-minute captures finish in well under ten minutes).
public final class SyntheticScreenSource: ScreenFrameSource, @unchecked Sendable {
    private let width: Int
    private let height: Int
    private let frameRate: Double
    private let durationNs: Int64
    private let pace: Double
    private let startOffsetNs: Int64
    private let delivery: SyntheticDelivery

    private let stopped = Mutex(false)
    private let sent = Mutex(SyntheticSentStats())
    private var task: Task<Void, Never>?

    public init(
        width: Int, height: Int, frameRate: Double,
        durationNs: Int64, pace: Double = 0, startOffsetNs: Int64 = 0,
        delivery: SyntheticDelivery = .steady
    ) {
        self.width = width
        self.height = height
        self.frameRate = frameRate
        self.durationNs = durationNs
        self.pace = pace
        self.startOffsetNs = startOffsetNs
        self.delivery = delivery
    }

    /// Frames actually emitted plus their first/last (jittered) timestamps.
    public func sentStats() -> SyntheticSentStats {
        sent.withLock { $0 }
    }

    public func start(_ handler: @escaping @Sendable (VideoFrame) -> Void) async throws {
        let frameCount = Int(Double(durationNs) / 1_000_000_000 * frameRate)
        let width = self.width
        let height = self.height
        let frameRate = self.frameRate
        let pace = self.pace
        let offset = self.startOffsetNs
        let delivery = self.delivery
        task = Task.detached(priority: .userInitiated) { [weak self] in
            var pool: CVPixelBufferPool?
            let poolAttributes: [String: Any] = [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
                kCVPixelBufferWidthKey as String: width,
                kCVPixelBufferHeightKey as String: height,
            ]
            CVPixelBufferPoolCreate(nil, nil, poolAttributes as CFDictionary, &pool)
            guard let pool else { return }

            var rng = SplitMix64(seed: delivery.jitterSeed)
            var emittedAny = false
            let wallStart = DispatchTime.now().uptimeNanoseconds
            for index in 0..<frameCount {
                if Task.isCancelled { return }
                if let self, self.isStopped() { return }
                let nominalNs = offset + Int64(Double(index) * 1_000_000_000 / frameRate)
                // Jitter is consumed per frame even when the frame is then
                // dropped/gapped, so the sequence stays index-deterministic.
                var jitterNs = rng.jitter(amplitudeNs: delivery.jitterAmplitudeNs)
                let dropped = delivery.dropEveryNth > 0
                    && (index + 1) % delivery.dropEveryNth == 0
                if !dropped, !delivery.inGap(nominalNs) {
                    if !emittedAny { jitterNs = max(0, jitterNs) }
                    let ptsNs = nominalNs + jitterNs
                    var bufferOut: CVPixelBuffer?
                    CVPixelBufferPoolCreatePixelBuffer(nil, pool, &bufferOut)
                    guard let buffer = bufferOut else { continue }
                    Self.render(frameIndex: index, into: buffer, width: width, height: height)
                    handler(VideoFrame(pixelBuffer: buffer, ptsNs: ptsNs))
                    emittedAny = true
                    self?.sent.withLock { stats in
                        stats.frames += 1
                        if stats.firstPtsNs == nil { stats.firstPtsNs = ptsNs }
                        stats.lastPtsNs = ptsNs
                    }
                }
                if pace > 0 {
                    let targetWall = wallStart
                        + UInt64(Double(index + 1) * 1_000_000_000 / frameRate / pace)
                    let now = DispatchTime.now().uptimeNanoseconds
                    if targetWall > now {
                        try? await Task.sleep(nanoseconds: targetWall - now)
                    }
                }
            }
        }
    }

    public func stop() async {
        stopped.withLock { $0 = true }
        task?.cancel()
        await task?.value
    }

    /// Wait for natural completion (all frames generated).
    public func waitUntilFinished() async {
        await task?.value
    }

    private func isStopped() -> Bool {
        stopped.withLock { $0 }
    }

    private static func render(frameIndex: Int, into buffer: CVPixelBuffer, width: Int, height: Int) {
        CVPixelBufferLockBaseAddress(buffer, [])
        defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
        guard let base = CVPixelBufferGetBaseAddress(buffer) else { return }
        let bytesPerRow = CVPixelBufferGetBytesPerRow(buffer)
        // Background varies per frame; a white bar sweeps left→right once per
        // 120 frames so every frame differs.
        let background = Int32((frameIndex &* 7) % 200)
        let barX = (frameIndex % 120) * max(1, width / 120)
        let barWidth = max(8, width / 60)
        for y in 0..<height {
            let row = base.advanced(by: y * bytesPerRow)
            memset(row, background, width * 4)
            let inHorizontalBand = y > height / 3 && y < 2 * height / 3
            if inHorizontalBand {
                let start = min(barX, width - barWidth)
                memset(row.advanced(by: start * 4), 255, barWidth * 4)
            }
        }
    }
}

/// Deterministic audio source: a fixed-frequency sine with amplitude keyed to
/// the chunk index. `silenceAfterNs` simulates a microphone that dies
/// mid-session (the missing-audio acceptance gate) by stopping delivery —
/// not by sending zeros — after that timestamp.
public final class SyntheticAudioSource: AudioChunkSource, @unchecked Sendable {
    private let sampleRate: Double
    private let channels: Int
    private let durationNs: Int64
    private let pace: Double
    private let chunkFrames: Int
    private let silenceAfterNs: Int64?
    private let frequency: Double
    private let delivery: SyntheticDelivery

    private let stopped = Mutex(false)
    private let sent = Mutex(SyntheticSentStats())
    private var task: Task<Void, Never>?

    public init(
        sampleRate: Double = 48_000, channels: Int = 1,
        durationNs: Int64, pace: Double = 0,
        chunkFrames: Int = 1024, silenceAfterNs: Int64? = nil,
        frequency: Double = 440,
        delivery: SyntheticDelivery = .steady
    ) {
        self.sampleRate = sampleRate
        self.channels = channels
        self.durationNs = durationNs
        self.pace = pace
        self.chunkFrames = chunkFrames
        self.silenceAfterNs = silenceAfterNs
        self.frequency = frequency
        self.delivery = delivery
    }

    /// Sample frames actually emitted plus first/last chunk timestamps.
    public func sentStats() -> SyntheticSentStats {
        sent.withLock { $0 }
    }

    public func start(_ handler: @escaping @Sendable (AudioChunk) -> Void) async throws {
        let totalFrames = Int(Double(durationNs) / 1_000_000_000 * sampleRate)
        let sampleRate = self.sampleRate
        let channels = self.channels
        let chunkFrames = self.chunkFrames
        let pace = self.pace
        let silenceAfterNs = self.silenceAfterNs
        let frequency = self.frequency
        let delivery = self.delivery
        task = Task.detached(priority: .userInitiated) { [weak self] in
            var frame = 0
            var rng = SplitMix64(seed: delivery.jitterSeed)
            var emittedAny = false
            let wallStart = DispatchTime.now().uptimeNanoseconds
            while frame < totalFrames {
                if Task.isCancelled { return }
                if let self, self.isStopped() { return }
                let frames = min(chunkFrames, totalFrames - frame)
                let nominalNs = Int64(Double(frame) / sampleRate * 1_000_000_000)
                if let silenceAfterNs, nominalNs >= silenceAfterNs { return }
                var jitterNs = rng.jitter(amplitudeNs: delivery.jitterAmplitudeNs)
                if delivery.inGap(nominalNs) {
                    // Delivery hole: nothing arrives; later chunks keep their
                    // true (later) timestamps and the sine phase continues.
                    frame += frames
                    continue
                }
                if !emittedAny { jitterNs = max(0, jitterNs) }
                let ptsNs = nominalNs + jitterNs
                var samples = [Float](repeating: 0, count: frames * channels)
                for i in 0..<frames {
                    let t = Double(frame + i) / sampleRate
                    let value = Float(sin(2 * .pi * frequency * t)) * 0.5
                    for c in 0..<channels {
                        samples[i * channels + c] = value
                    }
                }
                handler(AudioChunk(
                    samples: samples, frameCount: frames, channels: channels,
                    sampleRate: sampleRate, ptsNs: ptsNs))
                emittedAny = true
                self?.sent.withLock { stats in
                    stats.frames += frames
                    if stats.firstPtsNs == nil { stats.firstPtsNs = ptsNs }
                    stats.lastPtsNs = ptsNs
                }
                frame += frames
                if pace > 0 {
                    let targetWall = wallStart
                        + UInt64(Double(frame) / sampleRate * 1_000_000_000 / pace)
                    let now = DispatchTime.now().uptimeNanoseconds
                    if targetWall > now {
                        try? await Task.sleep(nanoseconds: targetWall - now)
                    }
                }
            }
        }
    }

    public func stop() async {
        stopped.withLock { $0 = true }
        task?.cancel()
        await task?.value
    }

    public func waitUntilFinished() async {
        await task?.value
    }

    private func isStopped() -> Bool {
        stopped.withLock { $0 }
    }
}

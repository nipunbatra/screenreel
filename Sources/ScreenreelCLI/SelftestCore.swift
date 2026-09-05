import AVFoundation
import CaptureCore
import CoreVideo
import Foundation
import ProjectModel
import Synchronization

/// Marker sources and the measurement core behind `screenreel selftest`
///:
/// a synthetic screen source flashes WHITE for a few consecutive frames at
/// known capture times, a synthetic mic beeps at the same times; both are
/// recorded through the REAL `CaptureSession` → segment-writer → container
/// pipeline, the finalized project is decoded back with AVFoundation, and
/// flash/beep onsets are paired to *measure* the end-to-end A/V offset and
/// drift the rest of the test suite can only bound structurally.
enum SyncSelftest {

    // MARK: - Plan

    /// Fixed capture shape: small frames keep encode/decode cheap without
    /// changing any timing behavior under test.
    static let width = 320
    static let height = 180
    static let fps: Double = 30
    static let sampleRate: Double = 48_000
    static let flashFrameCount = 3
    static let beepDurationNs: Int64 = 200_000_000
    static let beepFrequency: Double = 1_000
    static let offsetThresholdMs: Double = 40
    static let driftThresholdMsPerMinute: Double = 50

    /// Marker capture times: every 2 s starting at 1 s, kept clear of the
    /// session end so every beep completes inside the recording.
    static func markerTimesNs(durationNs: Int64) -> [Int64] {
        var times: [Int64] = []
        var t: Int64 = 1_000_000_000
        while t + beepDurationNs + 300_000_000 <= durationNs {
            times.append(t)
            t += 2_000_000_000
        }
        return times
    }

    // MARK: - Recording

    /// Record a flash/beep marker session through the real pipeline.
    /// Returns the marker times that were generated.
    @discardableResult
    static func record(
        projectURL: URL,
        durationNs: Int64,
        pace: Double,
        onWarning: @escaping @Sendable (String, String) -> Void = { _, _ in }
    ) async throws -> [Int64] {
        let markers = markerTimesNs(durationNs: durationNs)
        let configuration = CaptureConfiguration(
            widthPx: width, heightPx: height,
            nominalFrameRate: fps,
            videoCodec: .hevc, displayID: 1,
            microphoneEnabled: true,
            microphoneDeviceName: "Selftest Beep Microphone",
            audioSampleRate: sampleRate,
            segmentDurationSeconds: 4)
        let session = CaptureSession(
            projectURL: projectURL, configuration: configuration,
            callbacks: .init(onWarning: onWarning))
        let screen = FlashScreenSource(
            width: width, height: height, frameRate: fps,
            durationNs: durationNs, pace: pace,
            flashStartsNs: markers, flashFrameCount: flashFrameCount)
        let mic = BeepAudioSource(
            sampleRate: sampleRate, durationNs: durationNs, pace: pace,
            beepStartsNs: markers, beepDurationNs: beepDurationNs,
            frequency: beepFrequency)
        try await session.start(screen: screen, microphone: mic, systemAudio: nil)
        await screen.waitUntilFinished()
        await mic.waitUntilFinished()
        let summary = try await session.stop()
        guard summary.validation.isHealthy else {
            throw ScreenreelError.invariantViolated(
                "selftest recording did not validate: \(summary.validation.issues)")
        }
        return markers
    }

    // MARK: - Measurement

    struct PairDetail: Codable, Sendable {
        var flashMs: Double
        var beepMs: Double
        var offsetMs: Double
        var rejected: Bool
    }

    struct Report: Codable, Sendable {
        var projectPath: String
        var flashOnsets: Int
        var beepOnsets: Int
        var pairs: Int
        var outliersRejected: Int
        var medianOffsetMs: Double
        var driftMsPerMinute: Double
        var offsetThresholdMs: Double
        var driftThresholdMsPerMinute: Double
        var passed: Bool
        var pairDetails: [PairDetail]
    }

    /// Decode the finalized project, detect flash and beep onsets, pair
    /// them, and compute median offset (beep − flash, audio-late positive)
    /// plus a least-squares drift estimate with MAD outlier rejection.
    static func measure(projectAt projectURL: URL) async throws -> Report {
        let loaded = try ProjectPackage.load(at: projectURL)
        let layout = loaded.layout
        func segments(of type: TrackType) -> [SegmentDescriptor] {
            (loaded.manifest.tracks.first { $0.type == type }?.segments ?? [])
                .sorted { $0.sequenceInTrack < $1.sequenceInTrack }
        }
        let screenSegments = segments(of: .screen)
        let micSegments = segments(of: .microphone)
        guard !screenSegments.isEmpty, !micSegments.isEmpty else {
            throw ScreenreelError.invariantViolated(
                "selftest project needs committed screen and microphone segments "
                    + "(found \(screenSegments.count) screen, \(micSegments.count) mic)")
        }

        let flashOnsetsNs = try await detectFlashOnsets(
            segments: screenSegments, layout: layout)
        let beepOnsetsNs = try detectBeepOnsets(
            segments: micSegments, layout: layout)

        // Pair each flash with the nearest beep within half the marker gap.
        var pairs: [(flashNs: Int64, beepNs: Int64)] = []
        for flash in flashOnsetsNs {
            let candidate = beepOnsetsNs.min {
                abs($0 - flash) < abs($1 - flash)
            }
            if let beep = candidate, abs(beep - flash) < 500_000_000 {
                pairs.append((flash, beep))
            }
        }
        guard pairs.count >= 3 else {
            throw ScreenreelError.invariantViolated(
                "selftest needs at least 3 flash/beep pairs to measure sync; "
                    + "found \(flashOnsetsNs.count) flashes, \(beepOnsetsNs.count) beeps, "
                    + "\(pairs.count) pairs")
        }

        // Offsets in ms; MAD outlier rejection (>3× MAD, floored so a run of
        // near-identical offsets rejects nothing).
        let offsets = pairs.map { Double($0.beepNs - $0.flashNs) / 1e6 }
        let median = Self.median(offsets)
        let deviations = offsets.map { abs($0 - median) }
        let mad = max(Self.median(deviations), 2.0)
        var kept: [(timeMin: Double, offsetMs: Double)] = []
        var details: [PairDetail] = []
        var rejectedCount = 0
        for (index, pair) in pairs.enumerated() {
            let rejected = abs(offsets[index] - median) > 3 * mad
            if rejected {
                rejectedCount += 1
            } else {
                kept.append((Double(pair.flashNs) / 60e9, offsets[index]))
            }
            details.append(PairDetail(
                flashMs: Double(pair.flashNs) / 1e6,
                beepMs: Double(pair.beepNs) / 1e6,
                offsetMs: offsets[index],
                rejected: rejected))
        }

        let keptMedian = Self.median(kept.map(\.offsetMs))
        let drift = Self.leastSquaresSlope(kept)
        let passed = abs(keptMedian) < offsetThresholdMs
            && abs(drift) < driftThresholdMsPerMinute

        return Report(
            projectPath: projectURL.path,
            flashOnsets: flashOnsetsNs.count,
            beepOnsets: beepOnsetsNs.count,
            pairs: pairs.count,
            outliersRejected: rejectedCount,
            medianOffsetMs: keptMedian,
            driftMsPerMinute: drift,
            offsetThresholdMs: offsetThresholdMs,
            driftThresholdMsPerMinute: driftThresholdMsPerMinute,
            passed: passed,
            pairDetails: details)
    }

    // MARK: - Flash detection (mean-luma step)

    private static func detectFlashOnsets(
        segments: [SegmentDescriptor], layout: ProjectLayout
    ) async throws -> [Int64] {
        var onsets: [Int64] = []
        // Luma of the previous frame carries across segment boundaries so a
        // flash landing exactly on a boundary is still a detected step.
        var previousLuma: Double = 0
        for segment in segments {
            let url = try layout.resolve(relativePath: segment.path)
            let asset = AVURLAsset(
                url: url, options: [AVURLAssetPreferPreciseDurationAndTimingKey: true])
            guard let track = try await asset.loadTracks(withMediaType: .video).first else {
                throw ScreenreelError.invariantViolated("\(segment.path): no video track")
            }
            let reader = try AVAssetReader(asset: asset)
            let output = AVAssetReaderTrackOutput(track: track, outputSettings: [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA
            ])
            reader.add(output)
            guard reader.startReading() else {
                throw ScreenreelError.invariantViolated(
                    "\(segment.path): reader failed: \(reader.error.map { "\($0)" } ?? "unknown")")
            }
            var frames: [(ptsNs: Int64, luma: Double)] = []
            while let sample = output.copyNextSampleBuffer() {
                let pts = CMSampleBufferGetPresentationTimeStamp(sample)
                guard pts.isNumeric, let buffer = CMSampleBufferGetImageBuffer(sample) else {
                    continue
                }
                frames.append((Int64((pts.seconds * 1e9).rounded()), meanLuma(of: buffer)))
            }
            if reader.status == .failed {
                throw ScreenreelError.invariantViolated(
                    "\(segment.path): read failed: \(reader.error.map { "\($0)" } ?? "unknown")")
            }
            frames.sort { $0.ptsNs < $1.ptsNs }
            guard let firstPts = frames.first?.ptsNs else { continue }
            for frame in frames {
                let absoluteNs = frame.ptsNs - firstPts + segment.normalizedStartNs
                if frame.luma > 160, previousLuma < 64 {
                    onsets.append(absoluteNs)
                }
                previousLuma = frame.luma
            }
        }
        return onsets.sorted()
    }

    private static func meanLuma(of buffer: CVPixelBuffer) -> Double {
        CVPixelBufferLockBaseAddress(buffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
        guard let base = CVPixelBufferGetBaseAddress(buffer) else { return 0 }
        let width = CVPixelBufferGetWidth(buffer)
        let height = CVPixelBufferGetHeight(buffer)
        let bytesPerRow = CVPixelBufferGetBytesPerRow(buffer)
        let bytes = base.assumingMemoryBound(to: UInt8.self)
        var total = 0
        var count = 0
        // Subsampled grid: plenty for a full-frame black↔white step.
        for y in stride(from: 0, to: height, by: 8) {
            let row = y * bytesPerRow
            for x in stride(from: 0, to: width, by: 8) {
                let pixel = row + x * 4
                total += Int(bytes[pixel]) + Int(bytes[pixel + 1]) + Int(bytes[pixel + 2])
                count += 3
            }
        }
        return count > 0 ? Double(total) / Double(count) : 0
    }

    // MARK: - Beep detection (RMS gate with sample refinement)

    private static func detectBeepOnsets(
        segments: [SegmentDescriptor], layout: ProjectLayout
    ) throws -> [Int64] {
        var onsets: [Int64] = []
        for segment in segments {
            let url = try layout.resolve(relativePath: segment.path)
            let file = try AVAudioFile(forReading: url)
            let format = file.processingFormat
            let frameCount = AVAudioFrameCount(file.length)
            guard frameCount > 0,
                let pcm = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameCount)
            else { continue }
            try file.read(into: pcm)
            guard let channel = pcm.floatChannelData?[0] else { continue }
            let samples = UnsafeBufferPointer(start: channel, count: Int(pcm.frameLength))
            let rate = format.sampleRate

            let window = max(1, Int(rate * 0.010))
            let hop = max(1, Int(rate * 0.005))
            var quietBefore = true
            var index = 0
            while index + window <= samples.count {
                var energy: Double = 0
                for i in index..<(index + window) {
                    energy += Double(samples[i]) * Double(samples[i])
                }
                let rms = (energy / Double(window)).squareRoot()
                if rms > 0.2, quietBefore {
                    // Refine to the first loud sample inside the window.
                    var onsetFrame = index
                    for i in index..<(index + window) where abs(samples[i]) > 0.1 {
                        onsetFrame = i
                        break
                    }
                    onsets.append(
                        segment.normalizedStartNs
                            + Int64(Double(onsetFrame) / rate * 1e9))
                    quietBefore = false
                } else if rms < 0.05 {
                    quietBefore = true
                }
                index += hop
            }
        }
        return onsets.sorted()
    }

    // MARK: - Statistics

    static func median(_ values: [Double]) -> Double {
        guard !values.isEmpty else { return 0 }
        let sorted = values.sorted()
        let mid = sorted.count / 2
        return sorted.count.isMultiple(of: 2)
            ? (sorted[mid - 1] + sorted[mid]) / 2
            : sorted[mid]
    }

    /// Least-squares slope of offset (ms) over marker time (minutes):
    /// positive = audio falls progressively later.
    static func leastSquaresSlope(_ points: [(timeMin: Double, offsetMs: Double)]) -> Double {
        guard points.count >= 2 else { return 0 }
        let n = Double(points.count)
        let meanX = points.map(\.timeMin).reduce(0, +) / n
        let meanY = points.map(\.offsetMs).reduce(0, +) / n
        var numerator: Double = 0
        var denominator: Double = 0
        for point in points {
            numerator += (point.timeMin - meanX) * (point.offsetMs - meanY)
            denominator += (point.timeMin - meanX) * (point.timeMin - meanX)
        }
        guard denominator > 1e-9 else { return 0 }
        return numerator / denominator
    }
}

// MARK: - Marker sources

/// Screen source that renders full-frame BLACK except for `flashFrameCount`
/// consecutive WHITE frames starting at each flash time. Same pacing and
/// lifecycle contract as `SyntheticScreenSource`.
final class FlashScreenSource: ScreenFrameSource, @unchecked Sendable {
    private let width: Int
    private let height: Int
    private let frameRate: Double
    private let durationNs: Int64
    private let pace: Double
    private let flashStartsNs: [Int64]
    private let flashFrameCount: Int

    private let stopped = Mutex(false)
    private var task: Task<Void, Never>?

    init(
        width: Int, height: Int, frameRate: Double,
        durationNs: Int64, pace: Double,
        flashStartsNs: [Int64], flashFrameCount: Int
    ) {
        self.width = width
        self.height = height
        self.frameRate = frameRate
        self.durationNs = durationNs
        self.pace = pace
        self.flashStartsNs = flashStartsNs
        self.flashFrameCount = flashFrameCount
    }

    func start(_ handler: @escaping @Sendable (VideoFrame) -> Void) async throws {
        let frameCount = Int(Double(durationNs) / 1_000_000_000 * frameRate)
        let width = self.width
        let height = self.height
        let frameRate = self.frameRate
        let pace = self.pace
        let flashStarts = self.flashStartsNs
        let flashFrames = self.flashFrameCount
        task = Task.detached(priority: .userInitiated) { [weak self] in
            var pool: CVPixelBufferPool?
            let poolAttributes: [String: Any] = [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
                kCVPixelBufferWidthKey as String: width,
                kCVPixelBufferHeightKey as String: height,
            ]
            CVPixelBufferPoolCreate(nil, nil, poolAttributes as CFDictionary, &pool)
            guard let pool else { return }
            let flashSpanNs = Int64(Double(flashFrames) * 1_000_000_000 / frameRate)
            let wallStart = DispatchTime.now().uptimeNanoseconds
            for index in 0..<frameCount {
                if Task.isCancelled { return }
                if let self, self.isStopped() { return }
                let ptsNs = Int64(Double(index) * 1_000_000_000 / frameRate)
                var bufferOut: CVPixelBuffer?
                CVPixelBufferPoolCreatePixelBuffer(nil, pool, &bufferOut)
                guard let buffer = bufferOut else { continue }
                let white = flashStarts.contains {
                    ptsNs >= $0 && ptsNs < $0 + flashSpanNs
                }
                Self.fill(buffer, value: white ? 255 : 0, width: width, height: height)
                handler(VideoFrame(pixelBuffer: buffer, ptsNs: ptsNs))
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

    func stop() async {
        stopped.withLock { $0 = true }
        task?.cancel()
        await task?.value
    }

    func waitUntilFinished() async {
        await task?.value
    }

    private func isStopped() -> Bool {
        stopped.withLock { $0 }
    }

    private static func fill(_ buffer: CVPixelBuffer, value: Int32, width: Int, height: Int) {
        CVPixelBufferLockBaseAddress(buffer, [])
        defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
        guard let base = CVPixelBufferGetBaseAddress(buffer) else { return }
        let bytesPerRow = CVPixelBufferGetBytesPerRow(buffer)
        for y in 0..<height {
            memset(base.advanced(by: y * bytesPerRow), value, width * 4)
        }
    }
}

/// Mono mic source that is silent except for a fixed-length 1 kHz beep
/// starting at each marker time, sample-exact against the same nominal
/// timeline the flash source uses.
final class BeepAudioSource: AudioChunkSource, @unchecked Sendable {
    private let sampleRate: Double
    private let durationNs: Int64
    private let pace: Double
    private let chunkFrames: Int
    private let beepStartsNs: [Int64]
    private let beepDurationNs: Int64
    private let frequency: Double

    private let stopped = Mutex(false)
    private var task: Task<Void, Never>?

    init(
        sampleRate: Double, durationNs: Int64, pace: Double,
        beepStartsNs: [Int64], beepDurationNs: Int64,
        frequency: Double, chunkFrames: Int = 1024
    ) {
        self.sampleRate = sampleRate
        self.durationNs = durationNs
        self.pace = pace
        self.chunkFrames = chunkFrames
        self.beepStartsNs = beepStartsNs
        self.beepDurationNs = beepDurationNs
        self.frequency = frequency
    }

    func start(_ handler: @escaping @Sendable (AudioChunk) -> Void) async throws {
        let totalFrames = Int(Double(durationNs) / 1_000_000_000 * sampleRate)
        let sampleRate = self.sampleRate
        let chunkFrames = self.chunkFrames
        let pace = self.pace
        let frequency = self.frequency
        // Beep windows in sample frames for exact membership tests.
        let windows: [(start: Int, end: Int)] = beepStartsNs.map {
            (
                Int(Double($0) / 1e9 * sampleRate),
                Int(Double($0 + beepDurationNs) / 1e9 * sampleRate)
            )
        }
        task = Task.detached(priority: .userInitiated) { [weak self] in
            var frame = 0
            let wallStart = DispatchTime.now().uptimeNanoseconds
            while frame < totalFrames {
                if Task.isCancelled { return }
                if let self, self.isStopped() { return }
                let frames = min(chunkFrames, totalFrames - frame)
                let ptsNs = Int64(Double(frame) / sampleRate * 1_000_000_000)
                var samples = [Float](repeating: 0, count: frames)
                for i in 0..<frames {
                    let absolute = frame + i
                    let inBeep = windows.contains { absolute >= $0.start && absolute < $0.end }
                    if inBeep {
                        let t = Double(absolute) / sampleRate
                        samples[i] = Float(sin(2 * .pi * frequency * t)) * 0.8
                    }
                }
                handler(AudioChunk(
                    samples: samples, frameCount: frames, channels: 1,
                    sampleRate: sampleRate, ptsNs: ptsNs))
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

    func stop() async {
        stopped.withLock { $0 = true }
        task?.cancel()
        await task?.value
    }

    func waitUntilFinished() async {
        await task?.value
    }

    private func isStopped() -> Bool {
        stopped.withLock { $0 }
    }
}

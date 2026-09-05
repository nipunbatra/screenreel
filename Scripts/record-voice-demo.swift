// Actual ScreenCaptureKit window video with an explicitly controlled demo voice
// supplied to the microphone-track writer. Never accesses the physical microphone.
import AVFoundation
import CaptureCore
import Foundation
import ProjectModel

private actor DemoVoice: AudioChunkSource {
    let url: URL
    private var task: Task<Void, Never>?
    init(url: URL) { self.url = url }
    func start(_ handler: @escaping @Sendable (AudioChunk) -> Void) async throws {
        let file = try AVAudioFile(forReading: url, commonFormat: .pcmFormatFloat32, interleaved: false)
        precondition(file.processingFormat.sampleRate == 48_000 && file.processingFormat.channelCount == 1)
        task = Task {
            let clock = ContinuousClock()
            let start = clock.now
            while file.framePosition < file.length, !Task.isCancelled {
                let position = file.framePosition
                let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: 4800)!
                do { try file.read(into: buffer) } catch { break }
                let count = Int(buffer.frameLength)
                handler(AudioChunk(samples: Array(UnsafeBufferPointer(start: buffer.floatChannelData![0], count: count)),
                    frameCount: count, channels: 1, sampleRate: 48_000, ptsNs: position * 1_000_000_000 / 48_000))
                try? await clock.sleep(until: start.advanced(by: .nanoseconds(file.framePosition * 1_000_000_000 / 48_000)))
            }
        }
    }
    func wait() async { await task?.value }
    func stop() async { task?.cancel(); await task?.value }
}

@main struct RecordVoiceDemo {
    static func main() async throws {
        let windowID = UInt32(CommandLine.arguments[1])!
        let directory = URL(fileURLWithPath: CommandLine.arguments[2])
        let windows = try await SCKCapture.availableWindows()
        guard let window = windows.first(where: { $0.windowID == windowID && $0.title == "Wave Lab — Screen Reel demo" }) else {
            throw ScreenreelError.invariantViolated("Only the clean Wave Lab demo window may be recorded by this helper.")
        }
        var config = CaptureConfiguration(widthPx: window.widthPx, heightPx: window.heightPx,
            displayID: Int(window.displayID!), sourceKind: .window, windowID: windowID,
            microphoneEnabled: true, microphoneDeviceName: "Controlled demo: synthesized voice + seeded hiss")
        let session = CaptureSession(projectURL: directory.appendingPathComponent("Voice comparison.screenreel"), configuration: config)
        config.microphoneEnabled = false // SCK captures ONLY the real window, never a physical mic.
        let capture = SCKCapture(configuration: config, clock: session.sessionClock)
        let voice = DemoVoice(url: directory.appendingPathComponent("voice-noisy.wav"))
        try await session.start(screen: capture.screenSource(), microphone: voice, systemAudio: nil)
        await voice.wait()
        let summary = try await session.stop()
        print("Actual window video + labeled controlled voice: \(summary.videoFrames) frames, \(summary.droppedBuffers) drops, healthy=\(summary.validation.isHealthy)")
        guard summary.validation.isHealthy, summary.droppedBuffers == 0 else {
            throw ScreenreelError.invariantViolated("Demo recording failed validation")
        }
    }
}

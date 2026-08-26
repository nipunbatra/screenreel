import AVFoundation
import CaptureCore
import Foundation
import Observation

/// Live microphone level for the pre-record panel, so silent-mic surprises
/// are caught before a recording instead of after.
/// Runs only while the start view shows; recording itself uses the
/// ScreenCaptureKit microphone path, not this engine.
@Observable
@MainActor
final class MicLevelMonitor {
    /// Smoothed RMS level in 0...1.
    private(set) var level: Double = 0
    private(set) var active = false

    private var engine: AVAudioEngine?
    /// A grant arriving after stop() must not resurrect the engine while a
    /// recording owns the input device.
    private var wantsRunning = false

    func start() {
        guard !active else { return }
        wantsRunning = true
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized:
            attach()
        case .notDetermined:
            // @Sendable: the completion runs on an arbitrary queue (the
            // installTap crash mechanism).
            AVCaptureDevice.requestAccess(for: .audio) { @Sendable granted in
                Task { @MainActor [weak self] in
                    guard let self, granted, self.wantsRunning else { return }
                    self.attach()
                }
            }
        default:
            break
        }
    }

    func stop() {
        wantsRunning = false
        engine?.inputNode.removeTap(onBus: 0)
        engine?.stop()
        engine = nil
        active = false
        level = 0
    }

    private func attach() {
        guard engine == nil else { return }
        let engine = AVAudioEngine()
        let input = engine.inputNode
        let format = input.inputFormat(forBus: 0)
        guard format.sampleRate > 0, format.channelCount > 0 else { return }
        // The tap block runs on AVFAudio's RealtimeMessenger queue. It MUST
        // be @Sendable: a closure formed here without it inherits MainActor
        // isolation, and Swift 6's runtime executor check then crashes the
        // process (dispatch_assert_queue) the first time audio arrives.
        // No main-actor state is touched synchronously — the measured value
        // hops over in a MainActor task.
        input.installTap(onBus: 0, bufferSize: 2048, format: format) {
            @Sendable [weak self] buffer, _ in
            guard let data = buffer.floatChannelData?[0] else { return }
            let count = Int(buffer.frameLength)
            guard count > 0 else { return }
            let mapped = AudioLevel.meterValue(
                rms: AudioLevel.rms(data, count: count))
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.level = AudioLevel.smoothed(previous: self.level, next: mapped)
            }
        }
        do {
            try engine.start()
            self.engine = engine
            self.active = true
        } catch {
            input.removeTap(onBus: 0)
        }
    }
}

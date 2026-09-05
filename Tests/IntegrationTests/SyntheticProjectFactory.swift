import Foundation
import XCTest

@testable import CaptureCore
@testable import EventCapture
@testable import ProjectModel

/// Shared builder for complete synthetic projects (screen + mic + events).
enum SyntheticProjectFactory {
    static func make(
        in directory: URL,
        durationNs: Int64,
        width: Int = 320,
        height: Int = 180,
        withEvents: Bool = true,
        micSilenceAfterNs: Int64? = nil,
        pace: Double = 4
    ) async throws -> URL {
        let projectURL = directory.appendingPathComponent("p-\(UUID().uuidString).screenreel")
        let configuration = CaptureConfiguration(
            widthPx: width, heightPx: height, nominalFrameRate: 30,
            videoCodec: .hevc, displayID: 1,
            microphoneEnabled: true, microphoneDeviceName: "Synthetic Microphone",
            segmentDurationSeconds: 4)
        let session = CaptureSession(projectURL: projectURL, configuration: configuration)
        let screen = SyntheticScreenSource(
            width: width, height: height, frameRate: 30, durationNs: durationNs, pace: pace)
        let mic = SyntheticAudioSource(
            channels: 1, durationNs: durationNs, pace: pace,
            silenceAfterNs: micSilenceAfterNs)
        try await session.start(screen: screen, microphone: mic, systemAudio: nil)

        var pump: Task<Void, Never>?
        var events: SyntheticEventSource?
        if withEvents {
            let cursorTrackID = try await session.registerEventTrack(type: .cursorEvents)
            let clickTrackID = try await session.registerEventTrack(type: .clickEvents)
            let store = EventChunkStore(
                layout: session.projectLayout(),
                trackIDs: [.cursor: cursorTrackID, .clicks: clickTrackID],
                onCommit: { [session] chunk in
                    try await session.commitEventChunk(chunk)
                })
            let (stream, continuation) = AsyncStream.makeStream(of: EventRecord.self)
            let source = SyntheticEventSource(
                durationNs: durationNs, widthPx: Double(width), heightPx: Double(height),
                pace: pace)
            source.start { record in continuation.yield(record) }
            events = source
            pump = Task {
                for await record in stream {
                    try? await store.append(record)
                }
                try? await store.finish()
            }
            Task {
                await source.waitUntilFinished()
                continuation.finish()
            }
        }

        await screen.waitUntilFinished()
        await mic.waitUntilFinished()
        if let events { await events.waitUntilFinished() }
        await pump?.value
        _ = try await session.stop()
        return projectURL
    }
}

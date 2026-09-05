import AVFoundation
import Foundation
import XCTest
@testable import AudioPipeline
import ProjectModel
import TimelineCore

final class MusicAssetTests: XCTestCase {
    private func workspace() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }

    private func fixture(at url: URL, rate: Double = 44_100, seconds: Double = 0.3) throws {
        let format = AVAudioFormat(standardFormatWithSampleRate: rate, channels: 1)!
        let file = try AVAudioFile(forWriting: url, settings: format.settings)
        let count = AVAudioFrameCount(rate * seconds)
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: count)!
        buffer.frameLength = count
        for i in 0..<Int(count) { buffer.floatChannelData![0][i] = 0.4 * sin(Float(i) * 2 * .pi * 440 / Float(rate)) }
        try file.write(from: buffer)
    }

    func testImportResamplesPreservesOriginalAndSurvivesProjectMove() throws {
        let root = try workspace(), source = root.appendingPathComponent("song.caf")
        try fixture(at: source)
        let bytes = try Data(contentsOf: source)
        let layout = ProjectLayout(root: root.appendingPathComponent("project"))
        let track = try MusicAsset.importFile(source, into: layout)
        XCTAssertEqual(try Data(contentsOf: layout.resolve(relativePath: track.originalPath)), bytes)
        let file = try AVAudioFile(forReading: track.audioURL(in: layout))
        XCTAssertEqual(file.processingFormat.sampleRate, 48_000)
        XCTAssertEqual(file.processingFormat.channelCount, 2)
        XCTAssertEqual(Double(file.length), 14_400, accuracy: 2)
        let moved = ProjectLayout(root: root.appendingPathComponent("moved"))
        try FileManager.default.moveItem(at: layout.root, to: moved.root)
        XCTAssertNoThrow(try MusicReader(track: track, layout: moved))
        XCTAssertEqual(try Data(contentsOf: source), bytes)
    }

    func testLoopSeekGainAndNonLoopTail() throws {
        let root = try workspace(), source = root.appendingPathComponent("tone.caf")
        try fixture(at: source, rate: 48_000, seconds: 0.01)
        let layout = ProjectLayout(root: root.appendingPathComponent("project"))
        var track = try MusicAsset.importFile(source, into: layout)
        track.volume = 0.5
        let reader = try MusicReader(track: track, layout: layout)
        var first = [Float](repeating: 0, count: 1920)
        try reader.mix(into: &first, frames: 960, channels: 2, at: 0)
        XCTAssertEqual(Array(first[0..<960]), Array(first[960..<1920]))
        XCTAssertGreaterThan(first.map(abs).max()!, 0.19)
        XCTAssertLessThan(first.map(abs).max()!, 0.21)
        var seek = [Float](repeating: 0, count: 400)
        try reader.mix(into: &seek, frames: 200, channels: 2, at: 980)
        XCTAssertEqual(seek, Array(first[40..<440]))
        track.loops = false
        let noLoop = try MusicReader(track: track, layout: layout)
        var tail = [Float](repeating: 0, count: 1920)
        try noLoop.mix(into: &tail, frames: 960, channels: 2, at: 0)
        XCTAssertTrue(tail[960...].allSatisfy { $0 == 0 })
    }

    func testMuteAndInvalidPaths() throws {
        let root = try workspace(), source = root.appendingPathComponent("tone.caf")
        try fixture(at: source)
        let layout = ProjectLayout(root: root.appendingPathComponent("project"))
        var track = try MusicAsset.importFile(source, into: layout)
        track.volume = 0
        var buffer = [Float](repeating: 0.1, count: 1000)
        try MusicReader(track: track, layout: layout).mix(into: &buffer, frames: 500, channels: 2, at: 0)
        XCTAssertTrue(buffer.allSatisfy { $0 == 0.1 })
        for path in ["../tone.caf", "/tmp/tone.caf", "raw/screen/fake.caf"] {
            track.path = path
            XCTAssertThrowsError(try track.audioURL(in: layout))
        }
    }

    func testInvalidImportDoesNotLeaveAssets() throws {
        let root = try workspace(), source = root.appendingPathComponent("broken.mp3")
        try Data("not audio".utf8).write(to: source)
        let layout = ProjectLayout(root: root.appendingPathComponent("project"))
        XCTAssertThrowsError(try MusicAsset.importFile(source, into: layout))
        XCTAssertFalse(FileManager.default.fileExists(atPath: layout.root.path))
    }

    func testMusicEditsRoundTripAndLegacyDefault() throws {
        var edits = EditDocument()
        let legacy = try JSONEncoder().encode(edits)
        XCTAssertNil(try JSONDecoder().decode(EditDocument.self, from: legacy).music)
        edits.music = BackgroundMusic(path: "assets/music/test.caf", originalPath: "assets/music/test.wav", name: "Test", volume: 0.35, loops: false)
        XCTAssertEqual(try JSONDecoder().decode(EditDocument.self, from: JSONEncoder().encode(edits)), edits)
        XCTAssertEqual(edits.music?.sourceFrame(at: 110, length: 100), nil)
        edits.music?.loops = true
        XCTAssertEqual(edits.music?.sourceFrame(at: 110, length: 100), 10)
        edits.music?.volume = .infinity
        XCTAssertEqual(edits.music?.gain, 0)
    }
}

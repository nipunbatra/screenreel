import XCTest

@testable import ProjectModel

final class RobustnessTests: XCTestCase {
    private var directory: URL!

    override func setUp() {
        super.setUp()
        AtomicFile.fullFsync = false
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("aks-robustness-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: directory)
        AtomicFile.fullFsync = true
        super.tearDown()
    }

    // MARK: - Journal fuzzing

    func testJournalMutationSweepAlwaysReturnsReverifiedPrefix() async throws {
        let validURL = directory.appendingPathComponent("valid-journal.jsonl")
        let writer = try JournalWriter(creatingAt: validURL)
        for index in 0..<12 {
            try await writer.append(
                type: .fault,
                timeNs: Int64(index) * 17,
                payload: JournalPayload.fault(
                    kind: "seeded-fuzz", message: String(format: "payload-%02d-abcdef", index)),
                durable: false)
        }
        try await writer.synchronize()

        let valid = try Data(contentsOf: validURL)
        let lines = lineRanges(in: valid)
        XCTAssertEqual(lines.count, 12)
        let mutationURL = directory.appendingPathComponent("mutated-journal.jsonl")
        let trustedURL = directory.appendingPathComponent("trusted-prefix.jsonl")

        func assertTrusted(
            _ bytes: Data, expectedCount: Int? = nil, maximumCount: Int,
            _ label: String, file: StaticString = #filePath, line: UInt = #line
        ) throws {
            try bytes.write(to: mutationURL)
            let scan = try JournalReader.scan(url: mutationURL)
            XCTAssertLessThanOrEqual(
                scan.records.count, maximumCount,
                "\(label): scan trusted records past the first mutation", file: file, line: line)
            if let expectedCount {
                XCTAssertEqual(scan.records.count, expectedCount, label, file: file, line: line)
            }

            var previousHash = journalGenesisHash
            for (offset, record) in scan.records.enumerated() {
                XCTAssertEqual(record.sequence, UInt64(offset + 1), label, file: file, line: line)
                XCTAssertEqual(record.prevHash, previousHash, label, file: file, line: line)
                XCTAssertEqual(try record.computedHash(), record.hash, label, file: file, line: line)
                previousHash = record.hash
            }

            let trustedText = try scan.records.map { try $0.jsonlLine() }.joined(separator: "\n")
                + (scan.records.isEmpty ? "" : "\n")
            try Data(trustedText.utf8).write(to: trustedURL)
            let rescanned = try JournalReader.scan(url: trustedURL)
            XCTAssertNil(rescanned.truncationReason, label, file: file, line: line)
            XCTAssertEqual(rescanned.records, scan.records, label, file: file, line: line)
        }

        // Every complete-record boundary, including the empty and whole file.
        let boundaries = [0] + lines.map { $0.upperBound + 1 }
        for (count, boundary) in boundaries.enumerated() {
            try assertTrusted(
                Data(valid.prefix(boundary)), expectedCount: count, maximumCount: count,
                "boundary-\(count)")
        }

        // Three truncations inside every line. The fixed generator makes the
        // offsets deterministic while varying their exact positions.
        var generator = SplitMix64(seed: 0xA5A5_5A5A_DEAD_BEEF)
        for (lineIndex, range) in lines.enumerated() {
            let interior = max(1, range.count - 2)
            let seeded = range.lowerBound + 1 + generator.next(upperBound: interior)
            let offsets = Set([
                range.lowerBound + max(1, range.count / 4),
                range.lowerBound + max(1, range.count / 2),
                min(range.upperBound - 1, seeded),
            ])
            for offset in offsets.sorted() {
                try assertTrusted(
                    Data(valid.prefix(offset)), expectedCount: lineIndex, maximumCount: lineIndex,
                    "mid-line-\(lineIndex)-\(offset - range.lowerBound)")
            }
        }

        // Flip one deterministic byte in each semantic region of every line.
        for (lineIndex, range) in lines.enumerated() {
            let lineData = valid.subdata(in: range)
            let regions: [(String, Range<Int>)] = [
                ("header", try valueRange(after: "\"sequence\":", until: ",", in: lineData)),
                ("payload", try valueRange(after: "\"message\":\"", until: "\"", in: lineData)),
                ("hash", try valueRange(after: "\"hash\":\"", until: "\"", in: lineData)),
            ]
            for (name, region) in regions {
                var mutated = valid
                let localOffset = region.lowerBound + generator.next(upperBound: region.count)
                let absoluteOffset = range.lowerBound + localOffset
                mutated[absoluteOffset] ^= UInt8(1 << generator.next(upperBound: 5))
                try assertTrusted(
                    mutated, expectedCount: lineIndex, maximumCount: lineIndex,
                    "flip-\(name)-line-\(lineIndex)")
            }
        }

        // Duplicate each line in place. The original occurrence remains
        // trusted; the duplicate must stop the scan at its sequence gap.
        for (lineIndex, range) in lines.enumerated() {
            let recordWithNewline = valid.subdata(in: range.lowerBound..<(range.upperBound + 1))
            var mutated = valid
            mutated.insert(contentsOf: recordWithNewline, at: range.upperBound + 1)
            try assertTrusted(
                mutated, expectedCount: lineIndex + 1, maximumCount: lineIndex + 1,
                "duplicate-line-\(lineIndex)")
        }

        // Swap every adjacent pair. No record at or beyond the first swapped
        // line may enter the trusted prefix.
        for lineIndex in 0..<(lines.count - 1) {
            var records = lines.map { valid.subdata(in: $0.lowerBound..<$0.upperBound) }
            records.swapAt(lineIndex, lineIndex + 1)
            var mutated = Data()
            for record in records {
                mutated.append(record)
                mutated.append(0x0A)
            }
            try assertTrusted(
                mutated, expectedCount: lineIndex, maximumCount: lineIndex,
                "reorder-lines-\(lineIndex)-\(lineIndex + 1)")
        }
    }

    // MARK: - Recovery

    func testRecoveryIsIdempotentAndPreservesRawBytes() async throws {
        let originalURL = directory.appendingPathComponent("crashed.aks")
        try await TestProject.build(at: originalURL, finalize: false)
        let originalRaw = try rawAssets(in: originalURL)

        let firstURL = directory.appendingPathComponent("RECOVERED-1.aks")
        _ = try await Recovery.recover(
            projectAt: originalURL, options: RecoveryOptions(destination: firstURL))
        let secondURL = directory.appendingPathComponent("RECOVERED-2.aks")
        _ = try await Recovery.recover(
            projectAt: firstURL, options: RecoveryOptions(destination: secondURL))

        for recoveredURL in [firstURL, secondURL] {
            let report = await Validator().validate(projectAt: recoveredURL)
            XCTAssertTrue(report.isHealthy, "\(recoveredURL.lastPathComponent): \(report.issues)")
            XCTAssertEqual(try rawAssets(in: recoveredURL), originalRaw)
        }
    }

    func testRecoverySucceedsWhenEventsDirectoryIsMissing() async throws {
        let originalURL = directory.appendingPathComponent("no-events.aks")
        let built = try await TestProject.build(at: originalURL, finalize: false)
        try FileManager.default.removeItem(at: built.layout.eventsDirectory)

        let recoveredURL = directory.appendingPathComponent("no-events-recovered.aks")
        let recovery = try await Recovery.recover(
            projectAt: originalURL, options: RecoveryOptions(destination: recoveredURL))
        XCTAssertEqual(recovery.recoveredChunks, 0)
        XCTAssertTrue(recovery.rejectedAssets.contains("events/cursor-000001.jsonl"))

        let validation = await Validator().validate(projectAt: recoveredURL)
        XCTAssertTrue(validation.isHealthy, "\(validation.issues)")
    }

    func testRecoverySkipsCorruptNewestHistoryAndUsesValidOlderManifest() async throws {
        let originalURL = directory.appendingPathComponent("history.aks")
        let built = try await TestProject.build(at: originalURL, finalize: false)
        let original = try ProjectPackage.load(at: originalURL).manifest
        let history = try FileManager.default.contentsOfDirectory(
            at: built.layout.historyDirectory, includingPropertiesForKeys: nil)
            .filter { $0.lastPathComponent.hasPrefix("manifest-") }
            .sorted { generation(of: $0) < generation(of: $1) }
        XCTAssertGreaterThanOrEqual(history.count, 2)

        try Data("{\"corrupt\":true}".utf8).write(to: history.last!)
        try Data("torn main manifest".utf8).write(to: built.layout.manifestURL)

        let recoveredURL = directory.appendingPathComponent("history-recovered.aks")
        let recovery = try await Recovery.recover(
            projectAt: originalURL, options: RecoveryOptions(destination: recoveredURL))
        let recovered = try ProjectPackage.load(at: recoveredURL)
        XCTAssertEqual(recovered.manifest.projectID, original.projectID)
        XCTAssertEqual(recovered.manifest.clock, original.clock)
        XCTAssertTrue(recovery.issues.contains { $0.code == "manifest.recoveredFromHistory" })

        let validation = await Validator().validate(projectAt: recoveredURL)
        XCTAssertTrue(validation.isHealthy, "\(validation.issues)")
    }

    // MARK: - Validator hostile inputs

    func testValidatorTurnsValidJSONWithWrongTypesIntoErrorReport() async throws {
        let projectURL = directory.appendingPathComponent("wrong-types.aks")
        let built = try await TestProject.build(at: projectURL)
        let wrongTypes = #"{"format":"in.aks.project","schemaVersion":"1","projectID":7,"tracks":{},"generation":false}"#
        try Data(wrongTypes.utf8).write(to: built.layout.manifestURL)

        let report = await Validator().validate(projectAt: projectURL)
        XCTAssertFalse(report.isHealthy)
        XCTAssertTrue(report.issues.contains {
            $0.severity == .error && $0.code == "project.unreadable"
        }, "\(report.issues)")
    }

    func testValidatorRejectsDuplicateTraversalAndExtremeByteSizesWithoutEscapingPackage() async throws {
        let projectURL = directory.appendingPathComponent("hostile.aks")
        let built = try await TestProject.build(at: projectURL, finalize: false)
        var manifest = try ProjectPackage.load(at: projectURL).manifest
        let screenIndex = try XCTUnwrap(manifest.tracks.firstIndex { $0.id == built.screenTrackID })
        let screenTrack = manifest.tracks[screenIndex]
        let journal = try JournalWriter(resumingAt: built.layout.journalURL)

        let outsideSentinel = directory.appendingPathComponent("outside-sentinel")
        let sentinelData = Data("must remain untouched".utf8)
        try sentinelData.write(to: outsideSentinel)
        let sentinelDate = try XCTUnwrap(
            FileManager.default.attributesOfItem(atPath: outsideSentinel.path)[.modificationDate]
                as? Date)

        // Duplicate a real committed path across two manifest tracks.
        let originalSegment = try XCTUnwrap(screenTrack.segments?.first)
        var duplicateTrack = TrackDescriptor(type: .screen, displayID: 2)
        var duplicateSegment = originalSegment
        duplicateSegment.trackID = duplicateTrack.id
        duplicateTrack.segments = [duplicateSegment]
        manifest.tracks.append(duplicateTrack)

        // Journal hostile traversal paths so the validator exercises its
        // resolver, not merely manifest indexing.
        for (offset, path) in ["..%2foutside-sentinel", "raw/../../outside-sentinel"].enumerated() {
            var descriptor = SegmentDescriptor(
                trackID: screenTrack.id, trackType: .screen,
                path: path, sequenceInTrack: 80 + offset,
                container: .mov, codec: .hevc,
                sourceStartNs: 0, sourceEndNs: 1,
                normalizedStartNs: 0, normalizedEndNs: 1,
                byteSize: 1, sha256: String(repeating: "a", count: 64),
                commitSequence: 0)
            descriptor.commitSequence = await journal.lastCommittedSequence + 1
            try await journal.append(
                type: .segmentCommitted, timeNs: 1,
                payload: JournalPayload.segmentCommitted(descriptor), durable: false)
            manifest.appendSegment(descriptor)
        }

        // Real in-package files paired with impossible descriptor sizes.
        for (sequence, claimedSize) in [(90, Int64(0)), (91, Int64.max)] {
            let fileURL = built.layout.screenDirectory.appendingPathComponent(
                ProjectLayout.segmentFileName(type: .screen, displayID: 1, sequence: sequence))
            let bytes = Data("hostile-size-\(sequence)".utf8)
            try bytes.write(to: fileURL)
            var descriptor = SegmentDescriptor(
                trackID: screenTrack.id, trackType: .screen,
                path: built.layout.relativePath(of: fileURL), sequenceInTrack: sequence,
                container: .mov, codec: .hevc,
                sourceStartNs: 0, sourceEndNs: 1,
                normalizedStartNs: 0, normalizedEndNs: 1,
                byteSize: claimedSize, sha256: Hashing.sha256Hex(bytes),
                commitSequence: 0)
            descriptor.commitSequence = await journal.lastCommittedSequence + 1
            try await journal.append(
                type: .segmentCommitted, timeNs: 1,
                payload: JournalPayload.segmentCommitted(descriptor), durable: false)
            manifest.appendSegment(descriptor)
        }
        try await journal.synchronize()
        try AtomicFile.writeJSON(manifest, to: built.layout.manifestURL)

        let report = await Validator().validate(projectAt: projectURL)
        XCTAssertFalse(report.isHealthy)
        XCTAssertTrue(report.issues.contains { $0.code == "manifest.duplicateAssetPath" }, "\(report.issues)")
        for hostilePath in ["..%2foutside-sentinel", "raw/../../outside-sentinel"] {
            XCTAssertTrue(report.issues.contains {
                $0.code == "manifest.unsafePath" && $0.message.contains(hostilePath)
            }, "missing unsafe-path issue for \(hostilePath): \(report.issues)")
        }
        for sequence in [90, 91] {
            let path = "raw/screen/display-1-\(String(format: "%06d", sequence)).mov"
            XCTAssertTrue(report.issues.contains {
                $0.code == "segment.sizeMismatch" && $0.path == path
            }, "missing size issue for \(path): \(report.issues)")
        }
        XCTAssertEqual(try Data(contentsOf: outsideSentinel), sentinelData)
        XCTAssertEqual(
            try FileManager.default.attributesOfItem(atPath: outsideSentinel.path)[.modificationDate]
                as? Date,
            sentinelDate)
    }

    func testValidatorRejectsBackwardSequenceInsideCorrectlyCountedEventChunk() async throws {
        let projectURL = directory.appendingPathComponent("backward-events.aks")
        let built = try await TestProject.build(at: projectURL, finalize: false)
        var manifest = try ProjectPackage.load(at: projectURL).manifest
        let eventTrack = try XCTUnwrap(manifest.tracks.first { $0.type == .cursorEvents })

        let records = [
            EventRecord(
                sequence: 100, timeNs: 10, type: .cursorMove,
                displayID: 1, xPx: 1, yPx: 1, cursorID: "arrow", buttons: 0),
            EventRecord(
                sequence: 101, timeNs: 11, type: .cursorMove,
                displayID: 1, xPx: 2, yPx: 1, cursorID: "arrow", buttons: 0),
            EventRecord(
                sequence: 99, timeNs: 12, type: .cursorMove,
                displayID: 1, xPx: 3, yPx: 1, cursorID: "arrow", buttons: 0),
        ]
        let text = try records.map { try $0.jsonlLine() }.joined(separator: "\n") + "\n"
        let bytes = Data(text.utf8)
        let chunkURL = built.layout.eventsDirectory.appendingPathComponent("cursor-000002.jsonl")
        try bytes.write(to: chunkURL)

        let journal = try JournalWriter(resumingAt: built.layout.journalURL)
        var descriptor = EventChunkDescriptor(
            trackID: eventTrack.id, kind: .cursor,
            path: built.layout.relativePath(of: chunkURL), sequenceInTrack: 2,
            firstEventSequence: 100, lastEventSequence: 99,
            startNs: 10, endNs: 12, recordCount: 3,
            byteSize: Int64(bytes.count), sha256: Hashing.sha256Hex(bytes),
            commitSequence: 0)
        descriptor.commitSequence = await journal.lastCommittedSequence + 1
        try await journal.append(
            type: .eventChunkCommitted, timeNs: 12,
            payload: JournalPayload.eventChunkCommitted(descriptor), durable: false)
        try await journal.synchronize()
        manifest.appendEventChunk(descriptor)
        try AtomicFile.writeJSON(manifest, to: built.layout.manifestURL)

        let report = await Validator().validate(projectAt: projectURL)
        XCTAssertTrue(report.issues.contains {
            $0.severity == .error && $0.code == "chunk.sequenceNotMonotonic"
        }, "\(report.issues)")
    }

    // MARK: - Helpers

    private func lineRanges(in data: Data) -> [Range<Int>] {
        var ranges: [Range<Int>] = []
        var start = 0
        for offset in data.indices where data[offset] == 0x0A {
            ranges.append(start..<offset)
            start = offset + 1
        }
        if start < data.count { ranges.append(start..<data.count) }
        return ranges
    }

    private func valueRange(after prefix: String, until suffix: String, in data: Data) throws -> Range<Int> {
        let prefixData = Data(prefix.utf8)
        let suffixData = Data(suffix.utf8)
        let prefixRange = try XCTUnwrap(data.range(of: prefixData))
        let valueStart = prefixRange.upperBound
        let suffixRange = try XCTUnwrap(data.range(of: suffixData, in: valueStart..<data.endIndex))
        return valueStart..<suffixRange.lowerBound
    }

    private func rawAssets(in projectURL: URL) throws -> [String: Data] {
        let layout = ProjectLayout(root: projectURL)
        guard let enumerator = FileManager.default.enumerator(
            at: layout.rawDirectory,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles])
        else { return [:] }
        var assets: [String: Data] = [:]
        for case let fileURL as URL in enumerator {
            let values = try fileURL.resourceValues(forKeys: [.isRegularFileKey])
            if values.isRegularFile == true {
                assets[layout.relativePath(of: fileURL)] = try Data(contentsOf: fileURL)
            }
        }
        return assets
    }

    private func generation(of url: URL) -> Int {
        Int(url.deletingPathExtension().lastPathComponent.dropFirst("manifest-".count)) ?? 0
    }
}

private struct SplitMix64 {
    private var state: UInt64

    init(seed: UInt64) {
        state = seed
    }

    mutating func next(upperBound: Int) -> Int {
        precondition(upperBound > 0)
        state &+= 0x9E37_79B9_7F4A_7C15
        var value = state
        value = (value ^ (value >> 30)) &* 0xBF58_476D_1CE4_E5B9
        value = (value ^ (value >> 27)) &* 0x94D0_49BB_1331_11EB
        value ^= value >> 31
        return Int(value % UInt64(upperBound))
    }
}

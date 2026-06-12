@preconcurrency import AVFoundation
import Foundation
import Testing
@testable import StorageKit

// MARK: - RecoveryServiceTests

@Suite(
    "RecoveryService tests",
    .serialized,
    .disabled(
        if: ProcessInfo.processInfo.environment["CI"] == "true",
        "Uses AVMutableComposition + AVAssetExportSession to concat .m4a segments — crashes with SIGSEGV on headless macos-15 GH Actions runners. Local Apple Silicon runs only."
    )
)
struct RecoveryServiceTests {

    // MARK: - Helpers

    private func makeRecordingsRoot() throws -> URL {
        let dir = URL.temporaryDirectory.appendingPathComponent("KosmoNotesRecoveryTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private func cleanup(_ dir: URL) {
        try? FileManager.default.removeItem(at: dir)
    }

    /// Create a session directory with N synthetic .m4a segments inside `<root>/<sid>/segments/`.
    /// Each segment contains `framesPerSegment` frames of a sine wave at 48 kHz mono.
    /// Returns the session directory URL.
    @discardableResult
    private func makeSessionWithSegments(
        root: URL,
        sid: String,
        segmentCount: Int,
        framesPerSegment: AVAudioFrameCount = 48_000  // 1 second
    ) async throws -> URL {
        let sessionDir = root.appendingPathComponent(sid)
        let segmentsDir = sessionDir.appendingPathComponent("segments")
        try FileManager.default.createDirectory(at: segmentsDir, withIntermediateDirectories: true)

        for i in 0..<segmentCount {
            let segmentURL = segmentsDir.appendingPathComponent("\(i).m4a")
            try await writeSyntheticM4A(to: segmentURL, frames: framesPerSegment)
        }

        return sessionDir
    }

    /// Write a synthetic mono AAC .m4a file containing `frames` frames of a 440 Hz sine wave.
    private func writeSyntheticM4A(to outputURL: URL, frames: AVAudioFrameCount, sampleRate: Double = 48_000) async throws {
        let writer = try AVAssetWriter(outputURL: outputURL, fileType: .m4a)
        let aacSettings: [String: Any] = [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: sampleRate,
            AVNumberOfChannelsKey: 1,
            AVEncoderBitRateKey: 96_000,
        ]
        let input = AVAssetWriterInput(mediaType: .audio, outputSettings: aacSettings)
        input.expectsMediaDataInRealTime = false
        writer.add(input)
        writer.startWriting()
        writer.startSession(atSourceTime: .zero)

        // Feed the audio in 4800-frame chunks (100 ms each).
        let chunkSize: AVAudioFrameCount = 4800
        var sampleOffset: Int64 = 0
        var remaining = Int(frames)

        while remaining > 0 {
            let n = AVAudioFrameCount(min(remaining, Int(chunkSize)))
            guard let pcm = makeSineBuffer(frameCount: n, sampleRate: sampleRate) else {
                break
            }
            guard let sb = pcm.toCMSampleBuffer(sampleOffset: sampleOffset, sampleRate: sampleRate) else {
                break
            }
            while !input.isReadyForMoreMediaData {
                try? await Task.sleep(nanoseconds: 1_000_000)
            }
            input.append(sb)
            sampleOffset += Int64(n)
            remaining -= Int(n)
        }

        input.markAsFinished()
        await writer.finishWriting()

        guard writer.status == .completed else {
            throw NSError(
                domain: "RecoveryServiceTests",
                code: writer.status.rawValue,
                userInfo: [NSLocalizedDescriptionKey: writer.error?.localizedDescription ?? "writer failed"]
            )
        }
    }

    private func makeSineBuffer(frameCount: AVAudioFrameCount, sampleRate: Double) -> AVAudioPCMBuffer? {
        guard let format = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: sampleRate,
            channels: 1,
            interleaved: false
        ) else { return nil }
        guard let buf = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameCount) else { return nil }
        buf.frameLength = frameCount
        guard let data = buf.floatChannelData?[0] else { return nil }
        for i in 0..<Int(frameCount) {
            data[i] = Float(sin(2.0 * Double.pi * 440.0 * Double(i) / sampleRate))
        }
        return buf
    }

    // MARK: - Scan tests

    @Test("scanForOrphans on missing root returns empty")
    func scanMissingRootIsEmpty() throws {
        let root = URL.temporaryDirectory.appendingPathComponent("does-not-exist-\(UUID().uuidString)")
        let svc = RecoveryService()
        let orphans = try svc.scanForOrphans(rootDir: root)
        #expect(orphans.isEmpty)
    }

    @Test("scanForOrphans on empty root returns empty")
    func scanEmptyRootIsEmpty() async throws {
        let root = try makeRecordingsRoot()
        defer { cleanup(root) }

        let svc = RecoveryService()
        let orphans = try svc.scanForOrphans(rootDir: root)
        #expect(orphans.isEmpty)
    }

    @Test("scanForOrphans skips sessions with finalized audio.m4a")
    func scanSkipsFinalizedSessions() async throws {
        let root = try makeRecordingsRoot()
        defer { cleanup(root) }

        let sessionDir = try await makeSessionWithSegments(root: root, sid: "abc", segmentCount: 2)
        // Pretend this session was finalized: write an audio.m4a placeholder.
        let audio = sessionDir.appendingPathComponent("audio.m4a")
        try Data().write(to: audio)

        let svc = RecoveryService()
        let orphans = try svc.scanForOrphans(rootDir: root)
        #expect(orphans.isEmpty)
    }

    @Test("scanForOrphans skips sessions with no segments dir")
    func scanSkipsSessionsWithoutSegments() async throws {
        let root = try makeRecordingsRoot()
        defer { cleanup(root) }

        let sessionDir = root.appendingPathComponent("ghost")
        try FileManager.default.createDirectory(at: sessionDir, withIntermediateDirectories: true)

        let svc = RecoveryService()
        let orphans = try svc.scanForOrphans(rootDir: root)
        #expect(orphans.isEmpty)
    }

    @Test("scanForOrphans returns sessions with segments and no audio.m4a, sorted by sid")
    func scanReturnsOrphansSortedById() async throws {
        let root = try makeRecordingsRoot()
        defer { cleanup(root) }

        // Create two orphans, plus one finalized session that should be skipped.
        try await makeSessionWithSegments(root: root, sid: "session-z", segmentCount: 1)
        try await makeSessionWithSegments(root: root, sid: "session-a", segmentCount: 2)

        let finalizedSession = try await makeSessionWithSegments(root: root, sid: "session-m", segmentCount: 1)
        try Data().write(to: finalizedSession.appendingPathComponent("audio.m4a"))

        let svc = RecoveryService()
        let orphans = try svc.scanForOrphans(rootDir: root)

        #expect(orphans.count == 2)
        #expect(orphans.map(\.id) == ["session-a", "session-z"])
        #expect(orphans.first { $0.id == "session-a" }?.segmentURLs.count == 2)
    }

    @Test("scanForOrphans skips caller-declared active sessions")
    func scanSkipsActiveSessionIDs() throws {
        let root = try makeRecordingsRoot()
        defer { cleanup(root) }

        for sid in ["active", "interrupted"] {
            let segmentsDir = root
                .appendingPathComponent(sid)
                .appendingPathComponent("segments")
            try FileManager.default.createDirectory(at: segmentsDir, withIntermediateDirectories: true)
            try Data([0]).write(to: segmentsDir.appendingPathComponent("0.m4a"))
        }

        let svc = RecoveryService()
        let orphans = try svc.scanForOrphans(rootDir: root, activeSessionIDs: ["active"])
        #expect(orphans.map(\.id) == ["interrupted"])
    }

    @Test("scanForOrphans sorts segment URLs numerically (10.m4a after 9.m4a)")
    func scanSortsSegmentsNumerically() async throws {
        let root = try makeRecordingsRoot()
        defer { cleanup(root) }

        // Create 11 segments named 0.m4a..10.m4a.
        try await makeSessionWithSegments(root: root, sid: "many", segmentCount: 11, framesPerSegment: 4800)

        let svc = RecoveryService()
        let orphans = try svc.scanForOrphans(rootDir: root)
        #expect(orphans.count == 1)

        let names = orphans[0].segmentURLs.map { $0.deletingPathExtension().lastPathComponent }
        #expect(names == ["0", "1", "2", "3", "4", "5", "6", "7", "8", "9", "10"])
    }

    // MARK: - Finalize tests

    @Test("finalize produces audio.m4a from 3 segments with combined duration")
    func finalizeConcatenatesSegments() async throws {
        let root = try makeRecordingsRoot()
        defer { cleanup(root) }

        // 3 segments × 1 second each = 3 seconds total.
        let sessionDir = try await makeSessionWithSegments(
            root: root,
            sid: "concat-test",
            segmentCount: 3,
            framesPerSegment: 48_000
        )

        let svc = RecoveryService()
        let orphans = try svc.scanForOrphans(rootDir: root)
        #expect(orphans.count == 1)

        let outputURL = try await svc.finalize(orphans[0])

        // AVAssetExportSession resolves symlinks (/var → /private/var on macOS), so
        // compare by resolved path rather than raw URL equality.
        let expectedPath = sessionDir.appendingPathComponent("audio.m4a").resolvingSymlinksInPath().path
        #expect(outputURL.resolvingSymlinksInPath().path == expectedPath)
        #expect(FileManager.default.fileExists(atPath: outputURL.path))

        // Verify the output is decodable and has duration ≈ 3 s.
        let asset = AVURLAsset(url: outputURL)
        let duration = try await asset.load(.duration)
        let seconds = CMTimeGetSeconds(duration)
        #expect(seconds >= 2.5 && seconds <= 3.5, "Expected ~3s duration, got \(seconds)s")

        let tracks = try await asset.loadTracks(withMediaType: .audio)
        #expect(tracks.count >= 1)
    }

    @Test("finalize throws if audio.m4a already exists")
    func finalizeThrowsIfFinalizedFileExists() async throws {
        let root = try makeRecordingsRoot()
        defer { cleanup(root) }

        let sessionDir = try await makeSessionWithSegments(root: root, sid: "already-done", segmentCount: 1)
        try Data().write(to: sessionDir.appendingPathComponent("audio.m4a"))

        let svc = RecoveryService()
        let segmentURL = sessionDir.appendingPathComponent("segments/0.m4a")
        let orphan = RecoveryService.OrphanSession(
            id: "already-done",
            sessionDir: sessionDir,
            segmentURLs: [segmentURL]
        )

        await #expect(throws: RecoveryService.RecoveryError.self) {
            try await svc.finalize(orphan)
        }
    }

    @Test("finalize throws for empty segment list")
    func finalizeThrowsForEmptySegments() async throws {
        let root = try makeRecordingsRoot()
        defer { cleanup(root) }

        let sessionDir = root.appendingPathComponent("empty")
        try FileManager.default.createDirectory(at: sessionDir, withIntermediateDirectories: true)

        let svc = RecoveryService()
        let orphan = RecoveryService.OrphanSession(
            id: "empty",
            sessionDir: sessionDir,
            segmentURLs: []
        )
        await #expect(throws: RecoveryService.RecoveryError.self) {
            try await svc.finalize(orphan)
        }
    }

    @Test("finalize round-trip: scan → finalize removes session from subsequent scans")
    func finalizeRemovesFromSubsequentScans() async throws {
        let root = try makeRecordingsRoot()
        defer { cleanup(root) }

        try await makeSessionWithSegments(root: root, sid: "round-trip", segmentCount: 2, framesPerSegment: 48_000)

        let svc = RecoveryService()
        var orphans = try svc.scanForOrphans(rootDir: root)
        #expect(orphans.count == 1)

        _ = try await svc.finalize(orphans[0])

        orphans = try svc.scanForOrphans(rootDir: root)
        #expect(orphans.isEmpty)
    }
}

// MARK: - Local CMSampleBuffer conversion helper
//
// The test fixture builder needs to convert AVAudioPCMBuffer → CMSampleBuffer
// to feed AVAssetWriter. CaptureKit has a public extension for this, but
// StorageKitTests only depends on StorageKit. Inlining a minimal version here
// keeps the dependency graph clean.

private extension AVAudioPCMBuffer {
    func toCMSampleBuffer(sampleOffset: Int64, sampleRate: Double) -> CMSampleBuffer? {
        guard let channelData = self.floatChannelData else { return nil }
        let frameCount = Int(self.frameLength)
        guard frameCount > 0 else { return nil }

        var asbd = AudioStreamBasicDescription(
            mSampleRate: sampleRate,
            mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked | kAudioFormatFlagIsNonInterleaved,
            mBytesPerPacket: 4,
            mFramesPerPacket: 1,
            mBytesPerFrame: 4,
            mChannelsPerFrame: 1,
            mBitsPerChannel: 32,
            mReserved: 0
        )

        var formatDesc: CMAudioFormatDescription?
        guard CMAudioFormatDescriptionCreate(
            allocator: kCFAllocatorDefault,
            asbd: &asbd,
            layoutSize: 0,
            layout: nil,
            magicCookieSize: 0,
            magicCookie: nil,
            extensions: nil,
            formatDescriptionOut: &formatDesc
        ) == noErr, let formatDescription = formatDesc else { return nil }

        let dataSize = frameCount * 4
        var blockBuffer: CMBlockBuffer?
        guard CMBlockBufferCreateWithMemoryBlock(
            allocator: kCFAllocatorDefault,
            memoryBlock: nil,
            blockLength: dataSize,
            blockAllocator: kCFAllocatorDefault,
            customBlockSource: nil,
            offsetToData: 0,
            dataLength: dataSize,
            flags: 0,
            blockBufferOut: &blockBuffer
        ) == noErr, let block = blockBuffer else { return nil }

        let copyStatus = channelData[0].withMemoryRebound(to: UInt8.self, capacity: dataSize) { srcPtr in
            CMBlockBufferReplaceDataBytes(
                with: srcPtr,
                blockBuffer: block,
                offsetIntoDestination: 0,
                dataLength: dataSize
            )
        }
        guard copyStatus == noErr else { return nil }

        let pts = CMTime(value: sampleOffset, timescale: CMTimeScale(sampleRate))
        var sampleBuffer: CMSampleBuffer?
        guard CMAudioSampleBufferCreateReadyWithPacketDescriptions(
            allocator: kCFAllocatorDefault,
            dataBuffer: block,
            formatDescription: formatDescription,
            sampleCount: frameCount,
            presentationTimeStamp: pts,
            packetDescriptions: nil,
            sampleBufferOut: &sampleBuffer
        ) == noErr else { return nil }

        return sampleBuffer
    }
}

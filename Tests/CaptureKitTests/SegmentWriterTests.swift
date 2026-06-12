@preconcurrency import AVFoundation
import Foundation
import Testing
@testable import CaptureKit

@Suite(
    "SegmentWriter tests",
    .serialized,
    .disabled(
        if: ProcessInfo.processInfo.environment["CI"] == "true",
        "AVAssetWriter crashes the swift-testing process with SIGSEGV on headless macos-15 GH Actions runners. Tests pass locally on Apple Silicon — coverage comes from local runs + manual smoke."
    )
)
struct SegmentWriterTests {

    // MARK: - Helpers

    private func makeTempDir() throws -> URL {
        let dir = URL.temporaryDirectory.appendingPathComponent("KosmoNotesTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private func cleanup(_ dir: URL) {
        try? FileManager.default.removeItem(at: dir)
    }

    // MARK: - Tests

    @Test("SegmentWriter creates segments directory on init")
    func createsSegmentsDir() throws {
        let sessionDir = try makeTempDir()
        defer { cleanup(sessionDir) }

        _ = try SegmentWriter(sessionDir: sessionDir, segmentDurationSeconds: 5.0)

        let segDir = sessionDir.appendingPathComponent("segments")
        #expect(FileManager.default.fileExists(atPath: segDir.path))
    }

    @Test("12 seconds of mic audio produces 3 segments (5+5+2)")
    func twelveSecondsProducesThreeSegments() async throws {
        let sessionDir = try makeTempDir()
        defer { cleanup(sessionDir) }

        let writer = try SegmentWriter(sessionDir: sessionDir, segmentDurationSeconds: 5.0, sampleRate: 48_000)

        // 12 seconds = 576_000 frames at 48 kHz
        // Feed 4800-frame buffers (100 ms each) × 120 = 12 s
        let framesPerBuffer: AVAudioFrameCount = 4800
        let totalBuffers = 120  // 12 s worth

        for _ in 0..<totalBuffers {
            guard let buf = AVAudioPCMBuffer.sineWave(frameCount: framesPerBuffer) else { continue }
            try await writer.append(buf, source: .mic)
        }

        let paths = try await writer.close()

        // Expect exactly 3 segments
        #expect(paths.count == 3, "Expected 3 segments, got \(paths.count): \(paths.map(\.lastPathComponent))")
    }

    @Test("Each segment file is a decodable .m4a with at least one audio track")
    func segmentsAreDecodable() async throws {
        let sessionDir = try makeTempDir()
        defer { cleanup(sessionDir) }

        let writer = try SegmentWriter(sessionDir: sessionDir, segmentDurationSeconds: 5.0, sampleRate: 48_000)

        // Feed 12 seconds of audio
        let framesPerBuffer: AVAudioFrameCount = 4800
        for _ in 0..<120 {
            guard let buf = AVAudioPCMBuffer.sineWave(frameCount: framesPerBuffer) else { continue }
            try await writer.append(buf, source: .mic)
        }

        let paths = try await writer.close()
        #expect(!paths.isEmpty)

        for path in paths {
            #expect(FileManager.default.fileExists(atPath: path.path), "Segment missing: \(path.lastPathComponent)")

            // Verify audio track count via AVAsset
            let asset = AVAsset(url: path)
            let tracks = try await asset.loadTracks(withMediaType: .audio)
            #expect(tracks.count >= 1, "Segment \(path.lastPathComponent) has no audio tracks")
        }
    }

    @Test("close() on a fresh writer with no appended buffers returns empty")
    func closeWithNoBuffersReturnsEmpty() async throws {
        let sessionDir = try makeTempDir()
        defer { cleanup(sessionDir) }

        let writer = try SegmentWriter(sessionDir: sessionDir)
        let paths = try await writer.close()
        #expect(paths.isEmpty)
    }

    @Test("append after close does not reopen a segment")
    func appendAfterCloseIsIgnored() async throws {
        let sessionDir = try makeTempDir()
        defer { cleanup(sessionDir) }

        let writer = try SegmentWriter(sessionDir: sessionDir, segmentDurationSeconds: 5.0, sampleRate: 48_000)
        guard let buffer = AVAudioPCMBuffer.sineWave(frameCount: 4800) else {
            Issue.record("Failed to build test audio buffer")
            return
        }

        try await writer.append(buffer, source: .mic)
        let paths = try await writer.close()
        #expect(paths.count == 1)

        try await writer.append(buffer, source: .mic)
        let pathsAfterLateAppend = try await writer.close()
        #expect(pathsAfterLateAppend == paths)

        let segDir = sessionDir.appendingPathComponent("segments")
        let m4aFiles = try FileManager.default.contentsOfDirectory(atPath: segDir.path)
            .filter { $0.hasSuffix(".m4a") }
        #expect(m4aFiles.count == paths.count)
    }

    @Test("Segments directory contains expected number of .m4a files")
    func segmentsDirContainsM4AFiles() async throws {
        let sessionDir = try makeTempDir()
        defer { cleanup(sessionDir) }

        let writer = try SegmentWriter(sessionDir: sessionDir, segmentDurationSeconds: 5.0, sampleRate: 48_000)

        // 11 seconds → 3 segments: [0–5), [5–10), [10–11)
        // 11 s = 528_000 frames = 110 × 4800-frame buffers
        for _ in 0..<110 {
            guard let buf = AVAudioPCMBuffer.sineWave(frameCount: 4800) else { continue }
            try await writer.append(buf, source: .mic)
        }

        let paths = try await writer.close()

        let segDir = sessionDir.appendingPathComponent("segments")
        let files = try FileManager.default.contentsOfDirectory(atPath: segDir.path)
        let m4aFiles = files.filter { $0.hasSuffix(".m4a") }

        #expect(m4aFiles.count == paths.count)
        #expect(paths.count >= 2)
    }

    @Test("2-track segment: appending mic and system buffers creates valid file")
    func twoTrackSegment() async throws {
        let sessionDir = try makeTempDir()
        defer { cleanup(sessionDir) }

        let writer = try SegmentWriter(sessionDir: sessionDir, segmentDurationSeconds: 5.0, sampleRate: 48_000)

        // Feed 6 seconds of interleaved mic + system audio (2 × 3 s)
        for i in 0..<60 {
            guard let buf = AVAudioPCMBuffer.sineWave(frameCount: 4800) else { continue }
            let source: AudioSource = i.isMultiple(of: 2) ? .mic : .system
            try await writer.append(buf, source: source)
        }

        let paths = try await writer.close()
        #expect(!paths.isEmpty)

        // Verify at least one segment was created
        for path in paths {
            #expect(FileManager.default.fileExists(atPath: path.path))
        }
    }
}

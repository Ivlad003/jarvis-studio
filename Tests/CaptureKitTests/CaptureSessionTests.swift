@preconcurrency import AVFoundation
import Foundation
import Testing
@testable import CaptureKit

// MARK: - CaptureSession tests
//
// These tests exercise CaptureSession with micEnabled=true, systemAudioEnabled=false
// (system audio requires Screen Recording TCC which CI runners don't have).
//
// The tests feed synthetic PCM buffers to a MockAudioEngine and verify that
// segment files are written to the expected directory structure.

@Suite(
    "CaptureSession tests (mic-only, no TCC required)",
    .serialized,
    .disabled(
        if: ProcessInfo.processInfo.environment["CI"] == "true",
        "Spins up SegmentWriter / AVAssetWriter; same SIGSEGV story as the SegmentWriter suite. Local Apple Silicon runs only."
    )
)
struct CaptureSessionTests {
    private enum TestStartupError: Error {
        case micBootstrap
        case tier2MicBootstrap
    }

    private func makeTempDir() throws -> URL {
        let dir = URL.temporaryDirectory.appendingPathComponent("KosmoNotesSessionTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private func cleanup(_ dir: URL) {
        try? FileManager.default.removeItem(at: dir)
    }

    // MARK: - Config tests (no real capture needed)

    @Test("CaptureSession.Config stores values correctly")
    func configStoresValues() throws {
        let dir = try makeTempDir()
        defer { cleanup(dir) }

        let config = CaptureSession.Config(
            micEnabled: true,
            systemAudioEnabled: false,
            sessionDir: dir,
            segmentDurationSeconds: 3.0
        )

        #expect(config.micEnabled == true)
        #expect(config.systemAudioEnabled == false)
        #expect(config.echoCancellationEnabled == false)
        #expect(config.sessionDir == dir)
        #expect(config.segmentDurationSeconds == 3.0)
    }

    @Test("CaptureSession.Config default values")
    func configDefaults() throws {
        let dir = try makeTempDir()
        defer { cleanup(dir) }

        let config = CaptureSession.Config(sessionDir: dir)
        #expect(config.micEnabled == true)
        #expect(config.systemAudioEnabled == false)
        #expect(config.echoCancellationEnabled == false)
        #expect(config.segmentDurationSeconds == 5.0)
    }

    @Test("CaptureSession builds mic AudioEngine config from configured sample rate")
    func micAudioEngineConfigUsesConfiguredSampleRate() throws {
        let dir = try makeTempDir()
        defer { cleanup(dir) }

        let config = CaptureSession.Config(
            micEnabled: true,
            systemAudioEnabled: false,
            sessionDir: dir,
            audioSampleRate: 24_000
        )

        let engineConfig = CaptureSession.micAudioEngineConfig(for: config)
        #expect(engineConfig.sampleRate == 24_000)
        #expect(engineConfig.channels == 1)
        #expect(engineConfig.voiceProcessing == false)
    }

    @Test("CaptureSession forwards echo cancellation to mic AudioEngine config")
    func micAudioEngineConfigUsesEchoCancellationFlag() throws {
        let dir = try makeTempDir()
        defer { cleanup(dir) }

        let config = CaptureSession.Config(
            micEnabled: true,
            systemAudioEnabled: true,
            echoCancellationEnabled: true,
            sessionDir: dir
        )

        let engineConfig = CaptureSession.micAudioEngineConfig(for: config)
        #expect(engineConfig.voiceProcessing == true)
    }

    // MARK: - Direct SegmentWriter-based integration (feeds synthetic buffers)

    @Test("start → feed synthetic buffers via SegmentWriter → stop returns segment paths")
    func startFeedStop() async throws {
        let sessionDir = try makeTempDir()
        defer { cleanup(sessionDir) }

        // Directly exercise SegmentWriter (the core of CaptureSession) with synthetic audio
        let writer = try SegmentWriter(
            sessionDir: sessionDir,
            segmentDurationSeconds: 2.0,
            sampleRate: 48_000
        )

        // Feed 5 seconds of audio → expect 3 segments: [0–2), [2–4), [4–5)
        // 5 s = 240_000 frames = 50 × 4800-frame buffers
        for _ in 0..<50 {
            guard let buf = AVAudioPCMBuffer.sineWave(frameCount: 4800) else { continue }
            try await writer.append(buf, source: .mic)
        }

        let paths = try await writer.close()

        #expect(paths.count >= 2, "Expected ≥2 segments for 5 s with 2 s segments, got \(paths.count)")
        for path in paths {
            #expect(FileManager.default.fileExists(atPath: path.path))
        }
    }

    @Test("Pause finalizes current segment")
    func pauseFinalizesSegment() async throws {
        let sessionDir = try makeTempDir()
        defer { cleanup(sessionDir) }

        // Simulate pause: write some audio, close (= pause finalize), then write more
        let writer1 = try SegmentWriter(
            sessionDir: sessionDir,
            segmentDurationSeconds: 5.0,
            sampleRate: 48_000
        )

        // Feed 3 seconds (less than 5 s segment) then close — simulates pause
        for _ in 0..<30 {
            guard let buf = AVAudioPCMBuffer.sineWave(frameCount: 4800) else { continue }
            try await writer1.append(buf, source: .mic)
        }
        let paths1 = try await writer1.close()
        #expect(paths1.count == 1, "Expected 1 segment before pause, got \(paths1.count)")

        // Simulate resume: new writer, feed 3 more seconds
        let writer2 = try SegmentWriter(
            sessionDir: sessionDir,
            segmentDurationSeconds: 5.0,
            sampleRate: 48_000
        )
        for _ in 0..<30 {
            guard let buf = AVAudioPCMBuffer.sineWave(frameCount: 4800) else { continue }
            try await writer2.append(buf, source: .mic)
        }
        let paths2 = try await writer2.close()
        #expect(paths2.count == 1, "Expected 1 segment after resume, got \(paths2.count)")

        // Total: 2 segments
        let segDir = sessionDir.appendingPathComponent("segments")
        let files = (try? FileManager.default.contentsOfDirectory(atPath: segDir.path)) ?? []
        let m4aFiles = files.filter { $0.hasSuffix(".m4a") }
        #expect(m4aFiles.count == 2)
    }

    @Test("CaptureSession stop without start returns empty paths")
    func stopWithoutStartReturnsEmpty() async throws {
        let sessionDir = try makeTempDir()
        defer { cleanup(sessionDir) }

        let config = CaptureSession.Config(
            micEnabled: false,
            systemAudioEnabled: false,
            sessionDir: sessionDir
        )
        let session = CaptureSession(config: config)
        let paths = try await session.stop()
        #expect(paths.isEmpty)
    }

    @Test("CaptureSession start with micEnabled=false systemAudioEnabled=false creates no capture tasks")
    func startWithBothDisabled() async throws {
        let sessionDir = try makeTempDir()
        defer { cleanup(sessionDir) }

        let config = CaptureSession.Config(
            micEnabled: false,
            systemAudioEnabled: false,
            sessionDir: sessionDir
        )
        let session = CaptureSession(config: config)

        // Should not throw — just creates segment writer with no active feeds
        try await session.start()
        let paths = try await session.stop()

        // No buffers fed, so no completed segments
        #expect(paths.isEmpty)
    }

    @Test("CaptureSession failed mic bootstrap tears down partial start resources")
    func failedMicBootstrapTearsDownPartialStartResources() async throws {
        let sessionDir = try makeTempDir()
        defer { cleanup(sessionDir) }

        let config = CaptureSession.Config(
            micEnabled: true,
            systemAudioEnabled: false,
            sessionDir: sessionDir
        )
        let session = CaptureSession(
            config: config,
            liveSink: nil,
            testMicStartupError: TestStartupError.micBootstrap
        )

        do {
            try await session.start()
            Issue.record("Expected start() to throw the injected mic bootstrap error")
        } catch TestStartupError.micBootstrap {
            // Expected path.
        } catch {
            Issue.record("Expected TestStartupError.micBootstrap, got \(error)")
        }

        let hasResources = await session.hasAllocatedCaptureResourcesForTesting
        #expect(hasResources == false)
        let activeMicSource = await session.activeMicSource
        #expect(activeMicSource == .none)

        let paths = try await session.stop()
        #expect(paths.isEmpty)
    }

    @Test("AudioSource enum values are correct")
    func audioSourceValues() {
        let mic: AudioSource = .mic
        let system: AudioSource = .system
        // Enum identity check
        if case .mic = mic { } else {
            Issue.record("Expected .mic")
        }
        if case .system = system { } else {
            Issue.record("Expected .system")
        }
    }

    // MARK: - Live PCM sink tests

    @Test("CaptureSession forwards PCM buffers to LivePCMSink during capture")
    func livePCMSinkReceivesBuffers() async throws {
        let sessionDir = try makeTempDir()
        defer { cleanup(sessionDir) }

        let sink = TestPCMSink()
        
        // Create a test mic stream
        let (stream, continuation) = AsyncStream<AVAudioPCMBuffer>.makeStream()
        
        // Create a session with the test sink and mock stream
        let config = CaptureSession.Config(
            micEnabled: true,
            systemAudioEnabled: false,
            sessionDir: sessionDir,
            segmentDurationSeconds: 5.0
        )
        let session = CaptureSession(config: config, liveSink: sink, testMicStream: stream)
        
        // Start the session (uses test stream instead of real mic)
        try await session.start()
        
        // Feed 3 buffers through the test stream
        for _ in 0..<3 {
            guard let buf = AVAudioPCMBuffer.sineWave(frameCount: 4800) else {
                Issue.record("Failed to create sine wave buffer")
                continue
            }
            continuation.yield(buf)
        }
        
        // Give the feed task a moment to process
        try await Task.sleep(for: .milliseconds(100))
        
        // Verify sink received all buffers
        let count = await sink.count()
        #expect(count == 3, "Expected sink to receive 3 buffers, got \(count)")
        
        // Verify host times are non-zero
        let buffers = await sink.receivedBuffers
        for (index, recorded) in buffers.enumerated() {
            #expect(recorded.hostTime > 0, "Buffer \(index) has zero host time")
            #expect(recorded.frameLength == 4800, "Buffer \(index) has wrong frameLength: \(recorded.frameLength)")
        }
        
        // Clean stop
        continuation.finish()
        _ = try await session.stop()
    }

    @Test("CaptureSession does not await live sink inline")
    func livePCMSinkDeliveryIsNonblocking() async throws {
        let sessionDir = try makeTempDir()
        defer { cleanup(sessionDir) }

        let sink = BlockingTestPCMSink(delay: .milliseconds(250))
        let (stream, continuation) = AsyncStream<AVAudioPCMBuffer>.makeStream()

        let config = CaptureSession.Config(
            micEnabled: true,
            systemAudioEnabled: false,
            sessionDir: sessionDir,
            segmentDurationSeconds: 5.0
        )
        let session = CaptureSession(config: config, liveSink: sink, testMicStream: stream)

        try await session.start()

        for _ in 0..<3 {
            guard let buf = AVAudioPCMBuffer.sineWave(frameCount: 4800) else {
                Issue.record("Failed to create sine wave buffer")
                continue
            }
            continuation.yield(buf)
        }

        try await Task.sleep(for: .milliseconds(100))

        #expect(sink.startedCount() >= 1, "Expected at least 1 sink delivery to start without blocking capture")
        #expect(sink.finishedCount() <= 2, "Expected serial delivery (at most 2 complete due to timing)")

        continuation.finish()
        _ = try await session.stop()
    }

    @Test("CaptureSession delivers buffers in order to live sink")
    func livePCMSinkOrderedDelivery() async throws {
        let sessionDir = try makeTempDir()
        defer { cleanup(sessionDir) }

        let sink = BlockingTestPCMSink(delay: .milliseconds(10))
        let (stream, continuation) = AsyncStream<AVAudioPCMBuffer>.makeStream()

        let config = CaptureSession.Config(
            micEnabled: true,
            systemAudioEnabled: false,
            sessionDir: sessionDir,
            segmentDurationSeconds: 5.0
        )
        let session = CaptureSession(config: config, liveSink: sink, testMicStream: stream)

        try await session.start()

        // Feed 5 buffers quickly
        for _ in 0..<5 {
            guard let buf = AVAudioPCMBuffer.sineWave(frameCount: 4800) else {
                Issue.record("Failed to create sine wave buffer")
                continue
            }
            continuation.yield(buf)
        }

        // Give feed task time to enqueue all buffers before finishing
        try await Task.sleep(for: .milliseconds(100))

        continuation.finish()
        _ = try await session.stop()

        // After stop completes, all deliveries should be done
        let order = sink.receivedOrder()
        #expect(order.count == 5, "Expected sink to receive all 5 buffers, got \(order.count)")

        // Verify ordering: each hostTime should be >= previous
        for i in 1..<order.count {
            #expect(order[i] >= order[i-1], "Buffer \(i) out of order: \(order[i]) < \(order[i-1])")
        }
    }

    @Test("CaptureSession stop() drains pending live sink deliveries")
    func stopDrainsPendingDeliveries() async throws {
        let sessionDir = try makeTempDir()
        defer { cleanup(sessionDir) }

        let sink = BlockingTestPCMSink(delay: .milliseconds(50))
        let (stream, continuation) = AsyncStream<AVAudioPCMBuffer>.makeStream()

        let config = CaptureSession.Config(
            micEnabled: true,
            systemAudioEnabled: false,
            sessionDir: sessionDir,
            segmentDurationSeconds: 5.0
        )
        let session = CaptureSession(config: config, liveSink: sink, testMicStream: stream)

        try await session.start()

        // Feed 10 buffers quickly
        for _ in 0..<10 {
            guard let buf = AVAudioPCMBuffer.sineWave(frameCount: 4800) else {
                Issue.record("Failed to create sine wave buffer")
                continue
            }
            continuation.yield(buf)
        }

        // Give feed task time to enqueue all buffers
        try await Task.sleep(for: .milliseconds(100))

        continuation.finish()
        
        // stop() should drain all pending deliveries before returning
        _ = try await session.stop()

        // After stop completes, all 10 buffers should be delivered
        let order = sink.receivedOrder()
        #expect(order.count == 10, "Expected sink to receive all 10 buffers after stop(), got \(order.count)")
    }

    @Test("LiveSinkDelivery keeps newest buffers when queue is full")
    func liveDeliveryKeepsNewestWhenFull() async throws {
        let sessionDir = try makeTempDir()
        defer { cleanup(sessionDir) }

        let sink = TaggedIndexPCMSink(delay: .milliseconds(100))
        let (stream, continuation) = AsyncStream<AVAudioPCMBuffer>.makeStream()

        let config = CaptureSession.Config(
            micEnabled: true,
            systemAudioEnabled: false,
            sessionDir: sessionDir,
            segmentDurationSeconds: 5.0
        )
        let session = CaptureSession(config: config, liveSink: sink, testMicStream: stream)

        try await session.start()

        // Feed 50 buffers rapidly to exceed the default queue size (32)
        for index in 0..<50 {
            guard let buf = AVAudioPCMBuffer.taggedIndex(index, frameCount: 4800) else {
                Issue.record("Failed to create tagged buffer")
                continue
            }
            continuation.yield(buf)
        }

        // Give the mic feed loop time to enqueue the burst before stopping.
        try await Task.sleep(for: .milliseconds(200))

        continuation.finish()
        _ = try await session.stop()

        let indices = await sink.receivedIndices
        #expect(indices.count <= 33, "Expected 1 in-flight delivery plus at most 32 queued buffers, got \(indices.count)")
        #expect(indices.count > 0, "Expected at least some buffers to be delivered")
        #expect(indices.count < 50, "Expected some older pending buffers to be dropped, got \(indices)")
        #expect(indices.last == 49, "Expected newest buffer to survive queue pressure")
        if indices.count > 1 {
            #expect(indices[1] > 0, "Expected oldest pending buffers to be dropped, got \(indices)")
        }

        if indices.count > 1 {
            for i in 1..<indices.count {
                #expect(indices[i] > indices[i - 1], "Tagged indices should stay in ascending order")
            }
        }
    }

    // MARK: - MicHealth surface

    @Test("CaptureSession.micHealth starts in .idle before recording begins")
    func micHealthStartsIdle() async throws {
        let dir = try makeTempDir()
        defer { cleanup(dir) }
        let config = CaptureSession.Config(
            micEnabled: true,
            systemAudioEnabled: false,
            sessionDir: dir
        )
        let session = CaptureSession(config: config)
        let health = await session.micHealth
        #expect(health == .idle, "Expected .idle before start, got \(health)")
    }

    @Test("MicHealth equality covers associated-value reasons")
    func micHealthEquatable() {
        #expect(MicHealth.idle == .idle)
        #expect(MicHealth.ok != .idle)
        #expect(MicHealth.degraded(reason: "x") == .degraded(reason: "x"))
        #expect(MicHealth.degraded(reason: "x") != .degraded(reason: "y"))
        #expect(MicHealth.dead(reason: "x") != .degraded(reason: "x"))
    }

    // MARK: - MicHealthClassifier (deterministic state machine)

    @Test("Classifier reports muted regardless of stall")
    func classifierMuted() {
        let s = MicHealthSnapshot(
            isMuted: true,
            everDelivered: true,
            sinceLastBuffer: 100,
            sinceStart: 200
        )
        #expect(MicHealthClassifier.classify(s) == .muted)
    }

    @Test("Classifier reports warmingUp before first delivery within grace")
    func classifierWarmupGrace() {
        let s = MicHealthSnapshot(
            isMuted: false,
            everDelivered: false,
            sinceLastBuffer: 4,
            sinceStart: 4
        )
        #expect(MicHealthClassifier.classify(s) == .warmingUp)
    }

    @Test("Classifier reports ok when buffers are recent")
    func classifierOk() {
        let s = MicHealthSnapshot(
            isMuted: false,
            everDelivered: true,
            sinceLastBuffer: 0.5,
            sinceStart: 10
        )
        #expect(MicHealthClassifier.classify(s) == .ok)
    }

    @Test("Classifier transitions to degraded at 5 s of stall")
    func classifierDegradedAt5s() {
        let s = MicHealthSnapshot(
            isMuted: false,
            everDelivered: true,
            sinceLastBuffer: 5.0,
            sinceStart: 30
        )
        switch MicHealthClassifier.classify(s) {
        case .degraded: break
        default: Issue.record("Expected .degraded at 5s stall")
        }
    }

    @Test("Classifier transitions to dead at 30 s of stall")
    func classifierDeadAt30s() {
        let s = MicHealthSnapshot(
            isMuted: false,
            everDelivered: true,
            sinceLastBuffer: 30.0,
            sinceStart: 60
        )
        switch MicHealthClassifier.classify(s) {
        case .dead: break
        default: Issue.record("Expected .dead at 30s stall — fail-safe trigger threshold")
        }
    }

    @Test("Classifier reports dead immediately when tier-2 also failed")
    func classifierTier2Dead() {
        let s = MicHealthSnapshot(
            isMuted: false,
            everDelivered: true,
            sinceLastBuffer: 2,
            sinceStart: 60,
            scStreamRecoveryGaveUp: true,
            tier2Attempted: true
        )
        switch MicHealthClassifier.classify(s) {
        case .dead(let reason):
            #expect(reason.contains("tier-2"), "Tier-2 failure should be reflected in the dead reason; got: \(reason)")
        default:
            Issue.record("Expected .dead when both SCStream recovery and tier-2 failed")
        }
    }

    @Test("Classifier never re-enters warmingUp after first delivery")
    func classifierNoReWarmup() {
        let s = MicHealthSnapshot(
            isMuted: false,
            everDelivered: true,
            sinceLastBuffer: 2,
            sinceStart: 2
        )
        #expect(MicHealthClassifier.classify(s) == .ok)
    }

    // MARK: - Deterministic invariants (mic source graph + pause/resume)

    @Test("CaptureSession with test mic stream reports activeMicSource == .scStream while recording")
    func activeMicSourceIsScStreamWithTestStream() async throws {
        let sessionDir = try makeTempDir()
        defer { cleanup(sessionDir) }

        let (stream, continuation) = AsyncStream<AVAudioPCMBuffer>.makeStream()
        let config = CaptureSession.Config(
            micEnabled: true,
            systemAudioEnabled: false,
            sessionDir: sessionDir,
            segmentDurationSeconds: 5.0
        )
        let session = CaptureSession(config: config, liveSink: nil, testMicStream: stream)

        let pre = await session.activeMicSource
        #expect(pre == .none, "Before start, mic source must be .none")

        try await session.start()
        let during = await session.activeMicSource
        #expect(during == .scStream, "Test-stream path mirrors the SCStream-mic path; start must flip the enum to .scStream so RecorderState skips MicLevelMeter")

        continuation.finish()
        _ = try await session.stop()

        let post = await session.activeMicSource
        #expect(post == .none, "After stop, mic source must reset to .none")
    }

    @Test("CaptureSession SCStream-mode pause+resume keeps the mic feed task alive")
    func scStreamModePauseResumeKeepsMicFeedAlive() async throws {
        let sessionDir = try makeTempDir()
        defer { cleanup(sessionDir) }

        let sink = TestPCMSink()
        let (stream, continuation) = AsyncStream<AVAudioPCMBuffer>.makeStream()
        let config = CaptureSession.Config(
            micEnabled: true,
            systemAudioEnabled: false,
            sessionDir: sessionDir,
            segmentDurationSeconds: 5.0
        )
        let session = CaptureSession(config: config, liveSink: sink, testMicStream: stream)

        try await session.start()

        // Pause immediately — before any audio is fed. We're proving the
        // SCStream feed task survives pause/resume; the pre-pause writer's
        // segments are out of scope.
        try await session.pause()
        let pausedSource = await session.activeMicSource
        #expect(pausedSource == .scStream, "pause() must leave activeMicSource == .scStream so resume() can rebrand without recreating the iterator")

        try await session.resume()
        let resumedSource = await session.activeMicSource
        #expect(resumedSource == .scStream, "resume() must keep the mic source enum on .scStream")

        // Feed three buffers AFTER resume. If pause() were to cancel the
        // mic task (AsyncStream cannot be re-iterated), no buffer would
        // reach the live sink — count would stay at 0.
        for _ in 0..<3 {
            if let buf = AVAudioPCMBuffer.sineWave(frameCount: 4800) {
                continuation.yield(buf)
            }
        }
        try await Task.sleep(for: .milliseconds(150))

        let count = await sink.count()
        #expect(count == 3, "After pause+resume the live sink must still receive buffers from the surviving SCStream mic feed task; got \(count).")

        continuation.finish()
        _ = try await session.stop()

        let postStop = await session.activeMicSource
        #expect(postStop == .none, "stop() must reset activeMicSource to .none")
    }

    @Test("Tier-2 fallback preserves requested mute and marks mic dead when bootstrap fails")
    func tier2FallbackPreservesMuteAndMarksDeadWhenBootstrapFails() async throws {
        let sessionDir = try makeTempDir()
        defer { cleanup(sessionDir) }

        let (stream, continuation) = AsyncStream<AVAudioPCMBuffer>.makeStream()
        let config = CaptureSession.Config(
            micEnabled: true,
            systemAudioEnabled: false,
            sessionDir: sessionDir,
            segmentDurationSeconds: 5.0
        )
        let session = CaptureSession(
            config: config,
            liveSink: nil,
            testMicStream: stream,
            testTier2MicStartupError: TestStartupError.tier2MicBootstrap
        )

        try await session.start()
        await session.setMicMuted(true)

        await session.forceTier2FallbackForTesting(stallSeconds: 6)

        #expect(await session.requestedMicMutedForTesting == true)
        #expect(await session.tier2MicBootstrapFailedForTesting == true)
        #expect(await session.activeMicSource == .none)
        switch await session.micHealth {
        case .dead(let reason):
            #expect(reason.contains("tier-2"))
        default:
            let health = await session.micHealth
            Issue.record("Expected .dead after failed tier-2 bootstrap, got \(String(describing: health))")
        }

        continuation.finish()
        _ = try await session.stop()
    }

    // MARK: - ScreenRecorder restart failure surfaces the give-up flag

    @Test("Classifier marks .dead when tier-2 attempted but SCStream recovery is exhausted")
    func classifierDeadWhenTier2ExhaustedAndSCStreamRecoveryFailed() {
        // Emulates the post-failed-restart state described by audit issue #4:
        // ScreenRecorder.restartSCStreamForMicRecovery returned failure, the
        // tick set micRecoveryGaveUp=true, and CaptureSession's supervisor
        // already attempted tier-2 (also failed). The classifier MUST collapse
        // to .dead, not .degraded — otherwise the fail-safe stop never fires.
        let snap = MicHealthSnapshot(
            isMuted: false,
            everDelivered: true,
            sinceLastBuffer: 2,
            sinceStart: 60,
            scStreamRecoveryGaveUp: true,
            tier2Attempted: true
        )
        switch MicHealthClassifier.classify(snap) {
        case .dead:
            break
        default:
            Issue.record("Expected .dead when scStreamRecoveryGaveUp == true and tier-2 already attempted; got \(MicHealthClassifier.classify(snap)).")
        }
    }

    // MARK: - 30s fail-safe budget (classifier emits .dead exactly at 30 s)

    @Test("Fail-safe budget — classifier flips to .dead at exactly the configured deadThreshold")
    func classifierFailSafeBudgetIs30Seconds() {
        // Default deadThreshold is 30. We assert the boundary in both
        // directions so a future tweak (e.g. someone trimming it to 25) is
        // caught by this test.
        let just29 = MicHealthSnapshot(
            isMuted: false,
            everDelivered: true,
            sinceLastBuffer: 29.0,
            sinceStart: 60
        )
        switch MicHealthClassifier.classify(just29) {
        case .degraded: break
        default: Issue.record("29 s of stall must be .degraded, not .dead")
        }

        let at30 = MicHealthSnapshot(
            isMuted: false,
            everDelivered: true,
            sinceLastBuffer: 30.0,
            sinceStart: 60
        )
        switch MicHealthClassifier.classify(at30) {
        case .dead: break
        default: Issue.record("30 s of stall must be .dead — RecorderState stops on first .dead so total budget == this threshold")
        }
    }
}

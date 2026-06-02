import AVFoundation
import CoreMedia
import Foundation
import Testing
@testable import CaptureKit

// MARK: - Tests

@Suite("AudioEngine synthetic-buffer tests (no real mic required)")
struct AudioEngineTests {

    @Test("Synthetic sine wave buffer has correct frame count")
    func sineWaveBufferFrameCount() {
        let frameCount: AVAudioFrameCount = 4800
        let buffer = AVAudioPCMBuffer.sineWave(frameCount: frameCount)
        #expect(buffer != nil)
        #expect(buffer?.frameLength == frameCount)
    }

    @Test("Synthetic sine wave buffer has non-zero samples")
    func sineWaveBufferNonZero() {
        guard let buf = AVAudioPCMBuffer.sineWave(frameCount: 4800),
              let data = buf.floatChannelData?[0] else {
            Issue.record("Failed to create sine buffer")
            return
        }
        let hasNonZero = (0..<Int(buf.frameLength)).contains { data[$0] != 0.0 }
        #expect(hasNonZero)
    }

    @Test("Silence buffer has all-zero samples")
    func silenceBufferIsZero() {
        guard let buf = AVAudioPCMBuffer.silence(frameCount: 4800),
              let data = buf.floatChannelData?[0] else {
            Issue.record("Failed to create silence buffer")
            return
        }
        let allZero = (0..<Int(buf.frameLength)).allSatisfy { data[$0] == 0.0 }
        #expect(allZero)
    }

    @Test("MockAudioEngine delivers fed buffers via AsyncStream")
    func mockEngineDeliversBuffers() async {
        let engine = MockAudioEngine()
        let stream = await engine.start()

        let bufferCount = 3
        Task {
            for _ in 0..<bufferCount {
                if let buf = AVAudioPCMBuffer.sineWave(frameCount: 4800) {
                    await engine.feed(buf)
                }
            }
            await engine.stop()
        }

        var received = 0
        for await _ in stream {
            received += 1
        }
        #expect(received == bufferCount)
    }

    @Test("AVAudioPCMBuffer toCMSampleBuffer produces non-nil result")
    func toCMSampleBufferProducesResult() {
        guard let buf = AVAudioPCMBuffer.sineWave(frameCount: 4800) else {
            Issue.record("Could not create buffer")
            return
        }
        let result = buf.toCMSampleBuffer(sampleOffset: 0, sampleRate: 48_000)
        // Should produce a valid CMSampleBuffer for a non-empty buffer
        #expect(result != nil)
    }

    @Test("AVAudioPCMBuffer toCMSampleBuffer preserves frame count")
    func toCMSampleBufferFrameCount() {
        let frameCount: AVAudioFrameCount = 4800
        guard let buf = AVAudioPCMBuffer.sineWave(frameCount: frameCount) else { return }
        guard let sb = buf.toCMSampleBuffer(sampleOffset: 0, sampleRate: 48_000) else { return }
        #expect(CMSampleBufferGetNumSamples(sb) == Int(frameCount))
    }

    @Test(
        "AudioEngine.start throws or succeeds without crashing (CI-safe)",
        .disabled(if: ProcessInfo.processInfo.environment["CI"] == "true",
                  "AVAudioEngine.start() crashes with signal 11 on headless macos-15 GH Actions runners — uncatchable in Swift; verified locally on M-series.")
    )
    func audioEngineStartIsSafe() async {
        let engine = AudioEngine()
        do {
            _ = try await engine.start()
            await engine.stop()
        } catch {
            // Expected on CI — no mic. Pass.
        }
    }

    @Test("Tap bootstrap uses pre-start install when input format is already valid")
    func tapBootstrapUsesPreStartInstallForUsableFormat() {
        #expect(
            AudioEngine.tapBootstrapStrategy(
                preStartSampleRate: 48_000,
                preStartChannelCount: 2
            ) == .installBeforeEngineStart
        )
    }

    @Test("Tap bootstrap falls back to delayed install when pre-start format is degenerate")
    func tapBootstrapFallsBackForDegenerateFormat() {
        #expect(
            AudioEngine.tapBootstrapStrategy(
                preStartSampleRate: 0,
                preStartChannelCount: 0
            ) == .installAfterEngineStart
        )
    }

    @Test("Tap install refreshes stale proposed format from live AUHAL format")
    func tapInstallRefreshesStaleProposedFormatFromLiveAUHALFormat() {
        #expect(
            AudioEngine.tapInstallFormatStrategy(
                proposedSampleRate: 44_100,
                proposedChannelCount: 2,
                liveSampleRate: 24_000,
                liveChannelCount: 1
            ) == .refreshFromLiveAUHALFormat
        )
    }

    @Test("Tap install keeps proposed format when live AUHAL format is degenerate")
    func tapInstallKeepsProposedFormatWhenLiveAUHALFormatIsDegenerate() {
        #expect(
            AudioEngine.tapInstallFormatStrategy(
                proposedSampleRate: 48_000,
                proposedChannelCount: 1,
                liveSampleRate: 0,
                liveChannelCount: 0
            ) == .keepProposedFormat
        )
    }

    @Test("Muted tap buffer preserves frame count as silence")
    func mutedTapBufferPreservesFrameCountAsSilence() throws {
        let frameCount: AVAudioFrameCount = 4800
        let buffer = try #require(AVAudioPCMBuffer.sineWave(frameCount: frameCount))

        AudioEngine.overwriteWithSilence(buffer)

        #expect(buffer.frameLength == frameCount)
        let data = try #require(buffer.floatChannelData?[0])
        let allZero = (0..<Int(buffer.frameLength)).allSatisfy { data[$0] == 0.0 }
        #expect(allZero)
    }
}

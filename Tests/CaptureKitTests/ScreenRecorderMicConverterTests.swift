// ScreenRecorderMicConverterTests.swift — Regression test for the SCStream
// mic resample fix. Without `ScreenRecorder.convertToTargetFormat`, the
// SCStream mic path on Bluetooth HFP/SCO devices (AirPods, headsets) yielded
// 24 kHz buffers into a 48 kHz SegmentWriter that dropped every one, so the
// resulting audio.m4a was never opened. See the 2026-06-09 debug session.

import AVFoundation
import Foundation
import Testing
@testable import CaptureKit

@Suite("ScreenRecorder.convertToTargetFormat")
struct ScreenRecorderMicConverterTests {

    private static func format(sampleRate: Double, channels: AVAudioChannelCount = 1) -> AVAudioFormat {
        AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: sampleRate,
            channels: channels,
            interleaved: false
        )!
    }

    @Test("Returns the same buffer untouched when source matches target (fast path)")
    func fastPathWhenFormatsMatch() throws {
        let cache = MicConverterCache()
        let target = Self.format(sampleRate: 48_000)
        let input = try #require(AVAudioPCMBuffer.sineWave(frameCount: 4_800, sampleRate: 48_000))

        let result = try #require(ScreenRecorder.convertToTargetFormat(
            buffer: input,
            target: target,
            cache: cache
        ))

        // Fast path returns the original instance.
        #expect(result === input)
        #expect(result.format.sampleRate == 48_000)
    }

    @Test("Resamples a 24 kHz Bluetooth-HFP-shaped buffer up to 48 kHz")
    func resamples24kToTargetRate() throws {
        let cache = MicConverterCache()
        let target = Self.format(sampleRate: 48_000)
        let input = try #require(AVAudioPCMBuffer.sineWave(frameCount: 240, sampleRate: 24_000))

        let result = try #require(ScreenRecorder.convertToTargetFormat(
            buffer: input,
            target: target,
            cache: cache
        ))

        #expect(result.format.sampleRate == 48_000)
        // 10 ms at 24 kHz → 10 ms at 48 kHz, ≈ 480 frames. The converter is
        // allowed a one-frame slack on either side.
        let expected: AVAudioFrameCount = 480
        let slack: AVAudioFrameCount = 2
        let lower = expected - slack
        let upper = expected + slack
        #expect((lower...upper).contains(result.frameLength))

        // Non-trivial signal preserved (sine over the window has non-zero energy).
        guard let data = result.floatChannelData?[0] else {
            Issue.record("Converted buffer missing channel data")
            return
        }
        let hasNonZero = (0..<Int(result.frameLength)).contains { abs(data[$0]) > 1e-6 }
        #expect(hasNonZero)
    }

    @Test("Builds a system-audio reference PCM buffer from an SCStream sample buffer")
    func buildsSystemAudioReferenceBufferFromSampleBuffer() throws {
        let cache = MicConverterCache()
        let target = Self.format(sampleRate: 48_000)
        let source = try #require(AVAudioPCMBuffer.sineWave(frameCount: 240, sampleRate: 24_000))
        let sampleBuffer = try #require(source.toCMSampleBuffer(sampleOffset: 0, sampleRate: 24_000))

        let result = try #require(ScreenRecorder.systemAudioReferenceBuffer(
            from: sampleBuffer,
            target: target,
            cache: cache
        ))

        #expect(result.format.sampleRate == 48_000)
        #expect(result.format.channelCount == 1)
        #expect((478...482).contains(result.frameLength))

        guard let data = result.floatChannelData?[0] else {
            Issue.record("Reference buffer missing channel data")
            return
        }
        let hasNonZero = (0..<Int(result.frameLength)).contains { abs(data[$0]) > 1e-6 }
        #expect(hasNonZero)
    }

    @Test("Reuses the same AVAudioConverter across consecutive same-format buffers")
    func cachesConverterAcrossBuffers() throws {
        let cache = MicConverterCache()
        let target = Self.format(sampleRate: 48_000)
        let source24k = Self.format(sampleRate: 24_000)

        let first = cache.converter(from: source24k, to: target)
        let second = cache.converter(from: source24k, to: target)

        #expect(first != nil)
        #expect(first === second)
    }

    @Test("Rebuilds the converter when the source format changes mid-session")
    func rebuildsOnFormatChange() throws {
        let cache = MicConverterCache()
        let target = Self.format(sampleRate: 48_000)
        let source24k = Self.format(sampleRate: 24_000)
        let source16k = Self.format(sampleRate: 16_000)

        let first = cache.converter(from: source24k, to: target)
        let second = cache.converter(from: source16k, to: target)

        #expect(first != nil)
        #expect(second != nil)
        #expect(first !== second)
    }
}

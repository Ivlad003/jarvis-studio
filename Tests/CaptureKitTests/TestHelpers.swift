// TestHelpers.swift — Synthetic audio buffer helpers shared across CaptureKitTests.
// Kept in a separate file so the AVFoundation extension does not affect
// Swift Testing macro expansion in the test structs.

import AVFoundation
import Foundation
@testable import CaptureKit

// MARK: - AVAudioPCMBuffer test helpers

extension AVAudioPCMBuffer {
    /// Create a synthetic mono Float32 PCM buffer filled with a sine wave.
    static func sineWave(
        frameCount: AVAudioFrameCount,
        sampleRate: Double = 48_000,
        frequency: Double = 440.0
    ) -> AVAudioPCMBuffer? {
        guard let format = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: sampleRate,
            channels: 1,
            interleaved: false
        ) else { return nil }

        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameCount) else {
            return nil
        }
        buffer.frameLength = frameCount

        guard let data = buffer.floatChannelData?[0] else { return nil }
        for i in 0..<Int(frameCount) {
            data[i] = Float(sin(2.0 * Double.pi * frequency * Double(i) / sampleRate))
        }
        return buffer
    }

    /// Create a silent mono Float32 PCM buffer.
    static func silence(frameCount: AVAudioFrameCount, sampleRate: Double = 48_000) -> AVAudioPCMBuffer? {
        guard let format = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: sampleRate,
            channels: 1,
            interleaved: false
        ) else { return nil }

        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameCount) else {
            return nil
        }
        buffer.frameLength = frameCount
        return buffer
    }

    /// Create a mono Float32 PCM buffer whose first sample encodes an index.
    static func taggedIndex(_ index: Int, frameCount: AVAudioFrameCount, sampleRate: Double = 48_000) -> AVAudioPCMBuffer? {
        guard let buffer = silence(frameCount: frameCount, sampleRate: sampleRate) else {
            return nil
        }

        buffer.floatChannelData?[0][0] = Float(index)
        return buffer
    }
}

// MARK: - MockAudioEngine

/// A test double that produces synthetic PCM buffers without requiring a real microphone.
actor MockAudioEngine {
    private var continuation: AsyncStream<AVAudioPCMBuffer>.Continuation?

    func start() async -> AsyncStream<AVAudioPCMBuffer> {
        let (stream, cont) = AsyncStream<AVAudioPCMBuffer>.makeStream()
        self.continuation = cont
        return stream
    }

    func feed(_ buffer: AVAudioPCMBuffer) {
        continuation?.yield(buffer)
    }

    func stop() async {
        continuation?.finish()
        continuation = nil
    }
}

// MARK: - TestPCMSink

/// Test sink that records received PCM buffers.
actor TestPCMSink: LivePCMSink {
    struct RecordedBuffer {
        let frameLength: AVAudioFrameCount
        let hostTime: UInt64
    }
    
    private(set) var receivedBuffers: [RecordedBuffer] = []
    
    func receive(_ buffer: AVAudioPCMBuffer, at hostTime: UInt64, source: LivePCMSource) async {
        _ = source
        // Store key properties rather than the buffer itself (AVAudioPCMBuffer isn't Sendable)
        receivedBuffers.append(RecordedBuffer(frameLength: buffer.frameLength, hostTime: hostTime))
    }
    
    func count() -> Int {
        receivedBuffers.count
    }
    
    func reset() {
        receivedBuffers.removeAll()
    }
}

// MARK: - BlockingTestPCMSink

/// Sink used to prove capture does not wait on live delivery.
final class BlockingTestPCMSink: @unchecked Sendable, LivePCMSink {
    private let stateQueue = DispatchQueue(label: "BlockingTestPCMSink.state")
    private var _startedCount = 0
    private var _finishedCount = 0
    private var _receivedOrder: [UInt64] = []
    let delay: Duration

    init(delay: Duration = .milliseconds(250)) {
        self.delay = delay
    }

    func receive(_ buffer: AVAudioPCMBuffer, at hostTime: UInt64, source: LivePCMSource) async {
        _ = source
        stateQueue.sync { _startedCount += 1 }

        try? await Task.sleep(for: delay)

        stateQueue.sync {
            _finishedCount += 1
            _receivedOrder.append(hostTime)
        }
    }

    func startedCount() -> Int {
        stateQueue.sync { _startedCount }
    }

    func finishedCount() -> Int {
        stateQueue.sync { _finishedCount }
    }

    func receivedOrder() -> [UInt64] {
        stateQueue.sync { _receivedOrder }
    }
}

// MARK: - TaggedIndexPCMSink

actor TaggedIndexPCMSink: LivePCMSink {
    let delay: Duration
    private(set) var receivedIndices: [Int] = []

    init(delay: Duration = .zero) {
        self.delay = delay
    }

    func receive(_ buffer: AVAudioPCMBuffer, at hostTime: UInt64, source: LivePCMSource) async {
        _ = hostTime
        _ = source
        if delay > .zero {
            try? await Task.sleep(for: delay)
        }
        let firstSample = buffer.floatChannelData?[0][0] ?? -1
        receivedIndices.append(Int(firstSample.rounded()))
    }
}

@preconcurrency import AVFoundation
import Testing
@testable import CaptureKit

@Suite("EchoCancellationProcessor offline")
struct EchoCancellationProcessorTests {
    @Test("Suppresses synthetic echo while preserving near-end speech")
    func suppressesEchoAndPreservesNearEnd() async throws {
        let sampleRate = 16_000.0
        let totalSamples = 64_000
        let blockSize = 480
        let reference = processorNoise(count: totalSamples)
        var impulse = Array(repeating: Float.zero, count: 96)
        impulse[12] = 0.65
        impulse[31] = -0.26
        impulse[63] = 0.14
        let echo = processorConvolve(reference, impulse: impulse)
        let nearStart = 36_000
        let nearEnd = (0..<totalSamples).map { index -> Float in
            guard index >= nearStart else { return 0 }
            return 0.18 * sinf(2 * .pi * 710 * Float(index) / Float(sampleRate))
        }
        let microphone = zip(echo, nearEnd).map(+)
        let processor = EchoCancellationProcessor(config: .init(
            processingSampleRate: sampleRate,
            filterLength: 128,
            delayEstimationWindowSamples: blockSize,
            maxDelaySamples: 128,
            bypassCoherenceThreshold: 0.05
        ))
        var output: [Float] = []
        var sawAdaptivePath = false

        for start in stride(from: 0, to: totalSamples, by: blockSize) {
            let end = min(start + blockSize, totalSamples)
            let refBuffer = try AVAudioPCMBuffer.testBuffer(samples: Array(reference[start..<end]), sampleRate: sampleRate)
            let micBuffer = try AVAudioPCMBuffer.testBuffer(samples: Array(microphone[start..<end]), sampleRate: sampleRate)
            let hostTime = UInt64(start)

            try await processor.receiveSystemBuffer(refBuffer, hostTime: hostTime)
            let result = try await processor.processMicrophoneBuffer(micBuffer, hostTime: hostTime)
            sawAdaptivePath = sawAdaptivePath || !result.bypassed
            output.append(contentsOf: result.buffer.monoSamples())
        }

        let echoOnlyRange = 28_000..<35_000
        let erle = processorERLE(
            microphone: Array(microphone[echoOnlyRange]),
            cleaned: Array(output[echoOnlyRange])
        )
        let nearRange = 42_000..<58_000
        let preservedCorrelation = abs(processorCorrelation(
            Array(output[nearRange]),
            Array(nearEnd[nearRange])
        ))

        #expect(sawAdaptivePath)
        #expect(erle >= 18)
        #expect(preservedCorrelation >= 0.9)
    }

    @Test("No-echo input bypasses with sample-identical output")
    func noEchoBypasses() async throws {
        let sampleRate = 48_000.0
        let frames = 4_800
        let reference = processorNoise(count: frames, seed: 0xABCD)
        let microphone = (0..<frames).map { index in
            Float(0.2 * sin(2 * Double.pi * 1_000 * Double(index) / sampleRate))
        }
        let processor = EchoCancellationProcessor(config: .init(
            processingSampleRate: 16_000,
            filterLength: 128,
            delayEstimationWindowSamples: 1_600,
            maxDelaySamples: 128,
            bypassCoherenceThreshold: 0.2
        ))

        try await processor.receiveSystemBuffer(
            try AVAudioPCMBuffer.testBuffer(samples: reference, sampleRate: sampleRate),
            hostTime: 0
        )
        let result = try await processor.processMicrophoneBuffer(
            try AVAudioPCMBuffer.testBuffer(samples: microphone, sampleRate: sampleRate),
            hostTime: 0
        )

        #expect(result.bypassed)
        #expect(result.buffer.format.sampleRate == sampleRate)
        #expect(result.buffer.frameLength == AVAudioFrameCount(frames))
        #expect(processorMSE(result.buffer.monoSamples(), microphone) <= 1e-6)
    }

    @Test("Echo-correlated input uses adaptive path")
    func echoInputDoesNotBypass() async throws {
        let sampleRate = 16_000.0
        let frames = 4_800
        let reference = processorNoise(count: frames)
        let microphone = processorConvolve(reference, impulse: [0.55, 0, 0.25])
        let processor = EchoCancellationProcessor(config: .init(
            processingSampleRate: sampleRate,
            filterLength: 64,
            delayEstimationWindowSamples: frames,
            maxDelaySamples: 64,
            bypassCoherenceThreshold: 0.2
        ))

        try await processor.receiveSystemBuffer(
            try AVAudioPCMBuffer.testBuffer(samples: reference, sampleRate: sampleRate),
            hostTime: 0
        )
        let result = try await processor.processMicrophoneBuffer(
            try AVAudioPCMBuffer.testBuffer(samples: microphone, sampleRate: sampleRate),
            hostTime: 0
        )

        #expect(!result.bypassed)
    }

    @Test("Cleaned output preserves microphone frame length when reference block is shorter")
    func preservesMicFrameLengthWhenReferenceBlockIsShorter() async throws {
        let sampleRate = 16_000.0
        let reference = processorNoise(count: 240)
        let microphone = processorConvolve(reference + Array(repeating: 0, count: 240), impulse: [0.5, 0.25])
        let processor = EchoCancellationProcessor(config: .init(
            processingSampleRate: sampleRate,
            filterLength: 64,
            delayEstimationWindowSamples: 480,
            maxDelaySamples: 64,
            bypassCoherenceThreshold: 0.05
        ))

        try await processor.receiveSystemBuffer(
            try AVAudioPCMBuffer.testBuffer(samples: reference, sampleRate: sampleRate),
            hostTime: 0
        )
        let result = try await processor.processMicrophoneBuffer(
            try AVAudioPCMBuffer.testBuffer(samples: microphone, sampleRate: sampleRate),
            hostTime: 0
        )

        #expect(result.buffer.frameLength == AVAudioFrameCount(microphone.count))
    }
}

private extension AVAudioPCMBuffer {
    static func testBuffer(samples: [Float], sampleRate: Double) throws -> AVAudioPCMBuffer {
        let format = try #require(AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: sampleRate,
            channels: 1,
            interleaved: false
        ))
        let buffer = try #require(AVAudioPCMBuffer(
            pcmFormat: format,
            frameCapacity: AVAudioFrameCount(samples.count)
        ))
        buffer.frameLength = AVAudioFrameCount(samples.count)
        let channel = try #require(buffer.floatChannelData?[0])
        for index in samples.indices {
            channel[index] = samples[index]
        }
        return buffer
    }

    func monoSamples() -> [Float] {
        guard let channel = floatChannelData?[0] else { return [] }
        let count = Int(frameLength)
        return (0..<count).map { channel[$0] }
    }
}

private func processorNoise(count: Int, seed: UInt64 = 0xF00D) -> [Float] {
    var state = seed
    return (0..<count).map { _ in
        state = state &* 6_364_136_223_846_793_005 &+ 1
        let raw = UInt32((state >> 32) & 0xFFFF_FFFF)
        return (Float(raw) / Float(UInt32.max) * 2) - 1
    }
}

private func processorConvolve(_ source: [Float], impulse: [Float]) -> [Float] {
    var out = Array(repeating: Float.zero, count: source.count)
    for index in source.indices {
        var sample = Float.zero
        for tap in impulse.indices where index >= tap {
            sample += source[index - tap] * impulse[tap]
        }
        out[index] = sample
    }
    return out
}

private func processorMSE(_ lhs: [Float], _ rhs: [Float]) -> Float {
    let count = min(lhs.count, rhs.count)
    guard count > 0 else { return .infinity }
    var sum = Float.zero
    for index in 0..<count {
        let diff = lhs[index] - rhs[index]
        sum += diff * diff
    }
    return sum / Float(count)
}

private func processorERLE(microphone: [Float], cleaned: [Float]) -> Float {
    let micEnergy = microphone.reduce(Float.zero) { $0 + $1 * $1 }
    let cleanEnergy = max(cleaned.reduce(Float.zero) { $0 + $1 * $1 }, 1e-12)
    return 10 * log10f(micEnergy / cleanEnergy)
}

private func processorCorrelation(_ lhs: [Float], _ rhs: [Float]) -> Float {
    let count = min(lhs.count, rhs.count)
    guard count > 0 else { return 0 }
    let leftMean = lhs.reduce(Float.zero, +) / Float(count)
    let rightMean = rhs.reduce(Float.zero, +) / Float(count)
    var numerator = Float.zero
    var leftEnergy = Float.zero
    var rightEnergy = Float.zero
    for index in 0..<count {
        let left = lhs[index] - leftMean
        let right = rhs[index] - rightMean
        numerator += left * right
        leftEnergy += left * left
        rightEnergy += right * right
    }
    guard leftEnergy > 0, rightEnergy > 0 else { return 0 }
    return numerator / sqrtf(leftEnergy * rightEnergy)
}

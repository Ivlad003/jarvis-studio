@preconcurrency import AVFoundation
import AudioDSP
import Foundation
import os

private let echoLog = Logger(subsystem: "dev.kosmonotes.studio", category: "EchoCancellation")

public actor EchoCancellationProcessor {
    public struct Config: Sendable {
        public let processingSampleRate: Double
        public let filterLength: Int
        public let stepSize: Float
        public let delayEstimationWindowSamples: Int
        public let maxDelaySamples: Int
        public let bypassCoherenceThreshold: Float
        public let energyFloor: Float
        public let dtdThreshold: Float
        public let dtdHoldSamples: Int
        public let maxBufferedReferenceBlocks: Int

        public init(
            processingSampleRate: Double = 16_000,
            filterLength: Int = 2_048,
            stepSize: Float = 0.3,
            delayEstimationWindowSamples: Int = 4_096,
            maxDelaySamples: Int = 2_048,
            bypassCoherenceThreshold: Float = 0.05,
            energyFloor: Float = 1e-6,
            dtdThreshold: Float = 2,
            dtdHoldSamples: Int = 640,
            maxBufferedReferenceBlocks: Int = 64
        ) {
            self.processingSampleRate = processingSampleRate
            self.filterLength = filterLength
            self.stepSize = stepSize
            self.delayEstimationWindowSamples = delayEstimationWindowSamples
            self.maxDelaySamples = maxDelaySamples
            self.bypassCoherenceThreshold = bypassCoherenceThreshold
            self.energyFloor = energyFloor
            self.dtdThreshold = dtdThreshold
            self.dtdHoldSamples = dtdHoldSamples
            self.maxBufferedReferenceBlocks = maxBufferedReferenceBlocks
        }
    }

    public struct Output: @unchecked Sendable {
        public let buffer: AVAudioPCMBuffer
        public let bypassed: Bool
        public let estimatedDelaySamples: Int
        public let coherence: Float
    }

    private struct TimedSamples: Sendable {
        let hostTime: UInt64
        let samples: [Float]
        let sampleRate: Double
    }

    private let config: Config
    private var referenceBlocks: [TimedSamples] = []
    private var canceller: NLMSCanceller
    private var doubleTalkDetector: GeigelDTD
    /// Bulk speaker→mic delay, estimated ONCE over the first block that carries
    /// signal on both streams, then frozen. Re-estimating every buffer (over a
    /// single short block) returned a jittery delay that shifted the reference
    /// alignment between buffers and stopped the NLMS from converging — the mic
    /// and system share the SCStream clock here, so the true delay is ~0 and
    /// stable. Cleared on `reset()` (route change / new recording).
    private var cachedDelaySamples: Int?
    /// Periodic-diagnostics counter (logs ERL/coherence every N processed blocks
    /// so on-device cancellation can be confirmed from the unified log).
    private var processedBlocks = 0

    public init(config: Config = .init()) {
        self.config = config
        self.canceller = NLMSCanceller(filterLength: config.filterLength, stepSize: config.stepSize)
        self.doubleTalkDetector = GeigelDTD(
            referenceWindowLength: config.filterLength,
            threshold: config.dtdThreshold,
            holdSamples: config.dtdHoldSamples,
            energyFloor: config.energyFloor
        )
    }

    public func reset() {
        referenceBlocks.removeAll(keepingCapacity: true)
        canceller.reset()
        doubleTalkDetector.reset()
        cachedDelaySamples = nil
        processedBlocks = 0
    }

    public func receiveSystemBuffer(_ buffer: AVAudioPCMBuffer, hostTime: UInt64) throws {
        let samples = try Self.resampledMonoSamples(from: buffer, targetSampleRate: config.processingSampleRate)
        referenceBlocks.append(TimedSamples(
            hostTime: hostTime,
            samples: samples,
            sampleRate: config.processingSampleRate
        ))

        if referenceBlocks.count > config.maxBufferedReferenceBlocks {
            referenceBlocks.removeFirst(referenceBlocks.count - config.maxBufferedReferenceBlocks)
        }
    }

    public func processMicrophoneBuffer(_ buffer: AVAudioPCMBuffer, hostTime: UInt64) throws -> Output {
        guard let referenceIndex = nearestReferenceBlockIndex(to: hostTime) else {
            return Output(buffer: buffer, bypassed: true, estimatedDelaySamples: 0, coherence: 0)
        }
        let reference = referenceBlocks[referenceIndex]

        let microphone = try Self.resampledMonoSamples(from: buffer, targetSampleRate: config.processingSampleRate)
        let count = microphone.count
        guard count > 0 else {
            return Output(buffer: buffer, bypassed: true, estimatedDelaySamples: 0, coherence: 0)
        }

        let microphoneBlock = Array(microphone.prefix(count))
        let referenceBlock = Array(reference.samples.prefix(min(reference.samples.count, count)))
        // Estimate the bulk delay ONCE (when both streams carry signal) and
        // freeze it. Per-buffer re-estimation over a single short block jittered
        // the alignment and prevented convergence. Default to 0 until a
        // confident estimate is cached — correct for the SCStream mic+system
        // case (shared clock → ~0 delay) and absorbed by the NLMS tail otherwise.
        let delay: Int
        if let cachedDelaySamples {
            delay = cachedDelaySamples
        } else if Self.energy(referenceBlock) > config.energyFloor,
                  Self.energy(microphoneBlock) > config.energyFloor {
            let estimated = estimateDelay(reference: referenceBlock, microphone: microphoneBlock)
            cachedDelaySamples = estimated
            delay = estimated
            echoLog.info("EchoCancellation: locked bulk delay = \(estimated, privacy: .public) samples")
        } else {
            delay = cachedDelaySamples ?? 0
        }
        let timeline = referenceTimeline(through: referenceIndex)
        let currentStart = referenceBlocks[..<referenceIndex].reduce(0) { $0 + $1.samples.count }
        let alignedReference = Self.align(
            referenceTimeline: timeline,
            currentStart: currentStart,
            delaySamples: delay,
            count: count
        )
        let coherence = Self.normalizedCorrelation(alignedReference, microphoneBlock)

        if shouldBypass(reference: alignedReference, microphone: microphoneBlock, coherence: coherence) {
            return Output(buffer: buffer, bypassed: true, estimatedDelaySamples: delay, coherence: coherence)
        }

        var cleaned = [Float](repeating: 0, count: count)
        for index in 0..<count {
            let adapt = doubleTalkDetector.shouldAdapt(
                reference: alignedReference[index],
                microphone: microphoneBlock[index]
            )
            cleaned[index] = canceller.process(
                reference: alignedReference[index],
                microphone: microphoneBlock[index],
                adapt: adapt
            ).error
        }

        processedBlocks += 1
        if processedBlocks % 30 == 1 {
            let erle = 10 * log10f(max(Self.energy(microphoneBlock), 1e-12) / max(Self.energy(cleaned), 1e-12))
            echoLog.info("EchoCancellation: block=\(self.processedBlocks, privacy: .public) delay=\(delay, privacy: .public) coherence=\(coherence, privacy: .public) ERLE=\(erle, privacy: .public)dB")
        }

        // Divergence guard: NLMS mis-adaptation produces a "cleaned" block that
        // is LOUDER than the input (negative ERLE → the robotic/musical
        // artifact). Never emit that — pass the original mic through for this
        // block so echo cancellation can only ever reduce, never add, energy.
        if Self.energy(cleaned) > Self.energy(microphoneBlock) {
            return Output(buffer: buffer, bypassed: true, estimatedDelaySamples: delay, coherence: coherence)
        }

        let cleanedBuffer = try Self.buffer(
            fromProcessingSamples: cleaned,
            processingSampleRate: config.processingSampleRate,
            outputFormat: buffer.format
        )
        return Output(buffer: cleanedBuffer, bypassed: false, estimatedDelaySamples: delay, coherence: coherence)
    }

    private func nearestReferenceBlockIndex(to hostTime: UInt64) -> Int? {
        referenceBlocks.indices.min { lhs, rhs in
            Self.distance(referenceBlocks[lhs].hostTime, hostTime) < Self.distance(referenceBlocks[rhs].hostTime, hostTime)
        }
    }

    private func referenceTimeline(through index: Int) -> [Float] {
        referenceBlocks[...index].flatMap(\.samples)
    }

    private func estimateDelay(reference: [Float], microphone: [Float]) -> Int {
        let window = min(config.delayEstimationWindowSamples, reference.count, microphone.count)
        guard window >= 2 else { return 0 }
        return estimateDelayGCCPHAT(
            reference: Array(reference.prefix(window)),
            microphone: Array(microphone.prefix(window)),
            fftSize: max(2, config.delayEstimationWindowSamples),
            maxDelaySamples: min(config.maxDelaySamples, window / 2)
        )
    }

    private func shouldBypass(reference: [Float], microphone: [Float], coherence: Float) -> Bool {
        Self.energy(reference) <= config.energyFloor
            || Self.energy(microphone) <= config.energyFloor
            || coherence < config.bypassCoherenceThreshold
    }

    private static func align(referenceTimeline: [Float], currentStart: Int, delaySamples: Int, count: Int) -> [Float] {
        var aligned = [Float](repeating: 0, count: count)

        for index in 0..<count {
            let referenceIndex = currentStart + index - delaySamples
            if referenceTimeline.indices.contains(referenceIndex) {
                aligned[index] = referenceTimeline[referenceIndex]
            }
        }

        return aligned
    }

    private static func normalizedCorrelation(_ lhs: [Float], _ rhs: [Float]) -> Float {
        let count = min(lhs.count, rhs.count)
        guard count > 0 else { return 0 }

        var numerator = Float.zero
        var leftEnergy = Float.zero
        var rightEnergy = Float.zero
        for index in 0..<count {
            numerator += lhs[index] * rhs[index]
            leftEnergy += lhs[index] * lhs[index]
            rightEnergy += rhs[index] * rhs[index]
        }

        guard leftEnergy > 0, rightEnergy > 0 else { return 0 }
        return abs(numerator / sqrtf(leftEnergy * rightEnergy))
    }

    private static func energy(_ samples: [Float]) -> Float {
        samples.reduce(Float.zero) { $0 + $1 * $1 }
    }

    private static func distance(_ lhs: UInt64, _ rhs: UInt64) -> UInt64 {
        lhs > rhs ? lhs - rhs : rhs - lhs
    }

    private static func resampledMonoSamples(
        from buffer: AVAudioPCMBuffer,
        targetSampleRate: Double
    ) throws -> [Float] {
        let inputSamples = monoSamples(from: buffer)
        guard abs(buffer.format.sampleRate - targetSampleRate) > 0.5 else {
            return inputSamples
        }

        let outputFormat = try makeFormat(sampleRate: targetSampleRate)
        return try convert(samples: inputSamples, fromSampleRate: buffer.format.sampleRate, toFormat: outputFormat)
    }

    private static func buffer(
        fromProcessingSamples samples: [Float],
        processingSampleRate: Double,
        outputFormat: AVAudioFormat
    ) throws -> AVAudioPCMBuffer {
        if abs(outputFormat.sampleRate - processingSampleRate) <= 0.5 {
            return try makeBuffer(samples: samples, format: outputFormat)
        }

        let converted = try convert(samples: samples, fromSampleRate: processingSampleRate, toFormat: outputFormat)
        return try makeBuffer(samples: converted, format: outputFormat)
    }

    private static func convert(
        samples: [Float],
        fromSampleRate inputSampleRate: Double,
        toFormat outputFormat: AVAudioFormat
    ) throws -> [Float] {
        let inputFormat = try makeFormat(sampleRate: inputSampleRate)
        let inputBuffer = try makeBuffer(samples: samples, format: inputFormat)
        let ratio = outputFormat.sampleRate / inputSampleRate
        let outputCapacity = AVAudioFrameCount(max(1, Int(ceil(Double(samples.count) * ratio)) + 32))
        guard let outputBuffer = AVAudioPCMBuffer(pcmFormat: outputFormat, frameCapacity: outputCapacity),
              let converter = AVAudioConverter(from: inputFormat, to: outputFormat)
        else {
            throw EchoCancellationProcessorError.formatConversionFailed
        }

        let inputState = ConversionInputState()
        var conversionError: NSError?
        converter.convert(to: outputBuffer, error: &conversionError) { _, status in
            if inputState.didProvideInput {
                status.pointee = .noDataNow
                return nil
            }
            inputState.didProvideInput = true
            status.pointee = .haveData
            return inputBuffer
        }

        if let conversionError {
            throw conversionError
        }

        return monoSamples(from: outputBuffer)
    }

    private static func makeFormat(sampleRate: Double) throws -> AVAudioFormat {
        guard let format = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: sampleRate,
            channels: 1,
            interleaved: false
        ) else {
            throw EchoCancellationProcessorError.formatConversionFailed
        }
        return format
    }

    private static func makeBuffer(samples: [Float], format: AVAudioFormat) throws -> AVAudioPCMBuffer {
        guard let buffer = AVAudioPCMBuffer(
            pcmFormat: format,
            frameCapacity: AVAudioFrameCount(samples.count)
        ) else {
            throw EchoCancellationProcessorError.formatConversionFailed
        }

        buffer.frameLength = AVAudioFrameCount(samples.count)
        guard let channel = buffer.floatChannelData?[0] else {
            throw EchoCancellationProcessorError.formatConversionFailed
        }

        for index in samples.indices {
            channel[index] = samples[index]
        }

        return buffer
    }

    private static func monoSamples(from buffer: AVAudioPCMBuffer) -> [Float] {
        guard let channel = buffer.floatChannelData?[0] else { return [] }
        let count = Int(buffer.frameLength)
        return (0..<count).map { channel[$0] }
    }
}

public enum EchoCancellationProcessorError: Error, Sendable {
    case formatConversionFailed
}

private final class ConversionInputState: @unchecked Sendable {
    var didProvideInput = false
}

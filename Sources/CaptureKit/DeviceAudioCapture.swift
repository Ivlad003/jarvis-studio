@preconcurrency import AVFoundation
@preconcurrency import CoreAudio
import Foundation
import os

private let deviceCaptureLog = Logger(subsystem: "dev.kosmonotes.studio", category: "DeviceAudioCapture")

// MARK: - DeviceAudioCapture

/// Capture audio from a specific Core Audio input device (e.g. BlackHole 2ch
/// virtual loopback) instead of the default mic. Used as a "system audio
/// source" alternative to SCKit when the user wants to record system audio
/// while their mic is also live, without the speaker → mic echo loop.
///
/// Implementation: spins up an `AVAudioEngine`, points its input AUHAL at the
/// configured `AudioDeviceID` via `kAudioOutputUnitProperty_CurrentDevice`,
/// installs a tap, and yields ~100 ms PCM buffers as `AsyncStream<AVAudioPCMBuffer>`
/// — same shape as `AudioEngine` so the rest of the pipeline can consume it
/// without caring about the source.
public actor DeviceAudioCapture {

    public struct Config: Sendable {
        public let deviceUID: String
        public let sampleRate: Double
        public let channels: AVAudioChannelCount

        public init(deviceUID: String, sampleRate: Double = 48_000, channels: AVAudioChannelCount = 1) {
            self.deviceUID = deviceUID
            self.sampleRate = sampleRate
            self.channels = channels
        }
    }

    public enum DeviceCaptureError: Error, Sendable {
        case deviceNotFound(uid: String)
        case audioUnitUnavailable
        case setDeviceFailed(status: OSStatus)
        case formatCreationFailed
        case engineStartFailed(underlying: Error)
        case noBuffersReceived
    }

    private let config: Config
    private var engine: AVAudioEngine?
    private var continuation: AsyncStream<AVAudioPCMBuffer>.Continuation?

    public init(config: Config) {
        self.config = config
    }

    /// Start capture. Returns an AsyncStream of mono Float32 48 kHz buffers.
    public func start() async throws -> sending AsyncStream<AVAudioPCMBuffer> {
        if engine != nil { await stop() }

        guard let deviceID = AudioDeviceEnumerator.deviceID(forUID: config.deviceUID) else {
            deviceCaptureLog.error("DeviceAudioCapture.start: device with UID \(self.config.deviceUID, privacy: .public) not found")
            throw DeviceCaptureError.deviceNotFound(uid: config.deviceUID)
        }
        deviceCaptureLog.info("DeviceAudioCapture.start: targeting deviceID=\(deviceID, privacy: .public) UID=\(self.config.deviceUID, privacy: .public)")

        let engine = AVAudioEngine()
        self.engine = engine

        guard let targetFormat = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: config.sampleRate,
            channels: config.channels,
            interleaved: false
        ) else {
            throw DeviceCaptureError.formatCreationFailed
        }

        let inputNode = engine.inputNode

        // Override the engine's default input device. AVAudioEngine doesn't
        // expose this directly — we reach into the underlying AUHAL via
        // `AudioUnit` and set kAudioOutputUnitProperty_CurrentDevice.
        guard let audioUnit = inputNode.audioUnit else {
            deviceCaptureLog.error("DeviceAudioCapture.start: inputNode has no audioUnit")
            throw DeviceCaptureError.audioUnitUnavailable
        }
        var devID = deviceID
        let setStatus = AudioUnitSetProperty(
            audioUnit,
            kAudioOutputUnitProperty_CurrentDevice,
            kAudioUnitScope_Global,
            0,
            &devID,
            UInt32(MemoryLayout<AudioDeviceID>.size)
        )
        guard setStatus == noErr else {
            deviceCaptureLog.error("DeviceAudioCapture.start: AudioUnitSetProperty(CurrentDevice) failed status=\(setStatus, privacy: .public)")
            throw DeviceCaptureError.setDeviceFailed(status: setStatus)
        }

        let (stream, continuation) = AudioPCMBufferStream.makeStream()
        self.continuation = continuation

        engine.prepare()
        do {
            try engine.start()
        } catch {
            deviceCaptureLog.error("DeviceAudioCapture.start: engine.start threw — \(error.localizedDescription, privacy: .public)")
            self.engine = nil
            continuation.finish()
            self.continuation = nil
            throw DeviceCaptureError.engineStartFailed(underlying: error)
        }

        // Same format-poll pattern as AudioEngine — AUHAL needs a moment
        // after start() before its input bus reports a real format.
        var inputFormat = inputNode.outputFormat(forBus: 0)
        var attempts = 0
        while (inputFormat.channelCount == 0 || inputFormat.sampleRate == 0) && attempts < 100 {
            try? await Task.sleep(nanoseconds: 10_000_000)
            inputFormat = inputNode.outputFormat(forBus: 0)
            attempts += 1
        }
        guard inputFormat.channelCount > 0, inputFormat.sampleRate > 0 else {
            deviceCaptureLog.error("DeviceAudioCapture.start: input format never bound after \(attempts, privacy: .public) polls")
            engine.stop()
            self.engine = nil
            continuation.finish()
            self.continuation = nil
            throw DeviceCaptureError.engineStartFailed(underlying: NSError(
                domain: "DeviceAudioCapture",
                code: -1,
                userInfo: [NSLocalizedDescriptionKey: "Device input format did not bind within 1 s."]
            ))
        }
        deviceCaptureLog.info("DeviceAudioCapture.start: input format bound — sampleRate=\(inputFormat.sampleRate, privacy: .public) channels=\(inputFormat.channelCount, privacy: .public)")

        let bufferSize: AVAudioFrameCount = 4800
        let cont = continuation
        let converterCache = ConverterCacheRef()

        inputNode.installTap(onBus: 0, bufferSize: bufferSize, format: inputFormat) { buffer, _ in
            let bufferFormat = buffer.format
            if bufferFormat.sampleRate == targetFormat.sampleRate
                && bufferFormat.channelCount == targetFormat.channelCount
                && bufferFormat.commonFormat == targetFormat.commonFormat {
                cont.yield(buffer)
                return
            }
            guard let converter = converterCache.converter(from: bufferFormat, to: targetFormat) else { return }
            let frameCapacity = AVAudioFrameCount(
                Double(buffer.frameLength) * targetFormat.sampleRate / bufferFormat.sampleRate
            ) + 1
            guard let converted = AVAudioPCMBuffer(pcmFormat: targetFormat, frameCapacity: max(1, frameCapacity)) else { return }
            var error: NSError?
            let src = buffer
            let status = converter.convert(to: converted, error: &error) { _, outStatus in
                outStatus.pointee = .haveData
                return src
            }
            if status != .error, converted.frameLength > 0 {
                cont.yield(converted)
            }
        }
        return stream
    }

    public func stop() async {
        engine?.inputNode.removeTap(onBus: 0)
        engine?.stop()
        continuation?.finish()
        engine = nil
        continuation = nil
    }
}

// MARK: - Local converter cache (mirrors AudioEngine's pattern)

private final class ConverterCacheRef: @unchecked Sendable {
    private var converter: AVAudioConverter?
    private var sourceFormat: AVAudioFormat?

    func converter(from source: AVAudioFormat, to target: AVAudioFormat) -> AVAudioConverter? {
        if let existing = converter,
           let cached = sourceFormat,
           cached.sampleRate == source.sampleRate,
           cached.channelCount == source.channelCount,
           cached.commonFormat == source.commonFormat {
            return existing
        }
        let new = AVAudioConverter(from: source, to: target)
        converter = new
        sourceFormat = source
        return new
    }
}

@preconcurrency import AVFoundation
import CaptureKit
import Foundation
import TranscriptionKit

@available(macOS 14.0, *)
struct StreamingLiveSession: Sendable {
    let events: AsyncThrowingStream<TranscriptSegment, Error>
    let send: @Sendable (Data) async throws -> Void
    let finish: @Sendable () async throws -> Void
    let cancel: @Sendable () async -> Void

    init(
        events: AsyncThrowingStream<TranscriptSegment, Error>,
        send: @escaping @Sendable (Data) async throws -> Void,
        finish: @escaping @Sendable () async throws -> Void,
        cancel: @escaping @Sendable () async -> Void
    ) {
        self.events = events
        self.send = send
        self.finish = finish
        self.cancel = cancel
    }
}

@available(macOS 14.0, *)
actor StreamingLiveSource: LivePCMSink {
    typealias OpenSession = @Sendable () async throws -> StreamingLiveSession
    typealias PCMEncoder = @Sendable (AVAudioPCMBuffer) throws -> Data

    private let openSession: OpenSession
    private let encodePCM: PCMEncoder
    private let hub: LiveTranscriptHub
    private var session: StreamingLiveSession?
    private var consumeTask: Task<Void, Never>?

    init(
        openSession: @escaping OpenSession,
        encodePCM: @escaping PCMEncoder = StreamingLiveSource.encodeLinear16PCM16k,
        hub: LiveTranscriptHub = LiveTranscriptHub()
    ) {
        self.openSession = openSession
        self.encodePCM = encodePCM
        self.hub = hub
    }

    static func deepgram(
        apiKey: String,
        language: String?,
        hub: LiveTranscriptHub = LiveTranscriptHub()
    ) -> StreamingLiveSource {
        StreamingLiveSource(
            openSession: {
                let provider = DeepgramProvider(apiKey: apiKey)
                let config = TranscriptionConfig(language: language, sampleRate: 16_000, channels: 1)
                let session = try await provider.openResilientSession(config: config)
                return StreamingLiveSession(
                    events: session.events,
                    send: { data in try await session.send(data) },
                    finish: { try await session.finish() },
                    cancel: { await session.cancel() }
                )
            },
            hub: hub
        )
    }

    func start() async throws {
        guard session == nil else { return }
        await hub.reset()
        let opened = try await openSession()
        session = opened
        consumeTask = Task { [weak self] in
            await self?.consume(opened.events)
        }
    }

    func receive(_ buffer: AVAudioPCMBuffer, at hostTime: UInt64, source: LivePCMSource) async {
        guard source == .mic, let session else { return }

        do {
            let data = try encodePCM(buffer)
            guard !data.isEmpty else { return }
            try await session.send(data)
        } catch {
            await hub.markFailed(error.localizedDescription)
        }
    }

    func snapshot() async -> LiveTranscriptState {
        await hub.snapshot()
    }

    func stop() async {
        let active = session
        session = nil
        do {
            try await active?.finish()
        } catch {
            await hub.markFailed(error.localizedDescription)
        }
        consumeTask?.cancel()
        consumeTask = nil
    }

    func cancel() async {
        let active = session
        session = nil
        consumeTask?.cancel()
        consumeTask = nil
        await active?.cancel()
    }

    private func consume(_ events: AsyncThrowingStream<TranscriptSegment, Error>) async {
        do {
            for try await segment in events {
                await hub.apply(segment)
            }
        } catch {
            await hub.markFailed(error.localizedDescription)
        }
    }

    static func encodeLinear16PCM16k(_ buffer: AVAudioPCMBuffer) throws -> Data {
        guard buffer.frameLength > 0 else { return Data() }
        guard buffer.format.sampleRate > 0 else {
            throw TranscriptionError.sendFailed(message: "input buffer has an invalid sample rate")
        }
        guard let channels = buffer.floatChannelData else {
            throw TranscriptionError.sendFailed(message: "expected non-interleaved Float32 PCM")
        }

        let inputFrames = Int(buffer.frameLength)
        let inputRate = buffer.format.sampleRate
        let outputRate = 16_000.0
        let outputFrames = max(1, Int(floor(Double(inputFrames) * outputRate / inputRate)))
        var data = Data()
        data.reserveCapacity(outputFrames * MemoryLayout<Int16>.size)

        for outputIndex in 0..<outputFrames {
            let sourceIndex = min(
                inputFrames - 1,
                Int(floor(Double(outputIndex) * inputRate / outputRate))
            )
            let sample = min(1, max(-1, channels[0][sourceIndex]))
            let scaled = sample < 0
                ? Int16((sample * 32_768).rounded())
                : Int16((sample * 32_767).rounded())
            var littleEndian = scaled.littleEndian
            withUnsafeBytes(of: &littleEndian) { bytes in
                data.append(contentsOf: bytes)
            }
        }

        return data
    }
}

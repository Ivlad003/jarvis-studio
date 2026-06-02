@preconcurrency import AVFoundation
import CaptureKit
import Foundation
import TranscriptionKit
import os

private let recorderLiveTeeLog = Logger(subsystem: "dev.kosmonotes.studio", category: "RecorderLiveTee")

/// Bridges `CaptureSession`'s `LivePCMSink` PCM tee into a
/// `LiveTranscriptEngine`. Owns a temporary CAF file the engine reads from
/// during ticks, plus the periodic tick scheduler.
///
/// The CAF file lives under `FileManager.default.temporaryDirectory` and is
/// deleted on `stop()`. Recorder's persisted artifacts (audio.m4a, transcript)
/// continue to come from the existing post-stop batch path — this tee only
/// provides the surface the popover / menu-bar live transcript displays.
@available(macOS 14.0, *)
struct RecorderLiveTeeEngine: Sendable {
    let attach: @Sendable (URL) async -> Void
    let ingest: @Sendable (TimeInterval, Data) async -> Void
    let tick: @Sendable (TimeInterval, TranscriptionConfig) async throws -> Void
    let finish: @Sendable (TimeInterval, TranscriptionConfig) async throws -> Void
    let snapshot: @Sendable () async -> LiveTranscriptState

    init(
        attach: @escaping @Sendable (URL) async -> Void,
        ingest: @escaping @Sendable (TimeInterval, Data) async -> Void,
        tick: @escaping @Sendable (TimeInterval, TranscriptionConfig) async throws -> Void,
        finish: @escaping @Sendable (TimeInterval, TranscriptionConfig) async throws -> Void,
        snapshot: @escaping @Sendable () async -> LiveTranscriptState
    ) {
        self.attach = attach
        self.ingest = ingest
        self.tick = tick
        self.finish = finish
        self.snapshot = snapshot
    }

    init(_ engine: LiveTranscriptEngine) {
        self.init(
            attach: { file in await engine.attach(audioFile: file) },
            ingest: { sampleTime, pcmData in await engine.ingest(sampleTime: sampleTime, pcmData: pcmData) },
            tick: { now, config in try await engine.tick(now: now, config: config) },
            finish: { now, config in try await engine.finish(now: now, config: config) },
            snapshot: { await engine.snapshot() }
        )
    }
}

@available(macOS 14.0, *)
public actor RecorderLiveTee: LivePCMSink {
    public nonisolated let audioFileURL: URL
    private let engine: RecorderLiveTeeEngine
    private let cadence: TimeInterval
    private let config: TranscriptionConfig
    private var audioFile: AVAudioFile?
    private var tickTask: Task<Void, Never>?
    private var startTime: TimeInterval = 0
    private var writtenFrames: AVAudioFramePosition = 0

    public init(
        engine: LiveTranscriptEngine,
        cadence: TimeInterval = 3,
        config: TranscriptionConfig = TranscriptionConfig(language: nil, sampleRate: 16_000)
    ) {
        self.init(engine: RecorderLiveTeeEngine(engine), cadence: cadence, config: config)
    }

    init(
        engine: RecorderLiveTeeEngine,
        cadence: TimeInterval = 3,
        config: TranscriptionConfig = TranscriptionConfig(language: nil, sampleRate: 16_000)
    ) {
        self.engine = engine
        self.cadence = cadence
        self.config = config
        self.audioFileURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("recorder_live_\(UUID().uuidString).caf")
    }

    /// Open the temporary CAF file (deferred to first PCM buffer so we adopt
    /// the live source's exact format), attach it to the engine, and start the
    /// periodic tick scheduler.
    public func start() async {
        startTime = ProcessInfo.processInfo.systemUptime
        writtenFrames = 0
        await engine.attach(audioFileURL)
        let cadenceNs = UInt64(cadence * 1_000_000_000)
        let engineRef = engine
        let cfg = config
        let baseTime = startTime
        tickTask = Task.detached {
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: cadenceNs)
                if Task.isCancelled { return }
                let now = ProcessInfo.processInfo.systemUptime - baseTime
                try? await engineRef.tick(now, cfg)
            }
        }
        recorderLiveTeeLog.info("RecorderLiveTee.start: cadence=\(self.cadence, privacy: .public)s file=\(self.audioFileURL.lastPathComponent, privacy: .public)")
    }

    public func receive(_ buffer: AVAudioPCMBuffer, at hostTime: UInt64) async {
        if audioFile == nil {
            do {
                audioFile = try AVAudioFile(forWriting: audioFileURL, settings: buffer.format.settings)
            } catch {
                recorderLiveTeeLog.error("RecorderLiveTee.receive: AVAudioFile open failed — \(error.localizedDescription, privacy: .public)")
                return
            }
        }
        do {
            try audioFile?.write(from: buffer)
            let sampleRate = buffer.format.sampleRate
            guard sampleRate > 0 else { return }
            writtenFrames += AVAudioFramePosition(buffer.frameLength)
            let sampleTime = Double(writtenFrames) / sampleRate
            await engine.ingest(sampleTime, Data())
        } catch {
            recorderLiveTeeLog.error("RecorderLiveTee.receive: write failed — \(error.localizedDescription, privacy: .public)")
        }
    }

    public func snapshot() async -> LiveTranscriptState {
        await engine.snapshot()
    }

    /// Cancel the tick scheduler, force a final flush, close the CAF, remove
    /// the temp file. Safe to call multiple times.
    public func stop() async {
        tickTask?.cancel()
        tickTask = nil
        let now = ProcessInfo.processInfo.systemUptime - startTime
        try? await engine.finish(now, config)
        audioFile = nil
        try? FileManager.default.removeItem(at: audioFileURL)
        recorderLiveTeeLog.info("RecorderLiveTee.stop: tick task cancelled, temp file removed")
    }
}

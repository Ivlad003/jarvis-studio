@preconcurrency import AVFoundation
import Foundation
import os
import os.signpost
import TranscriptionKit
import AIKit

// MARK: - DictationPipeline

/// Orchestrates: hotkey-press → AVAudioEngine mic tap → hotkey-release →
/// WAV encode → Whisper batch transcription → optional LLM cleanup →
/// AccessibilityPaster.
///
/// v0 latency note: Whisper batch median ~3 s on a typical broadband connection.
/// <1.5 s requires Deepgram streaming + a public PCM tee out of CaptureSession —
/// both deferred to v0.1. The Settings UI reflects this honestly.
@available(macOS 14.0, *)
@MainActor
public final class DictationPipeline {

    public typealias Logger = @Sendable (String) -> Void

    /// Stable signpost-event names emitted by the pipeline. Public so tests
    /// (and Instruments queries) can match against them without fuzzy strings.
    public enum Stage: String, Sendable, CaseIterable {
        case captureStart = "capture-start"
        case encodeDone = "encode-done"
        case uploadIssued = "upload-issued"
        case transcriptFinal = "transcript-final"
        case llmCleanupFinal = "llm-cleanup-final"
        case pasteIssued = "paste-issued"

        /// `OSSignposter.emitEvent` needs a `StaticString`, so we precompute
        /// one `EventName` per case from a literal.
        var signpostName: StaticString {
            switch self {
            case .captureStart:     return "capture-start"
            case .encodeDone:       return "encode-done"
            case .uploadIssued:     return "upload-issued"
            case .transcriptFinal:  return "transcript-final"
            case .llmCleanupFinal:  return "llm-cleanup-final"
            case .pasteIssued:      return "paste-issued"
            }
        }
    }

    /// Test/observability hook fired in addition to the real `os_signpost`
    /// emission. Receives the `Stage` and the absolute timestamp at which
    /// the pipeline reached it. Default `nil` keeps existing call sites
    /// (e.g. `App/State/DictationState.swift`) untouched.
    public typealias EventHook = @Sendable (Stage, ContinuousClock.Instant) -> Void

    /// Test-only paste shim. Defaults to the real `AccessibilityPaster.paste`.
    public typealias Paster = @Sendable (String) -> AccessibilityPaster.PasteResult

    /// Test-only transcription shim. Defaults to the configured
    /// `WhisperProvider.transcribe`.
    public typealias Transcriber = @Sendable (URL, TranscriptionConfig) async throws -> BatchTranscriptResult

    /// `OSSignposter` is the modern API and is `Sendable`-safe; one shared
    /// instance per process is fine.
    static let signposter = OSSignposter(
        subsystem: "dev.kosmonotes.dictation",
        category: "pipeline"
    )

    // MARK: - Status

    public enum Status: Equatable, Sendable {
        case idle
        case recording
        case transcribing
        case cleaning
        case pasting
        case completed
        case failed(String)
    }

    // MARK: - Observable state

    public var status: Status = .idle

    // MARK: - Last-run capture (for app-layer persistence)
    //
    // Set during stopAndProcess. App layer (DictationState) reads these after
    // the await returns to write a SessionRecord + audio.m4a + transcript files
    // into the Library. Cleared on each new startRecording.

    /// Final transcript that was paste-bound. `nil` until stopAndProcess (or
    /// stopCapture + live flush) produces one; non-empty when the pipeline
    /// reached the paste stage.
    public private(set) var lastTranscript: String?

    /// Raw mono Float32 PCM samples captured by the engine, at `lastSampleRate`.
    /// Set even if transcription / paste failed, so failed sessions can still
    /// be persisted with their audio.
    public private(set) var lastPCMData: Data?

    /// Sample rate of `lastPCMData` — currently always 16 kHz, but explicit so
    /// the consumer doesn't bake the constant in.
    public private(set) var lastSampleRate: Double?

    /// Wall-clock duration of the captured audio in seconds.
    public private(set) var lastDurationSecs: TimeInterval?

    // MARK: - Dependencies

    private let llmProvider: (any AIProvider)?
    private let llmModel: String
    private let maxDurationSeconds: Int
    private let logger: Logger?
    let eventHook: EventHook?
    let transcriber: Transcriber
    let paster: Paster
    /// Optional preflight check called at the start of `startRecording`.
    /// Returning `.micOwnedByActiveRecording` causes start to throw
    /// `DictationError.micOwnedByActiveRecording` so the caller can show a
    /// "another recording is using the mic" alert instead of fighting the
    /// active SCStream/AVAudioEngine for the HAL.
    let preflight: Preflight?

    /// Preflight outcome the pipeline can act on. We deliberately keep this
    /// coarse — "ok" or "refuse" — so the caller's check doesn't leak its
    /// reason all the way into DictationKit.
    public enum PreflightResult: Sendable, Equatable {
        case ok
        case micOwnedByActiveRecording
    }
    public typealias Preflight = @Sendable () async -> PreflightResult

    // MARK: - Engine state (nonisolated storage via actor-hop-safe box)

    private var engineBox: EngineBox? = nil
    /// 5-second zero-frame watchdog. Lives inside the pipeline rather than
    /// at the call site so every caller (DictationState, PushToMarkdownState,
    /// AgentHotkeyState) fails loudly instead of silently pasting an empty
    /// transcript when the mic engine never delivers a frame.
    private var watchdogTask: Task<Void, Never>? = nil

    /// The URL of the live CAF audio file being written during the current
    /// recording. Non-nil between `startRecording()` and
    /// `stopAndProcess()` / `stopCapture()` / `cancel()`.
    /// The live-adapter path reads this immediately after `startRecording()`
    /// returns to attach the engine before any audio arrives.
    public var currentLiveAudioURL: URL? { engineBox?.liveAudioURL }

    /// Live mic-frame counter exposed for watchdog/UI use during a hold-to-talk
    /// session. Returns 0 when the engine isn't running. Lets the app layer
    /// detect "tap installed but no audio arriving" within a few seconds and
    /// surface a fail-loud error instead of pasting an empty transcript.
    public var liveSampleCount: Int { engineBox?.sampleCountSnapshot ?? 0 }

    // MARK: - Init

    /// Production initializer. Wraps `whisperProvider.transcribe` and the
    /// real `AccessibilityPaster.paste` in shim closures so the rest of the
    /// pipeline can run against either real or mocked stages without
    /// branching.
    public init(
        whisperProvider: WhisperProvider,
        llmProvider: (any AIProvider)?,
        llmModel: String = "claude-sonnet-4-6",
        maxDurationSeconds: Int,
        insertionStrategy: DictationInsertionStrategy = .clipboardSimulatedV,
        logger: Logger? = nil,
        eventHook: EventHook? = nil,
        preflight: Preflight? = nil
    ) {
        self.llmProvider = llmProvider
        self.llmModel = llmModel
        self.maxDurationSeconds = maxDurationSeconds
        self.logger = logger
        self.eventHook = eventHook
        self.transcriber = { url, cfg in
            try await whisperProvider.transcribe(audioFile: url, config: cfg)
        }
        let strategy = insertionStrategy
        self.paster = { text in
            AccessibilityPaster.paste(text, strategy: strategy)
        }
        self.preflight = preflight
    }

    /// Initializer that injects custom transcription / paste shims. Originally
    /// test-only (internal), now public so app-layer features like
    /// PushToMarkdownState and AgentHotkeyState can swap the paste step for
    /// their own sinks (save .md, launch agent, etc.) while reusing the
    /// dictation capture + transcribe + cleanup flow unchanged.
    public init(
        transcriber: @escaping Transcriber,
        paster: @escaping Paster,
        llmProvider: (any AIProvider)?,
        llmModel: String = "claude-sonnet-4-6",
        maxDurationSeconds: Int,
        logger: Logger? = nil,
        eventHook: EventHook? = nil,
        preflight: Preflight? = nil
    ) {
        self.llmProvider = llmProvider
        self.llmModel = llmModel
        self.maxDurationSeconds = maxDurationSeconds
        self.logger = logger
        self.eventHook = eventHook
        self.transcriber = transcriber
        self.paster = paster
        self.preflight = preflight
    }

    // MARK: - Signpost helpers

    /// Emit an `os_signpost` `.event` for the given stage and notify the
    /// optional in-process `EventHook`. Both fire synchronously so the test
    /// hook's timestamp matches the signpost timestamp within nanoseconds.
    func emit(_ stage: Stage) {
        let now = ContinuousClock.now
        Self.signposter.emitEvent(stage.signpostName)
        eventHook?(stage, now)
    }

    // MARK: - Public API

    /// Begin capturing microphone audio. Sets status = .recording.
    public func startRecording() async throws {
        guard status == .idle || status == .completed || {
            if case .failed = status { return true } else { return false }
        }() else { return }

        // refuse to start when the SCStream-mic path of an
        // active recording owns the audio HAL. Standing up a parallel
        // AVAudioEngine on the same HAL is exactly the multi-client failure
        // the always-on capture design forbids.
        if let preflight = preflight {
            let outcome = await preflight()
            if outcome == .micOwnedByActiveRecording {
                logger?("[DictationPipeline] preflight refused: mic owned by active recording")
                throw DictationError.micOwnedByActiveRecording
            }
        }

        // Wipe last-run capture so the consumer never sees stale data from a
        // previous press if startRecording is called twice without a stop.
        lastTranscript = nil
        lastPCMData = nil
        lastSampleRate = nil
        lastDurationSecs = nil

        emit(.captureStart)
        let box = EngineBox()
        try await box.start(maxSeconds: maxDurationSeconds)
        engineBox = box
        status = .recording
        logger?("[DictationPipeline] recording started")

        // shared mic-flow watchdog. If the engine delivers
        // zero frames in the first 5 s, abort loudly so the user sees an
        // error instead of having the eventual paste land an empty string.
        // Lives inside the pipeline so PushToMarkdownState and
        // AgentHotkeyState — neither of which installed their own watchdog
        // historically — get the protection for free.
        watchdogTask?.cancel()
        let pipelineRef = self
        let boxRef = box
        watchdogTask = Task { @MainActor [weak pipelineRef] in
            try? await Task.sleep(for: .seconds(5))
            if Task.isCancelled { return }
            guard let p = pipelineRef else { return }
            // Only fire if we're still in the .recording state — the
            // caller may have already released and moved past us.
            guard p.status == .recording else { return }
            if boxRef.sampleCountSnapshot == 0 {
                p.logger?("[DictationPipeline] watchdog: 5 s with zero mic frames — aborting")
                await p.failWatchdog()
            }
        }
    }

    /// Internal: called by the mic-flow watchdog when the 5 s grace window
    /// elapses with zero mic frames. Tears the engine down and flips status
    /// to .failed so the caller's status switch surfaces an error rather
    /// than the empty-transcript paste.
    func failWatchdog() async {
        if let box = engineBox {
            engineBox = nil
            _ = await box.stop()
        }
        watchdogTask = nil
        status = .failed("Microphone not delivering audio. Check System Settings → Sound → Input.")
    }

    /// Stop capture, transcribe, optionally clean with LLM, paste. Updates status throughout.
    public func stopAndProcess() async {
        guard status == .recording, let box = engineBox else { return }
        engineBox = nil
        watchdogTask?.cancel()
        watchdogTask = nil

        // Encode captured PCM to a temp WAV file
        let pcmData = await box.stop()
        guard !pcmData.isEmpty else {
            status = .failed("No audio captured")
            logger?("[DictationPipeline] no audio data")
            return
        }

        let sampleRate: Double = 16_000
        // Stash for app-layer persistence even when later stages fail. Duration
        // is samples/sec — Float32 mono so each sample is 4 bytes.
        let frameCount = pcmData.count / MemoryLayout<Float>.size
        lastPCMData = pcmData
        lastSampleRate = sampleRate
        lastDurationSecs = TimeInterval(frameCount) / sampleRate

        guard let wavURL = writeTempWAV(pcmData: pcmData, sampleRate: sampleRate) else {
            status = .failed("Could not encode audio")
            return
        }
        emit(.encodeDone)
        defer { try? FileManager.default.removeItem(at: wavURL) }

        // Transcribe
        status = .transcribing
        logger?("[DictationPipeline] transcribing")
        let transcript: String
        do {
            emit(.uploadIssued)
            let result = try await transcriber(
                wavURL,
                TranscriptionConfig(language: nil, sampleRate: Int(sampleRate))
            )
            emit(.transcriptFinal)
            transcript = result.text.trimmingCharacters(in: .whitespacesAndNewlines)
        } catch {
            status = .failed("Transcription failed: \(error.localizedDescription)")
            logger?("[DictationPipeline] transcription error: \(error)")
            return
        }
        guard !transcript.isEmpty else {
            status = .failed("Empty transcript")
            return
        }

        // Optional LLM cleanup
        var finalText = transcript
        if let llm = llmProvider {
            status = .cleaning
            logger?("[DictationPipeline] LLM cleanup")
            let context = AppContextDetector.detect()
            let prompt = cleanupPrompt(transcript: transcript, context: context)
            let config = AIConfig(
                model: llmModel,
                temperature: 0.2,
                maxTokens: 1024,
                systemPrompt: nil
            )
            do {
                let cleaned = try await llm.chat(
                    messages: [ChatMessage(role: .user, content: prompt)],
                    config: config
                )
                let trimmed = cleaned.trimmingCharacters(in: .whitespacesAndNewlines)
                if !trimmed.isEmpty { finalText = trimmed }
            } catch {
                // LLM cleanup failure is non-fatal — fall back to raw transcript
                logger?("[DictationPipeline] LLM cleanup failed (non-fatal): \(error)")
            }
            // Emit even on non-fatal cleanup failure so per-run signpost
            // counts stay stable when cleanup is enabled.
            emit(.llmCleanupFinal)
        }

        // Stash final transcript for app-layer persistence regardless of paste outcome.
        lastTranscript = finalText

        // Paste
        status = .pasting
        logger?("[DictationPipeline] pasting")
        emit(.pasteIssued)
        let pasteResult = paster(finalText)
        switch pasteResult {
        case .clipboardSimulatedV, .clipboardOnly:
            // clipboardOnly is a successful outcome — text reached the
            // clipboard, the user just pastes it manually. The pipeline
            // status doesn't distinguish; the app layer can read
            // `lastResult` and surface a "copied to clipboard" toast.
            status = .completed
            logger?("[DictationPipeline] completed via \(pasteResult)")
        case .failed(let reason):
            status = .failed("Paste failed: \(reason)")
            logger?("[DictationPipeline] paste failed: \(reason)")
        }
    }

    /// Abort capture without processing.
    public func cancel() async {
        watchdogTask?.cancel()
        watchdogTask = nil
        if let box = engineBox {
            engineBox = nil
            _ = await box.stop()
        }
        status = .idle
        logger?("[DictationPipeline] cancelled")
    }

    /// Stop capture and store PCM for persistence without running transcription.
    ///
    /// Called by the live-adapter path instead of `stopAndProcess()`.
    /// Sets `lastPCMData`, `lastSampleRate`, `lastDurationSecs` so the app
    /// layer can persist the session after the live engine finishes.
    /// The live audio CAF file is closed and flushed when this returns.
    public func stopCapture() async {
        guard status == .recording, let box = engineBox else { return }
        engineBox = nil
        watchdogTask?.cancel()
        watchdogTask = nil
        let pcmData = await box.stop()
        guard !pcmData.isEmpty else {
            status = .failed("No audio captured")
            logger?("[DictationPipeline] stopCapture: no audio data")
            return
        }
        let sampleRate: Double = 16_000
        let frameCount = pcmData.count / MemoryLayout<Float>.size
        lastPCMData = pcmData
        lastSampleRate = sampleRate
        lastDurationSecs = TimeInterval(frameCount) / sampleRate
        status = .idle
        logger?("[DictationPipeline] stopCapture: audio stored (\(frameCount) frames)")
    }

    // MARK: - Private: LLM prompt

    private func cleanupPrompt(transcript: String, context: DictationContext) -> String {
        """
        You are a dictation cleanup assistant. The user just dictated raw transcribed \
        text. Clean it up: fix punctuation, capitalisation, paragraph breaks, common \
        speech artifacts ("um", "you know"). DO NOT add meaning or change wording. \
        Output ONLY the cleaned text — no preamble, no explanation.

        Application context: \(context.rawValue)
        Context-specific formatting: \(context.contextSpecificFormatting)

        Raw transcript:
        \(transcript)
        """
    }

    // MARK: - Private: WAV encoding

    private func writeTempWAV(pcmData: Data, sampleRate: Double) -> URL? {
        let frameCount = pcmData.count / MemoryLayout<Float>.size
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("dictation_\(UUID().uuidString).wav")

        guard let format = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: sampleRate,
            channels: 1,
            interleaved: false
        ) else { return nil }

        guard let file = try? AVAudioFile(forWriting: url, settings: format.settings) else {
            return nil
        }

        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(frameCount)) else {
            return nil
        }
        buffer.frameLength = AVAudioFrameCount(frameCount)

        pcmData.withUnsafeBytes { rawPtr in
            guard let floatPtr = rawPtr.bindMemory(to: Float.self).baseAddress,
                  let channelData = buffer.floatChannelData else { return }
            channelData[0].update(from: floatPtr, count: frameCount)
        }

        do {
            try file.write(from: buffer)
        } catch {
            return nil
        }
        return url
    }
}

// MARK: - EngineBox

/// Non-isolated box that owns AVAudioEngine state so it can cross MainActor boundaries.
@available(macOS 14.0, *)
private final class EngineBox: @unchecked Sendable {

    private let engine = AVAudioEngine()
    private var samples: [Float] = []
    private var maxFrames: Int = 0
    private let lock = NSLock()

    /// Live CAF file written in parallel with the PCM accumulation.
    /// Protected by `lock` — set before the tap fires, cleared in `stop()`.
    private var liveCAFFile: AVAudioFile?

    /// URL of the live CAF file. Set once in `start()` before the tap fires;
    /// not mutated thereafter. Safe to read from the main actor between
    /// `start()` and `stop()` without locking.
    private(set) var liveAudioURL: URL?

    /// Snapshot of the current sample count for the watchdog. Lock-guarded.
    var sampleCountSnapshot: Int {
        lock.withLock { samples.count }
    }

    // 16 kHz mono Float32 — Whisper's preferred format
    private static let sampleRate: Double = 16_000

    func start(maxSeconds: Int) async throws {
        maxFrames = Int(Self.sampleRate) * maxSeconds
        samples.reserveCapacity(maxFrames)

        let inputNode = engine.inputNode
        let inputFormat = inputNode.outputFormat(forBus: 0)

        guard let tapFormat = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: Self.sampleRate,
            channels: 1,
            interleaved: true
        ) else { throw DictationError.formatCreationFailed }

        // Open a live CAF file in tapFormat so the LiveTranscriptEngine can
        // read time windows from it while recording is in progress.
        // CAF is the only Apple-managed container that accepts arbitrary PCM
        // (Float32, interleaved, 16 kHz mono) without resampling.
        // NOTE: interleaved is chosen over non-interleaved because
        // AVAssetExportSession used by LiveWindowExporter may reject
        // non-interleaved PCM input.
        let cafURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("dictation_live_\(UUID().uuidString).caf")
        if let cafFile = try? AVAudioFile(forWriting: cafURL, settings: tapFormat.settings) {
            lock.withLock { liveCAFFile = cafFile }
            liveAudioURL = cafURL
        }

        let converter: AVAudioConverter?
        if inputFormat.sampleRate != Self.sampleRate || inputFormat.channelCount != 1 {
            converter = AVAudioConverter(from: inputFormat, to: tapFormat)
        } else {
            converter = nil
        }

        let bufferSize: AVAudioFrameCount = 1600  // 100 ms @ 16 kHz
        let maxF = maxFrames
        let inputSR = inputFormat.sampleRate

        if let conv = converter {
            let convRef = conv
            inputNode.installTap(onBus: 0, bufferSize: bufferSize, format: inputFormat) { [weak self] buffer, _ in
                guard let self else { return }
                let cap = AVAudioFrameCount(Double(buffer.frameLength) * Self.sampleRate / inputSR) + 1
                guard let converted = AVAudioPCMBuffer(pcmFormat: tapFormat, frameCapacity: max(1, cap)) else { return }
                var err: NSError?
                let src = buffer
                let status = convRef.convert(to: converted, error: &err) { _, outStatus in
                    outStatus.pointee = .haveData
                    return src
                }
                if status != .error, converted.frameLength > 0 {
                    self.accumulateSamples(converted, max: maxF)
                }
            }
        } else {
            inputNode.installTap(onBus: 0, bufferSize: bufferSize, format: tapFormat) { [weak self] buffer, _ in
                self?.accumulateSamples(buffer, max: maxF)
            }
        }

        // engine.start() can throw on permission denial / no input device.
        // The tap is already installed on inputNode at this point — without
        // explicit cleanup the AVAudioEngine retains the tap until the engine
        // itself is deallocated. Removing it before re-throw is the only path
        // that doesn't leak the tap callback closure (which captures self).
        do {
            try engine.start()
        } catch {
            engine.inputNode.removeTap(onBus: 0)
            lock.withLock { liveCAFFile = nil }
            if let url = liveAudioURL {
                try? FileManager.default.removeItem(at: url)
                liveAudioURL = nil
            }
            throw error
        }
    }

    func stop() async -> Data {
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        let captured: [Float] = lock.withLock {
            let snapshot = samples
            samples = []
            // Explicit close() before nil ensures the CAF header is updated
            // with the final data size and all buffered writes are flushed.
            // ARC-triggered close on deinit is documented to flush, but an
            // explicit call removes room for race conditions when the
            // LiveTranscriptEngine opens the file immediately after.
            liveCAFFile = nil
            return snapshot
        }
        var data = Data(count: captured.count * MemoryLayout<Float>.size)
        data.withUnsafeMutableBytes { rawPtr in
            guard let dst = rawPtr.bindMemory(to: Float.self).baseAddress else { return }
            dst.update(from: captured, count: captured.count)
        }
        return data
    }

    private func accumulateSamples(_ buffer: AVAudioPCMBuffer, max maxF: Int) {
        guard let channelData = buffer.floatChannelData else { return }
        let count = Int(buffer.frameLength)
        lock.lock()
        let remaining = maxF - samples.count
        guard remaining > 0 else { lock.unlock(); return }
        let take = min(count, remaining)
        samples.append(contentsOf: UnsafeBufferPointer(start: channelData[0], count: take))
        try? liveCAFFile?.write(from: buffer)  // non-fatal; keep recording even if write fails
        lock.unlock()
    }
}

// MARK: - Errors

public enum DictationError: Error, LocalizedError, Sendable {
    case formatCreationFailed
    /// Returned from `startRecording` when the preflight closure reports
    /// that an active recording owns the mic HAL via SCStream. Stops
    /// dictation from standing up a second AVAudioEngine on the same HAL
    /// (invariant I3).
    case micOwnedByActiveRecording

    public var errorDescription: String? {
        switch self {
        case .formatCreationFailed:
            return "Could not create AVAudioFormat for PCM source"
        case .micOwnedByActiveRecording:
            return "Microphone is in use by an active recording. Stop the recording, then try dictation again."
        }
    }
}

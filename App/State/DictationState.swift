@preconcurrency import AVFoundation
import Foundation
import Observation
import os
import DictationKit
import TranscriptionKit
import StorageKit
import AIKit

private let dictationLog = Logger(subsystem: "dev.kosmonotes.studio", category: "Dictation")

// MARK: - DictationState

/// When `sessionStore` is provided, every successful dictation is persisted
/// into the Library as a `mode = .dictation` SessionRecord with audio.m4a +
/// transcript.txt + transcript.jsonl.
@available(macOS 14.0, *)
@Observable
@MainActor
final class DictationState {

    enum UIStatus: Equatable, Sendable {
        case idle
        case recording
        case processing
        case completed
        case failed(String)
    }

    // MARK: - Observable

    var uiStatus: UIStatus = .idle
    var lastResult: String?

    // MARK: - Dependencies

    private let settings: AppSettings
    private let sessionStore: SessionStore?
    /// Weak reference to the meeting recorder so the dictation preflight can
    /// refuse to start a parallel AVAudioEngine while an active recording
    /// owns the mic HAL (invariant I3).
    private weak var recorder: RecorderState?
    private var pipeline: DictationPipeline?
    private var liveAdapter: HoldToTalkLiveAdapter?
    private let installer = TriggerHotkeyInstaller(comboName: .dictation, label: "Dictation")
    /// NotificationCenter token observing AppSettings.dictationTriggerDidChange,
    /// so a Settings change re-registers the hotkey live.
    private var triggerChangeObserver: NSObjectProtocol?
    // MARK: - Init

    init(
        settings: AppSettings,
        sessionStore: SessionStore? = nil,
        recorder: RecorderState? = nil
    ) {
        self.settings = settings
        self.sessionStore = sessionStore
        self.recorder = recorder
    }

    // MARK: - Public API

    /// Wire up the hotkey monitor + a Settings change observer so picking a
    /// different trigger in Settings → Dictation takes effect without relaunch.
    func install() {
        installer.install(
            trigger: settings.dictationTrigger,
            onPress: { [weak self] in
                Task { @MainActor [weak self] in await self?.handlePress() }
            },
            onRelease: { [weak self] in
                Task { @MainActor [weak self] in await self?.handleRelease() }
            }
        )
        triggerChangeObserver = NotificationCenter.default.addObserver(
            forName: AppSettings.dictationTriggerDidChange,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.installer.reinstall(
                    trigger: self.settings.dictationTrigger,
                    onPress: { [weak self] in
                        Task { @MainActor [weak self] in await self?.handlePress() }
                    },
                    onRelease: { [weak self] in
                        Task { @MainActor [weak self] in await self?.handleRelease() }
                    }
                )
            }
        }
    }

    /// Remove hotkey callbacks and stop observing trigger-change notifications.
    func uninstall() {
        installer.uninstall()
        if let token = triggerChangeObserver {
            NotificationCenter.default.removeObserver(token)
            triggerChangeObserver = nil
        }
    }

    // MARK: - Private

    private func handlePress() async {
        dictationLog.info("Dictation.handlePress: hotkey fired")
        // Snapshot the live config to logs every press so we can correlate the
        // configured insertion strategy / LLM cleanup state with whatever the
        // user observes (text appearing or not, latency, paste target).
        settings.logSnapshot(context: "before-dictation")
        // Pre-flight: Accessibility permission. Without it, the cleaned transcript
        // can't be pasted into the focused text field. Surface a modal pointing
        // at System Settings → Privacy → Accessibility and reminding the user that
        // AX trust only refreshes on relaunch.
        if !PermissionsHelper.accessibilityGranted() {
            dictationLog.error("Dictation.handlePress: Accessibility not granted — showing alert")
            PermissionsHelper.showMissingAlert(.accessibility)
            uiStatus = .failed("Accessibility access required. Grant in System Settings, then quit and relaunch KosmoNotes.")
            return
        }

        // Rebuild the pipeline on every press so settings changes apply.
        do {
            pipeline = try makePipeline()
        } catch {
            dictationLog.error("Dictation.handlePress: makePipeline threw — \(error.localizedDescription, privacy: .public)")
            uiStatus = .failed(error.localizedDescription)
            return
        }
        guard let p = pipeline else { return }
        do {
            try await p.startRecording()
            uiStatus = .recording
            dictationLog.info("Dictation.handlePress: recording started")
        } catch {
            dictationLog.error("Dictation.handlePress: startRecording threw — \(error.localizedDescription, privacy: .public)")
            uiStatus = .failed("Could not start dictation: \(error.localizedDescription)")
            return
        }

        // Zero-frame mic-flow protection lives inside DictationPipeline
        // (pipeline-internal 5 s watchdog → status = .failed), so
        // PushToMarkdownState gets it for free.
        // handleRelease surfaces that .failed status to the user.

        // Wire a live adapter if the current transcription provider supports it.
        // When available, handleRelease will use the adapter path instead of the
        // batch DictationPipeline path — no double-transcription.
        if let liveURL = p.currentLiveAudioURL,
           let liveProvider = settings.makeLiveProvider() {
            let engine = LiveTranscriptEngine(provider: liveProvider, exporter: LiveWindowExporter())
            await engine.attach(audioFile: liveURL)
            liveAdapter = HoldToTalkLiveAdapter(
                engine: engine,
                configSource: { [settings = self.settings] in
                    TranscriptionConfig(language: nil, sampleRate: 16_000)
                },
                sink: { [weak self] text in
                    await self?.handleLiveFinalTranscript(text)
                }
            )
            dictationLog.info("Dictation.handlePress: live adapter armed (\(String(describing: type(of: liveProvider)), privacy: .public))")
        }
    }

    private func handleRelease() async {
        dictationLog.info("Dictation.handleRelease: hotkey released — processing")
        guard let p = pipeline else {
            dictationLog.error("Dictation.handleRelease: no active pipeline (press did not register?)")
            return
        }

        // Live path: stop the engine (closes + flushes the CAF), then let the
        // live adapter transcribe the closed file. Mutually exclusive with the
        // batch path — avoids double-transcription.
        if let adapter = liveAdapter {
            liveAdapter = nil
            await p.stopCapture()    // closes CAF; stores PCM/sampleRate/duration for persistence
            uiStatus = .processing
            await adapter.stopAndFlush()  // → handleLiveFinalTranscript (sets uiStatus, pastes, persists)
            // If the adapter didn't call sink (didFlush == false), the
            // transcript is empty or an error occurred — surface it rather
            // than leaving uiStatus stuck at .processing.
            if !adapter.didFlush {
                let reason: String
                if let err = adapter.lastFlushError {
                    reason = err.localizedDescription
                } else if case .failed(let msg) = adapter.health {
                    reason = msg
                } else {
                    reason = "No audio captured or transcription produced empty result"
                }
                dictationLog.error("Dictation.handleRelease: live adapter produced no text — \(reason, privacy: .public)")
                uiStatus = .failed(reason)
                // Still try to persist the audio-only session.
                await persistIfPossible(pipeline: p, status: .failed)
            }
            return
        }

        // Batch path (original flow).
        uiStatus = .processing
        await p.stopAndProcess()
        switch p.status {
        case .completed:
            uiStatus = .completed
            lastResult = p.lastTranscript
            dictationLog.info("Dictation.handleRelease: pipeline completed — text pasted")
            await persistIfPossible(pipeline: p, status: .complete)
        case .failed(let msg):
            uiStatus = .failed(msg)
            dictationLog.error("Dictation.handleRelease: pipeline failed — \(msg, privacy: .public)")
            // Persist whatever we got — failed sessions are still useful in
            // Library if at least the audio + a partial transcript made it.
            await persistIfPossible(pipeline: p, status: .failed)
        default:
            uiStatus = .idle
            dictationLog.info("Dictation.handleRelease: pipeline ended in unexpected state \(String(describing: p.status), privacy: .public)")
        }
    }

    private func makePipeline() throws -> DictationPipeline {
        let key = settings.openaiApiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty else {
            throw DictationSetupError.missingAPIKey("Configure OpenAI key for dictation")
        }
        let whisper = WhisperProvider(apiKey: key, model: settings.openaiTranscribeModel.rawValue)

        // LLM provider + per-provider model. The pipeline used to hardcode
        // claude-sonnet-4-6 in its AIConfig, so cleanup tied to OpenAI / Ollama
        // / OpenRouter would either reject the model or silently fall back to
        // raw transcript. AIProviderResolver picks the right default per
        // provider so the configured provider actually runs cleanup with a
        // model it understands.
        let resolved = AIProviderResolver.resolve(settings.aiProviderConfig)
        let llm: (any AIProvider)? = settings.dictationLLMCleanup ? resolved?.provider : nil
        let model = resolved?.model ?? ""
        let insertionStrategy = settings.dictationInsertion

        let preflight = Self.makePreflight(recorder: recorder)

        return DictationPipeline(
            transcriber: { url, cfg in
                try await whisper.transcribe(audioFile: url, config: cfg)
            },
            paster: { finalText in
                Self.pasteDictation(finalText, strategy: insertionStrategy)
            },
            llmProvider: llm,
            llmModel: model,
            maxDurationSeconds: settings.dictationMaxSeconds,
            preflight: preflight
        )
    }

    /// Build the HAL-ownership preflight closure for DictationPipeline.
    /// Returns `.micOwnedByActiveRecording` whenever a meeting/voice-note
    /// recording is in flight, regardless of OS version — running a parallel
    /// AVAudioEngine on the same mic HAL is the exact failure mode the
    /// always-on capture design forbids.
    static func makePreflight(recorder: RecorderState?) -> DictationPipeline.Preflight? {
        guard let recorder else { return nil }
        return { [weak recorder] in
            guard let recorder else { return .ok }
            // Only an in-flight *recording* owns the mic HAL. `.transcribing`
            // also reads as busy, but the capture session is torn down before
            // that status begins — blocking hold-to-talk for the whole
            // transcription window (minutes) was a false positive.
            let recording: Bool = await MainActor.run {
                if case .recording = recorder.status { return true }
                return false
            }
            return recording ? .micOwnedByActiveRecording : .ok
        }
    }

    /// Kept separate so the hold-to-talk live adapter can target the same
    /// downstream insertion step once DictationPipeline exposes live capture hooks.
    private nonisolated static func pasteDictation(
        _ text: String,
        strategy: DictationInsertionStrategy
    ) -> AccessibilityPaster.PasteResult {
        AccessibilityPaster.paste(text, strategy: strategy)
    }

    /// Downstream sink for the live-adapter path (called by HoldToTalkLiveAdapter.stopAndFlush).
    ///
    /// Runs the same optional LLM cleanup as the batch pipeline, then pastes
    /// and persists the session. The pipeline has already stored PCM data via
    /// `stopCapture()`, so `persistIfPossible` can write audio.m4a normally.
    private func handleLiveFinalTranscript(_ rawText: String) async {
        dictationLog.info("Dictation.handleLiveFinalTranscript: \(rawText.prefix(60), privacy: .public)…")
        var finalText = rawText

        // Optional LLM cleanup — same logic as DictationPipeline.stopAndProcess.
        if settings.dictationLLMCleanup,
           let resolved = AIProviderResolver.resolve(settings.aiProviderConfig) {
            let context = AppContextDetector.detect()
            let prompt = """
                You are a dictation cleanup assistant. The user just dictated raw \
                transcribed text. Clean it up: fix punctuation, capitalisation, \
                paragraph breaks, common speech artifacts ("um", "you know"). \
                DO NOT add meaning or change wording. Output ONLY the cleaned \
                text — no preamble, no explanation.

                Application context: \(context.rawValue)
                Context-specific formatting: \(context.contextSpecificFormatting)

                Raw transcript:
                \(rawText)
                """
            let config = AIConfig(
                model: resolved.model,
                temperature: 0.2,
                maxTokens: 1024,
                systemPrompt: nil
            )
            if let cleaned = try? await resolved.provider.chat(
                messages: [ChatMessage(role: .user, content: prompt)],
                config: config
            ) {
                let trimmed = cleaned.trimmingCharacters(in: .whitespacesAndNewlines)
                if !trimmed.isEmpty { finalText = trimmed }
            }
        }

        lastResult = finalText
        uiStatus = .completed
        _ = Self.pasteDictation(finalText, strategy: settings.dictationInsertion)
        dictationLog.info("Dictation.handleLiveFinalTranscript: pasted — persisting")

        if let p = pipeline {
            await persistIfPossible(pipeline: p, status: .complete, finalText: finalText)
        }
    }

    // MARK: - Persistence

    /// After stopAndProcess finishes (succeed or fail), copy the captured PCM
    /// + transcript out of the pipeline and into a new Library session.
    ///
    /// `finalText` overrides `p.lastTranscript` for the live-adapter path where
    /// LLM cleanup runs in `handleLiveFinalTranscript` rather than inside the
    /// pipeline itself.
    private func persistIfPossible(
        pipeline p: DictationPipeline,
        status: SessionStatus,
        finalText: String? = nil
    ) async {
        guard let store = sessionStore else { return }
        guard let pcm = p.lastPCMData,
              let sampleRate = p.lastSampleRate,
              let duration = p.lastDurationSecs else {
            dictationLog.info("Dictation.persist: no captured audio/duration — skipping")
            return
        }

        do {
            // 1. Reserve a SessionRecord. Mode = .dictation makes it filterable
            // in Library's Mode picker.
            let record = try await store.createSession(mode: .dictation, language: nil)
            let dir = await store.sessionDir(for: record.id)
            dictationLog.info("Dictation.persist: created session \(record.id, privacy: .public)")

            // 2. Encode PCM → AAC .m4a. Two-step (PCM → CAF → AVAssetExportSession)
            // because the direct AVAudioFile-with-AAC-settings path throws
            // CoreAudio '!dat' (560226676) on Float32 16 kHz mono in.
            let audioURL = dir.appendingPathComponent("audio.m4a")
            try await writeAACFile(pcmData: pcm, sampleRate: sampleRate, to: audioURL)

            // 3. Write transcript text + JSONL (single segment covering whole clip).
            let transcript = (finalText ?? p.lastTranscript ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            try writeTranscriptFiles(transcript: transcript, durationSecs: duration, sessionDir: dir)

            // 4. Index FTS so the dictation is searchable in Library.
            if !transcript.isEmpty {
                try await store.indexTranscript(sid: record.id, text: transcript)
            }

            // 5. Finalize: status=complete (or failed) + actual duration.
            _ = try await store.finalize(
                id: record.id,
                status: status,
                durationSecs: duration,
                enhancementStatus: .ok
            )
            dictationLog.info("Dictation.persist: \(record.id, privacy: .public) finalized as \(String(describing: status), privacy: .public) (\(String(format: "%.1f", duration))s)")
        } catch {
            dictationLog.error("Dictation.persist: failed — \(error.localizedDescription, privacy: .public)")
        }
    }

    /// Write the raw Float32 PCM as a mono AAC `.m4a` file.
    ///
    /// Two-step encode mirroring `RecoveryService.finalize` because direct
    /// AVAudioFile-with-AAC-settings throws CoreAudio error 560226676 ('!dat')
    /// in practice — its built-in resampler/encoder doesn't reliably accept
    /// Float32 16 kHz mono in.
    ///
    ///   1. AVAudioFile writes the PCM verbatim to a temp `.caf` (always
    ///      succeeds; CAF carries any PCM format unchanged).
    ///   2. AVAssetExportSession with `AVAssetExportPresetAppleM4A` re-encodes
    ///      the CAF as AAC m4a — same path the recovery service uses for
    ///      meeting audio.
    private func writeAACFile(pcmData: Data, sampleRate: Double, to url: URL) async throws {
        let frameCount = pcmData.count / MemoryLayout<Float>.size
        guard frameCount > 0 else { return }

        guard let pcmFormat = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: sampleRate,
            channels: 1,
            interleaved: false
        ) else {
            throw DictationPersistError.formatCreationFailed
        }

        // Step 1: dump PCM as a CAF file. CAF is the only Apple-managed
        // container that round-trips arbitrary PCM (Float32, non-interleaved,
        // any sample rate) without complaining.
        let cafURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("dictation_\(UUID().uuidString).caf")
        defer { try? FileManager.default.removeItem(at: cafURL) }

        let cafSettings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: sampleRate,
            AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 32,
            AVLinearPCMIsFloatKey: true,
            AVLinearPCMIsNonInterleaved: true,
        ]
        let cafFile = try AVAudioFile(forWriting: cafURL, settings: cafSettings)

        guard let buffer = AVAudioPCMBuffer(pcmFormat: pcmFormat, frameCapacity: AVAudioFrameCount(frameCount)) else {
            throw DictationPersistError.bufferCreationFailed
        }
        buffer.frameLength = AVAudioFrameCount(frameCount)
        pcmData.withUnsafeBytes { rawPtr in
            guard let floatPtr = rawPtr.bindMemory(to: Float.self).baseAddress,
                  let channelData = buffer.floatChannelData else { return }
            channelData[0].update(from: floatPtr, count: frameCount)
        }
        try cafFile.write(from: buffer)

        // Step 2: re-encode CAF → m4a via the export session. AppleM4A preset
        // is AAC-LC at 64 kbps stereo / 32 kbps mono — fine for dictation.
        let asset = AVURLAsset(url: cafURL)
        guard let exporter = AVAssetExportSession(
            asset: asset,
            presetName: AVAssetExportPresetAppleM4A
        ) else {
            throw DictationPersistError.exportSessionInitFailed
        }
        if FileManager.default.fileExists(atPath: url.path) {
            try? FileManager.default.removeItem(at: url)
        }
        exporter.outputURL = url
        exporter.outputFileType = .m4a

        try await runExport(exporter, outputURL: url)
    }

    /// Mirror of `RecoveryService.runExport` — drives the legacy callback API
    /// to completion via a checked continuation. The newer
    /// `AVAssetExportSession.export(to:as:)` async overload exists on macOS 15+;
    /// using the callback path keeps us source-compatible at 14.
    private nonisolated func runExport(_ exporter: AVAssetExportSession, outputURL: URL) async throws -> URL {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<URL, Error>) in
            exporter.exportAsynchronously {
                switch exporter.status {
                case .completed:
                    continuation.resume(returning: outputURL)
                case .failed, .cancelled:
                    let err = exporter.error ?? NSError(
                        domain: "DictationState",
                        code: -1,
                        userInfo: [NSLocalizedDescriptionKey: "AVAssetExportSession ended in \(exporter.status.rawValue)"]
                    )
                    continuation.resume(throwing: err)
                default:
                    continuation.resume(throwing: NSError(
                        domain: "DictationState",
                        code: -2,
                        userInfo: [NSLocalizedDescriptionKey: "Unexpected exporter status \(exporter.status.rawValue)"]
                    ))
                }
            }
        }
    }

    /// Write transcript.txt + transcript.jsonl matching the meeting/voice-note
    /// session layout. Even though dictation has no fine-grained segmentation,
    /// emitting a single JSONL row keeps the Library detail view code path the
    /// same as for meetings.
    private func writeTranscriptFiles(transcript: String, durationSecs: TimeInterval, sessionDir: URL) throws {
        let txtURL = sessionDir.appendingPathComponent("transcript.txt")
        try transcript.write(to: txtURL, atomically: true, encoding: .utf8)

        guard !transcript.isEmpty else { return }
        // Single "whole-clip" segment — Whisper batch doesn't return per-word
        // timings here, so confidence is 1.0 and we cover [0, durationSecs).
        let segment = TranscriptSegment(
            start: 0,
            end: durationSecs,
            text: transcript,
            confidence: 1.0,
            isFinal: true
        )
        let encoder = JSONEncoder()
        let data = try encoder.encode(segment)
        let line = data + Data([0x0A])
        let jsonlURL = sessionDir.appendingPathComponent("transcript.jsonl")
        try line.write(to: jsonlURL, options: .atomic)
    }
}

// MARK: - Errors

private enum DictationSetupError: LocalizedError {
    case missingAPIKey(String)

    var errorDescription: String? {
        switch self {
        case .missingAPIKey(let msg): return msg
        }
    }
}

private enum DictationPersistError: LocalizedError {
    case formatCreationFailed
    case bufferCreationFailed
    case exportSessionInitFailed

    var errorDescription: String? {
        switch self {
        case .formatCreationFailed:    return "Could not create AVAudioFormat for PCM source"
        case .bufferCreationFailed:    return "Could not allocate PCM buffer for AAC encoding"
        case .exportSessionInitFailed: return "Could not create AVAssetExportSession for the captured CAF"
        }
    }
}

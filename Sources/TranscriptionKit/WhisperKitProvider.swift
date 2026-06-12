@preconcurrency import Foundation
@preconcurrency import WhisperKit
import os

private let whisperKitLog = Logger(subsystem: "dev.kosmonotes.studio", category: "WhisperKit")

// MARK: - WhisperKitProvider

/// On-device transcription via Argmax's WhisperKit (CoreML port of OpenAI
/// Whisper). Targets the Apple Neural Engine on Apple Silicon for ~real-time
/// performance — concrete numbers depend on the chosen model and chip.
///
/// The provider is intentionally lightweight to construct: the underlying
/// `WhisperKit` instance is loaded lazily on the first `transcribe(...)` call
/// because model load takes 1-10s depending on size. Subsequent calls reuse
/// the loaded instance until the actor is deallocated or `unload()` is called.
///
/// Models are NOT auto-downloaded by this provider. Callers must download them
/// up front (via `WhisperKit.download(variant:downloadBase:progressCallback:)`)
/// and persist into a stable folder; the provider is then constructed pointing
/// at that folder. This split lets the UI surface a "Download (123 MB)" button
/// with progress instead of letting transcription start a multi-GB download
/// without warning.
public actor WhisperKitProvider: BatchTranscriptionProvider {

    // MARK: - Public API

    /// Variant id (e.g. `"openai_whisper-large-v3-v20240930_626MB"` or
    /// `"openai_whisper-base"`). Must match a folder under `modelsRootDir`.
    public let modelVariant: String

    /// Root directory holding all downloaded WhisperKit model folders. The
    /// expected layout is `<modelsRootDir>/<modelVariant>/<*.mlmodelc>`.
    /// Pass the same root that `WhisperKit.download(downloadBase:)` was given.
    public let modelsRootDir: URL

    /// The loaded engine. Lazily populated on first transcribe. Cleared by
    /// `unload()`. Stored as `Any?` because `WhisperKit` itself is not
    /// `Sendable`-conforming and an actor can hold non-Sendable mutable state.
    private var engine: WhisperKit?
    private var loadTask: Task<WhisperKit, Error>?

    public init(modelVariant: String, modelsRootDir: URL) {
        self.modelVariant = modelVariant
        self.modelsRootDir = modelsRootDir
    }

    /// Drop the loaded engine to reclaim memory. Next transcribe reloads.
    public func unload() {
        loadTask?.cancel()
        loadTask = nil
        engine = nil
    }

    // MARK: - BatchTranscriptionProvider

    public func transcribe(audioFile: URL, config: TranscriptionConfig) async throws -> BatchTranscriptResult {
        let kit = try await ensureLoaded()

        let language = config.language?.lowercased()
        let usePrefill = (language != nil)
        let detect = (language == nil)
        let options = DecodingOptions(
            verbose: false,
            task: .transcribe,
            language: language,
            usePrefillPrompt: usePrefill,
            detectLanguage: detect,
            withoutTimestamps: false,
            wordTimestamps: false
        )

        whisperKitLog.info("WhisperKitProvider.transcribe: file=\(audioFile.lastPathComponent, privacy: .public) lang=\(language ?? "(auto)", privacy: .public) variant=\(self.modelVariant, privacy: .public)")
        let started = Date()

        let results: [TranscriptionResult]
        do {
            results = try await kit.transcribe(audioPath: audioFile.path, decodeOptions: options)
        } catch {
            whisperKitLog.error("WhisperKitProvider.transcribe: failed — \(error.localizedDescription, privacy: .public)")
            throw WhisperKitProviderError.transcriptionFailed(message: error.localizedDescription)
        }

        // Concatenate text + segments across the chunks WhisperKit emits when
        // the audio is longer than the 30-second window.
        let text = results.map { $0.text }
            .joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let detectedLanguage = results.first?.language

        var ourSegments: [TranscriptSegment] = []
        var maxEnd: Double = 0
        for result in results {
            for s in result.segments {
                let segText = s.text.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !segText.isEmpty else { continue }
                let start = TimeInterval(s.start)
                let end = TimeInterval(s.end)
                ourSegments.append(TranscriptSegment(
                    start: start,
                    end: end,
                    text: segText,
                    confidence: 1.0,
                    isFinal: true
                ))
                if end > maxEnd { maxEnd = end }
            }
        }
        // If the model didn't emit segments (rare — happens on very short
        // clips that don't cross any segment boundary), synthesize a single
        // [0, audioDuration) segment so the receiver still sees something.
        if ourSegments.isEmpty, !text.isEmpty {
            ourSegments.append(TranscriptSegment(
                start: 0,
                end: max(0.5, maxEnd),
                text: text,
                confidence: 1.0,
                isFinal: true
            ))
        }

        let elapsed = Date().timeIntervalSince(started)
        whisperKitLog.info("WhisperKitProvider.transcribe: done in \(String(format: "%.2f", elapsed), privacy: .public)s, segments=\(ourSegments.count, privacy: .public), chars=\(text.count, privacy: .public)")

        return BatchTranscriptResult(
            language: detectedLanguage,
            duration: maxEnd,
            segments: ourSegments,
            text: text
        )
    }

    // MARK: - LiveTranscriptionProvider

    /// Transcribe a short audio window for live display.
    ///
    /// This adapter calls the existing `transcribe(audioFile:config:)` method
    /// and converts the `BatchTranscriptResult` into a `LiveTranscriptWindowResult`
    /// with session-relative timestamps.
    public func transcribeLiveWindow(
        audioFile: URL,
        windowStart: TimeInterval,
        windowEnd: TimeInterval,
        config: TranscriptionConfig
    ) async throws -> LiveTranscriptWindowResult {
        let result = try await transcribe(audioFile: audioFile, config: config)
        return LiveTranscriptWindowResult(
            windowStart: windowStart,
            windowEnd: windowEnd,
            text: result.text,
            emittedAt: windowEnd
        )
    }

    // MARK: - Private

    private func ensureLoaded() async throws -> WhisperKit {
        if let engine { return engine }
        if let loadTask {
            return try await loadTask.value
        }

        let modelVariant = self.modelVariant
        let modelsRootDir = self.modelsRootDir
        let task = Task<WhisperKit, Error> {
            try await Self.loadEngine(modelVariant: modelVariant, modelsRootDir: modelsRootDir)
        }
        loadTask = task
        do {
            let kit = try await task.value
            engine = kit
            loadTask = nil
            return kit
        } catch {
            loadTask = nil
            throw error
        }
    }

    private static func loadEngine(modelVariant: String, modelsRootDir: URL) async throws -> WhisperKit {
        // The model folder produced by `WhisperKit.download` is
        // `<downloadBase>/argmaxinc/whisperkit-coreml/<variant>` (HuggingFace
        // snapshot layout). We let the user pass the **outer** root and resolve
        // the snapshot path here so the API surface stays simple.
        let candidatePaths: [URL] = [
            modelsRootDir.appendingPathComponent("argmaxinc/whisperkit-coreml/\(modelVariant)"),
            modelsRootDir.appendingPathComponent(modelVariant),
            modelsRootDir,
        ]
        let chosen = candidatePaths.first { url in
            FileManager.default.fileExists(atPath: url.path)
        } ?? modelsRootDir

        let cfg = WhisperKitConfig(
            model: modelVariant,
            downloadBase: modelsRootDir,
            modelFolder: chosen.path,
            verbose: false,
            logLevel: .error,
            prewarm: false,
            load: true,
            download: false
        )

        whisperKitLog.info("WhisperKitProvider.load: variant=\(modelVariant, privacy: .public) folder=\(chosen.path, privacy: .public)")
        let started = Date()
        do {
            let kit = try await WhisperKit(cfg)
            let elapsed = Date().timeIntervalSince(started)
            whisperKitLog.info("WhisperKitProvider.load: ready in \(String(format: "%.2f", elapsed), privacy: .public)s")
            return kit
        } catch {
            whisperKitLog.error("WhisperKitProvider.load: failed — \(error.localizedDescription, privacy: .public)")
            throw WhisperKitProviderError.loadFailed(message: error.localizedDescription)
        }
    }
}

// MARK: - LiveTranscriptionProvider conformance

extension WhisperKitProvider: LiveTranscriptionProvider {}

// MARK: - Errors

public enum WhisperKitProviderError: LocalizedError, Sendable {
    case loadFailed(message: String)
    case transcriptionFailed(message: String)

    public var errorDescription: String? {
        switch self {
        case .loadFailed(let m):           return "Could not load local Whisper model: \(m)"
        case .transcriptionFailed(let m):  return "Local Whisper transcription failed: \(m)"
        }
    }
}

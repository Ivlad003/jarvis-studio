import Foundation
import AIKit
import TranscriptionKit

// MARK: - AppSettings → Resolver configs

/// Bridges between `AppSettings`'s persisted enums (`LLMProviderChoice`,
/// `TranscriptionProviderChoice`, `OpenAITranscribeModel`, `OllamaAPIMode`) and
/// the resolver-internal mirrors in AIKit / TranscriptionKit. Kept in App-side
/// so AIKit / TranscriptionKit don't need to import AppSettings.
extension AppSettings {

    /// Snapshot of the current LLM-provider settings as a flat config the
    /// `AIProviderResolver` can consume. Each call site materializes this
    /// fresh so a setting change between calls is reflected.
    var aiProviderConfig: AIProviderResolver.Config {
        AIProviderResolver.Config(
            kind: aiResolverKind,
            anthropicAPIKey: anthropicApiKey,
            openaiAPIKey: openaiApiKey,
            openrouterAPIKey: openrouterApiKey,
            openrouterModel: openrouterModel,
            ollamaEndpoint: ollamaEndpoint,
            ollamaModel: ollamaModel,
            ollamaAPIMode: ollamaResolverMode,
            ollamaBearer: ollamaBearer
        )
    }

    /// Snapshot of the current transcription-provider settings.
    var transcriptionConfig: TranscriptionResolver.Config {
        TranscriptionResolver.Config(
            kind: txResolverKind,
            openaiAPIKey: openaiApiKey,
            openaiModel: txResolverOpenAIModel,
            deepgramAPIKey: deepgramApiKey,
            geminiAPIKey: geminiApiKey,
            openrouterAPIKey: openrouterApiKey,
            openrouterModel: openrouterModel,
            whisperKitVariant: whisperKitModel,
            whisperKitModelsRoot: AppSettings.whisperKitModelsRoot()
        )
    }

    /// Returns a `LiveTranscriptionProvider` for the current transcription
    /// settings, or `nil` if the selected provider doesn't support live
    /// window-based transcription.
    ///
    /// Only OpenAI Whisper and WhisperKit conform to `LiveTranscriptionProvider`.
    /// Deepgram / Gemini / OpenRouter use streaming APIs that are incompatible
    /// with the `LiveWindowExporter` batch-window model.
    func makeLiveProvider() -> (any LiveTranscriptionProvider)? {
        switch transcriptionProvider {
        case .openaiWhisper:
            let key = openaiApiKey.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !key.isEmpty else { return nil }
            return WhisperProvider(apiKey: key, model: openaiTranscribeModel.rawValue)
        case .whisperKit:
            let variant = whisperKitModel.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !variant.isEmpty else { return nil }
            return WhisperKitProvider(
                modelVariant: variant,
                modelsRootDir: AppSettings.whisperKitModelsRoot()
            )
        case .deepgram, .gemini, .openrouterAudio:
            return nil
        }
    }

    /// Returns a streaming live source for providers that can consume the
    /// recorder's live PCM tee directly.
    func makeStreamingLiveSource(hub: LiveTranscriptHub = LiveTranscriptHub()) -> StreamingLiveSource? {
        switch transcriptionProvider {
        case .deepgram:
            let key = deepgramApiKey.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !key.isEmpty else { return nil }
            return StreamingLiveSource.deepgram(apiKey: key, language: liveTranscriptionLanguage, hub: hub)
        case .openaiWhisper, .whisperKit, .gemini, .openrouterAudio:
            return nil
        }
    }

    // MARK: - Enum bridges

    private var liveTranscriptionLanguage: String? {
        let trimmed = summaryLanguage.trimmingCharacters(in: .whitespacesAndNewlines)
        return (trimmed.isEmpty || trimmed == "auto") ? nil : trimmed
    }

    private var aiResolverKind: AIProviderResolver.Kind {
        switch llmProvider {
        case .anthropic:  return .anthropic
        case .openai:     return .openai
        case .openrouter: return .openrouter
        case .ollama:     return .ollama
        }
    }

    private var ollamaResolverMode: OllamaProvider.APIMode {
        switch ollamaApiMode {
        case .native:           return .native
        case .openaiCompat:     return .openaiCompat
        case .anthropicCompat:  return .anthropicCompat
        }
    }

    private var txResolverKind: TranscriptionResolver.Kind {
        switch transcriptionProvider {
        case .deepgram:        return .deepgram
        case .openaiWhisper:   return .openaiWhisper
        case .gemini:          return .gemini
        case .openrouterAudio: return .openrouterAudio
        case .whisperKit:      return .whisperKit
        }
    }

    private var txResolverOpenAIModel: TranscriptionResolver.OpenAITranscribeModel {
        switch openaiTranscribeModel {
        case .whisper1:            return .whisper1
        case .gpt4oTranscribe:     return .gpt4oTranscribe
        case .gpt4oMiniTranscribe: return .gpt4oMiniTranscribe
        }
    }
}

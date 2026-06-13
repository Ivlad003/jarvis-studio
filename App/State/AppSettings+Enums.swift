import Foundation

// MARK: - AppSettings choice enums
//
// Pulled out of AppSettings.swift to keep the main file focused on storage,
// observable state, init, and Keychain plumbing. These types stay nested
// under `AppSettings` (callers continue to write `AppSettings.LLMProviderChoice`,
// `AppSettings.TranscriptionProviderChoice`, etc. — no source changes at any
// call site).

@available(macOS 14.0, *)
extension AppSettings {

    /// Keychain service-key identifiers. Raw values are the actual Keychain
    /// account names; changing one would orphan all existing entries.
    enum KeychainAccount: String, CaseIterable {
        case deepgram = "deepgram.api_key"
        case openaiWhisper = "openai.api_key"           // shared between Whisper transcription + GPT LLM
        case anthropic = "anthropic.api_key"
        case ollama = "ollama.bearer_token"             // optional; some self-hosted setups require auth
        case openrouter = "openrouter.api_key"
        // Google AI Studio key for Gemini multimodal audio transcription
        // (https://aistudio.google.com/apikey). Separate from any Vertex AI
        // service-account credentials.
        case gemini = "gemini.api_key"
        case s3AccessKey = "s3.access_key_id"
        case s3SecretKey = "s3.secret_access_key"
    }

    enum TranscriptionProviderChoice: String, CaseIterable, Identifiable {
        case deepgram
        case openaiWhisper
        case gemini
        case openrouterAudio
        /// On-device WhisperKit (CoreML port of Whisper). Free, private,
        /// requires a one-time model download per chosen variant.
        case whisperKit

        var id: String { rawValue }
        var displayName: String {
            switch self {
            case .deepgram: return "Deepgram"
            case .openaiWhisper: return "OpenAI Whisper"
            case .gemini: return "Gemini (multimodal)"
            case .openrouterAudio: return "OpenRouter (multimodal)"
            case .whisperKit: return "WhisperKit (on-device, free)"
            }
        }
    }

    /// Which OpenAI hosted speech-to-text model to use when the
    /// transcription provider is `.openaiWhisper`. Same `/v1/audio/transcriptions`
    /// endpoint, different `model` field. `whisper-1` is the legacy hosted
    /// Whisper-large-v2 model; the gpt-4o-transcribe family is OpenAI's
    /// newer (March 2025) successor with measurably lower WER.
    enum OpenAITranscribeModel: String, CaseIterable, Identifiable {
        case whisper1 = "whisper-1"
        case gpt4oTranscribe = "gpt-4o-transcribe"
        case gpt4oMiniTranscribe = "gpt-4o-mini-transcribe"

        var id: String { rawValue }
        var displayName: String {
            switch self {
            case .whisper1: return "whisper-1 (legacy Large-v2)"
            case .gpt4oTranscribe: return "gpt-4o-transcribe (highest accuracy)"
            case .gpt4oMiniTranscribe: return "gpt-4o-mini-transcribe (recommended)"
            }
        }
    }

    enum LLMProviderChoice: String, CaseIterable, Identifiable {
        case anthropic
        case openai
        case openrouter
        case ollama

        var id: String { rawValue }
        var displayName: String {
            switch self {
            case .anthropic: return "Anthropic Claude"
            case .openai: return "OpenAI"
            case .openrouter: return "OpenRouter"
            case .ollama: return "Ollama (local)"
            }
        }
    }

    enum OllamaAPIMode: String, CaseIterable, Identifiable {
        case native
        case openaiCompat
        case anthropicCompat

        var id: String { rawValue }
        var displayName: String {
            switch self {
            case .native: return "Native (/api/chat)"
            case .openaiCompat: return "OpenAI-compat (/v1/chat/completions)"
            case .anthropicCompat: return "Anthropic-compat (/v1/messages)"
            }
        }
    }

    /// Which backend drives the autonomous agent loop:
    ///   - `builtin`     → in-process Anthropic Messages API loop with bash/read/write tools (AgentRunner)
    ///   - `claudeCode`  → spawn `claude -p "<instruction>" --output-format stream-json --verbose` and stream stdout
    ///   - `codex`       → spawn `codex exec "<instruction>"` and stream stdout
    ///   - `copilot`     → spawn `gh copilot suggest -t shell "<instruction>"` (one-shot, no streaming loop)
    ///
    /// External CLIs run in the agent workspace folder as cwd; their own auth
    /// (claude.ai login, ChatGPT subscription, GitHub auth) is reused as-is.
    enum AgentBackendChoice: String, CaseIterable, Identifiable {
        case builtin
        case claudeCode
        case codex
        case copilot

        var id: String { rawValue }
        var displayName: String {
            switch self {
            case .builtin:    return "Built-in (Anthropic API)"
            case .claudeCode: return "Claude Code CLI"
            case .codex:      return "Codex CLI"
            case .copilot:    return "GitHub Copilot CLI"
            }
        }
    }

    /// Anthropic Claude model the *built-in* backend uses for the agent loop.
    /// External CLI backends pick their own model out-of-band (`claude` /
    /// `codex` / `gh copilot` honour their own config), so this only applies
    /// when `agentBackend == .builtin`.
    ///
    /// Defaults to Sonnet 4.6 — the current speed/cost/quality sweet spot for
    /// tool-using loops. Bump to Opus 4.7 for hard tasks; drop to Haiku 4.5
    /// for cheap exploratory runs.
    enum AgentBuiltinModel: String, CaseIterable, Identifiable {
        case opus47   = "claude-opus-4-7"
        case opus46   = "claude-opus-4-6"
        case sonnet46 = "claude-sonnet-4-6"
        case sonnet45 = "claude-sonnet-4-5"
        case haiku45  = "claude-haiku-4-5"

        var id: String { rawValue }
        var displayName: String {
            switch self {
            case .opus47:   return "Claude Opus 4.7 (highest quality, slowest, most expensive)"
            case .opus46:   return "Claude Opus 4.6 (previous opus — supports faster Fast Mode)"
            case .sonnet46: return "Claude Sonnet 4.6 (balanced — default)"
            case .sonnet45: return "Claude Sonnet 4.5 (previous sonnet — cheaper alternative)"
            case .haiku45:  return "Claude Haiku 4.5 (fastest, cheapest, smaller context)"
            }
        }
    }

    enum RecordingMode: String, CaseIterable, Identifiable {
        case audioOnly
        case audioAndScreen

        var id: String { rawValue }
        var displayName: String {
            switch self {
            case .audioOnly: return "Audio only"
            case .audioAndScreen: return "Audio + Screen"
            }
        }
    }

    /// Audio + video codec preset for new recordings. Each profile picks the
    /// codec, sample rate, and bitrate; the screen recorder reads `videoCodec`
    /// + `videoBitrate`, the audio capture stack reads `audioCodec` +
    /// `audioBitrate` + `audioSampleRate`.
    ///
    /// Storage savings (vs Quality, per hour of meeting + screen):
    ///   - Quality:   ~1.74 GB (H.264 4 Mbps + AAC-LC 96k @ 48 kHz)
    ///   - Balanced:  ~870 MB (HEVC 2 Mbps + HE-AAC 48k @ 48 kHz)  default
    ///   - Compact:   ~430 MB (HEVC 1.5 Mbps + Opus 32k @ 24 kHz)
    enum StorageProfile: String, CaseIterable, Identifiable {
        case quality
        case balanced
        case compact

        var id: String { rawValue }
        var displayName: String {
            switch self {
            case .quality:  return "Quality"
            case .balanced: return "Balanced"
            case .compact:  return "Compact"
            }
        }
        var summary: String {
            switch self {
            case .quality:  return "H.264 4 Mbps + AAC-LC 96 kbps @ 48 kHz · ~1.74 GB/h"
            case .balanced: return "HEVC 2 Mbps + HE-AAC 48 kbps @ 48 kHz · ~870 MB/h (-50%)"
            case .compact:  return "HEVC 1.5 Mbps + Opus 32 kbps @ 24 kHz · ~430 MB/h (-75%)"
            }
        }
    }

    /// Audio codec — derived from StorageProfile but overridable.
    /// `aac` = AAC-LC (legacy default), `heAAC` = HE-AAC v1, `opus` = Opus (14+).
    enum AudioCodec: String, CaseIterable, Identifiable {
        case aac
        case heAAC
        case opus

        var id: String { rawValue }
        var displayName: String {
            switch self {
            case .aac:   return "AAC-LC"
            case .heAAC: return "HE-AAC v1"
            case .opus:  return "Opus"
            }
        }
    }
}

import Foundation
import CoreGraphics
import AIKit
import DictationKit
@preconcurrency import KeychainAccess
import Observation
import os

private let appSettingsLog = Logger(subsystem: "dev.kosmonotes.studio", category: "AppSettings")

// MARK: - AppSettings
//
// Reads / writes user-configurable settings:
//   - API keys (Keychain-backed, never written to disk in plain text)
//   - default transcription provider, default summary language
//
// The Keychain service name is locked to the bundle ID per design §13 —
// changing it post-ship would orphan all existing entries.

@available(macOS 14.0, *)
@Observable
@MainActor
final class AppSettings {

    // Choice enums + KeychainAccount live in AppSettings+Enums.swift so the
    // main file stays focused on storage / observable state / init plumbing.

    // MARK: UserDefaults-backed prefs (non-secret)

    private enum Defaults {
        static let transcriptionProvider = "transcriptionProvider"
        static let llmProvider = "llmProvider"
        static let summaryLanguage = "summaryLanguage"
        static let recordingMode = "recordingMode"
        static let costCapUSD = "costCapUSD"
        static let ollamaEndpoint = "ollamaEndpoint"
        static let ollamaApiMode = "ollamaApiMode"
        static let ollamaModel = "ollamaModel"
        // ollamaBearer is Keychain-backed; this constant is the account name reference.
        static let ollamaBearer = "ollamaBearer"
        static let systemAudioEnabled = "systemAudioEnabled"
        static let echoCancellationEnabled = "echoCancellationEnabled"
        static let dictationLLMCleanup = "dictationLLMCleanup"
        // Three insertion strategies for the cleaned dictation transcript:
        //   - axapiThenClipboard (faster, less reliable in Electron)
        //   - clipboardSimulatedV (default — universal compatibility)
        //   - clipboardOnly (no auto-paste; user pastes manually)
        // Stored as the rawValue of `DictationInsertionStrategy`.
        static let dictationInsertion = "dictationInsertion"
        // Whether to run the meeting/voice-note transcript through an LLM cleanup
        // pass after Whisper/Deepgram. Reuses the configured llmProvider; default ON.
        static let transcriptCleanupEnabled = "transcriptCleanupEnabled"
        static let dictationMaxSeconds = "dictationMaxSeconds"
        // How the Dictation hotkey is delivered. JSON-encoded HotkeyTrigger
        // because the enum carries associated values (hold ms, etc) so a plain
        // raw-value can't round-trip it. Same JSON pattern for the parallel
        // Push-to-Markdown and Agent triggers.
        static let dictationTrigger = "dictationTrigger"
        static let pushToMarkdownTrigger = "pushToMarkdownTrigger"
        static let agentTrigger = "agentTriggerKind"  // "agentTrigger" is a KeyboardShortcuts.Name; rename here to avoid collision
        // Optional double-tap-modifier shortcut for the Library window. Stored
        // as the raw string of DoubleTapModifier; empty / missing = disabled.
        // The combo `.openLibrary` (default ⌘⇧L) stays wired regardless.
        static let libraryDoubleTapModifier = "libraryDoubleTapModifier"
        static let voiceNoteKind = "voiceNoteKind"
        static let openrouterModel = "openrouterModel"
        static let semanticSearchEnabled = "semanticSearchEnabled"
        // Per-process Core Audio Tap source (14.4+ only). When false (or on <14.4),
        // SCKit whole-system mixdown is used. When true on 14.4+, only the configured
        // bundle IDs are captured.
        static let useProcessTap = "useProcessTap"
        static let processTapBundleIDs = "processTapBundleIDs"
        // Custom Core Audio input device for system-audio capture (e.g. BlackHole 2ch).
        // Empty string = use SCKit whole-system mixdown (default behavior).
        static let systemAudioDeviceUID = "systemAudioDeviceUID"
        // Loom-style floating webcam bubble during Audio + Screen recordings.
        static let cameraBubbleEnabled = "cameraBubbleEnabled"
        static let cameraDeviceUID = "cameraDeviceUID"
        static let cameraBubblePositionX = "cameraBubblePositionX"
        static let cameraBubblePositionY = "cameraBubblePositionY"
        static let cameraBubbleSize = "cameraBubbleSize"
        static let screenCaptureDisplayID = "screenCaptureDisplayID"
        // Chat auto-frame sampling — when on, every chat message that
        // has an attached session with screen.mp4 gets N evenly-spaced
        // baseline frames added as vision context (in addition to any
        // timestamp-extracted frames).
        static let chatVideoAutoFramesEnabled = "chatVideoAutoFramesEnabled"
        static let chatVideoAutoFramesCount = "chatVideoAutoFramesCount"
        // Markdown export — at the end of every recording, run the cleaned
        // transcript through an LLM with the user-defined prompts and write
        // the result as a .md file at the chosen folder.
        static let markdownExportEnabled = "markdownExportEnabled"
        static let markdownExportFolder = "markdownExportFolder"
        static let markdownExportSystemPrompt = "markdownExportSystemPrompt"
        static let markdownExportUserPrompt = "markdownExportUserPrompt"
        // Push-to-Markdown — same hold-hotkey-and-talk pattern as Dictation,
        // but result is saved as a .md file (using the markdownExport*
        // prompts above) instead of pasted into the focused field.
        static let pushToMarkdownEnabled = "pushToMarkdownEnabled"
        // Autonomous agent — voice instruction → tool-using Claude loop.
        static let agentEnabled = "agentEnabled"
        static let agentSystemPrompt = "agentSystemPrompt"
        static let agentMaxIterations = "agentMaxIterations"
        static let agentWorkspaceFolder = "agentWorkspaceFolder"
        // Backend selector — built-in Anthropic-API loop, or spawn an
        // external CLI (Claude Code, Codex, GitHub Copilot).
        static let agentBackend = "agentBackend"
        // Claude model used by the *built-in* backend (Opus 4.7 / Sonnet 4.6
        // / Haiku 4.5). External CLI backends pick their own model.
        static let agentBuiltinModel = "agentBuiltinModel"
        static let agentClaudeCodeBin = "agentClaudeCodeBin"
        static let agentCodexBin = "agentCodexBin"
        static let agentCopilotBin = "agentCopilotBin"
        // S3 sharing
        static let s3Endpoint = "s3Endpoint"
        static let s3Region = "s3Region"
        static let s3Bucket = "s3Bucket"
        static let s3PresignTTLHours = "s3PresignTTLHours"
        // OpenAI speech-to-text model selection. Whisper-1 is the legacy
        // hosted Large-v2; gpt-4o-transcribe / gpt-4o-mini-transcribe are
        // OpenAI's newer (March 2025) higher-accuracy successors. Same
        // /v1/audio/transcriptions endpoint, different `model` field.
        static let openaiTranscribeModel = "openaiTranscribeModel"
        // WhisperKit (local) variant id, e.g. "openai_whisper-base". Empty
        // string means "user hasn't picked one yet" — the Settings UI guides
        // them to choose + download before they can switch the active provider.
        static let whisperKitModel = "whisperKitModel"
        // Storage profile + codec overrides
        static let storageProfile = "storageProfile"
        static let audioCodec = "audioCodec"
        static let audioBitrate = "audioBitrate"
        static let audioSampleRate = "audioSampleRate"
        static let videoUseHEVC = "videoUseHEVC"
        static let videoBitrate = "videoBitrate"
    }

    // MARK: Observable state — secrets read on demand from Keychain

    /// Mirror copies of the secrets so SwiftUI bindings have something to bind to.
    /// Saved to Keychain via `commit*` actions; never persisted to disk in plain text.
    var deepgramApiKey: String = ""
    var openaiApiKey: String = ""
    var anthropicApiKey: String = ""
    var ollamaBearer: String = ""   // optional bearer token for self-hosted Ollama frontends
    var openrouterApiKey: String = ""
    var geminiApiKey: String = ""
    var s3AccessKey: String = ""
    var s3SecretKey: String = ""

    /// Persistent UID of a custom Core Audio input device (e.g. BlackHole 2ch)
    /// used as the system-audio source instead of SCKit. Empty string = use
    /// SCKit whole-system mixdown (default). Set via Settings → Transcription.
    var systemAudioDeviceUID: String {
        didSet { UserDefaults.standard.set(systemAudioDeviceUID, forKey: Defaults.systemAudioDeviceUID) }
    }

    /// Preferred display ID for screen capture. `0` means auto / primary display.
    var screenCaptureDisplayID: UInt32 {
        didSet { UserDefaults.standard.set(Int(screenCaptureDisplayID), forKey: Defaults.screenCaptureDisplayID) }
    }

    /// Show a Loom-style floating webcam bubble during Audio + Screen recordings.
    /// When on, a circular always-on-top NSWindow with the front camera feed
    /// appears at the saved position; ScreenCaptureKit then captures it as
    /// part of `screen.mp4`. Off by default — opt-in.
    var cameraBubbleEnabled: Bool {
        didSet { UserDefaults.standard.set(cameraBubbleEnabled, forKey: Defaults.cameraBubbleEnabled) }
    }
    /// Persistent UID of the AVCaptureDevice the bubble should use (FaceTime,
    /// USB cam, Continuity Camera, etc). Empty string = system default.
    var cameraDeviceUID: String {
        didSet { UserDefaults.standard.set(cameraDeviceUID, forKey: Defaults.cameraDeviceUID) }
    }
    /// On-screen position of the bubble's bottom-left corner (Cocoa coords).
    /// Persisted across launches so the bubble reappears where the user left it.
    var cameraBubblePosition: CGPoint {
        didSet {
            UserDefaults.standard.set(Double(cameraBubblePosition.x), forKey: Defaults.cameraBubblePositionX)
            UserDefaults.standard.set(Double(cameraBubblePosition.y), forKey: Defaults.cameraBubblePositionY)
        }
    }
    /// Side length in points of the (square) bubble window. 200 default;
    /// clamped to [120, 500] in the window controller.
    var cameraBubbleSize: Double {
        didSet { UserDefaults.standard.set(cameraBubbleSize, forKey: Defaults.cameraBubbleSize) }
    }

    /// When ON, every Chat message with an attached session that has
    /// screen.mp4 gets N evenly-spaced baseline frames automatically
    /// added as vision context — without the user needing to type a
    /// timestamp. Lets the LLM "see" the whole video instead of just
    /// the moments the user explicitly asked about. Off by default
    /// (opt-in: more tokens cost more $).
    var chatVideoAutoFramesEnabled: Bool {
        didSet { UserDefaults.standard.set(chatVideoAutoFramesEnabled, forKey: Defaults.chatVideoAutoFramesEnabled) }
    }
    /// Number of evenly-spaced baseline frames to sample. Clamped 1–10
    /// in the UI; combined with timestamp-extracted frames the total is
    /// hard-capped (in ChatState) to keep request size reasonable.
    var chatVideoAutoFramesCount: Int {
        didSet { UserDefaults.standard.set(chatVideoAutoFramesCount, forKey: Defaults.chatVideoAutoFramesCount) }
    }

    /// When ON, every finished recording is also formatted into a custom
    /// `.md` file via the user-defined system + user prompts (below) and
    /// saved to `markdownExportFolder`. Independent of the built-in
    /// `summary.md` — that uses our PromptTemplates; this one is whatever
    /// the user wants ("turn into Notion-style notes", "extract action
    /// items as JIRA tickets", "translate to English while reformatting").
    var markdownExportEnabled: Bool {
        didSet { UserDefaults.standard.set(markdownExportEnabled, forKey: Defaults.markdownExportEnabled) }
    }
    /// Filesystem path where exported `.md` files land. Empty = use the
    /// default `~/Documents/KosmoNotes`. Stored as POSIX path string;
    /// MarkdownExporter creates the dir if missing.
    var markdownExportFolder: String {
        didSet { UserDefaults.standard.set(markdownExportFolder, forKey: Defaults.markdownExportFolder) }
    }
    /// System prompt for the Markdown export pass. Editable in Settings.
    /// Defaults to a meeting-formatter prompt; user can replace with
    /// anything (the LLM gets `system` + `user{transcript}` and returns
    /// the `.md` body).
    var markdownExportSystemPrompt: String {
        didSet { UserDefaults.standard.set(markdownExportSystemPrompt, forKey: Defaults.markdownExportSystemPrompt) }
    }
    /// User-prompt template. Must contain `{transcript}` — that token is
    /// substituted with the actual cleaned transcript before sending to
    /// the LLM. Default keeps it simple: "Here is the transcript: {transcript}".
    var markdownExportUserPrompt: String {
        didSet { UserDefaults.standard.set(markdownExportUserPrompt, forKey: Defaults.markdownExportUserPrompt) }
    }

    /// Push-to-Markdown toggle. When ON, the global hotkey
    /// `KeyboardShortcuts.Name.pushToMarkdown` (default ⌘⇧Y) records
    /// while held; on release the cleaned transcript runs through the
    /// same MarkdownExporter flow (markdownExport* prompts + folder)
    /// and a new `.md` file is written. Off by default.
    var pushToMarkdownEnabled: Bool {
        didSet { UserDefaults.standard.set(pushToMarkdownEnabled, forKey: Defaults.pushToMarkdownEnabled) }
    }

    /// Autonomous agent toggle. When ON, the global hotkey
    /// `KeyboardShortcuts.Name.agentTrigger` (default ⌘⇧A) is push-to-talk
    /// for an agent loop: hold it, speak an instruction, release. Whisper
    /// transcribes; AgentSessionState spawns a Claude tool-use loop with
    /// bash/read_file/write_file tools restricted to the workspace folder.
    var agentEnabled: Bool {
        didSet { UserDefaults.standard.set(agentEnabled, forKey: Defaults.agentEnabled) }
    }
    /// System prompt the agent runs with. User-editable in Settings → Agent.
    var agentSystemPrompt: String {
        didSet { UserDefaults.standard.set(agentSystemPrompt, forKey: Defaults.agentSystemPrompt) }
    }
    /// Hard cap on agent loop iterations — runaway protection. Default 12.
    /// Each iteration = one round-trip to Claude + zero or more tool runs.
    var agentMaxIterations: Int {
        didSet { UserDefaults.standard.set(agentMaxIterations, forKey: Defaults.agentMaxIterations) }
    }
    /// Workspace directory the agent's bash/read/write tools are restricted
    /// to. Empty → `~/Documents/KosmoNotes-agent` (auto-created on first run).
    var agentWorkspaceFolder: String {
        didSet { UserDefaults.standard.set(agentWorkspaceFolder, forKey: Defaults.agentWorkspaceFolder) }
    }
    /// Which backend drives the agent loop. `.builtin` keeps the Anthropic-API
    /// AgentRunner; the other three spawn an external CLI as a subprocess.
    var agentBackend: AgentBackendChoice {
        didSet { UserDefaults.standard.set(agentBackend.rawValue, forKey: Defaults.agentBackend) }
    }

    /// Claude model variant used by the *built-in* agent backend. External
    /// CLI backends ignore this — they have their own model selection.
    var agentBuiltinModel: AgentBuiltinModel {
        didSet { UserDefaults.standard.set(agentBuiltinModel.rawValue, forKey: Defaults.agentBuiltinModel) }
    }
    /// Absolute path to the `claude` binary (Claude Code CLI). Empty = use $PATH lookup.
    var agentClaudeCodeBin: String {
        didSet { UserDefaults.standard.set(agentClaudeCodeBin, forKey: Defaults.agentClaudeCodeBin) }
    }
    /// Absolute path to the `codex` binary (OpenAI Codex CLI). Empty = $PATH lookup.
    var agentCodexBin: String {
        didSet { UserDefaults.standard.set(agentCodexBin, forKey: Defaults.agentCodexBin) }
    }
    /// Absolute path to the `gh` binary (GitHub CLI w/ Copilot extension). Empty = $PATH lookup.
    var agentCopilotBin: String {
        didSet { UserDefaults.standard.set(agentCopilotBin, forKey: Defaults.agentCopilotBin) }
    }

    var transcriptionProvider: TranscriptionProviderChoice {
        didSet { UserDefaults.standard.set(transcriptionProvider.rawValue, forKey: Defaults.transcriptionProvider) }
    }

    /// Which OpenAI hosted speech-to-text model to use when
    /// `transcriptionProvider == .openaiWhisper`. Default is `gpt-4o-mini-transcribe`
    /// per OpenAI's own recommendation — newer than `whisper-1` (~4.1% WER vs 5.3%)
    /// and cheaper than `gpt-4o-transcribe`. User can switch in Settings → Transcription.
    var openaiTranscribeModel: OpenAITranscribeModel {
        didSet { UserDefaults.standard.set(openaiTranscribeModel.rawValue, forKey: Defaults.openaiTranscribeModel) }
    }
    /// On-device WhisperKit variant id (e.g. `"openai_whisper-base"`). Empty
    /// string until the user picks one. Read by `WhisperKitProvider` only when
    /// `transcriptionProvider == .whisperKit`.
    var whisperKitModel: String {
        didSet { UserDefaults.standard.set(whisperKitModel, forKey: Defaults.whisperKitModel) }
    }
    var llmProvider: LLMProviderChoice {
        didSet { UserDefaults.standard.set(llmProvider.rawValue, forKey: Defaults.llmProvider) }
    }
    /// BCP-47 code (e.g. "en", "uk", "auto"). "auto" = no override.
    var summaryLanguage: String {
        didSet { UserDefaults.standard.set(summaryLanguage, forKey: Defaults.summaryLanguage) }
    }
    /// Whether new recordings include screen capture alongside audio.
    var recordingMode: RecordingMode {
        didSet { UserDefaults.standard.set(recordingMode.rawValue, forKey: Defaults.recordingMode) }
    }

    /// Per-session AI summary cost cap in USD. Requests estimated above this are silently skipped.
    var costCapUSD: Double {
        didSet { UserDefaults.standard.set(costCapUSD, forKey: Defaults.costCapUSD) }
    }

    /// Base URL of the Ollama server (default: http://localhost:11434).
    var ollamaEndpoint: String {
        didSet { UserDefaults.standard.set(ollamaEndpoint, forKey: Defaults.ollamaEndpoint) }
    }
    /// API mode: native /api/chat, OpenAI-compat /v1/chat/completions, or Anthropic-compat /v1/messages.
    var ollamaApiMode: OllamaAPIMode {
        didSet { UserDefaults.standard.set(ollamaApiMode.rawValue, forKey: Defaults.ollamaApiMode) }
    }
    /// Default model name sent to Ollama (e.g. "qwen2.5:14b").
    var ollamaModel: String {
        didSet { UserDefaults.standard.set(ollamaModel, forKey: Defaults.ollamaModel) }
    }

    /// Capture system audio (SCKit mixdown) alongside the mic. Off by default —
    /// requires Screen Recording permission and captures whole-system audio.
    var systemAudioEnabled: Bool {
        didSet { UserDefaults.standard.set(systemAudioEnabled, forKey: Defaults.systemAudioEnabled) }
    }
    /// Apple voice-processing echo cancellation for speaker-based meetings.
    /// Default ON; users can disable it for high-fidelity ambient recording.
    var echoCancellationEnabled: Bool {
        didSet { UserDefaults.standard.set(echoCancellationEnabled, forKey: Defaults.echoCancellationEnabled) }
    }
    /// Run an LLM cleanup pass on the Whisper transcript before pasting (Dictation Mode).
    /// On = cleaner output, slower (extra round-trip). Off = paste raw transcript.
    var dictationLLMCleanup: Bool {
        didSet { UserDefaults.standard.set(dictationLLMCleanup, forKey: Defaults.dictationLLMCleanup) }
    }
    /// Strategy used by `AccessibilityPaster` to deliver the cleaned transcript.
    /// Default `.clipboardSimulatedV` — universal compatibility. See enum docs
    /// for the trade-offs.
    var dictationInsertion: DictationInsertionStrategy {
        didSet { UserDefaults.standard.set(dictationInsertion.rawValue, forKey: Defaults.dictationInsertion) }
    }
    /// Hard cap on a single Dictation utterance length, in seconds. Default 60.
    var dictationMaxSeconds: Int {
        didSet { UserDefaults.standard.set(dictationMaxSeconds, forKey: Defaults.dictationMaxSeconds) }
    }

    /// How the Dictation hotkey fires. Default `.combo` keeps the historical
    /// ⌘⇧D shortcut wired through `KeyboardShortcuts`. `.holdKey` and
    /// `.doubleTapModifier` route through `KeyTriggerEngine` (CGEventTap +
    /// Accessibility permission).
    var dictationTrigger: HotkeyTrigger {
        didSet {
            if let data = try? JSONEncoder().encode(dictationTrigger) {
                UserDefaults.standard.set(data, forKey: Defaults.dictationTrigger)
            }
            NotificationCenter.default.post(name: AppSettings.dictationTriggerDidChange, object: nil)
        }
    }

    /// Same shape as `dictationTrigger`, for the Push-to-Markdown hotkey.
    var pushToMarkdownTrigger: HotkeyTrigger {
        didSet {
            if let data = try? JSONEncoder().encode(pushToMarkdownTrigger) {
                UserDefaults.standard.set(data, forKey: Defaults.pushToMarkdownTrigger)
            }
            NotificationCenter.default.post(name: AppSettings.pushToMarkdownTriggerDidChange, object: nil)
        }
    }

    /// Same shape as `dictationTrigger`, for the autonomous-agent hotkey.
    var agentTrigger: HotkeyTrigger {
        didSet {
            if let data = try? JSONEncoder().encode(agentTrigger) {
                UserDefaults.standard.set(data, forKey: Defaults.agentTrigger)
            }
            NotificationCenter.default.post(name: AppSettings.agentTriggerDidChange, object: nil)
        }
    }

    /// Optional double-tap-modifier shortcut for opening the Library window.
    /// `nil` = feature disabled; only the combo `.openLibrary` is active.
    /// Routed through `KeyTriggerEngine` (CGEventTap), so it needs Accessibility
    /// permission to actually fire — the combo path keeps working without it.
    var libraryDoubleTapModifier: DoubleTapModifier? {
        didSet {
            if let mod = libraryDoubleTapModifier {
                UserDefaults.standard.set(mod.rawValue, forKey: Defaults.libraryDoubleTapModifier)
            } else {
                UserDefaults.standard.removeObject(forKey: Defaults.libraryDoubleTapModifier)
            }
            NotificationCenter.default.post(name: AppSettings.libraryDoubleTapModifierDidChange, object: nil)
        }
    }

    /// Posted on the default NotificationCenter whenever the matching trigger
    /// is reassigned (e.g. via the Settings UI). The owning state class
    /// subscribes and re-registers its hotkey without requiring an app relaunch.
    static let dictationTriggerDidChange      = Notification.Name("dev.kosmonotes.studio.dictationTriggerDidChange")
    static let pushToMarkdownTriggerDidChange = Notification.Name("dev.kosmonotes.studio.pushToMarkdownTriggerDidChange")
    static let agentTriggerDidChange          = Notification.Name("dev.kosmonotes.studio.agentTriggerDidChange")
    static let libraryDoubleTapModifierDidChange = Notification.Name("dev.kosmonotes.studio.libraryDoubleTapModifierDidChange")

    /// Run the long-form meeting / voice-note transcript through an LLM cleanup
    /// pass after Whisper / Deepgram / Gemini transcribes. Reuses the configured
    /// `llmProvider`. On = ASR mistakes (numbers, names, double-words, missing
    /// punctuation) corrected; speaker voice and timing preserved. Off = raw
    /// transcript stored as-is. Default ON. Adds ~1–3 s + a small LLM cost per
    /// recording. Cleanup failures are non-fatal — raw transcript is kept.
    var transcriptCleanupEnabled: Bool {
        didSet { UserDefaults.standard.set(transcriptCleanupEnabled, forKey: Defaults.transcriptCleanupEnabled) }
    }

    /// Default Voice Note kind. The user can override per session.
    var voiceNoteKind: PromptTemplates.VoiceNoteKind {
        didSet { UserDefaults.standard.set(voiceNoteKind.rawValue, forKey: Defaults.voiceNoteKind) }
    }

    /// Default OpenRouter model. Free-text — OpenRouter accepts vendor/model strings like
    /// `anthropic/claude-3.5-sonnet` or `openai/gpt-4o-mini`.
    var openrouterModel: String {
        didSet { UserDefaults.standard.set(openrouterModel, forKey: Defaults.openrouterModel) }
    }

    /// Enable embedding-based semantic search alongside FTS5. Off by default — requires an
    /// OpenAI API key (uses text-embedding-3-small).
    var semanticSearchEnabled: Bool {
        didSet { UserDefaults.standard.set(semanticSearchEnabled, forKey: Defaults.semanticSearchEnabled) }
    }

    /// Use per-process Core Audio Tap (macOS 14.4+) instead of SCKit whole-system mixdown.
    /// Off by default; turning it on requires picking bundle IDs in `processTapBundleIDs`.
    var useProcessTap: Bool {
        didSet { UserDefaults.standard.set(useProcessTap, forKey: Defaults.useProcessTap) }
    }

    /// Comma-separated list of bundle IDs to capture when `useProcessTap` is on.
    /// Default common targets: Zoom, Meet (via Chrome/Safari), Teams, Slack.
    var processTapBundleIDs: String {
        didSet { UserDefaults.standard.set(processTapBundleIDs, forKey: Defaults.processTapBundleIDs) }
    }

    /// S3 endpoint URL (e.g. https://s3.amazonaws.com or https://<account>.r2.cloudflarestorage.com).
    var s3Endpoint: String {
        didSet { UserDefaults.standard.set(s3Endpoint, forKey: Defaults.s3Endpoint) }
    }
    /// S3 region (e.g. us-east-1, auto for R2).
    var s3Region: String {
        didSet { UserDefaults.standard.set(s3Region, forKey: Defaults.s3Region) }
    }
    /// S3 bucket name.
    var s3Bucket: String {
        didSet { UserDefaults.standard.set(s3Bucket, forKey: Defaults.s3Bucket) }
    }

    /// Presigned URL TTL in hours. Default 168 (7 days, the S3 max for sigv4).
    var s3PresignTTLHours: Int {
        didSet { UserDefaults.standard.set(s3PresignTTLHours, forKey: Defaults.s3PresignTTLHours) }
    }

    // MARK: Storage profile + codec overrides

    /// User-facing preset that picks codec + bitrate combos. Setting this also
    /// rewrites the individual codec fields below — they remain user-editable
    /// after a preset is picked, the preset is just the starting point.
    var storageProfile: StorageProfile {
        didSet {
            UserDefaults.standard.set(storageProfile.rawValue, forKey: Defaults.storageProfile)
            applyStorageProfile()
        }
    }

    /// Audio codec for new recordings. AAC-LC is the universal-compatibility default.
    var audioCodec: AudioCodec {
        didSet { UserDefaults.standard.set(audioCodec.rawValue, forKey: Defaults.audioCodec) }
    }
    /// Audio bitrate in bits/sec. AAC-LC: 96k default. HE-AAC: 48k. Opus: 32k.
    var audioBitrate: Int {
        didSet { UserDefaults.standard.set(audioBitrate, forKey: Defaults.audioBitrate) }
    }
    /// Audio sample rate Hz. 48000 captures full-band, 24000 is voice-only and ~⅔ size.
    var audioSampleRate: Int {
        didSet { UserDefaults.standard.set(audioSampleRate, forKey: Defaults.audioSampleRate) }
    }
    /// Use HEVC instead of H.264 for screen.mp4 video stream. ~50% smaller at same quality.
    /// Hardware-accelerated on all Apple Silicon Macs.
    var videoUseHEVC: Bool {
        didSet { UserDefaults.standard.set(videoUseHEVC, forKey: Defaults.videoUseHEVC) }
    }
    /// Video bitrate in bits/sec. Default 4_000_000 (H.264). HEVC defaults to 2_000_000.
    var videoBitrate: Int {
        didSet { UserDefaults.standard.set(videoBitrate, forKey: Defaults.videoBitrate) }
    }
    /// Rewrite codec fields to match the active StorageProfile.
    private func applyStorageProfile() {
        switch storageProfile {
        case .quality:
            audioCodec = .aac
            audioBitrate = 96_000
            audioSampleRate = 48_000
            videoUseHEVC = false
            videoBitrate = 4_000_000
        case .balanced:
            // Was HE-AAC 48 kbps — encoder fails on the macOS AAC HE path with
            // "Cannot Encode Media" for our mono PCM input. Use AAC-LC at the
            // same 48 kbps; for voice mono the difference is small enough to
            // accept until HE-AAC is properly debugged.
            audioCodec = .aac
            audioBitrate = 48_000
            audioSampleRate = 48_000
            videoUseHEVC = true
            videoBitrate = 2_000_000
        case .compact:
            audioCodec = .opus
            audioBitrate = 32_000
            audioSampleRate = 24_000
            videoUseHEVC = true
            videoBitrate = 1_500_000
        }
    }

    // Default prompts (Markdown export + Agent system) live in
    // AppSettings+Prompts.swift — they're long string literals with no logic.

    // MARK: Init

    private let keychain: Keychain
    private var keychainReadFailedAccounts: Set<KeychainAccount> = []

    init() {
        // Keychain service must match the bundle identifier.
        self.keychain = Keychain(service: "dev.kosmonotes.studio")
            .accessibility(.afterFirstUnlockThisDeviceOnly)
            .synchronizable(false)

        let providerRaw = UserDefaults.standard.string(forKey: Defaults.transcriptionProvider) ?? TranscriptionProviderChoice.openaiWhisper.rawValue
        self.transcriptionProvider = TranscriptionProviderChoice(rawValue: providerRaw) ?? .openaiWhisper

        let openaiModelRaw = UserDefaults.standard.string(forKey: Defaults.openaiTranscribeModel) ?? OpenAITranscribeModel.gpt4oMiniTranscribe.rawValue
        self.openaiTranscribeModel = OpenAITranscribeModel(rawValue: openaiModelRaw) ?? .gpt4oMiniTranscribe

        // WhisperKit variant — empty default forces the user to pick + download
        // before they can switch the active transcription provider to .whisperKit.
        self.whisperKitModel = UserDefaults.standard.string(forKey: Defaults.whisperKitModel) ?? ""

        self.systemAudioDeviceUID = UserDefaults.standard.string(forKey: Defaults.systemAudioDeviceUID) ?? ""
        let savedDisplayID = UserDefaults.standard.integer(forKey: Defaults.screenCaptureDisplayID)
        self.screenCaptureDisplayID = savedDisplayID > 0 ? UInt32(savedDisplayID) : 0

        self.cameraBubbleEnabled = (UserDefaults.standard.object(forKey: Defaults.cameraBubbleEnabled) as? Bool) ?? false
        self.cameraDeviceUID = UserDefaults.standard.string(forKey: Defaults.cameraDeviceUID) ?? ""
        let cbX = UserDefaults.standard.object(forKey: Defaults.cameraBubblePositionX) as? Double ?? 100
        let cbY = UserDefaults.standard.object(forKey: Defaults.cameraBubblePositionY) as? Double ?? 100
        self.cameraBubblePosition = CGPoint(x: cbX, y: cbY)
        let savedSize = UserDefaults.standard.double(forKey: Defaults.cameraBubbleSize)
        self.cameraBubbleSize = savedSize > 0 ? savedSize : 200

        self.chatVideoAutoFramesEnabled = (UserDefaults.standard.object(forKey: Defaults.chatVideoAutoFramesEnabled) as? Bool) ?? false
        let savedFrames = UserDefaults.standard.integer(forKey: Defaults.chatVideoAutoFramesCount)
        self.chatVideoAutoFramesCount = savedFrames > 0 ? savedFrames : 4

        self.markdownExportEnabled = (UserDefaults.standard.object(forKey: Defaults.markdownExportEnabled) as? Bool) ?? false
        self.markdownExportFolder = UserDefaults.standard.string(forKey: Defaults.markdownExportFolder) ?? ""
        self.markdownExportSystemPrompt = UserDefaults.standard.string(forKey: Defaults.markdownExportSystemPrompt)
            ?? AppSettings.defaultMarkdownExportSystemPrompt
        self.markdownExportUserPrompt = UserDefaults.standard.string(forKey: Defaults.markdownExportUserPrompt)
            ?? AppSettings.defaultMarkdownExportUserPrompt
        self.pushToMarkdownEnabled = (UserDefaults.standard.object(forKey: Defaults.pushToMarkdownEnabled) as? Bool) ?? false

        self.agentEnabled = (UserDefaults.standard.object(forKey: Defaults.agentEnabled) as? Bool) ?? false
        self.agentSystemPrompt = UserDefaults.standard.string(forKey: Defaults.agentSystemPrompt) ?? AppSettings.defaultAgentSystemPrompt
        let savedIters = UserDefaults.standard.integer(forKey: Defaults.agentMaxIterations)
        self.agentMaxIterations = savedIters > 0 ? savedIters : 12
        self.agentWorkspaceFolder = UserDefaults.standard.string(forKey: Defaults.agentWorkspaceFolder) ?? ""
        let backendRaw = UserDefaults.standard.string(forKey: Defaults.agentBackend) ?? AgentBackendChoice.builtin.rawValue
        self.agentBackend = AgentBackendChoice(rawValue: backendRaw) ?? .builtin
        let modelRaw = UserDefaults.standard.string(forKey: Defaults.agentBuiltinModel) ?? AgentBuiltinModel.sonnet46.rawValue
        self.agentBuiltinModel = AgentBuiltinModel(rawValue: modelRaw) ?? .sonnet46
        self.agentClaudeCodeBin = UserDefaults.standard.string(forKey: Defaults.agentClaudeCodeBin) ?? ""
        self.agentCodexBin = UserDefaults.standard.string(forKey: Defaults.agentCodexBin) ?? ""
        self.agentCopilotBin = UserDefaults.standard.string(forKey: Defaults.agentCopilotBin) ?? ""

        let llmRaw = UserDefaults.standard.string(forKey: Defaults.llmProvider) ?? LLMProviderChoice.anthropic.rawValue
        self.llmProvider = LLMProviderChoice(rawValue: llmRaw) ?? .anthropic

        self.summaryLanguage = UserDefaults.standard.string(forKey: Defaults.summaryLanguage) ?? "auto"

        let modeRaw = UserDefaults.standard.string(forKey: Defaults.recordingMode) ?? RecordingMode.audioOnly.rawValue
        self.recordingMode = RecordingMode(rawValue: modeRaw) ?? .audioOnly

        // Default $1.00 only when the preference is absent. A stored 0.0 is a
        // deliberate "disable spend" cap and must survive reloads.
        if UserDefaults.standard.object(forKey: Defaults.costCapUSD) == nil {
            self.costCapUSD = 1.00
        } else {
            self.costCapUSD = max(0.0, UserDefaults.standard.double(forKey: Defaults.costCapUSD))
        }

        self.ollamaEndpoint = UserDefaults.standard.string(forKey: Defaults.ollamaEndpoint) ?? "http://localhost:11434"

        let apiModeRaw = UserDefaults.standard.string(forKey: Defaults.ollamaApiMode) ?? OllamaAPIMode.native.rawValue
        self.ollamaApiMode = OllamaAPIMode(rawValue: apiModeRaw) ?? .native

        self.ollamaModel = UserDefaults.standard.string(forKey: Defaults.ollamaModel) ?? "qwen2.5:14b"

        self.systemAudioEnabled = UserDefaults.standard.bool(forKey: Defaults.systemAudioEnabled)
        self.echoCancellationEnabled = (UserDefaults.standard.object(forKey: Defaults.echoCancellationEnabled) as? Bool) ?? true
        // Default true for cleanup; UserDefaults.bool returns false for missing keys, so check object presence.
        self.dictationLLMCleanup = (UserDefaults.standard.object(forKey: Defaults.dictationLLMCleanup) as? Bool) ?? true
        // Default `clipboardSimulatedV` — universal compatibility. The
        // historical `axapiThenClipboard` enum case (removed 2026-05-04)
        // would silently no-op in Electron targets and confuse users into
        // thinking dictation was broken; migrate any stored "axapiThenClipboard"
        // raw value to `clipboardSimulatedV` here so existing installs
        // upgrade cleanly without the user having to flip a toggle.
        let insertionRaw = UserDefaults.standard.string(forKey: Defaults.dictationInsertion)
            ?? DictationInsertionStrategy.clipboardSimulatedV.rawValue
        let migrated = (insertionRaw == "axapiThenClipboard")
            ? DictationInsertionStrategy.clipboardSimulatedV.rawValue
            : insertionRaw
        if migrated != insertionRaw {
            UserDefaults.standard.set(migrated, forKey: Defaults.dictationInsertion)
        }
        self.dictationInsertion = DictationInsertionStrategy(rawValue: migrated) ?? .clipboardSimulatedV
        self.transcriptCleanupEnabled = (UserDefaults.standard.object(forKey: Defaults.transcriptCleanupEnabled) as? Bool) ?? true
        let maxSecs = UserDefaults.standard.integer(forKey: Defaults.dictationMaxSeconds)
        self.dictationMaxSeconds = maxSecs > 0 ? maxSecs : 60

        // dictationTrigger / pushToMarkdownTrigger / agentTrigger: each is a
        // JSON blob in UserDefaults; .combo if absent or corrupt so existing
        // installs see no behaviour change at upgrade.
        self.dictationTrigger = AppSettings.loadTrigger(forKey: Defaults.dictationTrigger)
        self.pushToMarkdownTrigger = AppSettings.loadTrigger(forKey: Defaults.pushToMarkdownTrigger)
        self.agentTrigger = AppSettings.loadTrigger(forKey: Defaults.agentTrigger)

        // libraryDoubleTapModifier: optional rawValue string in UserDefaults.
        if let raw = UserDefaults.standard.string(forKey: Defaults.libraryDoubleTapModifier) {
            self.libraryDoubleTapModifier = DoubleTapModifier(rawValue: raw)
        } else {
            self.libraryDoubleTapModifier = nil
        }

        let kindRaw = UserDefaults.standard.string(forKey: Defaults.voiceNoteKind) ?? PromptTemplates.VoiceNoteKind.freeform.rawValue
        self.voiceNoteKind = PromptTemplates.VoiceNoteKind(rawValue: kindRaw) ?? .freeform

        self.openrouterModel = UserDefaults.standard.string(forKey: Defaults.openrouterModel) ?? "anthropic/claude-3.5-sonnet"
        self.semanticSearchEnabled = UserDefaults.standard.bool(forKey: Defaults.semanticSearchEnabled)

        self.useProcessTap = UserDefaults.standard.bool(forKey: Defaults.useProcessTap)
        self.processTapBundleIDs = UserDefaults.standard.string(forKey: Defaults.processTapBundleIDs)
            ?? "us.zoom.xos,com.microsoft.teams2,com.tinyspeck.slackmacgap,com.google.Chrome,com.apple.Safari"

        self.s3Endpoint = UserDefaults.standard.string(forKey: Defaults.s3Endpoint) ?? ""
        self.s3Region = UserDefaults.standard.string(forKey: Defaults.s3Region) ?? "us-east-1"
        self.s3Bucket = UserDefaults.standard.string(forKey: Defaults.s3Bucket) ?? ""
        let ttl = UserDefaults.standard.integer(forKey: Defaults.s3PresignTTLHours)
        self.s3PresignTTLHours = ttl > 0 ? ttl : 168

        // Storage profile defaults to .balanced for new installs (50 % smaller than
        // the legacy "Quality" default). Existing installs that have no UserDefaults
        // entry get .balanced too — but their per-field overrides (audioCodec etc)
        // also have no entry so applyStorageProfile-equivalent values are loaded.
        let profileRaw = UserDefaults.standard.string(forKey: Defaults.storageProfile) ?? StorageProfile.balanced.rawValue
        self.storageProfile = StorageProfile(rawValue: profileRaw) ?? .balanced

        // Auto-migrate away from HE-AAC: the macOS AAC encoder rejects the PCM
        // input we feed AVAssetWriterInput with kAudioFormatMPEG4AAC_HE under
        // certain mono/48 kHz/48 kbps configurations ("Cannot Encode Media",
        // status=.failed on first append). Until that's properly diagnosed,
        // any stored .heAAC preference is rewritten to .aac so recordings
        // actually produce segments. Users can flip back via Storage Profile.
        let codecRaw = UserDefaults.standard.string(forKey: Defaults.audioCodec) ?? AudioCodec.aac.rawValue
        var resolvedCodec = AudioCodec(rawValue: codecRaw) ?? .aac
        if resolvedCodec == .heAAC {
            resolvedCodec = .aac
            UserDefaults.standard.set(resolvedCodec.rawValue, forKey: Defaults.audioCodec)
        }
        self.audioCodec = resolvedCodec

        let abr = UserDefaults.standard.integer(forKey: Defaults.audioBitrate)
        self.audioBitrate = abr > 0 ? abr : 48_000
        let asr = UserDefaults.standard.integer(forKey: Defaults.audioSampleRate)
        self.audioSampleRate = asr > 0 ? asr : 48_000

        // HEVC default true on a fresh install — well-supported on macOS 14+.
        self.videoUseHEVC = (UserDefaults.standard.object(forKey: Defaults.videoUseHEVC) as? Bool) ?? true
        let vbr = UserDefaults.standard.integer(forKey: Defaults.videoBitrate)
        self.videoBitrate = vbr > 0 ? vbr : 2_000_000

        loadKeysFromKeychain()
    }

    /// Decode a stored HotkeyTrigger from UserDefaults under the given key.
    /// Returns `.combo` when the key is missing OR the JSON is corrupt — that
    /// way an upgrade adding new associated values to a HotkeyTrigger case
    /// can't lock the user out by failing to decode an old preference.
    private static func loadTrigger(forKey key: String) -> HotkeyTrigger {
        guard let data = UserDefaults.standard.data(forKey: key),
              let decoded = try? JSONDecoder().decode(HotkeyTrigger.self, from: data) else {
            return .combo
        }
        return decoded
    }

    // MARK: Persistence

    private func loadKeysFromKeychain() {
        deepgramApiKey = loadKey(.deepgram)
        openaiApiKey = loadKey(.openaiWhisper)
        anthropicApiKey = loadKey(.anthropic)
        ollamaBearer = loadKey(.ollama)
        openrouterApiKey = loadKey(.openrouter)
        geminiApiKey = loadKey(.gemini)
        s3AccessKey = loadKey(.s3AccessKey)
        s3SecretKey = loadKey(.s3SecretKey)
    }

    private func loadKey(_ account: KeychainAccount) -> String {
        do {
            keychainReadFailedAccounts.remove(account)
            return try keychain.get(account.rawValue) ?? ""
        } catch {
            keychainReadFailedAccounts.insert(account)
            appSettingsLog.error("Keychain read failed for account \(account.rawValue, privacy: .public): \(error.localizedDescription, privacy: .public)")
            return ""
        }
    }

    /// Persist all currently-loaded values to Keychain. Empty strings are
    /// treated as "remove" so users can clear a key from the UI.
    func commitAllKeys() {
        commit(.deepgram, value: deepgramApiKey)
        commit(.openaiWhisper, value: openaiApiKey)
        commit(.anthropic, value: anthropicApiKey)
        commit(.ollama, value: ollamaBearer)
        commit(.openrouter, value: openrouterApiKey)
        commit(.gemini, value: geminiApiKey)
        commit(.s3AccessKey, value: s3AccessKey)
        commit(.s3SecretKey, value: s3SecretKey)
    }

    func commit(_ account: KeychainAccount, value: String) {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        let action = Self.keychainCommitAction(
            trimmedValue: trimmed,
            readFailed: keychainReadFailedAccounts.contains(account)
        )
        do {
            switch action {
            case .remove:
                try keychain.remove(account.rawValue)
                keychainReadFailedAccounts.remove(account)
            case .set(let value):
                try keychain.set(value, key: account.rawValue)
                keychainReadFailedAccounts.remove(account)
            case .skipEmptyRemovalAfterReadFailure:
                appSettingsLog.error("Skipped empty Keychain commit for account \(account.rawValue, privacy: .public) because the startup read failed")
            }
        } catch {
            // Log so failures are visible in Console.app (subsystem
            // dev.kosmonotes.studio, category AppSettings). Common causes:
            // device locked + .afterFirstUnlockThisDeviceOnly not yet reached,
            // ACL change, Keychain corruption. The user-visible "I saved a key
            // but auth still fails" symptom is otherwise impossible to debug.
            appSettingsLog.error("Keychain commit failed for account \(account.rawValue, privacy: .public): \(error.localizedDescription, privacy: .public)")
        }
    }

    enum KeychainCommitAction: Equatable {
        case remove
        case set(String)
        case skipEmptyRemovalAfterReadFailure
    }

    static func keychainCommitAction(trimmedValue: String, readFailed: Bool) -> KeychainCommitAction {
        if trimmedValue.isEmpty {
            return readFailed ? .skipEmptyRemovalAfterReadFailure : .remove
        }
        return .set(trimmedValue)
    }

    // MARK: - WhisperKit paths

    /// Stable root for downloaded WhisperKit models. Lives next to recordings
    /// (`~/Library/Application Support/KosmoNotes/whisperkit/`) so a user
    /// scrubbing Application Support can find and remove all model state in
    /// one folder.
    static func whisperKitModelsRoot() -> URL {
        let appSupport = (try? FileManager.default.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )) ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support")
        return appSupport
            .appendingPathComponent("KosmoNotes")
            .appendingPathComponent("whisperkit")
    }

    // MARK: - Diagnostics

    /// Emit a one-shot summary of user-visible configuration to os_log so the
    /// user can read it back in Settings → Logs (category `AppSettings`). Does
    /// not include any secrets — only flags / model names / hotkey labels —
    /// so it's safe to copy/paste into a bug report.
    ///
    /// - Parameter context: short label identifying the call site
    ///   (e.g. "startup", "before-dictation", "before-recording") so multiple
    ///   snapshots in one log are distinguishable.
    func logSnapshot(context: String) {
        // Single multi-line entry — easier to copy than 12 separate lines.
        let trigger = dictationTrigger.displayName
        let lines = [
            "context=\(context)",
            "transcription=\(transcriptionProvider.rawValue)",
            "openaiTranscribeModel=\(openaiTranscribeModel.rawValue)",
            "llm=\(llmProvider.rawValue)",
            "recordingMode=\(recordingMode.rawValue)",
            "systemAudioEnabled=\(systemAudioEnabled)",
            "echoCancellationEnabled=\(echoCancellationEnabled)",
            "useProcessTap=\(useProcessTap)",
            "systemAudioDeviceUID=\(systemAudioDeviceUID.isEmpty ? "(default SCKit)" : systemAudioDeviceUID)",
            "screenCaptureDisplayID=\(screenCaptureDisplayID)",
            "audioCodec=\(audioCodec.rawValue) bitrate=\(audioBitrate) sampleRate=\(audioSampleRate)",
            "videoUseHEVC=\(videoUseHEVC) videoBitrate=\(videoBitrate)",
            "dictationInsertion=\(dictationInsertion.rawValue)",
            "dictationLLMCleanup=\(dictationLLMCleanup)",
            "dictationMaxSeconds=\(dictationMaxSeconds)",
            "dictationTrigger=\(trigger)",
            "transcriptCleanupEnabled=\(transcriptCleanupEnabled)",
            "semanticSearchEnabled=\(semanticSearchEnabled)",
            "summaryLanguage=\(summaryLanguage)",
            "markdownExportEnabled=\(markdownExportEnabled)",
            "pushToMarkdownEnabled=\(pushToMarkdownEnabled)",
            "agentEnabled=\(agentEnabled) agentBackend=\(agentBackend.rawValue) agentBuiltinModel=\(agentBuiltinModel.rawValue)",
            "cameraBubbleEnabled=\(cameraBubbleEnabled)",
            "s3Configured=\(!s3Endpoint.isEmpty && !s3Bucket.isEmpty && !s3AccessKey.isEmpty)",
            "openaiKeySet=\(!openaiApiKey.isEmpty)",
            "anthropicKeySet=\(!anthropicApiKey.isEmpty)",
            "deepgramKeySet=\(!deepgramApiKey.isEmpty)",
            "openrouterKeySet=\(!openrouterApiKey.isEmpty)",
            "geminiKeySet=\(!geminiApiKey.isEmpty)",
        ]
        let dump = lines.joined(separator: " | ")
        appSettingsLog.info("config snapshot: \(dump, privacy: .public)")
    }
}

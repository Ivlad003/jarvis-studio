@preconcurrency import AVFoundation
@preconcurrency import ScreenCaptureKit
import SwiftUI
import AIKit
import CaptureKit
import DictationKit
import KeyboardShortcuts
import StorageKit
import TranscriptionKit

enum SettingsCopy {
    static let costCapDescription = "AI summaries, cleanup, embeddings, and known transcription estimates above this per-session limit are blocked or skipped. Deepgram live transcription is checked before recording starts using the first-hour estimate. Default $1.00."

    static let audioHandling = """
    Recordings stay on your Mac at:

    ~/Library/Application Support/KosmoNotes/recordings/

    Deepgram live streaming sends microphone audio during recording. Batch cloud transcription uploads audio after Stop. WhisperKit keeps transcription on this Mac.

    AI summaries and cleanup are sent to the AI provider you configure unless you use Ollama for local AI.

    If you need a local-only recording, use WhisperKit for transcription and Ollama for AI before you start.
    """
}

// MARK: - SettingsView

/// Top-level Settings window content. Embedded in the @main App's `Settings`
/// scene — opens automatically on Cmd+, or via the menu-bar item action.
@available(macOS 14.0, *)
struct SettingsView: View {

    @Bindable var settings: AppSettings
    let knowledgeBaseStore: KnowledgeBaseStore?

    init(settings: AppSettings, knowledgeBaseStore: KnowledgeBaseStore? = nil) {
        self.settings = settings
        self.knowledgeBaseStore = knowledgeBaseStore
    }

    var body: some View {
        TabView {
            TranscriptionTab(settings: settings)
                .tabItem { Label("Transcription", systemImage: "waveform") }

            AIProvidersTab(settings: settings)
                .tabItem { Label("AI Providers", systemImage: "sparkles") }

            DictationTab(settings: settings)
                .tabItem { Label("Dictation", systemImage: "keyboard") }

            HotkeysTab(settings: settings)
                .tabItem { Label("Hotkeys", systemImage: "command") }

            SharingTab(settings: settings)
                .tabItem { Label("Sharing", systemImage: "square.and.arrow.up") }

            MarkdownExportTab(settings: settings)
                .tabItem { Label("Markdown", systemImage: "doc.text") }

            AgentTab(settings: settings)
                .tabItem { Label("Agent", systemImage: "wand.and.rays") }

            KnowledgeBaseTab(store: knowledgeBaseStore)
                .tabItem { Label("Knowledge", systemImage: "books.vertical") }

            PrivacyTab()
                .tabItem { Label("Privacy", systemImage: "lock.shield") }

            LogsTab()
                .tabItem { Label("Logs", systemImage: "doc.plaintext") }
        }
        .padding(20)
        // Tab labels were getting truncated on the default 520pt width
        // because we have many tabs (Transcription / AI Providers /
        // Dictation / Hotkeys / Sharing / Markdown / Knowledge /
        // Privacy / Logs). Bumped both ideal and min so labels render in full.
        .frame(minWidth: 760, idealWidth: 820, minHeight: 380, idealHeight: 560)
    }
}

// MARK: - KnowledgeBaseTab

@available(macOS 14.0, *)
private struct KnowledgeBaseTab: View {
    @State private var state: KnowledgeBaseSettingsState

    init(store: KnowledgeBaseStore?) {
        _state = State(initialValue: KnowledgeBaseSettingsState(store: store))
    }

    var body: some View {
        Form {
            Section("Sources") {
                if state.sources.isEmpty {
                    Text("No knowledge sources configured.")
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(state.sources) { source in
                        HStack(alignment: .firstTextBaseline) {
                            VStack(alignment: .leading, spacing: 3) {
                                Text(source.path)
                                    .font(.system(.callout, design: .monospaced))
                                    .lineLimit(1)
                                    .truncationMode(.middle)
                                Text(Self.detailText(for: source))
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                            Button("Remove", role: .destructive) {
                                Task { await state.removeSource(id: source.id) }
                            }
                            .disabled(state.isBusy)
                        }
                    }
                }

                HStack {
                    Button("Add documents…") { pickDocuments() }
                        .disabled(state.isBusy)
                    Button("Add code folder…") { pickCodeFolder() }
                        .disabled(state.isBusy)
                    Spacer()
                    Button("Reindex all") {
                        Task { await state.reindexAll() }
                    }
                    .disabled(state.isBusy || state.sources.isEmpty)
                }

                if state.isBusy {
                    ProgressView()
                        .controlSize(.small)
                }
                if let status = state.statusMessage {
                    Text(status)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                if let error = state.lastError {
                    Text(error)
                        .font(.caption)
                        .foregroundStyle(.red)
                }
            }

            Section("Indexing") {
                Text("Documents can be Markdown, text, or PDF files. Code folders are indexed with identifier-safe full-text search and are also available to the agent's code search tool.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .task { await state.refresh() }
    }

    private static func detailText(for source: KnowledgeBaseSource) -> String {
        "\(KnowledgeBaseSettingsState.displayName(for: source.kind)) source"
    }

    private func pickDocuments() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = true
        panel.allowedFileTypes = ["md", "markdown", "txt", "text", "pdf"]
        panel.prompt = "Add"
        panel.title = "Add documents to the knowledge base"
        if panel.runModal() == .OK {
            let urls = panel.urls
            Task {
                for url in urls {
                    await state.addSource(kind: .document, path: url)
                }
            }
        }
    }

    private func pickCodeFolder() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.prompt = "Add"
        panel.title = "Add a code folder to the knowledge base"
        if panel.runModal() == .OK, let url = panel.url {
            Task { await state.addSource(kind: .codeFolder, path: url) }
        }
    }
}

// MARK: - Transcription tab

@available(macOS 14.0, *)
private struct TranscriptionTab: View {
    @Bindable var settings: AppSettings

    @State private var deepgramTestState: ConnectionTestState = .idle
    /// Per-tab WhisperKit download state. Cached state lives in
    /// `WhisperKitModelManager`'s files on disk, so creating a fresh
    /// view-model each Settings open is acceptable; downloads in flight
    /// will still appear because `refreshCatalogue` reads from the
    /// shared filesystem.
    @State private var whisperKitDownload: WhisperKitDownloadState = WhisperKitDownloadState(
        manager: WhisperKitModelManager(rootDir: AppSettings.whisperKitModelsRoot())
    )

    var body: some View {
        Form {
            Section("Recording mode") {
                Picker("Mode", selection: $settings.recordingMode) {
                    ForEach(AppSettings.RecordingMode.allCases) { m in
                        Text(m.displayName).tag(m)
                    }
                }
                .pickerStyle(.segmented)
                if settings.recordingMode == .audioAndScreen {
                    Text("Records the entire screen + system audio at 24 fps. Requires Screen Recording permission. The first time you start a recording, macOS will prompt you to grant access.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Toggle("Capture system audio alongside mic", isOn: $settings.systemAudioEnabled)
                Text("Mixes Spotify, video calls, browser audio etc. into the recording. Off by default; toggle on for meeting / call capture.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("System audio source") {
                SystemAudioSourcePicker(settings: settings)
                Toggle("Echo cancellation", isOn: $settings.echoCancellationEnabled)
                Text("Uses the clean system-audio track as a reference to remove speaker bleed from the mic track. Headphone and no-echo paths bypass automatically.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Webcam bubble (Loom-style)") {
                CameraBubbleSettings(settings: settings)
            }

            if isMacOS14_4OrLater() {
                Section("System audio source — per-process tap (macOS 14.4+)") {
                    Toggle("Capture only specific apps (per-process Core Audio Tap)", isOn: $settings.useProcessTap)
                    if settings.useProcessTap {
                        ProcessTapAppPicker(settings: settings)
                    } else {
                        Text("Off: ScreenCaptureKit captures whole-system audio, including unrelated apps (Spotify, notifications). On: only the apps you tick are recorded — quieter, more private. Works in Audio + Screen mode AND Audio-only mode (the system audio toggle above must also be ON).")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }

            Section("Storage profile") {
                Picker("Profile", selection: $settings.storageProfile) {
                    ForEach(AppSettings.StorageProfile.allCases) { p in
                        Text(p.displayName).tag(p)
                    }
                }
                .pickerStyle(.segmented)
                Text(settings.storageProfile.summary)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text("Picking a profile rewrites the codec and bitrate fields below. Tweak them after if you need finer control.")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }

            Section("Audio codec") {
                Picker("Codec", selection: $settings.audioCodec) {
                    ForEach(AppSettings.AudioCodec.allCases) { c in
                        Text(c.displayName).tag(c)
                    }
                }
                .pickerStyle(.segmented)
                HStack {
                    Text("Bitrate (kbps)")
                    Spacer()
                    TextField("kbps", value: Binding(
                        get: { settings.audioBitrate / 1000 },
                        set: { settings.audioBitrate = $0 * 1000 }
                    ), format: .number)
                        .frame(width: 80)
                        .textFieldStyle(.roundedBorder)
                }
                HStack {
                    Text("Sample rate")
                    Spacer()
                    Picker("", selection: $settings.audioSampleRate) {
                        Text("48 kHz").tag(48_000)
                        Text("24 kHz (voice)").tag(24_000)
                        Text("16 kHz (voice, very compact)").tag(16_000)
                    }
                    .frame(width: 240)
                    .labelsHidden()
                }
                Text("Opus falls back to HE-AAC inside .m4a containers (Opus muxing requires a different container).")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }

            if settings.recordingMode == .audioAndScreen {
                Section("Display (when Audio + Screen mode)") {
                    ScreenDisplayPicker(settings: settings)
                    Text("Picks which monitor goes into screen.mp4. The list is fetched from ScreenCaptureKit, so external displays appear once Screen Recording permission is granted. Changes take effect on the next recording.")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
            }

            Section("Video codec (when Audio + Screen mode)") {
                Toggle("Use HEVC (H.265)", isOn: $settings.videoUseHEVC)
                HStack {
                    Text("Bitrate (Mbps)")
                    Spacer()
                    TextField("Mbps", value: Binding(
                        get: { Double(settings.videoBitrate) / 1_000_000 },
                        set: { settings.videoBitrate = Int($0 * 1_000_000) }
                    ), format: .number.precision(.fractionLength(1)))
                        .frame(width: 80)
                        .textFieldStyle(.roundedBorder)
                }
                Text("HEVC is hardware-accelerated on all Apple Silicon Macs and is roughly 50% smaller than H.264 at equivalent visual quality.")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }

            Section("Default provider") {
                Picker("Provider", selection: $settings.transcriptionProvider) {
                    ForEach(AppSettings.TranscriptionProviderChoice.allCases) { choice in
                        Text(choice.displayName).tag(choice)
                    }
                }
                .pickerStyle(.segmented)
                Text(footerForProvider(settings.transcriptionProvider))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            if settings.transcriptionProvider == .openaiWhisper {
                Section("OpenAI model") {
                    Picker("Model", selection: $settings.openaiTranscribeModel) {
                        ForEach(AppSettings.OpenAITranscribeModel.allCases) { m in
                            Text(m.displayName).tag(m)
                        }
                    }
                    .pickerStyle(.menu)
                    Text("`whisper-1` is the legacy hosted Whisper Large-v2 (~5.3% WER). `gpt-4o-transcribe` and `gpt-4o-mini-transcribe` are OpenAI's March 2025 successors with measurably lower WER (~4.1%). Same /v1/audio/transcriptions endpoint, same API key — only the `model` field differs. Default is `gpt-4o-mini-transcribe` per OpenAI's own recommendation.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            // Local WhisperKit section. Always rendered, regardless of the
            // active provider — the user has to be able to download a model
            // BEFORE flipping the provider switch to use it.
            WhisperKitSection(settings: settings, download: whisperKitDownload)

            Section("Transcript LLM cleanup") {
                Toggle("Clean transcript with LLM after transcription", isOn: $settings.transcriptCleanupEnabled)
                Text("Runs the raw ASR output through your configured LLM (AI Providers tab) to fix mishearing — wrong numbers, names, technical terms, doubled words, missing punctuation. Speaker voice and timing are preserved. Adds ~1–3 s + a small LLM cost per recording. Saved separately as `transcript.raw.txt` for audit. Cleanup failures are non-fatal — raw transcript stays.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Deepgram") {
                APIKeyField(
                    title: "API key",
                    text: $settings.deepgramApiKey,
                    onCommit: { settings.commit(.deepgram, value: settings.deepgramApiKey) }
                )
                Link("Get a Deepgram API key", destination: URL(string: "https://console.deepgram.com/")!)
                    .font(.caption)
                ConnectionTestRow(label: "Test connection", state: deepgramTestState) {
                    Task { await testDeepgram() }
                }
            }

            Section("OpenAI (Whisper transcription + GPT LLM)") {
                APIKeyField(
                    title: "API key",
                    text: $settings.openaiApiKey,
                    onCommit: { settings.commit(.openaiWhisper, value: settings.openaiApiKey) }
                )
                Text("This key is shared by Whisper transcription and the OpenAI LLM provider.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Link("Get an OpenAI API key", destination: URL(string: "https://platform.openai.com/api-keys")!)
                    .font(.caption)
            }

            Section("Gemini (multimodal audio)") {
                APIKeyField(
                    title: "API key",
                    text: $settings.geminiApiKey,
                    onCommit: { settings.commit(.gemini, value: settings.geminiApiKey) }
                )
                Text("Used when 'Default provider' is set to Gemini. Sends the recording's audio.m4a directly to Gemini 2.5 Flash, which returns transcript + segments in one shot.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Link("Get a Gemini API key (Google AI Studio)", destination: URL(string: "https://aistudio.google.com/apikey")!)
                    .font(.caption)
            }
        }
        .formStyle(.grouped)
    }

    /// Per-process Core Audio Tap requires macOS 14.4+. We use ProcessInfo here
    /// rather than `#available` so the SwiftUI conditional can render dynamically.
    private func isMacOS14_4OrLater() -> Bool {
        let v = ProcessInfo.processInfo.operatingSystemVersion
        if v.majorVersion > 14 { return true }
        return v.majorVersion == 14 && v.minorVersion >= 4
    }

    private func footerForProvider(_ choice: AppSettings.TranscriptionProviderChoice) -> String {
        switch choice {
        case .deepgram:
            return "Deepgram streams partial transcripts during recording (live). Best fit for Dictation Mode."
        case .openaiWhisper:
            return "OpenAI Whisper transcribes after the recording stops (batch). Higher latency, broad language coverage."
        case .gemini:
            return "Google Gemini ingests the audio file directly via its multimodal API. One round-trip = transcript + segments. Inline upload caps at ~18 MB (~3–4 h of HE-AAC mono); longer recordings fail until we wire the resumable File API."
        case .openrouterAudio:
            return "Routes audio through OpenRouter to a multimodal model (defaults to google/gemini-2.5-flash, configurable in AI Providers → OpenRouter model). Same OpenRouter API key as LLM cleanup. Inline cap ~18 MB. Use this if you want one billing relationship for everything."
        case .whisperKit:
            return "On-device WhisperKit (CoreML port of Whisper). No network calls, no API key, no billing. You must download a model first in the Local — WhisperKit section below. Apple Silicon recommended."
        }
    }

    /// Minimal probe: GET /v1/projects with Token auth. 200 → success.
    private func testDeepgram() async {
        deepgramTestState = .testing
        let key = settings.deepgramApiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty else {
            deepgramTestState = .failed("No API key set")
            return
        }
        var req = URLRequest(url: URL(string: "https://api.deepgram.com/v1/projects")!)
        req.setValue("Token \(key)", forHTTPHeaderField: "Authorization")
        do {
            let (_, response) = try await URLSession.shared.data(for: req)
            if let http = response as? HTTPURLResponse {
                deepgramTestState = http.statusCode == 200 ? .success : .failed("HTTP \(http.statusCode)")
            } else {
                deepgramTestState = .failed("Non-HTTP response")
            }
        } catch {
            deepgramTestState = .failed(error.localizedDescription)
        }
    }
}

// MARK: - AI Providers tab

@available(macOS 14.0, *)
private struct AIProvidersTab: View {
    @Bindable var settings: AppSettings

    // Per-provider connection-test state; kept local so they don't pollute AppSettings.
    @State private var anthropicTestState: ConnectionTestState = .idle
    @State private var openaiTestState: ConnectionTestState = .idle
    @State private var ollamaTestState: ConnectionTestState = .idle
    @State private var openrouterTestState: ConnectionTestState = .idle

    var body: some View {
        Form {
            Section("Default LLM provider") {
                Picker("Provider", selection: $settings.llmProvider) {
                    ForEach(AppSettings.LLMProviderChoice.allCases) { choice in
                        Text(choice.displayName).tag(choice)
                    }
                }
                .pickerStyle(.segmented)
            }

            Section("Anthropic Claude") {
                APIKeyField(
                    title: "API key",
                    text: $settings.anthropicApiKey,
                    onCommit: { settings.commit(.anthropic, value: settings.anthropicApiKey) }
                )
                Link("Get an Anthropic API key", destination: URL(string: "https://console.anthropic.com/settings/keys")!)
                    .font(.caption)
                ConnectionTestRow(label: "Test connection", state: anthropicTestState) {
                    Task { await testAnthropic() }
                }
            }

            Section("OpenAI") {
                APIKeyField(
                    title: "API key",
                    text: $settings.openaiApiKey,
                    onCommit: { settings.commit(.openaiWhisper, value: settings.openaiApiKey) }
                )
                Text("Same key as the Whisper transcription field — managed in one place.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                ConnectionTestRow(label: "Test connection", state: openaiTestState) {
                    Task { await testOpenAI() }
                }
            }

            Section("OpenRouter") {
                APIKeyField(
                    title: "API key",
                    text: $settings.openrouterApiKey,
                    onCommit: { settings.commit(.openrouter, value: settings.openrouterApiKey) }
                )
                HStack {
                    Text("Default model")
                    Spacer()
                    TextField("anthropic/claude-3.5-sonnet", text: $settings.openrouterModel)
                        .frame(width: 240)
                        .textFieldStyle(.roundedBorder)
                }
                Text("OpenRouter routes to many providers via vendor/model identifiers (e.g. openai/gpt-4o-mini, anthropic/claude-3.5-sonnet, meta-llama/llama-3.3-70b).")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Link("Get an OpenRouter API key", destination: URL(string: "https://openrouter.ai/keys")!)
                    .font(.caption)
                ConnectionTestRow(label: "Test connection", state: openrouterTestState) {
                    Task { await testOpenRouter() }
                }
            }

            Section("Ollama (local)") {
                HStack {
                    Text("Endpoint")
                    Spacer()
                    TextField("http://localhost:11434", text: $settings.ollamaEndpoint)
                        .frame(width: 240)
                        .textFieldStyle(.roundedBorder)
                }
                Picker("API mode", selection: $settings.ollamaApiMode) {
                    ForEach(AppSettings.OllamaAPIMode.allCases) { m in
                        Text(m.displayName).tag(m)
                    }
                }
                .pickerStyle(.segmented)
                HStack {
                    Text("Default model")
                    Spacer()
                    TextField("qwen2.5:14b", text: $settings.ollamaModel)
                        .frame(width: 200)
                        .textFieldStyle(.roundedBorder)
                }
                APIKeyField(
                    title: "Bearer token (optional)",
                    text: $settings.ollamaBearer,
                    onCommit: { settings.commit(.ollama, value: settings.ollamaBearer) }
                )
                Text("HTTP only allowed for localhost / 10.x / 172.16-31.x / 192.168.x. Use HTTPS for any other host.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                ConnectionTestRow(label: "Test connection", state: ollamaTestState) {
                    Task { await testOllama() }
                }
            }

            Section("Chat — video frames") {
                Toggle("Auto-attach baseline frames from session videos", isOn: $settings.chatVideoAutoFramesEnabled)
                if settings.chatVideoAutoFramesEnabled {
                    HStack {
                        Text("Frames per message")
                        Slider(value: Binding(
                            get: { Double(settings.chatVideoAutoFramesCount) },
                            set: { settings.chatVideoAutoFramesCount = Int($0.rounded()) }
                        ), in: 1...10, step: 1)
                        Text("\(settings.chatVideoAutoFramesCount)")
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(.secondary)
                            .frame(width: 30, alignment: .trailing)
                    }
                }
                Text("When ON, every Chat message with an attached session that has screen.mp4 sends N evenly-spaced frames to the LLM as vision context — without needing to type a timestamp. Lets the model 'see' the whole video. Costs more tokens; needs a vision-capable provider (Claude Sonnet, GPT-4o, Gemini). Cap is shared with timestamp-extracted frames at 10 per message.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Cost cap") {
                HStack {
                    Text("Per-session limit")
                    Spacer()
                    TextField("USD", value: $settings.costCapUSD, format: .currency(code: "USD"))
                        .frame(width: 100)
                        .textFieldStyle(.roundedBorder)
                }
                Text(SettingsCopy.costCapDescription)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Semantic search") {
                Toggle("Enable embedding-based semantic search", isOn: $settings.semanticSearchEnabled)
                Text("On finalize, sessions are embedded via OpenAI text-embedding-3-small (~$0.02 per 1M tokens) and stored locally. Searches augment FTS5 with cosine-similar matches. Requires an OpenAI API key.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Default summary language") {
                Picker("Language", selection: $settings.summaryLanguage) {
                    Text("Auto detected").tag("auto")
                    Text("English").tag("en")
                    Text("Українська").tag("uk")
                    Text("Русский").tag("ru")
                    Text("Français").tag("fr")
                    Text("Deutsch").tag("de")
                    Text("Español").tag("es")
                }
                Text("This is the default. Each recording can override at start time (Phase B Week 1 Day 4 — UI lands later).")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }

    // MARK: - Connection probe helpers

    /// Minimal probe: POST /v1/messages with max_tokens=5. 200 → success, else fail.
    private func testAnthropic() async {
        anthropicTestState = .testing
        let key = settings.anthropicApiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty else {
            anthropicTestState = .failed("No API key set")
            return
        }
        var req = URLRequest(url: URL(string: "https://api.anthropic.com/v1/messages")!)
        req.httpMethod = "POST"
        req.setValue(key, forHTTPHeaderField: "x-api-key")
        req.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        req.setValue("application/json", forHTTPHeaderField: "content-type")
        req.httpBody = try? JSONSerialization.data(withJSONObject: [
            "model": "claude-sonnet-4-6",
            "max_tokens": 5,
            "messages": [["role": "user", "content": "hi"]],
        ])
        anthropicTestState = await probe(request: req)
    }

    /// Minimal probe: GET /v1/models with Bearer auth. 200 → success.
    private func testOpenAI() async {
        openaiTestState = .testing
        let key = settings.openaiApiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty else {
            openaiTestState = .failed("No API key set")
            return
        }
        var req = URLRequest(url: URL(string: "https://api.openai.com/v1/models")!)
        req.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        openaiTestState = await probe(request: req)
    }

    /// Minimal probe: GET /api/tags on the configured Ollama endpoint. Surfaces
    /// the RFC1918-validation error inline if the user typed a public-IP HTTP URL.
    private func testOllama() async {
        ollamaTestState = .testing
        guard let url = URL(string: settings.ollamaEndpoint) else {
            ollamaTestState = .failed("Invalid URL")
            return
        }
        // Re-use the provider-level RFC1918 check so the error message matches reality.
        do {
            try OllamaProvider.validate(endpoint: url)
        } catch {
            ollamaTestState = .failed("Endpoint not allowed (use HTTPS or RFC1918)")
            return
        }
        var req = URLRequest(url: url.appendingPathComponent("api/tags"))
        req.httpMethod = "GET"
        let bearer = settings.ollamaBearer.trimmingCharacters(in: .whitespacesAndNewlines)
        if !bearer.isEmpty {
            req.setValue("Bearer \(bearer)", forHTTPHeaderField: "Authorization")
        }
        ollamaTestState = await probe(request: req)
    }

    /// Minimal probe: GET /api/v1/models on OpenRouter. 200 → success.
    private func testOpenRouter() async {
        openrouterTestState = .testing
        let key = settings.openrouterApiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty else {
            openrouterTestState = .failed("No API key set")
            return
        }
        var req = URLRequest(url: URL(string: "https://openrouter.ai/api/v1/models")!)
        req.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        openrouterTestState = await probe(request: req)
    }

    /// Fires the request and maps the HTTP status to a ConnectionTestState.
    private func probe(request: URLRequest) async -> ConnectionTestState {
        do {
            let (_, response) = try await URLSession.shared.data(for: request)
            if let http = response as? HTTPURLResponse {
                if http.statusCode == 200 {
                    return .success
                } else {
                    return .failed("HTTP \(http.statusCode)")
                }
            }
            return .failed("Non-HTTP response")
        } catch {
            return .failed(error.localizedDescription)
        }
    }
}

// MARK: - ConnectionTestState

/// State machine for a single Test-connection button.
private enum ConnectionTestState: Equatable {
    case idle
    case testing
    case success
    case failed(String)
}

// MARK: - ConnectionTestRow

/// A row with a "Test connection" button and a small inline status indicator.
@available(macOS 14.0, *)
private struct ConnectionTestRow: View {
    let label: String
    let state: ConnectionTestState
    let action: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            Button(label, action: action)
                .disabled(state == .testing)
            switch state {
            case .idle:
                EmptyView()
            case .testing:
                ProgressView()
                    .scaleEffect(0.6)
                    .frame(width: 14, height: 14)
            case .success:
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(.green)
            case .failed(let msg):
                Image(systemName: "xmark.circle.fill")
                    .foregroundStyle(.red)
                Text(msg)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }
}

// MARK: - Dictation tab

@available(macOS 14.0, *)
private struct DictationTab: View {
    @Bindable var settings: AppSettings

    var body: some View {
        Form {
            TriggerPickerSection(
                title: "Hotkey",
                description: "Press and hold the global hotkey to dictate. Release to paste a cleaned transcript into the focused text field.",
                trigger: $settings.dictationTrigger,
                comboName: .dictation,
                comboHint: "Default: ⌘⇧D. Click the recorder to rebind. Uses the system hotkey API — no extra permissions required."
            )

            Section("Cleanup") {
                Toggle("Run LLM cleanup pass before pasting", isOn: $settings.dictationLLMCleanup)
                Text("Uses the configured AI Provider (Anthropic / OpenAI / Ollama) to fix punctuation, casing, and remove disfluencies. Adds ~1–2 s latency. Off = paste raw Whisper transcript.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Insertion strategy") {
                Picker("Method", selection: $settings.dictationInsertion) {
                    ForEach(DictationInsertionStrategy.allCases, id: \.self) { option in
                        Text(option.displayName).tag(option)
                    }
                }
                .pickerStyle(.radioGroup)
                .labelsHidden()

                Text(settings.dictationInsertion.detailDescription)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Section("Limits") {
                Stepper(value: $settings.dictationMaxSeconds, in: 10...120, step: 5) {
                    Text("Max utterance: \(settings.dictationMaxSeconds) seconds")
                }
                Text("Hard cap on a single dictation press-and-hold. Hitting the cap stops the recording automatically.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Permission") {
                Text("First press triggers a macOS Accessibility permission prompt. Grant in System Settings → Privacy & Security → Accessibility, then quit + relaunch KosmoNotes for the trust to take effect.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }
}

// MARK: - TriggerPickerSection (reusable)

/// One Form Section that surfaces the configurable HotkeyTrigger for any
/// press/hold/release feature (Dictation, Push-to-Markdown, Agent). The
/// .doubleTapModifier variant is intentionally hidden from the picker —
/// none of the consumers support it (they all need a release event), and
/// TriggerHotkeyInstaller falls back to .combo at install time if a stale
/// pref ever lands there.
@available(macOS 14.0, *)
private struct TriggerPickerSection: View {
    let title: String
    let description: String
    @Binding var trigger: HotkeyTrigger
    let comboName: KeyboardShortcuts.Name
    /// Sub-caption shown under the combo Recorder (e.g. "Default: ⌘⇧D").
    let comboHint: String

    /// 200 ms is short enough to feel instant but long enough that a stray
    /// brush of the key doesn't fire accidentally.
    private static let defaultHoldMs = 200

    private enum Kind: String, CaseIterable, Identifiable {
        case combo, holdKey
        var id: String { rawValue }
        var displayName: String {
            switch self {
            case .combo:   return "Key combination"
            case .holdKey: return "Hold a key"
            }
        }
    }

    var body: some View {
        Section(title) {
            Text(description)
                .font(.callout)
                .foregroundStyle(.secondary)

            Picker("Trigger type", selection: kindBinding) {
                ForEach(Kind.allCases) { Text($0.displayName).tag($0) }
            }

            switch trigger {
            case .combo:
                KeyboardShortcuts.Recorder("Combination", name: comboName)
                Text(comboHint)
                    .font(.caption)
                    .foregroundStyle(.secondary)

            case .holdKey(let key, let ms):
                Picker("Key", selection: holdKeyBinding(currentMs: ms)) {
                    ForEach(HoldKey.allCases, id: \.self) { Text($0.displayName).tag($0) }
                }
                Stepper(value: holdMsBinding(currentKey: key), in: 50...2000, step: 50) {
                    Text("Hold for \(ms) ms")
                }
                Text("Hold the chosen key past the threshold to start; release to stop. Requires Accessibility permission (System Settings → Privacy & Security → Accessibility) — first install will prompt.")
                    .font(.caption)
                    .foregroundStyle(.secondary)

            case .doubleTapModifier:
                // Defensive: a stale pref. install() falls back to .combo at
                // runtime; show a hint so the UI doesn't look broken.
                Text("Double-tap is not supported for press/hold/release. Pick Combination or Hold instead.")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }
        }
    }

    // MARK: - Bindings

    private var kindBinding: Binding<Kind> {
        Binding(
            get: {
                switch trigger {
                case .combo:                return .combo
                case .holdKey:              return .holdKey
                case .doubleTapModifier:    return .combo  // unsupported collapses
                }
            },
            set: { newKind in
                switch newKind {
                case .combo:
                    trigger = .combo
                case .holdKey:
                    if case .holdKey = trigger { break }   // keep existing sub-config
                    // Default to Right ⌘ — closest thing macOS has to a dedicated
                    // push-to-talk key (no accidental conflicts with text input).
                    trigger = .holdKey(.rightCommand, minHoldMs: Self.defaultHoldMs)
                }
            }
        )
    }

    private func holdKeyBinding(currentMs: Int) -> Binding<HoldKey> {
        Binding(
            get: {
                if case .holdKey(let k, _) = trigger { return k }
                return .rightCommand
            },
            set: { newKey in trigger = .holdKey(newKey, minHoldMs: currentMs) }
        )
    }

    private func holdMsBinding(currentKey: HoldKey) -> Binding<Int> {
        Binding(
            get: {
                if case .holdKey(_, let ms) = trigger { return ms }
                return Self.defaultHoldMs
            },
            set: { newMs in trigger = .holdKey(currentKey, minHoldMs: newMs) }
        )
    }
}

// MARK: - Hotkeys tab

@available(macOS 14.0, *)
private struct HotkeysTab: View {
    @Bindable var settings: AppSettings

    /// Picker option type — `nil` modifier collapses to "Disabled" so the
    /// optional `DoubleTapModifier?` round-trips through SwiftUI tagging.
    private enum LibraryDoubleTapChoice: Hashable, Identifiable {
        case disabled
        case modifier(DoubleTapModifier)
        var id: String {
            if case .modifier(let m) = self { return m.rawValue }
            return "disabled"
        }
        var displayName: String {
            switch self {
            case .disabled: return "Disabled"
            case .modifier(let m): return "Double-tap \(m.displayName)"
            }
        }
    }

    var body: some View {
        Form {
            Section("Global hotkeys") {
                KeyboardShortcuts.Recorder("Meeting record toggle", name: .toggleMeeting)
                KeyboardShortcuts.Recorder("Open Library", name: .openLibrary)
                KeyboardShortcuts.Recorder("Dictation (push-to-talk)", name: .dictation)
                KeyboardShortcuts.Recorder("Push-to-Markdown (hold + speak → save .md)", name: .pushToMarkdown)
                KeyboardShortcuts.Recorder("Agent (hold + speak → autonomous agent)", name: .agentTrigger)
                KeyboardShortcuts.Recorder("Drawing overlay (toggle)", name: .toggleAnnotation)
            }

            Section("Library double-tap (optional)") {
                Picker("Open Library on", selection: libraryDoubleTapBinding) {
                    Text(LibraryDoubleTapChoice.disabled.displayName).tag(LibraryDoubleTapChoice.disabled)
                    ForEach(DoubleTapModifier.allCases, id: \.self) { mod in
                        Text(LibraryDoubleTapChoice.modifier(mod).displayName)
                            .tag(LibraryDoubleTapChoice.modifier(mod))
                    }
                }
                Text("Quick one-shot shortcut alongside the combo. Tap twice within 350 ms — either side counts. Routed through the same CGEventTap as Dictation hold-key, so it needs Accessibility permission to fire (System Settings → Privacy & Security → Accessibility).")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Defaults") {
                Text("⌘⇧R — Meeting record · ⌘⇧L — Library · ⌘⇧D — Dictation")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }

    private var libraryDoubleTapBinding: Binding<LibraryDoubleTapChoice> {
        Binding(
            get: {
                if let mod = settings.libraryDoubleTapModifier { return .modifier(mod) }
                return .disabled
            },
            set: { newChoice in
                switch newChoice {
                case .disabled:           settings.libraryDoubleTapModifier = nil
                case .modifier(let mod):  settings.libraryDoubleTapModifier = mod
                }
            }
        )
    }
}

// MARK: - Sharing tab

@available(macOS 14.0, *)
private struct SharingTab: View {
    @Bindable var settings: AppSettings

    var body: some View {
        Form {
            Section("S3-compatible upload") {
                HStack {
                    Text("Endpoint")
                    Spacer()
                    TextField("https://s3.amazonaws.com", text: $settings.s3Endpoint)
                        .frame(width: 280)
                        .textFieldStyle(.roundedBorder)
                }
                HStack {
                    Text("Region")
                    Spacer()
                    TextField("us-east-1", text: $settings.s3Region)
                        .frame(width: 140)
                        .textFieldStyle(.roundedBorder)
                }
                HStack {
                    Text("Bucket")
                    Spacer()
                    TextField("kosmonotes", text: $settings.s3Bucket)
                        .frame(width: 200)
                        .textFieldStyle(.roundedBorder)
                }
                APIKeyField(
                    title: "Access Key ID",
                    text: $settings.s3AccessKey,
                    onCommit: { settings.commit(.s3AccessKey, value: settings.s3AccessKey) }
                )
                APIKeyField(
                    title: "Secret Access Key",
                    text: $settings.s3SecretKey,
                    onCommit: { settings.commit(.s3SecretKey, value: settings.s3SecretKey) }
                )
                Stepper(value: $settings.s3PresignTTLHours, in: 1...168) {
                    Text("Presigned link TTL: \(settings.s3PresignTTLHours)h")
                }
                Text("Works with AWS S3, Cloudflare R2 (region: auto), Backblaze B2, MinIO, RustFS — any S3-compatible endpoint. Sig V4 auth. Recipients open the presigned URL in a browser.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }
}


// MARK: - Privacy tab

@available(macOS 14.0, *)
private struct PrivacyTab: View {
    /// Bumped on every appear and after each "Refresh" tap so the cached
    /// permission badges re-read CGPreflightScreenCaptureAccess /
    /// AVCaptureDevice.authorizationStatus / AXIsProcessTrusted.
    @State private var refreshTick: Int = 0
    @State private var confirmReset: Bool = false
    @State private var resetResult: String? = nil

    var body: some View {
        Form {
            Section("Permissions") {
                PermissionRow(
                    title: "Microphone",
                    systemImage: "mic.fill",
                    detail: "Required for every recording — captures your voice.",
                    status: micStatusText,
                    granted: micGranted,
                    requestLabel: "Request",
                    onRequest: { Task { _ = await PermissionsHelper.requestMicAccess(); refreshTick &+= 1 } },
                    onOpen: { PermissionsHelper.openMicSettings() }
                )

                PermissionRow(
                    title: "Screen Recording",
                    systemImage: "rectangle.dashed.badge.record",
                    detail: "Required for Audio + Screen mode and for system-audio capture (e.g. recording call participants).",
                    status: screenStatusText,
                    granted: PermissionsHelper.screenRecordingGranted(),
                    requestLabel: "Request",
                    onRequest: {
                        PermissionsHelper.requestScreenRecordingAccess()
                        refreshTick &+= 1
                    },
                    onOpen: { PermissionsHelper.openScreenRecordingSettings() }
                )

                PermissionRow(
                    title: "Accessibility",
                    systemImage: "accessibility",
                    detail: "Only needed for Dictation Mode — pastes the cleaned transcript into the focused text field.",
                    status: axStatusText,
                    granted: PermissionsHelper.accessibilityGranted(),
                    requestLabel: "Open Settings",
                    onRequest: { PermissionsHelper.openAccessibilitySettings() },
                    onOpen: { PermissionsHelper.openAccessibilitySettings() }
                )

                PermissionRow(
                    title: "Camera",
                    systemImage: "video.fill",
                    detail: "Only needed for the Loom-style webcam bubble during Audio + Screen recordings.",
                    status: cameraStatusText,
                    granted: PermissionsHelper.cameraGranted(),
                    requestLabel: "Request",
                    onRequest: { Task { _ = await PermissionsHelper.requestCameraAccess(); refreshTick &+= 1 } },
                    onOpen: { PermissionsHelper.openCameraSettings() }
                )

                HStack {
                    Button(role: .destructive) {
                        confirmReset = true
                    } label: {
                        Label("Reset all permissions", systemImage: "arrow.counterclockwise.circle")
                    }
                    .help("Runs `tccutil reset All dev.kosmonotes.studio` so macOS will re-prompt fresh on the next recording. Use this when you granted access but the app still refuses (cdhash mismatch from rebuild).")

                    Spacer()
                    Button("Refresh status") { refreshTick &+= 1 }
                        .buttonStyle(.borderless)
                }

                Text("Tip: ad-hoc-signed dev builds change their code-signature hash on every rebuild, which can leave a stale TCC entry that shows as granted in System Settings but isn't honored at runtime. Click **Reset all permissions** to clear the slate, then re-grant on the next macOS prompt.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .id(refreshTick)
            .confirmationDialog(
                "Reset all KosmoNotes permissions?",
                isPresented: $confirmReset,
                titleVisibility: .visible
            ) {
                Button("Reset", role: .destructive) {
                    runTCCReset()
                }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("Microphone, Screen Recording, and Accessibility grants for `dev.kosmonotes.studio` will be cleared. macOS will prompt for them again the next time you start recording. KosmoNotes will need to be quit & relaunched after the prompts.")
            }
            .alert("Permissions reset", isPresented: Binding(
                get: { resetResult != nil },
                set: { if !$0 { resetResult = nil } }
            )) {
                Button("OK", role: .cancel) { resetResult = nil }
            } message: {
                Text(resetResult ?? "")
            }

            Section("How KosmoNotes handles your audio") {
                Text(SettingsCopy.audioHandling)
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.leading)
            }

            Section("Screen recording") {
                Text("""
                When "Audio + Screen" mode is enabled, KosmoNotes captures your \
                entire display alongside audio and saves a screen.mp4 sidecar next \
                to the audio file. Screen content is used locally for vision-chat \
                frame extraction — it is never uploaded to any cloud service. \
                macOS will request Screen Recording permission on the first recording.
                """)
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.leading)
            }
        }
        .formStyle(.grouped)
        .onAppear { refreshTick &+= 1 }
    }

    // MARK: - Status helpers

    private var micGranted: Bool {
        PermissionsHelper.micAuthStatus() == .authorized
    }

    private var micStatusText: String {
        switch PermissionsHelper.micAuthStatus() {
        case .authorized: return "Granted"
        case .denied: return "Denied"
        case .restricted: return "Restricted"
        case .notDetermined: return "Not requested"
        @unknown default: return "Unknown"
        }
    }

    private var screenStatusText: String {
        PermissionsHelper.screenRecordingGranted() ? "Granted" : "Not granted"
    }

    private var axStatusText: String {
        PermissionsHelper.accessibilityGranted() ? "Granted" : "Not granted"
    }

    private var cameraStatusText: String {
        switch PermissionsHelper.cameraAuthStatus() {
        case .authorized: return "Granted"
        case .denied: return "Denied"
        case .restricted: return "Restricted"
        case .notDetermined: return "Not requested"
        @unknown default: return "Unknown"
        }
    }

    /// Spawn `/usr/bin/tccutil reset All dev.kosmonotes.studio` and report
    /// the verdict via the alert. Runs synchronously on a background queue so
    /// SwiftUI doesn't stall during the ~50ms IPC. No admin needed — tccutil
    /// works at the user-level for app-scoped resets.
    private func runTCCReset() {
        let bundleID = "dev.kosmonotes.studio"
        DispatchQueue.global(qos: .userInitiated).async {
            let task = Process()
            task.executableURL = URL(fileURLWithPath: "/usr/bin/tccutil")
            task.arguments = ["reset", "All", bundleID]
            let pipe = Pipe()
            task.standardOutput = pipe
            task.standardError = pipe
            do {
                try task.run()
                task.waitUntilExit()
                let data = (try? pipe.fileHandleForReading.readToEnd()) ?? Data()
                let output = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                Task { @MainActor in
                    if task.terminationStatus == 0 {
                        resetResult = "All Microphone, Screen Recording, and Accessibility entries for \(bundleID) were cleared. Quit KosmoNotes and re-launch from /Applications, then start a recording — macOS will prompt fresh for each permission."
                    } else {
                        resetResult = "tccutil exited with status \(task.terminationStatus). Output:\n\(output.isEmpty ? "<empty>" : output)"
                    }
                    refreshTick &+= 1
                }
            } catch {
                Task { @MainActor in
                    resetResult = "Could not run tccutil: \(error.localizedDescription)"
                }
            }
        }
    }
}

/// One row per TCC permission. Status badge + Request + Open System Settings.
@available(macOS 14.0, *)
private struct PermissionRow: View {
    let title: String
    let systemImage: String
    let detail: String
    let status: String
    let granted: Bool
    let requestLabel: String
    let onRequest: () -> Void
    let onOpen: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 10) {
                Image(systemName: systemImage)
                    .frame(width: 22)
                    .foregroundStyle(.secondary)
                Text(title)
                    .font(.body.weight(.medium))
                Spacer()
                StatusBadge(text: status, granted: granted)
            }
            Text(detail)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 8) {
                Button(requestLabel, action: onRequest)
                    .buttonStyle(.bordered)
                Button("Open System Settings", action: onOpen)
                    .buttonStyle(.bordered)
            }
        }
        .padding(.vertical, 4)
    }
}

@available(macOS 14.0, *)
private struct StatusBadge: View {
    let text: String
    let granted: Bool

    var body: some View {
        Text(text)
            .font(.caption.weight(.semibold))
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(
                Capsule().fill(granted ? Color.green.opacity(0.18) : Color.orange.opacity(0.18))
            )
            .foregroundStyle(granted ? Color.green : Color.orange)
    }
}

// MARK: - APIKeyField

/// SecureField with a Show/Hide eye and a Save button that commits to Keychain.
@available(macOS 14.0, *)
private struct APIKeyField: View {
    let title: String
    @Binding var text: String
    let onCommit: () -> Void

    @State private var revealed = false

    var body: some View {
        HStack {
            Group {
                if revealed {
                    TextField(title, text: $text)
                } else {
                    SecureField(title, text: $text)
                }
            }
            .textFieldStyle(.roundedBorder)
            .autocorrectionDisabled()

            Button {
                revealed.toggle()
            } label: {
                Image(systemName: revealed ? "eye.slash" : "eye")
            }
            .buttonStyle(.borderless)
            .help(revealed ? "Hide" : "Show")

            Button("Save", action: onCommit)
                .keyboardShortcut(.defaultAction)
        }
    }
}

// MARK: - ScreenDisplayPicker

/// Picker for the display to capture in Audio + Screen mode (Settings →
/// Transcription). Loads the live display list from ScreenCaptureKit on
/// appear — external monitors appear once Screen Recording permission is
/// granted. "Auto" (tag = 0) defers to ScreenRecorder's first-display fallback.
@available(macOS 14.0, *)
private struct ScreenDisplayPicker: View {
    @Bindable var settings: AppSettings
    @State private var displays: [DisplayInfo] = []
    @State private var loadError: String? = nil
    @State private var refreshTick: Int = 0

    struct DisplayInfo: Identifiable, Sendable, Hashable {
        let id: UInt32   // CGDirectDisplayID
        let width: Int
        let height: Int
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Picker("Display", selection: $settings.screenCaptureDisplayID) {
                Text("Auto (primary display)").tag(UInt32(0))
                if !displays.isEmpty {
                    Divider()
                    ForEach(displays) { d in
                        Text("Display \(d.id) — \(d.width)×\(d.height)").tag(d.id)
                    }
                }
            }
            .id(refreshTick)

            HStack(spacing: 8) {
                Button("Refresh display list") {
                    Task { await load() }
                }
                .buttonStyle(.borderless)
                .controlSize(.small)

                if settings.screenCaptureDisplayID != 0,
                   !displays.contains(where: { $0.id == settings.screenCaptureDisplayID }) {
                    Label("Selected display not connected — will fall back to primary",
                          systemImage: "exclamationmark.triangle.fill")
                        .font(.caption)
                        .foregroundStyle(.orange)
                }
            }

            if let err = loadError {
                Text(err)
                    .font(.caption)
                    .foregroundStyle(.red)
            }
        }
        .task { await load() }
    }

    @MainActor
    private func load() async {
        do {
            let content = try await SCShareableContent.excludingDesktopWindows(
                false, onScreenWindowsOnly: true
            )
            self.displays = content.displays
                .map { DisplayInfo(id: $0.displayID, width: $0.width, height: $0.height) }
                .sorted { $0.id < $1.id }
            self.loadError = nil
            self.refreshTick &+= 1
        } catch {
            self.displays = []
            self.loadError = "Could not list displays — Screen Recording permission may be missing. (\(error.localizedDescription))"
        }
    }
}

// MARK: - SystemAudioSourcePicker

/// Picker for the system-audio source (Settings → Transcription).
///
/// "Default (ScreenCaptureKit)" reads system audio via SCStream — captures
/// whatever speakers play. The downside: if you record without headphones,
/// the mic picks up the speakers' output, doubling the recorded audio.
///
/// Picking a virtual loopback device (BlackHole 2ch / Loopback) lets the user
/// route system audio through a software cable that the mic doesn't hear.
/// Echo cancellation is the first-line fix; loopback devices remain useful
/// when users deliberately disable DSP cancellation.
/// Setup: install BlackHole (`brew install blackhole-2ch`), in Audio MIDI Setup
/// create a Multi-Output Device (BlackHole + headphones), set system output
/// to it, then pick BlackHole here. Echo gone.
@available(macOS 14.0, *)
private struct SystemAudioSourcePicker: View {
    @Bindable var settings: AppSettings
    @State private var devices: [AudioInputDevice] = []
    @State private var refreshTick: Int = 0

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Picker("Source", selection: $settings.systemAudioDeviceUID) {
                Text("Default (ScreenCaptureKit)").tag("")
                if !devices.isEmpty {
                    Divider()
                    ForEach(devices) { device in
                        HStack {
                            Image(systemName: device.isVirtualLoopback ? "waveform.path.ecg" : "mic")
                                .foregroundStyle(device.isVirtualLoopback ? .green : .secondary)
                            Text(device.name)
                            if device.isVirtualLoopback {
                                Text("loopback").font(.caption).foregroundStyle(.secondary)
                            }
                        }
                        .tag(device.uid)
                    }
                }
            }
            .id(refreshTick)

            HStack(spacing: 8) {
                Button("Refresh device list") {
                    devices = AudioInputDevice.fresh()
                    refreshTick &+= 1
                }
                .buttonStyle(.borderless)
                .controlSize(.small)

                if !settings.systemAudioDeviceUID.isEmpty,
                   !devices.contains(where: { $0.uid == settings.systemAudioDeviceUID }) {
                    Label("Selected device not connected", systemImage: "exclamationmark.triangle.fill")
                        .font(.caption)
                        .foregroundStyle(.orange)
                }
            }

            VStack(alignment: .leading, spacing: 4) {
                Text("Default route is ScreenCaptureKit's whole-system mixdown — captures whatever your speakers play. Echo cancellation is the first-line fix for speaker playback; without it or headphones, the mic picks up that audio too, doubling voices in the recording.")
                Text("If you turn Echo cancellation off, pick a virtual loopback device (BlackHole 2ch, Loopback) to route system audio through a software cable the mic doesn't hear. Setup:")
                Text("1. brew install blackhole-2ch")
                    .font(.system(.caption2, design: .monospaced))
                Text("2. Audio MIDI Setup → Create Multi-Output Device with BlackHole + your real output (speakers/headphones)")
                Text("3. System Settings → Sound → Output: pick the Multi-Output Device")
                Text("4. Refresh this list and pick BlackHole below.")
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        }
        .onAppear {
            devices = AudioInputDevice.fresh()
        }
    }
}

@available(macOS 14.0, *)
private extension AudioInputDevice {
    /// Tiny convenience wrapper so the view can call `.fresh()` instead of
    /// touching the enumerator directly.
    static func fresh() -> [AudioInputDevice] {
        AudioDeviceEnumerator.inputDevices()
    }
}

// MARK: - AgentTab

/// Settings for the autonomous voice-driven agent. Toggle, hotkey rebind
/// hint, workspace folder picker, max-iterations cap, and a TextEditor for
/// the system prompt.
@available(macOS 14.0, *)
private struct AgentTab: View {
    @Bindable var settings: AppSettings

    var body: some View {
        Form {
            Section("Autonomous agent") {
                Toggle("Enable agent hotkey", isOn: $settings.agentEnabled)
                Text("Hold the hotkey, speak an instruction, release. Whisper transcribes; the chosen backend runs an autonomous loop. Open the console (menu → Agent Console…) to watch the live log and inject extra instructions mid-run.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            TriggerPickerSection(
                title: "Agent trigger",
                description: "How the autonomous-agent hotkey fires.",
                trigger: $settings.agentTrigger,
                comboName: .agentTrigger,
                comboHint: "Default: ⌘⇧A. Click the recorder to rebind."
            )

            Section("Backend") {
                Picker("Driver", selection: $settings.agentBackend) {
                    ForEach(AppSettings.AgentBackendChoice.allCases) { choice in
                        Text(choice.displayName).tag(choice)
                    }
                }
                .pickerStyle(.menu)

                switch settings.agentBackend {
                case .builtin:
                    Picker("Model", selection: $settings.agentBuiltinModel) {
                        ForEach(AppSettings.AgentBuiltinModel.allCases) { choice in
                            Text(choice.displayName).tag(choice)
                        }
                    }
                    .pickerStyle(.menu)
                    Text("In-process Anthropic Messages API loop with bash / read_file / write_file tools sandboxed to the workspace folder. Uses your Anthropic API key. Sonnet 4.6 is the recommended default; Opus 4.7 is slower/more expensive but tackles harder reasoning; Haiku 4.5 is the cheapest for exploratory runs.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                case .claudeCode:
                    HStack {
                        TextField("`claude` binary path", text: $settings.agentClaudeCodeBin, prompt: Text("auto-detect (Homebrew / npm-global / $PATH)"))
                            .textFieldStyle(.roundedBorder)
                            .font(.system(.callout, design: .monospaced))
                        Button("Choose…") { pickBinary { settings.agentClaudeCodeBin = $0 } }
                    }
                    Text("Spawns `claude --print --output-format stream-json --verbose <instruction>` in the workspace folder. Reuses your existing claude.ai login — no API key needed here. Install with `npm install -g @anthropic-ai/claude-code` if missing.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                case .codex:
                    HStack {
                        TextField("`codex` binary path", text: $settings.agentCodexBin, prompt: Text("auto-detect (Homebrew / npm-global / $PATH)"))
                            .textFieldStyle(.roundedBorder)
                            .font(.system(.callout, design: .monospaced))
                        Button("Choose…") { pickBinary { settings.agentCodexBin = $0 } }
                    }
                    Text("Spawns `codex exec <instruction>` in the workspace folder. Uses your ChatGPT subscription / API key as configured in the Codex CLI. Install with `npm install -g @openai/codex` if missing.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                case .copilot:
                    HStack {
                        TextField("`gh` binary path", text: $settings.agentCopilotBin, prompt: Text("auto-detect (Homebrew / $PATH)"))
                            .textFieldStyle(.roundedBorder)
                            .font(.system(.callout, design: .monospaced))
                        Button("Choose…") { pickBinary { settings.agentCopilotBin = $0 } }
                    }
                    Text("Spawns `gh copilot suggest -t shell <question>`. Requires `gh auth login` and `gh extension install github/gh-copilot`. One-shot — mid-session injection is not supported here.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Section("Workspace folder") {
                HStack(alignment: .top) {
                    TextField("Path", text: $settings.agentWorkspaceFolder, prompt: Text("~/Documents/KosmoNotes-agent (default)"))
                        .textFieldStyle(.roundedBorder)
                        .font(.system(.callout, design: .monospaced))
                    Button("Choose…") { pickWorkspaceFolder() }
                }
                Text("All bash / read_file / write_file calls are sandboxed inside this directory. Path traversal (../etc/passwd) is rejected. Empty = use the default `~/Documents/KosmoNotes-agent` (created on first run).")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Iteration cap") {
                Stepper(value: $settings.agentMaxIterations, in: 3...30, step: 1) {
                    Text("Max iterations: \(settings.agentMaxIterations)")
                }
                Text("Each iteration = one round-trip to Claude + zero or more tool runs. Hitting the cap stops the agent automatically (runaway protection).")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("System prompt") {
                TextEditor(text: $settings.agentSystemPrompt)
                    .font(.system(.callout, design: .monospaced))
                    .frame(minHeight: 200)
                    .border(Color(NSColor.separatorColor), width: 1)
                HStack {
                    Text("Sent as Claude's `system` message every iteration. The workspace path + macOS version are appended automatically at run time.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button("Reset to default") {
                        settings.agentSystemPrompt = AppSettings.defaultAgentSystemPrompt
                    }
                    .buttonStyle(.borderless)
                    .controlSize(.small)
                }
            }

            Section("Session logs") {
                let logsDir = (try? FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: false))?
                    .appendingPathComponent("KosmoNotes/agent-sessions").path
                    ?? "~/Library/Application Support/KosmoNotes/agent-sessions"
                Text("Each session writes a JSONL log to:")
                    .font(.caption)
                Text(logsDir)
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(.secondary)
                Button("Open logs folder") {
                    if let url = URL(string: "file://" + logsDir) {
                        NSWorkspace.shared.open(url)
                    }
                }
                .buttonStyle(.borderless)
                .controlSize(.small)
            }
        }
        .formStyle(.grouped)
    }

    private func pickWorkspaceFolder() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.prompt = "Choose"
        panel.title = "Pick the agent workspace folder"
        if panel.runModal() == .OK, let url = panel.url {
            settings.agentWorkspaceFolder = url.path
        }
    }

    /// File-picker for absolute CLI binary paths (claude / codex / gh).
    /// Permits any executable; the runner verifies `isExecutableFile` at spawn.
    private func pickBinary(_ commit: (String) -> Void) {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.treatsFilePackagesAsDirectories = true
        panel.showsHiddenFiles = true
        panel.prompt = "Use binary"
        panel.title = "Pick the CLI binary"
        if panel.runModal() == .OK, let url = panel.url {
            commit(url.path)
        }
    }
}

// MARK: - MarkdownExportTab

/// Settings tab for the post-recording Markdown export pipeline. Lets the
/// user toggle the feature, pick an output folder via NSOpenPanel, and
/// edit the system + user prompts that drive formatting. Works alongside
/// (not instead of) the built-in `summary.md` — those use our PromptTemplates
/// in `Sources/AIKit/`; this tab is whatever the user wants their .md to
/// look like.
@available(macOS 14.0, *)
private struct MarkdownExportTab: View {
    @Bindable var settings: AppSettings

    var body: some View {
        Form {
            Section("Markdown export") {
                Toggle("Save formatted Markdown after every recording", isOn: $settings.markdownExportEnabled)
                Text("After transcription + cleanup, the cleaned transcript is sent through your configured LLM (AI Providers tab) with the prompts below, and the result is written as a .md file at the folder you pick. Independent of summary.md inside the session folder. Failures are non-fatal — recording stays usable.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Push-to-Markdown") {
                Toggle("Enable push-to-Markdown hotkey", isOn: $settings.pushToMarkdownEnabled)
                Text("Hold the hotkey, speak, release. The cleaned transcript is run through the SAME prompts + saved into the SAME folder as the post-recording Markdown export above — but as a separate file per press. No popover, no library entry — fast \"voice → markdown note\" capture.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            TriggerPickerSection(
                title: "Push-to-Markdown trigger",
                description: "How the push-to-Markdown hotkey fires. Same options as Dictation — pick a combo (default ⌘⇧Y) or hold a single key.",
                trigger: $settings.pushToMarkdownTrigger,
                comboName: .pushToMarkdown,
                comboHint: "Default: ⌘⇧Y. Click the recorder to rebind."
            )

            Section("Output folder") {
                HStack(alignment: .top) {
                    TextField("Path", text: $settings.markdownExportFolder, prompt: Text("~/Documents/KosmoNotes (default)"))
                        .textFieldStyle(.roundedBorder)
                        .font(.system(.callout, design: .monospaced))
                    Button("Choose…") { pickFolder() }
                }
                Text("Empty = use the default `~/Documents/KosmoNotes`. Filenames are auto-generated as `<date>_<mode>_<short-id>.md` so two recordings in the same minute don't collide.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("System prompt") {
                TextEditor(text: $settings.markdownExportSystemPrompt)
                    .font(.system(.callout, design: .monospaced))
                    .frame(minHeight: 160)
                    .border(Color(NSColor.separatorColor), width: 1)
                HStack {
                    Text("This is what the LLM gets as `system`. Sets the formatter persona and structural rules.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button("Reset to default") {
                        settings.markdownExportSystemPrompt = AppSettings.defaultMarkdownExportSystemPrompt
                    }
                    .buttonStyle(.borderless)
                    .controlSize(.small)
                }
            }

            Section("User prompt template") {
                TextEditor(text: $settings.markdownExportUserPrompt)
                    .font(.system(.callout, design: .monospaced))
                    .frame(minHeight: 100)
                    .border(Color(NSColor.separatorColor), width: 1)
                HStack {
                    Text("Use the placeholder `{transcript}` — it's replaced with the actual cleaned transcript at send time. If you remove the placeholder the transcript is still appended at the end.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button("Reset to default") {
                        settings.markdownExportUserPrompt = AppSettings.defaultMarkdownExportUserPrompt
                    }
                    .buttonStyle(.borderless)
                    .controlSize(.small)
                }
            }
        }
        .formStyle(.grouped)
    }

    /// NSOpenPanel folder picker. Sandbox is OFF (project.yml), so we don't
    /// need security-scoped bookmarks — the raw path string survives reboots.
    private func pickFolder() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.prompt = "Choose"
        panel.title = "Pick the Markdown export folder"
        if panel.runModal() == .OK, let url = panel.url {
            settings.markdownExportFolder = url.path
        }
    }
}

// MARK: - ProcessTapAppPicker

/// Multi-select picker for the per-process Core Audio Tap. Lists the apps
/// currently running with a regular UI, lets the user tick the ones whose
/// audio they want recorded. Selection persists into the comma-separated
/// `processTapBundleIDs` setting (legacy storage shape — kept so existing
/// installs don't lose their config).
@available(macOS 14.0, *)
private struct ProcessTapAppPicker: View {
    @Bindable var settings: AppSettings
    @State private var apps: [RunningAppInfo] = []
    @State private var refreshTick: Int = 0

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("Pick apps whose audio to capture")
                    .font(.callout)
                Spacer()
                Button("Refresh") {
                    apps = RunningAppsEnumerator.runningApps()
                    refreshTick &+= 1
                }
                .buttonStyle(.borderless)
                .controlSize(.small)
            }

            if apps.isEmpty {
                Text("No pickable apps found. Open the app you want to record from (Zoom, Meet, Slack, browser…), then tap Refresh.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 4) {
                        ForEach(apps) { app in
                            AppPickerRow(
                                app: app,
                                isSelected: selectedSet.contains(app.bundleID),
                                onToggle: { toggle(app.bundleID) }
                            )
                        }
                    }
                    .padding(.vertical, 4)
                }
                .frame(minHeight: 140, maxHeight: 240)
                .background(
                    RoundedRectangle(cornerRadius: 6)
                        .fill(Color(NSColor.textBackgroundColor))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 6)
                        .stroke(Color(NSColor.separatorColor), lineWidth: 1)
                )
                .id(refreshTick)
            }

            HStack(spacing: 8) {
                Text("Selected: \(selectedSet.count) app(s)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                if !selectedSet.isEmpty {
                    Button("Clear all") {
                        settings.processTapBundleIDs = ""
                    }
                    .buttonStyle(.borderless)
                    .controlSize(.small)
                }
            }

            Text("Apps not running at record-time are silently skipped. Tap fails gracefully → falls back to whole-system mixdown so you don't lose the recording. Per-process tap requires the system-audio toggle above to be ON regardless of whether you're in Audio + Screen or Audio-only mode.")
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        .onAppear {
            apps = RunningAppsEnumerator.runningApps()
        }
    }

    /// Parse the comma-separated stored string into a set for fast lookup.
    private var selectedSet: Set<String> {
        Set(settings.processTapBundleIDs
            .split(separator: ",")
            .map { String($0).trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty })
    }

    /// Flip membership for `bundleID` and re-serialize the set back to the
    /// stored comma-separated string. Sorted alphabetically so the persisted
    /// shape is stable (no diff churn on save).
    private func toggle(_ bundleID: String) {
        var set = selectedSet
        if set.contains(bundleID) { set.remove(bundleID) } else { set.insert(bundleID) }
        settings.processTapBundleIDs = set.sorted().joined(separator: ",")
    }
}

@available(macOS 14.0, *)
private struct AppPickerRow: View {
    let app: RunningAppInfo
    let isSelected: Bool
    let onToggle: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: isSelected ? "checkmark.square.fill" : "square")
                .foregroundStyle(isSelected ? Color.accentColor : Color.secondary)
                .frame(width: 18)
            if let url = app.bundleURL {
                Image(nsImage: NSWorkspace.shared.icon(forFile: url.path))
                    .resizable()
                    .frame(width: 18, height: 18)
            }
            VStack(alignment: .leading, spacing: 1) {
                Text(app.name)
                    .font(.callout)
                Text(app.bundleID)
                    .font(.caption2.monospaced())
                    .foregroundStyle(.tertiary)
            }
            Spacer()
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 3)
        .contentShape(Rectangle())
        .onTapGesture { onToggle() }
    }
}

// MARK: - CameraBubbleSettings

/// Toggle + camera-device picker + size slider for the Loom-style webcam
/// bubble. Lives inside the Transcription tab. The bubble itself is a
/// floating circular NSWindow that opens during Audio + Screen recordings;
/// ScreenCaptureKit captures the window as part of screen.mp4.
@available(macOS 14.0, *)
private struct CameraBubbleSettings: View {
    @Bindable var settings: AppSettings
    @State private var devices: [AVCaptureDevice] = []
    @State private var refreshTick: Int = 0

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Toggle("Show webcam bubble during Audio + Screen recordings", isOn: $settings.cameraBubbleEnabled)

            if settings.cameraBubbleEnabled {
                Picker("Camera", selection: $settings.cameraDeviceUID) {
                    Text("System default").tag("")
                    if !devices.isEmpty {
                        Divider()
                        ForEach(devices, id: \.uniqueID) { device in
                            Text(device.localizedName).tag(device.uniqueID)
                        }
                    }
                }
                .id(refreshTick)

                HStack {
                    Text("Size")
                    Slider(value: $settings.cameraBubbleSize, in: 120...400, step: 10)
                    Text("\(Int(settings.cameraBubbleSize)) pt")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                        .frame(width: 60, alignment: .trailing)
                }

                Button("Refresh camera list") {
                    devices = CameraBubble.availableDevices()
                    refreshTick &+= 1
                }
                .buttonStyle(.borderless)
                .controlSize(.small)
            }

            Text("Floating circular window with your front camera, draggable anywhere on screen. Captured by ScreenCaptureKit alongside the screen, so it lands inside `screen.mp4` automatically. Position and size are remembered between recordings. Camera permission is requested on first use.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .onAppear {
            devices = CameraBubble.availableDevices()
        }
    }
}

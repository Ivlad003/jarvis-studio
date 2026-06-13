@preconcurrency import AVFoundation
import Foundation
import Observation
import AIKit
import StorageKit
import TranscriptionKit

// MARK: - ChatState

/// Observable state for the Chat window.
///
/// Adds session-aware RAG context: FTS5 auto-search attaches the most relevant
/// recorded sessions as system-prompt context before each LLM call. Users can
/// also manually attach sessions via the picker sheet.
///
/// Provider is resolved per-call from `settings.llmProvider` so the user can
/// switch providers between messages without reopening the window.
///
/// Vision: when the user message contains timestamp patterns (0:30, 1:23:45,
/// "at minute 5", "на 3 хвилині"), ChatState extracts frames from screen.mp4
/// of attached sessions and appends them as image parts (cap: 3 frames/send).
@available(macOS 14.0, *)
@Observable
@MainActor
final class ChatState {

    static let defaultChatMaxTokens = 4_096
    typealias LiveContextProvider = @MainActor @Sendable () async -> LiveTranscriptState?
    typealias ProviderResolver = @MainActor @Sendable (AIProviderResolver.Config) -> AIProviderResolver.Resolved?

    // MARK: - Attached session discriminant

    enum AttachedSession: Hashable {
        case manual(SessionRecord)
        case autoFromSearch(SessionRecord, snippet: String)

        var record: SessionRecord {
            switch self {
            case .manual(let r): return r
            case .autoFromSearch(let r, _): return r
            }
        }

        // Hashable / Equatable on session id only — deduplicate by id.
        func hash(into hasher: inout Hasher) { hasher.combine(record.id) }
        static func == (lhs: AttachedSession, rhs: AttachedSession) -> Bool {
            lhs.record.id == rhs.record.id
        }
    }

    // MARK: - Observable state

    var messages: [ChatMessage] = []
    var inputDraft: String = ""
    var isSending: Bool = false
    var lastError: String?

    // Session context controls
    var autoSearchSessions: Bool = true
    var searchDepth: Int = 3
    var attachedSessions: [AttachedSession] = []

    // Live snapshot controls
    var snapshotQuestion: String = ""
    var isSnapshotting: Bool = false

    // Agent hand-off
    var isLaunchingAgent: Bool = false

    // MARK: - Dependencies
    // `database` is internal (not private) so ChatView can pass it to SessionPickerSheet.

    private let settings: AppSettings
    let database: AppDatabase
    private let sessionStore: SessionStore
    private let recorder: RecorderState
    private let knowledgeBaseStore: KnowledgeBaseStore?
    // Injectable factory so unit tests can swap WhisperProvider without network.
    private let whisperProviderFactory: @Sendable (String) -> WhisperProvider
    // Optional autonomous-agent hand-off. nil keeps the chat working stand-alone
    // (preview / unit tests) — the "Run as agent" button is hidden when unset.
    private let agentSession: AgentSessionState?
    private let onOpenAgentConsole: (@MainActor () -> Void)?
    private let liveContextProvider: LiveContextProvider?
    private let providerResolver: ProviderResolver

    // MARK: - Computed state exposed to the View

    /// True while a recording session is in progress (for input-mode switcher).
    var isRecording: Bool {
        if case .recording = recorder.status { return true }
        return false
    }

    // MARK: - Init

    init(
        settings: AppSettings,
        database: AppDatabase,
        sessionStore: SessionStore,
        recorder: RecorderState,
        knowledgeBaseStore: KnowledgeBaseStore? = nil,
        whisperProviderFactory: (@Sendable (String) -> WhisperProvider)? = nil,
        agentSession: AgentSessionState? = nil,
        onOpenAgentConsole: (@MainActor () -> Void)? = nil,
        liveContextProvider: LiveContextProvider? = nil,
        providerResolver: @escaping ProviderResolver = { AIProviderResolver.resolve($0) }
    ) {
        self.settings = settings
        self.database = database
        self.sessionStore = sessionStore
        self.recorder = recorder
        self.knowledgeBaseStore = knowledgeBaseStore
        self.agentSession = agentSession
        self.onOpenAgentConsole = onOpenAgentConsole
        self.liveContextProvider = liveContextProvider
        self.providerResolver = providerResolver
        // Default factory captures the user-selected OpenAI model
        // (whisper-1 / gpt-4o-transcribe / gpt-4o-mini-transcribe) at
        // init time, so chat-side audio snapshots use the same upgrade
        // path as the recorder's transcription. Tests still inject a
        // custom factory to short-circuit the network.
        let modelName = settings.openaiTranscribeModel.rawValue
        self.whisperProviderFactory = whisperProviderFactory ?? { apiKey in
            WhisperProvider(apiKey: apiKey, model: modelName)
        }
    }

    // MARK: - Agent hand-off

    /// Why `runAsAgent()` would refuse, or nil if the action is available.
    /// Drives the button's tooltip + enabled state.
    var runAsAgentDisabledReason: String? {
        guard let agent = agentSession else { return nil /* button hidden */ }
        if isSending { return "Sending a chat message — wait for it to finish" }
        if isLaunchingAgent { return "Launching agent…" }
        if case .running = agent.status { return "Agent is already running — stop it first" }
        // Built-in backend needs Anthropic key; CLI backends bring their own
        // auth (Claude Code, Codex, Copilot login).
        if settings.agentBackend == .builtin {
            let key = settings.anthropicApiKey.trimmingCharacters(in: .whitespacesAndNewlines)
            if key.isEmpty { return "Built-in agent needs Anthropic API key (Settings → AI Providers)" }
        }
        let hasDraft = !inputDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        let hasPriorUserTurn = messages.contains { $0.role == .user }
        if !hasDraft && !hasPriorUserTurn { return "Type a message or send something first" }
        return nil
    }

    /// True when the chat is wired to an autonomous agent and there's enough
    /// material (a draft or any prior user turn) to seed an agent run.
    var canRunAsAgent: Bool { runAsAgentDisabledReason == nil }

    /// Bundle the current chat context (current draft if non-empty, else last
    /// user turn; plus any prior conversation and attached-session transcripts)
    /// and hand it off to the autonomous agent. Opens the Agent Console so the
    /// user can watch the run.
    ///
    /// `isLaunchingAgent` stays true for the duration of the agent run so the
    /// button can't be re-pressed before status flips to .running. We also
    /// gate via `agent.status == .running` in `canRunAsAgent` for symmetry.
    func runAsAgent() async {
        guard canRunAsAgent, let agent = agentSession else { return }

        let instruction = await buildAgentInstruction()
        guard !instruction.isEmpty else {
            lastError = "Type a message or send something first — the agent needs a goal."
            return
        }

        isLaunchingAgent = true
        lastError = nil

        onOpenAgentConsole?()
        // Background the run; flip the launching flag back only after the
        // session has actually finished (or failed). canRunAsAgent's
        // `agent.status == .running` check prevents dual-fire in the meantime.
        Task { @MainActor [weak self, weak agent] in
            guard let agent else { return }
            await agent.start(initialInstruction: instruction)
            self?.isLaunchingAgent = false
        }
    }

    /// Compose the seed instruction for the agent. Prefers the current draft
    /// (and consumes it) so the user's most recent intent wins; falls back to
    /// the last user turn. Always appends the attached-session transcripts so
    /// the agent has the same context the chat was using.
    private func buildAgentInstruction() async -> String {
        let trimmedDraft = inputDraft.trimmingCharacters(in: .whitespacesAndNewlines)

        let primaryGoal: String
        if !trimmedDraft.isEmpty {
            primaryGoal = trimmedDraft
            inputDraft = ""
        } else if let last = messages.reversed().first(where: { $0.role == .user })?.text,
                  !last.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            primaryGoal = last
        } else {
            return ""
        }

        var sections: [String] = ["== User goal ==\n\(primaryGoal)"]

        // Prior conversation, if any. Skips system messages (those are
        // already-injected context, not dialogue) and the most recent user
        // turn when it was the source of `primaryGoal` (to avoid dupes).
        let priorTurns: [ChatMessage] = {
            let visible = messages.filter { $0.role != .system }
            guard trimmedDraft.isEmpty,
                  let lastUserIdx = visible.lastIndex(where: { $0.role == .user }) else {
                return visible
            }
            return Array(visible[..<lastUserIdx])
        }()
        if !priorTurns.isEmpty {
            var lines: [String] = ["== Prior chat history =="]
            for m in priorTurns {
                let role = m.role == .user ? "User" : "Assistant"
                let text = m.text.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !text.isEmpty else { continue }
                lines.append("\(role): \(text)")
            }
            if lines.count > 1 { sections.append(lines.joined(separator: "\n")) }
        }

        if !attachedSessions.isEmpty {
            var lines: [String] = ["== Attached session transcripts =="]
            let isoFormatter = ISO8601DateFormatter()
            for attachment in attachedSessions {
                let record = attachment.record
                let transcriptText = await loadTranscript(for: record)
                guard !transcriptText.isEmpty else { continue }
                let dateStr = isoFormatter.string(from: record.recordedAt)
                let durStr = String(format: "%.0f", record.durationSecs)
                let langStr = record.language ?? "auto"
                lines.append("[\(dateStr) · \(record.mode.rawValue) · \(durStr)s · \(langStr)]")
                lines.append(transcriptText)
            }
            if lines.count > 1 { sections.append(lines.joined(separator: "\n")) }
        }

        return sections.joined(separator: "\n\n")
    }

    // MARK: - Actions

    /// Posts the user message. When `autoSearchSessions` is on, runs FTS5
    /// over `inputDraft` first and attaches the top hits as context before
    /// building the system prompt. Scans for timestamp patterns and extracts
    /// frames from attached sessions' screen.mp4 (cap: 3 frames).
    func send() async {
        let text = inputDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty,
              Self.canStartTextSend(isSending: isSending, isSnapshotting: isSnapshotting) else { return }

        inputDraft = ""
        lastError = nil
        isSending = true
        defer { isSending = false }

        // Auto-attach FTS hits before building the system prompt.
        if autoSearchSessions {
            await attachAutoSearchResults(for: text)
        }

        // Extract vision frames for any timestamp mentions in the user message.
        let (timestampImages, timestampFooter) = await extractFramesForTimestamps(in: text)

        // Optional: auto-sample N evenly-spaced baseline frames so the LLM
        // sees the whole video, not just the moments the user explicitly
        // pointed at. Off by default; combined cap is 10 frames per message.
        let (autoImages, autoFooter): ([ChatMessage.Part], String)
        if settings.chatVideoAutoFramesEnabled {
            let remainingBudget = max(0, 10 - timestampImages.count)
            (autoImages, autoFooter) = await extractAutoSampledFrames(maxFrames: remainingBudget)
        } else {
            (autoImages, autoFooter) = ([], "")
        }

        // Build the user message: text + any image parts + optional footer.
        var parts: [ChatMessage.Part] = [.text(text)]
        parts.append(contentsOf: timestampImages)
        parts.append(contentsOf: autoImages)
        let combinedFooter = [timestampFooter, autoFooter]
            .filter { !$0.isEmpty }
            .joined(separator: "")
        if !combinedFooter.isEmpty {
            parts.append(.text(combinedFooter))
        }
        let userMessage = ChatMessage(role: .user, parts: parts)
        let userMessageIndex = messages.count
        messages.append(userMessage)

        do {
            let systemPrompt = await buildSystemPrompt()
            let replyMessages = try await runProvider(messages: messages, systemPrompt: systemPrompt)
            messages.append(contentsOf: replyMessages)
        } catch let error as AIError {
            lastError = friendlyMessage(for: error)
            Self.rollbackUserMessage(at: userMessageIndex, matching: userMessage, from: &messages)
            inputDraft = text
        } catch {
            lastError = error.localizedDescription
            Self.rollbackUserMessage(at: userMessageIndex, matching: userMessage, from: &messages)
            inputDraft = text
        }
    }

    /// Clears messages and all attached sessions.
    func clear() {
        messages = []
        attachedSessions = []
        lastError = nil
    }

    /// Looks up a SessionRecord by id and appends a manual attachment.
    func attachSession(_ id: String) async {
        guard !attachedSessions.contains(where: { $0.record.id == id }) else { return }
        do {
            if let record = try await database.session(id: id) {
                attachedSessions.append(.manual(record))
            }
        } catch {
            lastError = "Could not load session: \(error.localizedDescription)"
        }
    }

    /// Bulk manual attach — used by SessionPickerSheet.
    func attachSessions(_ ids: [String]) async {
        for id in ids {
            await attachSession(id)
        }
    }

    /// Removes an attached session by id (manual or auto).
    func detachSession(_ id: String) {
        attachedSessions.removeAll { $0.record.id == id }
    }

    /// Captures the last ~60 s of the active recording via Whisper, then sends
    /// a message with the snapshot transcript as context.
    func sendSnapshot() async {
        guard Self.canStartSnapshotSend(isSending: isSending, isSnapshotting: isSnapshotting) else { return }
        guard case .recording(let sid) = recorder.status else {
            lastError = "Not currently recording — start a recording to use live snapshot."
            return
        }
        let q = snapshotQuestion.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else { return }

        let openaiKey = settings.openaiApiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !openaiKey.isEmpty else {
            lastError = "OpenAI API key required for live snapshot (set in Settings)."
            return
        }

        isSnapshotting = true
        defer { isSnapshotting = false }

        let language = settings.summaryLanguage == "auto" ? nil : settings.summaryLanguage
        let maker = SnapshotMaker(sessionStore: sessionStore, whisperProviderFactory: whisperProviderFactory)
        var rollbackTarget: (index: Int, message: ChatMessage)?

        do {
            let snapshotText = try await maker.snapshot(
                sessionId: sid,
                apiKey: openaiKey,
                language: language
            )
            let userMessage = ChatMessage(
                role: .user,
                content: "[Live snapshot — last ~60 seconds of the active recording]\n\(snapshotText)\n\n---\n\nQuestion: \(q)"
            )
            rollbackTarget = (messages.count, userMessage)
            messages.append(userMessage)
            snapshotQuestion = ""

            let systemPrompt = await buildSystemPrompt()
            let replyMessages = try await runProvider(messages: messages, systemPrompt: systemPrompt)
            messages.append(contentsOf: replyMessages)
        } catch {
            if let rollbackTarget {
                Self.rollbackUserMessage(at: rollbackTarget.index, matching: rollbackTarget.message, from: &messages)
                snapshotQuestion = q
            }
            lastError = "Snapshot failed: \(error.localizedDescription)"
        }
    }

    // MARK: - Private: provider dispatch

    /// Shared send-to-LLM path used by both `send()` and `sendSnapshot()`.
    private func runProvider(messages: [ChatMessage], systemPrompt: String?) async throws -> [ChatMessage] {
        guard let resolved = providerResolver(settings.aiProviderConfig) else {
            throw AIError.authenticationFailed
        }
        let config = AIConfig(
            model: resolved.model,
            maxTokens: Self.defaultChatMaxTokens,
            systemPrompt: systemPrompt
        )
        let tools = await makeChatTools()
        guard !tools.isEmpty else {
            return [ChatMessage(role: .assistant, content: try await resolved.provider.chat(messages: messages, config: config))]
        }

        let engine = ToolLoopEngine(
            provider: resolved.provider,
            tools: tools,
            config: config,
            maxTranscriptBytes: ToolLoopEngine.defaultMaxTranscriptBytes
        )
        let result = try await engine.runWithTranscript(messages: messages)
        return Array(result.transcript.dropFirst(messages.count))
    }

    private func makeChatTools() async -> [ToolDefinition] {
        var tools: [AgentTool] = [
            SearchTranscriptsTool(database: database),
        ]
        if let liveContextProvider {
            tools.append(SearchLiveTranscriptTool(snapshotProvider: liveContextProvider))
        }
        if let screenFrameSource = await currentScreenFrameSource() {
            tools.append(GetScreenFrameTool(sourceProvider: { screenFrameSource }))
        }
        if let knowledgeBaseStore {
            tools.append(SearchKnowledgeBaseTool(store: knowledgeBaseStore))
            let codeRoots = (try? await knowledgeBaseStore.listSources())
                .map { sources in
                    sources
                        .filter { $0.kind == .codeFolder }
                        .map { URL(fileURLWithPath: $0.path, isDirectory: true) }
                } ?? []
            tools.append(SearchCodeTool(roots: codeRoots))
        }
        return tools.map { $0.toolDefinition() }
    }

    private func currentScreenFrameSource() async -> ScreenFrameSource? {
        guard case .recording(let sessionId) = recorder.status else { return nil }
        let dir = await sessionStore.sessionDir(for: sessionId)
        return ScreenFrameSource(
            sessionId: sessionId,
            videoURL: dir.appendingPathComponent("screen.mp4")
        )
    }

    // MARK: - Private: vision frame extraction

    /// Sample `maxFrames` evenly-spaced baseline frames from each attached
    /// session that has a screen.mp4 sidecar. Distributed evenly across the
    /// video duration so the LLM gets a thumbnail-strip view of the whole
    /// session, not just the timestamp the user named.
    /// Capped at `maxFrames` total across all sessions (round-robin pick).
    private func extractAutoSampledFrames(maxFrames: Int) async -> ([ChatMessage.Part], String) {
        guard maxFrames > 0 else { return ([], "") }
        let requested = max(1, settings.chatVideoAutoFramesCount)
        let cap = min(requested, maxFrames)

        // Resolve every attached session's screen.mp4 in parallel.
        struct VideoTarget: Sendable {
            let id: String
            let url: URL
            let duration: Double
        }
        let targets: [VideoTarget] = await withTaskGroup(of: VideoTarget?.self) { group in
            for attachment in attachedSessions {
                let id = attachment.record.id
                group.addTask {
                    let dir = await self.sessionStore.sessionDir(for: id)
                    let videoURL = dir.appendingPathComponent("screen.mp4")
                    guard FileManager.default.fileExists(atPath: videoURL.path) else { return nil }
                    let asset = AVURLAsset(url: videoURL)
                    let dur = (try? await asset.load(.duration)) ?? .zero
                    let secs = CMTimeGetSeconds(dur)
                    guard secs.isFinite, secs > 1 else { return nil }
                    return VideoTarget(id: id, url: videoURL, duration: secs)
                }
            }
            var out: [VideoTarget] = []
            for await t in group { if let t { out.append(t) } }
            return out
        }
        guard !targets.isEmpty else { return ([], "") }

        // Build the per-session sample plan: evenly-spaced offsets that skip
        // the very start / very end (first/last 5% are often blank).
        var imageParts: [ChatMessage.Part] = []
        var footerLines: [String] = []
        let perSession = max(1, cap / targets.count)
        outer: for target in targets {
            let n = perSession
            for k in 0..<n {
                guard imageParts.count < cap else { break outer }
                // (k+1) / (n+1) places samples uniformly inside (0, 1)
                let frac = Double(k + 1) / Double(n + 1)
                let safeStart = target.duration * 0.05
                let safeEnd = target.duration * 0.95
                let seconds = safeStart + (safeEnd - safeStart) * frac
                do {
                    let jpeg = try await FrameExtractor.extractFrame(at: seconds, from: target.url)
                    imageParts.append(.image(jpegData: jpeg, mimeType: "image/jpeg"))
                    footerLines.append("auto-frame from \(String(target.id.prefix(8))) at \(formatTimestamp(seconds))")
                } catch {
                    continue
                }
            }
        }

        guard !imageParts.isEmpty else { return ([], "") }
        let footer = "\n\n[Auto-attached: \(footerLines.joined(separator: ", "))]"
        return (imageParts, footer)
    }

    /// Parse timestamp patterns from `text`, extract ≤3 frames from attached
    /// sessions' screen.mp4, and return the image parts + a human-readable footer.
    private func extractFramesForTimestamps(in text: String) async -> ([ChatMessage.Part], String) {
        let timestamps = Self.parseTimestampMentions(from: text)
        guard !timestamps.isEmpty else { return ([], "") }

        // Collect sessions that have a screen.mp4 sidecar.
        let sessionsWithVideo: [(id: String, videoURL: URL)] = await withTaskGroup(
            of: (String, URL?).self
        ) { group in
            for attachment in attachedSessions {
                let id = attachment.record.id
                group.addTask {
                    let dir = await self.sessionStore.sessionDir(for: id)
                    let videoURL = dir.appendingPathComponent("screen.mp4")
                    guard FileManager.default.fileExists(atPath: videoURL.path) else { return (id, nil) }
                    return (id, videoURL)
                }
            }
            var results: [(String, URL?)] = []
            for await pair in group { results.append(pair) }
            return results
        }.compactMap { (id, url) -> (id: String, videoURL: URL)? in
            guard let url else { return nil }
            return (id: id, videoURL: url)
        }

        guard !sessionsWithVideo.isEmpty else { return ([], "") }

        var imageParts: [ChatMessage.Part] = []
        var footerLines: [String] = []
        let maxFrames = 3

        // For each timestamp, try to extract a frame from the first session that has video.
        outer: for seconds in timestamps {
            for session in sessionsWithVideo {
                guard imageParts.count < maxFrames else { break outer }
                do {
                    let jpegData = try await FrameExtractor.extractFrame(at: seconds, from: session.videoURL)
                    imageParts.append(.image(jpegData: jpegData, mimeType: "image/jpeg"))
                    let label = formatTimestamp(seconds)
                    let shortId = String(session.id.prefix(8))
                    footerLines.append("frame from session \(shortId) at \(label)")
                    break  // one frame per timestamp (first session wins)
                } catch {
                    // Skip silently — the session might be audio-only or too short.
                    continue
                }
            }
        }

        guard !imageParts.isEmpty else { return ([], "") }
        let footer = "\n\n[Attached: \(footerLines.joined(separator: ", "))]"
        return (imageParts, footer)
    }

    /// Parse all timestamp-like patterns from a string and return seconds values.
    ///
    /// Supported:
    ///   `12:34`        → m:ss
    ///   `0:12:34`      → h:mm:ss
    ///   `at minute 5`  → 5 * 60
    ///   `на 3 хвилині` / `на 3 хвилини` / `на 3 хвилинах` → 3 * 60
    static func parseTimestampMentions(from text: String) -> [TimeInterval] {
        var results: [(location: Int, time: TimeInterval)] = []
        var seen = Set<TimeInterval>()

        func add(_ t: TimeInterval, location: Int) {
            guard t >= 0, !seen.contains(t) else { return }
            seen.insert(t)
            results.append((location, t))
        }

        // h:mm:ss  (e.g. 1:23:45)
        let hmmss = try? NSRegularExpression(pattern: #"\b(\d+):(\d{2}):(\d{2})\b"#)
        if let matches = hmmss?.matches(in: text, range: NSRange(text.startIndex..., in: text)) {
            for m in matches {
                let h = Int(substring(text, range: m.range(at: 1))) ?? 0
                let min = Int(substring(text, range: m.range(at: 2))) ?? 0
                let sec = Int(substring(text, range: m.range(at: 3))) ?? 0
                guard min < 60, sec < 60 else { continue }
                add(TimeInterval(h * 3600 + min * 60 + sec), location: m.range.location)
            }
        }

        // m:ss  (e.g. 5:32) — must NOT be part of an h:mm:ss match already seen.
        let mss = try? NSRegularExpression(pattern: #"(?<!\d:)\b(\d+):(\d{2})\b(?!:\d)"#)
        if let matches = mss?.matches(in: text, range: NSRange(text.startIndex..., in: text)) {
            for m in matches {
                let min = Int(substring(text, range: m.range(at: 1))) ?? 0
                let sec = Int(substring(text, range: m.range(at: 2))) ?? 0
                guard sec < 60 else { continue }
                add(TimeInterval(min * 60 + sec), location: m.range.location)
            }
        }

        // English: "at minute N" or "minute N"
        let enMin = try? NSRegularExpression(pattern: #"\b(?:at )?minute (\d+)\b"#, options: .caseInsensitive)
        if let matches = enMin?.matches(in: text, range: NSRange(text.startIndex..., in: text)) {
            for m in matches {
                let n = Int(substring(text, range: m.range(at: 1))) ?? 0
                add(TimeInterval(n * 60), location: m.range.location)
            }
        }

        // Ukrainian: "на N хвилині/хвилини/хвилинах"
        let ukMin = try? NSRegularExpression(pattern: #"\bна (\d+) хвилин(?:і|и|ах)\b"#)
        if let matches = ukMin?.matches(in: text, range: NSRange(text.startIndex..., in: text)) {
            for m in matches {
                let n = Int(substring(text, range: m.range(at: 1))) ?? 0
                add(TimeInterval(n * 60), location: m.range.location)
            }
        }

        return results.sorted { $0.location < $1.location }.map(\.time)
    }

    static func canStartTextSend(isSending: Bool, isSnapshotting: Bool) -> Bool {
        !isSending && !isSnapshotting
    }

    static func canStartSnapshotSend(isSending: Bool, isSnapshotting: Bool) -> Bool {
        !isSending && !isSnapshotting
    }

    static func rollbackUserMessage(
        at index: Int,
        matching message: ChatMessage,
        from messages: inout [ChatMessage]
    ) {
        guard messages.indices.contains(index), messages[index] == message else { return }
        messages.remove(at: index)
    }

    static func liveTranscriptPromptSection(
        from state: LiveTranscriptState,
        maxCharacters: Int
    ) -> String? {
        var lines: [String] = []
        for unit in state.stableUnits {
            let text = unit.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { continue }
            lines.append("[\(formatLiveTimestamp(unit.start))-\(formatLiveTimestamp(unit.end))] \(text)")
        }

        let draft = state.draftUnits
            .map { $0.text.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .joined(separator: " ")
        if !draft.isEmpty {
            lines.append("[draft] \(draft)")
        }

        guard !lines.isEmpty else { return nil }
        let body = cappedLiveTranscriptBody(lines.joined(separator: "\n"), maxCharacters: maxCharacters)
        return """
        == Active recording live transcript ==
        This transcript is from the recording currently in progress. Draft text may still change.

        \(body)
        """
    }

    static func contextPrompt(
        liveSection: String?,
        attachedSessionSections: [String]
    ) -> String? {
        guard liveSection != nil || !attachedSessionSections.isEmpty else { return nil }

        var prompt = """
        You are a helpful assistant that has access to the user's audio recording transcripts.
        Reference these recordings when relevant; cite by recorded_at if you do.
        """

        if let liveSection {
            prompt += "\n\n\(liveSection)"
        }

        if !attachedSessionSections.isEmpty {
            prompt += "\n\n== Attached sessions ==\n\n"
            prompt += attachedSessionSections.joined(separator: "\n")
            prompt += "\n"
        }

        return prompt
    }

    private static func substring(_ text: String, range: NSRange) -> String {
        guard let r = Range(range, in: text) else { return "" }
        return String(text[r])
    }

    private static func cappedLiveTranscriptBody(_ text: String, maxCharacters: Int) -> String {
        guard maxCharacters > 0, text.count > maxCharacters else { return text }
        let suffix = String(text.suffix(maxCharacters))
        return "[earlier live transcript omitted]\n\(suffix)"
    }

    private static func formatLiveTimestamp(_ seconds: TimeInterval) -> String {
        let total = max(0, Int(seconds.rounded(.down)))
        let h = total / 3600
        let m = (total % 3600) / 60
        let s = total % 60
        if h > 0 { return String(format: "%d:%02d:%02d", h, m, s) }
        return String(format: "%02d:%02d", m, s)
    }

    private func formatTimestamp(_ seconds: TimeInterval) -> String {
        let total = Int(seconds)
        let h = total / 3600
        let m = (total % 3600) / 60
        let s = total % 60
        if h > 0 { return String(format: "%d:%02d:%02d", h, m, s) }
        return String(format: "%d:%02d", m, s)
    }

    // MARK: - Private: auto-search

    /// Runs FTS5 over `query`, fetches matching SessionRecords in parallel,
    /// and appends `.autoFromSearch` entries (deduplicated by id).
    private func attachAutoSearchResults(for query: String) async {
        let hits: [SearchHit]
        do {
            hits = try await database.searchTranscripts(query: query, limit: searchDepth)
        } catch {
            // FTS failure is non-fatal; proceed without auto-context.
            return
        }
        guard !hits.isEmpty else { return }

        // Fetch SessionRecords in parallel for all hits.
        var records: [(SearchHit, SessionRecord)] = []
        await withTaskGroup(of: (SearchHit, SessionRecord?).self) { group in
            for hit in hits {
                group.addTask {
                    let record = try? await self.database.session(id: hit.sid)
                    return (hit, record)
                }
            }
            for await (hit, record) in group {
                if let record {
                    records.append((hit, record))
                }
            }
        }

        // Preserve FTS ranking order; deduplicate against already-attached sessions.
        let orderedHits = hits.compactMap { hit in records.first(where: { $0.0.sid == hit.sid }) }
        for (hit, record) in orderedHits {
            guard !attachedSessions.contains(where: { $0.record.id == record.id }) else { continue }
            attachedSessions.append(.autoFromSearch(record, snippet: hit.snippet))
        }
    }

    // MARK: - Private: system prompt

    /// Builds the session-context system prompt from all attached sessions.
    /// Returns nil when there are no attached sessions.
    private func buildSystemPrompt() async -> String? {
        let liveSection: String?
        if let liveContextProvider, let liveState = await liveContextProvider() {
            liveSection = Self.liveTranscriptPromptSection(from: liveState, maxCharacters: 12_000)
        } else {
            liveSection = nil
        }

        let attachedSections: [String]
        if attachedSessions.isEmpty {
            attachedSections = []
        } else {
            let isoFormatter = ISO8601DateFormatter()
            var sections: [String] = []
            for attachment in attachedSessions {
                let record = attachment.record
                let transcriptText = await loadTranscript(for: record)
                let dateStr = isoFormatter.string(from: record.recordedAt)
                let durStr = String(format: "%.0f", record.durationSecs)
                let langStr = record.language ?? "auto"
                sections.append("""
                [\(dateStr) · \(record.mode.rawValue) · \(durStr)s · \(langStr)]
                \(transcriptText)
                """)
            }
            attachedSections = sections
        }

        return Self.contextPrompt(liveSection: liveSection, attachedSessionSections: attachedSections)
    }

    /// Reads `transcript.txt` from the session directory; falls back to
    /// concatenating `transcript.jsonl` lines. Returns empty string if both missing.
    private func loadTranscript(for record: SessionRecord) async -> String {
        let dir = await sessionStore.sessionDir(for: record.id)

        // Preferred: pre-built transcript.txt
        let txtURL = dir.appendingPathComponent("transcript.txt")
        if let text = try? String(contentsOf: txtURL, encoding: .utf8),
           !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return text.trimmingCharacters(in: .whitespacesAndNewlines)
        }

        // Fallback: parse transcript.jsonl
        let jsonlURL = dir.appendingPathComponent("transcript.jsonl")
        guard let raw = try? String(contentsOf: jsonlURL, encoding: .utf8) else { return "" }

        let decoder = JSONDecoder()
        let lines = raw.components(separatedBy: .newlines)
        let segments: [String] = lines.compactMap { line in
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty,
                  let data = trimmed.data(using: .utf8),
                  let seg = try? decoder.decode(TranscriptSegment.self, from: data) else { return nil }
            return seg.text
        }
        return segments.joined(separator: " ")
    }

    // MARK: - Private: error formatting

    private func friendlyMessage(for error: AIError) -> String {
        switch error {
        case .authenticationFailed:
            return "API key is missing or invalid. Check Settings → AI Providers."
        case .rateLimited:
            return "Rate limited by the provider. Wait a moment and try again."
        case .invalidEndpoint:
            return "Invalid provider endpoint."
        case .sendFailed(let msg):
            return "Request failed: \(msg)"
        case .decodingFailed(let msg):
            return "Could not parse the provider response: \(msg)"
        }
    }
}

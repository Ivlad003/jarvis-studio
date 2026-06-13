import Foundation
import Observation
import os
import StorageKit
import TranscriptionKit

private let agentSessionLog = Logger(subsystem: "dev.kosmonotes.studio", category: "AgentSession")

// MARK: - AgentSessionState

/// UI-facing state for the autonomous agent. One instance per app launch
/// (singleton owned by AppDelegate); manages at most ONE active run at a
/// time, streams events into the published `events` array (so SwiftUI can
/// re-render), and writes every event to a per-session JSONL on disk.
///
/// Mid-session injection: the console window's text field calls
/// `inject(_:)`. Stop button calls `requestStop()`.
///
/// Concurrency contract:
///   - `start(...)` is serialized via `activeRunTask`. A second concurrent
///     call cooperatively stops the previous run and *awaits* it before
///     spinning up a new one — so events from a prior run can't bleed into
///     the new session's `events` array or JSONL.
///   - `inject(...)` and `requestStop(...)` are no-ops outside `.running`,
///     but emit a clear error event so the UI doesn't silently drop them.
@available(macOS 14.0, *)
@Observable
@MainActor
final class AgentSessionState {

    enum Status: Equatable, Sendable {
        case idle
        case running(sessionID: String)
        case finished(sessionID: String)
        case failed(String)
    }

    // MARK: - Observable

    var status: Status = .idle
    /// Live event stream — appended to as the agent runs. Console view
    /// renders this. Cleared on `start(...)`.
    var events: [AgentEvent] = []

    // MARK: - Dependencies

    private let settings: AppSettings
    private let knowledgeBaseStore: KnowledgeBaseStore?
    private let liveTranscriptProvider: SearchLiveTranscriptTool.SnapshotProvider?
    /// One of these is non-nil while a session runs. Built-in backend uses
    /// AgentRunner; CLI backends use ExternalAgentRunner. Polymorphism via
    /// helpers below to avoid an extra protocol layer.
    private var builtinRunner: AgentRunner?
    private var externalRunner: ExternalAgentRunner?
    /// Tracks the currently-running backend loop so a second `start` can
    /// `await` the previous one to fully unwind before launching a new run.
    /// Without this, `requestStop()` (cooperative) returns immediately while
    /// the old loop is still emitting events into our shared `events` array.
    private var activeRunTask: Task<Void, Never>?
    private var sessionLogURL: URL?
    /// Long-lived file handle for the JSONL log. Re-opened per session so
    /// we don't pay open/seek/close on every event (chatty runs are 50–100
    /// events/min). Closed on session end.
    private var logHandle: FileHandle?
    private var jsonEncoder: JSONEncoder = {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .iso8601
        e.outputFormatting = [.sortedKeys]
        return e
    }()

    init(
        settings: AppSettings,
        knowledgeBaseStore: KnowledgeBaseStore? = nil,
        liveTranscriptProvider: SearchLiveTranscriptTool.SnapshotProvider? = nil
    ) {
        self.settings = settings
        self.knowledgeBaseStore = knowledgeBaseStore
        self.liveTranscriptProvider = liveTranscriptProvider
    }

    // MARK: - Public API

    /// Kick off a new agent session with the given initial instruction.
    /// If a previous run is in flight, requests its cooperative stop and
    /// **awaits its full unwind** before starting the new one. Returns once
    /// the new run's loop ends.
    func start(initialInstruction: String) async {
        // Drain any in-flight run cleanly first so its onEvent callbacks
        // don't bleed into the next session's `events` / JSONL.
        if let prev = activeRunTask {
            await builtinRunner?.requestStop()
            await externalRunner?.requestStop()
            _ = await prev.value
        }

        let workspace = resolveWorkspace()
        do {
            try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
        } catch {
            status = .failed("Could not create workspace at \(workspace.path): \(error.localizedDescription)")
            return
        }

        let sessionID = UUID().uuidString
        events = []
        closeLogFile()
        sessionLogURL = openLogFile(sessionID: sessionID)
        status = .running(sessionID: sessionID)

        agentSessionLog.info("AgentSession.start: id=\(sessionID, privacy: .public) backend=\(self.settings.agentBackend.rawValue, privacy: .public) workspace=\(workspace.path, privacy: .public)")

        // Per-run epoch: the onEvent closure captures this sessionID and only
        // delivers events whose run matches the *current* status. Defends
        // against the (rare) corner case where requestStop above fired and
        // returned but the runner still drains a final pipe write.
        let onEvent: AgentRunner.EventHandler = { [weak self] event in
            Task { @MainActor [weak self] in
                guard let self else { return }
                guard case .running(let active) = self.status, active == sessionID else { return }
                self.handleEvent(event)
            }
        }

        let task = Task<Void, Never> { [weak self] in
            guard let self else { return }
            switch self.settings.agentBackend {
            case .builtin:
                await self.runBuiltin(workspace: workspace, instruction: initialInstruction, onEvent: onEvent)
            case .claudeCode:
                await self.runExternal(backend: .claudeCode(binPath: self.settings.agentClaudeCodeBin),
                                       workspace: workspace, instruction: initialInstruction, onEvent: onEvent)
            case .codex:
                await self.runExternal(backend: .codex(binPath: self.settings.agentCodexBin),
                                       workspace: workspace, instruction: initialInstruction, onEvent: onEvent)
            case .copilot:
                await self.runExternal(backend: .copilot(binPath: self.settings.agentCopilotBin),
                                       workspace: workspace, instruction: initialInstruction, onEvent: onEvent)
            }
        }
        activeRunTask = task
        await task.value

        // Loop returned — flip status to finished. Failed events were already
        // surfaced via handleEvent.
        if case .running(let id) = status {
            status = .finished(sessionID: id)
        }
        builtinRunner = nil
        externalRunner = nil
        activeRunTask = nil
        closeLogFile()
    }

    /// Append a new user message to the running session. Surfaces an error
    /// event when called outside `.running` (TOCTOU between UI guard and
    /// agent finish) so the user knows their text wasn't silently dropped.
    func inject(_ message: String) async {
        guard case .running = status else {
            events.append(AgentEvent(kind: .error, text: "Cannot inject — agent session is not running. Start a new run first."))
            return
        }
        if let r = builtinRunner { await r.inject(message); return }
        if let r = externalRunner { await r.inject(message) }
    }

    /// Cooperative stop. Loop wraps up the current iteration then exits.
    /// Idempotent — safe to call when not running.
    func requestStop() async {
        guard case .running = status else { return }
        if let r = builtinRunner { await r.requestStop(); return }
        if let r = externalRunner { await r.requestStop() }
    }

    // MARK: - Backend dispatch

    private func runBuiltin(
        workspace: URL,
        instruction: String,
        onEvent: @escaping AgentRunner.EventHandler
    ) async {
        let key = settings.anthropicApiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty else {
            status = .failed("Anthropic API key required for built-in backend (Settings → AI Providers).")
            return
        }

        let tools = await AgentToolRegistry.makeBuiltinTools(
            workspace: workspace,
            knowledgeBaseStore: knowledgeBaseStore,
            liveTranscriptProvider: liveTranscriptProvider
        )
        let systemPrompt = settings.agentSystemPrompt.isEmpty
            ? AppSettings.defaultAgentSystemPrompt
            : settings.agentSystemPrompt
        let contextualSystem = systemPrompt + "\n\nYour workspace directory is `\(workspace.path)` — restrict all file operations to within it. The user's locale, current date, and OS info: macOS \(ProcessInfo.processInfo.operatingSystemVersionString)."

        let runner = AgentRunner(
            apiKey: key,
            model: settings.agentBuiltinModel.rawValue,
            systemPrompt: contextualSystem,
            maxIterations: settings.agentMaxIterations,
            tools: tools,
            onEvent: onEvent
        )
        self.builtinRunner = runner
        await runner.run(initialInstruction: instruction)
    }

    private func runExternal(
        backend: ExternalAgentRunner.Backend,
        workspace: URL,
        instruction: String,
        onEvent: @escaping ExternalAgentRunner.EventHandler
    ) async {
        let runner = ExternalAgentRunner(
            backend: backend,
            workspace: workspace,
            onEvent: onEvent
        )
        self.externalRunner = runner
        await runner.run(initialInstruction: instruction)
    }

    // MARK: - Private

    private func handleEvent(_ event: AgentEvent) {
        events.append(event)
        appendToLogFile(event)
    }

    private func resolveWorkspace() -> URL {
        let raw = settings.agentWorkspaceFolder.trimmingCharacters(in: .whitespacesAndNewlines)
        if !raw.isEmpty {
            let expanded = (raw as NSString).expandingTildeInPath
            return URL(fileURLWithPath: expanded, isDirectory: true)
        }
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Documents")
        return docs.appendingPathComponent("KosmoNotes-agent")
    }

    private func openLogFile(sessionID: String) -> URL? {
        let appSupport = (try? FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true))
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support")
        let dir = appSupport.appendingPathComponent("KosmoNotes/agent-sessions", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent("\(sessionID).jsonl")
        FileManager.default.createFile(atPath: url.path, contents: nil)
        do {
            self.logHandle = try FileHandle(forWritingTo: url)
        } catch {
            agentSessionLog.error("openLogFile: \(error.localizedDescription, privacy: .private)")
            self.logHandle = nil
        }
        return url
    }

    private func appendToLogFile(_ event: AgentEvent) {
        guard let handle = logHandle else { return }
        guard let data = try? jsonEncoder.encode(event) else { return }
        var line = data
        line.append(0x0A)  // newline
        do {
            try handle.write(contentsOf: line)
        } catch {
            agentSessionLog.error("appendToLogFile: \(error.localizedDescription, privacy: .private)")
        }
    }

    private func closeLogFile() {
        guard let handle = logHandle else { return }
        try? handle.close()
        logHandle = nil
    }
}

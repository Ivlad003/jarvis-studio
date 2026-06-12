import Foundation
import Observation
import os
import DictationKit
import KeyboardShortcuts
import TranscriptionKit

private let agentHotkeyLog = Logger(subsystem: "dev.kosmonotes.studio", category: "AgentHotkey")

extension KeyboardShortcuts.Name {
    /// Push-to-talk trigger for the autonomous agent. Default ⌘⇧A
    /// (A for Agent). Hold to record; release transcribes via Whisper
    /// and ships the result as the initial instruction to AgentSessionState.
    public static let agentTrigger = Self("agentTrigger", default: .init(.a, modifiers: [.command, .shift]))
}

// MARK: - AgentHotkeyState

/// Wires the .agentTrigger hotkey into the agent. On press: starts a mic
/// capture session via DictationPipeline (Whisper-only — no LLM cleanup
/// because we want the raw instruction). On release: feeds the transcribed
/// text to AgentSessionState.start as the initial instruction.
///
/// Mirror of PushToMarkdownState's pattern; the only difference is the
/// downstream sink (AgentSessionState instead of MarkdownExporter).
@available(macOS 14.0, *)
@Observable
@MainActor
final class AgentHotkeyState {

    enum UIStatus: Equatable, Sendable {
        case idle
        case recording
        case processing
        case launched(sessionID: String)
        case failed(String)
    }

    // MARK: - Observable

    var uiStatus: UIStatus = .idle

    // MARK: - Dependencies

    private let settings: AppSettings
    private let agentSession: AgentSessionState
    /// Weak ref to RecorderState so the dictation preflight can refuse to
    /// start a parallel AVAudioEngine while a meeting recording owns the
    /// mic HAL.
    private weak var recorder: RecorderState?
    private var pipeline: DictationPipeline?
    private var liveAdapter: HoldToTalkLiveAdapter?
    private let installer = TriggerHotkeyInstaller(comboName: .agentTrigger, label: "Agent")
    private var triggerChangeObserver: NSObjectProtocol?

    init(
        settings: AppSettings,
        agentSession: AgentSessionState,
        recorder: RecorderState? = nil
    ) {
        self.settings = settings
        self.agentSession = agentSession
        self.recorder = recorder
    }

    func install() {
        installer.install(
            trigger: settings.agentTrigger,
            onPress: { [weak self] in
                Task { @MainActor [weak self] in await self?.handlePress() }
            },
            onRelease: { [weak self] in
                Task { @MainActor [weak self] in await self?.handleRelease() }
            }
        )
        triggerChangeObserver = NotificationCenter.default.addObserver(
            forName: AppSettings.agentTriggerDidChange,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.installer.reinstall(
                    trigger: self.settings.agentTrigger,
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

    func uninstall() {
        installer.uninstall()
        if let token = triggerChangeObserver {
            NotificationCenter.default.removeObserver(token)
            triggerChangeObserver = nil
        }
    }

    // MARK: - Private

    private func handlePress() async {
        agentHotkeyLog.info("AgentHotkey.handlePress: hotkey fired")
        guard settings.agentEnabled else {
            agentHotkeyLog.info("AgentHotkey: agent disabled in Settings")
            return
        }
        let openaiKey = settings.openaiApiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !openaiKey.isEmpty else {
            uiStatus = .failed("OpenAI API key required to transcribe agent instructions (Settings → Transcription).")
            return
        }
        let anthropicKey = settings.anthropicApiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !anthropicKey.isEmpty else {
            uiStatus = .failed("Anthropic API key required for the agent loop (Settings → AI Providers).")
            return
        }

        // Build a Whisper-only pipeline — no LLM cleanup (we want the raw
        // user instruction, not a tidied-up version). Hijack `paster` to
        // forward the text to AgentSessionState.start as the initial
        // instruction; pipeline returns .clipboardSimulatedV so its own
        // status flips to `.completed`.
        let whisper = WhisperProvider(apiKey: openaiKey, model: settings.openaiTranscribeModel.rawValue)
        let finalTranscriptSink: HoldToTalkLiveAdapter.Sink = { [weak self] instruction in
            await self?.handleFinalTranscript(instruction)
        }
        let saver: DictationPipeline.Paster = { instruction in
            Task { @MainActor in
                await finalTranscriptSink(instruction)
            }
            return .clipboardSimulatedV
        }
        let p = DictationPipeline(
            transcriber: { url, cfg in
                try await whisper.transcribe(audioFile: url, config: cfg)
            },
            paster: saver,
            llmProvider: nil,
            llmModel: "claude-sonnet-4-6",
            maxDurationSeconds: max(15, settings.dictationMaxSeconds),
            preflight: DictationState.makePreflight(recorder: recorder)
        )
        self.pipeline = p
        do {
            try await p.startRecording()
            uiStatus = .recording
            agentHotkeyLog.info("AgentHotkey: recording instruction…")
        } catch {
            uiStatus = .failed("Could not start: \(error.localizedDescription)")
            agentHotkeyLog.error("AgentHotkey.startRecording threw — \(error.localizedDescription, privacy: .public)")
            return
        }

        if let liveURL = p.currentLiveAudioURL,
           let liveProvider = settings.makeLiveProvider() {
            let engine = LiveTranscriptEngine(provider: liveProvider, exporter: LiveWindowExporter())
            await engine.attach(audioFile: liveURL)
            liveAdapter = HoldToTalkLiveAdapter(
                engine: engine,
                configSource: { TranscriptionConfig(language: nil, sampleRate: 16_000) },
                sink: { [weak self] instruction in
                    await self?.handleFinalTranscript(instruction)
                }
            )
            agentHotkeyLog.info("AgentHotkey.handlePress: live adapter armed")
        }
    }

    private func handleRelease() async {
        agentHotkeyLog.info("AgentHotkey.handleRelease: stopping + transcribing")
        guard let p = pipeline else { return }

        // Live path — mutually exclusive with batch. stopCapture() closes the
        // CAF without re-transcribing; HoldToTalkLiveAdapter.stopAndFlush calls
        // handleFinalTranscript with the merged transcript, which fires
        // agentSession.start with the live result as initial instruction.
        if let adapter = liveAdapter {
            liveAdapter = nil
            uiStatus = .processing
            await p.stopCapture()
            await adapter.stopAndFlush()
            if !adapter.didFlush {
                let reason: String
                if let err = adapter.lastFlushError {
                    reason = err.localizedDescription
                } else if case .failed(let msg) = adapter.health {
                    reason = msg
                } else {
                    reason = "No audio captured or transcription produced empty result"
                }
                agentHotkeyLog.error("AgentHotkey: live adapter produced no text — \(reason, privacy: .public)")
                uiStatus = .failed(reason)
            }
            return
        }

        uiStatus = .processing
        await p.stopAndProcess()
        switch p.status {
        case .completed:
            // saver Task launched agentSession.start; status flipped there.
            break
        case .failed(let msg):
            uiStatus = .failed(msg)
        default:
            uiStatus = .idle
        }
    }

    /// Separate downstream sink so HoldToTalkLiveAdapter can reuse the same
    /// agent-launch behavior once live capture is wired into hold-to-talk.
    private func handleFinalTranscript(_ instruction: String) async {
        uiStatus = .processing
        await agentSession.start(initialInstruction: instruction)
        if case .running(let id) = agentSession.status {
            uiStatus = .launched(sessionID: id)
        }
    }
}

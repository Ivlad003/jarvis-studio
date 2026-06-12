@preconcurrency import AVFoundation
import AppKit
import Foundation
import Observation
import os
import AIKit
import CaptureKit
import StorageKit
import TranscriptionKit

// MARK: - Codec mapping

/// Maps AppSettings.AudioCodec → CaptureKit.AudioCodecChoice. Kept inline so
/// AppSettings doesn't need to import CaptureKit.
private extension AppSettings.AudioCodec {
    var captureChoice: AudioCodecChoice {
        switch self {
        case .aac:   return .aac
        case .heAAC: return .heAAC
        case .opus:  return .opus
        }
    }
}

// MARK: - RecorderState

/// The single mutable record-time state object for the app.
///
/// Wires together CaptureKit (audio in — mic, optional system audio via
/// Core Audio Tap on 14.4+ or ScreenCaptureKit mixdown, optional screen
/// capture), StorageKit (sessions on disk + DB), and TranscriptionKit
/// (batch transcription via the user-selected provider). The popover / menu
/// observe `status`, `micLevel`, and the optional live transcript surface to
/// render UI. Errors are surfaced via
/// `status = .failed(message:)` so the UI can show the user a single line.
@available(macOS 14.0, *)
@Observable
@MainActor
final class RecorderState {

    // MARK: - Status

    enum Status: Equatable, Sendable {
        case idle
        case recording(sessionId: String)
        case transcribing(sessionId: String)
        case complete(sessionId: String, audioFile: URL, transcriptPreview: String)
        case failed(message: String)

        var label: String {
            switch self {
            case .idle: return "Idle"
            case .recording: return "Recording"
            case .transcribing: return "Transcribing…"
            case .complete: return "Done"
            case .failed: return "Failed"
            }
        }

        var isBusy: Bool {
            switch self {
            case .recording, .transcribing: return true
            default: return false
            }
        }
    }

    enum ScreenAudioMixResult: Equatable, Sendable {
        case skipped
        case mixed
        case failed(String)
    }

    struct FinishedLiveTranscript: Sendable {
        let finalSegments: [TranscriptSegment]
        let persistedIncrementally: Bool
    }

    typealias ScreenAudioMixerFunction = @Sendable (_ screenURL: URL, _ audioFile: URL) async throws -> Void

    // MARK: - Observable state

    var status: Status = .idle
    /// 0..1 RMS-based level. Updated only while `status == .recording`.
    var micLevel: Double = 0
    /// Live mute toggle for the mic during a recording. UI binds to this so
    /// the menu item / popover button reflects the current state. Setter
    /// forwards into the actor stack so the tap closure starts dropping
    /// buffers immediately. Resets to false on every new recording.
    var micMuted: Bool = false
    /// Stable transcript text already outside the mutable rewrite horizon.
    var liveTranscriptStableText: String = ""
    /// Mutable tail still allowed to rewrite as fresh windows arrive.
    var liveTranscriptMutableText: String = ""
    /// User-facing health line for live transcription. Nil when healthy.
    var liveTranscriptStatusText: String? = nil
    /// True only when the adapter reports delayed health.
    var liveTranscriptIsDelayed: Bool = false
    /// Set after a successful AI summary write; nil when no summary exists yet.
    var lastSummaryURL: URL? = nil
    /// Non-nil when screen recording was requested but failed (e.g. TCC denied/changed
    /// after re-signing). Audio recording proceeds normally; this is a soft warning only.
    var screenRecordingWarning: String? = nil
    /// Live mic-health surface, projected from `CaptureSession.micHealth`. UI
    /// reads this directly — green dot when .ok, yellow + banner when
    /// .degraded, red + banner when .dead. Mirrors the invariant that the
    /// user must see within 5 s when their voice has stopped reaching disk.
    var micHealth: MicHealth = .idle
    /// User-facing message attached to the most recent .degraded or .dead
    /// transition. Nil while healthy. Cleared on session stop.
    var micHealthMessage: String? = nil
    /// True after the fail-safe auto-stop fires. The Library row is tagged
    /// with this in the finalize() path so the user can tell at a glance.
    private(set) var micFailSafeTriggered: Bool = false
    /// True after tier-2 fallback demoted screen recording to keep mic alive.
    /// Drives the user-facing "screen video stopped mid-session" copy in the
    /// recorder UI and persists into the session via enhancementStatus =
    /// .partial.
    private(set) var screenDemotedDuringRecording: Bool = false

    var showsLiveTranscript: Bool {
        !liveTranscriptStableText.isEmpty ||
        !liveTranscriptMutableText.isEmpty ||
        liveTranscriptStatusText != nil
    }

    // MARK: - Dependencies

    // `database` and `settings` are module-internal (not private) so the
    // post-stop extension files (RecorderState+Summary, +Cleanup, +SemanticIndex)
    // can read them. RecorderState itself is internal-default, so these stay
    // invisible to anything outside the App target.
    let database: AppDatabase
    private let sessionStore: SessionStore
    private let recoveryService = RecoveryService()
    let settings: AppSettings

    // MARK: - Recording-time state

    private var captureSession: CaptureSession?
    private var micMeter: MicLevelMeter?
    /// Periodic mic-silence watchdog. Logs current level every 5 s and
    /// emits a louder warning once the level has stayed near zero for
    /// 10 s, surfacing routing issues (Bluetooth HFP mic, wrong default
    /// input device) that otherwise look like "voice didn't record".
    private var micWatchdogTask: Task<Void, Never>?
    /// Polls CaptureSession.micHealth on a 1 s cadence, projects it onto the
    /// observable `micHealth` property, and triggers the fail-safe auto-stop
    /// after 30 s of `.dead`. This is the surface the design doc calls "I1
    /// (no silent mic death)" + "I2 (hard fail-safe)" — see
    /// docs/plans/2026-06-06-always-on-capture-design.md.
    private var micHealthPollerTask: Task<Void, Never>?
    /// Synchronous reentrancy gate for start()/stop(). Both methods cross
    /// multiple suspension points before `status` reflects the transition,
    /// so a fail-safe auto-stop racing a user stop (or a start() slotting
    /// into the transient `.failed` window mid-stop) could double-enter the
    /// lifecycle pipeline. Set as the FIRST statement of each — before any
    /// await — and reset via `defer` on every exit path.
    private var lifecycleTransitionInFlight = false
    /// On the SCStream-mic path, polls `CaptureSession.micLevel` on the same
    /// ~33 ms cadence MicLevelMeter would use. Stored separately so teardown
    /// can cancel it. Nil on the AudioEngine path.
    private var scStreamMicLevelPollerTask: Task<Void, Never>?
    /// os_log channel surfaced in Settings → Logs.
    fileprivate static let recorderLog = Logger(subsystem: "dev.kosmonotes.studio", category: "RecorderState")
    private let sleepAssertion = SleepAssertion()
    /// Floating webcam bubble window; opened only when both Audio + Screen
    /// mode AND `cameraBubbleEnabled` are on, AND camera permission was
    /// granted. The bubble lives on screen for ScreenCaptureKit to capture
    /// it as part of `screen.mp4` — no separate compositing in our writer.
    private let cameraBubbleController = CameraBubbleWindowController()
    private var liveTranscriptAdapter = RecorderLiveAdapter()
    private var liveTranscriptTee: RecorderLiveTee?
    private var streamingLiveSource: StreamingLiveSource?
    private var liveTranscriptHub: LiveTranscriptHub?
    private var liveTranscriptStore: TranscriptStore?
    private var liveTranscriptRefreshTask: Task<Void, Never>?

    // MARK: - Init

    init(
        database: AppDatabase,
        sessionStore: SessionStore,
        settings: AppSettings
    ) {
        self.database = database
        self.sessionStore = sessionStore
        self.settings = settings
    }

    // MARK: - Public API

    /// Tracks the mode of the active session so the post-process pipeline
    /// can pick the right prompt (Meeting summary vs. Voice Note).
    /// Module-internal so RecorderState+Summary can read it.
    var activeMode: SessionMode = .meeting

    /// Live-toggle mic mute during an in-flight recording. No-op when
    /// nothing is recording. UI calls this from the menu item / popover.
    func toggleMicMute() async {
        guard case .recording = status else { return }
        let next = !micMuted
        await captureSession?.setMicMuted(next)
        micMuted = next
    }

    /// Convenience: start if idle/done, stop if recording. Ignored while
    /// transcribing.
    func toggle() async {
        switch status {
        case .idle, .complete, .failed:
            await start(mode: .meeting)
        case .recording:
            await stop()
        case .transcribing:
            break
        }
    }

    /// Begin a recording session.
    func start(mode: SessionMode) async {
        // Idempotent: only proceed when not already mid-session AND no other
        // start()/stop() is between its first await and its status flip.
        guard !status.isBusy, !lifecycleTransitionInFlight else { return }
        lifecycleTransitionInFlight = true
        defer { lifecycleTransitionInFlight = false }

        // Pre-flight: API key for the configured transcription provider. The
        // selection in Settings → Transcription was previously decorative — the
        // record path always required an OpenAI key and always used Whisper.
        // Now we honor the choice and check the right key.
        switch settings.transcriptionProvider {
        case .openaiWhisper:
            let openaiKey = settings.openaiApiKey.trimmingCharacters(in: .whitespacesAndNewlines)
            if openaiKey.isEmpty {
                status = .failed(message: "Set your OpenAI API key in Settings → Transcription before recording.")
                return
            }
        case .deepgram:
            let deepgramKey = settings.deepgramApiKey.trimmingCharacters(in: .whitespacesAndNewlines)
            if deepgramKey.isEmpty {
                status = .failed(message: "Set your Deepgram API key in Settings → Transcription before recording.")
                return
            }
        case .gemini:
            let geminiKey = settings.geminiApiKey.trimmingCharacters(in: .whitespacesAndNewlines)
            if geminiKey.isEmpty {
                status = .failed(message: "Set your Gemini API key in Settings → Transcription before recording.")
                return
            }
        case .whisperKit:
            // Local provider: no API key, but the chosen variant must be both
            // picked and on disk. We don't auto-download here — the Settings
            // tab has a clearly-labelled Download button so the user knows a
            // multi-GB transfer is starting.
            let variant = settings.whisperKitModel.trimmingCharacters(in: .whitespacesAndNewlines)
            if variant.isEmpty {
                status = .failed(message: "Pick a WhisperKit model in Settings → Transcription → Local first, then press Download.")
                return
            }
            let manager = WhisperKitModelManager(rootDir: AppSettings.whisperKitModelsRoot())
            let downloaded = await manager.isDownloaded(variant)
            if !downloaded {
                status = .failed(message: "WhisperKit model '\(variant)' isn't downloaded yet. Open Settings → Transcription and press Download.")
                return
            }
        case .openrouterAudio:
            let orKey = settings.openrouterApiKey.trimmingCharacters(in: .whitespacesAndNewlines)
            if orKey.isEmpty {
                status = .failed(message: "Set your OpenRouter API key in Settings → AI Providers before recording (used for OpenRouter multimodal transcription).")
                return
            }
        }

        // Pre-flight: Microphone permission. First call triggers the macOS prompt;
        // subsequent calls return cached status. On denial, surface a modal with a
        // direct link to System Settings → Privacy → Microphone.
        let micGranted = await PermissionsHelper.requestMicAccess()
        if !micGranted {
            PermissionsHelper.showMissingAlert(.microphone)
            status = .failed(message: "Microphone access denied. Grant in System Settings, then try again.")
            return
        }

        let screenEnabled = settings.recordingMode == .audioAndScreen
        // Audio + Screen mode implies the user wants the whole call captured
        // — including the other participants' voices coming from speakers,
        // Zoom/Meet/browser. The explicit `systemAudioEnabled` toggle was
        // confusing in practice (people enabled screen recording, expected
        // app audio in the transcript, got mic-only). Auto-enable system
        // audio whenever screen recording is on; users can still uncheck
        // `systemAudioEnabled` and stay in audio-only mode to opt out.
        let systemAudioEnabled = settings.systemAudioEnabled || screenEnabled
        let speakerEchoWarning = RecordingStartWarningPolicy.speakerEchoWarning(
            systemAudioEnabled: systemAudioEnabled,
            echoCancellationEnabled: settings.echoCancellationEnabled,
            defaultOutputBuiltIn: AudioDevicesSnapshot.defaultOutputIsBuiltIn()
        )

        // Diagnostic: snapshot config + active audio devices before the
        // recording graph is built. Lets the Logs tab show exactly which mic /
        // output / loopback was in effect at the start of a session — critical
        // when "voice didn't record" is reported, since macOS quietly switches
        // the default input device when Bluetooth headsets engage HFP profile.
        settings.logSnapshot(context: "before-recording")
        AudioDevicesSnapshot.log(context: "before-recording")

        // Screen Recording permission is intentionally NOT pre-flighted here.
        // CGPreflightScreenCaptureAccess() reads TCC, which keys grants by the
        // binary's mach-o cdhash for ad-hoc-signed apps. Every rebuild changes
        // that hash, so even a freshly-granted "Allow" reads as denied on the
        // very next build. The preflight gate that lived here would loop the
        // user through "Open System Settings → toggle is already on → press
        // Record → denied" forever.
        //
        // Instead, we let SCKit handle permission natively: SCShareableContent /
        // SCStream.startCapture pop the system prompt themselves on first use
        // and bind the grant to the running binary's cdhash. If access is
        // truly denied, ScreenRecorder.start throws and the catch below surfaces
        // a clear "Could not start recording: …" message rather than our own
        // (now-redundant) modal.
        //
        // Best-effort nudge: still call CGRequest... so the row appears in
        // System Settings before anything else fails. No-op when already granted.
        if screenEnabled || systemAudioEnabled {
            _ = PermissionsHelper.requestScreenRecordingAccess()
        }

        let language: String? = {
            let s = settings.summaryLanguage
            return (s == "auto" || s.isEmpty) ? nil : s
        }()

        do {
            let session = try await sessionStore.createSession(mode: mode, language: language)
            let dir = await sessionStore.sessionDir(for: session.id)
            self.activeMode = mode

            // Process Tap is only meaningful when system audio is enabled and we're on
            // 14.4+. Below 14.4 the field is set but never used (CaptureSession.start
            // gates the codepath on `#available(macOS 14.4, *)`).
            let bundleIDs = settings.processTapBundleIDs
                .split(separator: ",")
                .map { String($0).trimmingCharacters(in: .whitespaces) }
                .filter { !$0.isEmpty }
            let config = CaptureSession.Config(
                micEnabled: true,
                systemAudioEnabled: systemAudioEnabled,
                echoCancellationEnabled: settings.echoCancellationEnabled,
                sessionDir: dir,
                screenRecordingEnabled: screenEnabled,
                screenOutputURL: screenEnabled ? dir.appendingPathComponent("screen.mp4") : nil,
                useProcessTap: settings.useProcessTap,
                processTapBundleIDs: bundleIDs,
                videoUseHEVC: settings.videoUseHEVC,
                videoBitrate: settings.videoBitrate,
                audioBitrate: settings.audioBitrate,
                audioSampleRate: settings.audioSampleRate,
                audioCodec: settings.audioCodec.captureChoice,
                systemAudioDeviceUID: settings.systemAudioDeviceUID.isEmpty ? nil : settings.systemAudioDeviceUID,
                screenCaptureDisplayID: settings.screenCaptureDisplayID
            )
            // Open the camera bubble window BEFORE starting SCStream so the
            // window is on screen by the time the first screen frame is
            // captured. Only when in Audio + Screen mode (no point recording
            // a webcam if there's no video file) and user has opted in.
            // If camera permission is missing we surface the alert and skip
            // — recording continues without the bubble.
            if screenEnabled && settings.cameraBubbleEnabled {
                let granted = await PermissionsHelper.requestCameraAccess()
                if granted {
                    await cameraBubbleController.show(settings: settings)
                } else {
                    PermissionsHelper.showMissingAlert(.camera)
                    // Don't fail the recording — just skip the bubble.
                }
            }

            // Optional live transcript engines. Windowed Whisper/WhisperKit and
            // Deepgram streaming both consume the same mic-only live PCM tee.
            // Failure to arm is non-fatal — recorder proceeds in batch-only mode.
            let liveSink: (any LivePCMSink)?
            var liveSinks: [any LivePCMSink] = []
            self.liveTranscriptTee = nil
            self.streamingLiveSource = nil
            self.liveTranscriptHub = nil
            self.liveTranscriptStore = nil
            if let liveProvider = settings.makeLiveProvider() {
                let engine = LiveTranscriptEngine(provider: liveProvider, exporter: LiveWindowExporter())
                let tee = RecorderLiveTee(engine: engine)
                await tee.start()
                self.liveTranscriptTee = tee
                liveSinks.append(tee)
                Self.recorderLog.info("RecorderState.start: live transcript engine armed")
            }
            let sessionStore = self.sessionStore
            let streamingSessionID = session.id
            let liveStore: TranscriptStore?
            do {
                liveStore = try TranscriptStore(sessionDir: dir)
            } catch {
                liveStore = nil
                Self.recorderLog.error("RecorderState.start: live transcript store failed to open — \(error.localizedDescription, privacy: .public)")
            }
            let hub = LiveTranscriptHub(onFinalSegment: { segment in
                guard let liveStore else { return }
                try await liveStore.append(segment)
                try await liveStore.flushTxt()

                let segments = await liveStore.segments()
                let text = Self.liveTranscriptText(from: segments)
                guard !text.isEmpty else { return }
                try? await sessionStore.indexTranscript(sid: streamingSessionID, text: text)
            })
            if let streamingSource = settings.makeStreamingLiveSource(hub: hub) {
                do {
                    try await streamingSource.start()
                    self.streamingLiveSource = streamingSource
                    self.liveTranscriptHub = hub
                    self.liveTranscriptStore = liveStore
                    liveSinks.append(streamingSource)
                    Self.recorderLog.info("RecorderState.start: streaming live transcript source armed")
                } catch {
                    Self.recorderLog.error("RecorderState.start: streaming live transcript source failed to arm — \(error.localizedDescription, privacy: .public)")
                }
            }
            liveSink = liveSinks.isEmpty
                ? nil
                : SourceFilteredPCMSink(FanOutPCMSink(liveSinks), allowedSources: [.mic])

            let capture = CaptureSession(config: config, liveSink: liveSink)
            try await capture.start()
            self.captureSession = capture

            // If the user's saved `systemAudioDeviceUID` resolved to a stale
            // aggregate device (`CADefaultDeviceAggregate-XXXXX-0` — macOS
            // recycles these IDs whenever it (re)builds the aggregate), the
            // capture session fell back to SCKit. Clear the stored UID so
            // the next recording goes straight to SCKit without paying the
            // 200 ms lookup cost again — and, more importantly, without
            // logging an error every single time.
            if await capture.deviceCaptureFellBack && !settings.systemAudioDeviceUID.isEmpty {
                Self.recorderLog.info("RecorderState.start: clearing stale systemAudioDeviceUID=\(self.settings.systemAudioDeviceUID, privacy: .public); will use SCKit going forward")
                settings.systemAudioDeviceUID = ""
            }

            // Screen recording is non-fatal: if it failed, surface a soft warning
            // so the user knows audio-only mode is active and how to fix it.
            if let srErr = await capture.screenRecordingError {
                let nsErr = srErr as NSError
                let isTCC = nsErr.code == -3801  // SCStreamErrorCode.userDeclined
                if isTCC {
                    self.screenRecordingWarning = "Screen Recording permission changed — recording audio only. To fix: run `tccutil reset ScreenCapture dev.kosmonotes.studio` in Terminal, then re-grant in System Settings → Privacy → Screen Recording."
                } else {
                    self.screenRecordingWarning = "Screen recording unavailable (\(srErr.localizedDescription)) — recording audio only."
                }
                Self.recorderLog.warning("RecorderState.start: screen recording failed, continuing audio-only — \(srErr.localizedDescription, privacy: .public)")
            } else {
                self.screenRecordingWarning = speakerEchoWarning
            }

            // / invariant I3: when SCStream owns the mic HAL
            // we must NOT start a second AVAudioEngine just to drive the UI
            // meter. CaptureSession exposes a cheap EMA-smoothed `micLevel`
            // computed from the same SCStream PCM buffers; we poll it on the
            // same ~33 ms cadence that MicLevelMeter used. Audio-only and
            // macOS 14 paths still use MicLevelMeter because there's no
            // SCStream client to fight there.
            let micSource = await capture.activeMicSource
            if micSource == .scStream {
                Self.recorderLog.info("RecorderState.start: SCStream mic owns the HAL — skipping MicLevelMeter (single-HAL invariant).")
                self.micMeter = nil
                let scStreamCapture = capture
                self.scStreamMicLevelPollerTask?.cancel()
                self.scStreamMicLevelPollerTask = Task { @MainActor [weak self] in
                    while !Task.isCancelled {
                        try? await Task.sleep(for: .milliseconds(33))
                        if Task.isCancelled { break }
                        guard let self else { break }
                        let level = await scStreamCapture.micLevel
                        self.micLevel = level
                    }
                }
            } else {
                let meter = MicLevelMeter()
                try meter.start { [weak self] level in
                    Task { @MainActor [weak self] in
                        self?.micLevel = level
                    }
                }
                self.micMeter = meter
            }

            // MicHealth poller: project CaptureSession.micHealth into the
            // observable surface every 1 s, and trigger the fail-safe stop
            // the moment we observe `.dead`. `.dead` is
            // emitted by the CaptureKit classifier ONLY after a 30 s stall
            // and recovery exhaustion, so waiting another 30 s here put the
            // total auto-stop budget at ~60 s — twice the invariant. Stopping
            // on first `.dead` keeps the user-visible budget at the documented
            // 30 s.
            self.micFailSafeTriggered = false
            self.screenDemotedDuringRecording = false
            self.micHealth = .warmingUp
            self.micHealthMessage = nil
            let healthStart = Date()
            self.micHealthPollerTask = Task { @MainActor [weak self] in
                while !Task.isCancelled {
                    try? await Task.sleep(for: .seconds(1))
                    if Task.isCancelled { break }
                    guard let self, let session = self.captureSession else { break }
                    let h = await session.micHealth
                    self.micHealth = h
                    // Mirror tier-2 demotion into the @Observable surface so
                    // the UI can show the partial-screen warning while the
                    // session is still running, not only after finalize.
                    let demoted = await session.tier2DemotedScreenRecording
                    if demoted && !self.screenDemotedDuringRecording {
                        self.screenDemotedDuringRecording = true
                    }
                    switch h {
                    case .ok, .muted, .idle, .warmingUp:
                        self.micHealthMessage = nil
                    case .degraded(let reason):
                        self.micHealthMessage = reason
                    case .dead(let reason):
                        self.micHealthMessage = reason
                        Self.recorderLog.error("RecorderState: fail-safe auto-stop on first .dead observation (reason: \(reason, privacy: .public)). The classifier emits .dead only after 30 s of stall + recovery exhaustion, so total elapsed from mic stall ≈ 30 s. Elapsed since recording start: \(Int(Date().timeIntervalSince(healthStart)), privacy: .public)s")
                        self.micFailSafeTriggered = true
                        // Fire stop() from a fresh unstructured task and end
                        // the poller: stop() cancels micHealthPollerTask —
                        // i.e. THIS task — so awaiting stop() inline would
                        // run the entire post-stop pipeline (URLSession
                        // transcription, asset loads, retry sleeps) under
                        // cooperative cancellation and fail it with
                        // "cancelled". Unstructured Tasks don't inherit
                        // cancellation from their spawning task.
                        Task { @MainActor [weak self] in
                            await self?.stop()
                        }
                        return
                    }
                }
            }

            // Mic-silence watchdog: every 5 s, log the current mic level so
            // the user can verify in Settings → Logs that the mic actually
            // captured sound. If the level stays at floor for >10 s after
            // recording starts, log a louder warning — most "my voice didn't
            // get recorded" reports are this exact failure mode (e.g. macOS
            // routed input to a dead Bluetooth HFP mic).
            let watchdogStart = Date()
            self.micWatchdogTask = Task { @MainActor [weak self] in
                var consecutiveSilent = 0
                while !Task.isCancelled {
                    try? await Task.sleep(for: .seconds(5))
                    if Task.isCancelled { break }
                    guard let self else { break }
                    let level = self.micLevel
                    let elapsed = Int(Date().timeIntervalSince(watchdogStart))
                    let muted = self.micMuted
                    Self.recorderLog.info("mic watchdog t=\(elapsed)s level=\(String(format: "%.4f", level), privacy: .public) muted=\(muted, privacy: .public)")
                    // Below ~0.002 RMS == effectively silence on every mic
                    // we've measured. Fire once per session at 10s mark.
                    if level < 0.002 && !muted {
                        consecutiveSilent += 1
                        if consecutiveSilent == 2 {
                            Self.recorderLog.error("mic watchdog: level near zero for \(elapsed)s — voice may not be reaching the mic. Check System Settings → Sound → Input, and AudioDevices snapshot above.")
                        }
                    } else {
                        consecutiveSilent = 0
                    }
                }
            }

            // Prevent the system from idle-sleeping for the lifetime of the
            // recording. Released in stop() / teardown().
            sleepAssertion.hold()

            // Reset live-mute on every new session so a previous mute doesn't
            // accidentally swallow the start of the next recording.
            self.micMuted = false
            await configureLiveTranscriptForRecording()
            self.status = .recording(sessionId: session.id)
        } catch {
            await teardown()
            self.status = .failed(message: "Could not start recording: \(error.localizedDescription)")
        }
    }

    /// Stop recording, finalize segments, run Whisper, persist transcript.
    func stop() async {
        // Reentrancy gate: a fail-safe auto-stop racing a user stop must not
        // double-enter — caller B would see captureSession == nil, get zero
        // segments, and clobber `status` with .failed while caller A is mid-
        // transcription. The flag is set synchronously before the first await.
        guard case .recording(let sessionId) = status,
              !lifecycleTransitionInFlight else { return }
        lifecycleTransitionInFlight = true
        defer { lifecycleTransitionInFlight = false }

        // Read capture-side flags BEFORE we tear the session down: tier-2
        // demotion of screen recording must be persisted onto
        // the session record so the Library row can show "screen video
        // stopped mid-session" — the supervisor's flag goes away with the
        // CaptureSession reference and there is no other source of truth.
        let tier2Demoted = (await captureSession?.tier2DemotedScreenRecording) ?? false

        // Tear down capture + meter regardless of what happens next.
        let segments: [URL]
        do {
            segments = try await captureSession?.stop() ?? []
        } catch {
            segments = []
        }
        captureSession = nil
        micMeter?.stop()
        micMeter = nil
        scStreamMicLevelPollerTask?.cancel()
        scStreamMicLevelPollerTask = nil
        micLevel = 0
        micWatchdogTask?.cancel()
        micWatchdogTask = nil
        micHealthPollerTask?.cancel()
        micHealthPollerTask = nil
        micHealth = .idle
        sleepAssertion.release()
        await cameraBubbleController.hide()
        let liveTranscript = await finishLiveTranscript()

        if tier2Demoted {
            self.screenDemotedDuringRecording = true
        }

        guard !segments.isEmpty else {
            let msg = micFailSafeTriggered
                ? "Recording auto-stopped: mic stopped delivering audio. Likely an audio HAL conflict (Bluetooth disconnect, screen-recording HAL race, or device pull). Try again — the SCStream mic path should be more resilient on macOS 15+."
                : "No audio captured (check Microphone permission in System Settings)."
            self.status = .failed(message: msg)
            return
        }
        if micFailSafeTriggered {
            // Recording was auto-stopped mid-session because mic died and
            // could not be recovered. We still have N seconds of audio that
            // captured before the failure; finalize and surface a warning so
            // the user sees the row is incomplete.
            self.screenRecordingWarning = "Mic stopped delivering audio mid-session; recording was auto-stopped. Captured up to the failure point."
        } else if tier2Demoted {
            // tier-2 fallback succeeded — we kept the mic
            // alive but the screen capture is partial. Surface a distinct
            // copy from the mic fail-safe so the user knows screen video
            // stopped, not audio.
            self.screenRecordingWarning = "Screen capture stopped mid-session; recording continued audio-only after the fallback. Screen video is partial."
        }

        self.status = .transcribing(sessionId: sessionId)

        do {
            let dir = await sessionStore.sessionDir(for: sessionId)

            // persist a sidecar tag whenever tier-2 fallback
            // demoted screen recording mid-session. The Library row reads
            // this to show "screen video is partial" instead of the generic
            // post-process partial message — capture warnings are about the
            // recording itself, post-process warnings are about optional
            // cleanup/summary stages, and the two should not collapse to the
            // same help text.
            // The mic fail-safe is the more severe signal, so it wins the
            // sidecar when both fired in the same session.
            if micFailSafeTriggered {
                let sidecar = dir.appendingPathComponent("capture-warning.txt")
                let message = "mic-failsafe: mic stopped delivering audio mid-session; recording was auto-stopped. Audio is captured up to the failure point."
                try? Data(message.utf8).write(to: sidecar, options: .atomic)
            } else if tier2Demoted {
                let sidecar = dir.appendingPathComponent("capture-warning.txt")
                let message = "screen-demoted: screen capture stopped mid-session; recording continued audio-only after the fallback. Screen video is partial."
                try? Data(message.utf8).write(to: sidecar, options: .atomic)
            }

            // Concatenate .m4a segments into a single audio.m4a via AVMutableComposition.
            let orphan = RecoveryService.OrphanSession(
                id: sessionId,
                sessionDir: dir,
                segmentURLs: segments
            )
            let audioFile = try await recoveryService.finalize(orphan)

            // Fold the mic track from audio.m4a into screen.mp4 so playback gives
            // you BOTH your voice and the system audio in the video file. Run it
            // concurrently with transcription, then join before marking the
            // session complete so Library/Share never sees a stale screen.mp4.
            let screenURL = dir.appendingPathComponent("screen.mp4")
            let mixTask: Task<ScreenAudioMixResult, Never> = Task.detached {
                await Self.mixScreenAudioIfPresent(screenURL: screenURL, audioFile: audioFile)
            }

            let asset = AVURLAsset(url: audioFile)
            let cmDuration = try await asset.load(.duration)
            let duration = CMTimeGetSeconds(cmDuration)

            let language: String? = {
                let s = settings.summaryLanguage
                return (s == "auto" || s.isEmpty) ? nil : s
            }()
            let result: BatchTranscriptResult
            let usedLiveTranscript: Bool
            if let liveResult = Self.liveTranscriptResult(
                from: liveTranscript.finalSegments,
                duration: duration,
                language: language
            ) {
                result = liveResult
                usedLiveTranscript = true
                Self.recorderLog.info("RecorderState.stop: using finalized live transcript; skipping batch transcription")
            } else {
                let resolvedTx = TranscriptionResolver.resolve(settings.transcriptionConfig)
                let provider = resolvedTx.provider

                // Pre-flight cost gate. Long recordings + a per-minute pricing
                // model can push past the user's cap silently — surface the same
                // "increase cap or cancel" modal we already use for summary /
                // cleanup. Providers without a known per-minute price (Gemini,
                // OpenRouter) return nil pricing and skip the gate.
                let txPricing = resolvedTx.pricing
                if let pricing = txPricing {
                    let estimated = CostEstimator.estimateTranscription(durationSec: duration, pricing: pricing)
                    if estimated > settings.costCapUSD {
                        let proceed = await Self.confirmCostOverage(
                            kind: "Transcription",
                            estimated: estimated,
                            cap: settings.costCapUSD,
                            onIncrease: { [weak self] newCap in self?.settings.costCapUSD = newCap }
                        )
                        if !proceed {
                            status = .failed(message: "Transcription cancelled — estimated cost exceeded the cap.")
                            await teardown()
                            return
                        }
                    }
                }

                result = try await provider.transcribe(
                    audioFile: audioFile,
                    config: TranscriptionConfig(language: language)
                )
                usedLiveTranscript = false
            }

            // Optional LLM cleanup pass — fixes ASR mistakes (numbers, names,
            // double-words, missing punctuation) without touching segment
            // boundaries. Only the full text gets rewritten; segment timing is
            // preserved from the ASR output. On failure (no key, network, etc.)
            // we keep the raw text and continue.
            let cleanedText: String
            if settings.transcriptCleanupEnabled {
                cleanedText = await tryCleanupTranscript(
                    rawText: result.text,
                    sourceLanguage: result.language
                ) ?? result.text
            } else {
                cleanedText = result.text
            }

            if usedLiveTranscript, liveTranscript.persistedIncrementally {
                try AtomicWriter.write(Data(cleanedText.utf8), to: dir.appendingPathComponent("transcript.txt"))
            } else {
                if usedLiveTranscript {
                    Self.removeTranscriptSidecars(in: dir)
                }
                // Persist transcript.jsonl (segments with timing — always raw) +
                // transcript.txt (the cleaned full text users actually read).
                let store = try TranscriptStore(sessionDir: dir)
                for segment in result.segments {
                    try await store.append(segment)
                }
                try await store.close(overrideText: cleanedText)
                // Always emit a timestamped sidecar alongside the cleaned text.
                // `transcript.txt` may be LLM-rewritten and lose segment timing;
                // `transcript.timestamped.txt` preserves [HH:MM:SS] anchors per
                // raw segment so the Library player / chat can scrub by moment.
                try? await store.writeTimestamped()
            }
            // Track whether any opt-in enhancement step degraded silently —
            // `partial` surfaces that in the Library row. Also seed `partial`
            // when tier-2 fallback demoted screen recording mid-session: the
            // screen.mp4 the user gets is truncated, and the Library row
            // should reflect that even if every post-stop enhancement succeeded.
            // Same for the mic fail-safe: the audio itself is truncated at the
            // failure point, which is the definition of a partial session.
            var enhancement: SessionEnhancementStatus =
                (tier2Demoted || micFailSafeTriggered) ? .partial : .ok
            if settings.transcriptCleanupEnabled, cleanedText != result.text {
                let rawURL = dir.appendingPathComponent("transcript.raw.txt")
                try? AtomicWriter.write(Data(result.text.utf8), to: rawURL)
            }
            // Cleanup was opted in but produced no usable result (returned the
            // raw text unchanged) → mark partial so the badge shows up.
            // We can't distinguish "model returned identical text" from
            // "fallback to raw" without a richer return type; for v1 we treat
            // identity as the signal — false positives on perfectly-clean
            // transcripts are acceptable cost.
            if settings.transcriptCleanupEnabled,
               cleanedText.trimmingCharacters(in: .whitespacesAndNewlines)
                 == result.text.trimmingCharacters(in: .whitespacesAndNewlines) {
                enhancement = .partial
            }

            // FTS index + DB row finalize — index the cleaned text so search
            // hits the corrected words, not the misheard versions.
            try await sessionStore.indexTranscript(sid: sessionId, text: cleanedText)

            // Optional embedding index for semantic search. Failures are silent;
            // FTS5 is the primary index, embeddings just augment recall.
            if settings.semanticSearchEnabled {
                await indexSemantic(sid: sessionId, transcript: cleanedText)
            }

            // Generate AI summary; failures are non-fatal — pipeline continues regardless.
            lastSummaryURL = await tryGenerateSummary(
                transcript: cleanedText,
                sessionDir: dir,
                sourceLanguage: result.language
            )
            // Summary failed despite a non-empty transcript? Mark partial.
            // tryGenerateSummary returns nil for: empty input (skip), missing
            // API key (also fine — user not configured), cost-cap rejection
            // (intentional skip), and real LLM failure. We only know the
            // outcome; preserve a conservative "if non-empty input → expect
            // a summary" rule.
            if !cleanedText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
               lastSummaryURL == nil {
                enhancement = .partial
            }

            // Optional Markdown export — runs the cleaned transcript through
            // the user's custom system + user prompts and writes a `.md` to
            // their chosen folder. Independent of summary.md (which uses our
            // built-in PromptTemplates). Non-fatal if it fails.
            _ = await MarkdownExporter.export(
                transcript: cleanedText,
                settings: settings,
                sessionID: sessionId,
                sessionMode: activeMode,
                recordedAt: Date()
            )

            switch await mixTask.value {
            case .mixed:
                Self.recorderLog.info("RecorderState.stop: screen.mp4 mic mix completed")
            case .failed(let message):
                enhancement = .partial
                Self.recorderLog.error("RecorderState.stop: screen.mp4 mic mix failed: \(message, privacy: .public)")
            case .skipped:
                break
            }

            try await sessionStore.finalize(
                id: sessionId,
                status: .complete,
                durationSecs: duration,
                enhancementStatus: enhancement
            )

            let preview = previewText(cleanedText)
            self.status = .complete(sessionId: sessionId, audioFile: audioFile, transcriptPreview: preview)
        } catch {
            // Mark the session failed in the DB, but don't crash if that fails too.
            try? await sessionStore.finalize(id: sessionId, status: .failed, durationSecs: 0)
            self.status = .failed(message: "Transcription failed: \(error.localizedDescription)")
        }
    }

    // tryCleanupTranscript / tryGenerateSummary / indexSemantic live in
    // RecorderState+Cleanup.swift / +Summary.swift / +SemanticIndex.swift
    // so this file stays focused on capture lifecycle. confirmCostOverage
    // is kept here since it's also called from `stop()` (transcription
    // cost-cap gate); module-internal so the +Summary extension can call
    // it across files.

    // MARK: - Cost-cap modal

    /// Surface "estimate exceeds cap" modal. Returns true if the user agreed
    /// to proceed (after raising the cap), false on cancel. `kind` controls
    /// the modal title ("AI summary", "Transcription", "Cleanup", …) so the
    /// same chrome surfaces all three cost-cap gates with stage-specific text.
    /// Static so it doesn't capture `self` weakly across the alert presentation.
    @MainActor
    static func confirmCostOverage(
        kind: String = "AI summary",
        estimated: Double,
        cap: Double,
        onIncrease: (Double) -> Void
    ) async -> Bool {
        let alert = NSAlert()
        alert.messageText = "\(kind) cost exceeds cap"
        alert.informativeText = String(
            format: "Estimated cost $%.4f exceeds your per-session cap $%.2f.\n\nIncrease the cap to allow this %@, or cancel to skip it.",
            estimated,
            cap,
            kind.lowercased()
        )
        alert.alertStyle = .warning
        let increaseTitle = String(format: "Increase cap to $%.2f", estimated)
        alert.addButton(withTitle: increaseTitle)
        alert.addButton(withTitle: "Cancel")
        let response = alert.runModal()
        if response == .alertFirstButtonReturn {
            // Round up to the next cent so the new cap actually exceeds the estimate.
            let rounded = (ceil(estimated * 100) / 100)
            onIncrease(rounded)
            return true
        }
        return false
    }

    nonisolated static func mixScreenAudioIfPresent(
        screenURL: URL,
        audioFile: URL,
        mixer: @escaping ScreenAudioMixerFunction = { screenURL, audioFile in
            try await ScreenAudioMixer.mixMicInto(screenMP4: screenURL, audioM4A: audioFile)
        }
    ) async -> ScreenAudioMixResult {
        guard FileManager.default.fileExists(atPath: screenURL.path) else {
            return .skipped
        }

        do {
            try await mixer(screenURL, audioFile)
            return .mixed
        } catch {
            return .failed(error.localizedDescription)
        }
    }

    nonisolated static func liveTranscriptResult(
        from segments: [TranscriptSegment],
        duration: TimeInterval,
        language: String?
    ) -> BatchTranscriptResult? {
        let finalSegments = segments.filter(\.isFinal)
        let text = liveTranscriptText(from: finalSegments)
        guard !text.isEmpty else { return nil }
        return BatchTranscriptResult(
            language: language,
            duration: duration,
            segments: finalSegments,
            text: text
        )
    }

    nonisolated static func liveTranscriptText(from segments: [TranscriptSegment]) -> String {
        segments
            .map { $0.text.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .joined(separator: " ")
    }

    nonisolated static func removeTranscriptSidecars(in sessionDir: URL) {
        for fileName in [
            "transcript.jsonl",
            "transcript.txt",
            "transcript.timestamped.txt",
            "transcript.raw.txt",
        ] {
            try? FileManager.default.removeItem(at: sessionDir.appendingPathComponent(fileName))
        }
    }

    // MARK: - Helpers

    private func teardown() async {
        if let session = captureSession {
            _ = try? await session.stop()
            captureSession = nil
        }
        micMeter?.stop()
        micMeter = nil
        scStreamMicLevelPollerTask?.cancel()
        scStreamMicLevelPollerTask = nil
        micLevel = 0
        micWatchdogTask?.cancel()
        micWatchdogTask = nil
        micHealthPollerTask?.cancel()
        micHealthPollerTask = nil
        micHealth = .idle
        sleepAssertion.release()
        await cameraBubbleController.hide()
        await clearLiveTranscript()
    }

    private func previewText(_ text: String) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.count <= 240 { return trimmed }
        return String(trimmed.prefix(240)) + "…"
    }

    func attachLiveTranscriptSnapshotSource(
        _ snapshotSource: @escaping RecorderLiveAdapter.SnapshotSource
    ) async {
        liveTranscriptAdapter = RecorderLiveAdapter(snapshotSource: snapshotSource)
        await refreshLiveTranscript()
    }

    func refreshLiveTranscript() async {
        applyLiveTranscript(await liveTranscriptAdapter.displayState())
    }

    func liveTranscriptSnapshot() async -> LiveTranscriptState? {
        if let hub = liveTranscriptHub {
            return await hub.snapshot()
        }
        if let tee = liveTranscriptTee {
            return await tee.snapshot()
        }
        return nil
    }

    private func configureLiveTranscriptForRecording() async {
        if let hub = liveTranscriptHub {
            liveTranscriptAdapter = RecorderLiveAdapter(snapshotSource: { await hub.snapshot() })
            liveTranscriptRefreshTask?.cancel()
            liveTranscriptRefreshTask = Task { @MainActor [weak self] in
                while !Task.isCancelled {
                    try? await Task.sleep(for: .milliseconds(500))
                    if Task.isCancelled { return }
                    await self?.refreshLiveTranscript()
                }
            }
        } else if let tee = liveTranscriptTee {
            liveTranscriptAdapter = RecorderLiveAdapter(snapshotSource: { await tee.snapshot() })
            liveTranscriptRefreshTask?.cancel()
            liveTranscriptRefreshTask = Task { @MainActor [weak self] in
                while !Task.isCancelled {
                    try? await Task.sleep(for: .milliseconds(500))
                    if Task.isCancelled { return }
                    await self?.refreshLiveTranscript()
                }
            }
        } else {
            liveTranscriptAdapter = RecorderLiveAdapter()
        }
        await refreshLiveTranscript()
    }

    private func clearLiveTranscript() async {
        _ = await finishLiveTranscript()
    }

    private func finishLiveTranscript() async -> FinishedLiveTranscript {
        liveTranscriptRefreshTask?.cancel()
        liveTranscriptRefreshTask = nil
        if let tee = liveTranscriptTee {
            await tee.stop()
        }
        if let source = streamingLiveSource {
            await source.stop()
        }
        let finalSegments = await liveTranscriptHub?.finalSegments() ?? []
        var persistedIncrementally = false
        if let store = liveTranscriptStore {
            do {
                try await store.close()
                persistedIncrementally = await store.segments() == finalSegments
                try await store.writeTimestamped()
            } catch {
                Self.recorderLog.error("RecorderState: live transcript store failed to close — \(error.localizedDescription, privacy: .public)")
            }
        }
        liveTranscriptTee = nil
        streamingLiveSource = nil
        liveTranscriptHub = nil
        liveTranscriptStore = nil
        liveTranscriptAdapter = RecorderLiveAdapter()
        applyLiveTranscript(.empty)
        return FinishedLiveTranscript(
            finalSegments: finalSegments,
            persistedIncrementally: persistedIncrementally
        )
    }

    private func applyLiveTranscript(_ display: RecorderLiveAdapter.DisplayState) {
        liveTranscriptStableText = display.stableText
        liveTranscriptMutableText = display.mutableText
        liveTranscriptStatusText = display.statusText
        liveTranscriptIsDelayed = display.isDelayed
    }
}

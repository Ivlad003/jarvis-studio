@preconcurrency import AVFoundation
import Foundation
import os

private let captureSessionLog = Logger(subsystem: "dev.kosmonotes.studio", category: "CaptureSession")

// MARK: - AudioCodecChoice

/// Public codec choice for capture configuration. Mirror of the user's
/// AppSettings.AudioCodec but kept inside CaptureKit so library consumers
/// (tests, callers from other targets) don't need to import App-level types.
public enum AudioCodecChoice: String, Sendable {
    case aac        // AAC-LC (kAudioFormatMPEG4AAC)
    case heAAC      // HE-AAC v1 (kAudioFormatMPEG4AAC_HE) — ~50% smaller for voice
    case opus       // Opus — silently downgraded to HE-AAC in .m4a containers

    var formatID: AudioFormatID {
        switch self {
        case .aac:   return kAudioFormatMPEG4AAC
        case .heAAC: return kAudioFormatMPEG4AAC_HE
        case .opus:  return kAudioFormatOpus
        }
    }
}

// MARK: - LivePCMSink

public typealias LivePCMSource = AudioSource

/// Protocol for receiving live PCM buffers during capture.
///
/// Conformers receive a copy of each PCM buffer as it flows through
/// CaptureSession's feed loops. The sink is best-effort: if the sink throws
/// or fails, the main capture path (SegmentWriter) continues unaffected.
public protocol LivePCMSink: Sendable {
    /// Receives a PCM buffer from the specified audio source.
    /// Called on a detached Task; implementers may be isolated actors.
    /// - Parameters:
    ///   - buffer: The PCM buffer to receive
    ///   - hostTime: Mach absolute time at which the buffer was captured
    ///   - source: Capture source that produced the buffer
    func receive(_ buffer: AVAudioPCMBuffer, at hostTime: UInt64, source: LivePCMSource) async
}

public struct FanOutPCMSink: LivePCMSink {
    private let sinks: [any LivePCMSink]

    public init(_ sinks: [any LivePCMSink]) {
        self.sinks = sinks
    }

    public func receive(_ buffer: AVAudioPCMBuffer, at hostTime: UInt64, source: LivePCMSource) async {
        for sink in sinks {
            await sink.receive(buffer, at: hostTime, source: source)
        }
    }
}

public struct SourceFilteredPCMSink: LivePCMSink {
    private let sink: any LivePCMSink
    private let allowedSources: Set<LivePCMSource>

    public init(_ sink: any LivePCMSink, allowedSources: Set<LivePCMSource>) {
        self.sink = sink
        self.allowedSources = allowedSources
    }

    public func receive(_ buffer: AVAudioPCMBuffer, at hostTime: UInt64, source: LivePCMSource) async {
        guard allowedSources.contains(source) else { return }
        await sink.receive(buffer, at: hostTime, source: source)
    }
}

// MARK: - LiveSinkDelivery

/// Serial delivery coordinator for live PCM sink with bounded buffering.
///
/// Prevents unbounded task-per-buffer spawning while keeping capture isolated
/// from sink slowness. Buffers are delivered in-order to the sink without
/// blocking the capture loop. A bounded queue (default 32 items) protects
/// against memory growth when the sink is slow — the queue retains the newest
/// 32 buffers, dropping the oldest pending buffer when backpressure builds.
private actor LiveSinkDelivery {
    private actor Metrics {
        private let maxQueueSize: Int
        private var queuedCount: Int = 0
        private var droppedCount: Int = 0

        init(maxQueueSize: Int) {
            self.maxQueueSize = maxQueueSize
        }

        func recordEnqueue(result: AsyncStream<(AVAudioPCMBuffer, UInt64, LivePCMSource)>.Continuation.YieldResult) -> Int? {
            switch result {
            case .enqueued:
                queuedCount = min(queuedCount + 1, maxQueueSize)
                return nil
            case .dropped:
                queuedCount = maxQueueSize
                droppedCount += 1
                return droppedCount
            case .terminated:
                return nil
            @unknown default:
                return nil
            }
        }

        func recordDequeue() {
            if queuedCount > 0 {
                queuedCount -= 1
            }
        }

        func totalDropped() -> Int {
            droppedCount
        }
    }

    private let sink: any LivePCMSink
    private var deliveryTask: Task<Void, Never>?
    private let continuation: AsyncStream<(AVAudioPCMBuffer, UInt64, LivePCMSource)>.Continuation
    private let metrics: Metrics

    init(sink: any LivePCMSink, maxQueueSize: Int = 32) {
        self.sink = sink
        self.metrics = Metrics(maxQueueSize: maxQueueSize)
        let (stream, continuation) = AsyncStream<(AVAudioPCMBuffer, UInt64, LivePCMSource)>.makeStream(
            bufferingPolicy: .bufferingNewest(maxQueueSize)
        )
        self.continuation = continuation
        // Wrap stream in UncheckedSendableBox to satisfy Swift 6 strict concurrency
        let streamBox = UncheckedSendableBox(stream)
        let metrics = self.metrics
        self.deliveryTask = Task.detached {
            var delivered = 0
            for await (buffer, hostTime, source) in streamBox.value {
                await metrics.recordDequeue()
                await sink.receive(buffer, at: hostTime, source: source)
                delivered += 1
            }
            captureSessionLog.debug("LiveSinkDelivery: delivered \(delivered, privacy: .public) buffers total")
        }
    }

    /// Enqueue a buffer for serial delivery. Returns immediately without awaiting sink.
    /// If the queue is full, drops the oldest buffer (drop-oldest policy).
    func enqueue(_ buffer: AVAudioPCMBuffer, hostTime: UInt64, source: LivePCMSource) async {
        if let droppedCount = await metrics.recordEnqueue(result: continuation.yield((buffer, hostTime, source))),
           droppedCount % 10 == 0 {
            captureSessionLog.warning("LiveSinkDelivery: dropped \(droppedCount, privacy: .public) buffers due to slow sink")
        }
    }

    /// Stop accepting new buffers and wait for in-flight delivery to complete.
    func finish() async {
        continuation.finish()
        await deliveryTask?.value
        deliveryTask = nil
        let droppedCount = await metrics.totalDropped()
        if droppedCount > 0 {
            captureSessionLog.info("LiveSinkDelivery.finish: dropped \(droppedCount, privacy: .public) total buffers during session")
        }
    }
}

// MARK: - MicHealth

/// Pure inputs the classifier needs to decide the current MicHealth. Keeping
/// these in a small struct lets us unit-test transitions without spinning up
/// a real CaptureSession + waiting through wall-clock timers.
public struct MicHealthSnapshot: Sendable, Equatable {
    public let isMuted: Bool
    public let everDelivered: Bool
    public let sinceLastBuffer: TimeInterval
    public let sinceStart: TimeInterval
    public let warmupSeconds: TimeInterval
    public let degradedThreshold: TimeInterval
    public let deadThreshold: TimeInterval
    public let scStreamRecoveryGaveUp: Bool
    public let tier2Attempted: Bool

    public init(
        isMuted: Bool,
        everDelivered: Bool,
        sinceLastBuffer: TimeInterval,
        sinceStart: TimeInterval,
        warmupSeconds: TimeInterval = 5,
        degradedThreshold: TimeInterval = 5,
        deadThreshold: TimeInterval = 30,
        scStreamRecoveryGaveUp: Bool = false,
        tier2Attempted: Bool = false
    ) {
        self.isMuted = isMuted
        self.everDelivered = everDelivered
        self.sinceLastBuffer = sinceLastBuffer
        self.sinceStart = sinceStart
        self.warmupSeconds = warmupSeconds
        self.degradedThreshold = degradedThreshold
        self.deadThreshold = deadThreshold
        self.scStreamRecoveryGaveUp = scStreamRecoveryGaveUp
        self.tier2Attempted = tier2Attempted
    }
}

/// Pure-function MicHealth classifier. The CaptureSession supervisor calls
/// this with a `MicHealthSnapshot` it built from live state; tests call it
/// directly with synthetic snapshots.
public enum MicHealthClassifier {
    public static func classify(_ s: MicHealthSnapshot) -> MicHealth {
        if s.isMuted { return .muted }
        if !s.everDelivered, s.sinceStart < s.warmupSeconds { return .warmingUp }
        // Both branches imply we've lost the SCStream mic source. Tier-2 may
        // or may not have run; either way mic is dead from the caller's POV
        // until we re-establish flow.
        if s.scStreamRecoveryGaveUp, s.tier2Attempted {
            return .dead(reason: "SCStream mic recovery exhausted, tier-2 AVAudioEngine fallback also failed")
        }
        if s.sinceLastBuffer >= s.deadThreshold {
            return .dead(reason: "No mic buffers for \(Int(s.sinceLastBuffer))s — recovery did not restore flow")
        }
        if s.sinceLastBuffer >= s.degradedThreshold {
            return .degraded(reason: "No mic buffers for \(Int(s.sinceLastBuffer))s — attempting recovery")
        }
        return .ok
    }
}

/// Single source of truth for whether the active mic source is actually
/// delivering samples. Consumers (RecorderState, menu bar, library) read this
/// rather than scrape logs. Drives the always-on invariant: the user must see
/// within seconds when their voice has stopped reaching disk.
public enum MicHealth: Equatable, Sendable {
    /// Capture isn't running.
    case idle
    /// First N seconds of capture; the supervisor is intentionally quiet
    /// because cold-start latency varies (~1.5 s for SCStream mic, up to 8 s
    /// for AVAudioEngine on Bluetooth HFP). UI shows "starting up" here.
    case warmingUp
    /// Buffers are flowing. Healthy state. UI shows the green dot.
    case ok
    /// User pressed mute. NOT a fault — the engine still ticks. UI shows
    /// the orange/muted indicator, not the red one.
    case muted
    /// No mic buffers for 5–30 s while not muted. Recovery may already be
    /// running (SCStream restart, AVAudioEngine recreate). UI shows yellow
    /// + a banner explaining we're trying to recover.
    case degraded(reason: String)
    /// No mic buffers for >30 s and recovery exhausted. The fail-safe will
    /// stop the recording shortly. UI shows red + a "mic dropped" message.
    case dead(reason: String)
}

// MARK: - CaptureSession

/// Top-level coordinator for audio capture.
///
/// Combines `AudioEngine` (mic) and `SCKitAudioCapture` (system audio) into
/// a single API. Both sources feed one `SegmentWriter` which writes 5-second
/// rolling segments to `<sessionDir>/segments/<n>.m4a`.
///
/// When a `LivePCMSink` is provided, PCM buffers are also forwarded to the
/// sink in real-time. The sink path is best-effort and does not affect the
/// main recording path.
public actor CaptureSession {

    // MARK: - State

    private var liveDelivery: LiveSinkDelivery?

    // MARK: - Config

    public struct Config: Sendable {
        public let micEnabled: Bool
        public let systemAudioEnabled: Bool
        public let echoCancellationEnabled: Bool
        public let sessionDir: URL
        public let segmentDurationSeconds: Double
        /// When true, a ScreenRecorder is started alongside audio capture.
        public let screenRecordingEnabled: Bool
        /// Where ScreenRecorder writes screen.mp4; ignored when screenRecordingEnabled is false.
        public let screenOutputURL: URL?
        /// When true and the OS is macOS 14.4+, system audio is captured via
        /// per-process Core Audio Taps targeting `processTapBundleIDs`. Falls
        /// back to SCKit whole-system mixdown on older OS or any tap failure.
        public let useProcessTap: Bool
        /// Bundle IDs to capture when `useProcessTap` is on. Only running apps
        /// match — apps launched after `start()` are not added retroactively.
        public let processTapBundleIDs: [String]
        /// Use HEVC for screen.mp4. ~50 % smaller at same quality.
        public let videoUseHEVC: Bool
        /// Video bitrate in bits/sec.
        public let videoBitrate: Int
        /// Audio bitrate in bits/sec for both audio.m4a (segmented) and screen.mp4.
        public let audioBitrate: Int
        /// Audio sample rate Hz.
        public let audioSampleRate: Int
        /// Audio codec (`aac` / `heAAC` / `opus`). Opus falls back to HE-AAC when
        /// the .m4a container can't carry it. Only AAC-family codecs work in .m4a.
        public let audioCodec: AudioCodecChoice
        /// When set, system audio is captured from this Core Audio input device
        /// (e.g. BlackHole 2ch loopback) instead of SCKit's whole-system mixdown.
        /// Lets users avoid the speaker → mic echo loop by routing system audio
        /// through a virtual device that the mic doesn't pick up.
        public let systemAudioDeviceUID: String?
        /// Preferred display ID for screen recording. `0` means use the first available display.
        public let screenCaptureDisplayID: UInt32

        public init(
            micEnabled: Bool = true,
            systemAudioEnabled: Bool = false,
            echoCancellationEnabled: Bool = false,
            sessionDir: URL,
            segmentDurationSeconds: Double = 5.0,
            screenRecordingEnabled: Bool = false,
            screenOutputURL: URL? = nil,
            useProcessTap: Bool = false,
            processTapBundleIDs: [String] = [],
            videoUseHEVC: Bool = true,
            videoBitrate: Int = 2_000_000,
            audioBitrate: Int = 48_000,
            audioSampleRate: Int = 48_000,
            audioCodec: AudioCodecChoice = .heAAC,
            systemAudioDeviceUID: String? = nil,
            screenCaptureDisplayID: UInt32 = 0
        ) {
            self.micEnabled = micEnabled
            self.systemAudioEnabled = systemAudioEnabled
            self.echoCancellationEnabled = echoCancellationEnabled
            self.sessionDir = sessionDir
            self.segmentDurationSeconds = segmentDurationSeconds
            self.screenRecordingEnabled = screenRecordingEnabled
            self.screenOutputURL = screenOutputURL
            self.useProcessTap = useProcessTap
            self.processTapBundleIDs = processTapBundleIDs
            self.videoUseHEVC = videoUseHEVC
            self.videoBitrate = videoBitrate
            self.audioBitrate = audioBitrate
            self.audioSampleRate = audioSampleRate
            self.audioCodec = audioCodec
            self.systemAudioDeviceUID = systemAudioDeviceUID
            self.screenCaptureDisplayID = screenCaptureDisplayID
        }
    }

    /// Helper used at SegmentWriter construction time. Pulled out to keep the
    /// `try` site short.
    private static func formatIDForCodec(config: Config) -> AudioFormatID {
        config.audioCodec.formatID
    }

    static func micAudioEngineConfig(for config: Config) -> AudioEngine.Config {
        AudioEngine.Config(
            sampleRate: Double(config.audioSampleRate),
            channels: 1,
            voiceProcessing: false
        )
    }

    // MARK: - Private state

    private enum RecordingState { case idle, recording, paused, stopped }

    /// Which path is feeding the SegmentWriter's mic source. Made observable
    /// so callers (RecorderState) can suppress MicLevelMeter when SCStream
    /// already owns the mic HAL — see invariant I3 in
    /// docs/plans/2026-06-06-always-on-capture-design.md.
    public enum ActiveMicSource: Equatable, Sendable {
        /// Recording isn't running, or `micEnabled` was false.
        case none
        /// Cold path: a CaptureKit `AudioEngine` owns the mic HAL. Used on
        /// macOS 14 and on audio-only sessions where there is no SCStream
        /// fighting for the HAL.
        case audioEngine
        /// Hot path (macOS 15+, screen + mic both requested): SCStream's
        /// microphone output owns the mic HAL. No second AVAudioEngine may
        /// run while this source is active.
        case scStream
    }

    private let config: Config
    private var recordingState: RecordingState = .idle
    private var audioEngine: AudioEngine?
    private var segmentWriter: SegmentWriter?
    private var micTask: Task<Void, Never>?
    private var systemTask: Task<Void, Never>?
    private var scStreamSystemTaskRunning: Bool = false
    private var scKitBox: SCKitBox?
    private var screenRecorder: ScreenRecorder?
    /// Tracks which mic source is feeding the writer. Updated by start /
    /// pause / resume / tier-2 fallback. Public so RecorderState can branch
    /// on it (e.g. skip MicLevelMeter when SCStream mic owns the HAL).
    public private(set) var activeMicSource: ActiveMicSource = .none
    /// Writer-side mic delivery counters. Bumped only when `writer.append`
    /// returns successfully — so health derived from these reflects samples
    /// that actually reached disk, not just samples produced by SCStream that
    /// might be dropped by `bufferingNewest(100)` or rejected by the writer.
    /// / design invariant I5.
    private var micWriterAppendCount: Int = 0
    private var micWriterTotalFrames: Int = 0
    /// Smoothed RMS of the active mic source, exposed for UI meters when the
    /// SCStream-mic path is in use. Lets RecorderState suppress
    /// `MicLevelMeter`'s second AVAudioEngine on macOS 15+ screen+mic mode
    /// without losing the visual signal. Range [0, 1].
    private var _micLevel: Double = 0
    /// Public read-only snapshot of the meter. Polled by RecorderState every
    /// ~33 ms (the same cadence MicLevelMeter used on the AudioEngine path).
    public var micLevel: Double { _micLevel }
    /// True once the active mic source has stopped (writer.append closed,
    /// stream ended, or scStream cancelled by stop). Used by the pause/resume
    /// path to know whether the SCStream feed task is still draining buffers.
    private var scStreamMicTaskRunning: Bool = false
    /// Set when screen recording was requested but failed at start (e.g. TCC denied).
    /// Callers may surface a non-blocking warning to the user.
    public private(set) var screenRecordingError: Error?
    /// Set when the standalone system-audio capture path terminates externally
    /// or reports a terminal stream failure.
    public private(set) var systemAudioError: Error?
    /// Stored as `AnyObject?` because `TapBox` is `@available(macOS 14.4, *)` —
    /// stricter than the package's macOS 14.0 deployment target. Cast at the
    /// use site under `#available(macOS 14.4, *)`.
    private var tapBoxAny: AnyObject?
    /// Capture for the user-selected loopback device (BlackHole etc).
    /// Mutually exclusive with `scKitBox` / `tapBoxAny` — when set, system
    /// audio comes from this device instead of SCKit's whole-system mixdown.
    private var deviceAudioCapture: DeviceAudioCapture?
    /// Pure Swift/vDSP post-capture echo canceller. This replaces the old
    /// VoiceProcessingIO attempt; it never mutates the AVAudioEngine graph.
    private var echoCancellationProcessor: EchoCancellationProcessor?
    /// Set when the user had a `systemAudioDeviceUID` configured but the
    /// device couldn't be resolved at start (e.g. a stale aggregate UID like
    /// `CADefaultDeviceAggregate-22634-0` that macOS recycled). Callers may
    /// use this to clear the stored setting so subsequent recordings skip
    /// the failed lookup and go straight to SCKit fallback.
    public private(set) var deviceCaptureFellBack: Bool = false
    /// Optional sink for live PCM buffers. When set, each buffer is forwarded
    /// to the sink after appending to the SegmentWriter. Best-effort: sink
    /// failures do not interrupt the main recording path.
    private var liveSink: (any LivePCMSink)?
    /// Test seam: when set, this stream is used instead of starting a real mic.
    /// Internal for testing only; never exposed to public API.
    private let testMicStream: AsyncStream<AVAudioPCMBuffer>?
    /// Test seam: when set, this stream is used instead of SCKit/device/tap
    /// system audio. Lets tests verify DSP-AEC wiring without TCC.
    private let testSystemStream: AsyncStream<AVAudioPCMBuffer>?
    /// Test seam: when set, start() throws at the real-mic bootstrap point
    /// without touching AVAudioEngine. Lets tests cover partial-start teardown
    /// deterministically without requiring microphone hardware or TCC.
    private let testMicStartupError: Error?
    /// Test seam: when set, tier-2 fallback throws at the AVAudioEngine
    /// bootstrap point without touching microphone hardware.
    private let testTier2MicStartupError: Error?

    // MARK: - MicHealth supervisor

    /// Mic-health state machine output. Read by callers (RecorderState) every
    /// ~1 s while a recording is in flight. Updated by the supervisor task
    /// based on the active mic source's buffer flow.
    private var _micHealth: MicHealth = .idle
    public var micHealth: MicHealth { _micHealth }

    /// Internal diagnostic surface used by tests to prove partial-start failure
    /// cleanup. Not part of the public API.
    internal var hasAllocatedCaptureResourcesForTesting: Bool {
        liveDelivery != nil ||
            echoCancellationProcessor != nil ||
            audioEngine != nil ||
            segmentWriter != nil ||
            micTask != nil ||
            systemTask != nil ||
            scKitBox != nil ||
            screenRecorder != nil ||
            tapBoxAny != nil ||
            deviceAudioCapture != nil
    }

    private var micHealthSupervisorTask: Task<Void, Never>?
    /// True once we've ever seen mic buffers in this session. Lets us
    /// distinguish "startup hasn't delivered yet" (warmingUp) from
    /// "delivery stopped mid-session" (degraded → dead).
    private var micEverDelivered: Bool = false
    /// Cached snapshot count + wall-clock timestamp of the last increase.
    /// Used by the supervisor to decide stall windows.
    private var micLastCount: Int = 0
    private var micLastCountChangedAt: Date = .distantPast
    /// Last user-requested mute state. Source-specific mute flags can vanish
    /// during tier-2 demotion, so the request itself must survive source swaps.
    private var requestedMicMuted: Bool = false
    /// Cold-start grace window. SCStream mic typically delivers its first
    /// buffer in 500–1500 ms; AVAudioEngine on built-in mic in ~200 ms;
    /// AVAudioEngine on Bluetooth HFP/SCO can take 4–8 s. 5 s covers the
    /// common cases; the start() entry path enforces a hard 8 s deadline.
    private let micWarmupSeconds: TimeInterval = 5
    /// True after tier-2 fallback has been attempted in this session. Stops
    /// the supervisor from looping into multiple AudioEngine boots — one shot
    /// is the contract.
    private var tier2Attempted: Bool = false
    /// True when the one allowed tier-2 AVAudioEngine bootstrap failed.
    /// Prevents the supervisor from re-entering warmingUp forever after
    /// SCStream has already been torn down.
    private var tier2MicBootstrapFailed: Bool = false
    /// Public observable flag: true once we've demoted screen-record to keep
    /// mic alive. RecorderState reads this to surface a degraded-mode banner.
    public private(set) var tier2DemotedScreenRecording: Bool = false

    // MARK: - Init

    public init(config: Config, liveSink: (any LivePCMSink)? = nil) {
        self.config = config
        self.liveSink = liveSink
        self.testMicStream = nil
        self.testSystemStream = nil
        self.testMicStartupError = nil
        self.testTier2MicStartupError = nil
    }

    /// Internal test init that accepts a mock mic stream.
    internal init(config: Config, liveSink: (any LivePCMSink)?, testMicStream: AsyncStream<AVAudioPCMBuffer>) {
        self.config = config
        self.liveSink = liveSink
        self.testMicStream = testMicStream
        self.testSystemStream = nil
        self.testMicStartupError = nil
        self.testTier2MicStartupError = nil
    }

    /// Internal test init that accepts mock mic and system streams.
    internal init(
        config: Config,
        liveSink: (any LivePCMSink)?,
        testMicStream: AsyncStream<AVAudioPCMBuffer>,
        testSystemStream: AsyncStream<AVAudioPCMBuffer>
    ) {
        self.config = config
        self.liveSink = liveSink
        self.testMicStream = testMicStream
        self.testSystemStream = testSystemStream
        self.testMicStartupError = nil
        self.testTier2MicStartupError = nil
    }

    /// Internal test init that accepts a mock mic stream and injects a tier-2
    /// fallback bootstrap failure.
    internal init(
        config: Config,
        liveSink: (any LivePCMSink)?,
        testMicStream: AsyncStream<AVAudioPCMBuffer>,
        testTier2MicStartupError: Error
    ) {
        self.config = config
        self.liveSink = liveSink
        self.testMicStream = testMicStream
        self.testSystemStream = nil
        self.testMicStartupError = nil
        self.testTier2MicStartupError = testTier2MicStartupError
    }

    /// Internal test init that fails at mic bootstrap after early start()
    /// resources have been allocated.
    internal init(config: Config, liveSink: (any LivePCMSink)?, testMicStartupError: Error) {
        self.config = config
        self.liveSink = liveSink
        self.testMicStream = nil
        self.testSystemStream = nil
        self.testMicStartupError = testMicStartupError
        self.testTier2MicStartupError = nil
    }

    // MARK: - Public API

    public func start() async throws {
        guard recordingState == .idle else { return }

        tier2Attempted = false
        tier2MicBootstrapFailed = false
        tier2DemotedScreenRecording = false
        requestedMicMuted = false
        systemAudioError = nil
        activeMicSource = .none
        micWriterAppendCount = 0
        micWriterTotalFrames = 0
        _micLevel = 0
        scStreamMicTaskRunning = false
        scStreamSystemTaskRunning = false
        echoCancellationProcessor = nil

        // Set up serial delivery for live sink if configured
        if let sink = liveSink {
            liveDelivery = LiveSinkDelivery(sink: sink)
        }
        if config.echoCancellationEnabled, config.micEnabled {
            echoCancellationProcessor = EchoCancellationProcessor()
        }

        let writer = try SegmentWriter(
            sessionDir: config.sessionDir,
            segmentDurationSeconds: config.segmentDurationSeconds,
            sampleRate: Double(config.audioSampleRate),
            audioFormatID: Self.formatIDForCodec(config: config),
            audioBitrate: config.audioBitrate
        )
        self.segmentWriter = writer

        do {
            // -------------------------------------------------------------------
            // Order: screen → system audio → settle → mic.
            //
            // Previously the mic engine started FIRST and screen + system audio
            // started afterwards. Both screen (SCStream) and system audio
            // (SCKit/Tap/Device) touch the audio HAL, which fires
            // `AVAudioEngineConfigurationChange` on the mic's AVAudioEngine and
            // makes `engine.start()` return -10868 (FormatNotSupported) for the
            // rest of the configuration cascade. The recovery handler usually
            // wins on second/third tries but sometimes the engine never gets
            // healthy buffers again — the user-reported "audio dies right at the
            // start while screen.mp4 keeps growing for 36 minutes" failure mode.
            //
            // Starting screen + system audio FIRST and letting the HAL settle
            // (~300 ms) before bootstrapping the mic engine eliminates the race:
            // the mic engine binds to a stable AUHAL with no in-flight config
            // changes. The buffer-flow supervisor inside AudioEngine handles
            // anything that goes wrong after this point (BT (un)pair, sample-rate
            // flip, device hot-plug) as a separate concern.
            // -------------------------------------------------------------------

            // === SCREEN RECORDING first ===
            //
            // When screen + mic are both requested AND we're on macOS 15+, we ask
            // SCStream to ALSO capture the microphone. This makes SCStream the
            // single client of the audio HAL, eliminating the AVAudioEngine HAL
            // race (-10868 cascade) that caused mid-session mic loss for 33-minute
            // sessions. The AVAudioEngine path remains the fallback for macOS 14
            // and for audio-only sessions.
            var screenMicStream: AsyncStream<AVAudioPCMBuffer>? = nil
            var screenSystemAudioStream: AsyncStream<AVAudioPCMBuffer>? = nil
            let isMacOS15OrNewer: Bool
            if #available(macOS 15.0, *) {
                isMacOS15OrNewer = true
            } else {
                isMacOS15OrNewer = false
            }
            let scStreamMicEligible = MicPathPlan.shouldUseSCStreamMic(
                screenRecordingEnabled: config.screenRecordingEnabled,
                micEnabled: config.micEnabled,
                echoCancellationEnabled: config.echoCancellationEnabled,
                isMacOS15OrNewer: isMacOS15OrNewer
            )
            if config.screenRecordingEnabled, config.micEnabled, config.echoCancellationEnabled, isMacOS15OrNewer {
                captureSessionLog.info("CaptureSession.start: DSP echo cancellation enabled — preserving SCStream mic route when available.")
            }
            if config.screenRecordingEnabled, let outputURL = config.screenOutputURL {
                if #available(macOS 12.3, *) {
                    let recorder = ScreenRecorder()
                    let srConfig = ScreenRecorder.Config(
                        outputURL: outputURL,
                        displayID: config.screenCaptureDisplayID,
                        captureSystemAudio: true,
                        captureMicrophone: scStreamMicEligible,
                        microphoneDeviceUID: nil,
                        useHEVC: config.videoUseHEVC,
                        videoBitrate: config.videoBitrate,
                        audioBitrate: config.audioBitrate,
                        audioSampleRate: config.audioSampleRate
                    )
                    do {
                        let startResult = try await recorder.startWithAudioStreams(config: srConfig)
                        self.screenRecorder = recorder
                        screenMicStream = startResult.microphone
                        screenSystemAudioStream = startResult.systemAudio
                        if startResult.microphone != nil {
                            captureSessionLog.info("CaptureSession.start: SCStream mic path active — skipping AVAudioEngine to avoid HAL contention.")
                        }
                    } catch {
                        // Screen recording is non-fatal: audio capture continues unaffected.
                        // Common cause on macOS 15+/26: TCC identity changed after (re)signing.
                        // The caller can inspect screenRecordingError and guide the user to
                        // reset with `tccutil reset ScreenCapture dev.kosmonotes.studio`.
                        captureSessionLog.error("CaptureSession.start: ScreenRecorder failed (non-fatal, audio-only) — \(error.localizedDescription, privacy: .public)")
                        self.screenRecordingError = error
                    }
                }
            }

            // === SYSTEM AUDIO second ===
            //
            // / invariant I3: when ScreenRecorder is active we
            // must NOT stand up a second client of the system-audio HAL. SCStream
            // (inside ScreenRecorder) already captures system audio with
            // `streamConfig.capturesAudio = true` and routes it into screen.mp4.
            // Running the SCKit whole-system mixdown branch alongside that gives
            // us two clients reading the same HAL — exactly the multi-client
            // problem the design forbids.
            //
            // When no explicit custom device/process tap/test stream has taken
            // ownership, we reuse ScreenRecorder's already-running SCStream
            // `.audio` callback as the `.system` source. That gives the writer,
            // transcript pipeline, and DSP AEC a far-end reference without a
            // second HAL client. Custom Device (BlackHole) and per-process Core
            // Audio Tap remain higher-priority explicit routes.
            let screenOwnsSystemAudio = (self.screenRecorder != nil)
            if config.systemAudioEnabled {
                var systemStarted = false

                if let testSystemStream {
                    systemTask = makeTestSystemTask(
                        stream: testSystemStream,
                        writer: writer,
                        delivery: liveDelivery,
                        echoProcessor: echoCancellationProcessor
                    )
                    systemStarted = true
                }

                if !systemStarted, let deviceUID = config.systemAudioDeviceUID, !deviceUID.isEmpty {
                    do {
                        let capture = DeviceAudioCapture(config: .init(deviceUID: deviceUID))
                        self.deviceAudioCapture = capture
                        systemTask = try await makeDeviceCaptureTask(
                            capture: capture,
                            writer: writer,
                            delivery: liveDelivery,
                            echoProcessor: echoCancellationProcessor
                        )
                        systemStarted = true
                        captureSessionLog.info("CaptureSession.start: system audio via custom device UID=\(deviceUID, privacy: .public)")
                    } catch {
                        captureSessionLog.error("CaptureSession.start: device capture failed (\(error.localizedDescription, privacy: .public)) — falling back to SCKit")
                        self.deviceAudioCapture = nil
                        // Flag stale-UID case so the caller can clear the setting
                        // and skip this branch on the next recording.
                        if let dcErr = error as? DeviceAudioCapture.DeviceCaptureError,
                           case .deviceNotFound = dcErr {
                            self.deviceCaptureFellBack = true
                        }
                    }
                }

                if !systemStarted, config.useProcessTap, #available(macOS 14.4, *) {
                    do {
                        let box = TapBox()
                        self.tapBoxAny = box
                        systemTask = try await makeTapTask(
                            box: box,
                            bundleIDs: config.processTapBundleIDs,
                            writer: writer,
                            delivery: liveDelivery,
                            echoProcessor: echoCancellationProcessor
                        )
                        systemStarted = true
                    } catch {
                        self.tapBoxAny = nil
                    }
                }
                if !systemStarted, let screenSystemAudioStream {
                    systemTask = makeScreenRecorderSystemTask(stream: screenSystemAudioStream)
                    scStreamSystemTaskRunning = true
                    systemStarted = true
                    captureSessionLog.info("CaptureSession.start: system audio via ScreenRecorder SCStream reference (single-HAL path).")
                }
                // SCKit fallback runs ONLY when ScreenRecorder isn't already
                // capturing system audio via SCStream. See header comment.
                if !systemStarted, !screenOwnsSystemAudio, #available(macOS 12.3, *) {
                    let box = SCKitBox()
                    self.scKitBox = box
                    systemTask = try await makeSystemTask(
                        box: box,
                        writer: writer,
                        delivery: liveDelivery,
                        echoProcessor: echoCancellationProcessor
                    )
                } else if !systemStarted, screenOwnsSystemAudio {
                    captureSessionLog.info("CaptureSession.start: skipped SCKit system-audio fallback because ScreenRecorder already owns the system-audio HAL but no PCM reference stream was available.")
                }
            }

            // === HAL settle window ===
            // Only wait if we actually started something on the audio HAL. The
            // 300 ms figure was measured on M1/M2/M3 hardware: SCStream's audio
            // sub-component binds in 150–250 ms post-startCapture; we add headroom.
            // Skipped entirely for mic-only recordings (no race to avoid).
            let halTouched = (self.screenRecorder != nil)
                || (self.deviceAudioCapture != nil)
                || (self.scKitBox != nil)
                || (self.tapBoxAny != nil)
            if config.micEnabled && halTouched {
                try? await Task.sleep(nanoseconds: 300_000_000)
            }

            // === MIC last (bootstraps on a stable HAL) ===
            if config.micEnabled {
                // Use test stream if provided (test seam), otherwise pick path:
                //   1. SCStream mic (macOS 15+, screen+mic mode)
                //   2. AVAudioEngine (everything else)
                if let testStream = testMicStream {
                    micTask = makeTestMicTask(stream: testStream)
                    activeMicSource = .scStream
                    scStreamMicTaskRunning = true
                } else if let screenMicStream {
                    // SCStream mic active — write directly into SegmentWriter as
                    // the .mic source. No AVAudioEngine created, so no HAL race.
                    micTask = makeScreenRecorderMicTask(stream: screenMicStream)
                    activeMicSource = .scStream
                    scStreamMicTaskRunning = true
                } else {
                    if let testMicStartupError {
                        throw testMicStartupError
                    }
                    let engine = AudioEngine(config: Self.micAudioEngineConfig(for: config))
                    self.audioEngine = engine
                    micTask = try await makeMicTask(engine: engine)
                    activeMicSource = .audioEngine
                }
            }

            recordingState = .recording
            startMicHealthSupervisor()
        } catch {
            _ = try? await teardownCaptureResources()
            recordingState = .idle
            throw error
        }
    }

    // MARK: - MicHealth supervisor

    /// Spin up the supervisor task. Polls the active mic source's flow
    /// snapshot every 1 s; transitions `_micHealth` through warmingUp → ok →
    /// degraded → dead based on stall windows and recovery state. Idempotent.
    private func startMicHealthSupervisor() {
        micHealthSupervisorTask?.cancel()
        let sessionStartedAt = Date()
        _micHealth = config.micEnabled ? .warmingUp : .idle
        micEverDelivered = false
        micLastCount = 0
        micLastCountChangedAt = sessionStartedAt
        guard config.micEnabled else { return }
        micHealthSupervisorTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 1_000_000_000)
                if Task.isCancelled { break }
                await self?.micHealthSupervisorTick(sessionStartedAt: sessionStartedAt)
            }
        }
        captureSessionLog.info("CaptureSession: micHealth supervisor started")
    }

    private func micHealthSupervisorTick(sessionStartedAt: Date) async {
        let muted = await isMicMuted
        if muted {
            _micHealth = .muted
            micLastCount = await currentMicCount()
            micLastCountChangedAt = Date()
            return
        }

        let now = Date()
        let count = await currentMicCount()
        if count > micLastCount {
            micLastCount = count
            micLastCountChangedAt = now
            if !micEverDelivered { micEverDelivered = true }
        }

        let sinceLastBuffer = now.timeIntervalSince(micLastCountChangedAt)
        let sinceStart = now.timeIntervalSince(sessionStartedAt)

        if !micEverDelivered, sinceStart < micWarmupSeconds {
            _micHealth = .warmingUp
            return
        }

        var recoveryGaveUp = false
        if let recorder = screenRecorder, #available(macOS 12.3, *) {
            recoveryGaveUp = await recorder.micRecoveryGaveUp
            if let stopError = await recorder.streamStopError {
                self.screenRecordingError = stopError
                recoveryGaveUp = true
            }
        }

        // Tier-2 fallback gate. When SCStream mic recovery has exhausted its
        // 3 restart attempts AND we haven't already demoted, switch the mic
        // source to AVAudioEngine. The screen-record dies; the recording
        // continues audio-only. Invariant I2 keeps the user's voice over
        // their screen capture.
        if recoveryGaveUp, !tier2Attempted, screenRecorder != nil {
            await attemptTier2Fallback(stallSeconds: sinceLastBuffer)
            if tier2MicBootstrapFailed {
                let snapshot = MicHealthSnapshot(
                    isMuted: false,
                    everDelivered: micEverDelivered,
                    sinceLastBuffer: sinceLastBuffer,
                    sinceStart: sinceStart,
                    warmupSeconds: micWarmupSeconds,
                    scStreamRecoveryGaveUp: true,
                    tier2Attempted: true
                )
                _micHealth = MicHealthClassifier.classify(snapshot)
            } else {
                micLastCount = await currentMicCount()
                micLastCountChangedAt = Date()
                micEverDelivered = false
                _micHealth = .warmingUp
            }
            return
        }

        let snapshot = MicHealthSnapshot(
            isMuted: false,
            everDelivered: micEverDelivered,
            sinceLastBuffer: sinceLastBuffer,
            sinceStart: sinceStart,
            warmupSeconds: micWarmupSeconds,
            scStreamRecoveryGaveUp: recoveryGaveUp || tier2MicBootstrapFailed,
            tier2Attempted: tier2Attempted
        )
        _micHealth = MicHealthClassifier.classify(snapshot)
    }

    /// Tier-2 fallback: SCStream mic gave up after 3 restart attempts. Stop the
    /// screen recorder (finalizes screen.mp4 at whatever we captured), then
    /// bootstrap an AVAudioEngine on the default input and route its PCM into
    /// the existing SegmentWriter. The recording continues mic-only.
    ///
    /// Invariant: this method may only be called once per session. The
    /// `tier2Attempted` guard upstream enforces that — even on AudioEngine
    /// boot failure, we don't loop into a second attempt.
    private func attemptTier2Fallback(stallSeconds: TimeInterval) async {
        tier2Attempted = true
        tier2MicBootstrapFailed = false
        let fallbackMicMuted = await tier2FallbackMuteState()
        captureSessionLog.error("CaptureSession.tier2: SCStream mic recovery exhausted (\(Int(stallSeconds), privacy: .public)s stall). Demoting to audio-only mode — stopping ScreenRecorder, starting AVAudioEngine.")

        // 1. Cancel the SCStream mic feed task so it doesn't fight the
        // about-to-spawn AVAudioEngine feed for the writer's mic source.
        micTask?.cancel()
        micTask = nil

        // 2. Finalize the screen recorder. Partial screen.mp4 stays on disk
        // and remains playable — we don't try to delete it.
        if #available(macOS 12.3, *), let recorder = screenRecorder {
            do {
                _ = try await recorder.stop()
                captureSessionLog.info("CaptureSession.tier2: screen.mp4 finalized at the failure point")
            } catch {
                captureSessionLog.error("CaptureSession.tier2: screenRecorder.stop threw — \(error.localizedDescription, privacy: .public)")
            }
        }
        screenRecorder = nil
        tier2DemotedScreenRecording = true

        // 3. Bootstrap AVAudioEngine and rewire SegmentWriter's mic source.
        guard let writer = segmentWriter else {
            captureSessionLog.error("CaptureSession.tier2: SegmentWriter gone — cannot rewire mic. The supervisor will mark .dead next tick.")
            return
        }
        let engine = AudioEngine(config: Self.micAudioEngineConfig(for: config))
        do {
            if let testTier2MicStartupError {
                throw testTier2MicStartupError
            }
            await engine.setMuted(fallbackMicMuted)
            let newMicTask = try await makeMicTask(engine: engine)
            self.audioEngine = engine
            self.micTask = newMicTask
            self.activeMicSource = .audioEngine
            self.scStreamMicTaskRunning = false
            captureSessionLog.info("CaptureSession.tier2: AVAudioEngine bootstrapped successfully — mic capture resumed for the rest of the session")
        } catch {
            tier2MicBootstrapFailed = true
            self.audioEngine = nil
            self.activeMicSource = .none
            self.scStreamMicTaskRunning = false
            captureSessionLog.error("CaptureSession.tier2: AVAudioEngine bootstrap failed — \(error.localizedDescription, privacy: .public). Recording continues but mic is dead; supervisor will escalate to fail-safe stop within 30 s.")
        }

        await startTier2SystemAudioFallbackIfNeeded(writer: writer)
    }

    private func tier2FallbackMuteState() async -> Bool {
        if requestedMicMuted { return true }
        if let engine = audioEngine {
            return await engine.isMuted
        }
        if let recorder = screenRecorder, #available(macOS 12.3, *) {
            return await recorder.isMicMuted
        }
        return false
    }

    private func startTier2SystemAudioFallbackIfNeeded(writer: SegmentWriter) async {
        let hasProcessTap = tapBoxAny != nil
        guard Tier2SystemAudioFallbackPlan.shouldStartSCKit(
            systemAudioEnabled: config.systemAudioEnabled,
            hasSystemTask: systemTask != nil,
            hasDeviceAudioCapture: deviceAudioCapture != nil,
            hasProcessTap: hasProcessTap,
            hasSCKitCapture: scKitBox != nil
        ) else {
            return
        }

        if #available(macOS 12.3, *) {
            let box = SCKitBox()
            scKitBox = box
            do {
                systemTask = try await makeSystemTask(
                    box: box,
                    writer: writer,
                    delivery: liveDelivery,
                    echoProcessor: echoCancellationProcessor
                )
                captureSessionLog.info("CaptureSession.tier2: SCKit system-audio fallback started after ScreenRecorder demotion")
            } catch {
                scKitBox = nil
                captureSessionLog.error("CaptureSession.tier2: SCKit system-audio fallback failed — \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    /// Writer-side mic delivery count — the supervisor's source of truth.
    ///
    /// We deliberately return our own append-success counter rather than the
    /// active source's "buffers produced" counter. Design invariant I5: the
    /// user's voice has only reached the recording when it has been appended
    /// to the segment writer. SCStream's
    /// `bufferingNewest(100)` can drop buffers during downstream stalls, and
    /// `writer.append` can throw repeatedly — neither failure mode shows up
    /// if we read from `ScreenRecorder.micFlowSnapshot`.
    private func currentMicCount() async -> Int {
        micWriterAppendCount
    }

    /// Actor-routed mic enqueue. Single sink for every mic source (AudioEngine,
    /// SCStream microphone, test stream). Centralising here gives us:
    ///   - writer-side health accounting: the supervisor's counter only
    ///     ticks on append success;
    ///   - pause/resume continuity: SCStream's mic feed task can stay
    ///     alive across pause/resume, quietly dropping buffers when
    ///     `micWriter` is nil between segments;
    ///   - cheap UI level for the SCStream path: we recompute RMS in a
    ///     single place instead of standing up a second AVAudioEngine
    ///     tap just to drive the popover meter.
    func enqueueMicBuffer(_ buffer: AVAudioPCMBuffer, hostTime: UInt64) async {
        let micBuffer: AVAudioPCMBuffer
        if let echoCancellationProcessor {
            do {
                micBuffer = try await echoCancellationProcessor.processMicrophoneBuffer(buffer, hostTime: hostTime).buffer
            } catch {
                captureSessionLog.error("CaptureSession.mic: DSP echo cancellation failed — using raw mic buffer. \(error.localizedDescription, privacy: .public)")
                micBuffer = buffer
            }
        } else {
            micBuffer = buffer
        }

        updateMicLevelEMA(micBuffer)
        guard let writer = segmentWriter else {
            // pause() cleared the writer. Drop the buffer; SCStream may keep
            // yielding while we're paused and that's fine — buffers between
            // pause and resume are intentionally lost.
            if let delivery = liveDelivery {
                await delivery.enqueue(micBuffer, hostTime: hostTime, source: .mic)
            }
            return
        }
        do {
            try await writer.append(micBuffer, source: .mic)
            micWriterAppendCount &+= 1
            micWriterTotalFrames &+= Int(micBuffer.frameLength)
            if micWriterAppendCount == 1 || micWriterAppendCount % 200 == 0 {
                captureSessionLog.info("CaptureSession.mic: writer append #\(self.micWriterAppendCount, privacy: .public) totalFrames=\(self.micWriterTotalFrames, privacy: .public)")
            }
        } catch {
            captureSessionLog.error("CaptureSession.mic: writer.append threw — \(error.localizedDescription, privacy: .public). Health counter will not advance; supervisor will mark degraded.")
        }
        if let delivery = liveDelivery {
            await delivery.enqueue(micBuffer, hostTime: hostTime, source: .mic)
        }
    }

    /// Actor-routed system-audio enqueue for the ScreenRecorder SCStream path.
    ///
    /// Unlike SCKit/device/tap tasks, this stream cannot be restarted on resume:
    /// AsyncStream has a single iterator and ScreenRecorder owns the only
    /// SCStream instance. Keep the task alive across pause; when `segmentWriter`
    /// is nil, disk writes are intentionally skipped while AEC can keep its
    /// latest far-end reference warm for the next mic buffer.
    func enqueueScreenRecorderSystemBuffer(_ buffer: AVAudioPCMBuffer, hostTime: UInt64) async {
        if let writer = segmentWriter {
            do {
                try await writer.append(buffer, source: .system)
            } catch {
                captureSessionLog.error("CaptureSession.system(SCStream): writer.append threw — \(error.localizedDescription, privacy: .public)")
            }
        }
        if let echoCancellationProcessor {
            do {
                try await echoCancellationProcessor.receiveSystemBuffer(buffer, hostTime: hostTime)
            } catch {
                captureSessionLog.error("CaptureSession.system(SCStream): echo reference ingest failed — \(error.localizedDescription, privacy: .public)")
            }
        }
        if let delivery = liveDelivery {
            await delivery.enqueue(buffer, hostTime: hostTime, source: .system)
        }
    }

    /// Cheap EMA-smoothed RMS so RecorderState can drive the popover meter
    /// from the SCStream mic stream without standing up a parallel
    /// AVAudioEngine tap. Mirrors the empirical 4× scale used by
    /// `MicLevelMeter` so the visual gauge looks the same.
    private func updateMicLevelEMA(_ buffer: AVAudioPCMBuffer) {
        guard let data = buffer.floatChannelData?[0] else { return }
        let frames = Int(buffer.frameLength)
        guard frames > 0 else { return }
        var sumSquares: Float = 0
        for i in 0..<frames {
            let sample = data[i]
            sumSquares += sample * sample
        }
        let rms = sqrt(sumSquares / Float(frames))
        let raw = min(1.0, max(0.0, Double(rms) * 4.0))
        // 0.4 alpha keeps the meter responsive (~3-buffer 90% time constant
        // at ~50 buffers/s) without flickering on every fricative.
        _micLevel = _micLevel * 0.6 + raw * 0.4
    }

    public func pause() async throws {
        guard recordingState == .recording else { return }
        micHealthSupervisorTask?.cancel()
        micHealthSupervisorTask = nil
        _micHealth = .idle
        // in SCStream-mic mode, leave the mic feed task
        // running. AsyncStream only supports one iterator; cancelling here
        // would leave us with no way to drain SCStream's mic buffers on
        // resume. The actor's mic enqueue silently drops buffers while
        // `segmentWriter` is nil, so the stream keeps draining but writes
        // are paused — exactly what we want.
        if activeMicSource != .scStream {
            micTask?.cancel()
            micTask = nil
            await audioEngine?.stop()
        }
        if !scStreamSystemTaskRunning {
            systemTask?.cancel()
            systemTask = nil
        }
        await deviceAudioCapture?.stop()
        if #available(macOS 12.3, *) {
            await scKitBox?.capture.stop()
        }
        if #available(macOS 14.4, *), let box = tapBoxAny as? TapBox {
            await box.tap.stop()
        }
        await echoCancellationProcessor?.reset()
        _ = try await segmentWriter?.close()
        segmentWriter = nil

        // Finish pending deliveries during pause
        if let delivery = liveDelivery {
            await delivery.finish()
            liveDelivery = nil
        }

        recordingState = .paused
    }

    public func resume() async throws {
        guard recordingState == .paused else { return }

        // Restart serial delivery if sink is configured
        if let sink = liveSink {
            liveDelivery = LiveSinkDelivery(sink: sink)
        }

        let writer = try SegmentWriter(
            sessionDir: config.sessionDir,
            segmentDurationSeconds: config.segmentDurationSeconds,
            sampleRate: Double(config.audioSampleRate),
            audioFormatID: Self.formatIDForCodec(config: config),
            audioBitrate: config.audioBitrate
        )
        // Setting segmentWriter re-arms the actor's mic enqueue path. For
        // SCStream-mic mode the feed task was never cancelled, so the next
        // SCStream mic buffer that arrives will be appended into this fresh
        // writer with no further wiring.
        self.segmentWriter = writer

        switch activeMicSource {
        case .audioEngine:
            if let engine = audioEngine {
                micTask = try await makeMicTask(engine: engine)
            }
        case .scStream:
            // The pre-pause feed task is still draining SCStream's mic
            // AsyncStream and will dispatch into `enqueueMicBuffer` against
            // the new writer above. If it somehow died (testStream ended,
            // ScreenRecorder.stop happened concurrently with pause), we can't
            // recreate an iterator for a closed AsyncStream — log so the
            // supervisor's degraded path can surface the loss to the user.
            if !scStreamMicTaskRunning {
                captureSessionLog.error("CaptureSession.resume: SCStream mic feed task is no longer running — resume cannot rewire the mic path. Supervisor will mark .dead within 30 s.")
            }
        case .none:
            break
        }

        if config.systemAudioEnabled {
            // Restart whichever system-audio path was originally chosen.
            if scStreamSystemTaskRunning {
                // The ScreenRecorder system stream task stayed alive across
                // pause and will append into the fresh writer above on the
                // next buffer.
            } else if let capture = deviceAudioCapture {
                systemTask = try await makeDeviceCaptureTask(
                    capture: capture,
                    writer: writer,
                    delivery: liveDelivery,
                    echoProcessor: echoCancellationProcessor
                )
            } else if #available(macOS 14.4, *), let box = tapBoxAny as? TapBox {
                systemTask = try await makeTapTask(
                    box: box,
                    bundleIDs: config.processTapBundleIDs,
                    writer: writer,
                    delivery: liveDelivery,
                    echoProcessor: echoCancellationProcessor
                )
            } else if let box = scKitBox, #available(macOS 12.3, *) {
                systemTask = try await makeSystemTask(
                    box: box,
                    writer: writer,
                    delivery: liveDelivery,
                    echoProcessor: echoCancellationProcessor
                )
            }
        }

        recordingState = .recording
        startMicHealthSupervisor()
    }

    /// Live-mute the mic without tearing down capture. Forwards to the active
    /// mic source — either AudioEngine (default) or ScreenRecorder (SCStream
    /// mic path on macOS 15+). No-op when the session has no mic track.
    public func setMicMuted(_ muted: Bool) async {
        requestedMicMuted = muted
        if let engine = audioEngine {
            await engine.setMuted(muted)
        } else if let recorder = screenRecorder, #available(macOS 12.3, *) {
            await recorder.setMicMuted(muted)
        }
    }

    /// Current mic mute state. False when capture isn't running yet.
    public var isMicMuted: Bool {
        get async {
            if let engine = audioEngine {
                return await engine.isMuted
            }
            if let recorder = screenRecorder, #available(macOS 12.3, *) {
                return await recorder.isMicMuted
            }
            return recordingState == .recording ? requestedMicMuted : false
        }
    }

    @available(macOS 12.3, *)
    func recordSystemAudioStopError(_ failure: SCStreamStopFailure) {
        systemAudioError = failure
        captureSessionLog.error("CaptureSession.system(SCKit): stream stopped externally — \(failure.message, privacy: .public)")
    }

    @available(macOS 12.3, *)
    internal func recordSystemAudioStopErrorForTesting(_ failure: SCStreamStopFailure) {
        recordSystemAudioStopError(failure)
    }

    internal var requestedMicMutedForTesting: Bool {
        requestedMicMuted
    }

    internal var tier2MicBootstrapFailedForTesting: Bool {
        tier2MicBootstrapFailed
    }

    internal func forceTier2FallbackForTesting(stallSeconds: TimeInterval) async {
        await attemptTier2Fallback(stallSeconds: stallSeconds)
        if tier2MicBootstrapFailed {
            let snapshot = MicHealthSnapshot(
                isMuted: false,
                everDelivered: micEverDelivered,
                sinceLastBuffer: stallSeconds,
                sinceStart: micWarmupSeconds + stallSeconds,
                warmupSeconds: micWarmupSeconds,
                scStreamRecoveryGaveUp: true,
                tier2Attempted: true
            )
            _micHealth = MicHealthClassifier.classify(snapshot)
        }
    }

    @discardableResult
    private func teardownCaptureResources() async throws -> [URL] {
        micHealthSupervisorTask?.cancel()
        micHealthSupervisorTask = nil
        _micHealth = .idle

        await audioEngine?.stop()
        if #available(macOS 12.3, *) {
            await scKitBox?.capture.stop()
        }
        if #available(macOS 14.4, *), let box = tapBoxAny as? TapBox {
            await box.tap.stop()
        }
        await deviceAudioCapture?.stop()

        // Unlike pause(), teardown always cancels every feed task — including
        // the SCStream mic/system feeds that pause() deliberately leaves
        // running.
        cancelFeedTasks()

        if #available(macOS 12.3, *) {
            do {
                _ = try await screenRecorder?.stop()
            } catch {
                captureSessionLog.error("CaptureSession.teardown: screenRecorder.stop threw — \(error.localizedDescription, privacy: .public)")
            }
        }

        if let delivery = liveDelivery {
            await delivery.finish()
        }

        defer {
            audioEngine = nil
            scKitBox = nil
            tapBoxAny = nil
            deviceAudioCapture = nil
            echoCancellationProcessor = nil
            screenRecorder = nil
            segmentWriter = nil
            liveDelivery = nil
            scStreamMicTaskRunning = false
            scStreamSystemTaskRunning = false
            activeMicSource = .none
            _micLevel = 0
        }

        return try await segmentWriter?.close() ?? []
    }

    @discardableResult
    public func stop() async throws -> [URL] {
        guard recordingState == .recording || recordingState == .paused else { return [] }

        let paths = try await teardownCaptureResources()
        recordingState = .stopped
        return paths
    }

    // MARK: - Private

    private func cancelFeedTasks() {
        micTask?.cancel()
        systemTask?.cancel()
        micTask = nil
        systemTask = nil
    }

    /// Build a Task that drains a test mic stream into the writer via the
    /// actor's single mic enqueue. Used by test seam only — does not create
    /// or manage an AudioEngine.
    private nonisolated func makeTestMicTask(
        stream: AsyncStream<AVAudioPCMBuffer>
    ) -> Task<Void, Never> {
        let box = UncheckedSendableBox(stream)
        return Task.detached { [weak self] in
            var bufferIndex = 0
            var frameCursor: UInt64 = 0
            for await buffer in box.value {
                bufferIndex += 1
                let hostTime = frameCursor
                frameCursor &+= UInt64(buffer.frameLength)
                await self?.enqueueMicBuffer(buffer, hostTime: hostTime)
            }
            captureSessionLog.info("CaptureSession.testMic: stream ended after \(bufferIndex, privacy: .public) buffers")
            await self?.markScStreamMicTaskFinished()
        }
    }

    /// Drain ScreenRecorder.start's mic AsyncStream (SCStream-sourced) into
    /// the segment writer via the actor's single mic enqueue. Crucially this
    /// task is NOT cancelled by `pause()` — the actor enqueue drops buffers
    /// while `segmentWriter` is nil, and `resume()` re-attaches the writer.
    /// AsyncStream only supports one iterator, so cancelling on pause would
    /// leave us with no path to resume the SCStream mic feed.
    private nonisolated func makeScreenRecorderMicTask(
        stream: AsyncStream<AVAudioPCMBuffer>
    ) -> Task<Void, Never> {
        let box = UncheckedSendableBox(stream)
        return Task.detached { [weak self] in
            var bufferIndex = 0
            for await buffer in box.value {
                bufferIndex += 1
                let hostTime = mach_absolute_time()
                await self?.enqueueMicBuffer(buffer, hostTime: hostTime)
            }
            captureSessionLog.info("CaptureSession.mic(SCStream): stream ended after \(bufferIndex, privacy: .public) buffers")
            await self?.markScStreamMicTaskFinished()
        }
    }

    /// Build a Task that drains the AudioEngine mic stream into the writer
    /// via the actor's single mic enqueue.
    /// nonisolated so that the call to engine.start() (AudioEngine actor)
    /// and the resulting AsyncStream never cross into CaptureSession's isolation
    /// domain — avoiding the Swift 6 non-Sendable stream crossing error.
    private nonisolated func makeMicTask(
        engine: AudioEngine
    ) async throws -> Task<Void, Never> {
        let stream = try await engine.start()
        // AVAudioPCMBuffer is not Sendable; we assert single-consumer ownership here.
        let box = UncheckedSendableBox(stream)
        return Task.detached { [weak self] in
            var bufferIndex = 0
            for await buffer in box.value {
                bufferIndex += 1
                let hostTime = mach_absolute_time()
                await self?.enqueueMicBuffer(buffer, hostTime: hostTime)
            }
            captureSessionLog.info("CaptureSession.mic: stream ended after \(bufferIndex, privacy: .public) buffers")
        }
    }

    /// Called from the SCStream/test mic feed task once the underlying stream
    /// ends so the actor can clear its "running" bookkeeping flag.
    private func markScStreamMicTaskFinished() {
        scStreamMicTaskRunning = false
    }

    private func markScStreamSystemTaskFinished() {
        scStreamSystemTaskRunning = false
    }

    /// Drain ScreenRecorder.startWithAudioStreams' system-audio stream into the
    /// actor-routed `.system` path. This task mirrors the SCStream mic task: it
    /// stays alive across pause/resume because the underlying AsyncStream cannot
    /// be consumed a second time.
    private nonisolated func makeScreenRecorderSystemTask(
        stream: AsyncStream<AVAudioPCMBuffer>
    ) -> Task<Void, Never> {
        let streamBox = UncheckedSendableBox(stream)
        return Task.detached { [weak self] in
            var bufferIndex = 0
            for await buffer in streamBox.value {
                bufferIndex += 1
                let hostTime = mach_absolute_time()
                await self?.enqueueScreenRecorderSystemBuffer(buffer, hostTime: hostTime)
            }
            captureSessionLog.info("CaptureSession.system(SCStream): stream ended after \(bufferIndex, privacy: .public) buffers")
            await self?.markScStreamSystemTaskFinished()
        }
    }

    private nonisolated func makeTestSystemTask(
        stream: AsyncStream<AVAudioPCMBuffer>,
        writer: SegmentWriter,
        delivery: LiveSinkDelivery?,
        echoProcessor: EchoCancellationProcessor?
    ) -> Task<Void, Never> {
        let streamBox = UncheckedSendableBox(stream)
        return Task.detached {
            var bufferIndex = 0
            var frameCursor: UInt64 = 0
            for await buffer in streamBox.value {
                bufferIndex += 1
                let hostTime = frameCursor
                frameCursor &+= UInt64(buffer.frameLength)
                do {
                    try await writer.append(buffer, source: .system)
                } catch {
                    captureSessionLog.error("CaptureSession.system(test): writer.append threw — \(error.localizedDescription, privacy: .public)")
                }
                if let echoProcessor {
                    do {
                        try await echoProcessor.receiveSystemBuffer(buffer, hostTime: hostTime)
                    } catch {
                        captureSessionLog.error("CaptureSession.system(test): echo reference ingest failed — \(error.localizedDescription, privacy: .public)")
                    }
                }
                if let delivery {
                    await delivery.enqueue(buffer, hostTime: hostTime, source: .system)
                }
            }
            captureSessionLog.info("CaptureSession.system(test): stream ended after \(bufferIndex, privacy: .public) buffers")
        }
    }

    @available(macOS 12.3, *)
    private nonisolated func makeSystemTask(
        box: SCKitBox,
        writer: SegmentWriter,
        delivery: LiveSinkDelivery?,
        echoProcessor: EchoCancellationProcessor?
    ) async throws -> Task<Void, Never> {
        let stream = try await box.capture.start()
        let streamBox = UncheckedSendableBox(stream)
        return Task.detached { [weak self] in
            var bufferIndex = 0
            for await buffer in streamBox.value {
                bufferIndex += 1
                let hostTime = mach_absolute_time()
                do {
                    try await writer.append(buffer, source: .system)
                } catch {
                    captureSessionLog.error("CaptureSession.system(SCKit): writer.append threw — \(error.localizedDescription, privacy: .public)")
                }
                if let echoProcessor {
                    do {
                        try await echoProcessor.receiveSystemBuffer(buffer, hostTime: hostTime)
                    } catch {
                        captureSessionLog.error("CaptureSession.system(SCKit): echo reference ingest failed — \(error.localizedDescription, privacy: .public)")
                    }
                }
                // Forward to live sink via serial delivery (best-effort)
                if let delivery {
                    await delivery.enqueue(buffer, hostTime: hostTime, source: .system)
                }
            }
            if let stopError = await box.capture.streamStopError {
                await self?.recordSystemAudioStopError(stopError)
            }
            captureSessionLog.info("CaptureSession.system(SCKit): stream ended after \(bufferIndex, privacy: .public) buffers")
        }
    }

    /// Drain DeviceAudioCapture's PCM stream into the segment writer as the
    /// system-audio source. nonisolated mirrors the other makeXTask helpers
    /// so the AsyncStream never crosses CaptureSession's actor boundary.
    private nonisolated func makeDeviceCaptureTask(
        capture: DeviceAudioCapture,
        writer: SegmentWriter,
        delivery: LiveSinkDelivery?,
        echoProcessor: EchoCancellationProcessor?
    ) async throws -> Task<Void, Never> {
        let stream = try await capture.start()
        let streamBox = UncheckedSendableBox(stream)
        return Task.detached {
            var bufferIndex = 0
            for await buffer in streamBox.value {
                bufferIndex += 1
                let hostTime = mach_absolute_time()
                do {
                    try await writer.append(buffer, source: .system)
                    if bufferIndex == 1 || bufferIndex % 50 == 0 {
                        captureSessionLog.info("CaptureSession.system(Device): appended buffer #\(bufferIndex, privacy: .public)")
                    }
                } catch {
                    captureSessionLog.error("CaptureSession.system(Device): writer.append threw — \(error.localizedDescription, privacy: .public)")
                }
                if let echoProcessor {
                    do {
                        try await echoProcessor.receiveSystemBuffer(buffer, hostTime: hostTime)
                    } catch {
                        captureSessionLog.error("CaptureSession.system(Device): echo reference ingest failed — \(error.localizedDescription, privacy: .public)")
                    }
                }
                // Forward to live sink via serial delivery (best-effort)
                if let delivery {
                    await delivery.enqueue(buffer, hostTime: hostTime, source: .system)
                }
            }
            captureSessionLog.info("CaptureSession.system(Device): stream ended after \(bufferIndex, privacy: .public) buffers")
        }
    }

    @available(macOS 14.4, *)
    private nonisolated func makeTapTask(
        box: TapBox,
        bundleIDs: [String],
        writer: SegmentWriter,
        delivery: LiveSinkDelivery?,
        echoProcessor: EchoCancellationProcessor?
    ) async throws -> Task<Void, Never> {
        let stream = try await box.tap.start(bundleIDs: bundleIDs)
        let streamBox = UncheckedSendableBox(stream)
        return Task.detached {
            var bufferIndex = 0
            for await buffer in streamBox.value {
                bufferIndex += 1
                let hostTime = mach_absolute_time()
                do {
                    try await writer.append(buffer, source: .system)
                } catch {
                    captureSessionLog.error("CaptureSession.system(Tap): writer.append threw — \(error.localizedDescription, privacy: .public)")
                }
                if let echoProcessor {
                    do {
                        try await echoProcessor.receiveSystemBuffer(buffer, hostTime: hostTime)
                    } catch {
                        captureSessionLog.error("CaptureSession.system(Tap): echo reference ingest failed — \(error.localizedDescription, privacy: .public)")
                    }
                }
                // Forward to live sink via serial delivery (best-effort)
                if let delivery {
                    await delivery.enqueue(buffer, hostTime: hostTime, source: .system)
                }
            }
            captureSessionLog.info("CaptureSession.system(Tap): stream ended after \(bufferIndex, privacy: .public) buffers")
        }
    }
}

// MARK: - Helpers

/// Boxes an arbitrary value as @unchecked Sendable.
/// Used to transfer AsyncStream across concurrency domains when the caller
/// guarantees single-consumer exclusive ownership.
private final class UncheckedSendableBox<T>: @unchecked Sendable {
    let value: T
    init(_ value: T) { self.value = value }
}

/// Boxes SCKitAudioCapture (macOS 12.3+) so it can be stored as plain `Any`.
@available(macOS 12.3, *)
final class SCKitBox: Sendable {
    let capture = SCKitAudioCapture()
}

/// Boxes CoreAudioTap (macOS 14.4+) so the per-process tap can be stored
/// without the @available constraint leaking onto stored properties.
@available(macOS 14.4, *)
final class TapBox: Sendable {
    let tap = CoreAudioTap()
}

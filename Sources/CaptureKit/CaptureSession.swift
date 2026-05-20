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
    func receive(_ buffer: AVAudioPCMBuffer, at hostTime: UInt64) async
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

        func recordEnqueue(result: AsyncStream<(AVAudioPCMBuffer, UInt64)>.Continuation.YieldResult) -> Int? {
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
    private let continuation: AsyncStream<(AVAudioPCMBuffer, UInt64)>.Continuation
    private let metrics: Metrics

    init(sink: any LivePCMSink, maxQueueSize: Int = 32) {
        self.sink = sink
        self.metrics = Metrics(maxQueueSize: maxQueueSize)
        let (stream, continuation) = AsyncStream<(AVAudioPCMBuffer, UInt64)>.makeStream(
            bufferingPolicy: .bufferingNewest(maxQueueSize)
        )
        self.continuation = continuation
        // Wrap stream in UncheckedSendableBox to satisfy Swift 6 strict concurrency
        let streamBox = UncheckedSendableBox(stream)
        let metrics = self.metrics
        self.deliveryTask = Task.detached {
            var delivered = 0
            for await (buffer, hostTime) in streamBox.value {
                await metrics.recordDequeue()
                await sink.receive(buffer, at: hostTime)
                delivered += 1
            }
            captureSessionLog.debug("LiveSinkDelivery: delivered \(delivered, privacy: .public) buffers total")
        }
    }

    /// Enqueue a buffer for serial delivery. Returns immediately without awaiting sink.
    /// If the queue is full, drops the oldest buffer (drop-oldest policy).
    func enqueue(_ buffer: AVAudioPCMBuffer, hostTime: UInt64) async {
        if let droppedCount = await metrics.recordEnqueue(result: continuation.yield((buffer, hostTime))),
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
            channels: 1
        )
    }

    // MARK: - Private state

    private enum RecordingState { case idle, recording, paused, stopped }

    private let config: Config
    private var recordingState: RecordingState = .idle
    private var audioEngine: AudioEngine?
    private var segmentWriter: SegmentWriter?
    private var micTask: Task<Void, Never>?
    private var systemTask: Task<Void, Never>?
    private var scKitBox: SCKitBox?
    private var screenRecorder: ScreenRecorder?
    /// Set when screen recording was requested but failed at start (e.g. TCC denied).
    /// Callers may surface a non-blocking warning to the user.
    public private(set) var screenRecordingError: Error?
    /// Stored as `AnyObject?` because `TapBox` is `@available(macOS 14.4, *)` —
    /// stricter than the package's macOS 14.0 deployment target. Cast at the
    /// use site under `#available(macOS 14.4, *)`.
    private var tapBoxAny: AnyObject?
    /// Capture for the user-selected loopback device (BlackHole etc).
    /// Mutually exclusive with `scKitBox` / `tapBoxAny` — when set, system
    /// audio comes from this device instead of SCKit's whole-system mixdown.
    private var deviceAudioCapture: DeviceAudioCapture?
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

    // MARK: - Init

    public init(config: Config, liveSink: (any LivePCMSink)? = nil) {
        self.config = config
        self.liveSink = liveSink
        self.testMicStream = nil
    }

    /// Internal test init that accepts a mock mic stream.
    internal init(config: Config, liveSink: (any LivePCMSink)?, testMicStream: AsyncStream<AVAudioPCMBuffer>) {
        self.config = config
        self.liveSink = liveSink
        self.testMicStream = testMicStream
    }

    // MARK: - Public API

    public func start() async throws {
        guard recordingState == .idle else { return }

        // Set up serial delivery for live sink if configured
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
        self.segmentWriter = writer

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
        if config.screenRecordingEnabled, let outputURL = config.screenOutputURL {
            if #available(macOS 12.3, *) {
                let recorder = ScreenRecorder()
                let srConfig = ScreenRecorder.Config(
                    outputURL: outputURL,
                    displayID: config.screenCaptureDisplayID,
                    useHEVC: config.videoUseHEVC,
                    videoBitrate: config.videoBitrate,
                    audioBitrate: config.audioBitrate,
                    audioSampleRate: config.audioSampleRate
                )
                do {
                    try await recorder.start(config: srConfig)
                    self.screenRecorder = recorder
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
        if config.systemAudioEnabled {
            // Three system-audio source paths, picked in order of preference:
            //   1. Custom loopback device (BlackHole etc) — set explicitly via
            //      Settings, eliminates speaker → mic echo.
            //   2. Per-process Core Audio Tap (14.4+) — captures audio from
            //      specific bundle IDs.
            //   3. SCKit whole-system mixdown — captures everything that's
            //      currently playing, including from speakers (echo-prone).
            var systemStarted = false

            if let deviceUID = config.systemAudioDeviceUID, !deviceUID.isEmpty {
                do {
                    let capture = DeviceAudioCapture(config: .init(deviceUID: deviceUID))
                    self.deviceAudioCapture = capture
                    systemTask = try await makeDeviceCaptureTask(capture: capture, writer: writer, liveSink: liveSink, delivery: liveDelivery)
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
                    systemTask = try await makeTapTask(box: box, bundleIDs: config.processTapBundleIDs, writer: writer, liveSink: liveSink, delivery: liveDelivery)
                    systemStarted = true
                } catch {
                    self.tapBoxAny = nil
                }
            }
            if !systemStarted, #available(macOS 12.3, *) {
                let box = SCKitBox()
                self.scKitBox = box
                systemTask = try await makeSystemTask(box: box, writer: writer, liveSink: liveSink, delivery: liveDelivery)
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
            // Use test stream if provided (test seam), otherwise create real engine
            if let testStream = testMicStream {
                micTask = makeTestMicTask(stream: testStream, writer: writer, liveSink: liveSink, delivery: liveDelivery)
            } else {
                let engine = AudioEngine(config: Self.micAudioEngineConfig(for: config))
                self.audioEngine = engine
                micTask = try await makeMicTask(engine: engine, writer: writer, liveSink: liveSink, delivery: liveDelivery)
            }
        }

        recordingState = .recording
    }

    public func pause() async throws {
        guard recordingState == .recording else { return }
        cancelFeedTasks()
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
        self.segmentWriter = writer

        if let engine = audioEngine {
            micTask = try await makeMicTask(engine: engine, writer: writer, liveSink: liveSink, delivery: liveDelivery)
        }

        if config.systemAudioEnabled {
            // Restart whichever system-audio path was originally chosen.
            if let capture = deviceAudioCapture {
                systemTask = try await makeDeviceCaptureTask(capture: capture, writer: writer, liveSink: liveSink, delivery: liveDelivery)
            } else if #available(macOS 14.4, *), let box = tapBoxAny as? TapBox {
                systemTask = try await makeTapTask(box: box, bundleIDs: config.processTapBundleIDs, writer: writer, liveSink: liveSink, delivery: liveDelivery)
            } else if let box = scKitBox, #available(macOS 12.3, *) {
                systemTask = try await makeSystemTask(box: box, writer: writer, liveSink: liveSink, delivery: liveDelivery)
            }
        }

        recordingState = .recording
    }

    /// Live-mute the mic without tearing down capture. Forwards to the
    /// underlying AudioEngine's tap-side mute flag — see AudioEngine.setMuted.
    /// No-op when the session has no mic track (systemAudioOnly recordings).
    public func setMicMuted(_ muted: Bool) async {
        await audioEngine?.setMuted(muted)
    }

    /// Current mic mute state. False when capture isn't running yet.
    public var isMicMuted: Bool {
        get async { await audioEngine?.isMuted ?? false }
    }

    @discardableResult
    public func stop() async throws -> [URL] {
        guard recordingState == .recording || recordingState == .paused else { return [] }

        await audioEngine?.stop()
        if #available(macOS 12.3, *) {
            await scKitBox?.capture.stop()
        }
        if #available(macOS 14.4, *), let box = tapBoxAny as? TapBox {
            await box.tap.stop()
        }
        await deviceAudioCapture?.stop()
        cancelFeedTasks()

        // Stop screen recorder. Best-effort in the sense that we don't surface
        // its error to the caller (audio finalization must complete regardless),
        // but we DO log it so silent failures stop being invisible.
        if #available(macOS 12.3, *) {
            do {
                _ = try await screenRecorder?.stop()
            } catch {
                captureSessionLog.error("CaptureSession.stop: screenRecorder.stop threw — \(error.localizedDescription, privacy: .public)")
            }
        }
        screenRecorder = nil

        // Finish pending deliveries during stop (drain queued buffers)
        if let delivery = liveDelivery {
            await delivery.finish()
            liveDelivery = nil
        }

        let paths = try await segmentWriter?.close() ?? []
        audioEngine = nil
        scKitBox = nil
        tapBoxAny = nil
        deviceAudioCapture = nil
        segmentWriter = nil
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

    /// Build a Task that drains a test mic stream into the writer.
    /// Used by test seam only — does not create or manage an AudioEngine.
    private nonisolated func makeTestMicTask(
        stream: AsyncStream<AVAudioPCMBuffer>,
        writer: SegmentWriter,
        liveSink: (any LivePCMSink)?,
        delivery: LiveSinkDelivery?
    ) -> Task<Void, Never> {
        let box = UncheckedSendableBox(stream)
        return Task.detached {
            var bufferIndex = 0
            for await buffer in box.value {
                bufferIndex += 1
                let hostTime = mach_absolute_time()
                do {
                    try await writer.append(buffer, source: .mic)
                    if bufferIndex == 1 || bufferIndex % 50 == 0 {
                        captureSessionLog.info("CaptureSession.testMic: appended buffer #\(bufferIndex, privacy: .public) frames=\(buffer.frameLength, privacy: .public)")
                    }
                } catch {
                    captureSessionLog.error("CaptureSession.testMic: writer.append threw — \(error.localizedDescription, privacy: .public) (buffer #\(bufferIndex, privacy: .public))")
                }
                // Forward to live sink via serial delivery (best-effort)
                if let delivery {
                    await delivery.enqueue(buffer, hostTime: hostTime)
                }
            }
            captureSessionLog.info("CaptureSession.testMic: stream ended after \(bufferIndex, privacy: .public) buffers")
        }
    }

    /// Build a Task that drains the mic stream into the writer.
    /// nonisolated so that the call to engine.start() (AudioEngine actor)
    /// and the resulting AsyncStream never cross into CaptureSession's isolation
    /// domain — avoiding the Swift 6 non-Sendable stream crossing error.
    private nonisolated func makeMicTask(
        engine: AudioEngine,
        writer: SegmentWriter,
        liveSink: (any LivePCMSink)?,
        delivery: LiveSinkDelivery?
    ) async throws -> Task<Void, Never> {
        let stream = try await engine.start()
        // AVAudioPCMBuffer is not Sendable; we assert single-consumer ownership here.
        let box = UncheckedSendableBox(stream)
        return Task.detached {
            var bufferIndex = 0
            for await buffer in box.value {
                bufferIndex += 1
                let hostTime = mach_absolute_time()
                do {
                    try await writer.append(buffer, source: .mic)
                    if bufferIndex == 1 || bufferIndex % 50 == 0 {
                        captureSessionLog.info("CaptureSession.mic: appended buffer #\(bufferIndex, privacy: .public) frames=\(buffer.frameLength, privacy: .public)")
                    }
                } catch {
                    captureSessionLog.error("CaptureSession.mic: writer.append threw — \(error.localizedDescription, privacy: .public) (buffer #\(bufferIndex, privacy: .public))")
                }
                // Forward to live sink via serial delivery (best-effort)
                if let delivery {
                    await delivery.enqueue(buffer, hostTime: hostTime)
                }
            }
            captureSessionLog.info("CaptureSession.mic: stream ended after \(bufferIndex, privacy: .public) buffers")
        }
    }

    @available(macOS 12.3, *)
    private nonisolated func makeSystemTask(
        box: SCKitBox,
        writer: SegmentWriter,
        liveSink: (any LivePCMSink)?,
        delivery: LiveSinkDelivery?
    ) async throws -> Task<Void, Never> {
        let stream = try await box.capture.start()
        let streamBox = UncheckedSendableBox(stream)
        return Task.detached {
            var bufferIndex = 0
            for await buffer in streamBox.value {
                bufferIndex += 1
                let hostTime = mach_absolute_time()
                do {
                    try await writer.append(buffer, source: .system)
                } catch {
                    captureSessionLog.error("CaptureSession.system(SCKit): writer.append threw — \(error.localizedDescription, privacy: .public)")
                }
                // Forward to live sink via serial delivery (best-effort)
                if let delivery {
                    await delivery.enqueue(buffer, hostTime: hostTime)
                }
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
        liveSink: (any LivePCMSink)?,
        delivery: LiveSinkDelivery?
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
                // Forward to live sink via serial delivery (best-effort)
                if let delivery {
                    await delivery.enqueue(buffer, hostTime: hostTime)
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
        liveSink: (any LivePCMSink)?,
        delivery: LiveSinkDelivery?
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
                // Forward to live sink via serial delivery (best-effort)
                if let delivery {
                    await delivery.enqueue(buffer, hostTime: hostTime)
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

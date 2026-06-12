@preconcurrency import AVFoundation
import Foundation
import os

#if canImport(ScreenCaptureKit)
@preconcurrency import ScreenCaptureKit

/// Diagnostics channel for screen recording. Until this was added, ScreenRecorder
/// failed completely silently — start could "succeed" but no frames ever wrote,
/// and the stop path's `try?` in CaptureSession swallowed the writer-failed
/// error. The user sees no screen.mp4 with no explanation.
private let screenRecorderLog = Logger(subsystem: "dev.kosmonotes.studio", category: "ScreenRecorder")

// MARK: - ScreenRecorder

/// Captures the full screen + optional system audio via SCStream, writing a
/// single `screen.mp4` via AVAssetWriter (H.264 video + AAC audio).
///
/// TCC requirement: Screen Recording permission must be granted before `start()`
/// or SCStream will throw userDeclined. The first call implicitly triggers the
/// macOS TCC prompt.
///
/// - Note: Requires macOS 12.3+.
@available(macOS 12.3, *)
public actor ScreenRecorder: NSObject {

    // MARK: - Config

    public struct Config: Sendable {
        public let outputURL: URL
        public let displayID: UInt32
        public let captureSystemAudio: Bool
        /// macOS 15+: capture mic via SCStream's native microphone output, which
        /// shares the audio HAL with screen + system audio in one synchronized
        /// stream. This avoids the AVAudioEngine -10868 cascade (mid-session mic
        /// loss reported by users — see `_handleSampleBuffer` and the project
        /// CLAUDE.md history). Ignored on macOS <15. Default false for
        /// backward compatibility — callers must opt in.
        public let captureMicrophone: Bool
        /// Optional UID of the mic device to capture from. Nil uses system
        /// default input. Only meaningful when `captureMicrophone` is true.
        public let microphoneDeviceUID: String?
        public let frameRate: Int
        public let scaleFactor: CGFloat
        /// Use HEVC (H.265) instead of H.264. ~50 % smaller at the same quality;
        /// hardware-accelerated on Apple Silicon.
        public let useHEVC: Bool
        /// Video bitrate in bits/sec. H.264 typically 2_000_000; HEVC 1_000_000.
        public let videoBitrate: Int
        /// Audio bitrate in bits/sec.
        public let audioBitrate: Int
        /// Audio sample rate Hz.
        public let audioSampleRate: Int

        public init(
            outputURL: URL,
            displayID: UInt32 = 0,
            captureSystemAudio: Bool = true,
            captureMicrophone: Bool = false,
            microphoneDeviceUID: String? = nil,
            frameRate: Int = 15,
            scaleFactor: CGFloat = 1.0,
            useHEVC: Bool = true,
            videoBitrate: Int = 1_000_000,
            audioBitrate: Int = 48_000,
            audioSampleRate: Int = 48_000
        ) {
            self.outputURL = outputURL
            self.displayID = displayID
            self.captureSystemAudio = captureSystemAudio
            self.captureMicrophone = captureMicrophone
            self.microphoneDeviceUID = microphoneDeviceUID
            self.frameRate = frameRate
            self.scaleFactor = scaleFactor
            self.useHEVC = useHEVC
            self.videoBitrate = videoBitrate
            self.audioBitrate = audioBitrate
            self.audioSampleRate = audioSampleRate
        }
    }

    // MARK: - Private state

    private var config: Config?
    private var stream: SCStream?
    private var writer: AVAssetWriter?
    private var videoInput: AVAssetWriterInput?
    private var audioInput: AVAssetWriterInput?
    private var pixelBufferAdaptor: AVAssetWriterInputPixelBufferAdaptor?
    private var streamOutput: ScreenStreamOutput?
    private var streamDelegate: SCStreamStopDelegate?
    private var firstSampleTime: CMTime?

    /// macOS 15+ SCStream microphone path. Non-nil only when `config.captureMicrophone`
    /// is true AND the OS supports the API. The recorder yields AVAudioPCMBuffer
    /// to consumers (CaptureSession → SegmentWriter for audio.m4a mic track) so the
    /// existing ScreenAudioMixer post-process still adds mic into screen.mp4 by
    /// pulling track 0 of audio.m4a. No mic track is written into screen.mp4
    /// directly — that keeps the file layout unchanged.
    private var micContinuation: AsyncStream<AVAudioPCMBuffer>.Continuation?
    /// Target PCM format that downstream consumers expect — built from
    /// `config.audioSampleRate` (typically 48 kHz mono Float32). SCStream's
    /// mic output arrives at the device's native rate, which is 24 kHz when
    /// the active mic is a Bluetooth headset / AirPods on HFP/SCO. Without
    /// the conversion below, every buffer fails SegmentWriter's defense-in-
    /// depth rate check and the resulting recording has zero mic audio.
    private var micTargetFormat: AVAudioFormat?
    /// Lazily-built AVAudioConverter from the SCStream-delivered format to
    /// `micTargetFormat`. Cached because format probing per-buffer would
    /// allocate on the audio-callback thread.
    private var micConverterCache: MicConverterCache?
    /// Counter incremented every time a mic CMSampleBuffer arrives. Used by the
    /// mic-flow watchdog (see `micRecoveryTask`).
    private let micBufferCounter = MicBufferCounter()
    /// Live mute flag for SCStream mic. Replaces incoming PCM with silence
    /// before yielding so the writer timeline keeps growing during mute.
    private let micMuteFlag = TapMuteFlag()
    /// Recovery supervisor: monitors `micBufferCounter`, restarts SCStream when
    /// mic samples stall for >5 s. Bounded to 3 attempts per session.
    private var micRecoveryTask: Task<Void, Never>?
    private var micRecoveryAttempts: Int = 0
    /// Incremented whenever start/stop takes ownership of the SCStream lifecycle.
    /// Restart code checks this after every await so a user stop cannot race a
    /// recovery restart into creating an ownerless stream.
    private var streamGeneration: UInt64 = 0
    private var isStopping = false
    private let screenSampleQueue = DispatchQueue(
        label: "dev.kosmonotes.studio.screen-recorder.screen-samples",
        qos: .userInteractive
    )
    private let systemAudioSampleQueue = DispatchQueue(
        label: "dev.kosmonotes.studio.screen-recorder.system-audio-samples",
        qos: .userInitiated
    )
    private let microphoneSampleQueue = DispatchQueue(
        label: "dev.kosmonotes.studio.screen-recorder.microphone-samples",
        qos: .userInitiated
    )
    /// Set when the mic recovery watchdog has exhausted its retries. Callers
    /// (CaptureSession → RecorderState) can surface this to the UI.
    public private(set) var micRecoveryGaveUp: Bool = false
    /// Set when SCStream itself reports an external terminal stop, such as the
    /// macOS Stop Sharing control or system-level stream termination.
    public private(set) var streamStopError: SCStreamStopFailure?

    // MARK: - Init

    public override init() {
        super.init()
    }

    // MARK: - Public API

    /// Start screen capture. When `config.captureMicrophone` is true AND the OS
    /// supports it (macOS 15+), the returned AsyncStream yields mic PCM buffers
    /// synchronized with the screen + system-audio capture. Returns nil when mic
    /// capture isn't enabled or isn't available — callers fall back to
    /// AVAudioEngine.
    @discardableResult
    public func start(config: Config) async throws -> sending AsyncStream<AVAudioPCMBuffer>? {
        self.config = config
        isStopping = false
        streamGeneration &+= 1
        pendingSampleTasks.open()
        micRecoveryAttempts = 0
        micRecoveryGaveUp = false
        streamStopError = nil
        screenRecorderLog.info("ScreenRecorder.start: outputURL=\(config.outputURL.path, privacy: .public) hevc=\(config.useHEVC, privacy: .public) videoBitrate=\(config.videoBitrate, privacy: .public) audio=\(config.captureSystemAudio, privacy: .public) mic=\(config.captureMicrophone, privacy: .public) fps=\(config.frameRate, privacy: .public)")

        let content: SCShareableContent
        do {
            content = try await SCShareableContent.excludingDesktopWindows(
                false,
                onScreenWindowsOnly: true
            )
        } catch {
            screenRecorderLog.error("ScreenRecorder.start: SCShareableContent failed — \(error.localizedDescription, privacy: .public). Likely Screen Recording TCC denied; reset with `tccutil reset ScreenCapture dev.kosmonotes.studio` and re-grant.")
            throw error
        }
        let display = Self.selectDisplay(from: content.displays, preferredID: config.displayID)
        guard let display else {
            screenRecorderLog.error("ScreenRecorder.start: no displays available")
            throw ScreenRecorderError.noDisplayAvailable
        }

        let width = Int(CGFloat(display.width) * config.scaleFactor)
        let height = Int(CGFloat(display.height) * config.scaleFactor)
        screenRecorderLog.info("ScreenRecorder.start: selected displayID=\(display.displayID, privacy: .public) source=\(display.width, privacy: .public)×\(display.height, privacy: .public) → output \(width, privacy: .public)×\(height, privacy: .public)")

        // Configure SCStream for video + optional audio + optional mic.
        let streamConfig = SCStreamConfiguration()
        streamConfig.width = width
        streamConfig.height = height
        streamConfig.minimumFrameInterval = CMTime(value: 1, timescale: Int32(config.frameRate))
        streamConfig.pixelFormat = kCVPixelFormatType_32BGRA
        streamConfig.capturesAudio = config.captureSystemAudio
        streamConfig.excludesCurrentProcessAudio = true  // may be ignored on macOS 26+
        streamConfig.sampleRate = config.audioSampleRate
        streamConfig.channelCount = 1

        // Microphone capture via SCStream — macOS 15+ only. When enabled, SCStream
        // becomes the single client of the audio HAL for both system audio AND
        // mic, eliminating the AVAudioEngine vs SCStream HAL contention that
        // caused -10868 cascades and mid-session mic silence.
        var micStreamReturn: AsyncStream<AVAudioPCMBuffer>? = nil
        var micCaptureWillRun = false
        if config.captureMicrophone {
            if #available(macOS 15.0, *) {
                streamConfig.captureMicrophone = true
                if let deviceUID = config.microphoneDeviceUID, !deviceUID.isEmpty {
                    streamConfig.microphoneCaptureDeviceID = deviceUID
                }
                // Drop the oldest mic buffer when downstream stalls (pause, slow
                // disk). 100 buffers ≈ ~1 s at the typical 10 ms SCStream cadence.
                let (s, cont) = AudioPCMBufferStream.makeStream()
                self.micContinuation = cont
                // Build the target format that downstream (SegmentWriter)
                // expects. Float32 mono — same shape AudioEngine/DeviceAudioCapture
                // produce. SCStream often delivers the source at the mic's
                // native rate (24 kHz on Bluetooth HFP); we convert per-buffer.
                self.micTargetFormat = AVAudioFormat(
                    commonFormat: .pcmFormatFloat32,
                    sampleRate: Double(config.audioSampleRate),
                    channels: 1,
                    interleaved: false
                )
                self.micConverterCache = MicConverterCache()
                micStreamReturn = s
                micCaptureWillRun = true
                screenRecorderLog.info("ScreenRecorder.start: SCStream microphone capture ENABLED (macOS 15+, deviceUID=\(config.microphoneDeviceUID ?? "default", privacy: .public))")
            } else {
                screenRecorderLog.error("ScreenRecorder.start: captureMicrophone requested but OS<macOS 15 — SCStream mic API unavailable. Caller must fall back to AVAudioEngine.")
            }
        }

        let filter = SCContentFilter(display: display, excludingApplications: [], exceptingWindows: [])

        // Set up AVAssetWriter targeting the output URL.
        if FileManager.default.fileExists(atPath: config.outputURL.path) {
            try FileManager.default.removeItem(at: config.outputURL)
        }
        let assetWriter = try AVAssetWriter(outputURL: config.outputURL, fileType: .mp4)
        self.writer = assetWriter

        // Video input: H.264 or HEVC, real-time. HEVC is ~50% more efficient at
        // the same visual quality and hardware-accelerated on Apple Silicon.
        let codec: AVVideoCodecType = config.useHEVC ? .hevc : .h264
        let videoSettings: [String: Any] = [
            AVVideoCodecKey: codec,
            AVVideoWidthKey: width,
            AVVideoHeightKey: height,
            AVVideoCompressionPropertiesKey: [AVVideoAverageBitRateKey: config.videoBitrate],
        ]
        let vInput = AVAssetWriterInput(mediaType: .video, outputSettings: videoSettings)
        vInput.expectsMediaDataInRealTime = true
        self.videoInput = vInput

        let adaptor = AVAssetWriterInputPixelBufferAdaptor(
            assetWriterInput: vInput,
            sourcePixelBufferAttributes: [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
                kCVPixelBufferWidthKey as String: width,
                kCVPixelBufferHeightKey as String: height,
            ]
        )
        self.pixelBufferAdaptor = adaptor
        assetWriter.add(vInput)

        // Audio input: AAC mono, real-time (only when captureSystemAudio).
        // We always write AAC into the .mp4 container regardless of the
        // user-selected codec for the standalone audio.m4a file — MP4-in-Opus
        // playback support is uneven (Safari yes, QuickTime no), and the screen
        // file is meant to be playable in QuickTime out of the box. The user's
        // codec preference applies to audio.m4a (segmented capture path).
        if config.captureSystemAudio {
            let audioSettings: [String: Any] = [
                AVFormatIDKey: kAudioFormatMPEG4AAC,
                AVSampleRateKey: config.audioSampleRate,
                AVNumberOfChannelsKey: 1,
                AVEncoderBitRateKey: config.audioBitrate,
            ]
            let aInput = AVAssetWriterInput(mediaType: .audio, outputSettings: audioSettings)
            aInput.expectsMediaDataInRealTime = true
            self.audioInput = aInput
            assetWriter.add(aInput)
        }

        let started = assetWriter.startWriting()
        if !started || assetWriter.status != .writing {
            screenRecorderLog.error("ScreenRecorder.start: AVAssetWriter.startWriting returned \(started, privacy: .public) status=\(assetWriter.status.rawValue, privacy: .public) error=\(assetWriter.error?.localizedDescription ?? "nil", privacy: .public)")
            throw ScreenRecorderError.writeFailed(underlying: assetWriter.error ?? NSError(domain: "ScreenRecorder", code: -1))
        }

        // Wire stream output delegate (separate @unchecked Sendable class per codebase pattern).
        let output = ScreenStreamOutput(recorder: self)
        self.streamOutput = output

        let stopDelegate = SCStreamStopDelegate { [weak self] failure in
            Task {
                await self?.recordExternalStreamStop(failure)
            }
        }
        self.streamDelegate = stopDelegate

        let scStream = SCStream(filter: filter, configuration: streamConfig, delegate: stopDelegate)
        do {
            try scStream.addStreamOutput(output, type: .screen, sampleHandlerQueue: screenSampleQueue)
            if config.captureSystemAudio {
                try scStream.addStreamOutput(output, type: .audio, sampleHandlerQueue: systemAudioSampleQueue)
            }
            if micCaptureWillRun, #available(macOS 15.0, *) {
                try scStream.addStreamOutput(output, type: .microphone, sampleHandlerQueue: microphoneSampleQueue)
            }
            try await scStream.startCapture()
        } catch {
            screenRecorderLog.error("ScreenRecorder.start: SCStream.startCapture failed — \(error.localizedDescription, privacy: .public)")
            micContinuation?.finish()
            micContinuation = nil
            micTargetFormat = nil
            micConverterCache = nil
            streamOutput = nil
            streamDelegate = nil
            throw error
        }
        self.stream = scStream
        screenRecorderLog.info("ScreenRecorder.start: SCStream capturing, awaiting first frame")

        // Recovery supervisor for mic capture. Only run when SCStream mic is
        // actually feeding our pipeline — otherwise the watchdog has nothing
        // to recover. The first mic buffer can take a few hundred ms to arrive
        // post-startCapture, so the supervisor's grace window must be > that.
        if micCaptureWillRun {
            startMicRecoverySupervisor()
        }
        return micStreamReturn
    }

    private static func selectDisplay(from displays: [SCDisplay], preferredID: UInt32) -> SCDisplay? {
        if preferredID != 0,
           let preferred = displays.first(where: { $0.displayID == preferredID }) {
            return preferred
        }
        return displays.first
    }

    /// Live-toggle mute for the SCStream mic track. No-op when the SCStream
    /// mic isn't active. Mirrors `AudioEngine.setMuted` so the menu/popover
    /// can share the toggle path.
    public func setMicMuted(_ muted: Bool) {
        micMuteFlag.setMuted(muted)
    }

    /// True when the SCStream mic is currently muted.
    public var isMicMuted: Bool {
        micMuteFlag.isMuted
    }

    /// Snapshot of mic delivery for diagnostics / external watchdogs.
    public var micFlowSnapshot: (count: Int, totalFrames: Int) {
        micBufferCounter.snapshot
    }

    /// Stop capture, finalize the MP4, and return the output URL.
    @discardableResult
    public func stop() async throws -> URL {
        guard writer != nil, config != nil else {
            screenRecorderLog.error("ScreenRecorder.stop: not started")
            throw ScreenRecorderError.notStarted
        }
        isStopping = true
        streamGeneration &+= 1
        defer { isStopping = false }
        // Cancel mic supervisor BEFORE stopping the stream so it can't race
        // the teardown with a restart attempt.
        micRecoveryTask?.cancel()
        micRecoveryTask = nil
        if let scStream = stream {
            do {
                try await scStream.stopCapture()
            } catch {
                screenRecorderLog.error("ScreenRecorder.stop: SCStream.stopCapture threw — \(error.localizedDescription, privacy: .public) (continuing to finalize writer)")
            }
        } else {
            screenRecorderLog.error("ScreenRecorder.stop: stream is nil; finalizing writer from recovery/partial-stop state")
        }
        stream = nil
        streamOutput = nil
        streamDelegate = nil
        // Finish the mic AsyncStream so consumers' for-await loops exit cleanly.
        micContinuation?.finish()
        micContinuation = nil

        guard let w = writer, let cfg = config else { throw ScreenRecorderError.notStarted }

        // Drain any handleSampleBuffer Tasks that were queued behind the actor
        // before the SCStream actually stopped — without this, late frames
        // arrive AFTER finishWriting() and corrupt the tail of screen.mp4.
        for task in pendingSampleTasks.drain() {
            _ = await task.value
        }

        videoInput?.markAsFinished()
        audioInput?.markAsFinished()

        await w.finishWriting()
        screenRecorderLog.info("ScreenRecorder.stop: framesWritten=\(self.screenFrameCount, privacy: .public) framesDropped=\(self.screenFrameDropped, privacy: .public) writerStatus=\(w.status.rawValue, privacy: .public)")

        if w.status == .failed, let err = w.error {
            screenRecorderLog.error("ScreenRecorder.stop: writer failed — \(err.localizedDescription, privacy: .public)")
            throw ScreenRecorderError.writeFailed(underlying: err)
        }
        if screenFrameCount == 0 {
            screenRecorderLog.error("ScreenRecorder.stop: zero video frames written — screen.mp4 will be missing or unplayable. SCStream may not have delivered any .complete frames; check Screen Recording TCC trust against the running binary's hash.")
        }

        return cfg.outputURL
    }

    // MARK: - Internal: called from ScreenStreamOutput

    /// Bounded serial `_handleSampleBuffer` dispatcher. Samples are enqueued
    /// synchronously inside the nonisolated entry point (no actor hop), so
    /// `stop()` can wait for already-accepted callbacks before tearing down
    /// the writer. FIFO dispatch preserves per-output PTS order across the
    /// async actor hop.
    private let pendingSampleTasks = SCSampleTaskBag()

    /// Routes a sample buffer from the stream delegate into the correct writer input.
    nonisolated func handleSampleBuffer(_ sampleBuffer: CMSampleBuffer, ofType type: SCStreamOutputType) {
        // CMSampleBuffer is not Sendable; wrap in an unchecked-Sendable box.
        // The delegate callback owns the buffer for the duration of the closure
        // call, so the cross-actor hop is safe in practice.
        let box = SBBox(buffer: sampleBuffer, type: type)
        let bag = pendingSampleTasks
        bag.add { [weak self] in
            await self?._handleSampleBuffer(box.buffer, ofType: box.type)
        }
    }

    func recordExternalStreamStop(_ failure: SCStreamStopFailure) {
        guard !isStopping else { return }
        streamStopError = failure
        micRecoveryGaveUp = true
        stream = nil
        streamOutput = nil
        streamDelegate = nil
        micContinuation?.finish()
        micContinuation = nil
        screenRecorderLog.error("ScreenRecorder: SCStream stopped externally — \(failure.message, privacy: .public)")
    }

    private var screenFrameCount: Int = 0
    private var screenFrameDropped: Int = 0

    private func _handleSampleBuffer(_ sampleBuffer: CMSampleBuffer, ofType type: SCStreamOutputType) {
        guard let w = writer else { return }
        guard w.status == .writing else {
            if w.status == .failed {
                screenRecorderLog.error("ScreenRecorder: writer in failed state — dropping sample. error=\(w.error?.localizedDescription ?? "nil", privacy: .public)")
            }
            return
        }

        // Drop SCStream frames flagged with status != .complete (e.g. .idle when
        // no on-screen change since last frame) BEFORE we anchor the timeline,
        // otherwise firstSampleTime locks to a non-image frame and downstream
        // appends silently produce a malformed file.
        if let attachments = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: false) as? [[SCStreamFrameInfo: Any]],
           let info = attachments.first,
           let statusRaw = info[.status] as? Int,
           let status = SCFrameStatus(rawValue: statusRaw),
           status != .complete {
            screenFrameDropped += 1
            return
        }

        // Start the writer session on the very first sample to anchor PTS at .zero.
        let pts = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)

        if firstSampleTime == nil {
            firstSampleTime = pts
            // Anchor the writer's session at .zero, NOT at the first sample's
            // mach-time PTS. Both video frames (via offsetPTS) and audio samples
            // (via copyWithAdjustedPTS) are rebased to start at 0; if the session
            // were anchored at the original mach-time the rebased samples would
            // sit *before* the session window and the .mp4 would report
            // duration=0 — playable as one frozen frame, but Play does nothing.
            w.startSession(atSourceTime: .zero)
            screenRecorderLog.info("ScreenRecorder: first sample (type=\(type == .screen ? "screen" : "audio", privacy: .public)) — writer session started at .zero (machPTS=\(pts.seconds, privacy: .public))")
        }

        switch type {
        case .screen:
            guard let vInput = videoInput, vInput.isReadyForMoreMediaData else {
                screenFrameDropped += 1
                if screenFrameDropped % 100 == 0 {
                    screenRecorderLog.warning("ScreenRecorder: encoder backpressure — dropped=\(self.screenFrameDropped, privacy: .public) written=\(self.screenFrameCount, privacy: .public). Consider reducing frame rate or bitrate.")
                }
                return
            }
            guard let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else {
                screenFrameDropped += 1
                return
            }
            let offsetPTS = CMTimeSubtract(pts, firstSampleTime!)
            let appended = pixelBufferAdaptor?.append(pixelBuffer, withPresentationTime: offsetPTS) ?? false
            if appended {
                screenFrameCount += 1
                if screenFrameCount == 1 || screenFrameCount % 120 == 0 {
                    screenRecorderLog.info("ScreenRecorder: video frame #\(self.screenFrameCount, privacy: .public) appended (dropped so far=\(self.screenFrameDropped, privacy: .public))")
                }
            } else {
                screenRecorderLog.error("ScreenRecorder: pixelBufferAdaptor.append returned false — writerStatus=\(w.status.rawValue, privacy: .public) error=\(w.error?.localizedDescription ?? "nil", privacy: .public)")
            }

        case .audio:
            guard let aInput = audioInput, aInput.isReadyForMoreMediaData else { return }
            if let adjusted = sampleBuffer.copyWithAdjustedPTS(offset: firstSampleTime!) {
                let appended = aInput.append(adjusted)
                if !appended {
                    screenRecorderLog.error("ScreenRecorder: audio append returned false — writerStatus=\(w.status.rawValue, privacy: .public) error=\(w.error?.localizedDescription ?? "nil", privacy: .public)")
                }
            }

        case .microphone:
            // macOS 15+: SCStream emits a synchronized mic track when
            // `streamConfig.captureMicrophone = true`. The buffer is delivered
            // alongside screen + system audio with a single HAL client, so
            // there's no AVAudioEngine / SCStream race. We convert to
            // AVAudioPCMBuffer and yield to consumers; the existing
            // ScreenAudioMixer post-process still mixes mic from audio.m4a
            // into screen.mp4 for playback.
            guard let cont = micContinuation else { return }
            guard let pcm = sampleBuffer.toAVAudioPCMBuffer() else {
                screenRecorderLog.error("ScreenRecorder: mic CMSampleBuffer→AVAudioPCMBuffer conversion failed")
                return
            }
            // Resample / channel-fold to the format downstream consumers
            // expect. On built-in mics this is a no-op (already 48 kHz mono).
            // On Bluetooth HFP/SCO (AirPods, headsets) the source is typically
            // 24 kHz mono and the writer at 48 kHz would otherwise drop every
            // buffer as a "slow-bassy" rate mismatch.
            let yieldedBuffer: AVAudioPCMBuffer
            if let target = micTargetFormat,
               let cache = micConverterCache,
               let converted = ScreenRecorder.convertToTargetFormat(
                   buffer: pcm,
                   target: target,
                   cache: cache
               ) {
                yieldedBuffer = converted
            } else {
                yieldedBuffer = pcm
            }
            micBufferCounter.increment(frames: Int(yieldedBuffer.frameLength))
            if micMuteFlag.isMuted {
                ScreenRecorder.overwriteWithSilence(yieldedBuffer)
            }
            cont.yield(yieldedBuffer)
            let snapshot = micBufferCounter.snapshot
            if snapshot.count == 1 || snapshot.count % 200 == 0 {
                screenRecorderLog.info("ScreenRecorder: mic buffer #\(snapshot.count, privacy: .public) yielded (totalFrames=\(snapshot.totalFrames, privacy: .public))")
            }

        @unknown default:
            break
        }
    }
}

// MARK: - Mic recovery supervisor

@available(macOS 12.3, *)
extension ScreenRecorder {
    /// Replace PCM samples with zeroes in-place. Used by mute and by recovery
    /// in case SCStream delivers a malformed buffer mid-restart.
    fileprivate nonisolated static func overwriteWithSilence(_ buffer: AVAudioPCMBuffer) {
        let abl = UnsafeMutableAudioBufferListPointer(buffer.mutableAudioBufferList)
        for ab in abl {
            guard let data = ab.mData else { continue }
            memset(data, 0, Int(ab.mDataByteSize))
        }
    }

    /// Mic-flow watchdog. Polls `micBufferCounter` every second; if the count
    /// hasn't moved for `stallThreshold` consecutive ticks, restarts SCStream
    /// to recover from a silent HAL stall. Bounded at `maxAttempts` so a
    /// permanently broken device can't loop forever.
    fileprivate func startMicRecoverySupervisor() {
        let stallThreshold = 5  // 5 s without mic samples = stalled
        let maxAttempts = 3
        micRecoveryTask?.cancel()
        let baseline = micBufferCounter.snapshot.count
        micRecoveryTask = Task { [weak self] in
            var lastCount = baseline
            var stalledTicks = 0
            // Grace window: SCStream's mic sub-component can take 500–1500 ms
            // post-startCapture to deliver the first buffer. Don't bark during
            // initial bring-up.
            try? await Task.sleep(nanoseconds: 1_500_000_000)
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 1_000_000_000)
                if Task.isCancelled { break }
                await self?.micRecoveryTick(lastCount: &lastCount, stalledTicks: &stalledTicks, stallThreshold: stallThreshold, maxAttempts: maxAttempts)
            }
        }
        screenRecorderLog.info("ScreenRecorder: mic recovery supervisor started (stallThreshold=\(stallThreshold, privacy: .public)s, maxAttempts=\(maxAttempts, privacy: .public))")
    }

    /// One supervisor tick. Inout state lives on the Task to avoid actor hops
    /// per read; restart work is actor-isolated so we don't double-restart.
    ///
    /// After the rework for the always-on capture audit, this tick must NEVER
    /// silently no-op when the stream is gone. The prior version short-circuited
    /// whenever `stream == nil`, which meant a failed restart that cleared the
    /// stream left the supervisor idle forever and tier-2 fallback never fired.
    /// Now we treat `stream == nil` as a terminal recovery error.
    private func micRecoveryTick(
        lastCount: inout Int,
        stalledTicks: inout Int,
        stallThreshold: Int,
        maxAttempts: Int
    ) async {
        if micRecoveryGaveUp {
            stalledTicks = 0
            return
        }
        if stream == nil {
            // A restart attempt cleared the stream and never recreated it.
            // Without a stream there will never be more mic samples — fail
            // loudly so CaptureSession's supervisor can schedule tier-2.
            if !micRecoveryGaveUp {
                screenRecorderLog.error("ScreenRecorder.micRecovery: stream is nil — restart did not recreate it. Marking recovery as given up so tier-2 fallback can run.")
                micRecoveryGaveUp = true
            }
            stalledTicks = 0
            return
        }
        if micMuteFlag.isMuted {
            // Muted: SCStream is still delivering buffers and the tap still
            // increments the counter (we just overwrite with silence). No
            // stall accounting needed.
            stalledTicks = 0
            lastCount = micBufferCounter.snapshot.count
            return
        }
        let current = micBufferCounter.snapshot.count
        if current != lastCount {
            lastCount = current
            stalledTicks = 0
            return
        }
        stalledTicks += 1
        if stalledTicks < stallThreshold {
            return
        }
        stalledTicks = 0
        if micRecoveryAttempts >= maxAttempts {
            if !micRecoveryGaveUp {
                screenRecorderLog.error("ScreenRecorder.micRecovery: exhausted \(maxAttempts, privacy: .public) restart attempts — giving up. User must stop and restart recording.")
                micRecoveryGaveUp = true
            }
            return
        }
        micRecoveryAttempts += 1
        screenRecorderLog.error("ScreenRecorder.micRecovery: no mic samples for ~\(stallThreshold, privacy: .public)s — attempting SCStream restart (attempt \(self.micRecoveryAttempts, privacy: .public)/\(maxAttempts, privacy: .public))")
        let restarted = await restartSCStreamForMicRecovery()
        if !restarted {
            // The restart cycle could not recreate the SCStream. Don't keep
            // burning attempts on a permanently broken HAL — flag the recovery
            // as given up so CaptureSession can demote to tier-2 fallback on
            // the next tick.
            if !micRecoveryGaveUp {
                screenRecorderLog.error("ScreenRecorder.micRecovery: restart attempt \(self.micRecoveryAttempts, privacy: .public)/\(maxAttempts, privacy: .public) failed — giving up so tier-2 fallback can run.")
                micRecoveryGaveUp = true
            }
            return
        }
        // Re-baseline AFTER restart so the next tick measures from the new
        // counter (which may have new buffers already).
        lastCount = micBufferCounter.snapshot.count
    }

    /// Stop the current SCStream and start a fresh one with the same Config.
    /// The mic AsyncStream's continuation is preserved — consumers see no gap
    /// from their POV; samples just resume after a brief silence.
    ///
    /// Returns `true` only when a fresh SCStream is successfully started and
    /// reassigned to `self.stream`. Any failure path (SCShareableContent throw,
    /// no display, startCapture throw) returns `false` so the supervisor can
    /// escalate to tier-2 instead of looping silently with `stream == nil`.
    @discardableResult
    private func restartSCStreamForMicRecovery() async -> Bool {
        guard let cfg = config, let oldStream = stream, !isStopping else { return false }
        let restartGeneration = streamGeneration
        do {
            try await oldStream.stopCapture()
        } catch {
            screenRecorderLog.error("ScreenRecorder.micRecovery: stopCapture threw — \(error.localizedDescription, privacy: .public)")
        }
        guard !isStopping, restartGeneration == streamGeneration else { return false }
        stream = nil
        streamOutput = nil
        streamDelegate = nil

        // Rebuild SCStreamConfiguration from the cached Config. Don't touch the
        // writer / continuation — they keep accepting samples from the new stream.
        let content: SCShareableContent
        do {
            content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        } catch {
            screenRecorderLog.error("ScreenRecorder.micRecovery: SCShareableContent failed during restart — \(error.localizedDescription, privacy: .public)")
            return false
        }
        guard !isStopping, restartGeneration == streamGeneration else { return false }
        guard let display = Self.selectDisplay(from: content.displays, preferredID: cfg.displayID) else {
            screenRecorderLog.error("ScreenRecorder.micRecovery: no display available during restart")
            return false
        }
        let width = Int(CGFloat(display.width) * cfg.scaleFactor)
        let height = Int(CGFloat(display.height) * cfg.scaleFactor)

        let streamConfig = SCStreamConfiguration()
        streamConfig.width = width
        streamConfig.height = height
        streamConfig.minimumFrameInterval = CMTime(value: 1, timescale: Int32(cfg.frameRate))
        streamConfig.pixelFormat = kCVPixelFormatType_32BGRA
        streamConfig.capturesAudio = cfg.captureSystemAudio
        streamConfig.excludesCurrentProcessAudio = true
        streamConfig.sampleRate = cfg.audioSampleRate
        streamConfig.channelCount = 1
        if #available(macOS 15.0, *) {
            streamConfig.captureMicrophone = cfg.captureMicrophone
            if let uid = cfg.microphoneDeviceUID, !uid.isEmpty {
                streamConfig.microphoneCaptureDeviceID = uid
            }
        }

        let filter = SCContentFilter(display: display, excludingApplications: [], exceptingWindows: [])
        let output = ScreenStreamOutput(recorder: self)
        self.streamOutput = output

        let stopDelegate = SCStreamStopDelegate { [weak self] failure in
            Task {
                await self?.recordExternalStreamStop(failure)
            }
        }
        self.streamDelegate = stopDelegate

        let newStream = SCStream(filter: filter, configuration: streamConfig, delegate: stopDelegate)
        do {
            try newStream.addStreamOutput(output, type: .screen, sampleHandlerQueue: screenSampleQueue)
            if cfg.captureSystemAudio {
                try newStream.addStreamOutput(output, type: .audio, sampleHandlerQueue: systemAudioSampleQueue)
            }
            if cfg.captureMicrophone, #available(macOS 15.0, *) {
                try newStream.addStreamOutput(output, type: .microphone, sampleHandlerQueue: microphoneSampleQueue)
            }
            guard !isStopping, restartGeneration == streamGeneration else {
                streamOutput = nil
                streamDelegate = nil
                return false
            }
            try await newStream.startCapture()
            guard !isStopping, restartGeneration == streamGeneration else {
                try? await newStream.stopCapture()
                streamOutput = nil
                streamDelegate = nil
                return false
            }
            stream = newStream
            screenRecorderLog.info("ScreenRecorder.micRecovery: SCStream restarted successfully")
            return true
        } catch {
            streamOutput = nil
            streamDelegate = nil
            screenRecorderLog.error("ScreenRecorder.micRecovery: SCStream restart failed — \(error.localizedDescription, privacy: .public)")
            return false
        }
    }
}

/// Lock-protected mic buffer counter. Lives at file scope (not nested in the
/// actor) so it can be incremented from any thread the SCStream delivery queue
/// uses without an actor hop.
@available(macOS 12.3, *)
final class MicBufferCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var _count: Int = 0
    private var _totalFrames: Int = 0

    func increment(frames: Int) {
        lock.lock()
        _count += 1
        _totalFrames += frames
        lock.unlock()
    }

    var snapshot: (count: Int, totalFrames: Int) {
        lock.lock(); defer { lock.unlock() }
        return (_count, _totalFrames)
    }
}

// MARK: - MicConverterCache

/// Lazily-built AVAudioConverter cache for the SCStream mic path. Mirrors the
/// pattern used by `AudioEngine.ConverterCache` and
/// `DeviceAudioCapture.ConverterCacheRef` so behaviour stays consistent across
/// the three mic producers. NSLock-guarded because a sample-rate change
/// mid-session (e.g. Bluetooth profile flip from A2DP→HFP) can still interleave
/// with reads from the SCStream callback path.
@available(macOS 12.3, *)
final class MicConverterCache: @unchecked Sendable {
    private let lock = NSLock()
    private var converter: AVAudioConverter?
    private var sourceFormat: AVAudioFormat?

    func converter(from source: AVAudioFormat, to target: AVAudioFormat) -> AVAudioConverter? {
        lock.lock(); defer { lock.unlock() }
        if let existing = converter,
           let cached = sourceFormat,
           cached.sampleRate == source.sampleRate,
           cached.channelCount == source.channelCount,
           cached.commonFormat == source.commonFormat {
            return existing
        }
        let new = AVAudioConverter(from: source, to: target)
        converter = new
        sourceFormat = source
        return new
    }
}

// MARK: - ScreenRecorder mic conversion helper

@available(macOS 12.3, *)
extension ScreenRecorder {
    /// Resample/channel-fold `buffer` to `target` using `cache`. Returns the
    /// original buffer when the format already matches (zero-copy fast path),
    /// the converted buffer on success, or `nil` if the conversion failed.
    /// `nonisolated static` so it can be unit-tested without instantiating an
    /// actor or touching SCStream.
    nonisolated static func convertToTargetFormat(
        buffer: AVAudioPCMBuffer,
        target: AVAudioFormat,
        cache: MicConverterCache
    ) -> AVAudioPCMBuffer? {
        let src = buffer.format
        if src.sampleRate == target.sampleRate
            && src.channelCount == target.channelCount
            && src.commonFormat == target.commonFormat {
            return buffer
        }
        guard let converter = cache.converter(from: src, to: target) else {
            return nil
        }
        let frameCapacity = AVAudioFrameCount(
            Double(buffer.frameLength) * target.sampleRate / src.sampleRate
        ) + 1
        guard let converted = AVAudioPCMBuffer(
            pcmFormat: target,
            frameCapacity: max(1, frameCapacity)
        ) else {
            return nil
        }
        var error: NSError?
        let source = buffer
        let status = converter.convert(to: converted, error: &error) { _, outStatus in
            outStatus.pointee = .haveData
            return source
        }
        if status == .error || converted.frameLength == 0 {
            return nil
        }
        return converted
    }
}

// MARK: - SBBox

/// Sendable wrapper for `CMSampleBuffer` + `SCStreamOutputType`.
/// CMSampleBuffer is not Sendable; the box lets us hop the buffer across
/// the actor boundary. SCStream owns the buffer for the duration of the
/// delegate call, so the unchecked-sendability is safe in practice.
@available(macOS 12.3, *)
private final class SBBox: @unchecked Sendable {
    let buffer: CMSampleBuffer
    let type: SCStreamOutputType
    init(buffer: CMSampleBuffer, type: SCStreamOutputType) {
        self.buffer = buffer
        self.type = type
    }
}

/// Lock-protected, bounded FIFO dispatcher for sample-handler work. Recorded
/// synchronously inside `ScreenRecorder.handleSampleBuffer` (which is
/// `nonisolated`) so `stop()` can `drain()` and await every accepted callback
/// before tearing down the writer. Without this, callbacks queued behind the
/// actor can land after `writer.finishWriting()` and corrupt the tail of
/// `screen.mp4`.
@available(macOS 12.3, *)
final class SCSampleTaskBag: @unchecked Sendable {
    private struct Worker {
        let id: UInt64
        let task: Task<Void, Never>
    }

    private typealias Operation = @Sendable () async -> Void

    private let lock = NSLock()
    private let maxQueuedOperations: Int
    private var queue: [Operation] = []
    private var worker: Worker?
    private var workerIsExecuting = false
    private var nextWorkerID: UInt64 = 0
    private var closed = false

    init(maxQueuedOperations: Int = 240) {
        self.maxQueuedOperations = max(1, maxQueuedOperations)
    }

    var activeTaskCount: Int {
        lock.lock()
        let count = closed ? 0 : queue.count + (workerIsExecuting ? 1 : 0)
        lock.unlock()
        return count
    }

    func open() {
        lock.lock()
        queue.removeAll(keepingCapacity: true)
        closed = false
        nextWorkerID &+= 1
        let staleWorker = worker?.task
        worker = nil
        workerIsExecuting = false
        lock.unlock()
        staleWorker?.cancel()
    }

    @discardableResult
    func add(_ operation: @escaping @Sendable () async -> Void) -> Task<Void, Never>? {
        lock.lock()
        guard !closed else {
            lock.unlock()
            return nil
        }

        if queue.count >= maxQueuedOperations {
            queue.removeFirst(queue.count - maxQueuedOperations + 1)
        }
        queue.append(operation)
        let task = ensureWorkerLocked()
        lock.unlock()
        return task
    }

    func drain() -> [Task<Void, Never>] {
        lock.lock()
        closed = true
        let out = worker.map { [$0.task] } ?? []
        lock.unlock()
        return out
    }

    private func ensureWorkerLocked() -> Task<Void, Never> {
        if let worker {
            return worker.task
        }

        nextWorkerID &+= 1
        let id = nextWorkerID
        let task = Task<Void, Never> { [weak self] in
            await self?.runWorker(id: id)
        }
        worker = Worker(id: id, task: task)
        return task
    }

    private func runWorker(id: UInt64) async {
        while let operation = nextOperation(for: id) {
            await operation()
        }
    }

    private func nextOperation(for id: UInt64) -> Operation? {
        lock.lock()
        defer { lock.unlock() }

        guard let worker, worker.id == id else {
            return nil
        }
        if Task.isCancelled {
            queue.removeAll(keepingCapacity: true)
            self.worker = nil
            workerIsExecuting = false
            return nil
        }
        guard !queue.isEmpty else {
            self.worker = nil
            workerIsExecuting = false
            return nil
        }
        workerIsExecuting = true
        return queue.removeFirst()
    }
}

// MARK: - ScreenStreamOutput (SCStreamOutput delegate)

@available(macOS 12.3, *)
private final class ScreenStreamOutput: NSObject, SCStreamOutput, @unchecked Sendable {

    private weak var recorder: ScreenRecorder?

    init(recorder: ScreenRecorder) {
        self.recorder = recorder
    }

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        recorder?.handleSampleBuffer(sampleBuffer, ofType: type)
    }
}

// MARK: - CMSampleBuffer PTS adjustment

private extension CMSampleBuffer {
    /// Return a copy of this sample buffer with all timing adjusted by subtracting `offset`.
    func copyWithAdjustedPTS(offset: CMTime) -> CMSampleBuffer? {
        let sampleCount = CMSampleBufferGetNumSamples(self)
        var timingInfos = [CMSampleTimingInfo](repeating: .invalid, count: sampleCount)
        CMSampleBufferGetSampleTimingInfoArray(self, entryCount: sampleCount, arrayToFill: &timingInfos, entriesNeededOut: nil)

        // Subtract the first-sample offset so audio is time-aligned with video (both start at .zero).
        for i in 0..<sampleCount {
            timingInfos[i].presentationTimeStamp = CMTimeSubtract(timingInfos[i].presentationTimeStamp, offset)
            if CMTIME_IS_VALID(timingInfos[i].decodeTimeStamp) {
                timingInfos[i].decodeTimeStamp = CMTimeSubtract(timingInfos[i].decodeTimeStamp, offset)
            }
        }

        var adjusted: CMSampleBuffer?
        CMSampleBufferCreateCopyWithNewTiming(
            allocator: kCFAllocatorDefault,
            sampleBuffer: self,
            sampleTimingEntryCount: sampleCount,
            sampleTimingArray: &timingInfos,
            sampleBufferOut: &adjusted
        )
        return adjusted
    }
}

// MARK: - Errors

@available(macOS 12.3, *)
public enum ScreenRecorderError: Error, Sendable {
    case noDisplayAvailable
    case notStarted
    case writeFailed(underlying: Error)
}

#else

// Stub for platforms where ScreenCaptureKit is unavailable.
@available(macOS 12.3, *)
public actor ScreenRecorder: NSObject {
    public struct Config: Sendable {
        public let outputURL: URL
        public let captureSystemAudio: Bool
        public let captureMicrophone: Bool
        public let microphoneDeviceUID: String?
        public let frameRate: Int
        public let scaleFactor: CGFloat
        public init(outputURL: URL, captureSystemAudio: Bool = true, captureMicrophone: Bool = false, microphoneDeviceUID: String? = nil, frameRate: Int = 24, scaleFactor: CGFloat = 1.0) {
            self.outputURL = outputURL; self.captureSystemAudio = captureSystemAudio
            self.captureMicrophone = captureMicrophone; self.microphoneDeviceUID = microphoneDeviceUID
            self.frameRate = frameRate; self.scaleFactor = scaleFactor
        }
    }
    public private(set) var micRecoveryGaveUp: Bool = false
    public override init() {}
    @discardableResult
    public func start(config: Config) async throws -> AsyncStream<AVAudioPCMBuffer>? { throw ScreenRecorderError.noDisplayAvailable }
    public func stop() async throws -> URL { throw ScreenRecorderError.noDisplayAvailable }
    public func setMicMuted(_ muted: Bool) {}
    public var isMicMuted: Bool { false }
    public var micFlowSnapshot: (count: Int, totalFrames: Int) { (0, 0) }
    nonisolated func handleSampleBuffer(_ sampleBuffer: CMSampleBuffer, ofType type: SCStreamOutputType) {}
}

public enum ScreenRecorderError: Error, Sendable {
    case noDisplayAvailable
    case notStarted
    case writeFailed(underlying: Error)
}

#endif

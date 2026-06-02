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
    private var firstSampleTime: CMTime?

    // MARK: - Init

    public override init() {
        super.init()
    }

    // MARK: - Public API

    public func start(config: Config) async throws {
        self.config = config
        pendingSampleTasks.open()
        screenRecorderLog.info("ScreenRecorder.start: outputURL=\(config.outputURL.path, privacy: .public) hevc=\(config.useHEVC, privacy: .public) videoBitrate=\(config.videoBitrate, privacy: .public) audio=\(config.captureSystemAudio, privacy: .public) fps=\(config.frameRate, privacy: .public)")

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

        // Configure SCStream for video + optional audio.
        let streamConfig = SCStreamConfiguration()
        streamConfig.width = width
        streamConfig.height = height
        streamConfig.minimumFrameInterval = CMTime(value: 1, timescale: Int32(config.frameRate))
        streamConfig.pixelFormat = kCVPixelFormatType_32BGRA
        streamConfig.capturesAudio = config.captureSystemAudio
        streamConfig.excludesCurrentProcessAudio = true  // may be ignored on macOS 26+
        streamConfig.sampleRate = config.audioSampleRate
        streamConfig.channelCount = 1

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

        let scStream = SCStream(filter: filter, configuration: streamConfig, delegate: nil)
        do {
            try scStream.addStreamOutput(output, type: .screen, sampleHandlerQueue: .global(qos: .userInteractive))
            if config.captureSystemAudio {
                try scStream.addStreamOutput(output, type: .audio, sampleHandlerQueue: .global(qos: .userInitiated))
            }
            try await scStream.startCapture()
        } catch {
            screenRecorderLog.error("ScreenRecorder.start: SCStream.startCapture failed — \(error.localizedDescription, privacy: .public)")
            throw error
        }
        self.stream = scStream
        screenRecorderLog.info("ScreenRecorder.start: SCStream capturing, awaiting first frame")
    }

    private static func selectDisplay(from displays: [SCDisplay], preferredID: UInt32) -> SCDisplay? {
        if preferredID != 0,
           let preferred = displays.first(where: { $0.displayID == preferredID }) {
            return preferred
        }
        return displays.first
    }

    /// Stop capture, finalize the MP4, and return the output URL.
    @discardableResult
    public func stop() async throws -> URL {
        guard let scStream = stream else {
            screenRecorderLog.error("ScreenRecorder.stop: not started")
            throw ScreenRecorderError.notStarted
        }
        do {
            try await scStream.stopCapture()
        } catch {
            screenRecorderLog.error("ScreenRecorder.stop: SCStream.stopCapture threw — \(error.localizedDescription, privacy: .public) (continuing to finalize writer)")
        }
        stream = nil
        streamOutput = nil

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

    /// Bag of in-flight `_handleSampleBuffer` tasks. The bag is recorded
    /// synchronously inside the nonisolated entry point (no actor hop), so
    /// `stop()` can `await` every queued task before tearing down the writer.
    /// Without this, Tasks queued behind the actor could land *after*
    /// `writer.finishWriting()` and corrupt the tail of `screen.mp4`.
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
                aInput.append(adjusted)
            }

        case .microphone:
            // Added in macOS 15 SDK — SCStream can emit a synchronized mic
            // track. We don't enable it (capturesAudio is the only output
            // type we configure), but the case must exist to keep Swift 6's
            // exhaustive-switch happy.
            break

        @unknown default:
            break
        }
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

/// Lock-protected bag of in-flight sample-handler Tasks. Recorded
/// synchronously inside `ScreenRecorder.handleSampleBuffer` (which is
/// `nonisolated`) so `stop()` can `drain()` and `await` every queued task
/// before tearing down the writer. Without this, Tasks queued behind the
/// actor land *after* `writer.finishWriting()` and corrupt the tail of
/// `screen.mp4`.
@available(macOS 12.3, *)
final class SCSampleTaskBag: @unchecked Sendable {
    private final class Entry {
        var task: Task<Void, Never>?
    }

    private let lock = NSLock()
    private var tasks: [UInt64: Entry] = [:]
    private var nextID: UInt64 = 0
    private var closed = false

    var activeTaskCount: Int {
        lock.lock()
        let count = tasks.count
        lock.unlock()
        return count
    }

    func open() {
        lock.lock()
        tasks.removeAll()
        closed = false
        lock.unlock()
    }

    @discardableResult
    func add(_ operation: @escaping @Sendable () async -> Void) -> Task<Void, Never>? {
        lock.lock()
        guard !closed else {
            lock.unlock()
            return nil
        }

        let id = nextID
        nextID &+= 1
        let entry = Entry()
        tasks[id] = entry
        lock.unlock()

        let task = Task<Void, Never> { [weak self] in
            defer { self?.remove(id: id) }
            await operation()
        }

        lock.lock()
        guard !closed, tasks[id] === entry else {
            lock.unlock()
            task.cancel()
            return nil
        }
        entry.task = task
        lock.unlock()
        return task
    }

    func drain() -> [Task<Void, Never>] {
        lock.lock()
        closed = true
        let out = tasks.values.compactMap(\.task)
        tasks.removeAll()
        lock.unlock()
        return out
    }

    private func remove(id: UInt64) {
        lock.lock()
        tasks[id] = nil
        lock.unlock()
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
        public let frameRate: Int
        public let scaleFactor: CGFloat
        public init(outputURL: URL, captureSystemAudio: Bool = true, frameRate: Int = 24, scaleFactor: CGFloat = 1.0) {
            self.outputURL = outputURL; self.captureSystemAudio = captureSystemAudio
            self.frameRate = frameRate; self.scaleFactor = scaleFactor
        }
    }
    public override init() {}
    public func start(config: Config) async throws { throw ScreenRecorderError.noDisplayAvailable }
    public func stop() async throws -> URL { throw ScreenRecorderError.noDisplayAvailable }
    nonisolated func handleSampleBuffer(_ sampleBuffer: CMSampleBuffer, ofType type: SCStreamOutputType) {}
}

public enum ScreenRecorderError: Error, Sendable {
    case noDisplayAvailable
    case notStarted
    case writeFailed(underlying: Error)
}

#endif

@preconcurrency import AVFoundation
import Foundation
import os

private let segmentWriterLog = Logger(subsystem: "dev.kosmonotes.studio", category: "SegmentWriter")

// MARK: - AudioSource

/// Identifies which capture source produced a PCM buffer.
public enum AudioSource: Sendable, Equatable, Hashable {
    /// Microphone input (track 0 in the segment .m4a).
    case mic
    /// System audio (whole-system SCKit mixdown — track 1 in the segment .m4a).
    case system
}

// MARK: - SegmentWriter

/// Writes 5-second rolling segments to `<sessionDir>/segments/<n>.m4a`.
///
/// Each segment is an MPEG-4 file written via `AVAssetWriter` with up to 2 audio inputs:
///   - Track 0: mic PCM (AAC-encoded via AVAssetWriterInput)
///   - Track 1: system audio PCM (AAC-encoded, only present when system audio is active)
///
/// Crash-safety: each segment is finalized (fsync'd by AVAssetWriter on `finishWriting()`)
/// before the next one opens. Maximum data loss on SIGKILL is one partially-written
/// segment (≤5 s).
public actor SegmentWriter {

    // MARK: Types

    public enum SegmentWriterError: Error, Sendable {
        case segmentsDirCreationFailed(underlying: Error)
        case assetWriterCreationFailed(underlying: Error)
        case assetWriterInputCreationFailed
        case assetWriterStartFailed
        case assetWriterFinishFailed
    }

    // MARK: Private state

    private let sessionDir: URL
    private let segmentsDir: URL
    private let segmentDuration: Double
    private let sampleRate: Double
    private let audioFormatID: AudioFormatID
    private let audioBitrate: Int

    private var segmentIndex: Int = 0
    private var segmentPaths: [URL] = []

    // Current segment state
    private var assetWriter: AVAssetWriter?
    private var micInput: AVAssetWriterInput?
    private var systemInput: AVAssetWriterInput?
    /// Per-source sample counters. Each track in the .m4a needs its own
    /// monotonic PTS starting at 0. Sharing one counter for both sources
    /// (the previous bug) compressed system PTS into mic's accumulating
    /// offset, which de-synced the two tracks and rolled segments at
    /// roughly half the configured duration when both sources were active.
    private var micSampleCount: Int64 = 0
    private var systemSampleCount: Int64 = 0

    /// Reentrancy guard for `finalizeCurrentSegment`. While this is `true`,
    /// buffered `append()` calls that re-enter the actor during the
    /// `await writer.finishWriting()` suspension drop their PCM data
    /// instead of trying to write to inputs that have already received
    /// `markAsFinished()`. Without this, the second task's append hits
    /// `_transitionToClientInitiatedTerminalStatus` and aborts the process.
    private var finalizing: Bool = false
    /// Once `close()` has been requested, this writer is terminal. Late
    /// producer tasks may still call `append()` after stop teardown; they must
    /// not reopen a fresh segment behind the caller's back.
    private var closed: Bool = false

    // MARK: Init

    public init(
        sessionDir: URL,
        segmentDurationSeconds: Double = 5.0,
        sampleRate: Double = 48_000,
        audioFormatID: AudioFormatID = kAudioFormatMPEG4AAC,
        audioBitrate: Int = 96_000
    ) throws {
        self.sessionDir = sessionDir
        self.segmentDuration = segmentDurationSeconds
        self.sampleRate = sampleRate
        // .m4a container only carries AAC-family codecs (kAudioFormatMPEG4AAC,
        // kAudioFormatMPEG4AAC_HE, kAudioFormatMPEG4AAC_HE_V2). Opus would need
        // a different container — silently substitute HE-AAC if requested.
        if audioFormatID == kAudioFormatOpus {
            self.audioFormatID = kAudioFormatMPEG4AAC_HE
        } else {
            self.audioFormatID = audioFormatID
        }
        self.audioBitrate = audioBitrate
        self.segmentsDir = sessionDir.appendingPathComponent("segments")

        do {
            try FileManager.default.createDirectory(at: segmentsDir, withIntermediateDirectories: true)
        } catch {
            throw SegmentWriterError.segmentsDirCreationFailed(underlying: error)
        }

        // Resume after pause: find the highest existing segment index and start after it.
        let existing = (try? FileManager.default.contentsOfDirectory(atPath: segmentsDir.path)) ?? []
        let maxIndex = existing
            .compactMap { name -> Int? in
                guard name.hasSuffix(".m4a") else { return nil }
                return Int(name.dropLast(4))
            }
            .max()
        self.segmentIndex = maxIndex.map { $0 + 1 } ?? 0
    }

    // MARK: Public API

    /// Append a PCM buffer from the given source. Opens a new segment if needed.
    public func append(_ pcmBuffer: AVAudioPCMBuffer, source: AudioSource) async throws {
        if closed {
            segmentWriterLog.debug("SegmentWriter.append: writer already closed; dropping late buffer")
            return
        }

        // While the previous segment is still being finalized (the
        // `await writer.finishWriting()` suspension below in
        // `finalizeCurrentSegment`), the actor allows queued `append` calls
        // to re-enter. Inputs have already been `markAsFinished`'d, so any
        // append against them would throw an AVAssetWriter exception. Drop
        // the buffer; ~tens of ms of audio loss per roll, which is invisible
        // for the use case (transcription doesn't notice).
        if finalizing { return }

        // Defense in depth: AAC track in the .m4a is declared at `sampleRate`
        // and `toCMSampleBuffer` writes its CMSampleBuffer's ASBD with the
        // same rate. If a buffer arrives at a different rate (e.g. the
        // upstream AudioEngine's converter failed silently after a route
        // change, or someone wired raw HFP/SCO 16 kHz buffers directly here)
        // and we wrote it as if it were 48 kHz, playback would render at the
        // wrong speed — the "slow + bassy" artifact. Dropping the buffer
        // costs ~100 ms of audio; writing it would corrupt the whole segment.
        let bufferRate = pcmBuffer.format.sampleRate
        if abs(bufferRate - sampleRate) > 0.01 {
            segmentWriterLog.error("SegmentWriter.append: rate mismatch — buffer=\(bufferRate, privacy: .public) configured=\(self.sampleRate, privacy: .public) source=\(String(describing: source), privacy: .public). Dropping to prevent corrupt 'slow-bassy' playback. Upstream AudioEngine should be converting before delivery.")
            return
        }

        if assetWriter == nil {
            try openNewSegment()
        }

        switch source {
        case .mic:
            appendBuffer(pcmBuffer, to: micInput, sampleOffset: micSampleCount)
            micSampleCount += Int64(pcmBuffer.frameLength)
        case .system:
            appendBuffer(pcmBuffer, to: systemInput, sampleOffset: systemSampleCount)
            systemSampleCount += Int64(pcmBuffer.frameLength)
        }

        // Roll on the leading source's elapsed time. For mic-only sessions this
        // is mic's count; for dual-source it's whichever has accumulated more.
        // Either way the segment's wall-clock duration ≈ segmentDuration.
        let leadingFrames = max(micSampleCount, systemSampleCount)
        let elapsed = Double(leadingFrames) / sampleRate

        if elapsed >= segmentDuration {
            try await rollSegment()
        }
    }

    /// Finalize the current segment and return all segment paths (in order).
    public func close() async throws -> [URL] {
        closed = true
        try await finalizeCurrentSegment()
        return segmentPaths
    }

    // MARK: Private helpers

    private func openNewSegment() throws {
        let url = segmentsDir.appendingPathComponent("\(segmentIndex).m4a")
        segmentWriterLog.info("SegmentWriter.openNewSegment: idx=\(self.segmentIndex, privacy: .public) url=\(url.path, privacy: .public) formatID=\(self.audioFormatID, privacy: .public) sampleRate=\(self.sampleRate, privacy: .public)")

        let writer: AVAssetWriter
        do {
            writer = try AVAssetWriter(outputURL: url, fileType: .m4a)
        } catch {
            segmentWriterLog.error("SegmentWriter.openNewSegment: AVAssetWriter init failed — \(error.localizedDescription, privacy: .public)")
            throw SegmentWriterError.assetWriterCreationFailed(underlying: error)
        }

        let aacSettings: [String: Any] = [
            AVFormatIDKey: audioFormatID,
            AVSampleRateKey: sampleRate,
            AVNumberOfChannelsKey: 1,
            AVEncoderBitRateKey: audioBitrate,
        ]

        // Track 0 — mic
        let mInput = AVAssetWriterInput(mediaType: .audio, outputSettings: aacSettings)
        mInput.expectsMediaDataInRealTime = true

        // Track 1 — system audio (2-track output per AC-5)
        let sInput = AVAssetWriterInput(mediaType: .audio, outputSettings: aacSettings)
        sInput.expectsMediaDataInRealTime = true

        guard writer.canAdd(mInput), writer.canAdd(sInput) else {
            segmentWriterLog.error("SegmentWriter.openNewSegment: canAdd failed (mic=\(writer.canAdd(mInput), privacy: .public) sys=\(writer.canAdd(sInput), privacy: .public)) — codec/sampleRate combination rejected by .m4a container")
            throw SegmentWriterError.assetWriterInputCreationFailed
        }
        writer.add(mInput)
        writer.add(sInput)

        let started = writer.startWriting()
        if !started || writer.status != .writing {
            segmentWriterLog.error("SegmentWriter.openNewSegment: startWriting() returned \(started, privacy: .public) status=\(writer.status.rawValue, privacy: .public) error=\(writer.error?.localizedDescription ?? "nil", privacy: .public)")
            throw SegmentWriterError.assetWriterStartFailed
        }
        writer.startSession(atSourceTime: .zero)

        assetWriter = writer
        micInput = mInput
        systemInput = sInput
        micSampleCount = 0
        systemSampleCount = 0
    }

    private func appendBuffer(_ buffer: AVAudioPCMBuffer, to input: AVAssetWriterInput?, sampleOffset: Int64) {
        guard let input = input else {
            segmentWriterLog.error("SegmentWriter.appendBuffer: input is nil")
            return
        }
        // Don't keep feeding a writer that already failed. A `.failed` writer
        // turns every subsequent `append()` into a logged no-op; the next
        // rollSegment() finalize call would have aborted the process before
        // the previous fix landed. Bail early so the next roll opens a
        // fresh writer cleanly.
        if let w = self.assetWriter, w.status != .writing {
            segmentWriterLog.debug("SegmentWriter.appendBuffer: writer status=\(w.status.rawValue, privacy: .public) — skipping append until next roll")
            return
        }
        guard input.isReadyForMoreMediaData else {
            // High-frequency event — log at debug only.
            segmentWriterLog.debug("SegmentWriter.appendBuffer: input not ready (status=\(self.assetWriter?.status.rawValue ?? -1, privacy: .public) error=\(self.assetWriter?.error?.localizedDescription ?? "nil", privacy: .public))")
            return
        }
        guard let sampleBuffer = buffer.toCMSampleBuffer(sampleOffset: sampleOffset, sampleRate: sampleRate) else {
            segmentWriterLog.error("SegmentWriter.appendBuffer: toCMSampleBuffer failed (frameLength=\(buffer.frameLength, privacy: .public))")
            return
        }
        let appended = input.append(sampleBuffer)
        if !appended {
            segmentWriterLog.error("SegmentWriter.appendBuffer: AVAssetWriterInput.append returned false — status=\(self.assetWriter?.status.rawValue ?? -1, privacy: .public) error=\(self.assetWriter?.error?.localizedDescription ?? "nil", privacy: .public)")
        }
    }

    private func rollSegment() async throws {
        try await finalizeCurrentSegment()
        segmentIndex += 1
    }

    private func finalizeCurrentSegment() async throws {
        guard let writer = assetWriter else {
            segmentWriterLog.info("SegmentWriter.finalizeCurrentSegment: no active writer to finalize (no buffers ever opened a segment)")
            return
        }

        let url = segmentsDir.appendingPathComponent("\(segmentIndex).m4a")

        // AVFoundation contract: `finishWriting()` is only valid when the
        // writer is in `.writing`. Calling it on `.failed` / `.cancelled`
        // throws an Obj-C exception (`-[AVAssetWriterHelper
        // _transitionToClientInitiatedTerminalStatus:]`) that aborts the
        // process. A bad upstream append (encoder rejection, malformed
        // PTS, etc.) can transition the writer to `.failed` silently —
        // `appendBuffer` only logs and continues. Cancel cleanly here
        // instead of pulling the trigger.
        guard writer.status == .writing else {
            segmentWriterLog.error(
                "SegmentWriter.finalizeCurrentSegment: writer not in .writing (status=\(writer.status.rawValue, privacy: .public) error=\(writer.error?.localizedDescription ?? "nil", privacy: .public)) — cancelling instead of finishing"
            )
            writer.cancelWriting()
            assetWriter = nil
            micInput = nil
            systemInput = nil
            return
        }

        // Set the reentrancy flag BEFORE markAsFinished + finishWriting.
        // While `await writer.finishWriting()` suspends below, the actor
        // can let other tasks' queued `append()` calls run. They'll see
        // `finalizing == true` and bail out cleanly instead of writing to
        // inputs that have already been finished.
        finalizing = true

        micInput?.markAsFinished()
        systemInput?.markAsFinished()

        await writer.finishWriting()

        assetWriter = nil
        micInput = nil
        systemInput = nil
        finalizing = false

        if writer.status == .completed {
            segmentPaths.append(url)
            segmentWriterLog.info("SegmentWriter.finalizeCurrentSegment: completed idx=\(self.segmentIndex, privacy: .public) total=\(self.segmentPaths.count, privacy: .public)")
        } else {
            segmentWriterLog.error("SegmentWriter.finalizeCurrentSegment: idx=\(self.segmentIndex, privacy: .public) status=\(writer.status.rawValue, privacy: .public) error=\(writer.error?.localizedDescription ?? "nil", privacy: .public)")
        }
    }
}

// MARK: - AVAudioPCMBuffer → CMSampleBuffer conversion

extension AVAudioPCMBuffer {

    /// Convert a mono Float32 PCM buffer to a `CMSampleBuffer` suitable for AVAssetWriterInput.
    ///
    /// Uses `CMBlockBufferCreateWithMemoryBlock` to wrap the PCM data directly,
    /// avoiding a copy when possible.
    func toCMSampleBuffer(sampleOffset: Int64, sampleRate: Double) -> CMSampleBuffer? {
        guard let channelData = self.floatChannelData else { return nil }
        let frameCount = Int(self.frameLength)
        guard frameCount > 0 else { return nil }

        var asbd = AudioStreamBasicDescription(
            mSampleRate: sampleRate,
            mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked | kAudioFormatFlagIsNonInterleaved,
            mBytesPerPacket: 4,
            mFramesPerPacket: 1,
            mBytesPerFrame: 4,
            mChannelsPerFrame: 1,
            mBitsPerChannel: 32,
            mReserved: 0
        )

        var formatDesc: CMAudioFormatDescription?
        guard CMAudioFormatDescriptionCreate(
            allocator: kCFAllocatorDefault,
            asbd: &asbd,
            layoutSize: 0,
            layout: nil,
            magicCookieSize: 0,
            magicCookie: nil,
            extensions: nil,
            formatDescriptionOut: &formatDesc
        ) == noErr, let formatDescription = formatDesc else { return nil }

        let dataSize = frameCount * 4  // 4 bytes per Float32 frame
        var blockBuffer: CMBlockBuffer?

        // Allocate block buffer memory
        guard CMBlockBufferCreateWithMemoryBlock(
            allocator: kCFAllocatorDefault,
            memoryBlock: nil,
            blockLength: dataSize,
            blockAllocator: kCFAllocatorDefault,
            customBlockSource: nil,
            offsetToData: 0,
            dataLength: dataSize,
            flags: 0,
            blockBufferOut: &blockBuffer
        ) == noErr, let block = blockBuffer else { return nil }

        // Copy PCM data into the block buffer
        let copyStatus = channelData[0].withMemoryRebound(to: UInt8.self, capacity: dataSize) { srcPtr in
            CMBlockBufferReplaceDataBytes(
                with: srcPtr,
                blockBuffer: block,
                offsetIntoDestination: 0,
                dataLength: dataSize
            )
        }
        guard copyStatus == noErr else { return nil }

        let pts = CMTime(value: sampleOffset, timescale: CMTimeScale(sampleRate))

        var sampleBuffer: CMSampleBuffer?
        guard CMAudioSampleBufferCreateReadyWithPacketDescriptions(
            allocator: kCFAllocatorDefault,
            dataBuffer: block,
            formatDescription: formatDescription,
            sampleCount: frameCount,
            presentationTimeStamp: pts,
            packetDescriptions: nil,
            sampleBufferOut: &sampleBuffer
        ) == noErr else { return nil }

        return sampleBuffer
    }
}

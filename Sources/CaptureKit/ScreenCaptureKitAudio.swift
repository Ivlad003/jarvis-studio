@preconcurrency import AVFoundation
import Foundation

#if canImport(ScreenCaptureKit)
@preconcurrency import ScreenCaptureKit

// MARK: - SCKitAudioCapture

/// Captures whole-system audio mixdown via ScreenCaptureKit.
///
/// Delivers `AVAudioPCMBuffer` instances via an `AsyncStream`. The stream runs
/// until `stop()` is called.
///
/// TCC requirement: the app must have Screen Recording permission granted in
/// System Settings → Privacy & Security → Screen Recording. Without it,
/// `start()` throws `SCStreamError.userDeclined` (or similar).
///
/// Unit-test strategy: because TCC cannot be granted in CI, tests that call
/// `start()` are gated with `#if FEATURE_LIVE_AUDIO_TESTS`. The public API
/// compiles and the type wires up correctly — that is the CI-verifiable
/// invariant. Integration smoke tests are run manually.
///
/// - Note: Requires macOS 12.3+.
@available(macOS 12.3, *)
public actor SCKitAudioCapture: NSObject {

    // MARK: Private state

    private var stream: SCStream?
    private var continuation: AsyncStream<AVAudioPCMBuffer>.Continuation?
    private var streamOutput: AudioStreamOutput?

    // MARK: Init

    public override init() {}

    // MARK: Public API

    /// Start system-audio capture. Returns an `AsyncStream<AVAudioPCMBuffer>`.
    ///
    /// - Throws: `SCStreamError` if the stream cannot be started (e.g. TCC denied).
    public func start() async throws -> sending AsyncStream<AVAudioPCMBuffer> {
        let content = try await SCShareableContent.excludingDesktopWindows(
            false,
            onScreenWindowsOnly: true
        )

        let config = SCStreamConfiguration()
        config.capturesAudio = true
        config.excludesCurrentProcessAudio = true
        config.sampleRate = 48_000
        config.channelCount = 1

        guard let display = content.displays.first else {
            throw SCKitAudioCaptureError.noDisplayAvailable
        }
        let filter = SCContentFilter(display: display, excludingApplications: [], exceptingWindows: [])

        let (asyncStream, cont) = AsyncStream<AVAudioPCMBuffer>.makeStream()
        self.continuation = cont

        let output = AudioStreamOutput(continuation: cont)
        self.streamOutput = output

        let scStream = SCStream(filter: filter, configuration: config, delegate: nil)
        try scStream.addStreamOutput(output, type: .audio, sampleHandlerQueue: .global(qos: .userInitiated))
        try await scStream.startCapture()
        self.stream = scStream

        return asyncStream
    }

    /// Stop system-audio capture and finish the stream.
    public func stop() async {
        if let s = stream {
            try? await s.stopCapture()
        }
        stream = nil
        continuation?.finish()
        continuation = nil
        streamOutput = nil
    }
}

// MARK: - AudioStreamOutput (SCStreamOutput delegate)

@available(macOS 12.3, *)
private final class AudioStreamOutput: NSObject, SCStreamOutput, @unchecked Sendable {

    private let continuation: AsyncStream<AVAudioPCMBuffer>.Continuation

    init(continuation: AsyncStream<AVAudioPCMBuffer>.Continuation) {
        self.continuation = continuation
    }

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .audio else { return }
        guard let pcmBuffer = sampleBuffer.toAVAudioPCMBuffer() else { return }
        continuation.yield(pcmBuffer)
    }
}

// MARK: - AudioBufferList storage

final class AudioBufferListStorage {
    let byteCount: Int
    private let rawPointer: UnsafeMutableRawPointer
    let pointer: UnsafeMutablePointer<AudioBufferList>

    init?(byteCount: Int) {
        guard byteCount >= MemoryLayout<AudioBufferList>.size else { return nil }

        self.byteCount = byteCount
        self.rawPointer = UnsafeMutableRawPointer.allocate(
            byteCount: byteCount,
            alignment: max(16, MemoryLayout<AudioBufferList>.alignment)
        )
        self.rawPointer.initializeMemory(as: UInt8.self, repeating: 0, count: byteCount)
        self.pointer = rawPointer.bindMemory(to: AudioBufferList.self, capacity: 1)
    }

    deinit {
        rawPointer.deallocate()
    }
}

// MARK: - CMSampleBuffer → AVAudioPCMBuffer

extension CMSampleBuffer {
    /// Convert an audio `CMSampleBuffer` (as delivered by SCStream) to `AVAudioPCMBuffer`.
    fileprivate func toAVAudioPCMBuffer() -> AVAudioPCMBuffer? {
        guard let formatDesc = CMSampleBufferGetFormatDescription(self) else { return nil }
        guard let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(formatDesc) else { return nil }
        guard let avFormat = AVAudioFormat(streamDescription: asbd) else { return nil }

        let frameCount = AVAudioFrameCount(CMSampleBufferGetNumSamples(self))
        guard let pcmBuffer = AVAudioPCMBuffer(pcmFormat: avFormat, frameCapacity: frameCount) else { return nil }
        pcmBuffer.frameLength = frameCount

        // Get the size needed for the AudioBufferList
        var bufferListSize: Int = 0
        CMSampleBufferGetAudioBufferListWithRetainedBlockBuffer(
            self,
            bufferListSizeNeededOut: &bufferListSize,
            bufferListOut: nil,
            bufferListSize: 0,
            blockBufferAllocator: kCFAllocatorDefault,
            blockBufferMemoryAllocator: kCFAllocatorDefault,
            flags: 0,
            blockBufferOut: nil
        )

        guard bufferListSize > 0 else { return nil }

        guard let audioBufferListStorage = AudioBufferListStorage(byteCount: bufferListSize) else {
            return nil
        }
        let audioBufferListPtr = audioBufferListStorage.pointer

        var retainedBlock: CMBlockBuffer?
        let status = CMSampleBufferGetAudioBufferListWithRetainedBlockBuffer(
            self,
            bufferListSizeNeededOut: nil,
            bufferListOut: audioBufferListPtr,
            bufferListSize: bufferListSize,
            blockBufferAllocator: kCFAllocatorDefault,
            blockBufferMemoryAllocator: kCFAllocatorDefault,
            flags: kCMSampleBufferFlag_AudioBufferList_Assure16ByteAlignment,
            blockBufferOut: &retainedBlock
        )

        guard status == noErr else { return nil }
        // Keep retainedBlock alive for the duration of the copy
        withExtendedLifetime((retainedBlock, audioBufferListStorage)) {
            let ablPtr = UnsafeMutableAudioBufferListPointer(audioBufferListPtr)
            if let floatChannelData = pcmBuffer.floatChannelData {
                for channelIndex in 0..<ablPtr.count {
                    let srcBuffer = ablPtr[channelIndex]
                    guard let srcData = srcBuffer.mData else { continue }
                    let byteCount = Int(srcBuffer.mDataByteSize)
                    floatChannelData[channelIndex].withMemoryRebound(to: UInt8.self, capacity: byteCount) { dst in
                        let srcPtr = srcData.assumingMemoryBound(to: UInt8.self)
                        dst.initialize(from: srcPtr, count: byteCount)
                    }
                }
            }
        }

        return pcmBuffer
    }
}

// MARK: - Errors

@available(macOS 12.3, *)
public enum SCKitAudioCaptureError: Error, Sendable {
    case noDisplayAvailable
    case streamStartFailed(underlying: Error)
}

#else

// Fallback stub for platforms where ScreenCaptureKit is unavailable.
@available(macOS 12.3, *)
public actor SCKitAudioCapture {
    public init() {}
    public func start() async throws -> sending AsyncStream<AVAudioPCMBuffer> {
        throw SCKitAudioCaptureError.noDisplayAvailable
    }
    public func stop() async {}
}

@available(macOS 12.3, *)
public enum SCKitAudioCaptureError: Error, Sendable {
    case noDisplayAvailable
    case streamStartFailed(underlying: Error)
}

#endif

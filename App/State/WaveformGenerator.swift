import AVFoundation
import AppKit
import Foundation

// MARK: - WaveformGenerator

/// Generates a downsampled mono waveform PNG from an `.m4a` audio file.
///
/// Pipeline:
///   1. Open the file via `AVAssetReader`.
///   2. Read PCM Float32 samples in chunks.
///   3. Bucket-average absolute amplitude into `bucketCount` buckets (default 256
///      — more than enough for a sidebar thumbnail; 1024 is overkill there).
///   4. Render via Core Graphics into a PNG cached at `<sessionDir>/thumb.png`.
///
/// Implemented as an actor so the heavy lifting runs off the main thread.
/// The output PNG is small (~3-6 KB) and cheap to load on subsequent renders.
@available(macOS 14.0, *)
public actor WaveformGenerator {

    public init() {}

    /// Width of the rendered PNG in pixels. Sidebar thumbs are ~140 pt wide,
    /// so 280 gives 2x sharpness on Retina without bloating disk.
    public static let renderWidth: Int = 280
    /// Height of the rendered PNG in pixels.
    public static let renderHeight: Int = 36

    /// Look up an existing thumbnail or generate one. Returns the PNG file URL.
    /// On failure (file missing, decode error) returns nil — caller falls back
    /// to a placeholder waveform icon.
    public func thumbnailURL(for sessionDir: URL, audioFile: URL) async -> URL? {
        let thumbURL = sessionDir.appendingPathComponent("thumb.png")
        if FileManager.default.fileExists(atPath: thumbURL.path) {
            return thumbURL
        }
        guard FileManager.default.fileExists(atPath: audioFile.path) else { return nil }

        do {
            let buckets = try await readBuckets(from: audioFile, count: Self.renderWidth)
            let png = renderPNG(buckets: buckets,
                                width: Self.renderWidth,
                                height: Self.renderHeight)
            try png.write(to: thumbURL, options: .atomic)
            return thumbURL
        } catch {
            return nil
        }
    }

    // MARK: - Sample reader

    /// Read the audio file and bucket-average absolute float samples into `count` buckets.
    /// Single-channel: when the asset is stereo we average left+right per frame.
    private func readBuckets(from url: URL, count bucketCount: Int) async throws -> [Float] {
        let asset = AVURLAsset(url: url)
        guard let track = try await asset.loadTracks(withMediaType: .audio).first else {
            throw WaveformError.noAudioTrack
        }

        let outputSettings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVLinearPCMBitDepthKey: 32,
            AVLinearPCMIsFloatKey: true,
            AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsNonInterleaved: false,
        ]

        let reader = try AVAssetReader(asset: asset)
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: outputSettings)
        output.alwaysCopiesSampleData = false
        reader.add(output)
        reader.startReading()
        // Cancel-on-throw insurance — if the bucket-fill loop below throws or
        // returns early, AVAssetReader's internal I/O resources stay alive
        // until the object is deallocated. cancelReading on a .completed
        // reader is a documented no-op, so it's safe to always run.
        defer {
            if reader.status != .completed {
                reader.cancelReading()
            }
        }

        // Stream-fill `bucketCount` slots. We don't know the total sample count up
        // front, so we use an online algorithm: keep a running sum + count per
        // bucket, advance to the next bucket once we've accumulated
        // `expectedSamplesPerBucket` samples. The expected count is computed from
        // the asset duration + sample rate.
        let duration = try await asset.load(.duration)
        let formatDescriptions = try await track.load(.formatDescriptions)
        var sampleRate: Double = 48_000  // sane default
        var channelCount: Int = 1
        if let firstFormat = formatDescriptions.first,
           let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(firstFormat)?.pointee {
            sampleRate = asbd.mSampleRate
            channelCount = max(1, Int(asbd.mChannelsPerFrame))
        }
        let totalSamples = max(1, Int(CMTimeGetSeconds(duration) * sampleRate))
        let samplesPerBucket = max(1, totalSamples / bucketCount)

        var buckets = [Float](repeating: 0, count: bucketCount)
        var bucketIndex = 0
        var bucketSum: Float = 0
        var bucketCountSamples: Int = 0

        while reader.status == .reading, let sampleBuffer = output.copyNextSampleBuffer() {
            guard let blockBuffer = CMSampleBufferGetDataBuffer(sampleBuffer) else { continue }
            var lengthAtOffset = 0
            var totalLength = 0
            var dataPointer: UnsafeMutablePointer<Int8>? = nil
            let status = CMBlockBufferGetDataPointer(
                blockBuffer,
                atOffset: 0,
                lengthAtOffsetOut: &lengthAtOffset,
                totalLengthOut: &totalLength,
                dataPointerOut: &dataPointer
            )
            guard status == kCMBlockBufferNoErr, let raw = dataPointer else { continue }

            let count = totalLength / MemoryLayout<Float>.size
            raw.withMemoryRebound(to: Float.self, capacity: count) { fp in
                let frameCount = count / channelCount
                for frameIndex in 0..<frameCount {
                    var frameSum: Float = 0
                    let base = frameIndex * channelCount
                    for channelIndex in 0..<channelCount {
                        frameSum += abs(fp[base + channelIndex])
                    }
                    let v = frameSum / Float(channelCount)
                    bucketSum += v
                    bucketCountSamples += 1
                    if bucketCountSamples >= samplesPerBucket && bucketIndex < bucketCount {
                        buckets[bucketIndex] = bucketSum / Float(bucketCountSamples)
                        bucketIndex += 1
                        bucketSum = 0
                        bucketCountSamples = 0
                    }
                }
            }
        }

        // Tail: if we have leftover samples and an unfilled bucket, write them.
        if bucketCountSamples > 0, bucketIndex < bucketCount {
            buckets[bucketIndex] = bucketSum / Float(bucketCountSamples)
        }

        if reader.status == .failed {
            throw reader.error ?? WaveformError.readFailed
        }

        // Normalize so the loudest bucket is 1.0 — improves visual contrast on
        // quiet recordings. Avoids dividing by zero on silent files.
        if let maxValue = buckets.max(), maxValue > 0 {
            for i in 0..<buckets.count { buckets[i] /= maxValue }
        }
        return buckets
    }

    nonisolated static func averageInterleavedFrameAmplitudes(_ samples: [Float], channelCount: Int) -> [Float] {
        let channels = max(1, channelCount)
        let frameCount = samples.count / channels
        guard frameCount > 0 else { return [] }
        return (0..<frameCount).map { frameIndex in
            let base = frameIndex * channels
            var sum: Float = 0
            for channelIndex in 0..<channels {
                sum += abs(samples[base + channelIndex])
            }
            return sum / Float(channels)
        }
    }

    // MARK: - PNG renderer

    /// Render `buckets` as a centered horizontal waveform into a PNG.
    private func renderPNG(buckets: [Float], width: Int, height: Int) -> Data {
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        let bitmapInfo = CGImageAlphaInfo.premultipliedLast.rawValue
        guard let context = CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: colorSpace,
            bitmapInfo: bitmapInfo
        ) else { return Data() }

        // Transparent background.
        context.clear(CGRect(x: 0, y: 0, width: width, height: height))

        let midY = CGFloat(height) / 2
        let strokeColor = CGColor(red: 0.42, green: 0.51, blue: 0.95, alpha: 1.0)
        context.setStrokeColor(strokeColor)
        context.setLineWidth(1.0)
        context.setLineCap(.round)

        let columnWidth = CGFloat(width) / CGFloat(buckets.count)
        for (i, amp) in buckets.enumerated() {
            let h = max(CGFloat(amp) * (CGFloat(height) - 2), 1)
            let x = CGFloat(i) * columnWidth + columnWidth / 2
            context.move(to: CGPoint(x: x, y: midY - h / 2))
            context.addLine(to: CGPoint(x: x, y: midY + h / 2))
        }
        context.strokePath()

        guard let image = context.makeImage() else { return Data() }
        let rep = NSBitmapImageRep(cgImage: image)
        return rep.representation(using: .png, properties: [:]) ?? Data()
    }
}

// MARK: - Errors

@available(macOS 14.0, *)
public enum WaveformError: Error {
    case noAudioTrack
    case readFailed
}

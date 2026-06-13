@preconcurrency import AVFoundation
import Accelerate
import AudioDSP
import Foundation
import os

private let mixerLog = Logger(subsystem: "dev.kosmonotes.studio", category: "ScreenAudioMixer")

// MARK: - ScreenAudioMixer

/// Post-process step that rebuilds `screen.mp4` as video + a balanced audio mix
/// of the near-end voice and the system (remote) audio.
///
/// Why PCM-level, not track-volume mixing: the single-HAL SCStream microphone
/// output is entangled with the system-audio capture — `audio.m4a` (track 0,
/// "mic") actually contains BOTH the near-end voice AND a bit-exact, zero-delay
/// digital copy of the system audio (confirmed on-device 2026-06-13). Simply
/// summing that mic with the separate system track doubled the remote voice
/// (audible "echo"); using the mic alone left the near-end voice buried under
/// the loud system copy.
///
/// Since the two streams share the SCStream clock, the system copy inside the
/// mic is sample-aligned with the dedicated system track. So we isolate the
/// near-end by least-squares subtraction — `near = mic - g·system` — then remix
/// `near·micVolume + system·systemVolume` at controlled levels. This is done
/// offline on decoded PCM (no real-time/HAL constraints, exact alignment).
///
/// Failure is non-fatal — caller should swallow errors and leave the original
/// `screen.mp4` in place.
public enum ScreenAudioMixer {

    public enum MixError: Error, Sendable {
        case noVideoTrack
        case exportSessionInitFailed
        case exportFailed(underlying: Error?)
        case replaceFailed(underlying: Error)
        case decodeFailed
        case encodeFailed
    }

    private static let workSampleRate = 48_000.0

    /// Rebuild `screenMP4` in place with a balanced near-end + system mix.
    /// Atomic: writes to a sibling temp file and replaces only on success.
    ///
    /// - Parameters:
    ///   - micVolume: gain for the isolated near-end voice (default 1.8 — the
    ///     near-end is captured acoustically and is quieter than the digital
    ///     system copy, so it is boosted).
    ///   - systemVolume: gain for the clean system/remote audio (default 0.6 so
    ///     it is clearly present without burying the near-end).
    public static func mixMicInto(
        screenMP4: URL,
        audioM4A: URL,
        micVolume: Float = 1.8,
        systemVolume: Float = 0.6
    ) async throws {
        mixerLog.info("ScreenAudioMixer.mixMicInto: screen=\(screenMP4.lastPathComponent, privacy: .public) audio=\(audioM4A.lastPathComponent, privacy: .public)")

        let screenAsset = AVURLAsset(url: screenMP4)
        let audioAsset = AVURLAsset(url: audioM4A)

        // Mic track (audio.m4a track 0) = near_end + system (entangled).
        let micTracks = try await audioAsset.loadTracks(withMediaType: .audio)
        guard let micTrack = micTracks.first else {
            mixerLog.error("ScreenAudioMixer.mixMicInto: audio.m4a has no audio track — leaving screen.mp4 unchanged")
            return
        }
        let mic = try await decodeMonoPCM(track: micTrack, sampleRate: workSampleRate)
        guard !mic.isEmpty else {
            mixerLog.error("ScreenAudioMixer.mixMicInto: decoded mic is empty — leaving screen.mp4 unchanged")
            return
        }

        // Mic-only. On speakers the SCStream mic already captures BOTH the
        // near-end voice AND the system audio (digitally bit-exact and/or
        // acoustically via the room), so the mic IS the complete meeting audio.
        // Adding screen.mp4's separate system track on top doubled the remote
        // voice — a bit-exact copy ("echo") when the bleed was digital, or a
        // reverberant comb ("barrel") when it was acoustic. Single-delay
        // subtraction only fixes the digital case; the acoustic room echo needs
        // a multi-tap AEC (not yet implemented). Until then, mic-only is the
        // reliable choice: both voices present, never doubled. `micVolume` lets
        // the whole thing be lifted since the acoustic near-end can be quiet.
        // (isolateNearEnd / remix remain as tested building blocks for a future
        // proper AEC.) See design notes 2026-06-13.
        _ = (micVolume, systemVolume)

        // Peak-normalize to ~-3 dBFS so the acoustically-captured near-end voice
        // is comfortably audible (it tends to be quieter than the system). Gain
        // is capped so near-silent recordings aren't blown up, and the target is
        // below full scale so it never clips. Adapts per-recording (quiet → lift,
        // loud → tame) rather than a fixed boost.
        var peak: Float = 0
        vDSP_maxmgv(mic, 1, &peak, vDSP_Length(mic.count))
        var finalAudio = mic
        if peak > 1e-4 {
            var gain = min(Float(4), Float(0.7) / peak)
            vDSP_vsmul(mic, 1, &gain, &finalAudio, 1, vDSP_Length(mic.count))
            mixerLog.info("ScreenAudioMixer.mixMicInto: mic-only, normalized peak=\(peak, privacy: .public) gain=\(gain, privacy: .public)")
        }

        // Write the processed audio to a temp file, then mux with the video.
        let mixAudioURL = screenMP4.deletingPathExtension().appendingPathExtension("mixaudio.caf")
        try? FileManager.default.removeItem(at: mixAudioURL)
        try writeMonoPCM(finalAudio, sampleRate: workSampleRate, to: mixAudioURL)
        defer { try? FileManager.default.removeItem(at: mixAudioURL) }

        // Compose: video from screen.mp4 + the processed audio.
        let composition = AVMutableComposition()
        let videoTracks = try await screenAsset.loadTracks(withMediaType: .video)
        guard let sourceVideo = videoTracks.first else {
            mixerLog.error("ScreenAudioMixer.mixMicInto: screen.mp4 has no video track")
            throw MixError.noVideoTrack
        }
        let videoDuration = try await screenAsset.load(.duration)
        let composedVideo = composition.addMutableTrack(withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid)
        try composedVideo?.insertTimeRange(CMTimeRange(start: .zero, duration: videoDuration), of: sourceVideo, at: .zero)
        composedVideo?.preferredTransform = try await sourceVideo.load(.preferredTransform)

        let mixAsset = AVURLAsset(url: mixAudioURL)
        if let mixAudioTrack = try await mixAsset.loadTracks(withMediaType: .audio).first {
            let audioDuration = try await mixAsset.load(.duration)
            let window = CMTimeMinimum(videoDuration, audioDuration)
            let composedAudio = composition.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid)
            try composedAudio?.insertTimeRange(CMTimeRange(start: .zero, duration: window), of: mixAudioTrack, at: .zero)
        }

        // Export (re-encodes LPCM → AAC); passthrough can't, so use HighestQuality.
        let tmpURL = screenMP4.deletingPathExtension().appendingPathExtension("mixed.mp4")
        try? FileManager.default.removeItem(at: tmpURL)
        guard let exporter = AVAssetExportSession(asset: composition, presetName: AVAssetExportPresetHighestQuality) else {
            mixerLog.error("ScreenAudioMixer: AVAssetExportSession init failed")
            throw MixError.exportSessionInitFailed
        }
        exporter.outputURL = tmpURL
        exporter.outputFileType = .mp4
        try await runExport(exporter)

        do {
            _ = try FileManager.default.replaceItemAt(screenMP4, withItemAt: tmpURL)
            mixerLog.info("ScreenAudioMixer.mixMicInto: success — screen.mp4 rebuilt with balanced near-end + system mix")
        } catch {
            try? FileManager.default.removeItem(at: tmpURL)
            mixerLog.error("ScreenAudioMixer.mixMicInto: replace failed — \(error.localizedDescription, privacy: .public)")
            throw MixError.replaceFailed(underlying: error)
        }
    }

    // MARK: - Near-end isolation (PCM)

    /// `near = mic - g·system`, where `system` is integer-aligned to `mic` and
    /// `g` is the least-squares gain of the system copy present in the mic.
    /// Both streams share the SCStream clock, so the offset is ~0; a small
    /// search refines it. Returns `mic` unchanged if there is no usable system.
    /// Isolate the near-end voice: `near = mic - g·system`, where `g` is the
    /// least-squares amount of the (aligned) system present in the mic.
    ///
    /// This works whether or not the SCStream mic bled the system audio — and
    /// crucially that bleed is INCONSISTENT across recordings (sometimes a
    /// bit-exact copy, sometimes none):
    ///   - mic = near + system (g ≈ 1): the system copy is removed → clean near.
    ///   - mic = near       (g ≈ 0): nothing is subtracted → near = mic.
    /// The caller then ALWAYS adds the clean system back, so the result is
    /// `near + system` in every case — both voices, never doubled, never dropped.
    static func isolateNearEnd(mic: [Float], system: [Float]) -> [Float] {
        let n = min(mic.count, system.count)
        guard n > 0 else { return mic }

        let offset = alignmentOffset(mic: mic, system: system)
        var aligned = [Float](repeating: 0, count: n)
        for i in 0..<n {
            let j = i - offset
            if j >= 0 && j < system.count { aligned[i] = system[j] }
        }

        var dot: Float = 0
        var energy: Float = 0
        vDSP_dotpr(mic, 1, aligned, 1, &dot, vDSP_Length(n))
        vDSP_dotpr(aligned, 1, aligned, 1, &energy, vDSP_Length(n))
        // The system copy is ~unity gain; clamp to [0, 1.2]. g≈0 ⇒ clean mic
        // (subtract nothing); g≈1 ⇒ full bleed (remove it).
        let gain = energy > 1e-9 ? max(0, min(1.2, dot / energy)) : 0
        mixerLog.info("ScreenAudioMixer.isolateNearEnd: offset=\(offset, privacy: .public) gain=\(gain, privacy: .public)")

        var near = [Float](repeating: 0, count: n)
        var negGain = -gain
        vDSP_vsma(aligned, 1, &negGain, mic, 1, &near, 1, vDSP_Length(n))
        return near
    }

    /// Integer sample offset of `system` relative to `mic` (positive = mic lags
    /// system), found over a large range via GCC-PHAT on a windowed slice. The
    /// two files are finalized separately, so the offset can be tens to hundreds
    /// of ms — a small linear search misses it (gain → 0).
    private static func alignmentOffset(mic: [Float], system: [Float]) -> Int {
        let n = min(mic.count, system.count)
        let fftSize = 131_072                              // ~2.7 s @ 48 kHz
        let win = min(n, fftSize)
        guard win >= 2 else { return 0 }
        let start = max(0, (n - win) / 2)
        return estimateDelayGCCPHAT(
            reference: Array(system[start..<start + win]),
            microphone: Array(mic[start..<start + win]),
            fftSize: fftSize,
            maxDelaySamples: min(win / 2, 96_000)          // ±2 s
        )
    }

    /// `final = clamp(near·micVolume + system·systemVolume)`.
    static func remix(nearEnd: [Float], system: [Float], micVolume: Float, systemVolume: Float) -> [Float] {
        let n = max(nearEnd.count, system.count)
        var out = [Float](repeating: 0, count: n)
        for i in 0..<n {
            let near = i < nearEnd.count ? nearEnd[i] : 0
            let sys = i < system.count ? system[i] : 0
            out[i] = min(1, max(-1, near * micVolume + sys * systemVolume))
        }
        return out
    }

    // MARK: - PCM I/O

    /// Decode an audio track to mono Float32 PCM at `sampleRate` via AVAssetReader.
    private static func decodeMonoPCM(track: AVAssetTrack, sampleRate: Double) async throws -> [Float] {
        let asset = track.asset ?? AVMutableComposition()
        guard let reader = try? AVAssetReader(asset: asset) else { throw MixError.decodeFailed }
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: sampleRate,
            AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 32,
            AVLinearPCMIsFloatKey: true,
            AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsNonInterleaved: false
        ]
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: settings)
        output.alwaysCopiesSampleData = false
        guard reader.canAdd(output) else { throw MixError.decodeFailed }
        reader.add(output)
        guard reader.startReading() else { throw MixError.decodeFailed }

        var samples: [Float] = []
        while let sampleBuffer = output.copyNextSampleBuffer() {
            guard let blockBuffer = CMSampleBufferGetDataBuffer(sampleBuffer) else {
                CMSampleBufferInvalidate(sampleBuffer)
                continue
            }
            let length = CMBlockBufferGetDataLength(blockBuffer)
            if length > 0 {
                var bytes = [UInt8](repeating: 0, count: length)
                CMBlockBufferCopyDataBytes(blockBuffer, atOffset: 0, dataLength: length, destination: &bytes)
                let count = length / MemoryLayout<Float>.size
                bytes.withUnsafeBytes { raw in
                    let floats = raw.bindMemory(to: Float.self)
                    samples.append(contentsOf: floats.prefix(count))
                }
            }
            CMSampleBufferInvalidate(sampleBuffer)
        }
        guard reader.status == .completed else { throw MixError.decodeFailed }
        return samples
    }

    /// Write mono Float32 PCM to a CAF file.
    private static func writeMonoPCM(_ samples: [Float], sampleRate: Double, to url: URL) throws {
        guard let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: sampleRate, channels: 1, interleaved: false) else {
            throw MixError.encodeFailed
        }
        let file = try AVAudioFile(forWriting: url, settings: format.settings)
        let chunk = 48_000
        var index = 0
        while index < samples.count {
            let count = min(chunk, samples.count - index)
            guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(count)) else {
                throw MixError.encodeFailed
            }
            buffer.frameLength = AVAudioFrameCount(count)
            if let channel = buffer.floatChannelData?[0] {
                for k in 0..<count { channel[k] = samples[index + k] }
            }
            try file.write(from: buffer)
            index += count
        }
    }

    /// Bridge AVAssetExportSession's old completion-handler API to async/await.
    private static func runExport(_ exporter: AVAssetExportSession) async throws {
        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            exporter.exportAsynchronously { cont.resume(returning: ()) }
        }
        if exporter.status != .completed {
            mixerLog.error("ScreenAudioMixer: exporter status=\(exporter.status.rawValue, privacy: .public) error=\(exporter.error?.localizedDescription ?? "nil", privacy: .public)")
            throw MixError.exportFailed(underlying: exporter.error)
        }
    }
}

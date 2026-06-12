import AVFoundation
import Foundation

// MARK: - RecoveryService

/// Finalizes orphan recording sessions left behind by an ungraceful exit
/// (SIGKILL, panic, lid-close before stop, etc.).
///
/// A session is considered an orphan when its directory contains
/// `segments/<n>.m4a` files but **no** finalized `audio.m4a`. The service
/// concatenates the segments losslessly via `AVMutableComposition` +
/// `AVAssetExportSession` (passthrough preset — no decode/re-encode).
///
/// This replaces the design-doc's bundled-ffmpeg approach: ffmpeg was needed
/// only because the original plan used Opus, and Opus packets cannot be
/// concatenated by AVFoundation. AAC-in-`.m4a` is natively concatenable, so
/// the recovery path stays inside AVFoundation — no 30 MB binary, no
/// bundle-size pressure on AC-16.
public actor RecoveryService {

    // MARK: Types

    /// A session whose segments exist on disk but were never finalized.
    public struct OrphanSession: Sendable, Equatable {
        public let id: String
        public let sessionDir: URL
        public let segmentURLs: [URL]

        public init(id: String, sessionDir: URL, segmentURLs: [URL]) {
            self.id = id
            self.sessionDir = sessionDir
            self.segmentURLs = segmentURLs
        }
    }

    public enum RecoveryError: Error, Sendable {
        case noSegmentsFound
        case compositionFailed
        case exportSessionCreationFailed
        case exportFailed(status: Int, underlying: String?)
        case audioFileAlreadyExists(URL)
    }

    // MARK: Init

    public init() {}

    // MARK: - Scan

    /// Scan `rootDir` (e.g. `~/Library/Application Support/KosmoNotes/recordings/`)
    /// for orphan sessions. A subdirectory `<sid>/` qualifies when:
    ///   - `<sid>/segments/` exists and contains at least one `.m4a` file, AND
    ///   - `<sid>/audio.m4a` does NOT exist.
    ///
    /// `activeSessionIDs` lets callers reuse the scanner outside launch-time
    /// recovery without racing a currently-recording session whose segments
    /// directory is intentionally present before `audio.m4a` exists.
    ///
    /// Segments are returned sorted by their numeric filename (`0.m4a`, `1.m4a`, ...).
    ///
    /// Pure filesystem traversal — `nonisolated` so callers don't pay actor-hop cost
    /// for what is effectively a stateless query.
    public nonisolated func scanForOrphans(
        rootDir: URL,
        activeSessionIDs: Set<String> = []
    ) throws -> [OrphanSession] {
        let fm = FileManager.default
        guard fm.fileExists(atPath: rootDir.path) else { return [] }

        let entries: [URL]
        do {
            entries = try fm.contentsOfDirectory(
                at: rootDir,
                includingPropertiesForKeys: [.isDirectoryKey],
                options: [.skipsHiddenFiles]
            )
        } catch {
            return []
        }

        var orphans: [OrphanSession] = []
        for entry in entries {
            var isDir: ObjCBool = false
            guard fm.fileExists(atPath: entry.path, isDirectory: &isDir), isDir.boolValue else { continue }
            let sessionID = entry.lastPathComponent
            guard !activeSessionIDs.contains(sessionID) else { continue }

            let audioFile = entry.appendingPathComponent("audio.m4a")
            if fm.fileExists(atPath: audioFile.path) { continue }

            let segmentsDir = entry.appendingPathComponent("segments")
            guard fm.fileExists(atPath: segmentsDir.path) else { continue }

            let segments = (try? fm.contentsOfDirectory(
                at: segmentsDir,
                includingPropertiesForKeys: nil
            )) ?? []

            let m4aSegments = segments
                .filter { $0.pathExtension == "m4a" }
                .sorted { lhs, rhs in
                    let li = Int(lhs.deletingPathExtension().lastPathComponent) ?? Int.max
                    let ri = Int(rhs.deletingPathExtension().lastPathComponent) ?? Int.max
                    return li < ri
                }

            guard !m4aSegments.isEmpty else { continue }

            orphans.append(OrphanSession(
                id: sessionID,
                sessionDir: entry,
                segmentURLs: m4aSegments
            ))
        }

        return orphans.sorted { $0.id < $1.id }
    }

    // MARK: - Finalize

    /// Concatenate `orphan.segmentURLs` into a single `<sessionDir>/audio.m4a`.
    ///
    /// Uses `AVMutableComposition` + `AVAssetExportSession` with
    /// `AVAssetExportPresetPassthrough` — no decode/re-encode, lossless.
    ///
    /// Multi-track segments (mic on track 0, system audio on track 1) are
    /// preserved: composition track 0 receives all source track-0 ranges,
    /// composition track 1 receives all source track-1 ranges. The output
    /// `.m4a` therefore retains the same 2-track structure as a normally-stopped
    /// recording.
    @discardableResult
    public nonisolated func finalize(_ orphan: OrphanSession) async throws -> URL {
        let outputURL = orphan.sessionDir.appendingPathComponent("audio.m4a")

        if FileManager.default.fileExists(atPath: outputURL.path) {
            throw RecoveryError.audioFileAlreadyExists(outputURL)
        }
        guard !orphan.segmentURLs.isEmpty else {
            throw RecoveryError.noSegmentsFound
        }

        let composition = AVMutableComposition()
        var insertTime: CMTime = .zero
        var insertedAnything = false

        for segmentURL in orphan.segmentURLs {
            let asset = AVURLAsset(url: segmentURL)

            let audioTracks: [AVAssetTrack]
            do {
                audioTracks = try await asset.loadTracks(withMediaType: .audio)
            } catch {
                // Corrupt segment — skip and keep going.
                continue
            }
            if audioTracks.isEmpty { continue }

            let duration: CMTime
            do {
                duration = try await asset.load(.duration)
            } catch {
                continue
            }
            guard duration.isValid, duration > .zero else { continue }

            let timeRange = CMTimeRange(start: .zero, duration: duration)
            var insertedSegmentTrack = false

            for (trackIdx, sourceTrack) in audioTracks.enumerated() {
                let compositionTrack = trackForIndex(trackIdx, in: composition)
                guard let compositionTrack else {
                    throw RecoveryError.compositionFailed
                }
                do {
                    try compositionTrack.insertTimeRange(timeRange, of: sourceTrack, at: insertTime)
                    insertedAnything = true
                    insertedSegmentTrack = true
                } catch {
                    // Per-track insert failure shouldn't tank the whole recovery —
                    // the user still gets the audio they can salvage.
                    continue
                }
            }

            if insertedSegmentTrack {
                insertTime = CMTimeAdd(insertTime, duration)
            }
        }

        guard insertedAnything else {
            throw RecoveryError.noSegmentsFound
        }

        // We use `AVAssetExportPresetAppleM4A` rather than `AVAssetExportPresetPassthrough`.
        // Passthrough fails with `Operation Stopped` (status .failed) on
        // multi-asset compositions in macOS 14+; AppleM4A re-encodes to AAC,
        // which for our AAC-source segments is effectively a no-op at the same
        // bitrate but goes through the well-tested encoding path.
        //
        // We use the legacy `exportAsynchronously` callback API wrapped in a
        // continuation rather than the parameter-less `await exporter.export()`,
        // because the latter is deprecated on macOS 15 and behaves
        // unreliably. Callback + continuation is bulletproof across macOS 14/15.
        guard let exporter = AVAssetExportSession(
            asset: composition,
            presetName: AVAssetExportPresetAppleM4A
        ) else {
            throw RecoveryError.exportSessionCreationFailed
        }
        exporter.outputURL = outputURL
        exporter.outputFileType = .m4a

        return try await runExport(exporter, outputURL: outputURL)
    }

    /// Run an `AVAssetExportSession` to completion via the legacy callback API,
    /// wrapped in a Swift continuation.
    private nonisolated func runExport(_ exporter: AVAssetExportSession, outputURL: URL) async throws -> URL {
        let box = AVAssetExportSessionBox(exporter: exporter, outputURL: outputURL)
        return try await withCheckedThrowingContinuation { (cont: CheckedContinuation<URL, Error>) in
            box.exporter.exportAsynchronously {
                switch box.exporter.status {
                case .completed:
                    cont.resume(returning: box.outputURL)
                default:
                    cont.resume(throwing: RecoveryError.exportFailed(
                        status: box.exporter.status.rawValue,
                        underlying: box.exporter.error?.localizedDescription
                    ))
                }
            }
        }
    }

    // MARK: - Private helpers

    /// Get the existing composition audio track at index `idx`, or add a new one.
    private nonisolated func trackForIndex(_ idx: Int, in composition: AVMutableComposition) -> AVMutableCompositionTrack? {
        let existing = composition.tracks(withMediaType: .audio)
        if idx < existing.count {
            return existing[idx]
        }
        // Add as many empty tracks as needed so the requested idx exists.
        var lastAdded: AVMutableCompositionTrack?
        for _ in existing.count...idx {
            lastAdded = composition.addMutableTrack(
                withMediaType: .audio,
                preferredTrackID: kCMPersistentTrackID_Invalid
            )
        }
        return lastAdded
    }
}

private final class AVAssetExportSessionBox: @unchecked Sendable {
    let exporter: AVAssetExportSession
    let outputURL: URL

    init(exporter: AVAssetExportSession, outputURL: URL) {
        self.exporter = exporter
        self.outputURL = outputURL
    }
}

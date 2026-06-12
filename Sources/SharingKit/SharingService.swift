import Foundation
import StorageKit

// MARK: - SharingService

/// Coordinates uploading session sidecars to S3 + presigning recipient URLs.
///
/// v1.0 ships a simple bundle layout: each session uploads as `<prefix>/<sid>/audio.m4a`
/// and (when present) `<prefix>/<sid>/summary.md`. Recipients get a list of presigned
/// URLs they can open in a browser.
public struct SharingService: Sendable {

    public let s3: S3Client
    public let keyPrefix: String   // e.g. "jarvis-note/" — namespaces bucket use across users
    public let presignTTLSeconds: Int

    public init(s3: S3Client, keyPrefix: String = "jarvis-note/", presignTTLSeconds: Int = 7 * 24 * 3600) {
        self.s3 = s3
        // Normalize: ensure prefix ends with `/` so concatenation produces clean keys.
        var normalized = keyPrefix
        if !normalized.isEmpty, !normalized.hasSuffix("/") { normalized += "/" }
        self.keyPrefix = normalized
        self.presignTTLSeconds = presignTTLSeconds
    }

    // MARK: - Public API

    /// Result of a session share: presigned URLs for each artifact that was uploaded.
    public struct ShareResult: Sendable, Equatable {
        public let audioURL: URL?
        public let videoURL: URL?
        public let summaryURL: URL?
        public let transcriptURL: URL?

        public init(
            audioURL: URL?,
            videoURL: URL?,
            summaryURL: URL?,
            transcriptURL: URL?
        ) {
            self.audioURL = audioURL
            self.videoURL = videoURL
            self.summaryURL = summaryURL
            self.transcriptURL = transcriptURL
        }

        public var allLinks: [URL] {
            [audioURL, videoURL, summaryURL, transcriptURL].compactMap { $0 }
        }
    }

    /// Upload every artifact present on disk for the session — convenience for
    /// "share everything" callers. Delegates to the artifact-selecting overload
    /// after filtering `SharedArtifactKind.allCases` by file existence.
    public func shareSession(sessionDir: URL, sessionId: String) async throws -> ShareResult {
        let available = SharedArtifactKind.allCases.filter { kind in
            FileManager.default.fileExists(atPath: sessionDir.appendingPathComponent(kind.fileName).path)
        }
        return try await shareSession(sessionDir: sessionDir, sessionId: sessionId, artifacts: available)
    }

    /// Upload only the requested artifacts, then build presigned GET URLs for
    /// each successful upload. Files missing from disk are silently skipped —
    /// caller is expected to pre-filter via `availableShareArtifacts(for:)` if
    /// they want to enforce "all selected must exist".
    ///
    /// - Parameter sessionDir: filesystem dir containing the session sidecars.
    /// - Parameter sessionId: stable identifier; used as the S3 key suffix.
    /// - Parameter artifacts: which kinds to upload. Empty selection produces
    ///   an empty `ShareResult` — UI callers should validate non-empty before
    ///   invoking.
    public func shareSession(
        sessionDir: URL,
        sessionId: String,
        artifacts: [SharedArtifactKind]
    ) async throws -> ShareResult {
        let now = Date()
        let selected = Set(artifacts)

        let audioFile = sessionDir.appendingPathComponent("audio.m4a")
        let videoFile = sessionDir.appendingPathComponent("screen.mp4")
        let summaryFile = sessionDir.appendingPathComponent("summary.md")
        let transcriptFile = sessionDir.appendingPathComponent("transcript.txt")

        var audioURL: URL?
        var videoURL: URL?
        var summaryURL: URL?
        var transcriptURL: URL?

        if selected.contains(.audio), FileManager.default.fileExists(atPath: audioFile.path) {
            let key = "\(keyPrefix)\(sessionId)/audio.m4a"
            try await s3.putObject(key: key, fileURL: audioFile, contentType: "audio/mp4", now: now)
            audioURL = try s3.presignedGetURL(key: key, expirySeconds: presignTTLSeconds, now: now)
        }

        if selected.contains(.video), FileManager.default.fileExists(atPath: videoFile.path) {
            let key = "\(keyPrefix)\(sessionId)/screen.mp4"
            try await s3.putObject(key: key, fileURL: videoFile, contentType: "video/mp4", now: now)
            videoURL = try s3.presignedGetURL(key: key, expirySeconds: presignTTLSeconds, now: now)
        }

        if selected.contains(.summary), FileManager.default.fileExists(atPath: summaryFile.path) {
            let key = "\(keyPrefix)\(sessionId)/summary.md"
            try await s3.putObject(key: key, fileURL: summaryFile, contentType: "text/markdown; charset=utf-8", now: now)
            summaryURL = try s3.presignedGetURL(key: key, expirySeconds: presignTTLSeconds, now: now)
        }

        if selected.contains(.transcript), FileManager.default.fileExists(atPath: transcriptFile.path) {
            let key = "\(keyPrefix)\(sessionId)/transcript.txt"
            try await s3.putObject(key: key, fileURL: transcriptFile, contentType: "text/plain; charset=utf-8", now: now)
            transcriptURL = try s3.presignedGetURL(key: key, expirySeconds: presignTTLSeconds, now: now)
        }

        return ShareResult(
            audioURL: audioURL,
            videoURL: videoURL,
            summaryURL: summaryURL,
            transcriptURL: transcriptURL
        )
    }
}

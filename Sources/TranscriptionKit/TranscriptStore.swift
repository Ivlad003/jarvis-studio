import Foundation
import StorageKit

// MARK: - TranscriptStore

/// Persists `TranscriptSegment`s to a session's on-disk sidecars.
///
/// File layout:
///   - `<sessionDir>/transcript.jsonl` — one JSON object per line, only final
///     segments. Append-only during the session.
///   - `<sessionDir>/transcript.txt` — the human-readable plain-text view.
///     Rewritten atomically on every flush from accumulated final segments.
///
/// The store is an actor — concurrent appends from the receive task and
/// `flushTxt` calls from the UI never race.
public actor TranscriptStore {

    // MARK: Stored

    private let sessionDir: URL
    private let jsonlURL: URL
    private let txtURL: URL
    private var jsonlHandle: FileHandle?
    private var allFinals: [TranscriptSegment] = []

    // MARK: Init

    public init(sessionDir: URL) throws {
        self.sessionDir = sessionDir
        try FileManager.default.createDirectory(at: sessionDir, withIntermediateDirectories: true)
        self.jsonlURL = sessionDir.appendingPathComponent("transcript.jsonl")
        self.txtURL = sessionDir.appendingPathComponent("transcript.txt")
    }

    // MARK: Public API

    /// Append one segment. Interim (non-final) segments are dropped — they're
    /// not durable; final segments will replace them.
    public func append(_ segment: TranscriptSegment) throws {
        guard segment.isFinal else { return }
        try writeJSONL(segment)
        allFinals.append(segment)
    }

    /// Atomically rewrite `transcript.txt` from accumulated final segments.
    /// Safe to call repeatedly — last write wins.
    public func flushTxt() throws {
        let combined = allFinals
            .map { $0.text.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .joined(separator: " ")
        let data = Data(combined.utf8)
        try AtomicWriter.write(data, to: txtURL)
    }

    /// Close the JSONL handle and flush the text file. Safe to call multiple
    /// times — subsequent calls are no-ops after the first.
    public func close() throws {
        try jsonlHandle?.synchronize()
        try jsonlHandle?.close()
        jsonlHandle = nil
        try flushTxt()
    }

    /// Close the JSONL handle and write `overrideText` (e.g. an LLM-cleaned
    /// version of the full transcript) to `transcript.txt` instead of
    /// concatenating segments. JSONL still holds the per-segment timing /
    /// raw text — only the human-readable plain-text view is overridden.
    public func close(overrideText: String) throws {
        try jsonlHandle?.synchronize()
        try jsonlHandle?.close()
        jsonlHandle = nil
        try AtomicWriter.write(Data(overrideText.utf8), to: txtURL)
    }

    /// Snapshot of all final segments persisted so far. Useful for tests
    /// and for re-driving the AI summary stage from a finished session.
    public func segments() -> [TranscriptSegment] {
        allFinals
    }

    /// Write `<sessionDir>/transcript.timestamped.txt` — one line per final
    /// segment prefixed with `[HH:MM:SS]` (or `[MM:SS]` for sub-hour
    /// recordings). Independent of `transcript.txt`, which may be overridden
    /// by the LLM-cleanup pass and loses segment timing. Lets the user (or
    /// Library player) scrub to specific moments by reading the timestamp
    /// next to the line they care about.
    ///
    /// Safe to call repeatedly — last write wins. No-op when no final
    /// segments have been appended (avoids leaving an empty file behind).
    public func writeTimestamped() throws {
        let lines = allFinals.compactMap { segment -> String? in
            let text = segment.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { return nil }
            return "[\(Self.formatTimestamp(seconds: segment.start))] \(text)"
        }
        guard !lines.isEmpty else { return }
        let url = sessionDir.appendingPathComponent("transcript.timestamped.txt")
        let body = lines.joined(separator: "\n") + "\n"
        try AtomicWriter.write(Data(body.utf8), to: url)
    }

    /// Format `seconds` as `HH:MM:SS` for >= 1 h durations, `MM:SS` otherwise.
    /// Visible-for-tests: callers should prefer `writeTimestamped()`.
    static func formatTimestamp(seconds: Double) -> String {
        let total = max(0, Int(seconds.rounded(.down)))
        let h = total / 3600
        let m = (total % 3600) / 60
        let s = total % 60
        if h > 0 {
            return String(format: "%d:%02d:%02d", h, m, s)
        }
        return String(format: "%02d:%02d", m, s)
    }

    // MARK: Private

    private func writeJSONL(_ segment: TranscriptSegment) throws {
        let handle = try jsonlHandleEnsured()
        var data = try JSONEncoder().encode(segment)
        data.append(0x0A)  // newline — JSONL is one object per line
        try handle.write(contentsOf: data)
        // We do NOT fsync per-segment — that would tank throughput on long
        // recordings. The handle is fsync'd in `close()`. On a hard crash,
        // the trailing few segments may be lost; the audio segments still
        // hold the source-of-truth audio for re-transcription.
    }

    private func jsonlHandleEnsured() throws -> FileHandle {
        if let handle = jsonlHandle { return handle }
        if !FileManager.default.fileExists(atPath: jsonlURL.path) {
            FileManager.default.createFile(atPath: jsonlURL.path, contents: nil)
        }
        let handle = try FileHandle(forWritingTo: jsonlURL)
        try handle.seekToEnd()
        jsonlHandle = handle
        return handle
    }
}

import Foundation
import Observation
import AIKit
import StorageKit
import TranscriptionKit

// MARK: - ModeFilter

@available(macOS 14.0, *)
enum ModeFilter: String, CaseIterable, Identifiable {
    case all
    case meeting
    case dictation

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .all: return "All"
        case .meeting: return "Meeting"
        case .dictation: return "Dictation"
        }
    }
}

// MARK: - LibraryState

/// Observable state for the Library window.
///
/// Holds query + filter selection; drives async refresh against the DB.
/// Transcript segments are loaded lazily (only when a session is selected)
/// to avoid reading hundreds of JSONL files at startup.
@available(macOS 14.0, *)
@Observable
@MainActor
final class LibraryState {

    // MARK: - Dependencies

    let database: AppDatabase
    let sessionStore: SessionStore
    let settings: AppSettings?
    private let canClearAllSessions: @MainActor () -> Bool

    // MARK: - Observable state

    var query: String = "" {
        didSet { scheduleRefresh() }
    }

    var modeFilter: ModeFilter = .all {
        didSet { scheduleRefresh() }
    }

    var sessions: [SessionRecord] = []
    var selectedSessionId: String?

    // MARK: - Init

    init(
        database: AppDatabase,
        sessionStore: SessionStore,
        settings: AppSettings? = nil,
        canClearAllSessions: @escaping @MainActor () -> Bool = { true }
    ) {
        self.database = database
        self.sessionStore = sessionStore
        self.settings = settings
        self.canClearAllSessions = canClearAllSessions
    }

    // MARK: - Data loading

    /// Populate `sessions` from DB using the current query + filter.
    func refresh() async {
        do {
            let raw: [SessionRecord]
            let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)

            if trimmed.isEmpty {
                raw = try await database.listSessions(limit: 200)
            } else {
                // FTS5 search returns hits with sids; hydrate back to full records in parallel.
                let hits = try await database.searchTranscripts(query: trimmed, limit: 100)

                // Optional: fold in semantic search results. Cosine top-K sids are
                // appended to the FTS sid list (deduplicated) so users still get a
                // hit for "поговорили про дедлайн" when the transcript said
                // "запропонували нову дату." Falls back silently when:
                //   - settings is nil (programmatic test usage)
                //   - semanticSearchEnabled is off
                //   - no API key available
                //   - the embed call fails
                var orderedSids = hits.map { $0.sid }
                let semanticSids = await semanticHits(for: trimmed)
                for sid in semanticSids where !orderedSids.contains(sid) {
                    orderedSids.append(sid)
                }

                raw = try await withThrowingTaskGroup(of: SessionRecord?.self) { group in
                    for sid in orderedSids {
                        group.addTask { [database] in
                            try await database.session(id: sid)
                        }
                    }
                    var results: [SessionRecord] = []
                    for try await record in group {
                        if let r = record { results.append(r) }
                    }
                    // TaskGroup ordering is non-deterministic; restore the
                    // FTS/semantic relevance order the user searched for.
                    return Self.records(results, orderedBy: orderedSids)
                }
            }

            // Apply mode filter client-side — DB already filters by date; mode is cheap.
            sessions = raw.filter { record in
                switch modeFilter {
                case .all: return true
                case .meeting: return record.mode == .meeting
                case .dictation: return record.mode == .dictation
                }
            }
        } catch {
            // Surfacing DB errors here would require a separate error state; for v0
            // leave sessions unchanged and log to console.
            print("[LibraryState] refresh failed: \(error)")
        }
    }

    /// Read transcript.jsonl for a session and decode line-by-line.
    ///
    /// Returns an empty array (not throws) when transcript.jsonl is missing —
    /// this happens for sessions that never reached the transcription stage.
    func loadSegments(for sid: String) async throws -> [TranscriptSegment] {
        let dir = await sessionStore.sessionDir(for: sid)
        let jsonlURL = dir.appendingPathComponent("transcript.jsonl")

        // Skip reading if the file doesn't exist (transcription incomplete/failed).
        guard (try? jsonlURL.resourceValues(forKeys: [.fileSizeKey]))?.fileSize != nil else {
            return []
        }

        let data = try Data(contentsOf: jsonlURL)
        guard !data.isEmpty else { return [] }

        let decoder = JSONDecoder()
        var segments: [TranscriptSegment] = []

        // JSONL: one JSON object per line.
        for line in data.split(separator: UInt8(ascii: "\n"), omittingEmptySubsequences: true) {
            if let segment = try? decoder.decode(TranscriptSegment.self, from: Data(line)) {
                segments.append(segment)
            }
        }
        return segments
    }

    /// URL for the audio file of a session.
    func audioFileURL(for sid: String) async -> URL {
        let dir = await sessionStore.sessionDir(for: sid)
        return dir.appendingPathComponent("audio.m4a")
    }

    func sharedLinks(for sid: String) async -> SharedLinksSnapshot? {
        do {
            return try await sessionStore.loadSharedLinksSnapshot(for: sid)
        } catch {
            print("[LibraryState] sharedLinks failed: \(error)")
            return nil
        }
    }

    /// Delete a session: DB rows (sessions / FTS / embeddings) + the on-disk
    /// session directory. Best-effort on the filesystem side — the DB delete
    /// runs first so a row never points at a half-deleted directory. After
    /// success, refreshes the visible list and clears the selection if needed.
    func deleteSession(id: String) async {
        do {
            try await database.deleteSession(id: id)
        } catch {
            print("[LibraryState] deleteSession DB failed: \(error)")
            return
        }
        let dir = await sessionStore.sessionDir(for: id)
        try? FileManager.default.removeItem(at: dir)
        if selectedSessionId == id { selectedSessionId = nil }
        await refresh()
    }

    /// Nuke every session and its files. DB rows for sessions / FTS / embeddings
    /// are dropped one-by-one (so any partially-orphaned rows still get cleaned),
    /// then the recordings root is emptied so even abandoned-mid-record session
    /// directories that never made it to the DB are removed.
    func clearAllSessions() async {
        guard canClearAllSessions() else {
            print("[LibraryState] clearAllSessions refused: active recording in progress")
            return
        }
        let all = (try? await database.listSessions(limit: 10_000)) ?? []
        for record in all {
            try? await database.deleteSession(id: record.id)
        }
        let root = await sessionStore.recordingsRoot
        if let entries = try? FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil) {
            for entry in entries {
                try? FileManager.default.removeItem(at: entry)
            }
        }
        selectedSessionId = nil
        await refresh()
    }

    // MARK: - Private

    static func records(_ records: [SessionRecord], orderedBy orderedSids: [String]) -> [SessionRecord] {
        var byID: [String: SessionRecord] = [:]
        for record in records {
            byID[record.id] = record
        }
        return orderedSids.compactMap { byID[$0] }
    }

    /// Embed `query` and return up to 20 sids ordered by descending cosine
    /// similarity to stored session embeddings. Returns `[]` when semantic
    /// search is disabled, no key is set, or any step fails.
    private func semanticHits(for query: String) async -> [String] {
        guard let settings, settings.semanticSearchEnabled else { return [] }
        let key = settings.openaiApiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty else { return [] }
        let provider = OpenAIEmbeddingProvider(apiKey: key)
        do {
            let queryVector = try await provider.embed(query)
            let stored = try await database.allEmbeddings()
            // Score each row, drop low-confidence matches (<0.3 cosine), top-20.
            let scored: [(sid: String, score: Float)] = stored.compactMap { row in
                let v = EmbeddingMath.unpack(row.vector)
                guard v.count == queryVector.count else { return nil }
                let score = EmbeddingMath.cosineSimilarity(queryVector, v)
                return score > 0.3 ? (sid: row.sid, score: score) : nil
            }
            return scored
                .sorted { $0.score > $1.score }
                .prefix(20)
                .map { $0.sid }
        } catch {
            return []
        }
    }

    // Debounce: refresh fires on the next run-loop turn after the last mutation.
    // Avoids a DB round-trip per keystroke while still feeling live.
    private var refreshTask: Task<Void, Never>?
    private var refreshGeneration = 0

    private func scheduleRefresh() {
        refreshGeneration += 1
        let generation = refreshGeneration
        refreshTask?.cancel()
        refreshTask = Task { @MainActor [weak self] in
            // Yield once to coalesce rapid changes (e.g. filter + query changed together).
            await Task.yield()
            guard !Task.isCancelled, self?.refreshGeneration == generation else { return }
            await self?.refresh()
        }
    }
}

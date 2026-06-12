import Foundation
import Testing
import SharingKit
import StorageKit
@testable import KosmoNotes

@MainActor
@Suite("Library share logic")
struct LibraryShareLogicTests {

    private func makeTempDir() throws -> URL {
        let tmpDir = URL.temporaryDirectory.appendingPathComponent("KosmoNotesAppTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
        return tmpDir
    }

    @Test("snapshot(from:) keeps only non-nil URLs in artifact order")
    func snapshotFromShareResultKeepsStableOrder() {
        let result = SharingService.ShareResult(
            audioURL: URL(string: "https://example.test/audio")!,
            videoURL: URL(string: "https://example.test/video")!,
            summaryURL: nil,
            transcriptURL: URL(string: "https://example.test/transcript")!
        )

        let snapshot = SessionSharePlanning.snapshot(
            from: result,
            sharedAt: Date(timeIntervalSince1970: 1_715_130_000)
        )

        #expect(snapshot.links.map(\.kind) == [.audio, .video, .transcript])
    }

    @Test("validatedSelection rejects an empty artifact list")
    func validatedSelectionRejectsEmptySelection() {
        #expect(throws: SessionSharePlanning.SelectionError.self) {
            try SessionSharePlanning.validatedSelection([])
        }
    }

    @Test("sharedLinks returns nil when shared-links.json is invalid")
    func sharedLinksReturnsNilForCorruptSidecar() async throws {
        // Nested helper so the AppDatabase + SessionStore + LibraryState references
        // go out of scope before we delete tmpDir. GRDB's DatabasePool has no
        // explicit close; we rely on ARC to drop the SQLite handles. Without
        // this scoping the previous test emitted a 'unlinking a vnode while in
        // use' warning at tmpDir removal time.
        let tmpDir = try makeTempDir()
        try await runCorruptSidecarScenario(in: tmpDir)
        try? FileManager.default.removeItem(at: tmpDir)
    }

    private func runCorruptSidecarScenario(in tmpDir: URL) async throws {
        let dbURL = tmpDir.appendingPathComponent("sessions.sqlite")
        let db = try AppDatabase(path: dbURL)
        try await db.migrate()
        let recordingsDir = tmpDir.appendingPathComponent("recordings")
        let store = try SessionStore(rootDir: recordingsDir, database: db)

        let session = try await store.createSession(mode: .meeting, language: nil)
        let dir = await store.sessionDir(for: session.id)
        try Data("not json".utf8).write(to: dir.appendingPathComponent("shared-links.json"))

        let state = LibraryState(database: db, sessionStore: store, settings: nil)
        let loaded = await state.sharedLinks(for: session.id)

        #expect(loaded == nil)
    }

    @Test("hydrated search records preserve relevance order instead of newest-first")
    func hydratedSearchRecordsPreserveRelevanceOrder() {
        let newest = makeRecord(id: "newest", recordedAt: Date(timeIntervalSince1970: 300))
        let oldest = makeRecord(id: "oldest", recordedAt: Date(timeIntervalSince1970: 100))
        let middle = makeRecord(id: "middle", recordedAt: Date(timeIntervalSince1970: 200))

        let ordered = LibraryState.records(
            [newest, oldest, middle],
            orderedBy: ["oldest", "newest", "middle"]
        )

        #expect(ordered.map(\.id) == ["oldest", "newest", "middle"])
    }

    @Test("clear all is refused while an active recording owns the library")
    func clearAllRefusesActiveRecording() async throws {
        let tmpDir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: tmpDir) }

        let dbURL = tmpDir.appendingPathComponent("sessions.sqlite")
        let db = try AppDatabase(path: dbURL)
        try await db.migrate()
        let recordingsDir = tmpDir.appendingPathComponent("recordings")
        let store = try SessionStore(rootDir: recordingsDir, database: db)
        let session = try await store.createSession(mode: .meeting, language: nil)
        let sessionDir = await store.sessionDir(for: session.id)
        try Data("audio".utf8).write(to: sessionDir.appendingPathComponent("audio.m4a"))

        let state = LibraryState(
            database: db,
            sessionStore: store,
            settings: nil,
            canClearAllSessions: { false }
        )
        await state.clearAllSessions()

        #expect(try await db.session(id: session.id) != nil)
        #expect(FileManager.default.fileExists(atPath: sessionDir.path))
    }

    private func makeRecord(id: String, recordedAt: Date) -> SessionRecord {
        SessionRecord(
            id: id,
            recordedAt: recordedAt,
            durationSecs: 12,
            mode: .meeting,
            language: nil,
            status: .complete
        )
    }
}

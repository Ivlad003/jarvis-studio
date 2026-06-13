import Foundation
import AppKit
import Testing
@testable import StorageKit

@Suite("KnowledgeBaseStore tests")
struct KnowledgeBaseStoreTests {

    private func makeStore() async throws -> (KnowledgeBaseStore, AppDatabase, URL) {
        let tmpDir = URL.temporaryDirectory.appendingPathComponent("KosmoNotesKBTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)

        let dbURL = tmpDir.appendingPathComponent("sessions.sqlite")
        let db = try AppDatabase(path: dbURL)
        try await db.migrate()

        let store = KnowledgeBaseStore(database: db)
        return (store, db, tmpDir)
    }

    private func cleanup(_ dir: URL) {
        try? FileManager.default.removeItem(at: dir)
    }

    private func writePDF(text: String, to url: URL) throws {
        let data = NSMutableData()
        var mediaBox = CGRect(x: 0, y: 0, width: 612, height: 792)
        guard let consumer = CGDataConsumer(data: data),
              let context = CGContext(consumer: consumer, mediaBox: &mediaBox, nil) else {
            throw CocoaError(.fileWriteUnknown)
        }

        context.beginPDFPage(nil)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: false)
        (text as NSString).draw(
            at: CGPoint(x: 72, y: 700),
            withAttributes: [.font: NSFont.systemFont(ofSize: 14)]
        )
        NSGraphicsContext.restoreGraphicsState()
        context.endPDFPage()
        context.closePDF()

        try data.write(to: url, options: .atomic)
    }

    @Test("addSource persists code folder sources")
    func addSourcePersistsCodeFolderSources() async throws {
        let (store, _, tmpDir) = try await makeStore()
        defer { cleanup(tmpDir) }

        let sourceDir = tmpDir.appendingPathComponent("code")
        try FileManager.default.createDirectory(at: sourceDir, withIntermediateDirectories: true)

        let source = try await store.addSource(kind: .codeFolder, path: sourceDir)
        let sources = try await store.listSources()

        #expect(sources.count == 1)
        #expect(sources[0].id == source.id)
        #expect(sources[0].kind == .codeFolder)
        #expect(sources[0].path == sourceDir.standardizedFileURL.path)
    }

    @Test("reindexAll indexes text, markdown, and code with underscore identifiers")
    func reindexAllIndexesTextMarkdownAndCodeIdentifiers() async throws {
        let (store, _, tmpDir) = try await makeStore()
        defer { cleanup(tmpDir) }

        let sourceDir = tmpDir.appendingPathComponent("knowledge")
        let docsDir = sourceDir.appendingPathComponent("docs")
        let codeDir = sourceDir.appendingPathComponent("Sources")
        try FileManager.default.createDirectory(at: docsDir, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: codeDir, withIntermediateDirectories: true)
        try "# Search Notes\nQuarterly budget is due Friday.\n".write(
            to: docsDir.appendingPathComponent("meeting.md"),
            atomically: true,
            encoding: .utf8
        )
        try """
        func search_user_by_id(_ id: String) -> User? {
            users.first { $0.id == id }
        }
        """.write(
            to: codeDir.appendingPathComponent("UserService.swift"),
            atomically: true,
            encoding: .utf8
        )

        _ = try await store.addSource(kind: .codeFolder, path: sourceDir)
        try await store.reindexAll()

        let identifierHits = try await store.search(query: "search_user_by_id", limit: 10)
        #expect(identifierHits.contains { $0.relPath == "Sources/UserService.swift" })

        let documentHits = try await store.search(query: "budget Friday", limit: 10)
        #expect(documentHits.contains { $0.relPath == "docs/meeting.md" })
    }

    @Test("reindexAll indexes PDF document text")
    func reindexAllIndexesPDFDocumentText() async throws {
        let (store, _, tmpDir) = try await makeStore()
        defer { cleanup(tmpDir) }

        let sourceDir = tmpDir.appendingPathComponent("knowledge")
        try FileManager.default.createDirectory(at: sourceDir, withIntermediateDirectories: true)
        let pdfURL = sourceDir.appendingPathComponent("brief.pdf")
        try writePDF(text: "Quarterly launch budget includes live chat transcription.", to: pdfURL)

        _ = try await store.addSource(kind: .document, path: sourceDir)
        try await store.reindexAll()

        let hits = try await store.search(query: "live chat transcription", limit: 10)
        #expect(hits.contains { $0.relPath == "brief.pdf" })
    }

    @Test("reindexAll removes stale chunks for changed files")
    func reindexAllRemovesStaleChunksForChangedFiles() async throws {
        let (store, _, tmpDir) = try await makeStore()
        defer { cleanup(tmpDir) }

        let sourceDir = tmpDir.appendingPathComponent("knowledge")
        try FileManager.default.createDirectory(at: sourceDir, withIntermediateDirectories: true)
        let noteURL = sourceDir.appendingPathComponent("note.txt")
        try "legacy launch checklist".write(to: noteURL, atomically: true, encoding: .utf8)

        _ = try await store.addSource(kind: .document, path: sourceDir)
        try await store.reindexAll()
        #expect(try await store.search(query: "legacy", limit: 10).count == 1)

        try "replacement rollout checklist".write(to: noteURL, atomically: true, encoding: .utf8)
        try await store.reindexAll()

        #expect(try await store.search(query: "legacy", limit: 10).isEmpty)
        #expect(try await store.search(query: "replacement", limit: 10).count == 1)
    }

    @Test("search returns semantic KB hits when FTS has no lexical match")
    func searchReturnsSemanticHitsWhenFTSHasNoLexicalMatch() async throws {
        let (_, db, tmpDir) = try await makeStore()
        defer { cleanup(tmpDir) }

        let sourceDir = tmpDir.appendingPathComponent("knowledge")
        try FileManager.default.createDirectory(at: sourceDir, withIntermediateDirectories: true)
        try "Quarterly roadmap says launch funding is due Friday.".write(
            to: sourceDir.appendingPathComponent("roadmap.md"),
            atomically: true,
            encoding: .utf8
        )

        let embedder = DeterministicKnowledgeBaseEmbedder { text in
            text.contains("strategy question") || text.contains("roadmap")
                ? [1, 0]
                : [0, 1]
        }
        let store = KnowledgeBaseStore(database: db, embeddingProvider: embedder)
        _ = try await store.addSource(kind: .document, path: sourceDir)
        try await store.reindexAll()

        let hits = try await store.search(query: "strategy question", limit: 10)

        #expect(hits.map(\.relPath) == ["roadmap.md"])
        #expect(hits.first?.snippet.contains("Quarterly roadmap") == true)
    }

    @Test("search keeps FTS hits first and appends cosine hits")
    func searchKeepsFTSHitsFirstAndAppendsCosineHits() async throws {
        let (_, db, tmpDir) = try await makeStore()
        defer { cleanup(tmpDir) }

        let sourceDir = tmpDir.appendingPathComponent("knowledge")
        try FileManager.default.createDirectory(at: sourceDir, withIntermediateDirectories: true)
        try "The budget spreadsheet is archived.".write(
            to: sourceDir.appendingPathComponent("budget.txt"),
            atomically: true,
            encoding: .utf8
        )
        try "Quarterly roadmap says launch funding is due Friday.".write(
            to: sourceDir.appendingPathComponent("roadmap.md"),
            atomically: true,
            encoding: .utf8
        )

        let embedder = DeterministicKnowledgeBaseEmbedder { text in
            text.contains("budget") || text.contains("roadmap")
                ? [1, 0]
                : [0, 1]
        }
        let store = KnowledgeBaseStore(database: db, embeddingProvider: embedder)
        _ = try await store.addSource(kind: .document, path: sourceDir)
        try await store.reindexAll()

        let hits = try await store.search(query: "budget", limit: 10)

        #expect(hits.map(\.relPath) == ["budget.txt", "roadmap.md"])
    }

    @Test("removeSource deletes source metadata and indexed chunks")
    func removeSourceDeletesMetadataAndIndexedChunks() async throws {
        let (store, _, tmpDir) = try await makeStore()
        defer { cleanup(tmpDir) }

        let sourceDir = tmpDir.appendingPathComponent("knowledge")
        try FileManager.default.createDirectory(at: sourceDir, withIntermediateDirectories: true)
        try "private roadmap alpha".write(
            to: sourceDir.appendingPathComponent("roadmap.txt"),
            atomically: true,
            encoding: .utf8
        )

        let source = try await store.addSource(kind: .document, path: sourceDir)
        try await store.reindexAll()
        #expect(try await store.search(query: "roadmap", limit: 10).count == 1)

        try await store.removeSource(id: source.id)

        #expect(try await store.listSources().isEmpty)
        #expect(try await store.search(query: "roadmap", limit: 10).isEmpty)
    }
}

private struct DeterministicKnowledgeBaseEmbedder: KnowledgeBaseEmbeddingProvider {
    let modelIdentifier = "deterministic-test-embedder"
    let embedText: @Sendable (String) -> [Float]

    init(_ embedText: @escaping @Sendable (String) -> [Float]) {
        self.embedText = embedText
    }

    func embed(_ text: String) async throws -> [Float] {
        embedText(text)
    }
}

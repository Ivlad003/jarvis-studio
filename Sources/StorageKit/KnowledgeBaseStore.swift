import Foundation
import PDFKit

public protocol KnowledgeBaseEmbeddingProvider: Sendable {
    var modelIdentifier: String { get }
    func embed(_ text: String) async throws -> [Float]
}

public actor KnowledgeBaseStore {
    private let database: AppDatabase
    private let fileManager: FileManager
    private let embeddingProvider: (any KnowledgeBaseEmbeddingProvider)?
    private let semanticThreshold: Float

    public init(
        database: AppDatabase,
        fileManager: FileManager = .default,
        embeddingProvider: (any KnowledgeBaseEmbeddingProvider)? = nil,
        semanticThreshold: Float = 0.3
    ) {
        self.database = database
        self.fileManager = fileManager
        self.embeddingProvider = embeddingProvider
        self.semanticThreshold = semanticThreshold
    }

    @discardableResult
    public func addSource(kind: KnowledgeBaseSourceKind, path: URL) async throws -> KnowledgeBaseSource {
        let normalizedPath = path.standardizedFileURL.path
        return try await database.addKnowledgeBaseSource(kind: kind, path: normalizedPath)
    }

    public func listSources() async throws -> [KnowledgeBaseSource] {
        try await database.listKnowledgeBaseSources()
    }

    public func removeSource(id: String) async throws {
        try await database.deleteKnowledgeBaseSource(id: id)
    }

    public func reindexAll() async throws {
        let sources = try await database.listKnowledgeBaseSources()
        for source in sources {
            let documents = try scan(source: source)
            try await database.replaceKnowledgeBaseIndex(sourceID: source.id, documents: documents)
            if let embeddingProvider {
                let embeddings = await buildEmbeddings(
                    sourceID: source.id,
                    documents: documents,
                    provider: embeddingProvider
                )
                try await database.replaceKnowledgeBaseEmbeddings(sourceID: source.id, embeddings: embeddings)
            }
        }
    }

    public func search(query: String, limit: Int = 20) async throws -> [KnowledgeBaseHit] {
        let boundedLimit = max(1, limit)
        let ftsHits = try await database.searchKnowledgeBase(query: query, limit: boundedLimit)
        guard ftsHits.count < boundedLimit,
              let embeddingProvider,
              let queryVector = try? await embeddingProvider.embed(query),
              !queryVector.isEmpty else {
            return ftsHits
        }

        let existingKeys = Set(ftsHits.map(Self.semanticKey))
        let stored = try await database.allKnowledgeBaseEmbeddings()
        let semanticHits = stored.compactMap { row -> (hit: KnowledgeBaseHit, score: Float)? in
            let key = Self.semanticKey(documentID: row.documentID, chunkIndex: row.chunkIndex)
            guard !existingKeys.contains(key) else { return nil }
            let vector = Self.unpack(row.vector)
            guard vector.count == queryVector.count else { return nil }
            let score = Self.cosineSimilarity(queryVector, vector)
            guard score > semanticThreshold else { return nil }
            return (
                hit: KnowledgeBaseHit(
                    sourceID: row.sourceID,
                    documentID: row.documentID,
                    relPath: row.relPath,
                    chunkIndex: row.chunkIndex,
                    snippet: Self.semanticSnippet(from: row.text)
                ),
                score: score
            )
        }

        let remaining = boundedLimit - ftsHits.count
        return ftsHits + semanticHits
            .sorted {
                if $0.score == $1.score {
                    if $0.hit.relPath == $1.hit.relPath {
                        return $0.hit.chunkIndex < $1.hit.chunkIndex
                    }
                    return $0.hit.relPath < $1.hit.relPath
                }
                return $0.score > $1.score
            }
            .prefix(remaining)
            .map(\.hit)
    }

    private func scan(source: KnowledgeBaseSource) throws -> [KnowledgeBaseIndexedDocument] {
        let rootURL = URL(fileURLWithPath: source.path)
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: rootURL.path, isDirectory: &isDirectory) else {
            return []
        }

        let urls: [URL]
        if isDirectory.boolValue {
            let keys: Set<URLResourceKey> = [.isRegularFileKey, .fileSizeKey, .contentModificationDateKey]
            let enumerator = fileManager.enumerator(
                at: rootURL,
                includingPropertiesForKeys: Array(keys),
                options: [.skipsHiddenFiles, .skipsPackageDescendants]
            )
            urls = (enumerator?.compactMap { $0 as? URL } ?? []).filter { url in
                guard let values = try? url.resourceValues(forKeys: keys) else { return false }
                return values.isRegularFile == true && isSupportedFile(url, for: source.kind)
            }
        } else {
            urls = isSupportedFile(rootURL, for: source.kind) ? [rootURL] : []
        }

        return try urls.sorted { $0.path < $1.path }.compactMap { url in
            guard let text = try readIndexableText(url), !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                return nil
            }
            let values = try url.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
            return KnowledgeBaseIndexedDocument(
                relPath: relPath(for: url, rootURL: rootURL),
                mtime: values.contentModificationDate ?? Date(timeIntervalSince1970: 0),
                size: Int64(values.fileSize ?? 0),
                chunks: Self.chunks(from: text)
            )
        }
    }

    private func readIndexableText(_ url: URL) throws -> String? {
        if url.pathExtension.lowercased() == "pdf" {
            return Self.truncated(PDFDocument(url: url)?.string)
        }
        return try readTextFile(url)
    }

    private func readTextFile(_ url: URL) throws -> String? {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        let data = try handle.read(upToCount: 64 * 1024) ?? Data()
        return String(data: data, encoding: .utf8)
    }

    private func relPath(for fileURL: URL, rootURL: URL) -> String {
        let filePath = fileURL.standardizedFileURL.path
        let rootPath = rootURL.standardizedFileURL.path
        guard filePath.hasPrefix(rootPath + "/") else {
            return fileURL.lastPathComponent
        }
        return String(filePath.dropFirst(rootPath.count + 1))
    }

    private func isSupportedFile(_ url: URL, for kind: KnowledgeBaseSourceKind) -> Bool {
        let ext = url.pathExtension.lowercased()
        switch kind {
        case .document:
            return Self.documentExtensions.contains(ext)
        case .codeFolder:
            return Self.documentExtensions.contains(ext) || Self.codeExtensions.contains(ext)
        }
    }

    private func buildEmbeddings(
        sourceID: String,
        documents: [KnowledgeBaseIndexedDocument],
        provider: any KnowledgeBaseEmbeddingProvider
    ) async -> [KnowledgeBaseIndexedEmbedding] {
        var embeddings: [KnowledgeBaseIndexedEmbedding] = []
        for document in documents {
            let documentID = Self.documentID(sourceID: sourceID, relPath: document.relPath)
            for (index, chunk) in document.chunks.enumerated() {
                do {
                    let vector = try await provider.embed(chunk)
                    guard !vector.isEmpty else { continue }
                    embeddings.append(KnowledgeBaseIndexedEmbedding(
                        documentID: documentID,
                        chunkIndex: index,
                        vector: Self.pack(vector),
                        model: provider.modelIdentifier,
                        indexedAt: Date()
                    ))
                } catch {
                    continue
                }
            }
        }
        return embeddings
    }

    private static func chunks(from text: String, maxCharacters: Int = 6_000, overlap: Int = 600) -> [String] {
        guard text.count > maxCharacters else { return [text] }

        var chunks: [String] = []
        var start = text.startIndex
        while start < text.endIndex {
            let end = text.index(start, offsetBy: maxCharacters, limitedBy: text.endIndex) ?? text.endIndex
            chunks.append(String(text[start..<end]))
            guard end < text.endIndex else { break }
            let chunkDistance = text.distance(from: start, to: end)
            let overlapDistance = min(overlap, max(0, chunkDistance - 1))
            start = text.index(end, offsetBy: -overlapDistance)
        }
        return chunks
    }

    private static func truncated(_ text: String?, maxCharacters: Int = 64 * 1024) -> String? {
        guard let text else { return nil }
        guard text.count > maxCharacters else { return text }
        let end = text.index(text.startIndex, offsetBy: maxCharacters)
        return String(text[..<end])
    }

    private static func documentID(sourceID: String, relPath: String) -> String {
        "\(sourceID):\(relPath)"
    }

    private static func semanticKey(_ hit: KnowledgeBaseHit) -> String {
        semanticKey(documentID: hit.documentID, chunkIndex: hit.chunkIndex)
    }

    private static func semanticKey(documentID: String, chunkIndex: Int) -> String {
        "\(documentID)#\(chunkIndex)"
    }

    private static func semanticSnippet(from text: String, maxCharacters: Int = 240) -> String {
        let normalized = text
            .split(whereSeparator: \.isWhitespace)
            .joined(separator: " ")
        guard normalized.count > maxCharacters else { return normalized }
        let end = normalized.index(normalized.startIndex, offsetBy: maxCharacters)
        return String(normalized[..<end]) + "…"
    }

    private static func cosineSimilarity(_ a: [Float], _ b: [Float]) -> Float {
        guard a.count == b.count, !a.isEmpty else { return 0 }
        var dot: Float = 0
        var aNorm: Float = 0
        var bNorm: Float = 0
        for index in a.indices {
            dot += a[index] * b[index]
            aNorm += a[index] * a[index]
            bNorm += b[index] * b[index]
        }
        let denominator = aNorm.squareRoot() * bNorm.squareRoot()
        return denominator > 0 ? dot / denominator : 0
    }

    private static func pack(_ vector: [Float]) -> Data {
        var copy = vector
        return copy.withUnsafeMutableBufferPointer { buffer in
            Data(buffer: buffer)
        }
    }

    private static func unpack(_ data: Data) -> [Float] {
        let count = data.count / MemoryLayout<Float>.size
        return data.withUnsafeBytes { rawBuffer in
            guard count > 0 else { return [] }
            return (0..<count).map { index in
                rawBuffer.loadUnaligned(
                    fromByteOffset: index * MemoryLayout<Float>.size,
                    as: Float.self
                )
            }
        }
    }

    private static let documentExtensions: Set<String> = [
        "md", "markdown", "pdf", "txt", "text",
    ]

    private static let codeExtensions: Set<String> = [
        "bash", "c", "cc", "cpp", "cs", "css", "go", "h", "hpp", "html", "java",
        "js", "json", "jsx", "kt", "m", "mm", "php", "py", "rb", "rs", "sh",
        "sql", "swift", "toml", "ts", "tsx", "xml", "yaml", "yml", "zsh",
    ]
}

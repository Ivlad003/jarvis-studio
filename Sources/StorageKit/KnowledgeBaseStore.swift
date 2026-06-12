import Foundation

public actor KnowledgeBaseStore {
    private let database: AppDatabase
    private let fileManager: FileManager

    public init(database: AppDatabase, fileManager: FileManager = .default) {
        self.database = database
        self.fileManager = fileManager
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
        }
    }

    public func search(query: String, limit: Int = 20) async throws -> [KnowledgeBaseHit] {
        try await database.searchKnowledgeBase(query: query, limit: limit)
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
            guard let text = try readTextFile(url), !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
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

    private static let documentExtensions: Set<String> = [
        "md", "markdown", "txt", "text",
    ]

    private static let codeExtensions: Set<String> = [
        "bash", "c", "cc", "cpp", "cs", "css", "go", "h", "hpp", "html", "java",
        "js", "json", "jsx", "kt", "m", "mm", "php", "py", "rb", "rs", "sh",
        "sql", "swift", "toml", "ts", "tsx", "xml", "yaml", "yml", "zsh",
    ]
}

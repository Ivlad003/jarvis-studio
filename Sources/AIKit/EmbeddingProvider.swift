import Foundation
import StorageKit

// MARK: - EmbeddingProvider

/// Produces dense vector embeddings for arbitrary text. Used by semantic search
/// to find sessions that are conceptually related to a query, even when no
/// exact word overlaps with the FTS5 index.
///
/// v1.0 ships a single concrete impl: OpenAI's `text-embedding-3-small` (1536-dim).
/// Adding more (Voyage, Cohere) is a matter of writing another conformer.
public protocol EmbeddingProvider: Sendable {
    /// Embed a single text and return a Float32 vector.
    func embed(_ text: String) async throws -> [Float]

    /// Identifier of the model used. Stored alongside the vector so future
    /// migrations can re-embed when the dimension or weights change.
    var modelIdentifier: String { get }

    /// Dimensionality of the returned vector. Used by callers to pre-allocate
    /// or to validate stored vectors against the active model.
    var dimensions: Int { get }
}

// MARK: - OpenAIEmbeddingProvider

/// `text-embedding-3-small` — 1536 dims, $0.02 per 1M tokens. Cheap enough that
/// even hundreds of hour-long transcripts cost cents to index.
public final class OpenAIEmbeddingProvider: EmbeddingProvider, Sendable {

    public typealias HTTPClient = @Sendable (URLRequest) async throws -> (Data, URLResponse)

    private let apiKey: String
    private let endpoint: URL
    private let httpClient: HTTPClient

    public let modelIdentifier: String = "text-embedding-3-small"
    public let dimensions: Int = 1536

    public init(
        apiKey: String,
        endpoint: URL = URL(string: "https://api.openai.com/v1/embeddings")!,
        httpClient: @escaping HTTPClient = { try await URLSession.shared.data(for: $0) }
    ) {
        self.apiKey = apiKey
        self.endpoint = endpoint
        self.httpClient = httpClient
    }

    public func embed(_ text: String) async throws -> [Float] {
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "content-type")

        // OpenAI's embeddings endpoint truncates at 8191 tokens; transcripts longer
        // than that are split by the caller. Here we trust the caller.
        let body: [String: Any] = [
            "model": modelIdentifier,
            "input": text,
            "encoding_format": "float",
        ]
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await httpClient(request)
        guard let http = response as? HTTPURLResponse else {
            throw AIError.sendFailed(message: "Non-HTTP response from embeddings API")
        }
        guard http.statusCode == 200 else {
            let body = String(data: data, encoding: .utf8) ?? "<unreadable>"
            if http.statusCode == 401 { throw AIError.authenticationFailed }
            if http.statusCode == 429 { throw AIError.rateLimited }
            throw AIError.sendFailed(message: "HTTP \(http.statusCode): \(body)")
        }

        struct Response: Decodable {
            struct Item: Decodable { let embedding: [Float] }
            let data: [Item]
        }
        let parsed = try JSONDecoder().decode(Response.self, from: data)
        guard let first = parsed.data.first else {
            throw AIError.decodingFailed(message: "No embedding in response")
        }
        return first.embedding
    }
}

extension OpenAIEmbeddingProvider: KnowledgeBaseEmbeddingProvider {}

// MARK: - Vector helpers

public enum EmbeddingMath {
    /// Cosine similarity in `[-1, 1]`. Higher is more similar. Returns 0 on zero vectors.
    public static func cosineSimilarity(_ a: [Float], _ b: [Float]) -> Float {
        guard a.count == b.count, !a.isEmpty else { return 0 }
        var dot: Float = 0
        var na: Float = 0
        var nb: Float = 0
        for i in 0..<a.count {
            dot += a[i] * b[i]
            na += a[i] * a[i]
            nb += b[i] * b[i]
        }
        let denom = (na.squareRoot() * nb.squareRoot())
        return denom > 0 ? dot / denom : 0
    }

    /// Pack a Float32 vector into a little-endian Data blob suitable for SQLite BLOB.
    public static func pack(_ vector: [Float]) -> Data {
        var copy = vector
        return copy.withUnsafeMutableBufferPointer { buf in
            Data(buffer: buf)
        }
    }

    /// Unpack a Float32 little-endian blob back into `[Float]`.
    public static func unpack(_ data: Data) -> [Float] {
        let count = data.count / MemoryLayout<Float>.size
        return data.withUnsafeBytes { raw -> [Float] in
            guard count > 0 else { return [] }
            return (0..<count).map { index in
                raw.loadUnaligned(
                    fromByteOffset: index * MemoryLayout<Float>.size,
                    as: Float.self
                )
            }
        }
    }
}

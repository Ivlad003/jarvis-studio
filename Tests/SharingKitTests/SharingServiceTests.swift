import Foundation
import Testing
import StorageKit
@testable import SharingKit

@Suite("SharingService selected artifacts")
struct SharingServiceTests {

    actor RecordingHTTPClient {
        private(set) var paths: [String] = []

        func handle(_ request: URLRequest, _ body: Data?) async throws -> (Data, URLResponse) {
            Issue.record("SharingService should upload artifacts through fileHTTPClient, not load Data into memory")
            let response = HTTPURLResponse(url: request.url!, statusCode: 500, httpVersion: nil, headerFields: [:])!
            return (body ?? Data(), response)
        }

        func handleFile(_ request: URLRequest, _ fileURL: URL) async throws -> (Data, URLResponse) {
            paths.append(request.url?.path ?? "")
            #expect(FileManager.default.fileExists(atPath: fileURL.path))
            let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: [:])!
            return (Data(), response)
        }
    }

    @Test("shareSession uploads only the requested artifacts")
    func shareSessionUploadsOnlySelectedArtifacts() async throws {
        let dir = URL.temporaryDirectory.appendingPathComponent("SharingServiceTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        try Data("audio".utf8).write(to: dir.appendingPathComponent("audio.m4a"))
        try Data("summary".utf8).write(to: dir.appendingPathComponent("summary.md"))
        try Data("transcript".utf8).write(to: dir.appendingPathComponent("transcript.txt"))

        let recorder = RecordingHTTPClient()
        let client = S3Client(
            endpoint: URL(string: "https://s3.example.test")!,
            region: "us-east-1",
            bucket: "bucket",
            credentials: .init(accessKeyId: "key", secretAccessKey: "secret"),
            httpClient: { request, body in
                try await recorder.handle(request, body)
            },
            fileHTTPClient: { request, fileURL in
                try await recorder.handleFile(request, fileURL)
            }
        )
        let service = SharingService(s3: client, keyPrefix: "kosmonotes/", presignTTLSeconds: 3600)

        let result = try await service.shareSession(
            sessionDir: dir,
            sessionId: "sid-123",
            artifacts: [.audio, .transcript]
        )

        #expect(await recorder.paths == [
            "/bucket/kosmonotes/sid-123/audio.m4a",
            "/bucket/kosmonotes/sid-123/transcript.txt",
        ])
        #expect(result.audioURL != nil)
        #expect(result.transcriptURL != nil)
        #expect(result.summaryURL == nil)
    }
}

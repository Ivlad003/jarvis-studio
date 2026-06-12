import Foundation
import Testing
@testable import TranscriptionKit

@Suite("WhisperKitModelManager local state")
struct WhisperKitModelManagerTests {
    @Test("in-progress marker keeps a partial model from reading as downloaded")
    func inProgressMarkerBlocksDownloadedState() async throws {
        let root = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }

        let manager = WhisperKitModelManager(rootDir: root)
        let folder = manager.variantFolder("openai_whisper-base")
        try FileManager.default.createDirectory(at: folder.appendingPathComponent("AudioEncoder.mlmodelc"), withIntermediateDirectories: true)
        try Data().write(to: folder.appendingPathComponent(WhisperKitModelManager.downloadInProgressMarkerName))

        let downloaded = await manager.isDownloaded("openai_whisper-base")

        #expect(downloaded == false)
    }

    @Test("complete marker plus compiled model reads as downloaded")
    func completeMarkerAllowsDownloadedState() async throws {
        let root = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }

        let manager = WhisperKitModelManager(rootDir: root)
        let folder = manager.variantFolder("openai_whisper-base")
        try FileManager.default.createDirectory(at: folder.appendingPathComponent("AudioEncoder.mlmodelc"), withIntermediateDirectories: true)
        try Data().write(to: folder.appendingPathComponent(WhisperKitModelManager.downloadCompleteMarkerName))

        let downloaded = await manager.isDownloaded("openai_whisper-base")

        #expect(downloaded == true)
    }

    private func makeTempDir() throws -> URL {
        let tmpDir = URL.temporaryDirectory.appendingPathComponent("KosmoNotesWhisperKitModelTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
        return tmpDir
    }
}

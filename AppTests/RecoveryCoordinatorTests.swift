import Foundation
import Testing
import StorageKit
@testable import KosmoNotes

@MainActor
@Suite("Recovery coordinator")
struct RecoveryCoordinatorTests {

    @Test("declined recovery prompt returns without blocking")
    func declinedRecoveryPromptReturnsWithoutBlocking() async throws {
        let tmpDir = URL.temporaryDirectory.appendingPathComponent("KosmoNotesRecoveryCoordinator-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: tmpDir) }

        let recordingsDir = tmpDir.appendingPathComponent("recordings")
        let orphanSegmentsDir = recordingsDir.appendingPathComponent("interrupted-session/segments")
        try FileManager.default.createDirectory(at: orphanSegmentsDir, withIntermediateDirectories: true)
        try Data("placeholder".utf8).write(to: orphanSegmentsDir.appendingPathComponent("0.m4a"))

        let db = try AppDatabase(path: tmpDir.appendingPathComponent("sessions.sqlite"))
        try await db.migrate()
        let store = try SessionStore(rootDir: recordingsDir, database: db)
        let coordinator = RecoveryCoordinator(
            sessionStore: store,
            database: db,
            promptResponseOverride: { orphans in
                #expect(orphans.map(\.id) == ["interrupted-session"])
                return .alertSecondButtonReturn
            }
        )

        let result = await coordinator.runAtLaunch(rootDir: recordingsDir)

        guard case .userDeclined = result else {
            Issue.record("Expected userDeclined, got \(result)")
            return
        }
    }
}

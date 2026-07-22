import Foundation
import Testing
@testable import KosmoNotes

@MainActor
@Suite("MigrationService", .serialized)
struct MigrationServiceTests {
    private let didMigrateKey = "didMigrateFromJarvisNote_v1"

    @Test("migration sentinel is not set when a required step fails")
    func sentinelIsNotSetWhenKeychainMigrationFails() throws {
        let (suiteName, defaults) = try makeDefaults()
        let tmpDir = try makeTempDir()
        defer {
            defaults.removePersistentDomain(forName: suiteName)
            try? FileManager.default.removeItem(at: tmpDir)
        }

        MigrationService.runIfNeeded(
            defaults: defaults,
            appSupportRoot: tmpDir.appendingPathComponent("Application Support"),
            migrateKeychain: { false }
        )

        #expect(defaults.bool(forKey: didMigrateKey) == false)
    }

    @Test("migration sentinel is set after clean successful pass")
    func sentinelIsSetAfterSuccessfulPass() throws {
        let (suiteName, defaults) = try makeDefaults()
        let tmpDir = try makeTempDir()
        defer {
            defaults.removePersistentDomain(forName: suiteName)
            try? FileManager.default.removeItem(at: tmpDir)
        }

        MigrationService.runIfNeeded(
            defaults: defaults,
            appSupportRoot: tmpDir.appendingPathComponent("Application Support"),
            migrateKeychain: { true }
        )

        #expect(defaults.bool(forKey: didMigrateKey) == true)
    }

    private func makeDefaults() throws -> (String, UserDefaults) {
        let suiteName = "KosmoNotesMigrationTests-\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suiteName) else {
            throw CocoaError(.fileNoSuchFile)
        }
        defaults.removePersistentDomain(forName: suiteName)
        return (suiteName, defaults)
    }

    private func makeTempDir() throws -> URL {
        let tmpDir = URL.temporaryDirectory.appendingPathComponent("KosmoNotesMigrationTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
        return tmpDir
    }
}

import AppKit
import Foundation
import StorageKit

// MARK: - RecoveryCoordinator

/// Runs at launch to find and optionally finalize orphan sessions.
///
/// An orphan is a session directory that has segments on disk but no audio.m4a
/// — left behind by a crash or SIGKILL before RecorderState could stop cleanly.
@available(macOS 14.0, *)
@MainActor
final class RecoveryCoordinator {

    enum Result: Sendable {
        case noOrphans
        case userDeclined
        case recovered(count: Int)
        case partial(recovered: Int, failed: Int)
    }

    private let recoveryService = RecoveryService()
    private let sessionStore: SessionStore
    private let database: AppDatabase
    private let promptResponseOverride: (([RecoveryService.OrphanSession]) -> NSApplication.ModalResponse)?

    init(
        sessionStore: SessionStore,
        database: AppDatabase,
        promptResponseOverride: (([RecoveryService.OrphanSession]) -> NSApplication.ModalResponse)? = nil
    ) {
        self.sessionStore = sessionStore
        self.database = database
        self.promptResponseOverride = promptResponseOverride
    }

    /// Scan for orphans; if any exist, prompt the user via a blocking NSAlert.
    /// On "Recover", finalize each orphan and mark its DB row as .failed so the
    /// Library shows it with a clear status (user can re-trigger transcription later).
    func runAtLaunch(rootDir: URL) async -> Result {
        let orphans: [RecoveryService.OrphanSession]
        do {
            orphans = try recoveryService.scanForOrphans(rootDir: rootDir)
        } catch {
            // Scan failure is non-fatal — treat as no orphans rather than blocking launch.
            return .noOrphans
        }

        guard !orphans.isEmpty else { return .noOrphans }

        let response: NSApplication.ModalResponse
        if let promptResponseOverride {
            response = promptResponseOverride(orphans)
        } else {
            // Bring app into regular mode so the alert is visible over other windows.
            NSApp.setActivationPolicy(.regular)
            NSApp.activate(ignoringOtherApps: true)
            response = showPromptAlert(orphans: orphans)
        }
        guard response == .alertFirstButtonReturn else { return .userDeclined }

        var recovered = 0
        var failed = 0

        for orphan in orphans {
            do {
                try await recoveryService.finalize(orphan)
                // Update or insert the DB row so the Library reflects the recovered session.
                await markSessionFailed(orphan: orphan)
                recovered += 1
            } catch RecoveryService.RecoveryError.noSegmentsFound {
                // Truly empty orphan — segments dir contains only zero-frame
                // .m4a stubs (user pressed Record then Stop instantly, or the
                // app crashed before any PCM buffer arrived). There's nothing
                // to salvage; purge the dir + DB row so it stops triggering
                // recovery prompts on every launch.
                await purgeEmptyOrphan(orphan)
            } catch {
                // Partial failure — keep processing remaining orphans.
                failed += 1
            }
        }

        if failed == 0 {
            return .recovered(count: recovered)
        } else {
            return .partial(recovered: recovered, failed: failed)
        }
    }

    // MARK: - Private

    /// Build and run the blocking prompt alert. Returns the modal response.
    private func showPromptAlert(orphans: [RecoveryService.OrphanSession]) -> NSApplication.ModalResponse {
        let alert = NSAlert()
        alert.messageText = "Recover \(orphans.count) interrupted recording(s)?"

        // Show up to 5 sessions by name + segment count; truncate the rest.
        let lines = orphans.prefix(5).map { "• \($0.id) — \($0.segmentURLs.count) segment(s)" }
        var info = lines.joined(separator: "\n")
        if orphans.count > 5 {
            info += "\n…+\(orphans.count - 5) more"
        }
        alert.informativeText = info
        alert.addButton(withTitle: "Recover")
        alert.addButton(withTitle: "Skip")
        alert.alertStyle = .warning
        return alert.runModal()
    }

    /// Upsert the session DB row with status=.failed so the Library can display it,
    /// AND rewrite session.json so the on-disk sidecar matches.
    ///
    /// "Filesystem sidecars are source of truth, SQLite is rebuildable index" is
    /// the project invariant. The previous version touched only the DB, leaving
    /// session.json with status=.recording — a rebuild from sidecars would then
    /// undo the recovery's status update.
    ///
    /// Reads session.json if present to preserve recordedAt/mode/language; falls
    /// back to safe defaults when the sidecar is missing (crash before first write).
    private func markSessionFailed(orphan: RecoveryService.OrphanSession) async {
        let sessionJSONURL = orphan.sessionDir.appendingPathComponent("session.json")

        // Attempt to read the existing sidecar so we preserve metadata.
        let existing: SessionRecord? = try? {
            let data = try Data(contentsOf: sessionJSONURL)
            return try JSONDecoder().decode(SessionRecord.self, from: data)
        }()

        let record = SessionRecord(
            id: orphan.id,
            recordedAt: existing?.recordedAt ?? dirCreationDate(orphan.sessionDir),
            durationSecs: existing?.durationSecs ?? 0,
            mode: existing?.mode ?? .meeting,
            language: existing?.language,
            status: .failed
        )

        // Rewrite the sidecar first (fs is source of truth). Atomic + durable.
        do {
            try AtomicWriter.writeJSON(record, to: sessionJSONURL)
        } catch {
            // Continue to DB update even if sidecar rewrite fails — the row at
            // least gives the Library something to render. Recovery is best-effort.
        }

        // Try update first; if the row doesn't exist yet, insert it.
        do {
            if try await database.session(id: orphan.id) != nil {
                try await database.updateSession(record)
            } else {
                try await database.insertSession(record)
            }
        } catch {
            // DB failure after successful finalize is non-fatal — audio.m4a is on disk.
        }
    }

    /// Wipe the orphan's session directory + any DB row for it. Called when
    /// the segments are empty / unrecoverable — there's no transcript-able
    /// audio to salvage, and leaving the dir behind would re-trigger the
    /// "recover N interrupted recordings?" prompt on every future launch.
    private func purgeEmptyOrphan(_ orphan: RecoveryService.OrphanSession) async {
        try? FileManager.default.removeItem(at: orphan.sessionDir)
        try? await database.deleteSession(id: orphan.id)
    }

    /// Returns the filesystem creation date of a directory, or now() as a fallback.
    private nonisolated func dirCreationDate(_ url: URL) -> Date {
        let attrs = try? FileManager.default.attributesOfItem(atPath: url.path)
        return (attrs?[.creationDate] as? Date) ?? Date()
    }
}

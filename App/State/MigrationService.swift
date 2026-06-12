import Foundation
import os
@preconcurrency import KeychainAccess

private let migrationLog = Logger(subsystem: "dev.kosmonotes.studio", category: "Migration")

// MARK: - MigrationService
//
// One-time renames from JarvisNote → KosmoNotes. Runs before AppSettings is
// constructed (so Keychain reads land on already-migrated entries) and before
// the recordings DB is opened (so SessionStore points at the renamed dir).
//
// Idempotent: each step short-circuits if the new location is already populated
// or the old location is missing. Safe to call on every launch.

@MainActor
enum MigrationService {

    /// Sentinel — once flipped to true we stop probing the legacy paths.
    private static let didMigrateKey = "didMigrateFromJarvisNote_v1"

    /// Old + new constants kept in one place so the Keychain / FS rename
    /// stays in sync. The new values must mirror the live Keychain service
    /// + bundle ID; old values are frozen literals.
    private enum Const {
        static let oldKeychainService = "dev.jarvisnote.studio"
        static let newKeychainService = "dev.kosmonotes.studio"
        static let oldAppSupportDir = "JarvisNote"
        static let newAppSupportDir = "KosmoNotes"
        static let oldAgentDocsDir = "JarvisNote-agent"
        static let newAgentDocsDir = "KosmoNotes-agent"
    }

    /// Top-level entry. Called once from `applicationDidFinishLaunching`
    /// before any subsystem reads from Keychain or the AppSupport folder.
    static func runIfNeeded(
        defaults: UserDefaults = .standard,
        appSupportRoot: URL? = nil,
        documentsRoot: URL? = nil,
        migrateKeychain: () -> Bool = MigrationService.migrateKeychain
    ) {
        if defaults.bool(forKey: didMigrateKey) {
            return
        }
        let appSupportOK = migrateAppSupport(root: appSupportRoot)
        let agentWorkspaceOK = migrateAgentWorkspace(root: documentsRoot)
        let keychainOK = migrateKeychain()
        guard appSupportOK, agentWorkspaceOK, keychainOK else {
            migrationLog.error("MigrationService: JarvisNote → KosmoNotes rename incomplete; will retry on next launch")
            return
        }
        defaults.set(true, forKey: didMigrateKey)
        migrationLog.info("MigrationService: completed JarvisNote → KosmoNotes rename")
    }

    // MARK: - Application Support

    /// `~/Library/Application Support/JarvisNote/` → `…/KosmoNotes/`. Skips
    /// if the new dir already exists (don't clobber a fresh install) or the
    /// old dir is absent (clean install on this machine).
    private static func migrateAppSupport(root injectedRoot: URL? = nil) -> Bool {
        let fm = FileManager.default
        let appSupport: URL
        if let injectedRoot {
            appSupport = injectedRoot
        } else if let resolved = try? fm.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true) {
            appSupport = resolved
        } else {
            return false
        }
        let oldURL = appSupport.appendingPathComponent(Const.oldAppSupportDir, isDirectory: true)
        let newURL = appSupport.appendingPathComponent(Const.newAppSupportDir, isDirectory: true)

        guard fm.fileExists(atPath: oldURL.path) else { return true }
        if fm.fileExists(atPath: newURL.path) {
            migrationLog.info("MigrationService: \(newURL.path, privacy: .public) already exists — skipping AppSupport move")
            return true
        }
        do {
            try fm.moveItem(at: oldURL, to: newURL)
            migrationLog.info("MigrationService: moved \(oldURL.path, privacy: .public) → \(newURL.path, privacy: .public)")
            return true
        } catch {
            migrationLog.error("MigrationService: AppSupport move failed — \(error.localizedDescription, privacy: .public)")
            return false
        }
    }

    /// `~/Documents/JarvisNote-agent/` → `…/KosmoNotes-agent/`. Same rules.
    /// User-set workspace overrides (AppSettings.agentWorkspaceFolder) are
    /// untouched — only the default location.
    private static func migrateAgentWorkspace(root injectedRoot: URL? = nil) -> Bool {
        let fm = FileManager.default
        let docs = injectedRoot ?? fm.urls(for: .documentDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Documents")
        let oldURL = docs.appendingPathComponent(Const.oldAgentDocsDir, isDirectory: true)
        let newURL = docs.appendingPathComponent(Const.newAgentDocsDir, isDirectory: true)
        guard fm.fileExists(atPath: oldURL.path), !fm.fileExists(atPath: newURL.path) else { return true }
        do {
            try fm.moveItem(at: oldURL, to: newURL)
            migrationLog.info("MigrationService: moved agent workspace \(oldURL.path, privacy: .public) → \(newURL.path, privacy: .public)")
            return true
        } catch {
            migrationLog.error("MigrationService: agent workspace move failed — \(error.localizedDescription, privacy: .public)")
            return false
        }
    }

    // MARK: - Keychain

    /// Copy every account from the old Keychain service to the new one,
    /// then delete from old. Skips any account that already has a value
    /// under the new service so a re-run can't blow away a freshly-typed key.
    private static func migrateKeychain() -> Bool {
        let oldKC = Keychain(service: Const.oldKeychainService).accessibility(.afterFirstUnlockThisDeviceOnly)
        let newKC = Keychain(service: Const.newKeychainService).accessibility(.afterFirstUnlockThisDeviceOnly)

        // Hardcoded list of every account name we've ever used. Mirrors
        // AppSettings.KeychainAccount.allCases; pinned here so changes to
        // that enum don't silently drop a migration.
        let accounts = [
            "deepgram.api_key",
            "openai.api_key",
            "anthropic.api_key",
            "ollama.bearer_token",
            "openrouter.api_key",
            "gemini.api_key",
            "s3.access_key_id",
            "s3.secret_access_key",
        ]

        var succeeded = true
        for account in accounts {
            do {
                if (try newKC.get(account))?.isEmpty == false { continue }
                guard let value = try oldKC.get(account), !value.isEmpty else { continue }
                try newKC.set(value, key: account)
                try? oldKC.remove(account)
                migrationLog.info("MigrationService: migrated keychain entry '\(account, privacy: .public)'")
            } catch {
                succeeded = false
                migrationLog.error("MigrationService: keychain '\(account, privacy: .public)' move failed — \(error.localizedDescription, privacy: .public)")
            }
        }
        return succeeded
    }
}

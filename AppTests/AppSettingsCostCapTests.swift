import Foundation
import Testing
@testable import KosmoNotes

@MainActor
@Suite("AppSettings cost cap", .serialized)
struct AppSettingsCostCapTests {
    private let costCapUSDKey = "costCapUSD"
    private let echoCancellationEnabledKey = "echoCancellationEnabled"
    private let echoCancellationMigratedOffKey = "echoCancellationMigratedOff_v1"

    @Test("missing cost cap defaults to one dollar")
    func missingCostCapDefaultsToOneDollar() {
        let prior = UserDefaults.standard.object(forKey: costCapUSDKey)
        UserDefaults.standard.removeObject(forKey: costCapUSDKey)
        defer { restore(prior, forKey: costCapUSDKey) }

        let settings = AppSettings()

        #expect(settings.costCapUSD == 1.00)
    }

    @Test("stored zero cost cap is preserved")
    func storedZeroCostCapIsPreserved() {
        let prior = UserDefaults.standard.object(forKey: costCapUSDKey)
        UserDefaults.standard.set(0.0, forKey: costCapUSDKey)
        defer { restore(prior, forKey: costCapUSDKey) }

        let settings = AppSettings()

        #expect(settings.costCapUSD == 0.0)
    }

    // Echo cancellation defaults OFF: VoiceProcessingIO has never delivered
    // audio on this input-tap-only engine (see AudioEngine NOTE). A one-time
    // migration flips the legacy D21 default (`true`) to false.

    @Test("missing echo cancellation preference defaults off")
    func missingEchoCancellationPreferenceDefaultsOff() {
        let priorPref = UserDefaults.standard.object(forKey: echoCancellationEnabledKey)
        let priorMig = UserDefaults.standard.object(forKey: echoCancellationMigratedOffKey)
        UserDefaults.standard.removeObject(forKey: echoCancellationEnabledKey)
        // Migration already done — isolates the default from the migration path.
        UserDefaults.standard.set(true, forKey: echoCancellationMigratedOffKey)
        defer {
            restore(priorPref, forKey: echoCancellationEnabledKey)
            restore(priorMig, forKey: echoCancellationMigratedOffKey)
        }

        let settings = AppSettings()

        #expect(settings.echoCancellationEnabled == false)
    }

    @Test("legacy enabled echo cancellation is migrated off once")
    func legacyEnabledEchoCancellationIsMigratedOff() {
        let priorPref = UserDefaults.standard.object(forKey: echoCancellationEnabledKey)
        let priorMig = UserDefaults.standard.object(forKey: echoCancellationMigratedOffKey)
        UserDefaults.standard.set(true, forKey: echoCancellationEnabledKey)        // old D21 default persisted
        UserDefaults.standard.removeObject(forKey: echoCancellationMigratedOffKey) // migration not yet run
        defer {
            restore(priorPref, forKey: echoCancellationEnabledKey)
            restore(priorMig, forKey: echoCancellationMigratedOffKey)
        }

        let settings = AppSettings()

        #expect(settings.echoCancellationEnabled == false)
        #expect(UserDefaults.standard.bool(forKey: echoCancellationMigratedOffKey) == true)
    }

    @Test("echo cancellation re-enabled after migration is preserved")
    func echoCancellationReenabledAfterMigrationIsPreserved() {
        let priorPref = UserDefaults.standard.object(forKey: echoCancellationEnabledKey)
        let priorMig = UserDefaults.standard.object(forKey: echoCancellationMigratedOffKey)
        UserDefaults.standard.set(true, forKey: echoCancellationEnabledKey)
        UserDefaults.standard.set(true, forKey: echoCancellationMigratedOffKey) // migration already done
        defer {
            restore(priorPref, forKey: echoCancellationEnabledKey)
            restore(priorMig, forKey: echoCancellationMigratedOffKey)
        }

        let settings = AppSettings()

        #expect(settings.echoCancellationEnabled == true)
    }

    @Test("empty keychain commit is skipped after a read failure")
    func emptyKeychainCommitIsSkippedAfterReadFailure() {
        #expect(AppSettings.keychainCommitAction(trimmedValue: "", readFailed: true) == .skipEmptyRemovalAfterReadFailure)
        #expect(AppSettings.keychainCommitAction(trimmedValue: "", readFailed: false) == .remove)
        #expect(AppSettings.keychainCommitAction(trimmedValue: "abc", readFailed: true) == .set("abc"))
    }

    @Test("privacy copy distinguishes live streaming, batch upload, and local transcription")
    func privacyCopyDistinguishesProviderDataFlow() throws {
        let copy = SettingsCopy.audioHandling

        #expect(copy.contains("Deepgram live streaming sends microphone audio during recording."))
        #expect(copy.contains("Batch cloud transcription uploads audio after Stop."))
        #expect(copy.contains("WhisperKit keeps transcription on this Mac."))
        #expect(!copy.contains("every recorded second of audio is uploaded"))
        #expect(!copy.contains("There is no on-device transcription"))
    }

    @Test("cost cap copy includes live transcription preflight")
    func costCapCopyIncludesLiveTranscriptionPreflight() throws {
        let copy = SettingsCopy.costCapDescription

        #expect(copy.contains("known transcription estimates"))
        #expect(copy.contains("Deepgram live transcription is checked before recording starts"))
        #expect(!copy.contains("AI summary requests above this estimate are silently skipped"))
    }

    private func restore(_ value: Any?, forKey key: String) {
        if let value {
            UserDefaults.standard.set(value, forKey: key)
        } else {
            UserDefaults.standard.removeObject(forKey: key)
        }
    }
}

import Foundation
import Testing
@testable import KosmoNotes

@MainActor
@Suite("AppSettings cost cap", .serialized)
struct AppSettingsCostCapTests {
    private let costCapUSDKey = "costCapUSD"
    private let echoCancellationEnabledKey = "echoCancellationEnabled"

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

    @Test("missing echo cancellation preference defaults on")
    func missingEchoCancellationPreferenceDefaultsOn() {
        let prior = UserDefaults.standard.object(forKey: echoCancellationEnabledKey)
        UserDefaults.standard.removeObject(forKey: echoCancellationEnabledKey)
        defer { restore(prior, forKey: echoCancellationEnabledKey) }

        let settings = AppSettings()

        #expect(settings.echoCancellationEnabled == true)
    }

    @Test("stored disabled echo cancellation preference is preserved")
    func storedDisabledEchoCancellationPreferenceIsPreserved() {
        let prior = UserDefaults.standard.object(forKey: echoCancellationEnabledKey)
        UserDefaults.standard.set(false, forKey: echoCancellationEnabledKey)
        defer { restore(prior, forKey: echoCancellationEnabledKey) }

        let settings = AppSettings()

        #expect(settings.echoCancellationEnabled == false)
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

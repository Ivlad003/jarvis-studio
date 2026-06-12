import Foundation
import Observation
import os
import TranscriptionKit

private let downloadLog = Logger(subsystem: "dev.kosmonotes.studio", category: "WhisperKitDownload")

// MARK: - WhisperKitDownloadState

/// @Observable view-model for Settings → Transcription → Local (WhisperKit).
/// Wraps `WhisperKitModelManager` with main-actor-friendly observable state
/// so SwiftUI can bind directly. Designed to outlive any single open of the
/// Settings window — a user can start a download, close Settings, open it
/// later and still see progress / completion.
@available(macOS 14.0, *)
@Observable
@MainActor
final class WhisperKitDownloadState {

    // MARK: - Observable state

    /// All known variants from HuggingFace (or fallback list when offline).
    /// Sorted alphabetically.
    var availableVariants: [String] = []
    /// Variant ids currently on disk.
    var downloadedVariants: Set<String> = []
    /// Bytes-on-disk per downloaded variant; absent when not downloaded.
    var sizesOnDisk: [String: Int64] = [:]
    /// Hint from WhisperKit on what the running device supports.
    var recommendedDefault: String?
    /// Variant currently downloading + its 0...1 progress; nil when idle.
    var inFlight: (variant: String, progress: Double)?
    /// One-shot human-readable error from the most recent failure; cleared
    /// when the user starts a new action.
    var lastError: String?
    /// True while `refreshCatalogue()` is in flight so the UI can show a spinner.
    var loadingCatalogue: Bool = false

    // MARK: - Dependencies

    private let manager: WhisperKitModelManager
    private var downloadGeneration = 0

    init(manager: WhisperKitModelManager) {
        self.manager = manager
    }

    // MARK: - Public API

    /// Pull live variant list + recompute downloaded set.
    func refreshCatalogue() async {
        loadingCatalogue = true
        let variants = await manager.availableVariants()
        let downloaded = await manager.downloadedVariants()
        var sizes: [String: Int64] = [:]
        for v in downloaded {
            let bytes = await manager.sizeOnDisk(v)
            sizes[v] = bytes
        }
        let recommendedRaw = await manager.recommendedDefault()
        self.availableVariants = variants
        self.downloadedVariants = Set(downloaded)
        self.sizesOnDisk = sizes
        self.recommendedDefault = recommendedRaw
        self.loadingCatalogue = false
    }

    /// Kick off a download. Updates `inFlight` until completion. Caller is
    /// responsible for guarding against concurrent downloads — this method
    /// does not queue.
    func download(_ variant: String) async {
        guard inFlight == nil else {
            lastError = "Another download is already running. Wait for it to finish."
            return
        }
        lastError = nil
        downloadGeneration += 1
        let generation = downloadGeneration
        inFlight = (variant, 0)
        defer {
            if downloadGeneration == generation {
                inFlight = nil
            }
        }

        do {
            try await manager.download(variant: variant) { [weak self] fraction in
                Task { @MainActor [weak self] in
                    guard let self,
                          Self.shouldApplyProgress(
                              callbackGeneration: generation,
                              currentGeneration: self.downloadGeneration,
                              callbackVariant: variant,
                              currentInFlightVariant: self.inFlight?.variant
                          ) else { return }
                    self.inFlight = (variant, fraction)
                }
            }
            // Repopulate downloaded set + sizes after success.
            await refreshCatalogue()
            downloadLog.info("WhisperKitDownloadState.download: \(variant, privacy: .public) complete")
        } catch {
            lastError = "Download failed: \(error.localizedDescription)"
            downloadLog.error("WhisperKitDownloadState.download: \(variant, privacy: .public) failed — \(error.localizedDescription, privacy: .public)")
        }
    }

    /// Remove a variant from disk. Returns immediately on the main actor;
    /// updates `downloadedVariants` once the deletion completes.
    func delete(_ variant: String) async {
        do {
            try await manager.delete(variant: variant)
            await refreshCatalogue()
            downloadLog.info("WhisperKitDownloadState.delete: \(variant, privacy: .public)")
        } catch {
            lastError = "Delete failed: \(error.localizedDescription)"
            downloadLog.error("WhisperKitDownloadState.delete: \(variant, privacy: .public) failed — \(error.localizedDescription, privacy: .public)")
        }
    }

    // MARK: - Helpers

    func isDownloaded(_ variant: String) -> Bool {
        downloadedVariants.contains(variant)
    }

    static func shouldApplyProgress(
        callbackGeneration: Int,
        currentGeneration: Int,
        callbackVariant: String,
        currentInFlightVariant: String?
    ) -> Bool {
        callbackGeneration == currentGeneration && callbackVariant == currentInFlightVariant
    }

    /// Format a size for the UI (e.g. "75 MB", "1.5 GB"). Bytes go through
    /// `ByteCountFormatter` so locale-correct units are used.
    func formattedSize(_ variant: String) -> String? {
        guard let bytes = sizesOnDisk[variant] else { return nil }
        let formatter = ByteCountFormatter()
        formatter.allowedUnits = [.useMB, .useGB]
        formatter.countStyle = .file
        return formatter.string(fromByteCount: bytes)
    }
}

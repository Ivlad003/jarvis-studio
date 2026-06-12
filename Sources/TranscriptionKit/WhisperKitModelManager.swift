@preconcurrency import Foundation
@preconcurrency import WhisperKit
import os

private let mgrLog = Logger(subsystem: "dev.kosmonotes.studio", category: "WhisperKitModels")

// MARK: - WhisperKitModelManager

/// Catalogue + on-disk lifecycle for WhisperKit models.
///
/// Three responsibilities:
///   1. Listing what's available remotely (HuggingFace `argmaxinc/whisperkit-coreml`).
///   2. Reporting what's already downloaded locally.
///   3. Downloading a chosen variant with progress + deleting it when no
///      longer needed.
///
/// The on-disk layout mirrors what `WhisperKit.download` writes — we just pin
/// the root to a stable folder so model state survives app relaunch and the
/// Settings UI can show "downloaded ✓" badges.
public actor WhisperKitModelManager {
    public static let downloadInProgressMarkerName = ".download-in-progress"
    public static let downloadCompleteMarkerName = ".download-complete"

    /// Root folder under which all WhisperKit models live. The default points
    /// at `~/Library/Application Support/KosmoNotes/whisperkit/`. Subfolders
    /// follow `<root>/argmaxinc/whisperkit-coreml/<variant>/...` per the HF
    /// snapshot layout.
    public let rootDir: URL

    /// HuggingFace repo to fetch from. Defaults to Argmax's official one.
    public let repo: String

    public init(rootDir: URL, repo: String = "argmaxinc/whisperkit-coreml") {
        self.rootDir = rootDir
        self.repo = repo
        try? FileManager.default.createDirectory(at: rootDir, withIntermediateDirectories: true)
    }

    // MARK: - Catalogue

    /// Live list of model variants from HuggingFace. Best-effort: returns the
    /// shipped fallback list when the network is offline so the UI still
    /// renders something usable.
    public func availableVariants() async -> [String] {
        do {
            let variants = try await WhisperKit.fetchAvailableModels(from: repo)
            mgrLog.info("WhisperKitModelManager.availableVariants: fetched \(variants.count, privacy: .public) variants from \(self.repo, privacy: .public)")
            return variants.sorted()
        } catch {
            mgrLog.error("WhisperKitModelManager.availableVariants: fetch failed — \(error.localizedDescription, privacy: .public). Falling back to recommended subset.")
            // Reasonable static fallback so the UI isn't empty when offline.
            return [
                "openai_whisper-tiny",
                "openai_whisper-tiny.en",
                "openai_whisper-base",
                "openai_whisper-base.en",
                "openai_whisper-small",
                "openai_whisper-small.en",
                "openai_whisper-medium",
                "openai_whisper-medium.en",
                "openai_whisper-large-v2",
                "openai_whisper-large-v3",
                "openai_whisper-large-v3-turbo",
                "distil-whisper_distil-small.en",
                "distil-whisper_distil-medium.en",
                "distil-whisper_distil-large-v3",
            ].sorted()
        }
    }

    /// What WhisperKit recommends for the running device (Apple Silicon chip
    /// detected via `WhisperKit.deviceName()`). Use to highlight a default
    /// pick in the picker.
    public func recommendedDefault() -> String? {
        let support = WhisperKit.recommendedModels()
        return support.default
    }

    // MARK: - Local state

    /// True when `<root>/argmaxinc/whisperkit-coreml/<variant>/` exists and
    /// contains at least one `.mlmodelc` file (the compiled CoreML bundle).
    public func isDownloaded(_ variant: String) -> Bool {
        let folder = variantFolder(variant)
        guard let entries = try? FileManager.default.contentsOfDirectory(atPath: folder.path) else {
            return false
        }
        let hasCompiledModel = entries.contains { $0.hasSuffix(".mlmodelc") }
        guard hasCompiledModel else { return false }

        let inProgress = folder.appendingPathComponent(Self.downloadInProgressMarkerName)
        if FileManager.default.fileExists(atPath: inProgress.path) {
            return false
        }

        let complete = folder.appendingPathComponent(Self.downloadCompleteMarkerName)
        if FileManager.default.fileExists(atPath: complete.path) {
            return true
        }

        // Backward compatibility for models downloaded before completion
        // markers existed. New interrupted downloads keep the in-progress marker
        // and are therefore not mistaken for usable models.
        return true
    }

    /// On-disk size in bytes of the variant's folder. 0 when not downloaded.
    public func sizeOnDisk(_ variant: String) -> Int64 {
        let folder = variantFolder(variant)
        return Self.directorySize(folder)
    }

    /// All variant ids that look downloaded under the model root.
    public func downloadedVariants() -> [String] {
        let snapshot = rootDir.appendingPathComponent("argmaxinc/whisperkit-coreml")
        guard let entries = try? FileManager.default.contentsOfDirectory(
            at: snapshot,
            includingPropertiesForKeys: [.isDirectoryKey]
        ) else {
            return []
        }
        return entries
            .filter { url in
                var isDir: ObjCBool = false
                FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir)
                return isDir.boolValue && modelFolderLooksDownloaded(url)
            }
            .map(\.lastPathComponent)
            .sorted()
    }

    // MARK: - Download / delete

    /// Download `variant` to `rootDir`, calling `onProgress(0.0...1.0)` as it
    /// progresses. Throws on failure; idempotent when the variant is already
    /// fully on disk (returns immediately).
    public func download(
        variant: String,
        onProgress: (@Sendable (Double) -> Void)? = nil
    ) async throws {
        if isDownloaded(variant) {
            mgrLog.info("WhisperKitModelManager.download: \(variant, privacy: .public) already on disk, skipping")
            onProgress?(1.0)
            return
        }
        mgrLog.info("WhisperKitModelManager.download: starting \(variant, privacy: .public) → \(self.rootDir.path, privacy: .public)")
        let started = Date()
        let folder = variantFolder(variant)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let inProgressMarker = folder.appendingPathComponent(Self.downloadInProgressMarkerName)
        let completeMarker = folder.appendingPathComponent(Self.downloadCompleteMarkerName)
        try? FileManager.default.removeItem(at: completeMarker)
        try Data().write(to: inProgressMarker)
        do {
            _ = try await WhisperKit.download(
                variant: variant,
                downloadBase: rootDir,
                useBackgroundSession: false,
                from: repo,
                progressCallback: { progress in
                    onProgress?(progress.fractionCompleted)
                }
            )
            let elapsed = Date().timeIntervalSince(started)
            try? FileManager.default.removeItem(at: inProgressMarker)
            try Data().write(to: completeMarker)
            mgrLog.info("WhisperKitModelManager.download: \(variant, privacy: .public) done in \(String(format: "%.1f", elapsed), privacy: .public)s")
            onProgress?(1.0)
        } catch {
            mgrLog.error("WhisperKitModelManager.download: \(variant, privacy: .public) failed — \(error.localizedDescription, privacy: .public)")
            throw error
        }
    }

    /// Remove a variant from disk. No-op when it isn't there.
    public func delete(variant: String) throws {
        let folder = variantFolder(variant)
        guard FileManager.default.fileExists(atPath: folder.path) else { return }
        try FileManager.default.removeItem(at: folder)
        mgrLog.info("WhisperKitModelManager.delete: removed \(variant, privacy: .public)")
    }

    // MARK: - Helpers

    /// Filesystem path for a given variant under the standard HF snapshot layout.
    public nonisolated func variantFolder(_ variant: String) -> URL {
        rootDir
            .appendingPathComponent("argmaxinc")
            .appendingPathComponent("whisperkit-coreml")
            .appendingPathComponent(variant)
    }

    private static func directorySize(_ url: URL) -> Int64 {
        let fm = FileManager.default
        guard let enumerator = fm.enumerator(
            at: url,
            includingPropertiesForKeys: [.isRegularFileKey, .totalFileAllocatedSizeKey],
            options: [.skipsHiddenFiles]
        ) else { return 0 }
        var total: Int64 = 0
        for case let fileURL as URL in enumerator {
            let values = try? fileURL.resourceValues(forKeys: [.isRegularFileKey, .totalFileAllocatedSizeKey])
            if values?.isRegularFile == true, let size = values?.totalFileAllocatedSize {
                total += Int64(size)
            }
        }
        return total
    }

    private nonisolated func modelFolderLooksDownloaded(_ folder: URL) -> Bool {
        guard let entries = try? FileManager.default.contentsOfDirectory(atPath: folder.path) else {
            return false
        }
        guard entries.contains(where: { $0.hasSuffix(".mlmodelc") }) else { return false }
        return !FileManager.default.fileExists(
            atPath: folder.appendingPathComponent(Self.downloadInProgressMarkerName).path
        )
    }
}

import AppKit
import Foundation
import Observation
import SharingKit
import StorageKit

// MARK: - ShareCoordinator

/// Builds an `S3Client` from the user's `AppSettings` and uploads a session's
/// sidecars. Surfaces a result modal with copy-to-pasteboard buttons.
@available(macOS 14.0, *)
@MainActor
final class ShareCoordinator {

    private let settings: AppSettings
    private let sessionStore: SessionStore

    init(settings: AppSettings, sessionStore: SessionStore) {
        self.settings = settings
        self.sessionStore = sessionStore
    }

    /// Validate config → pick artifacts → upload → save the resulting snapshot
    /// so Library can show "Already shared" links for this session → surface
    /// the URLs in an alert. Each step short-circuits cleanly on error.
    func share(sessionId: String) async {
        // Validate required fields up front so users see a clear error before we
        // try to encode an empty endpoint into a URL.
        guard let url = URL(string: settings.s3Endpoint), !settings.s3Endpoint.isEmpty else {
            alert("Set the S3 endpoint in Settings → Sharing first.")
            return
        }
        let bucket = settings.s3Bucket.trimmingCharacters(in: .whitespaces)
        guard !bucket.isEmpty else {
            alert("Set the S3 bucket name in Settings → Sharing first.")
            return
        }
        let access = settings.s3AccessKey.trimmingCharacters(in: .whitespaces)
        let secret = settings.s3SecretKey.trimmingCharacters(in: .whitespaces)
        guard !access.isEmpty, !secret.isEmpty else {
            alert("Set the S3 Access Key + Secret Access Key in Settings → Sharing first.")
            return
        }

        // What's actually on disk for this session — only those kinds show up
        // in the picker. Avoids users selecting "Video" for an audio-only
        // recording and getting a silent skip.
        let available = await sessionStore.availableShareArtifacts(for: sessionId)
        guard !available.isEmpty else {
            alert("Nothing to share — this session folder is empty.")
            return
        }

        guard let selected = promptArtifactSelection(from: available), !selected.isEmpty else {
            // User cancelled or unchecked everything — nothing to do.
            return
        }

        let client = S3Client(
            endpoint: url,
            region: settings.s3Region.isEmpty ? "us-east-1" : settings.s3Region,
            bucket: bucket,
            credentials: SigV4.Credentials(accessKeyId: access, secretAccessKey: secret)
        )
        let service = SharingService(
            s3: client,
            keyPrefix: "jarvis-note/",
            presignTTLSeconds: Self.clampedPresignTTLHours(settings.s3PresignTTLHours) * 3600
        )

        let dir = await sessionStore.sessionDir(for: sessionId)
        do {
            let result = try await service.shareSession(
                sessionDir: dir,
                sessionId: sessionId,
                artifacts: selected
            )
            // Persist the snapshot so Library shows the "Already shared" section
            // after the user closes the modal. Failure to persist is non-fatal
            // — the upload itself succeeded and the modal still shows URLs.
            let snapshot = SessionSharePlanning.snapshot(from: result, sharedAt: Date())
            if !snapshot.links.isEmpty {
                do {
                    try await sessionStore.saveSharedLinksSnapshot(snapshot, for: sessionId)
                } catch {
                    // Logged for the user via Settings → Logs; no user-facing
                    // warning since the actual upload succeeded.
                    NSLog("ShareCoordinator: saveSharedLinksSnapshot failed — \(error.localizedDescription)")
                }
            }
            presentResult(result)
        } catch {
            alert("Upload failed: \(error.localizedDescription)")
        }
    }

    // MARK: - UI

    /// Show a sheet-style alert with a checkbox per available artifact so the
    /// user picks what to upload. Returns the chosen kinds, or nil on Cancel.
    /// Pre-checks every available kind — the common case is "share all".
    private func promptArtifactSelection(from available: [SharedArtifactKind]) -> [SharedArtifactKind]? {
        let alert = NSAlert()
        alert.messageText = "Share to S3"
        alert.informativeText = "Pick which artifacts to upload. Presigned links are valid for \(Self.clampedPresignTTLHours(settings.s3PresignTTLHours)) h."
        alert.alertStyle = .informational

        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 6
        stack.translatesAutoresizingMaskIntoConstraints = false

        var checkboxes: [(SharedArtifactKind, NSButton)] = []
        for kind in available {
            let box = NSButton(checkboxWithTitle: kind.displayName, target: nil, action: nil)
            box.state = .on
            checkboxes.append((kind, box))
            stack.addArrangedSubview(box)
        }

        // Size the stack to fit the longest label plus padding so the alert
        // doesn't clip "Screen recording (.mp4)" on first show.
        let container = NSView(frame: NSRect(x: 0, y: 0, width: 280, height: max(20, CGFloat(checkboxes.count) * 22)))
        container.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            stack.topAnchor.constraint(equalTo: container.topAnchor),
            stack.bottomAnchor.constraint(equalTo: container.bottomAnchor),
        ])
        alert.accessoryView = container

        alert.addButton(withTitle: "Upload")
        alert.addButton(withTitle: "Cancel")

        let response = alert.runModal()
        guard response == .alertFirstButtonReturn else { return nil }
        return checkboxes.compactMap { kind, box in box.state == .on ? kind : nil }
    }

    static func clampedPresignTTLHours(_ hours: Int) -> Int {
        max(1, min(hours, 168))
    }

    private func presentResult(_ result: SharingService.ShareResult) {
        let alert = NSAlert()
        alert.messageText = "Session shared"
        alert.alertStyle = .informational

        // Ordered (label, url) pairs for whatever was actually uploaded. Short,
        // human labels — the raw presigned URLs stay off-screen so the modal
        // isn't a wall of query-string noise.
        let rows: [(label: String, url: URL)] = [
            ("Audio", result.audioURL),
            ("Screen recording", result.videoURL),
            ("Summary", result.summaryURL),
            ("Transcript", result.transcriptURL),
        ].compactMap { label, url in url.map { (label, $0) } }

        guard !rows.isEmpty else {
            alert.informativeText = "No artifacts uploaded — the session folder was empty."
            alert.addButton(withTitle: "OK")
            alert.runModal()
            return
        }

        alert.informativeText = "Each link is a presigned URL. Copy the ones you need — recipients open them in a browser."
        alert.accessoryView = makeCopyRows(rows)

        alert.addButton(withTitle: "Copy all")
        alert.addButton(withTitle: "Done")

        if alert.runModal() == .alertFirstButtonReturn {
            copyToPasteboard(rows.map(\.url.absoluteString).joined(separator: "\n"))
        }
    }

    /// One row per artifact: a label on the left and a dedicated "Copy link"
    /// button on the right that puts just that URL on the pasteboard. Handlers
    /// are retained by the returned view for the lifetime of the modal.
    private func makeCopyRows(_ rows: [(label: String, url: URL)]) -> NSView {
        var handlers: [CopyLinkHandler] = []
        var gridRows: [[NSView]] = []
        for row in rows {
            let handler = CopyLinkHandler(urlString: row.url.absoluteString)
            handlers.append(handler)

            let label = NSTextField(labelWithString: row.label)
            label.lineBreakMode = .byTruncatingTail

            let button = NSButton(title: "Copy link", target: handler, action: #selector(CopyLinkHandler.copy(_:)))
            button.bezelStyle = .rounded
            button.setContentHuggingPriority(.required, for: .horizontal)

            gridRows.append([label, button])
        }

        // Two aligned columns: labels on the left, "Copy link" buttons on the
        // right. The grid sizes column 0 to the widest label, so every button
        // starts at the same x and they line up with each other — no stretched
        // rows, no chasm between a short label and its button.
        let grid = NSGridView(views: gridRows)
        grid.translatesAutoresizingMaskIntoConstraints = false
        grid.rowSpacing = 10
        grid.columnSpacing = 24
        grid.column(at: 0).xPlacement = .leading
        grid.column(at: 1).xPlacement = .leading
        grid.rowAlignment = .firstBaseline

        // NSAlert lays out an accessory view by its `frame`, not by the Auto
        // Layout constraints inside it. Resolve the layout first, then hand back
        // a frame-based container sized to fit — otherwise the rows collapse to
        // zero height and overlap the message text above them.
        grid.layoutSubtreeIfNeeded()
        let size = grid.fittingSize

        let container = CopyRowsContainer(handlers: handlers)
        container.frame = NSRect(x: 0, y: 0, width: size.width, height: size.height)
        container.addSubview(grid)
        NSLayoutConstraint.activate([
            grid.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            grid.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            grid.topAnchor.constraint(equalTo: container.topAnchor),
            grid.bottomAnchor.constraint(equalTo: container.bottomAnchor),
        ])
        return container
    }

    private func copyToPasteboard(_ text: String) {
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(text, forType: .string)
    }

    private func alert(_ message: String) {
        let a = NSAlert()
        a.messageText = "Share"
        a.informativeText = message
        a.alertStyle = .warning
        a.runModal()
    }
}

// MARK: - Copy-link plumbing

/// Target for a single artifact's "Copy link" button. Copies its URL and
/// flashes "Copied ✓" briefly so the click is confirmed.
@available(macOS 14.0, *)
@MainActor
private final class CopyLinkHandler: NSObject {
    private let urlString: String

    init(urlString: String) {
        self.urlString = urlString
    }

    @objc func copy(_ sender: NSButton) {
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(urlString, forType: .string)

        let original = sender.title
        sender.title = "Copied ✓"
        sender.isEnabled = false
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) {
            sender.title = original
            sender.isEnabled = true
        }
    }
}

/// Retains the per-row copy handlers for the lifetime of the modal — NSButton's
/// `target` is a weak reference, so without this the handlers would deallocate
/// immediately and clicks would do nothing.
@available(macOS 14.0, *)
private final class CopyRowsContainer: NSView {
    private let handlers: [CopyLinkHandler]

    init(handlers: [CopyLinkHandler]) {
        self.handlers = handlers
        super.init(frame: .zero)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
}

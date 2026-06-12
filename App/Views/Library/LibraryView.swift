import SwiftUI
import AppKit
import AVKit
import AVFoundation
import StorageKit
import TranscriptionKit

// MARK: - LibraryView

@available(macOS 14.0, *)
struct LibraryView: View {

    @Bindable var state: LibraryState
    @State private var confirmClearAll: Bool = false

    var body: some View {
        NavigationSplitView {
            SidebarView(state: state)
                .navigationSplitViewColumnWidth(min: 240, ideal: 280)
        } detail: {
            if let sid = state.selectedSessionId,
               let session = state.sessions.first(where: { $0.id == sid }) {
                SessionDetailView(session: session, state: state)
                    // Re-create the detail view when selection changes so player resets.
                    .id(sid)
            } else {
                ContentUnavailableView(
                    "No Session Selected",
                    systemImage: "waveform",
                    description: Text("Choose a session from the sidebar.")
                )
            }
        }
        .frame(minWidth: 800, minHeight: 500)
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button(role: .destructive) {
                    confirmClearAll = true
                } label: {
                    Label("Clear All", systemImage: "trash.slash")
                }
                .help("Delete every recording, transcript, and screen capture from disk")
                .disabled(state.sessions.isEmpty)
            }
        }
        .confirmationDialog(
            "Delete every session?",
            isPresented: $confirmClearAll,
            titleVisibility: .visible
        ) {
            Button("Delete All", role: .destructive) {
                Task { await state.clearAllSessions() }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("All audio, transcripts, summaries, and screen recordings will be removed permanently. The database will also be cleared. This cannot be undone.")
        }
        .task {
            // Initial load when window opens.
            await state.refresh()
        }
    }
}

// MARK: - SidebarView

@available(macOS 14.0, *)
private struct SidebarView: View {

    @Bindable var state: LibraryState

    var body: some View {
        VStack(spacing: 0) {
            // Search field at top of sidebar.
            HStack {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(.secondary)
                TextField("Search transcripts…", text: $state.query)
                    .textFieldStyle(.plain)
                if !state.query.isEmpty {
                    Button {
                        state.query = ""
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.borderless)
                }
            }
            .padding(8)
            .background(.bar)

            Divider()

            // Mode filter picker.
            Picker("Filter", selection: $state.modeFilter) {
                ForEach(ModeFilter.allCases) { filter in
                    Text(filter.displayName).tag(filter)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .padding(.horizontal, 8)
            .padding(.vertical, 6)

            Divider()

            if state.sessions.isEmpty {
                Spacer()
                Text(state.query.isEmpty ? "No sessions yet." : "No results.")
                    .foregroundStyle(.secondary)
                    .font(.callout)
                Spacer()
            } else {
                List(state.sessions, id: \.id, selection: $state.selectedSessionId) { session in
                    SessionRowView(session: session, sessionStore: state.sessionStore)
                }
                .listStyle(.sidebar)
            }
        }
        .navigationTitle("Library")
    }
}

// MARK: - SessionRowView

@available(macOS 14.0, *)
private struct SessionRowView: View {

    let session: SessionRecord
    let sessionStore: SessionStore
    @State private var hasScreenRecording: Bool = false
    @State private var thumbImage: NSImage?
    /// Non-nil when `capture-warning.txt` was written to the session dir —
    /// i.e. tier-2 fallback demoted screen recording mid-session. Drives a
    /// capture-specific help string distinct from the post-process "partial
    /// enhancement" message.
    @State private var captureWarning: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 4) {
                Text(session.recordedAt.formatted(date: .abbreviated, time: .shortened))
                    .font(.subheadline)
                    .fontWeight(.medium)
                if hasScreenRecording {
                    Image(systemName: "video.fill")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .help("Screen recording available")
                }
                if session.enhancementStatus == .partial {
                    // Silent partial failures used to be invisible. The orange
                    // dot makes degraded sessions findable in the list. Two
                    // flavours of partial:
                    //   - capture-side (tier-2 demotion → screen.mp4 truncated)
                    //   - enhancement-side (cleanup/summary/export skipped)
                    // The help text reflects whichever signal is present.
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.caption2)
                        .foregroundStyle(.orange)
                        .help(captureWarning ?? "Some optional enhancements didn't complete (cleanup, summary, or export). The recording and transcript are intact.")
                }
            }
            // Waveform thumbnail (cached PNG; placeholder while loading).
            if let img = thumbImage {
                Image(nsImage: img)
                    .resizable()
                    .interpolation(.high)
                    .aspectRatio(contentMode: .fit)
                    .frame(height: 18)
                    .opacity(0.85)
            } else {
                // Placeholder: thin gray bar so the layout doesn't jump on render.
                Rectangle()
                    .fill(Color.secondary.opacity(0.12))
                    .frame(height: 4)
                    .clipShape(RoundedRectangle(cornerRadius: 2))
            }
            HStack(spacing: 6) {
                Label(session.mode.displayName,
                      systemImage: session.mode.iconName)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text("·")
                    .foregroundStyle(.secondary)
                    .font(.caption)
                Text(formatDuration(session.durationSecs))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 2)
        .task(id: session.id) {
            let root = await sessionStore.sessionDir(for: session.id)
            let screenURL = root.appendingPathComponent("screen.mp4")
            hasScreenRecording = FileManager.default.fileExists(atPath: screenURL.path)
            // Read the capture-warning sidecar so the
            // partial badge can show the right copy when tier-2 fallback
            // demoted screen recording.
            let captureURL = root.appendingPathComponent("capture-warning.txt")
            if let data = try? Data(contentsOf: captureURL),
               let raw = String(data: data, encoding: .utf8)?
                   .trimmingCharacters(in: .whitespacesAndNewlines),
               !raw.isEmpty {
                // Sidecar format: "screen-demoted: <message>" — strip the tag
                // prefix so the help text is just the human message.
                if let colon = raw.firstIndex(of: ":") {
                    captureWarning = String(raw[raw.index(after: colon)...])
                        .trimmingCharacters(in: .whitespaces)
                } else {
                    captureWarning = raw
                }
            }
            await loadThumbnail(sessionDir: root)
        }
    }

    /// Read or generate the waveform PNG and load it as an `NSImage`. Heavy work
    /// runs inside the WaveformGenerator actor, off the main thread.
    private func loadThumbnail(sessionDir: URL?) async {
        guard let dir = sessionDir else { return }
        // Prefer audio.m4a (always present); skip silently when the file is missing.
        let audioURL = dir.appendingPathComponent("audio.m4a")
        let generator = WaveformGenerator()
        guard let pngURL = await generator.thumbnailURL(for: dir, audioFile: audioURL) else {
            return
        }
        if let image = NSImage(contentsOf: pngURL) {
            thumbImage = image
        }
    }

    private func formatDuration(_ secs: TimeInterval) -> String {
        let total = Int(secs)
        let m = total / 60
        let s = total % 60
        return String(format: "%d:%02d", m, s)
    }
}

// MARK: - SessionDetailView

@available(macOS 14.0, *)
private struct SessionDetailView: View {

    let session: SessionRecord
    @Bindable var state: LibraryState

    // Player state lives here, not in LibraryState, because it's ephemeral UI-only.
    @State private var playerModel = PlayerModel()
    @State private var segments: [TranscriptSegment] = []
    @State private var segmentsLoading = true
    @State private var hasScreenVideo: Bool = false
    @State private var sharedLinks: SharedLinksSnapshot?
    @State private var exportError: String?
    @State private var confirmDelete: Bool = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Header
            SessionHeaderView(session: session)
                .padding()

            Divider()

            // Player. Tall enough to show the screen.mp4 frame at a usable
            // size when one exists; collapsed to the audio scrubber bar otherwise.
            AVPlayerRepresentable(model: playerModel)
                .frame(height: hasScreenVideo ? 280 : 44)
                .padding(.horizontal)
                .padding(.vertical, 8)

            // Skip buttons + Export menu + Open in Finder.
            HStack(spacing: 16) {
                Button {
                    playerModel.skip(by: -15)
                } label: {
                    Label("−15s", systemImage: "gobackward.15")
                }
                .buttonStyle(.borderless)

                Button {
                    playerModel.skip(by: 15)
                } label: {
                    Label("+15s", systemImage: "goforward.15")
                }
                .buttonStyle(.borderless)

                Spacer()

                Menu {
                    Button("Transcript text") { copyTranscript() }
                        .disabled(segments.isEmpty)
                    Button("Summary text") { copySummary() }
                    Button("Audio file path") { copyAudioPath() }
                } label: {
                    Label("Copy", systemImage: "doc.on.doc")
                }
                .buttonStyle(.borderless)
                .menuStyle(.button)
                .help("Copy transcript / summary / file path to clipboard for pasting into Slack, Telegram, etc.")

                Menu {
                    Button("Markdown bundle (.md)") { Task { await runExport(format: .markdown) } }
                    Button("Plain transcript (.txt)") { Task { await runExport(format: .plainText) } }
                    Button("Audio file (.m4a)") { Task { await runExport(format: .audio) } }
                    if hasScreenVideo {
                        Button("Screen recording (.mp4)") { Task { await runExport(format: .screenVideo) } }
                    }
                } label: {
                    Label("Export", systemImage: "square.and.arrow.up")
                }
                .buttonStyle(.borderless)
                .menuStyle(.button)

                Button {
                    Task { await runShare() }
                } label: {
                    Label("Share to S3", systemImage: "link")
                }
                .buttonStyle(.borderless)
                .disabled(!isS3Configured)
                .help(isS3Configured
                      ? "Upload audio + summary + transcript to S3 and copy presigned download links"
                      : "S3 sharing is not configured. Open Settings → Sharing to set bucket, region, endpoint, and access keys.")

                Button {
                    openInFinder()
                } label: {
                    Label("Open in Finder", systemImage: "folder")
                }
                .buttonStyle(.borderless)

                Button(role: .destructive) {
                    confirmDelete = true
                } label: {
                    Label("Delete", systemImage: "trash")
                }
                .buttonStyle(.borderless)
                .help("Delete this session and its files")
            }
            .padding(.horizontal)
            .padding(.bottom, 8)

            if let sharedLinks, !sharedLinks.links.isEmpty {
                Divider()

                SharedLinksSection(snapshot: sharedLinks)
                    .padding(.horizontal)
                    .padding(.vertical, 12)
            }

            Divider()

            // Transcript
            if segmentsLoading {
                ProgressView()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if segments.isEmpty {
                ContentUnavailableView(
                    "No Transcript",
                    systemImage: "doc.text",
                    description: Text("Transcription may still be in progress or did not complete.")
                )
            } else {
                TranscriptView(segments: segments, playerModel: playerModel)
            }
        }
        .task {
            await loadAudio()  // also sets hasScreenVideo
            await loadTranscript()
            await loadSharedLinks()
        }
        .alert("Export Failed", isPresented: Binding(
            get: { exportError != nil },
            set: { if !$0 { exportError = nil } }
        )) {
            Button("OK", role: .cancel) { exportError = nil }
        } message: {
            Text(exportError ?? "")
        }
        .confirmationDialog(
            "Delete this session?",
            isPresented: $confirmDelete,
            titleVisibility: .visible
        ) {
            Button("Delete", role: .destructive) {
                Task { await state.deleteSession(id: session.id) }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This removes the audio, transcript, summary, and any screen recording from disk. The action cannot be undone.")
        }
    }

    private func loadAudio() async {
        let audioURL = await state.audioFileURL(for: session.id)
        // Prefer screen.mp4 when present — it contains both video and the system audio track.
        let screenURL = audioURL.deletingLastPathComponent().appendingPathComponent("screen.mp4")
        let urlToLoad: URL
        if FileManager.default.fileExists(atPath: screenURL.path) {
            urlToLoad = screenURL
            // Toggle the video-sized panel BEFORE loading the asset so AVPlayerView
            // is built with enough room to host the video layer instead of falling
            // back to the audio-scrubber chrome and never re-laying out.
            hasScreenVideo = true
        } else if FileManager.default.fileExists(atPath: audioURL.path) {
            urlToLoad = audioURL
            hasScreenVideo = false
        } else {
            return
        }
        playerModel.load(url: urlToLoad)
        // Force a seek to t=0 so the player paints the first frame as a poster
        // image instead of staying blank until the user presses play.
        playerModel.seek(to: 0)
    }

    private func loadTranscript() async {
        defer { segmentsLoading = false }
        do {
            segments = try await state.loadSegments(for: session.id)
        } catch {
            print("[SessionDetailView] loadSegments failed: \(error)")
        }
    }

    private func loadSharedLinks() async {
        sharedLinks = await state.sharedLinks(for: session.id)
    }

    private func openInFinder() {
        Task {
            let audioURL = await state.audioFileURL(for: session.id)
            NSWorkspace.shared.activateFileViewerSelecting([audioURL])
        }
    }

    // MARK: - S3 availability

    /// True when Settings → Sharing is filled in enough that ShareCoordinator
    /// will succeed. `runShare` checks again at run time, but the disabled
    /// state on the toolbar gives the user a tooltip up front.
    private var isS3Configured: Bool {
        guard let s = state.settings else { return false }
        return !s.s3Endpoint.trimmingCharacters(in: .whitespaces).isEmpty
            && !s.s3Bucket.trimmingCharacters(in: .whitespaces).isEmpty
            && !s.s3AccessKey.trimmingCharacters(in: .whitespaces).isEmpty
    }

    // MARK: - Copy actions
    //
    // The Copy menu lets the user grab transcript / summary / audio path into
    // NSPasteboard so they can paste into Slack / Telegram / a bug report
    // without going through Export → save → re-attach.

    private func copyTranscript() {
        let text = segments.map(\.text).joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(text, forType: .string)
    }

    private func copySummary() {
        Task {
            let dir = await state.audioFileURL(for: session.id).deletingLastPathComponent()
            let summaryURL = dir.appendingPathComponent("summary.md")
            guard let text = try? String(contentsOf: summaryURL, encoding: .utf8),
                  !text.isEmpty else { return }
            await MainActor.run {
                let pb = NSPasteboard.general
                pb.clearContents()
                pb.setString(text, forType: .string)
            }
        }
    }

    private func copyAudioPath() {
        Task {
            let url = await state.audioFileURL(for: session.id)
            await MainActor.run {
                let pb = NSPasteboard.general
                pb.clearContents()
                pb.setString(url.path, forType: .string)
            }
        }
    }

    private func runExport(format: SessionExporter.Format) async {
        do {
            let dir = await state.audioFileURL(for: session.id).deletingLastPathComponent()
            try await SessionExporter.exportSession(session, sessionDir: dir, format: format)
        } catch {
            exportError = error.localizedDescription
        }
    }

    /// Upload session audio + summary + transcript to S3 and present links.
    /// Settings is required — the Share button is hidden when it's nil.
    private func runShare() async {
        guard let settings = state.settings else { return }
        let coordinator = ShareCoordinator(settings: settings, sessionStore: state.sessionStore)
        await coordinator.share(sessionId: session.id)
        await loadSharedLinks()
    }
}

// MARK: - SharedLinksSection

@available(macOS 14.0, *)
private struct SharedLinksSection: View {

    let snapshot: SharedLinksSnapshot

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Shared Links")
                    .font(.headline)
                Spacer()
                Text(snapshot.sharedAt.formatted(date: .abbreviated, time: .shortened))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            ForEach(snapshot.links, id: \.kind) { link in
                HStack(alignment: .firstTextBaseline, spacing: 12) {
                    Text(link.kind.displayName)
                        .font(.subheadline)
                        .frame(width: 160, alignment: .leading)

                    Text(link.url.absoluteString)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)

                    Spacer(minLength: 0)

                    Button("Open") {
                        NSWorkspace.shared.open(link.url)
                    }
                    .buttonStyle(.borderless)

                    Button("Copy") {
                        let pb = NSPasteboard.general
                        pb.clearContents()
                        pb.setString(link.url.absoluteString, forType: .string)
                    }
                    .buttonStyle(.borderless)
                }
            }
        }
    }
}

// MARK: - SessionHeaderView

@available(macOS 14.0, *)
private struct SessionHeaderView: View {

    let session: SessionRecord

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(session.recordedAt.formatted(date: .complete, time: .standard))
                    .font(.headline)
                Spacer()
                StatusBadge(status: session.status)
            }
            HStack(spacing: 12) {
                Label(session.mode.displayName,
                      systemImage: session.mode.iconName)
                Label(formatDuration(session.durationSecs), systemImage: "clock")
                if let lang = session.language {
                    Label(lang.uppercased(), systemImage: "globe")
                }
            }
            .font(.subheadline)
            .foregroundStyle(.secondary)
        }
    }

    private func formatDuration(_ secs: TimeInterval) -> String {
        let total = Int(secs)
        let h = total / 3600
        let m = (total % 3600) / 60
        let s = total % 60
        if h > 0 { return String(format: "%d:%02d:%02d", h, m, s) }
        return String(format: "%d:%02d", m, s)
    }
}

// MARK: - StatusBadge

@available(macOS 14.0, *)
private struct StatusBadge: View {

    let status: SessionStatus

    var body: some View {
        Text(status.rawValue.capitalized)
            .font(.caption)
            .fontWeight(.medium)
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(backgroundColor.opacity(0.15))
            .foregroundStyle(backgroundColor)
            .clipShape(Capsule())
    }

    private var backgroundColor: Color {
        switch status {
        case .complete: return .green
        case .recording: return .red
        case .transcribing: return .orange
        case .failed: return .secondary
        }
    }
}

// MARK: - TranscriptView

@available(macOS 14.0, *)
private struct TranscriptView: View {

    let segments: [TranscriptSegment]
    @Bindable var playerModel: PlayerModel

    var body: some View {
        ScrollViewReader { proxy in
            List(segments.indices, id: \.self) { index in
                let seg = segments[index]
                let isActive = isActive(seg)
                TranscriptRowView(segment: seg, isActive: isActive)
                    .id(index)
                    .contentShape(Rectangle())
                    .onTapGesture {
                        // Seek to the start of the tapped segment.
                        playerModel.seek(to: seg.start)
                    }
                    .listRowBackground(isActive ? Color.accentColor.opacity(0.12) : Color.clear)
            }
            .listStyle(.plain)
            // When the active segment changes, scroll it into view.
            .onChange(of: activeIndex) { _, newIndex in
                if let idx = newIndex {
                    withAnimation(.easeInOut(duration: 0.2)) {
                        proxy.scrollTo(idx, anchor: .center)
                    }
                }
            }
        }
    }

    private func isActive(_ seg: TranscriptSegment) -> Bool {
        let t = playerModel.currentTime
        return t >= seg.start && t < seg.end
    }

    // Compute the active index once so onChange can compare integers, not segments.
    private var activeIndex: Int? {
        let t = playerModel.currentTime
        return segments.indices.first { segments[$0].start <= t && t < segments[$0].end }
    }
}

// MARK: - TranscriptRowView

@available(macOS 14.0, *)
private struct TranscriptRowView: View {

    let segment: TranscriptSegment
    let isActive: Bool

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Text(formatTimestamp(segment.start))
                .font(.system(.caption, design: .monospaced))
                .foregroundStyle(.secondary)
                .frame(width: 44, alignment: .leading)
                .padding(.top, 2)

            Text(segment.text)
                .font(.callout)
                .foregroundStyle(isActive ? Color.primary : Color.primary.opacity(0.85))
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.vertical, 2)
    }

    private func formatTimestamp(_ secs: TimeInterval) -> String {
        let total = Int(secs)
        let m = total / 60
        let s = total % 60
        return String(format: "%d:%02d", m, s)
    }
}

// MARK: - PlayerModel

/// Holds the AVPlayer and exposes current time for the live-highlight UI.
///
/// @Observable so SwiftUI automatically re-renders transcript rows when
/// `currentTime` changes via the periodic time observer.
@available(macOS 14.0, *)
@Observable
@MainActor
final class PlayerModel {

    // Exposed to AVPlayerRepresentable for the underlying view.
    let player = AVPlayer()

    /// Updated by a periodic time observer at 100 ms resolution.
    var currentTime: TimeInterval = 0

    private var timeObserverToken: Any?

    init() {
        // 100 ms polling matches the ±100 ms seek accuracy requirement from AC-11.
        let interval = CMTime(value: 1, timescale: 10)
        timeObserverToken = player.addPeriodicTimeObserver(forInterval: interval, queue: .main) { [weak self] time in
            self?.currentTime = CMTimeGetSeconds(time)
        }
    }

    /// Explicit cleanup. Call from `.onDisappear`; deinit can't touch
    /// `@MainActor` state in Swift 6 strict concurrency mode.
    func invalidate() {
        if let token = timeObserverToken {
            player.removeTimeObserver(token)
            timeObserverToken = nil
        }
        player.pause()
    }

    func load(url: URL) {
        let item = AVPlayerItem(url: url)
        player.replaceCurrentItem(with: item)
    }

    func skip(by seconds: TimeInterval) {
        let current = player.currentTime()
        let target = CMTimeAdd(current, CMTimeMakeWithSeconds(seconds, preferredTimescale: 600))
        player.seek(to: target, toleranceBefore: .zero, toleranceAfter: .zero)
    }

    func seek(to seconds: TimeInterval) {
        let target = CMTimeMakeWithSeconds(seconds, preferredTimescale: 600)
        player.seek(to: target, toleranceBefore: .zero, toleranceAfter: .zero)
    }
}

// MARK: - AVPlayerRepresentable

/// NSViewRepresentable wrapping AVPlayerView with inline controls.
///
/// Controls style is `.inline`, not `.floating`. `.floating` draws a
/// translucent overlay panel that's larger than the player's own bounds,
/// which bleeds onto sibling views in the VStack — for the 44pt audio-only
/// frame in particular it covered the date header above and merged its
/// time label into the action bar below ("Share" + "00:17" rendered
/// touching). `.inline` keeps the scrubber + transport row inside the
/// player's own frame.
@available(macOS 14.0, *)
struct AVPlayerRepresentable: NSViewRepresentable {

    @Bindable var model: PlayerModel

    func makeNSView(context: Context) -> AVPlayerView {
        let view = AVPlayerView()
        view.player = model.player
        view.controlsStyle = .inline
        view.showsFullScreenToggleButton = false
        return view
    }

    func updateNSView(_ nsView: AVPlayerView, context: Context) {
        // Player reference is stable; no update needed on re-render.
        if nsView.player !== model.player {
            nsView.player = model.player
        }
    }
}

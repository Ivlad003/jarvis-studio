import SwiftUI
import AIKit
import StorageKit

// MARK: - ChatView

@available(macOS 14.0, *)
struct ChatView: View {

    @Bindable var chat: ChatState
    @Bindable var settings: AppSettings

    @State private var showSessionPicker: Bool = false
    @State private var pickerSelectedIds: Set<String> = []
    // "standard" or "snapshot" — only shown while recording.
    @State private var inputMode: InputMode = .standard

    private enum InputMode: String, CaseIterable, Identifiable {
        case standard = "Standard"
        case snapshot = "Live snapshot"
        var id: String { rawValue }
    }

    var body: some View {
        VStack(spacing: 0) {
            topBar
            Divider()
            attachedSessionsRow
            Divider()
            if chat.isRecording && chat.hasLiveTranscriptPreviewSource {
                liveTranscriptPanel
                Divider()
            }
            messageList
            if let error = chat.lastError {
                errorBanner(error)
            }
            Divider()
            bottomInputArea
        }
        .frame(minWidth: 540, minHeight: 600)
        .sheet(isPresented: $showSessionPicker) {
            sessionPickerSheet
        }
        .task(id: chat.isRecording) {
            if chat.isRecording {
                await chat.runLiveTranscriptPreviewLoop()
            } else {
                await chat.resetLiveTranscriptPreview()
            }
        }
    }

    // MARK: - Top bar

    private var topBar: some View {
        HStack(spacing: 10) {
            // Provider — menu picker so the row stays compact regardless of how
            // many providers are configured. Segmented overflows past 3 items
            // in this width.
            Picker("Provider", selection: $settings.llmProvider) {
                ForEach(AppSettings.LLMProviderChoice.allCases) { choice in
                    Text(choice.displayName).tag(choice)
                }
            }
            .pickerStyle(.menu)
            .labelsHidden()
            .frame(width: 160)
            .help("LLM provider used for chat responses")

            Divider().frame(height: 20)

            Toggle("Auto-find", isOn: $chat.autoSearchSessions)
                .toggleStyle(.checkbox)
                .font(.callout)
                .help("Automatically search recorded sessions for context matching your message")
                .fixedSize()

            if chat.autoSearchSessions {
                Stepper(
                    value: $chat.searchDepth,
                    in: 1...10,
                    label: {
                        Text("Depth: \(chat.searchDepth)")
                            .font(.callout)
                            .monospacedDigit()
                    }
                )
                .fixedSize()
                .help("Number of sessions to attach from FTS results (1–10)")
            }

            Spacer(minLength: 8)

            Button {
                Task { await chat.runAsAgent() }
            } label: {
                if chat.isLaunchingAgent {
                    ProgressView()
                        .scaleEffect(0.6)
                        .progressViewStyle(.circular)
                        .frame(width: 18, height: 18)
                } else {
                    Label("Run as agent", systemImage: "wand.and.stars")
                        .labelStyle(.iconOnly)
                }
            }
            .buttonStyle(.borderless)
            .help(chat.runAsAgentDisabledReason ?? "Hand the current message + attached sessions off to the autonomous agent (opens Agent Console)")
            .disabled(!chat.canRunAsAgent)

            Button(action: { Task { await chat.clear() } }) {
                Label("Clear", systemImage: "trash")
                    .labelStyle(.iconOnly)
            }
            .buttonStyle(.borderless)
            .help("Clear conversation and detach all sessions")
            .disabled(chat.messages.isEmpty && chat.attachedSessions.isEmpty && chat.lastError == nil)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }

    // MARK: - Attached sessions chips row

    // Always show the sessions row so the "Add session" button is always reachable.
    @ViewBuilder
    private var attachedSessionsRow: some View {
        HStack(spacing: 8) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    ForEach(chat.attachedSessions, id: \.self) { attached in
                        SessionChip(attached: attached) {
                            chat.detachSession(attached.record.id)
                        }
                    }
                }
                .padding(.horizontal, 4)
                .padding(.vertical, 6)
            }

            Spacer(minLength: 0)

            // Manual attach button
            Button {
                pickerSelectedIds = []
                showSessionPicker = true
            } label: {
                Label("Add session", systemImage: "paperclip")
                    .font(.callout)
            }
            .buttonStyle(.borderless)
            .help("Manually attach a recorded session as context")
            .padding(.trailing, 12)
        }
        .frame(minHeight: 36)
        .background(Color(NSColor.windowBackgroundColor))
    }

    // MARK: - Live transcript panel

    private var liveTranscriptPanel: some View {
        let rows = ChatState.liveTranscriptDisplayRows(from: chat.liveTranscriptPreview)

        return VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Label("Live transcript", systemImage: "waveform")
                    .font(.callout.weight(.semibold))
                Spacer()
                Text(liveTranscriptStatusText)
                    .font(.caption)
                    .foregroundStyle(liveTranscriptStatusIsError ? .red : .secondary)
                    .lineLimit(1)
            }

            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 6) {
                        if rows.isEmpty {
                            Text("Waiting for transcript...")
                                .font(.callout)
                                .foregroundStyle(.secondary)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .id("live-transcript-empty")
                        } else {
                            ForEach(rows) { row in
                                LiveTranscriptRow(row: row)
                                    .id(row.id)
                            }
                        }
                    }
                    .padding(10)
                }
                .frame(minHeight: 92, maxHeight: 150)
                .background(Color(NSColor.textBackgroundColor))
                .onChange(of: rows.last?.id) { _, lastID in
                    guard let lastID else { return }
                    withAnimation {
                        proxy.scrollTo(lastID, anchor: .bottom)
                    }
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: 6))
            .overlay(
                RoundedRectangle(cornerRadius: 6)
                    .stroke(Color(NSColor.separatorColor), lineWidth: 1)
            )
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(Color(NSColor.windowBackgroundColor))
    }

    private var liveTranscriptStatusText: String {
        guard let status = chat.liveTranscriptPreview?.status else { return "Waiting" }
        switch status {
        case .healthy:
            return "Live"
        case .delayed:
            return "Delayed"
        case .failed(let error):
            return error.isEmpty ? "Failed" : "Failed: \(error)"
        }
    }

    private var liveTranscriptStatusIsError: Bool {
        if case .failed = chat.liveTranscriptPreview?.status { return true }
        return false
    }

    // MARK: - Message list

    private var messageList: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 8) {
                    ForEach(chat.messages.filter { $0.role != .system }, id: \.id) { message in
                        MessageBubble(message: message)
                            .id(message.id)
                    }
                    if chat.isSending {
                        thinkingIndicator
                            .id("thinking")
                    }
                }
                .padding(16)
            }
            .onChange(of: chat.messages.count) { _, _ in
                if let lastID = chat.messages.last(where: { $0.role != .system })?.id {
                    withAnimation {
                        proxy.scrollTo(lastID, anchor: .bottom)
                    }
                }
            }
            .onChange(of: chat.isSending) { _, sending in
                if sending {
                    withAnimation { proxy.scrollTo("thinking", anchor: .bottom) }
                }
            }
        }
        .background(Color(NSColor.textBackgroundColor))
    }

    // MARK: - Thinking indicator

    private var thinkingIndicator: some View {
        HStack(spacing: 6) {
            ProgressView()
                .scaleEffect(0.7)
                .progressViewStyle(.circular)
            Text("Thinking…")
                .font(.callout)
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(Color(NSColor.controlBackgroundColor), in: RoundedRectangle(cornerRadius: 12))
    }

    // MARK: - Error banner

    private func errorBanner(_ message: String) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.yellow)
            Text(message)
                .font(.callout)
                .foregroundStyle(.primary)
                .lineLimit(3)
            Spacer()
            Button {
                chat.lastError = nil
            } label: {
                Image(systemName: "xmark")
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.borderless)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(Color(NSColor.windowBackgroundColor))
    }

    // MARK: - Bottom input area

    @ViewBuilder
    private var bottomInputArea: some View {
        VStack(spacing: 0) {
            // Mode switcher only shows when actively recording.
            if chat.isRecording {
                Picker("Input mode", selection: $inputMode) {
                    ForEach(InputMode.allCases) { mode in
                        Text(mode.rawValue).tag(mode)
                    }
                }
                .pickerStyle(.segmented)
                .padding(.horizontal, 16)
                .padding(.top, 10)
            }

            if inputMode == .snapshot, chat.isRecording {
                snapshotInputArea
            } else {
                standardInputArea
            }
        }
    }

    // Standard text → send path.
    private var standardInputArea: some View {
        HStack(alignment: .bottom, spacing: 8) {
            TextField("Message…", text: $chat.inputDraft, axis: .vertical)
                .textFieldStyle(.roundedBorder)
                .lineLimit(1...6)
                .onSubmit {
                    Task { await chat.send() }
                }
                .disabled(chat.isSending)

            Button {
                Task { await chat.send() }
            } label: {
                Image(systemName: "arrow.up.circle.fill")
                    .font(.title2)
                    .foregroundStyle(canSend ? .blue : .secondary)
            }
            .buttonStyle(.borderless)
            .disabled(!canSend)
            .help("Send (Return)")
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }

    // Live snapshot input path — whispers current recording into context.
    private var snapshotInputArea: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .bottom, spacing: 8) {
                TextField("Ask about the last ~60 seconds…", text: $chat.snapshotQuestion, axis: .vertical)
                    .textFieldStyle(.roundedBorder)
                    .lineLimit(1...4)
                    .disabled(chat.isSnapshotting)

                Button {
                    Task { await chat.sendSnapshot() }
                } label: {
                    if chat.isSnapshotting {
                        ProgressView()
                            .scaleEffect(0.7)
                            .progressViewStyle(.circular)
                            .frame(width: 28, height: 28)
                    } else {
                        Image(systemName: "waveform.and.arrow.up")
                            .font(.title2)
                            .foregroundStyle(canSendSnapshot ? .blue : .secondary)
                    }
                }
                .buttonStyle(.borderless)
                .disabled(!canSendSnapshot || chat.isSnapshotting)
                .help("Transcribe last ~60 s and ask")
            }

            Text("Transcribes the last ~60 s via Whisper, then asks your question.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }

    // MARK: - Session picker sheet

    private var sessionPickerSheet: some View {
        SessionPickerSheet(
            database: chat.database,
            selectedIds: $pickerSelectedIds,
            onConfirm: {
                showSessionPicker = false
                let ids = Array(pickerSelectedIds)
                Task { await chat.attachSessions(ids) }
            },
            onCancel: {
                showSessionPicker = false
            }
        )
    }

    // MARK: - Computed

    private var canSend: Bool {
        !chat.inputDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !chat.isSending
    }

    private var canSendSnapshot: Bool {
        !chat.snapshotQuestion.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
}

// MARK: - LiveTranscriptRow

@available(macOS 14.0, *)
private struct LiveTranscriptRow: View {

    let row: ChatState.LiveTranscriptDisplayRow

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(row.timeRange)
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
                .frame(width: 88, alignment: .leading)

            Text(row.text)
                .font(.callout)
                .foregroundStyle(row.isDraft ? .secondary : .primary)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)

            if row.isDraft {
                Text("draft")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 5)
                    .padding(.vertical, 2)
                    .background(Color(NSColor.controlBackgroundColor), in: RoundedRectangle(cornerRadius: 4))
            }
        }
    }
}

// MARK: - SessionChip

/// Compact chip showing a single attached session. Tapping the (X) detaches it.
@available(macOS 14.0, *)
private struct SessionChip: View {

    let attached: ChatState.AttachedSession
    let onRemove: () -> Void

    @State private var showSnippet: Bool = false

    private static let shortFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateStyle = .short
        f.timeStyle = .short
        return f
    }()

    var body: some View {
        HStack(spacing: 4) {
            if case .autoFromSearch = attached {
                Image(systemName: "magnifyingglass")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }

            Text(Self.shortFormatter.string(from: attached.record.recordedAt))
                .font(.caption)
                .lineLimit(1)

            Text(attached.record.mode.rawValue.prefix(3).uppercased())
                .font(.caption2)
                .foregroundStyle(.secondary)

            Button {
                onRemove()
            } label: {
                Image(systemName: "xmark")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.borderless)
            .help("Remove from context")
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(Color(NSColor.controlBackgroundColor), in: RoundedRectangle(cornerRadius: 8))
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(Color(NSColor.separatorColor), lineWidth: 0.5)
        )
        .contentShape(Rectangle())
        .onTapGesture { showSnippet.toggle() }
        .popover(isPresented: $showSnippet, arrowEdge: .bottom) {
            snippetPopover
        }
        .help("Tap to preview context snippet")
    }

    @ViewBuilder
    private var snippetPopover: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Context snippet")
                .font(.caption)
                .foregroundStyle(.secondary)
            if case .autoFromSearch(_, let snippet) = attached {
                Text(snippet)
                    .font(.callout)
                    .textSelection(.enabled)
            } else {
                Text("Manually attached — full transcript used as context.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(12)
        .frame(maxWidth: 320)
    }
}

// MARK: - MessageBubble

@available(macOS 14.0, *)
private struct MessageBubble: View {

    let message: ChatMessage

    var body: some View {
        if isToolActivity {
            toolActivityBody
        } else {
            textBubbleBody
        }
    }

    private var textBubbleBody: some View {
        HStack {
            if message.role == .user { Spacer(minLength: 60) }
            Text(message.text)
                .textSelection(.enabled)
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .background(bubbleColor, in: RoundedRectangle(cornerRadius: 12))
                .foregroundStyle(foregroundColor)
                .font(.body)
            if message.role != .user { Spacer(minLength: 60) }
        }
    }

    private var toolActivityBody: some View {
        HStack {
            VStack(alignment: .leading, spacing: 8) {
                ForEach(toolRows) { row in
                    VStack(alignment: .leading, spacing: 4) {
                        Label(row.title, systemImage: row.icon)
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(row.color)
                        if !row.detail.isEmpty {
                            Text(row.detail)
                                .font(.system(.caption, design: .monospaced))
                                .foregroundStyle(Color(NSColor.secondaryLabelColor))
                                .textSelection(.enabled)
                                .lineLimit(8)
                        }
                    }
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .background(Color(NSColor.windowBackgroundColor), in: RoundedRectangle(cornerRadius: 8))
            .overlay(
                RoundedRectangle(cornerRadius: 8)
                    .stroke(Color(NSColor.separatorColor), lineWidth: 1)
            )
            Spacer(minLength: 60)
        }
    }

    private var isToolActivity: Bool {
        message.parts.contains { part in
            if case .toolUse = part { return true }
            if case .toolResult = part { return true }
            return false
        }
    }

    private struct ToolActivityRow: Identifiable {
        let id: String
        let title: String
        let detail: String
        let icon: String
        let color: Color
    }

    private var toolRows: [ToolActivityRow] {
        message.parts.compactMap { part in
            switch part {
            case .toolUse(let call):
                return ToolActivityRow(
                    id: "\(message.id.uuidString)-tool-use-\(call.id)",
                    title: "Calling \(call.name)",
                    detail: (try? call.arguments.jsonString()) ?? "",
                    icon: "wrench.and.screwdriver",
                    color: Color.accentColor
                )
            case .toolResult(let id, let content, let isError):
                return ToolActivityRow(
                    id: "\(message.id.uuidString)-tool-result-\(id)",
                    title: isError ? "Tool error" : "Tool result",
                    detail: content,
                    icon: isError ? "exclamationmark.triangle" : "checkmark.circle",
                    color: isError ? Color.orange : Color(NSColor.secondaryLabelColor)
                )
            case .text, .image:
                return nil
            }
        }
    }

    private var bubbleColor: Color {
        switch message.role {
        case .user:      return Color.accentColor
        case .assistant: return Color(NSColor.controlBackgroundColor)
        case .system,
             .tool:      return Color(NSColor.windowBackgroundColor)
        }
    }

    private var foregroundColor: Color {
        message.role == .user ? .white : Color(NSColor.labelColor)
    }
}

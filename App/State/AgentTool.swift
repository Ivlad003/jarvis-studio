import Foundation
import AIKit
import os
import StorageKit
import TranscriptionKit

private let agentToolLog = Logger(subsystem: "dev.kosmonotes.studio", category: "AgentTool")

// MARK: - AgentTool

/// One executable capability the agent can call mid-session. Each tool exposes
/// a JSON-schema description (so Claude knows when + how to use it) and an
/// `execute(input:)` async function that does the real work and returns
/// human-readable output (becomes the `tool_result` sent back to Claude).
public protocol AgentTool: Sendable {
    var name: String { get }
    var description: String { get }
    /// JSON Schema (object) describing the tool's input. Sent verbatim to
    /// Anthropic in the `tools` array so the model picks the right one.
    var inputSchema: [String: Any] { get }

    /// Execute and return the result text. Throwing folds into `tool_result`
    /// with `is_error: true` so the model can recover.
    func execute(input: [String: Any]) async throws -> String
}

public protocol RichAgentTool: AgentTool {
    func executeResult(input: [String: Any]) async throws -> ToolExecutionResult
}

// MARK: - Built-in tools

/// Read the contents of a UTF-8 text file. Restricted to the workspace
/// directory the user picked in Settings — tries ~/Documents/KosmoNotes-agent
/// by default if no workspace is set.
public struct ReadFileTool: AgentTool {
    public let name = "read_file"
    public let description = "Read the contents of a UTF-8 text file at the given absolute path inside the agent workspace. Returns the file contents as a string."
    public let inputSchema: [String: Any] = [
        "type": "object",
        "properties": [
            "path": [
                "type": "string",
                "description": "Absolute filesystem path to read. Must resolve inside the agent workspace.",
            ],
        ],
        "required": ["path"],
    ]

    private let workspace: URL

    public init(workspace: URL) { self.workspace = workspace }

    public func execute(input: [String: Any]) async throws -> String {
        guard let path = input["path"] as? String else {
            throw AgentToolError.badInput("read_file: missing 'path'")
        }
        let url = URL(fileURLWithPath: path)
        try AgentToolGuard.requireInsideWorkspace(url, workspace: workspace, tool: "read_file")
        let data = try Data(contentsOf: url)
        guard let text = String(data: data, encoding: .utf8) else {
            return "<binary file, \(data.count) bytes>"
        }
        // Cap response so a 10MB file doesn't blow the context window.
        if text.count > 64_000 {
            return String(text.prefix(64_000)) + "\n\n... [truncated, file is \(text.count) chars]"
        }
        return text
    }
}

/// Atomically write a UTF-8 text file. Same workspace allowlist as read_file.
/// Capped at WriteFileTool.maxBytes so an LLM mistake can't fill the disk.
public struct WriteFileTool: AgentTool {
    public static let maxBytes = 1_048_576  // 1 MiB

    public let name = "write_file"
    public let description = "Write a UTF-8 text file. Overwrites if it exists, creates parent directories if missing. Use absolute paths inside your workspace. Capped at 1 MiB."
    public let inputSchema: [String: Any] = [
        "type": "object",
        "properties": [
            "path": ["type": "string", "description": "Absolute filesystem path to write. Must resolve inside the agent workspace."],
            "content": ["type": "string", "description": "Text to write. Must be ≤ 1 MiB UTF-8."],
        ],
        "required": ["path", "content"],
    ]

    private let workspace: URL

    public init(workspace: URL) { self.workspace = workspace }

    public func execute(input: [String: Any]) async throws -> String {
        guard let path = input["path"] as? String else { throw AgentToolError.badInput("write_file: missing 'path'") }
        guard let content = input["content"] as? String else { throw AgentToolError.badInput("write_file: missing 'content'") }
        let bytes = Data(content.utf8)
        guard bytes.count <= Self.maxBytes else {
            throw AgentToolError.notAllowed("write_file: content is \(bytes.count) bytes; cap is \(Self.maxBytes) bytes")
        }
        let url = URL(fileURLWithPath: path)
        try AgentToolGuard.requireInsideWorkspace(url, workspace: workspace, tool: "write_file")
        try AgentToolGuard.requireInsideWorkspace(url.deletingLastPathComponent(), workspace: workspace, tool: "write_file (parent dir)")
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try bytes.write(to: url, options: [.atomic])
        return "Wrote \(content.count) chars to \(url.path)"
    }
}

/// Run a strictly-allowlisted, read-only inspection command directly via
/// `Process` — never via a shell. The model passes a single command string;
/// we tokenize (whitespace + quoted strings), reject any shell metacharacters
/// (`; | & $ \` < > ( ) \\ \n \r`), validate the first token against a
/// read-only allowlist, and require any absolute-path argument to resolve
/// inside the agent workspace.
///
/// Threat model: an LLM (potentially driven by prompt-injected transcript
/// content from arbitrary recordings) could otherwise exfiltrate
/// `~/.ssh/id_rsa` via `cat ~/.ssh/id_rsa | curl …`, run `sed -i` mutations
/// outside the workspace, or shell-out to `python -c '…'`. Argv-only
/// invocation + path-arg sandbox + read-only allowlist closes those vectors.
public struct BashTool: AgentTool {

    /// Read-only inspection commands. Anything mutating (`sed`, `awk`,
    /// `git commit/push`, `swift build`, `npm install`, `python -c`, …)
    /// is intentionally absent. If you need to build/install, use the
    /// external CLI agent backends (Claude Code / Codex) which run in
    /// their own sandbox.
    public static let allowedCommands: Set<String> = [
        "ls", "cat", "echo", "pwd", "head", "tail", "wc", "file",
        "find", "grep", "rg", "date", "uname", "env", "which",
        "hostname", "stat", "tree", "diff", "basename", "dirname",
    ]

    /// Shell metacharacters that allow command chaining, substitution, or
    /// redirection. Forbidden because BashTool runs argv-direct via Process,
    /// not through a shell — these characters become literals if we let them
    /// through, but rejecting them prevents LLM confusion (the model thinks
    /// it's writing shell, gets surprised when literal `;` lands in argv).
    private static let forbiddenChars: Set<Character> = [
        ";", "|", "&", "$", "`", ">", "<", "\n", "\r", "\\",
    ]

    public let name = "bash"
    public let description = "Run a strictly read-only inspection command (ls, cat, find, grep, head/tail, etc.). NO shell metacharacters allowed (no pipes, redirects, substitution, chaining). NO mutating commands. Absolute path arguments must resolve inside the agent workspace."
    public let inputSchema: [String: Any] = [
        "type": "object",
        "properties": [
            "command": [
                "type": "string",
                "description": "Single read-only inspection command. Tokens are split on whitespace; quoted strings (\"foo bar\" or 'foo bar') are kept as one arg. Forbidden: ; | & $ ` > < \\ and newlines. First token must be one of: \(BashTool.allowedCommands.sorted().joined(separator: ", ")).",
            ],
        ],
        "required": ["command"],
    ]

    private let workspace: URL

    public init(workspace: URL) { self.workspace = workspace }

    public func execute(input: [String: Any]) async throws -> String {
        guard let raw = input["command"] as? String else {
            throw AgentToolError.badInput("bash: missing 'command'")
        }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw AgentToolError.badInput("bash: empty command") }

        if let bad = trimmed.first(where: { Self.forbiddenChars.contains($0) }) {
            throw AgentToolError.notAllowed("bash: forbidden character '\(bad)' — pipes, redirects, substitution, and chaining are disabled")
        }

        let tokens = try Self.tokenize(trimmed)
        guard let head = tokens.first, !head.isEmpty else {
            throw AgentToolError.badInput("bash: no command after tokenization")
        }
        guard Self.allowedCommands.contains(head) else {
            throw AgentToolError.notAllowed("bash: '\(head)' not in read-only allowlist (\(Self.allowedCommands.sorted().joined(separator: ", ")))")
        }
        let args = Array(tokens.dropFirst())

        // Validate path-looking args against the workspace.
        for arg in args {
            try Self.validateArg(arg, workspace: workspace)
        }

        // Resolve the binary up-front via /usr/bin/env-style PATH probe so
        // we never rely on shell PATH expansion.
        let executable = try Self.resolveBinary(head)

        return try await Self.spawn(executable: executable, args: args, command: trimmed, cwd: workspace)
    }

    // MARK: - Tokenizer

    /// Whitespace-splits `s`, preserving "..."/'...' quoted runs as a single
    /// token. No backslash escapes (those are forbidden anyway). Throws on an
    /// unclosed quote.
    static func tokenize(_ s: String) throws -> [String] {
        var tokens: [String] = []
        var current = ""
        var inDouble = false
        var inSingle = false

        for ch in s {
            if inDouble {
                if ch == "\"" { inDouble = false } else { current.append(ch) }
                continue
            }
            if inSingle {
                if ch == "'" { inSingle = false } else { current.append(ch) }
                continue
            }
            switch ch {
            case "\"": inDouble = true
            case "'":  inSingle = true
            case " ", "\t":
                if !current.isEmpty { tokens.append(current); current = "" }
            default:
                current.append(ch)
            }
        }
        if inDouble || inSingle {
            throw AgentToolError.badInput("bash: unterminated quote in command")
        }
        if !current.isEmpty { tokens.append(current) }
        return tokens
    }

    // MARK: - Argument validation

    /// Reject `~`-prefixed args (no shell expansion happens, but the LLM might
    /// assume one). Require any absolute-path arg to resolve inside the
    /// workspace. Relative args are fine — they resolve against `cwd`, which
    /// `Process` sets to the workspace.
    static func validateArg(_ arg: String, workspace: URL) throws {
        guard !arg.isEmpty else { return }
        if arg.hasPrefix("~") {
            throw AgentToolError.notAllowed("bash: '~' expansion not supported (no shell). Use absolute or workspace-relative paths.")
        }
        if arg.hasPrefix("/") {
            let url = URL(fileURLWithPath: arg)
            try AgentToolGuard.requireInsideWorkspace(url, workspace: workspace, tool: "bash")
        }
    }

    // MARK: - Binary resolution

    /// Probe a small allowlist of locations for the given command name. We
    /// never inherit the user's interactive PATH (GUI apps don't get one).
    static func resolveBinary(_ name: String) throws -> String {
        // Defensive: name should have already passed `allowedCommands`, but
        // refuse anything non-alphanumeric to be safe.
        guard !name.isEmpty,
              name.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" }) else {
            throw AgentToolError.notAllowed("bash: bad command name")
        }
        let candidates = [
            "/usr/bin/\(name)",
            "/bin/\(name)",
            "/usr/local/bin/\(name)",
            "/opt/homebrew/bin/\(name)",
            "/usr/sbin/\(name)",
            "/sbin/\(name)",
        ]
        for path in candidates where FileManager.default.isExecutableFile(atPath: path) {
            return path
        }
        throw AgentToolError.runtime("bash: '\(name)' not found in /usr/bin, /bin, /usr/local/bin, /opt/homebrew/bin")
    }

    // MARK: - Process spawn (async, deadlock-free)

    /// Launch `executable` with `args` inside `cwd`, drain stdout+stderr
    /// concurrently into a memory buffer (avoids the classic
    /// readToEnd-after-waitUntilExit deadlock when output > pipe buffer),
    /// cap at 32_000 chars, and return on exit. Uses a 60-s wall-clock cap
    /// so a stuck `find /` can't hang the agent forever.
    private static func spawn(executable: String, args: [String], command: String, cwd: URL) async throws -> String {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: executable)
        proc.arguments = args
        proc.currentDirectoryURL = cwd
        proc.environment = Self.minimalEnvironment(cwd: cwd)
        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        proc.standardOutput = stdoutPipe
        proc.standardError = stderrPipe
        proc.standardInput = FileHandle.nullDevice  // no stdin

        let exit = AgentProcessSignal()
        proc.terminationHandler = { _ in exit.fire() }

        do {
            try proc.run()
        } catch {
            throw AgentToolError.runtime("bash launch failed: \(error.localizedDescription)")
        }

        let stdoutFD = stdoutPipe.fileHandleForReading
        let stderrFD = stderrPipe.fileHandleForReading
        let stdoutTask = Task.detached { Self.readAll(stdoutFD, capBytes: 32_000) }
        let stderrTask = Task.detached { Self.readAll(stderrFD, capBytes: 16_000) }

        // 60-second wall clock; SIGTERM then SIGKILL the child if it hangs.
        let timeoutTask = Task.detached {
            try? await Task.sleep(nanoseconds: 60_000_000_000)
            if proc.isRunning {
                proc.terminate()
                try? await Task.sleep(nanoseconds: 2_000_000_000)
                if proc.isRunning {
                    kill(proc.processIdentifier, SIGKILL)
                }
            }
        }

        await exit.wait()
        timeoutTask.cancel()
        let stdoutText = await stdoutTask.value
        let stderrText = await stderrTask.value

        let combined = stdoutText + (stderrText.isEmpty ? "" : "\n[stderr]\n" + stderrText)
        let truncated = combined.count > 32_000 ? String(combined.prefix(32_000)) + "\n... [truncated]" : combined
        let exitInfo = proc.terminationStatus == 0 ? "" : " (exit \(proc.terminationStatus))"
        return "$ \(command)\(exitInfo)\n\(truncated)"
    }

    /// Drain a pipe synchronously into a String, capped at `capBytes`.
    /// Runs on a detached Task — never on the actor that owns the spawn.
    static func readAll(_ handle: FileHandle, capBytes: Int) -> String {
        var buf = Data()
        while true {
            let chunk: Data
            do {
                chunk = try handle.read(upToCount: 4096) ?? Data()
            } catch {
                return String(decoding: buf, as: UTF8.self)
            }
            if chunk.isEmpty { break }
            if buf.count + chunk.count > capBytes {
                let remaining = max(0, capBytes - buf.count)
                buf.append(chunk.prefix(remaining))
                // Drain the rest into the void so the child doesn't block on a full pipe.
                while let extra = try? handle.read(upToCount: 65_536), !extra.isEmpty { _ = extra }
                break
            }
            buf.append(chunk)
        }
        // Use String(decoding:as:) so a partial multibyte run at the cap
        // boundary becomes a replacement char instead of dropping the whole
        // string (which `String(data:encoding:.utf8)` would do).
        return String(decoding: buf, as: UTF8.self)
    }

    /// Minimal env: PATH covering the standard system bins + workspace as
    /// HOME/PWD analogues. Nothing inherited from the parent so the child
    /// can't see KOSMONOTES_API_KEY-style secrets the host might have set.
    static func minimalEnvironment(cwd: URL) -> [String: String] {
        return [
            "PATH": "/usr/bin:/bin:/usr/local/bin:/opt/homebrew/bin:/usr/sbin:/sbin",
            "HOME": cwd.path,
            "PWD": cwd.path,
            "LANG": "en_US.UTF-8",
            "TERM": "dumb",
        ]
    }
}

public struct SearchLiveTranscriptTool: AgentTool {
    public typealias SnapshotProvider = @MainActor @Sendable () async -> LiveTranscriptState?

    public let name = "search_live_transcript"
    public let description = "Search the current in-progress live transcript. Returns timestamped stable and draft matches from what has been said so far."
    public let inputSchema: [String: Any] = [
        "type": "object",
        "properties": [
            "query": ["type": "string", "description": "Words to search for in the live transcript."],
            "limit": ["type": "integer", "description": "Maximum matching transcript spans to return, from 1 to 20."],
        ],
        "required": ["query"],
    ]

    private let snapshotProvider: SnapshotProvider

    public init(snapshotProvider: @escaping SnapshotProvider) {
        self.snapshotProvider = snapshotProvider
    }

    public func execute(input: [String: Any]) async throws -> String {
        guard let query = input["query"] as? String else {
            throw AgentToolError.badInput("search_live_transcript: missing 'query'")
        }
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw AgentToolError.badInput("search_live_transcript: empty query")
        }

        guard let snapshot = await snapshotProvider() else {
            return "No live transcript is available."
        }

        let units = (snapshot.stableUnits + snapshot.draftUnits)
            .sorted { lhs, rhs in
                if lhs.start == rhs.start { return lhs.end < rhs.end }
                return lhs.start < rhs.start
            }
        guard !units.isEmpty else {
            return "Live transcript is empty."
        }

        let tokens = Self.searchTokens(in: trimmed)
        let limit = Self.clampedLimit(from: input["limit"], defaultValue: 8, upperBound: 20)
        let matches = units.filter { unit in
            let haystack = unit.text.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
            return tokens.allSatisfy { haystack.contains($0) }
        }.prefix(limit)

        guard !matches.isEmpty else {
            return "No live transcript matches for `\(trimmed)`."
        }

        return matches.enumerated().map { index, unit in
            "[\(index + 1)] [\(Self.formatTimestamp(unit.start))-\(Self.formatTimestamp(unit.end))] \(Self.label(for: unit.state))\n\(unit.text)"
        }.joined(separator: "\n\n")
    }

    private static func searchTokens(in query: String) -> [String] {
        query
            .split { $0.isWhitespace || $0.isNewline }
            .map { String($0).folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current) }
            .filter { !$0.isEmpty }
    }

    private static func label(for state: LiveTranscriptUnitState) -> String {
        switch state {
        case .stable:
            return "stable"
        case .draft:
            return "draft"
        }
    }

    private static func formatTimestamp(_ seconds: TimeInterval) -> String {
        let total = max(0, Int(seconds.rounded(.down)))
        let hours = total / 3600
        let minutes = (total % 3600) / 60
        let seconds = total % 60
        if hours > 0 {
            return String(format: "%02d:%02d:%02d", hours, minutes, seconds)
        }
        return String(format: "%02d:%02d", minutes, seconds)
    }

    private static func clampedLimit(from value: Any?, defaultValue: Int, upperBound: Int) -> Int {
        let raw: Int
        if let value = value as? Int {
            raw = value
        } else if let value = value as? Double {
            raw = Int(value)
        } else if let value = value as? NSNumber {
            raw = value.intValue
        } else {
            raw = defaultValue
        }
        return max(1, min(raw, upperBound))
    }
}

public struct SearchTranscriptsTool: AgentTool {
    public let name = "search_transcripts"
    public let description = "Search finished saved transcript sessions with local full-text search. Returns session metadata and matching snippets."
    public let inputSchema: [String: Any] = [
        "type": "object",
        "properties": [
            "query": ["type": "string", "description": "Words to search for in completed transcript sessions."],
            "limit": ["type": "integer", "description": "Maximum finished transcript hits to return, from 1 to 20."],
        ],
        "required": ["query"],
    ]

    private let database: AppDatabase

    public init(database: AppDatabase) {
        self.database = database
    }

    public func execute(input: [String: Any]) async throws -> String {
        guard let query = input["query"] as? String else {
            throw AgentToolError.badInput("search_transcripts: missing 'query'")
        }
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw AgentToolError.badInput("search_transcripts: empty query")
        }

        let limit = Self.clampedLimit(from: input["limit"], defaultValue: 8, upperBound: 20)
        let hits = try await database.searchTranscripts(query: trimmed, limit: limit)
        guard !hits.isEmpty else {
            return "No finished transcript matches for `\(trimmed)`."
        }

        var lines: [String] = []
        let formatter = ISO8601DateFormatter()
        for (index, hit) in hits.enumerated() {
            let shortID = String(hit.sid.prefix(8))
            if let record = try await database.session(id: hit.sid) {
                let recordedAt = formatter.string(from: record.recordedAt)
                let duration = String(format: "%.0fs", record.durationSecs)
                let language = record.language ?? "auto"
                lines.append("""
                [\(index + 1)] \(recordedAt) · \(record.mode.displayName) · \(duration) · \(language) · \(shortID)
                \(hit.snippet)
                """)
            } else {
                lines.append("""
                [\(index + 1)] session \(shortID)
                \(hit.snippet)
                """)
            }
        }

        return lines.joined(separator: "\n\n")
    }

    private static func clampedLimit(from value: Any?, defaultValue: Int, upperBound: Int) -> Int {
        let raw: Int
        if let value = value as? Int {
            raw = value
        } else if let value = value as? Double {
            raw = Int(value)
        } else if let value = value as? NSNumber {
            raw = value.intValue
        } else {
            raw = defaultValue
        }
        return max(1, min(raw, upperBound))
    }
}

struct ScreenFrameSource: Sendable, Equatable {
    let sessionId: String?
    let videoURL: URL

    init(sessionId: String?, videoURL: URL) {
        self.sessionId = sessionId
        self.videoURL = videoURL
    }
}

@available(macOS 14.0, *)
struct GetScreenFrameTool: RichAgentTool {
    typealias SourceProvider = @MainActor @Sendable () async -> ScreenFrameSource?
    typealias FrameLoader = @Sendable (_ seconds: TimeInterval, _ videoURL: URL) async throws -> Data

    let name = "get_screen_frame"
    let description = "Extract one JPEG frame from the active recording's screen.mp4 at a requested timestamp and return it as vision context."
    let inputSchema: [String: Any] = [
        "type": "object",
        "properties": [
            "timestamp": [
                "description": "Timestamp in seconds or h:mm:ss / mm:ss format, relative to the active screen recording.",
                "oneOf": [
                    ["type": "number"],
                    ["type": "string"],
                ],
            ],
        ],
        "required": ["timestamp"],
    ]

    private let sourceProvider: SourceProvider
    private let frameLoader: FrameLoader

    init(
        sourceProvider: @escaping SourceProvider,
        frameLoader: @escaping FrameLoader = { seconds, videoURL in
            try await FrameExtractor.extractFrame(at: seconds, from: videoURL)
        }
    ) {
        self.sourceProvider = sourceProvider
        self.frameLoader = frameLoader
    }

    func execute(input: [String: Any]) async throws -> String {
        try await executeResult(input: input).content
    }

    func executeResult(input: [String: Any]) async throws -> ToolExecutionResult {
        let seconds = try Self.parseTimestamp(input["timestamp"])
        guard let source = await sourceProvider() else {
            throw AgentToolError.runtime("get_screen_frame: no active screen recording is available")
        }

        let jpeg = try await frameLoader(seconds, source.videoURL)
        let label = Self.formatTimestamp(seconds)
        let sourceLabel: String
        if let sessionId = source.sessionId {
            sourceLabel = "session \(String(sessionId.prefix(8)))"
        } else {
            sourceLabel = source.videoURL.deletingLastPathComponent().lastPathComponent
        }

        return ToolExecutionResult(
            content: "Frame extracted from \(sourceLabel) at \(label).",
            attachments: [.image(jpegData: jpeg, mimeType: "image/jpeg")]
        )
    }

    private static func parseTimestamp(_ value: Any?) throws -> TimeInterval {
        guard let value else {
            throw AgentToolError.badInput("get_screen_frame: missing 'timestamp'")
        }

        let seconds: TimeInterval
        if let value = value as? Double {
            seconds = value
        } else if let value = value as? Int {
            seconds = TimeInterval(value)
        } else if let value = value as? NSNumber {
            seconds = value.doubleValue
        } else if let value = value as? String {
            seconds = try parseTimestampString(value)
        } else {
            throw AgentToolError.badInput("get_screen_frame: timestamp must be a number or timestamp string")
        }

        guard seconds.isFinite, seconds >= 0 else {
            throw AgentToolError.badInput("get_screen_frame: timestamp must be a non-negative finite value")
        }
        return seconds
    }

    private static func parseTimestampString(_ raw: String) throws -> TimeInterval {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !trimmed.isEmpty else {
            throw AgentToolError.badInput("get_screen_frame: empty timestamp")
        }

        if trimmed.contains(":") {
            let parts = trimmed.split(separator: ":").map(String.init)
            guard parts.count == 2 || parts.count == 3,
                  let values = parseIntegerComponents(parts) else {
                throw AgentToolError.badInput("get_screen_frame: invalid timestamp '\(raw)'")
            }
            if values.count == 2 {
                let minutes = values[0]
                let seconds = values[1]
                guard seconds < 60 else {
                    throw AgentToolError.badInput("get_screen_frame: invalid seconds in '\(raw)'")
                }
                return TimeInterval(minutes * 60 + seconds)
            }
            let hours = values[0]
            let minutes = values[1]
            let seconds = values[2]
            guard minutes < 60, seconds < 60 else {
                throw AgentToolError.badInput("get_screen_frame: invalid time in '\(raw)'")
            }
            return TimeInterval(hours * 3600 + minutes * 60 + seconds)
        }

        let suffixes = [" seconds", " second", " secs", " sec", "s"]
        let numeric = suffixes.reduce(trimmed) { partial, suffix in
            partial.hasSuffix(suffix) ? String(partial.dropLast(suffix.count)) : partial
        }.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let seconds = TimeInterval(numeric) else {
            throw AgentToolError.badInput("get_screen_frame: invalid timestamp '\(raw)'")
        }
        return seconds
    }

    private static func parseIntegerComponents(_ parts: [String]) -> [Int]? {
        var values: [Int] = []
        for part in parts {
            guard let value = Int(part), value >= 0 else { return nil }
            values.append(value)
        }
        return values
    }

    private static func formatTimestamp(_ seconds: TimeInterval) -> String {
        let total = max(0, Int(seconds.rounded()))
        let hours = total / 3600
        let minutes = (total % 3600) / 60
        let secs = total % 60
        if hours > 0 {
            return String(format: "%d:%02d:%02d", hours, minutes, secs)
        }
        return String(format: "%02d:%02d", minutes, secs)
    }
}

public struct SearchKnowledgeBaseTool: AgentTool {
    public let name = "search_knowledge_base"
    public let description = "Search user-added local knowledge-base documents and code chunks. Returns matching file paths and snippets."
    public let inputSchema: [String: Any] = [
        "type": "object",
        "properties": [
            "query": ["type": "string", "description": "Words or code identifier to search for."],
            "limit": ["type": "integer", "description": "Maximum hits to return, from 1 to 20."],
        ],
        "required": ["query"],
    ]

    private let store: KnowledgeBaseStore

    public init(store: KnowledgeBaseStore) {
        self.store = store
    }

    public func execute(input: [String: Any]) async throws -> String {
        guard let query = input["query"] as? String else {
            throw AgentToolError.badInput("search_knowledge_base: missing 'query'")
        }
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw AgentToolError.badInput("search_knowledge_base: empty query")
        }

        let limit = Self.clampedLimit(from: input["limit"], defaultValue: 8, upperBound: 20)
        let hits = try await store.search(query: trimmed, limit: limit)
        guard !hits.isEmpty else {
            return "No knowledge-base matches for `\(trimmed)`."
        }

        return hits.enumerated().map { index, hit in
            "[\(index + 1)] \(hit.relPath)#chunk-\(hit.chunkIndex)\n\(hit.snippet)"
        }.joined(separator: "\n\n")
    }

    private static func clampedLimit(from value: Any?, defaultValue: Int, upperBound: Int) -> Int {
        let raw: Int
        if let value = value as? Int {
            raw = value
        } else if let value = value as? Double {
            raw = Int(value)
        } else if let value = value as? NSNumber {
            raw = value.intValue
        } else {
            raw = defaultValue
        }
        return max(1, min(raw, upperBound))
    }
}

public struct SearchCodeTool: AgentTool {
    public let name = "search_code"
    public let description = "Search configured code-folder roots with ripgrep. Runs argv-direct, fixed-string rg; optional path must stay inside a configured code root."
    public let inputSchema: [String: Any] = [
        "type": "object",
        "properties": [
            "query": ["type": "string", "description": "Literal string or identifier to search for."],
            "path": ["type": "string", "description": "Optional absolute file or folder path inside a configured code-folder source."],
            "limit": ["type": "integer", "description": "Maximum matches per file, from 1 to 50."],
        ],
        "required": ["query"],
    ]

    private let roots: [URL]

    public init(roots: [URL]) {
        self.roots = roots.map { $0.standardizedFileURL.resolvingSymlinksInPath() }
    }

    public func execute(input: [String: Any]) async throws -> String {
        guard let query = input["query"] as? String else {
            throw AgentToolError.badInput("search_code: missing 'query'")
        }
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw AgentToolError.badInput("search_code: empty query")
        }
        guard !roots.isEmpty else {
            return "No code-folder sources are configured."
        }

        let targets: [URL]
        if let path = input["path"] as? String, !path.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            let target = URL(fileURLWithPath: path).standardizedFileURL.resolvingSymlinksInPath()
            _ = try matchingRoot(for: target)
            targets = [target]
        } else {
            targets = roots
        }

        let limit = Self.clampedLimit(from: input["limit"], defaultValue: 20, upperBound: 50)
        let executable = try BashTool.resolveBinary("rg")
        let args = [
            "--line-number",
            "--no-heading",
            "--color",
            "never",
            "--fixed-strings",
            "--max-count",
            "\(limit)",
            "--",
            trimmed,
        ] + targets.map(\.path)

        return try await runRipgrep(executable: executable, args: args, query: trimmed, cwd: targets[0])
    }

    private func matchingRoot(for target: URL) throws -> URL {
        for root in roots {
            do {
                try AgentToolGuard.requireInsideWorkspace(target, workspace: root, tool: "search_code")
                return root
            } catch AgentToolError.notAllowed {
                continue
            }
        }
        throw AgentToolError.notAllowed("search_code: path outside workspace (\(roots.map(\.path).joined(separator: ", ")))")
    }

    private func runRipgrep(executable: String, args: [String], query: String, cwd: URL) async throws -> String {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: executable)
        proc.arguments = args
        proc.currentDirectoryURL = cwd
        proc.environment = BashTool.minimalEnvironment(cwd: cwd)
        proc.standardInput = FileHandle.nullDevice

        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        proc.standardOutput = stdoutPipe
        proc.standardError = stderrPipe

        let exit = AgentProcessSignal()
        proc.terminationHandler = { _ in exit.fire() }

        do {
            try proc.run()
        } catch {
            throw AgentToolError.runtime("search_code launch failed: \(error.localizedDescription)")
        }

        let stdoutTask = Task.detached { BashTool.readAll(stdoutPipe.fileHandleForReading, capBytes: 32_000) }
        let stderrTask = Task.detached { BashTool.readAll(stderrPipe.fileHandleForReading, capBytes: 16_000) }
        let timeoutTask = Task.detached {
            try? await Task.sleep(nanoseconds: 30_000_000_000)
            if proc.isRunning {
                proc.terminate()
                try? await Task.sleep(nanoseconds: 1_000_000_000)
                if proc.isRunning {
                    kill(proc.processIdentifier, SIGKILL)
                }
            }
        }

        await exit.wait()
        timeoutTask.cancel()
        let stdout = await stdoutTask.value
        let stderr = await stderrTask.value

        switch proc.terminationStatus {
        case 0:
            return "$ rg --fixed-strings \(query)\n\(stdout)"
        case 1:
            return "No code matches for `\(query)`."
        default:
            throw AgentToolError.runtime("search_code: rg exited \(proc.terminationStatus): \(stderr)")
        }
    }

    private static func clampedLimit(from value: Any?, defaultValue: Int, upperBound: Int) -> Int {
        let raw: Int
        if let value = value as? Int {
            raw = value
        } else if let value = value as? Double {
            raw = Int(value)
        } else if let value = value as? NSNumber {
            raw = value.intValue
        } else {
            raw = defaultValue
        }
        return max(1, min(raw, upperBound))
    }
}

enum AgentToolRegistry {
    static func makeBuiltinTools(
        workspace: URL,
        database: AppDatabase? = nil,
        knowledgeBaseStore: KnowledgeBaseStore?,
        liveTranscriptProvider: SearchLiveTranscriptTool.SnapshotProvider?,
        screenFrameSourceProvider: GetScreenFrameTool.SourceProvider? = nil
    ) async -> [AgentTool] {
        var tools: [AgentTool] = [
            BashTool(workspace: workspace),
            ReadFileTool(workspace: workspace),
            WriteFileTool(workspace: workspace),
        ]

        if let database {
            tools.append(SearchTranscriptsTool(database: database))
        }

        if let liveTranscriptProvider {
            tools.append(SearchLiveTranscriptTool(snapshotProvider: liveTranscriptProvider))
        }

        if let screenFrameSourceProvider {
            tools.append(GetScreenFrameTool(sourceProvider: screenFrameSourceProvider))
        }

        if let knowledgeBaseStore {
            tools.append(SearchKnowledgeBaseTool(store: knowledgeBaseStore))
            let codeRoots = (try? await knowledgeBaseStore.listSources())
                .map { sources in
                    sources
                        .filter { $0.kind == .codeFolder }
                        .map { URL(fileURLWithPath: $0.path, isDirectory: true) }
                } ?? []
            tools.append(SearchCodeTool(roots: codeRoots))
        }

        return tools
    }
}

extension AgentTool {
    func toolDefinition() -> ToolDefinition {
        let schema = (try? JSONValue(any: inputSchema)) ?? .object(["type": .string("object")])
        return ToolDefinition(
            spec: ToolSpec(name: name, description: description, parameters: schema),
            execute: { arguments in
                let input = (arguments.anyValue as? [String: Any]) ?? [:]
                do {
                    if let richTool = self as? RichAgentTool {
                        return try await richTool.executeResult(input: input)
                    }
                    return ToolExecutionResult(content: try await execute(input: input))
                } catch {
                    return ToolExecutionResult(content: error.localizedDescription, isError: true)
                }
            }
        )
    }
}

// MARK: - Errors + helpers

public enum AgentToolError: Error, LocalizedError {
    case badInput(String)
    case notAllowed(String)
    case runtime(String)

    public var errorDescription: String? {
        switch self {
        case .badInput(let s), .notAllowed(let s), .runtime(let s):
            return s
        }
    }
}

enum AgentToolGuard {
    /// Reject any path that resolves outside `workspace`. Resolves
    /// `..`/symlinks via standardizedFileURL so the agent can't escape via
    /// `/foo/../etc/passwd` or symlink farms inside the workspace.
    ///
    /// Note: this is a TOCTOU-best-effort check — between this and the
    /// caller's actual `Data(contentsOf:)` / `Data.write(to:)` the symlink
    /// could be retargeted by a local attacker. Acceptable for a single-user
    /// menu-bar app where the only attacker model is an untrusted prompt.
    static func requireInsideWorkspace(_ url: URL, workspace: URL, tool: String) throws {
        let resolvedURL = url.standardizedFileURL.resolvingSymlinksInPath()
        let resolvedWS = workspace.standardizedFileURL.resolvingSymlinksInPath()
        let urlPath = resolvedURL.path
        let wsPath = resolvedWS.path
        if urlPath != wsPath && !urlPath.hasPrefix(wsPath + "/") {
            agentToolLog.error("\(tool, privacy: .public): path \(urlPath, privacy: .private) is outside workspace \(wsPath, privacy: .private)")
            throw AgentToolError.notAllowed("\(tool): path outside workspace (\(wsPath))")
        }
    }
}

// MARK: - Process termination signal

/// One-shot Sendable bridge from `Process.terminationHandler` (called from a
/// libdispatch queue) to async/await. Same shape as `ExternalAgentRunner`'s
/// `AsyncSignal` but kept private to AgentTool so the two files stay
/// independently testable.
final class AgentProcessSignal: @unchecked Sendable {
    private let lock = NSLock()
    private var fired = false
    private var continuation: CheckedContinuation<Void, Never>?

    func fire() {
        lock.lock()
        defer { lock.unlock() }
        if fired { return }
        fired = true
        continuation?.resume()
        continuation = nil
    }

    func wait() async {
        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            lock.lock()
            if fired {
                lock.unlock()
                cont.resume()
                return
            }
            continuation = cont
            lock.unlock()
        }
    }
}

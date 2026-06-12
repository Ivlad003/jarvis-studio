import Foundation

// MARK: - TranscriptionProvider

/// Provider protocol for streaming speech-to-text.
///
/// One provider may serve many sessions. Each call to `openSession` returns
/// an independent `TranscriptionSession` — its own connection, its own
/// transcript event stream.
public protocol TranscriptionProvider: Sendable {
    func openSession(config: TranscriptionConfig) async throws -> TranscriptionSession
}

// MARK: - TranscriptionSession

/// A single live transcription connection.
///
/// Lifecycle:
///   1. Caller obtains a session via `provider.openSession(config:)`.
///   2. Caller iterates `events` (an `AsyncThrowingStream<TranscriptSegment, Error>`) on one task.
///   3. Caller calls `send(_:)` repeatedly with raw PCM bytes (linear16,
///      sample rate / channels per `TranscriptionConfig`).
///   4. Caller calls `finish()` when the audio stream ends; the session
///      flushes any final segments, closes the WebSocket cleanly, and
///      finishes `events`.
///   5. On error or cancellation, `cancel()` aborts immediately.
///
/// `TranscriptionSession` is an actor so the underlying transport is never
/// touched from two contexts at once.
public actor TranscriptionSession {

    // MARK: Public surface

    /// Stream of transcript events. Bounded so an abandoned or stalled consumer
    /// cannot grow memory without limit; terminal receive failures surface as
    /// thrown errors from iteration.
    public nonisolated let events: AsyncThrowingStream<TranscriptSegment, Error>

    // MARK: Private state

    private let continuation: AsyncThrowingStream<TranscriptSegment, Error>.Continuation
    private let transport: any WebSocketTransport
    private let parser: TranscriptionEventParser
    private let defaultCloseMessage: String?
    private let finishDrainTimeoutNanoseconds: UInt64
    private let terminalMessage: @Sendable (WebSocketMessage) -> Bool
    private let lifecycle: WebSocketSessionLifecycle
    private var receiveTask: Task<Void, Never>?
    private var keepAliveTask: Task<Void, Never>?
    private var closed = false
    private var receiveLoopFinished = false

    private static let keepAliveMessage = #"{"type":"KeepAlive"}"#
    private static let keepAliveIntervalNanoseconds: UInt64 = 8_000_000_000

    // MARK: Init

    init(
        transport: any WebSocketTransport,
        parser: TranscriptionEventParser,
        defaultCloseMessage: String? = nil,
        finishDrainTimeoutNanoseconds: UInt64 = 2_500_000_000,
        terminalMessage: @escaping @Sendable (WebSocketMessage) -> Bool = { _ in false }
    ) {
        let lifecycle = WebSocketSessionLifecycle()
        let (stream, cont) = Self.makeEventStream(lifecycle: lifecycle)
        lifecycle.setTransport(transport)
        self.events = stream
        self.continuation = cont
        self.transport = transport
        self.parser = parser
        self.defaultCloseMessage = defaultCloseMessage
        self.finishDrainTimeoutNanoseconds = finishDrainTimeoutNanoseconds
        self.terminalMessage = terminalMessage
        self.lifecycle = lifecycle
    }

    // MARK: Public API

    public func send(_ pcm: Data) async throws {
        if closed { throw TranscriptionError.alreadyClosed }
        do {
            try await transport.send(.data(pcm))
        } catch {
            throw TranscriptionError.sendFailed(message: "\(error)")
        }
    }

    public func send(text: String) async throws {
        if closed { throw TranscriptionError.alreadyClosed }
        do {
            try await transport.send(.text(text))
        } catch {
            throw TranscriptionError.sendFailed(message: "\(error)")
        }
    }

    /// Graceful close. Waits briefly for the server to flush final segments,
    /// then closes the WebSocket and finishes the event stream.
    public func finish(closeMessage: String? = nil) async throws {
        if closed { return }
        closed = true

        if let msg = closeMessage ?? defaultCloseMessage {
            try? await transport.send(.text(msg))
        }

        await waitForReceiveDrain(timeoutNanoseconds: finishDrainTimeoutNanoseconds)

        keepAliveTask?.cancel()
        receiveTask?.cancel()
        transport.close(code: .normalClosure)
        continuation.finish()
    }

    /// Abrupt close. Drops any in-flight segments.
    public func cancel() {
        if closed { return }
        closed = true
        keepAliveTask?.cancel()
        receiveTask?.cancel()
        transport.close(code: .abnormalClosure)
        continuation.finish()
    }

    // MARK: Internal — receive loop

    /// Start the background receive task. Called by the provider after
    /// constructing the session.
    func startReceiving() {
        guard receiveTask == nil else { return }
        receiveLoopFinished = false
        let cont = continuation
        let parser = self.parser
        let transport = self.transport
        let terminalMessage = self.terminalMessage
        startKeepAlive()
        let task = Task.detached { [weak self] in
            while !Task.isCancelled {
                let message: WebSocketMessage
                do {
                    message = try await transport.receive()
                } catch {
                    if Task.isCancelled { break }
                    if await self?.isClosedForReceiveLoop() == true { break }
                    await self?.markReceiveLoopFinished()
                    cont.finish(throwing: TranscriptionError.receiveFailed(message: "\(error)"))
                    return
                }
                if terminalMessage(message) {
                    break
                }
                let segments = parser.parse(message)
                for segment in segments {
                    cont.yield(segment)
                }
            }
            await self?.markReceiveLoopFinished()
            cont.finish()
        }
        receiveTask = task
        lifecycle.setReceiveTask(task)
    }

    private static func makeEventStream(
        lifecycle: WebSocketSessionLifecycle
    ) -> (
        AsyncThrowingStream<TranscriptSegment, Error>,
        AsyncThrowingStream<TranscriptSegment, Error>.Continuation
    ) {
        var captured: AsyncThrowingStream<TranscriptSegment, Error>.Continuation!
        let stream = AsyncThrowingStream<TranscriptSegment, Error>(
            bufferingPolicy: .bufferingNewest(512)
        ) { continuation in
            captured = continuation
        }
        captured.onTermination = { @Sendable _ in
            lifecycle.terminate(code: .abnormalClosure)
        }
        return (stream, captured)
    }

    private func startKeepAlive() {
        guard keepAliveTask == nil else { return }
        let transport = self.transport
        let task = Task.detached {
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: Self.keepAliveIntervalNanoseconds)
                if Task.isCancelled { return }
                try? await transport.send(.text(Self.keepAliveMessage))
            }
        }
        keepAliveTask = task
        lifecycle.setKeepAliveTask(task)
    }

    private func waitForReceiveDrain(timeoutNanoseconds: UInt64) async {
        let deadline = Date().addingTimeInterval(Double(timeoutNanoseconds) / 1_000_000_000)
        while !receiveLoopFinished && Date() < deadline {
            try? await Task.sleep(nanoseconds: min(10_000_000, timeoutNanoseconds))
        }
    }

    private func isClosedForReceiveLoop() -> Bool {
        closed
    }

    private func markReceiveLoopFinished() {
        receiveLoopFinished = true
    }
}

// MARK: - WebSocketSessionLifecycle

final class WebSocketSessionLifecycle: @unchecked Sendable {
    private let lock = NSLock()
    private var transport: (any WebSocketTransport)?
    private var receiveTask: Task<Void, Never>?
    private var keepAliveTask: Task<Void, Never>?

    func setTransport(_ transport: any WebSocketTransport) {
        lock.withLock {
            self.transport = transport
        }
    }

    func setReceiveTask(_ task: Task<Void, Never>?) {
        lock.withLock {
            self.receiveTask = task
        }
    }

    func setKeepAliveTask(_ task: Task<Void, Never>?) {
        lock.withLock {
            self.keepAliveTask = task
        }
    }

    func terminate(code: WebSocketCloseCode) {
        let snapshot: ((any WebSocketTransport)?, Task<Void, Never>?, Task<Void, Never>?) = lock.withLock {
            let snapshot = (transport, receiveTask, keepAliveTask)
            receiveTask = nil
            keepAliveTask = nil
            return snapshot
        }
        snapshot.1?.cancel()
        snapshot.2?.cancel()
        snapshot.0?.close(code: code)
    }
}

// MARK: - TranscriptionEventParser

/// Provider-specific WebSocket-message → `[TranscriptSegment]` decoder.
///
/// Defined as a struct rather than a protocol so it crosses actor boundaries
/// without Sendable-protocol-existential ceremony.
public struct TranscriptionEventParser: Sendable {
    public typealias Parse = @Sendable (WebSocketMessage) -> [TranscriptSegment]
    private let parser: Parse

    public init(_ parser: @escaping Parse) {
        self.parser = parser
    }

    public func parse(_ message: WebSocketMessage) -> [TranscriptSegment] {
        parser(message)
    }
}

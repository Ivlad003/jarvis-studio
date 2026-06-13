import Foundation

// MARK: - ReconnectClock

/// Abstraction over wall-clock sleeping, so tests can verify backoff schedule
/// without paying real wall-clock time.
public protocol ReconnectClock: Sendable {
    func sleep(seconds: Double) async
}

// MARK: - SystemClock

/// Production clock — delegates to `Task.sleep`.
public struct SystemClock: ReconnectClock {
    public init() {}
    public func sleep(seconds: Double) async {
        try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
    }
}

// MARK: - ReconnectingSession

/// A resilient wrapper around a sequence of `WebSocketTransport` connections.
///
/// On receive failure the session reopens a fresh transport using the injected
/// factory, replays the last 5-second audio ring buffer to the new transport,
/// then resumes normal operation. After 5 consecutive failures it finishes the
/// events stream and surfaces the final error.
///
/// The `events` stream is stable across reconnects — the consumer iterates one
/// stream end-to-end; each reconnect is transparent except for a brief gap.
public actor ReconnectingSession {

    // MARK: Public surface

    /// Single stable stream of transcript events — survives reconnects.
    public nonisolated let events: AsyncThrowingStream<TranscriptSegment, Error>

    // MARK: Configuration

    /// Exponential backoff delays in seconds: 250ms → 500ms → 1s → 2s → 4s.
    /// After five consecutive failures the session gives up.
    static let backoffSchedule: [Double] = [0.25, 0.5, 1.0, 2.0, 4.0]
    static let maxRetries = 5

    // MARK: Private state

    private let continuation: AsyncThrowingStream<TranscriptSegment, Error>.Continuation
    private let transportFactory: @Sendable () -> any WebSocketTransport
    private let parserFactory: @Sendable (TimeInterval) -> TranscriptionEventParser
    private let clock: any ReconnectClock
    private let keepAliveClock: any ReconnectClock
    private let audioBytesPerSecond: Double?
    private let defaultCloseMessage: String?
    private let finishDrainTimeoutNanoseconds: UInt64
    private let lifecycle: WebSocketSessionLifecycle

    /// Ring buffer: tuples of (wallClockDate, audioData, audioDurationSeconds).
    /// Entries older than 5 s are pruned before each reconnect replay.
    private var ringBuffer: [(timestamp: Date, data: Data, duration: TimeInterval)] = []
    private static let ringBufferWindow: TimeInterval = 5.0
    private var audioSentSeconds: TimeInterval = 0
    private var connectionTimestampOffset: TimeInterval = 0

    /// The active transport. Replaced on each reconnect.
    private var transport: (any WebSocketTransport)?
    private var receiveTask: Task<Void, Never>?
    private var keepAliveTask: Task<Void, Never>?
    private var closed = false
    private var receiveLoopFinished = false
    private static let keepAliveMessage = #"{"type":"KeepAlive"}"#
    private static let keepAliveIntervalSeconds: Double = 5.0

    // MARK: Init

    public init(
        transportFactory: @escaping @Sendable () -> any WebSocketTransport,
        parser: TranscriptionEventParser,
        clock: any ReconnectClock = SystemClock(),
        keepAliveClock: any ReconnectClock = SystemClock(),
        defaultCloseMessage: String? = nil,
        finishDrainTimeoutNanoseconds: UInt64 = 2_500_000_000
    ) {
        let lifecycle = WebSocketSessionLifecycle()
        let (stream, cont) = Self.makeEventStream(lifecycle: lifecycle)
        self.events = stream
        self.continuation = cont
        self.transportFactory = transportFactory
        self.parserFactory = { _ in parser }
        self.clock = clock
        self.keepAliveClock = keepAliveClock
        self.audioBytesPerSecond = nil
        self.defaultCloseMessage = defaultCloseMessage
        self.finishDrainTimeoutNanoseconds = finishDrainTimeoutNanoseconds
        self.lifecycle = lifecycle
    }

    public init(
        transportFactory: @escaping @Sendable () -> any WebSocketTransport,
        parserFactory: @escaping @Sendable (TimeInterval) -> TranscriptionEventParser,
        clock: any ReconnectClock = SystemClock(),
        keepAliveClock: any ReconnectClock = SystemClock(),
        audioBytesPerSecond: Double,
        defaultCloseMessage: String? = nil,
        finishDrainTimeoutNanoseconds: UInt64 = 2_500_000_000
    ) {
        let lifecycle = WebSocketSessionLifecycle()
        let (stream, cont) = Self.makeEventStream(lifecycle: lifecycle)
        self.events = stream
        self.continuation = cont
        self.transportFactory = transportFactory
        self.parserFactory = parserFactory
        self.clock = clock
        self.keepAliveClock = keepAliveClock
        self.audioBytesPerSecond = audioBytesPerSecond > 0 ? audioBytesPerSecond : nil
        self.defaultCloseMessage = defaultCloseMessage
        self.finishDrainTimeoutNanoseconds = finishDrainTimeoutNanoseconds
        self.lifecycle = lifecycle
    }

    // MARK: Public API

    /// Send raw PCM bytes to the active transport and push to the ring buffer.
    public func send(_ pcm: Data) async throws {
        if closed { throw TranscriptionError.alreadyClosed }

        // Buffer before touching the socket. If the transport write fails
        // during an outage, reconnect replay still has the audio that was
        // produced while the network was broken.
        let now = Date()
        let duration = audioDuration(for: pcm)
        audioSentSeconds += duration
        ringBuffer.append((timestamp: now, data: pcm, duration: duration))
        pruneRingBuffer(before: now.addingTimeInterval(-Self.ringBufferWindow))

        guard let t = transport else {
            return
        }
        do {
            try await t.send(.data(pcm))
        } catch {
            return
        }
    }

    /// Send a text control message (e.g. CloseStream) to the active transport.
    public func send(text: String) async throws {
        if closed { throw TranscriptionError.alreadyClosed }
        guard let t = transport else { throw TranscriptionError.sendFailed(message: "no active transport") }
        do {
            try await t.send(.text(text))
        } catch {
            throw TranscriptionError.sendFailed(message: "\(error)")
        }
    }

    /// Graceful close. Flushes and terminates the events stream.
    public func finish(closeMessage: String? = nil) async throws {
        if closed { return }
        closed = true

        if let msg = closeMessage ?? defaultCloseMessage, let t = transport {
            try? await t.send(.text(msg))
        }

        await waitForReceiveDrain(timeoutNanoseconds: finishDrainTimeoutNanoseconds)

        keepAliveTask?.cancel()
        receiveTask?.cancel()
        transport?.close(code: .normalClosure)
        continuation.finish()
    }

    /// Abrupt close — drops in-flight segments.
    public func cancel() {
        if closed { return }
        closed = true
        keepAliveTask?.cancel()
        receiveTask?.cancel()
        transport?.close(code: .abnormalClosure)
        continuation.finish()
    }

    // MARK: Internal bootstrap

    /// Opens the first transport and starts the receive/reconnect loop.
    func start() {
        guard receiveTask == nil, !closed else { return }
        connectionTimestampOffset = 0
        let firstTransport = transportFactory()
        self.transport = firstTransport
        lifecycle.setTransport(firstTransport)
        startKeepAlive()
        launchReceiveTask(consecutiveFailures: 0)
    }

    // MARK: Private — receive loop

    private func launchReceiveTask(consecutiveFailures: Int) {
        receiveLoopFinished = false
        let cont = continuation
        let parser = self.parserFactory(connectionTimestampOffset)

        receiveTask = Task.detached { [weak self] in
            guard let self else { return }
            var activeConsecutiveFailures = consecutiveFailures

            // Drain messages from the current transport until it fails or is cancelled.
            let currentTransport: any WebSocketTransport
            if let t = await self.transport {
                currentTransport = t
            } else {
                return
            }

            while !Task.isCancelled {
                let message: WebSocketMessage
                do {
                    message = try await currentTransport.receive()
                } catch {
                    // Receive failed — decide whether to reconnect or give up.
                    if Task.isCancelled { break }
                    await self.markReceiveLoopFinished()
                    await self.handleReceiveFailure(
                        consecutiveFailures: activeConsecutiveFailures,
                        cont: cont
                    )
                    return  // launchReceiveTask re-entry handles the rest.
                }
                // A received frame proves the fresh transport is healthy. Any
                // later disconnect is a new consecutive-failure run, not a
                // lifetime retry budget hit.
                activeConsecutiveFailures = 0
                let segments = parser.parse(message)
                for segment in segments {
                    cont.yield(segment)
                }
            }
            await self.markReceiveLoopFinished()
        }
    }

    private func handleReceiveFailure(
        consecutiveFailures: Int,
        cont: AsyncThrowingStream<TranscriptSegment, Error>.Continuation
    ) async {
        if closed { return }

        let nextFailureCount = consecutiveFailures + 1

        guard nextFailureCount <= Self.maxRetries else {
            cont.finish(throwing: TranscriptionError.maxRetriesExceeded)
            closed = true
            return
        }

        // Wait before reconnecting. Index is failures-1 because first failure
        // uses index 0 of the schedule.
        let backoffIndex = min(nextFailureCount - 1, Self.backoffSchedule.count - 1)
        let delay = Self.backoffSchedule[backoffIndex]
        await clock.sleep(seconds: delay)

        if closed { return }

        // Close the stale transport before opening a fresh one.
        transport?.close(code: .abnormalClosure)

        let freshTransport = transportFactory()
        self.transport = freshTransport
        lifecycle.setTransport(freshTransport)

        // Replay ring buffer contents (entries within the last 5 s) to the
        // new transport so Deepgram can re-process any audio it may have missed.
        let now = Date()
        pruneRingBuffer(before: now.addingTimeInterval(-Self.ringBufferWindow))
        let replayDuration = ringBuffer.reduce(TimeInterval(0)) { $0 + $1.duration }
        connectionTimestampOffset = max(0, audioSentSeconds - replayDuration)
        for entry in ringBuffer {
            try? await freshTransport.send(.data(entry.data))
        }

        launchReceiveTask(consecutiveFailures: nextFailureCount)
    }

    // MARK: Helpers

    private func pruneRingBuffer(before cutoff: Date) {
        ringBuffer.removeAll { $0.timestamp < cutoff }
    }

    private func audioDuration(for data: Data) -> TimeInterval {
        guard let audioBytesPerSecond else { return 0 }
        return TimeInterval(data.count) / audioBytesPerSecond
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
        let keepAliveClock = self.keepAliveClock
        let keepAliveIntervalSeconds = Self.keepAliveIntervalSeconds
        let task = Task.detached { [weak self] in
            while !Task.isCancelled {
                await keepAliveClock.sleep(seconds: keepAliveIntervalSeconds)
                if Task.isCancelled { return }
                await self?.sendKeepAliveIfOpen()
            }
        }
        keepAliveTask = task
        lifecycle.setKeepAliveTask(task)
    }

    private func sendKeepAliveIfOpen() async {
        guard !closed, let transport else { return }
        try? await transport.send(.text(Self.keepAliveMessage))
    }

    private func waitForReceiveDrain(timeoutNanoseconds: UInt64) async {
        let deadline = Date().addingTimeInterval(Double(timeoutNanoseconds) / 1_000_000_000)
        while !receiveLoopFinished && Date() < deadline {
            try? await Task.sleep(nanoseconds: min(10_000_000, timeoutNanoseconds))
        }
    }

    private func markReceiveLoopFinished() {
        receiveLoopFinished = true
    }

    // MARK: Test seams

    /// Insert a ring-buffer entry with a back-dated timestamp. Used by tests to
    /// verify that chunks older than the 5-s window are pruned before replay.
    func injectStaleRingBufferEntry(data: Data, age: TimeInterval) {
        injectStaleRingBufferEntry(data: data, age: age, duration: 0)
    }

    /// Insert a ring-buffer entry and account for its timeline duration. Used
    /// by timestamp-offset tests to emulate audio that was sent before the
    /// replay window and should therefore advance the original session clock
    /// without being replayed.
    func injectStaleRingBufferEntry(data: Data, age: TimeInterval, duration: TimeInterval) {
        let timestamp = Date().addingTimeInterval(-age)
        ringBuffer.append((timestamp: timestamp, data: data, duration: duration))
        audioSentSeconds += duration
    }
}

// MARK: - TranscriptionError additions

extension TranscriptionError {
    /// Maximum reconnect retries exceeded.
    public static let maxRetriesExceeded = TranscriptionError.receiveFailed(message: "max retries exceeded")
}

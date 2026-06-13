import Foundation
import Testing
@testable import TranscriptionKit

// MARK: - MockClock

/// Test clock that records sleep requests and returns immediately.
/// Lets tests verify the exact backoff schedule without wall-clock delays.
final class MockClock: ReconnectClock, @unchecked Sendable {
    private let lock = NSLock()
    private var _recordedSleeps: [Double] = []

    var recordedSleeps: [Double] {
        lock.withLock { _recordedSleeps }
    }

    func sleep(seconds: Double) async {
        lock.withLock { _recordedSleeps.append(seconds) }
        // Return immediately — no actual delay.
    }
}

// MARK: - AtomicCounter
// Swift 6 strict concurrency: a plain `var callCount` captured mutably in a
// @Sendable closure is an error. Use a lock-protected counter instead.
final class AtomicCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var value = 0

    func increment() -> Int {
        lock.withLock {
            value += 1
            return value
        }
    }
}

// MARK: - Helpers

/// A minimal Deepgram Results JSON frame.
private func resultsJSON(
    text: String,
    start: Double = 0,
    duration: Double = 1.0,
    isFinal: Bool = true
) -> String {
    """
    {"type":"Results","start":\(start),"duration":\(duration),"is_final":\(isFinal ? "true" : "false"),"channel":{"alternatives":[{"transcript":"\(text)","confidence":0.9}]}}
    """
}

/// Build a `ReconnectingSession` backed by the provided transport factory.
private func makeSession(
    factory: @escaping @Sendable () -> any WebSocketTransport,
    clock: any ReconnectClock = MockClock()
) async -> ReconnectingSession {
    let session = ReconnectingSession(
        transportFactory: factory,
        parser: DeepgramEventParser.makeParser(),
        clock: clock
    )
    await session.start()
    return session
}

private func repoFile(_ relativePath: String) throws -> String {
    let testFile = URL(fileURLWithPath: #filePath)
    let repoRoot = testFile
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()
    let fileURL = relativePath
        .split(separator: "/")
        .reduce(repoRoot) { partial, component in
            partial.appendingPathComponent(String(component))
        }
    return try String(contentsOf: fileURL, encoding: .utf8)
}

// MARK: - Tests

@Suite("ReconnectingSession — reconnect on disconnect", .serialized)
struct ReconnectDisconnectTests {

    /// Disconnect mid-session → reconnect succeeds → events from BOTH transports flow.
    @Test("Reconnects after receive error and emits segments from both transports")
    func reconnectsAndEmitsFromBothTransports() async throws {
        let transport1 = MockWebSocketTransport()
        let transport2 = MockWebSocketTransport()
        let counter = AtomicCounter()
        let clock = MockClock()

        let session = await makeSession(
            factory: {
                let n = counter.increment()
                return n == 1 ? transport1 : transport2
            },
            clock: clock
        )

        var iterator = session.events.makeAsyncIterator()

        // First transport yields one segment, then fails.
        transport1.enqueueText(resultsJSON(text: "from first"))
        let seg1 = try await iterator.next()
        #expect(seg1?.text == "from first")

        // Inject an error to simulate mid-session disconnect.
        transport1.injectReceiveError(TranscriptionError.receiveFailed(message: "connection reset"))

        // Second transport yields one segment after reconnect.
        // Give the reconnect loop a brief moment to wire up transport2.
        try await Task.sleep(nanoseconds: 10_000_000)  // 10 ms
        transport2.enqueueText(resultsJSON(text: "from second"))

        let seg2 = try await iterator.next()
        #expect(seg2?.text == "from second")

        await session.cancel()
    }
}

@Suite("ReconnectingSession — ring buffer replay", .serialized)
struct RingBufferReplayTests {

    /// Ring buffer replays: enqueue 3 audio chunks, force disconnect, verify the
    /// new transport receives those 3 chunks in recordedSends before any live data.
    @Test("Replays ring buffer contents to the new transport after reconnect")
    func ringBufferIsReplayedOnReconnect() async throws {
        let transport1 = MockWebSocketTransport()
        let transport2 = MockWebSocketTransport()
        let counter = AtomicCounter()
        let clock = MockClock()

        let session = await makeSession(
            factory: {
                let n = counter.increment()
                return n == 1 ? transport1 : transport2
            },
            clock: clock
        )

        // Send 3 audio chunks — they land in the ring buffer AND transport1.
        let chunk1 = Data([0x01])
        let chunk2 = Data([0x02])
        let chunk3 = Data([0x03])
        try await session.send(chunk1)
        try await session.send(chunk2)
        try await session.send(chunk3)

        // Disconnect transport1.
        transport1.injectReceiveError(TranscriptionError.receiveFailed(message: "disconnect"))

        // Wait for reconnect to complete.
        try await Task.sleep(nanoseconds: 50_000_000)  // 50 ms

        // transport2 should have received the 3 ring-buffer chunks before any new live data.
        let sends2 = transport2.recordedSends
        #expect(sends2.count >= 3)
        #expect(sends2[0] == .data(chunk1))
        #expect(sends2[1] == .data(chunk2))
        #expect(sends2[2] == .data(chunk3))

        await session.cancel()
    }

    @Test("Failed live sends are retained for reconnect replay")
    func failedLiveSendIsRetainedForReconnectReplay() async throws {
        let transport1 = MockWebSocketTransport()
        let transport2 = MockWebSocketTransport()
        let counter = AtomicCounter()
        let clock = MockClock()

        let session = await makeSession(
            factory: {
                let n = counter.increment()
                return n == 1 ? transport1 : transport2
            },
            clock: clock
        )

        let outageChunk = Data([0x44])
        transport1.injectSendError(TranscriptionError.sendFailed(message: "network write failed"))

        try await session.send(outageChunk)
        #expect(!transport1.recordedSends.contains(.data(outageChunk)))

        transport1.injectReceiveError(TranscriptionError.receiveFailed(message: "disconnect after failed send"))
        try await Task.sleep(nanoseconds: 50_000_000)

        let sends2 = transport2.recordedSends
        #expect(sends2.contains(.data(outageChunk)))

        await session.cancel()
    }
}

@Suite("ReconnectingSession — max retries", .serialized)
struct MaxRetriesTests {

    /// After 5 consecutive failures the events stream finishes (next() returns nil).
    @Test("Events stream finishes after max retries exceeded")
    func eventsStreamFinishesAfterMaxRetries() async throws {
        let clock = MockClock()
        // Every call to the factory produces a transport that immediately errors.
        let session = await makeSession(
            factory: {
                let t = MockWebSocketTransport()
                // Inject the error before returning so the receive loop hits it immediately.
                t.injectReceiveError(TranscriptionError.receiveFailed(message: "always fails"))
                return t
            },
            clock: clock
        )

        // Drain the stream until it finishes. With MockClock (instant sleeps) this
        // should complete quickly. Use a timeout task to avoid hanging if broken.
        let finishedTask = Task {
            var iterator = session.events.makeAsyncIterator()
            // The stream must terminate — keep calling next() until nil.
            var count = 0
            do {
                while try await iterator.next() != nil {
                    count += 1
                    if count > 100 { break }  // safety valve
                }
                return false
            } catch TranscriptionError.receiveFailed(let message) where message == "max retries exceeded" {
                return true
            } catch {
                return false
            }
        }

        let timeoutTask = Task {
            try? await Task.sleep(nanoseconds: 500_000_000)  // 500 ms
            finishedTask.cancel()
            return false
        }

        let finished = await finishedTask.value
        timeoutTask.cancel()
        #expect(finished == true)
    }

    /// A successful receive after reconnect resets the consecutive-failure
    /// budget. Long sessions with isolated network drops should not die after
    /// five total drops spread across otherwise healthy transports.
    @Test("Successful reconnect receive resets the max-retry budget")
    func successfulReceiveResetsMaxRetryBudget() async throws {
        let clock = MockClock()
        let transports = (0..<7).map { _ in MockWebSocketTransport() }
        let counter = AtomicCounter()
        let session = await makeSession(
            factory: {
                let index = min(counter.increment() - 1, transports.count - 1)
                return transports[index]
            },
            clock: clock
        )

        var iterator = session.events.makeAsyncIterator()

        for i in 0..<6 {
            transports[i].enqueueText(resultsJSON(text: "healthy-\(i)"))
            let segment = try await iterator.next()
            #expect(segment?.text == "healthy-\(i)")

            transports[i].injectReceiveError(TranscriptionError.receiveFailed(message: "isolated drop \(i)"))
            try await Task.sleep(nanoseconds: 10_000_000)
        }

        transports[6].enqueueText(resultsJSON(text: "still connected"))
        let segmentAfterSixthIsolatedDrop = try await iterator.next()
        #expect(segmentAfterSixthIsolatedDrop?.text == "still connected")

        await session.cancel()
    }
}

@Suite("ReconnectingSession — backoff schedule", .serialized)
struct BackoffScheduleTests {

    /// Verify that the sleep calls use the correct exponential schedule.
    @Test("Backoff schedule matches spec: 0.25, 0.5, 1.0, 2.0, 4.0")
    func backoffScheduleIsCorrect() async throws {
        let clock = MockClock()
        let session = await makeSession(
            factory: {
                let t = MockWebSocketTransport()
                t.injectReceiveError(TranscriptionError.receiveFailed(message: "always fails"))
                return t
            },
            clock: clock
        )

        // Drain until stream ends.
        let drainTask = Task {
            var iterator = session.events.makeAsyncIterator()
            var count = 0
            do {
                while try await iterator.next() != nil {
                    count += 1
                    if count > 100 { break }
                }
            } catch TranscriptionError.receiveFailed(let message) where message == "max retries exceeded" {
                return
            } catch {
                Issue.record("Unexpected stream error: \(error)")
                return
            }
        }

        let timeoutTask = Task {
            try? await Task.sleep(nanoseconds: 500_000_000)
            drainTask.cancel()
        }

        await drainTask.value
        timeoutTask.cancel()

        // The clock should have recorded exactly the backoff schedule delays
        // (one sleep per failure, 5 failures total).
        let sleeps = clock.recordedSleeps
        #expect(sleeps.count == ReconnectingSession.maxRetries)
        #expect(sleeps == ReconnectingSession.backoffSchedule)
    }
}

@Suite("ReconnectingSession — KeepAlive", .serialized)
struct KeepAliveTests {

    @Test("Sends KeepAlive after about five seconds without audio")
    func sendsKeepAliveAfterAboutFiveSecondsWithoutAudio() async throws {
        let transport = MockWebSocketTransport()
        let session = await makeSession(factory: { transport })

        try await Task.sleep(nanoseconds: 6_200_000_000)

        #expect(transport.recordedSends.contains(.text(DeepgramProvider.keepAliveMessage)))
        await session.cancel()
    }

    @Test("KeepAlive loop uses injectable clock instead of hardcoded Task.sleep")
    func keepAliveLoopUsesInjectableClock() throws {
        let source = try repoFile("Sources/TranscriptionKit/ReconnectingSession.swift")

        #expect(source.contains("keepAliveIntervalSeconds: Double = 5.0"))
        #expect(source.contains("keepAliveClock.sleep(seconds: keepAliveIntervalSeconds)"))
        #expect(!source.contains("keepAliveIntervalNanoseconds: UInt64 = 8_000_000_000"))
    }
}

@Suite("ReconnectingSession — ring buffer aging", .serialized)
struct RingBufferAgingTests {

    /// Recent chunks (within 5 s) are replayed after reconnect.
    @Test("Recent ring-buffer chunks are replayed after reconnect")
    func recentChunksAreReplayed() async throws {
        let transport1 = MockWebSocketTransport()
        let transport2 = MockWebSocketTransport()
        let counter = AtomicCounter()
        let clock = MockClock()

        let session = await makeSession(
            factory: {
                let n = counter.increment()
                return n == 1 ? transport1 : transport2
            },
            clock: clock
        )

        let liveChunk = Data([0xAA])
        try await session.send(liveChunk)

        // Force disconnect immediately.
        transport1.injectReceiveError(TranscriptionError.receiveFailed(message: "disconnect"))

        // Wait for reconnect.
        try await Task.sleep(nanoseconds: 50_000_000)

        // Send a new live chunk after reconnect — this goes to transport2 only (no replay).
        let newChunk = Data([0xBB])
        try await session.send(newChunk)

        // transport2.recordedSends = [liveChunk (replay), newChunk (live)].
        // liveChunk was sent within the 5-s window so it IS replayed.
        let sends2 = transport2.recordedSends
        #expect(sends2.contains(.data(liveChunk)))
        let replayIdx = sends2.firstIndex(of: .data(liveChunk))!
        let liveIdx = sends2.firstIndex(of: .data(newChunk))!
        #expect(replayIdx < liveIdx)

        await session.cancel()
    }

    /// Chunks older than 5 s must NOT be replayed after reconnect.
    @Test("Chunks older than 5 s are pruned before replay")
    func chunksOlderThan5sArePruned() async throws {
        let transport1 = MockWebSocketTransport()
        let transport2 = MockWebSocketTransport()
        let counter = AtomicCounter()
        let clock = MockClock()

        let session = await makeSession(
            factory: {
                let n = counter.increment()
                return n == 1 ? transport1 : transport2
            },
            clock: clock
        )

        // Inject an aged entry directly using the internal test helper.
        let staleChunk = Data([0xFF])
        await session.injectStaleRingBufferEntry(data: staleChunk, age: 10.0)

        // Trigger disconnect.
        transport1.injectReceiveError(TranscriptionError.receiveFailed(message: "disconnect"))

        // Wait for reconnect.
        try await Task.sleep(nanoseconds: 50_000_000)

        // The stale chunk should NOT appear in transport2's sends.
        let sends2 = transport2.recordedSends
        #expect(!sends2.contains(.data(staleChunk)))

        await session.cancel()
    }
}

@Suite("ReconnectingSession — timestamp offsets", .serialized)
struct ReconnectTimestampOffsetTests {
    @Test("Reconnect offsets provider-local timestamps onto the original session timeline")
    func reconnectOffsetsProviderLocalTimestamps() async throws {
        let transport1 = MockWebSocketTransport()
        let transport2 = MockWebSocketTransport()
        let counter = AtomicCounter()
        let clock = MockClock()

        let session = ReconnectingSession(
            transportFactory: {
                let n = counter.increment()
                return n == 1 ? transport1 : transport2
            },
            parserFactory: { offset in
                DeepgramEventParser.makeParser(timestampOffset: offset)
            },
            clock: clock,
            audioBytesPerSecond: 1
        )
        await session.start()

        await session.injectStaleRingBufferEntry(
            data: Data(repeating: 0x01, count: 10),
            age: 10.0,
            duration: 10.0
        )
        try await session.send(Data(repeating: 0x02, count: 5))

        var iterator = session.events.makeAsyncIterator()
        transport1.injectReceiveError(TranscriptionError.receiveFailed(message: "disconnect"))
        try await Task.sleep(nanoseconds: 50_000_000)

        transport2.enqueueText(resultsJSON(text: "after reconnect", start: 0, duration: 1.0))
        let segment = try await iterator.next()
        #expect(segment?.text == "after reconnect")
        #expect(segment?.start == 10.0)
        #expect(segment?.end == 11.0)

        await session.cancel()
    }
}

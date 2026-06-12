import Foundation
@testable import TranscriptionKit

// MARK: - MockWebSocketTransport

/// Test double for `WebSocketTransport`.
///
/// Producers (the test) call `enqueueIncoming(_:)` to push messages that the
/// receive loop will yield. Consumers (the production code under test) call
/// `send(_:)` to record outgoing messages, which the test inspects via
/// `recordedSends`.
///
/// `receive()` blocks until a message is enqueued or the transport is closed.
/// Closing makes pending and future `receive()` calls throw.
final class MockWebSocketTransport: WebSocketTransport, @unchecked Sendable {

    // MARK: State (protected by `lock`)

    private let lock = NSLock()
    private var incoming: [WebSocketMessage] = []
    private var sends: [WebSocketMessage] = []
    private var continuations: [CheckedContinuation<WebSocketMessage, Error>] = []
    private var pendingErrors: [Error] = []
    private var pendingSendErrors: [Error] = []
    private var isClosed: Bool = false
    private var lastCloseCode: WebSocketCloseCode?

    // MARK: Public read API for tests

    var recordedSends: [WebSocketMessage] {
        lock.withLock { sends }
    }

    var didClose: Bool {
        lock.withLock { isClosed }
    }

    var closeCode: WebSocketCloseCode? {
        lock.withLock { lastCloseCode }
    }

    // MARK: Test driver API

    /// Enqueue a message for the next call to `receive()` to return.
    func enqueueIncoming(_ message: WebSocketMessage) {
        let waiter: CheckedContinuation<WebSocketMessage, Error>? = lock.withLock {
            if !continuations.isEmpty {
                return continuations.removeFirst()
            } else {
                incoming.append(message)
                return nil
            }
        }
        waiter?.resume(returning: message)
    }

    /// Helper: enqueue a JSON-text frame (Deepgram's wire format).
    func enqueueText(_ text: String) {
        enqueueIncoming(.text(text))
    }

    /// Inject a receive error — the next pending or future `receive()` call
    /// will throw this error instead of returning a message. Use this to
    /// simulate mid-session disconnects without closing the transport.
    func injectReceiveError(_ error: Error) {
        let waiter: CheckedContinuation<WebSocketMessage, Error>? = lock.withLock {
            if !continuations.isEmpty {
                return continuations.removeFirst()
            } else {
                pendingErrors.append(error)
                return nil
            }
        }
        waiter?.resume(throwing: error)
    }

    /// Inject a send error — the next `send(_:)` call throws without recording
    /// the message as delivered.
    func injectSendError(_ error: Error) {
        lock.withLock {
            pendingSendErrors.append(error)
        }
    }

    // MARK: WebSocketTransport

    func send(_ message: WebSocketMessage) async throws {
        enum SendDecision {
            case sent
            case error(Error)
            case closed
        }
        let decision: SendDecision = lock.withLock {
            if isClosed { return .closed }
            if !pendingSendErrors.isEmpty { return .error(pendingSendErrors.removeFirst()) }
            sends.append(message)
            return .sent
        }
        switch decision {
        case .sent:
            return
        case .error(let error):
            throw error
        case .closed:
            throw TranscriptionError.sendFailed(message: "transport closed")
        }
    }

    func receive() async throws -> WebSocketMessage {
        // Either pull a queued message/error synchronously or register a
        // continuation that the next `enqueueIncoming` / `injectReceiveError`
        // (or `close`) will resume.
        enum ReceiveDecision {
            case ready(WebSocketMessage)
            case error(Error)
            case closed
            case wait
        }

        return try await withCheckedThrowingContinuation { (cont: CheckedContinuation<WebSocketMessage, Error>) in
            let decision: ReceiveDecision = lock.withLock {
                if isClosed { return .closed }
                if !pendingErrors.isEmpty { return .error(pendingErrors.removeFirst()) }
                if !incoming.isEmpty { return .ready(incoming.removeFirst()) }
                continuations.append(cont)
                return .wait
            }
            switch decision {
            case .ready(let msg):
                cont.resume(returning: msg)
            case .error(let err):
                cont.resume(throwing: err)
            case .closed:
                cont.resume(throwing: TranscriptionError.receiveFailed(message: "transport closed"))
            case .wait:
                break  // continuation is held inside `continuations`; resumed later.
            }
        }
    }

    func close(code: WebSocketCloseCode) {
        let pending: [CheckedContinuation<WebSocketMessage, Error>] = lock.withLock {
            if isClosed { return [] }
            isClosed = true
            lastCloseCode = code
            let pending = continuations
            continuations.removeAll()
            return pending
        }
        for cont in pending {
            cont.resume(throwing: TranscriptionError.receiveFailed(message: "transport closed"))
        }
    }
}

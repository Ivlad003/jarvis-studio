import Foundation

// MARK: - DeepgramProvider

/// `TranscriptionProvider` implementation for Deepgram's streaming
/// `wss://api.deepgram.com/v1/listen` endpoint.
///
/// Audio in: linear16 PCM (sample rate / channels per `TranscriptionConfig`).
/// Audio out: JSON `Results` events delivered as text WebSocket frames.
///
/// The provider is stateless — `openSession(config:)` constructs a fresh
/// transport and `TranscriptionSession` per call. Reconnection / ring-buffer
/// resilience lives one layer up (next iteration of Phase A Week 2).
public final class DeepgramProvider: TranscriptionProvider, Sendable {

    public typealias TransportFactory = @Sendable (URL, [String: String]) -> any WebSocketTransport

    // MARK: Stored properties

    private let apiKey: String
    private let endpoint: URL
    private let transportFactory: TransportFactory
    private let sessionDrainTimeoutNanoseconds: UInt64

    public static let closeStreamMessage = #"{"type":"CloseStream"}"#
    public static let keepAliveMessage = #"{"type":"KeepAlive"}"#

    // MARK: Init

    public init(
        apiKey: String,
        endpoint: URL = DeepgramProvider.defaultEndpoint,
        transportFactory: @escaping TransportFactory = DeepgramProvider.defaultTransportFactory,
        sessionDrainTimeoutNanoseconds: UInt64 = 2_500_000_000
    ) {
        self.apiKey = apiKey
        self.endpoint = endpoint
        self.transportFactory = transportFactory
        self.sessionDrainTimeoutNanoseconds = sessionDrainTimeoutNanoseconds
    }

    // MARK: TranscriptionProvider

    public func openSession(config: TranscriptionConfig) async throws -> TranscriptionSession {
        let url = try Self.buildURL(endpoint: endpoint, config: config)
        let headers = ["Authorization": "Token \(apiKey)"]
        let transport = transportFactory(url, headers)
        let session = TranscriptionSession(
            transport: transport,
            parser: DeepgramEventParser.makeParser(),
            defaultCloseMessage: Self.closeStreamMessage,
            finishDrainTimeoutNanoseconds: sessionDrainTimeoutNanoseconds,
            terminalMessage: DeepgramEventParser.isTerminalMetadata
        )
        await session.startReceiving()
        return session
    }

    /// Opens a resilient session backed by `ReconnectingSession`.
    ///
    /// Preferred over `openSession(config:)` for production use — reconnects
    /// automatically with exponential backoff and replays the 5-s audio ring
    /// buffer on each reconnect.
    public func openResilientSession(
        config: TranscriptionConfig,
        clock: any ReconnectClock = SystemClock()
    ) async throws -> ReconnectingSession {
        let url = try Self.buildURL(endpoint: endpoint, config: config)
        let headers = ["Authorization": "Token \(apiKey)"]
        // Capture url/headers/factory by value so the closure is @Sendable without
        // capturing `self` across an actor boundary.
        let factory = transportFactory
        let session = ReconnectingSession(
            transportFactory: { factory(url, headers) },
            parserFactory: { offset in
                DeepgramEventParser.makeParser(timestampOffset: offset)
            },
            clock: clock,
            audioBytesPerSecond: Double(config.sampleRate * config.channels * 2),
            defaultCloseMessage: Self.closeStreamMessage
        )
        await session.start()
        return session
    }

    // MARK: Defaults

    public static let defaultEndpoint = URL(string: "wss://api.deepgram.com/v1/listen")!

    public static let defaultTransportFactory: TransportFactory = { url, headers in
        URLSessionWebSocketTransport(url: url, headers: headers)
    }

    // MARK: URL builder

    /// Build the Deepgram listen URL from a `TranscriptionConfig`.
    /// Exposed `internal` for tests.
    static func buildURL(endpoint: URL, config: TranscriptionConfig) throws -> URL {
        guard var components = URLComponents(url: endpoint, resolvingAgainstBaseURL: false) else {
            throw TranscriptionError.invalidEndpoint
        }
        var items: [URLQueryItem] = [
            URLQueryItem(name: "encoding", value: "linear16"),
            URLQueryItem(name: "sample_rate", value: String(config.sampleRate)),
            URLQueryItem(name: "channels", value: String(config.channels)),
            URLQueryItem(name: "model", value: config.model),
            URLQueryItem(name: "smart_format", value: config.punctuate ? "true" : "false"),
            URLQueryItem(name: "interim_results", value: config.interimResults ? "true" : "false"),
            URLQueryItem(name: "endpointing", value: "300"),
        ]
        if let lang = config.language {
            items.append(URLQueryItem(name: "language", value: lang))
        }
        components.queryItems = items
        guard let url = components.url else {
            throw TranscriptionError.invalidEndpoint
        }
        return url
    }
}

// MARK: - DeepgramEventParser

/// Decodes Deepgram `Results` JSON frames into `TranscriptSegment` values.
///
/// Public for tests; production code goes through `TranscriptionEventParser`
/// (the type-erased struct used by `TranscriptionSession`).
public enum DeepgramEventParser {

    public static func makeParser() -> TranscriptionEventParser {
        makeParser(timestampOffset: 0)
    }

    public static func makeParser(timestampOffset: TimeInterval) -> TranscriptionEventParser {
        TranscriptionEventParser { message in
            DeepgramEventParser.parse(message, timestampOffset: timestampOffset)
        }
    }

    /// Parse a single WebSocket message into zero or more transcript segments.
    public static func parse(_ message: WebSocketMessage) -> [TranscriptSegment] {
        parse(message, timestampOffset: 0)
    }

    /// Parse a single WebSocket message and offset provider-local timestamps
    /// into the original session timeline.
    public static func parse(
        _ message: WebSocketMessage,
        timestampOffset: TimeInterval
    ) -> [TranscriptSegment] {
        let json: String
        switch message {
        case .text(let s): json = s
        case .data(let d):
            // Some servers send JSON as a binary frame; tolerate it.
            guard let s = String(data: d, encoding: .utf8) else { return [] }
            json = s
        }
        guard let data = json.data(using: .utf8) else { return [] }
        guard let event = try? JSONDecoder().decode(DeepgramEvent.self, from: data) else {
            return []
        }
        guard event.type == "Results" else {
            return []
        }
        guard let alternative = event.channel?.alternatives.first else {
            return []
        }
        let text = alternative.transcript.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return [] }
        let start = (event.start ?? 0) + timestampOffset
        let duration = event.duration ?? 0
        return [
            TranscriptSegment(
                start: start,
                end: start + duration,
                text: text,
                confidence: alternative.confidence ?? 0,
                isFinal: event.isFinal ?? false,
                speaker: alternative.words?.first?.speaker
            ),
        ]
    }

    public static func isTerminalMetadata(_ message: WebSocketMessage) -> Bool {
        let json: String
        switch message {
        case .text(let s): json = s
        case .data(let d):
            guard let s = String(data: d, encoding: .utf8) else { return false }
            json = s
        }
        guard let data = json.data(using: .utf8),
              let event = try? JSONDecoder().decode(DeepgramEvent.self, from: data) else {
            return false
        }
        return event.type == "Metadata"
    }
}

// MARK: - Deepgram JSON model (private)

private struct DeepgramEvent: Decodable {
    let type: String?
    let start: Double?
    let duration: Double?
    let isFinal: Bool?
    let channel: DeepgramChannel?

    enum CodingKeys: String, CodingKey {
        case type
        case start
        case duration
        case isFinal = "is_final"
        case channel
    }
}

private struct DeepgramChannel: Decodable {
    let alternatives: [DeepgramAlternative]
}

private struct DeepgramAlternative: Decodable {
    let transcript: String
    let confidence: Double?
    let words: [DeepgramWord]?
}

private struct DeepgramWord: Decodable {
    let word: String
    let start: Double?
    let end: Double?
    let speaker: Int?
}

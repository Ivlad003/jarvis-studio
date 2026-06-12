import Foundation
import Testing
@testable import TranscriptionKit

// MARK: - DeepgramProvider URL building

@Suite("DeepgramProvider URL building")
struct DeepgramProviderURLTests {

    @Test("Default URL contains required query params")
    func defaultURLHasExpectedParams() throws {
        let config = TranscriptionConfig(language: "en")
        let url = try DeepgramProvider.buildURL(
            endpoint: DeepgramProvider.defaultEndpoint,
            config: config
        )
        let components = URLComponents(url: url, resolvingAgainstBaseURL: false)!
        let items = components.queryItems ?? []
        let dict = Dictionary(uniqueKeysWithValues: items.map { ($0.name, $0.value ?? "") })

        #expect(dict["encoding"] == "linear16")
        #expect(dict["sample_rate"] == "16000")
        #expect(dict["channels"] == "1")
        #expect(dict["model"] == "nova-2")
        #expect(dict["smart_format"] == "true")
        #expect(dict["interim_results"] == "true")
        #expect(dict["language"] == "en")
    }

    @Test("Endpointing is sent as documented millisecond value")
    func endpointingUsesMilliseconds() throws {
        let config = TranscriptionConfig()
        let url = try DeepgramProvider.buildURL(
            endpoint: DeepgramProvider.defaultEndpoint,
            config: config
        )
        let components = URLComponents(url: url, resolvingAgainstBaseURL: false)!
        let items = components.queryItems ?? []
        let dict = Dictionary(uniqueKeysWithValues: items.map { ($0.name, $0.value ?? "") })

        #expect(dict["endpointing"] == "300")
    }

    @Test("URL omits language when nil (auto-detect)")
    func urlOmitsLanguageWhenNil() throws {
        let config = TranscriptionConfig(language: nil)
        let url = try DeepgramProvider.buildURL(
            endpoint: DeepgramProvider.defaultEndpoint,
            config: config
        )
        let components = URLComponents(url: url, resolvingAgainstBaseURL: false)!
        let names = (components.queryItems ?? []).map(\.name)
        #expect(!names.contains("language"))
    }

    @Test("URL reflects custom sample rate and model")
    func urlReflectsCustomConfig() throws {
        let config = TranscriptionConfig(model: "nova-3", sampleRate: 48_000, channels: 2)
        let url = try DeepgramProvider.buildURL(
            endpoint: DeepgramProvider.defaultEndpoint,
            config: config
        )
        let components = URLComponents(url: url, resolvingAgainstBaseURL: false)!
        let dict = Dictionary(uniqueKeysWithValues: (components.queryItems ?? []).map { ($0.name, $0.value ?? "") })
        #expect(dict["model"] == "nova-3")
        #expect(dict["sample_rate"] == "48000")
        #expect(dict["channels"] == "2")
    }
}

// MARK: - DeepgramEventParser

@Suite("DeepgramEventParser JSON decoding")
struct DeepgramEventParserTests {

    @Test("Parses a final Results event into one segment")
    func parsesFinalResultsEvent() {
        let json = """
        {
          "type": "Results",
          "start": 1.5,
          "duration": 0.8,
          "is_final": true,
          "channel": {
            "alternatives": [
              {
                "transcript": "hello world",
                "confidence": 0.97
              }
            ]
          }
        }
        """
        let segments = DeepgramEventParser.parse(.text(json))
        #expect(segments.count == 1)
        let seg = segments[0]
        #expect(seg.text == "hello world")
        #expect(seg.start == 1.5)
        #expect(seg.end == 2.3)
        #expect(seg.isFinal == true)
        #expect(abs(seg.confidence - 0.97) < 0.0001)
    }

    @Test("Applies timestamp offset to Results events")
    func appliesTimestampOffset() {
        let json = """
        {
          "type": "Results",
          "start": 1.5,
          "duration": 0.8,
          "is_final": true,
          "channel": {
            "alternatives": [
              {
                "transcript": "hello again",
                "confidence": 0.97
              }
            ]
          }
        }
        """
        let segments = DeepgramEventParser.parse(.text(json), timestampOffset: 10.0)
        #expect(segments.count == 1)
        #expect(segments[0].start == 11.5)
        #expect(segments[0].end == 12.3)
    }

    @Test("Parses interim Results event with isFinal=false")
    func parsesInterimEvent() {
        let json = """
        {
          "type": "Results",
          "start": 0.0,
          "duration": 0.5,
          "is_final": false,
          "channel": {
            "alternatives": [{ "transcript": "hi", "confidence": 0.6 }]
          }
        }
        """
        let segments = DeepgramEventParser.parse(.text(json))
        #expect(segments.count == 1)
        #expect(segments[0].isFinal == false)
    }

    @Test("Returns empty for non-Results event types (Metadata, SpeechStarted)")
    func ignoresNonResultsEvents() {
        let metadata = """
        {"type":"Metadata","request_id":"abc","sha256":"x"}
        """
        let speechStarted = """
        {"type":"SpeechStarted","timestamp":1.234}
        """
        #expect(DeepgramEventParser.parse(.text(metadata)).isEmpty)
        #expect(DeepgramEventParser.parse(.text(speechStarted)).isEmpty)
    }

    @Test("Returns empty for empty transcript text")
    func ignoresEmptyTranscript() {
        let json = """
        {"type":"Results","start":0,"duration":0.1,"is_final":false,"channel":{"alternatives":[{"transcript":"","confidence":0}]}}
        """
        #expect(DeepgramEventParser.parse(.text(json)).isEmpty)
    }

    @Test("Returns empty for malformed JSON")
    func ignoresMalformedJSON() {
        #expect(DeepgramEventParser.parse(.text("{not json}")).isEmpty)
        #expect(DeepgramEventParser.parse(.text("")).isEmpty)
    }

    @Test("Tolerates JSON delivered as binary frame")
    func parsesBinaryFrameWithJSON() {
        let json = """
        {"type":"Results","start":0,"duration":0.5,"is_final":true,"channel":{"alternatives":[{"transcript":"binary frame","confidence":0.9}]}}
        """
        let data = Data(json.utf8)
        let segments = DeepgramEventParser.parse(.data(data))
        #expect(segments.count == 1)
        #expect(segments[0].text == "binary frame")
    }
}

// MARK: - End-to-end session through MockWebSocketTransport

@Suite("DeepgramProvider session via mock transport")
struct DeepgramProviderSessionTests {

    @Test("openSession sends audio bytes to transport")
    func openSessionSendsAudio() async throws {
        let mock = MockWebSocketTransport()
        let provider = DeepgramProvider(
            apiKey: "test-key",
            transportFactory: { _, _ in mock },
            sessionDrainTimeoutNanoseconds: 1_000_000
        )

        let session = try await provider.openSession(config: TranscriptionConfig(language: "en"))

        let audio = Data([0x01, 0x02, 0x03, 0x04])
        try await session.send(audio)

        #expect(mock.recordedSends.count == 1)
        #expect(mock.recordedSends[0] == .data(audio))

        await session.cancel()
    }

    @Test("Session yields parsed transcript segments from incoming messages")
    func sessionYieldsTranscriptSegments() async throws {
        let mock = MockWebSocketTransport()
        let provider = DeepgramProvider(
            apiKey: "test-key",
            transportFactory: { _, _ in mock },
            sessionDrainTimeoutNanoseconds: 1_000_000
        )

        let session = try await provider.openSession(config: TranscriptionConfig())

        let json = """
        {"type":"Results","start":0,"duration":1.0,"is_final":true,"channel":{"alternatives":[{"transcript":"hello","confidence":0.9}]}}
        """
        mock.enqueueText(json)

        var iterator = session.events.makeAsyncIterator()
        let segment = try await iterator.next()
        #expect(segment != nil)
        #expect(segment?.text == "hello")
        #expect(segment?.isFinal == true)

        await session.cancel()
    }

    @Test("finish() sends CloseStream control message and closes transport")
    func finishSendsCloseStreamMessage() async throws {
        let mock = MockWebSocketTransport()
        let provider = DeepgramProvider(
            apiKey: "test-key",
            transportFactory: { _, _ in mock },
            sessionDrainTimeoutNanoseconds: 1_000_000
        )

        let session = try await provider.openSession(config: TranscriptionConfig())
        try await session.finish()

        // The CloseStream text message should be in recordedSends
        let texts = mock.recordedSends.compactMap { msg -> String? in
            if case .text(let s) = msg { return s }
            return nil
        }
        #expect(texts.contains(DeepgramProvider.closeStreamMessage))
        #expect(mock.didClose == true)
        #expect(mock.closeCode == .normalClosure)
    }

    @Test("cancel() closes transport with abnormalClosure")
    func cancelClosesTransportAbnormally() async throws {
        let mock = MockWebSocketTransport()
        let provider = DeepgramProvider(
            apiKey: "test-key",
            transportFactory: { _, _ in mock }
        )

        let session = try await provider.openSession(config: TranscriptionConfig())
        await session.cancel()

        #expect(mock.didClose == true)
        #expect(mock.closeCode == .abnormalClosure)
    }

    @Test("send() after finish() throws alreadyClosed")
    func sendAfterFinishThrows() async throws {
        let mock = MockWebSocketTransport()
        let provider = DeepgramProvider(
            apiKey: "test-key",
            transportFactory: { _, _ in mock },
            sessionDrainTimeoutNanoseconds: 1_000_000
        )

        let session = try await provider.openSession(config: TranscriptionConfig())
        try await session.finish()

        await #expect(throws: TranscriptionError.self) {
            try await session.send(Data([0x00]))
        }
    }
}

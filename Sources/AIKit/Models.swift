import Foundation

// MARK: - Tool values

public indirect enum JSONValue: Sendable, Codable, Equatable {
    case null
    case bool(Bool)
    case number(Double)
    case string(String)
    case array([JSONValue])
    case object([String: JSONValue])

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            self = .null
        } else if let value = try? container.decode(Bool.self) {
            self = .bool(value)
        } else if let value = try? container.decode(Double.self) {
            self = .number(value)
        } else if let value = try? container.decode(String.self) {
            self = .string(value)
        } else if let value = try? container.decode([JSONValue].self) {
            self = .array(value)
        } else if let value = try? container.decode([String: JSONValue].self) {
            self = .object(value)
        } else {
            throw DecodingError.dataCorruptedError(
                in: container,
                debugDescription: "Unsupported JSON value"
            )
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .null:
            try container.encodeNil()
        case .bool(let value):
            try container.encode(value)
        case .number(let value):
            try container.encode(value)
        case .string(let value):
            try container.encode(value)
        case .array(let value):
            try container.encode(value)
        case .object(let value):
            try container.encode(value)
        }
    }

    public var anyValue: Any {
        switch self {
        case .null:
            return NSNull()
        case .bool(let value):
            return value
        case .number(let value):
            return value
        case .string(let value):
            return value
        case .array(let values):
            return values.map(\.anyValue)
        case .object(let values):
            return values.mapValues(\.anyValue)
        }
    }

    public init(any value: Any) throws {
        switch value {
        case is NSNull:
            self = .null
        case let value as Bool:
            self = .bool(value)
        case let value as Int:
            self = .number(Double(value))
        case let value as Double:
            self = .number(value)
        case let value as String:
            self = .string(value)
        case let value as [Any]:
            self = .array(try value.map { try JSONValue(any: $0) })
        case let value as [String: Any]:
            self = .object(try value.mapValues { try JSONValue(any: $0) })
        default:
            throw AIError.decodingFailed(message: "Unsupported JSON value: \(type(of: value))")
        }
    }

    public static func parseJSONString(_ text: String) throws -> JSONValue {
        guard let data = text.data(using: .utf8) else {
            throw AIError.decodingFailed(message: "Tool arguments are not UTF-8")
        }
        let object = try JSONSerialization.jsonObject(with: data)
        return try JSONValue(any: object)
    }

    public func jsonString() throws -> String {
        let data = try JSONSerialization.data(withJSONObject: anyValue, options: [.sortedKeys])
        guard let text = String(data: data, encoding: .utf8) else {
            throw AIError.sendFailed(message: "Could not encode JSON value as UTF-8")
        }
        return text
    }
}

public struct ToolSpec: Sendable, Codable, Equatable {
    public let name: String
    public let description: String
    public let parameters: JSONValue

    public init(name: String, description: String, parameters: JSONValue) {
        self.name = name
        self.description = description
        self.parameters = parameters
    }
}

public struct ToolCall: Sendable, Codable, Equatable {
    public let id: String
    public let name: String
    public let arguments: JSONValue

    public init(id: String, name: String, arguments: JSONValue) {
        self.id = id
        self.name = name
        self.arguments = arguments
    }
}

public enum StopReason: String, Sendable, Codable, Equatable {
    case endTurn
    case toolUse
    case maxTokens
    case unknown
}

public struct ChatResponse: Sendable, Codable, Equatable {
    public let parts: [ChatMessage.Part]
    public let stopReason: StopReason

    public init(parts: [ChatMessage.Part], stopReason: StopReason = .endTurn) {
        self.parts = parts
        self.stopReason = stopReason
    }

    public var text: String {
        parts.compactMap {
            if case .text(let text) = $0 { return text }
            return nil
        }.joined()
    }
}

// MARK: - ChatMessage

public struct ChatMessage: Sendable, Codable, Equatable {
    public enum Role: String, Sendable, Codable {
        case system
        case user
        case assistant
        case tool
    }

    /// A single content part in a message.
    public enum Part: Sendable, Codable, Equatable {
        case text(String)
        /// JPEG-encoded image data; providers base64-encode this for transport.
        case image(jpegData: Data, mimeType: String)
        case toolUse(ToolCall)
        case toolResult(id: String, content: String, isError: Bool)

        // Codable conformance via a keyed container so round-trips are stable.
        private enum CodingKeys: String, CodingKey {
            case type
            case text
            case jpegData
            case mimeType
            case toolCall
            case id
            case content
            case isError
        }

        public init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            let type = try container.decode(String.self, forKey: .type)
            switch type {
            case "text":
                let text = try container.decode(String.self, forKey: .text)
                self = .text(text)
            case "image":
                let data = try container.decode(Data.self, forKey: .jpegData)
                let mime = try container.decode(String.self, forKey: .mimeType)
                self = .image(jpegData: data, mimeType: mime)
            case "toolUse":
                self = .toolUse(try container.decode(ToolCall.self, forKey: .toolCall))
            case "toolResult":
                self = .toolResult(
                    id: try container.decode(String.self, forKey: .id),
                    content: try container.decode(String.self, forKey: .content),
                    isError: try container.decode(Bool.self, forKey: .isError)
                )
            default:
                throw DecodingError.dataCorruptedError(forKey: .type, in: container,
                    debugDescription: "Unknown part type: \(type)")
            }
        }

        public func encode(to encoder: Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            switch self {
            case .text(let s):
                try container.encode("text", forKey: .type)
                try container.encode(s, forKey: .text)
            case .image(let data, let mime):
                try container.encode("image", forKey: .type)
                try container.encode(data, forKey: .jpegData)
                try container.encode(mime, forKey: .mimeType)
            case .toolUse(let call):
                try container.encode("toolUse", forKey: .type)
                try container.encode(call, forKey: .toolCall)
            case .toolResult(let id, let content, let isError):
                try container.encode("toolResult", forKey: .type)
                try container.encode(id, forKey: .id)
                try container.encode(content, forKey: .content)
                try container.encode(isError, forKey: .isError)
            }
        }
    }

    public let role: Role
    public let parts: [Part]

    public init(role: Role, parts: [Part]) {
        self.role = role
        self.parts = parts
    }

    /// Convenience: single text-only message.
    public init(role: Role, content: String) {
        self.role = role
        self.parts = [.text(content)]
    }

    /// Concatenated text content for display and logging; ignores image parts.
    public var text: String {
        parts.compactMap {
            if case .text(let s) = $0 { return s } else { return nil }
        }.joined(separator: " ")
    }
}

// MARK: - AIConfig

public struct AIConfig: Sendable, Equatable {
    public let model: String
    public let temperature: Double
    public let maxTokens: Int
    /// Optional system-role prefix. Routed provider-specifically:
    /// Anthropic uses a top-level "system" field; OpenAI prepends a system message.
    public let systemPrompt: String?

    public init(
        model: String,
        temperature: Double = 0.7,
        maxTokens: Int = 1024,
        systemPrompt: String? = nil
    ) {
        self.model = model
        self.temperature = temperature
        self.maxTokens = maxTokens
        self.systemPrompt = systemPrompt
    }
}

// MARK: - AIError

public enum AIError: Error, Sendable, Equatable {
    case invalidEndpoint
    case authenticationFailed
    case rateLimited
    case sendFailed(message: String)
    case decodingFailed(message: String)
}

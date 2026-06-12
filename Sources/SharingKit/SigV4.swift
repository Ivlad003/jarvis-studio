import CryptoKit
import Foundation

// MARK: - SigV4

/// Hand-rolled AWS Signature Version 4 implementation, scoped to S3-compatible
/// PUT object + presigned GET use cases.
///
/// Why hand-rolled: aws-sdk-swift adds ~30 MB to the binary, pulls dozens of
/// transitive deps, and its ergonomics around presigning custom endpoints
/// (R2, B2, MinIO) are awkward. Sig V4 itself is ~200 lines of well-specified
/// crypto and string-massaging — manageable in-tree.
///
/// References:
///   • https://docs.aws.amazon.com/general/latest/gr/sigv4_signing.html
///   • https://docs.aws.amazon.com/AmazonS3/latest/API/sigv4-streaming.html
public enum SigV4 {

    public struct Credentials: Sendable, Equatable {
        public let accessKeyId: String
        public let secretAccessKey: String

        public init(accessKeyId: String, secretAccessKey: String) {
            self.accessKeyId = accessKeyId
            self.secretAccessKey = secretAccessKey
        }
    }

    // MARK: - Helpers

    /// SHA-256 hex digest. Used for canonical-request hash + payload hash.
    public static func sha256Hex(_ data: Data) -> String {
        let digest = SHA256.hash(data: data)
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    public static func sha256Hex(_ string: String) -> String {
        sha256Hex(Data(string.utf8))
    }

    /// SHA-256 hex digest for a file, read in bounded chunks so large
    /// recordings don't need to be loaded into memory just to sign a PUT.
    public static func sha256Hex(fileURL: URL, chunkSize: Int = 1_048_576) throws -> String {
        let handle = try FileHandle(forReadingFrom: fileURL)
        defer { try? handle.close() }

        var hasher = SHA256()
        while true {
            let chunk = handle.readData(ofLength: chunkSize)
            if chunk.isEmpty { break }
            hasher.update(data: chunk)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    /// HMAC-SHA256.
    public static func hmacSHA256(_ data: Data, key: Data) -> Data {
        let mac = HMAC<SHA256>.authenticationCode(for: data, using: SymmetricKey(data: key))
        return Data(mac)
    }

    public static func hmacSHA256Hex(_ data: Data, key: Data) -> String {
        hmacSHA256(data, key: key).map { String(format: "%02x", $0) }.joined()
    }

    /// AWS-flavoured percent encoding: rules are stricter than URLComponents.
    /// All bytes outside the unreserved set RFC-3986 §2.3 are encoded.
    /// Slashes encoded depending on `encodeSlash`. Used for both canonical URI
    /// (slashes preserved) and canonical query strings (slashes encoded).
    public static func awsEncode(_ s: String, encodeSlash: Bool) -> String {
        var output = ""
        output.reserveCapacity(s.utf8.count)
        for byte in s.utf8 {
            let scalar = Unicode.Scalar(byte)
            let isUnreserved = (byte >= 0x41 && byte <= 0x5A)        // A-Z
                || (byte >= 0x61 && byte <= 0x7A)                    // a-z
                || (byte >= 0x30 && byte <= 0x39)                    // 0-9
                || byte == 0x2D                                       // -
                || byte == 0x5F                                       // _
                || byte == 0x2E                                       // .
                || byte == 0x7E                                       // ~
            if isUnreserved {
                output.unicodeScalars.append(scalar)
            } else if byte == 0x2F && !encodeSlash {                 // /
                output.unicodeScalars.append(scalar)
            } else {
                output += String(format: "%%%02X", byte)
            }
        }
        return output
    }

    // MARK: - Date / time helpers

    /// `YYYYMMDDTHHMMSSZ` (ISO basic UTC). Used in `x-amz-date`.
    public static func amzDateTime(_ date: Date) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: "UTC")
        f.dateFormat = "yyyyMMdd'T'HHmmss'Z'"
        return f.string(from: date)
    }

    /// `YYYYMMDD`. Used in scope.
    public static func amzDateOnly(_ date: Date) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: "UTC")
        f.dateFormat = "yyyyMMdd"
        return f.string(from: date)
    }

    // MARK: - Signing key derivation

    /// Derive the per-request signing key. AWS-spec exact:
    /// kDate = HMAC("AWS4" + secret, date)
    /// kRegion = HMAC(kDate, region)
    /// kService = HMAC(kRegion, service)
    /// kSigning = HMAC(kService, "aws4_request")
    public static func signingKey(
        secret: String,
        date: String,
        region: String,
        service: String
    ) -> Data {
        let kDate = hmacSHA256(Data(date.utf8), key: Data(("AWS4" + secret).utf8))
        let kRegion = hmacSHA256(Data(region.utf8), key: kDate)
        let kService = hmacSHA256(Data(service.utf8), key: kRegion)
        let kSigning = hmacSHA256(Data("aws4_request".utf8), key: kService)
        return kSigning
    }

    // MARK: - Canonical request

    public struct CanonicalRequest: Sendable, Equatable {
        public let method: String
        public let canonicalURI: String
        public let canonicalQuery: String
        public let canonicalHeaders: String
        public let signedHeaders: String
        public let payloadHash: String

        public var stringValue: String {
            "\(method)\n\(canonicalURI)\n\(canonicalQuery)\n\(canonicalHeaders)\n\(signedHeaders)\n\(payloadHash)"
        }
    }

    /// Build the canonical request per Sig V4 spec.
    /// `headers` keys are case-insensitive — they're lowercased + sorted internally.
    public static func canonicalize(
        method: String,
        path: String,
        query: [(String, String)],
        headers: [String: String],
        payloadHash: String
    ) -> CanonicalRequest {
        let canonicalURI = path.isEmpty ? "/" : awsEncode(path, encodeSlash: false)

        // Sort query alphabetically by AWS-encoded key; AWS-encode key+value.
        // Break the chain up: the type-checker times out trying to infer through
        // the tuple-with-string-interpolation path in one pass.
        let encodedPairs: [(String, String)] = query.map { pair in
            (awsEncode(pair.0, encodeSlash: true), awsEncode(pair.1, encodeSlash: true))
        }
        let sortedPairs = encodedPairs.sorted { lhs, rhs in
            lhs.0 == rhs.0 ? lhs.1 < rhs.1 : lhs.0 < rhs.0
        }
        let joined = sortedPairs.map { pair -> String in
            pair.0 + "=" + pair.1
        }
        let canonicalQuery = joined.joined(separator: "&")

        // Lowercase header keys, trim and compress values, join with newlines,
        // append trailing newline. SigV4 canonical headers require sequential
        // spaces/tabs/newlines inside values to collapse to one space.
        let lowered = headers.map { (k, v) -> (String, String) in
            (k.lowercased(), canonicalHeaderValue(v))
        }.sorted { $0.0 < $1.0 }

        let canonicalHeaders = lowered
            .map { "\($0.0):\($0.1)" }
            .joined(separator: "\n") + "\n"

        let signedHeaders = lowered.map { $0.0 }.joined(separator: ";")

        return CanonicalRequest(
            method: method.uppercased(),
            canonicalURI: canonicalURI,
            canonicalQuery: canonicalQuery,
            canonicalHeaders: canonicalHeaders,
            signedHeaders: signedHeaders,
            payloadHash: payloadHash
        )
    }

    private static func canonicalHeaderValue(_ value: String) -> String {
        value
            .split(whereSeparator: { $0.isWhitespace })
            .joined(separator: " ")
    }

    // MARK: - String-to-sign + signature

    public static func stringToSign(
        date: Date,
        region: String,
        service: String,
        canonicalRequest: CanonicalRequest
    ) -> String {
        let amzDate = amzDateTime(date)
        let scope = "\(amzDateOnly(date))/\(region)/\(service)/aws4_request"
        let crHash = sha256Hex(canonicalRequest.stringValue)
        return "AWS4-HMAC-SHA256\n\(amzDate)\n\(scope)\n\(crHash)"
    }

    public static func signature(
        stringToSign: String,
        secret: String,
        date: Date,
        region: String,
        service: String
    ) -> String {
        let key = signingKey(
            secret: secret,
            date: amzDateOnly(date),
            region: region,
            service: service
        )
        return hmacSHA256Hex(Data(stringToSign.utf8), key: key)
    }

    // MARK: - Signed-payload constants

    /// SHA-256 of an empty body. Used as `x-amz-content-sha256` for presigned URLs.
    public static let emptyPayloadHash = "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855"

    /// Marker payload hash for presigned URLs: signed using "UNSIGNED-PAYLOAD".
    public static let unsignedPayload = "UNSIGNED-PAYLOAD"
}

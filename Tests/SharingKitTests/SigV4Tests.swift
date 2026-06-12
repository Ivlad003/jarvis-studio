import Foundation
import Testing
@testable import SharingKit

// MARK: - SHA + HMAC primitives

@Suite("SigV4 hash primitives")
struct SigV4HashTests {

    @Test("SHA-256 of empty string matches AWS reference")
    func emptyPayloadHash() {
        // Published constant: `e3b0c44…`. We embed it as `emptyPayloadHash`,
        // but the function should also derive it from "" directly.
        #expect(SigV4.sha256Hex("") == SigV4.emptyPayloadHash)
    }

    @Test("HMAC-SHA256 hex matches reference vector")
    func hmacReference() {
        // Reference: HMAC_SHA256("Jefe", "what do ya want for nothing?")
        // expected = 5bdcc146bf60754e6a042426089575c75a003f089d2739839dec58b964ec3843
        let mac = SigV4.hmacSHA256Hex(
            Data("what do ya want for nothing?".utf8),
            key: Data("Jefe".utf8)
        )
        #expect(mac == "5bdcc146bf60754e6a042426089575c75a003f089d2739839dec58b964ec3843")
    }
}

// MARK: - AWS-encoding

@Suite("SigV4 awsEncode")
struct SigV4EncodeTests {

    @Test("Unreserved characters pass through unchanged")
    func unreservedPassthrough() {
        let s = "ABCabc012-_.~"
        #expect(SigV4.awsEncode(s, encodeSlash: false) == s)
        #expect(SigV4.awsEncode(s, encodeSlash: true) == s)
    }

    @Test("Slashes preserved when encodeSlash = false")
    func slashPreserved() {
        #expect(SigV4.awsEncode("a/b/c", encodeSlash: false) == "a/b/c")
    }

    @Test("Slashes percent-encoded when encodeSlash = true")
    func slashEncoded() {
        #expect(SigV4.awsEncode("a/b/c", encodeSlash: true) == "a%2Fb%2Fc")
    }

    @Test("Spaces percent-encoded as %20")
    func spaceEncoded() {
        #expect(SigV4.awsEncode("hello world", encodeSlash: false) == "hello%20world")
    }

    @Test("Plus sign percent-encoded (not as space)")
    func plusEncoded() {
        // Plus is NOT in the unreserved set; AWS-encode it as %2B (don't treat as space).
        #expect(SigV4.awsEncode("a+b", encodeSlash: false) == "a%2Bb")
    }
}

// MARK: - Signing key derivation (AWS reference vector)

@Suite("SigV4 signingKey")
struct SigV4SigningKeyTests {

    @Test("AWS reference signing key matches")
    func referenceVector() {
        // AWS Sig V4 docs publish these values for iam.amazonaws.com:
        let key = SigV4.signingKey(
            secret: "wJalrXUtnFEMI/K7MDENG+bPxRfiCYEXAMPLEKEY",
            date: "20150830",
            region: "us-east-1",
            service: "iam"
        )
        let hex = key.map { String(format: "%02x", $0) }.joined()
        #expect(hex == "c4afb1cc5771d871763a393e44b703571b55cc28424d1a5e86da6ed3c154a4b9")
    }
}

// MARK: - Date helpers

@Suite("SigV4 date formatting")
struct SigV4DateTests {

    @Test("Date-time produces YYYYMMDDTHHMMSSZ")
    func dateTimeFormat() {
        // 2015-08-30 12:36:00 UTC
        let date = Date(timeIntervalSince1970: 1_440_938_160)
        #expect(SigV4.amzDateTime(date) == "20150830T123600Z")
    }

    @Test("Date-only produces YYYYMMDD")
    func dateOnlyFormat() {
        let date = Date(timeIntervalSince1970: 1_440_938_160)
        #expect(SigV4.amzDateOnly(date) == "20150830")
    }
}

// MARK: - Canonical request shape

@Suite("SigV4 canonicalize")
struct SigV4CanonicalTests {

    @Test("Empty path becomes /")
    func emptyPath() {
        let cr = SigV4.canonicalize(
            method: "PUT",
            path: "",
            query: [],
            headers: ["host": "example.com"],
            payloadHash: SigV4.emptyPayloadHash
        )
        #expect(cr.canonicalURI == "/")
    }

    @Test("Headers lowercased + sorted in canonical output")
    func headerSorting() {
        let cr = SigV4.canonicalize(
            method: "PUT",
            path: "/key",
            query: [],
            headers: [
                "X-Amz-Date": "20150830T123600Z",
                "Host": "example.com",
                "Content-Type": "text/plain",
            ],
            payloadHash: SigV4.emptyPayloadHash
        )
        #expect(cr.canonicalHeaders == "content-type:text/plain\nhost:example.com\nx-amz-date:20150830T123600Z\n")
        #expect(cr.signedHeaders == "content-type;host;x-amz-date")
    }

    @Test("Header values trim and compress sequential whitespace")
    func headerWhitespaceCompression() {
        let cr = SigV4.canonicalize(
            method: "PUT",
            path: "/key",
            query: [],
            headers: ["X-Test": "  alpha  beta\tgamma \n delta  "],
            payloadHash: SigV4.emptyPayloadHash
        )

        #expect(cr.canonicalHeaders == "x-test:alpha beta gamma delta\n")
    }

    @Test("Query params sorted alphabetically by encoded key")
    func querySorting() {
        let cr = SigV4.canonicalize(
            method: "GET",
            path: "/",
            query: [("Z", "1"), ("A", "2"), ("M", "3")],
            headers: ["host": "example.com"],
            payloadHash: SigV4.unsignedPayload
        )
        #expect(cr.canonicalQuery == "A=2&M=3&Z=1")
    }
}

// MARK: - Presigned URL shape

@Suite("S3Client presignedGetURL")
struct S3ClientPresignTests {

    private func makeClient() -> S3Client {
        S3Client(
            endpoint: URL(string: "https://s3.amazonaws.com")!,
            region: "us-east-1",
            bucket: "examplebucket",
            credentials: SigV4.Credentials(
                accessKeyId: "AKIAIOSFODNN7EXAMPLE",
                secretAccessKey: "wJalrXUtnFEMI/K7MDENG+bPxRfiCYEXAMPLEKEY"
            )
        )
    }

    @Test("Presigned URL contains the expected query parameters")
    func queryParams() throws {
        let client = makeClient()
        let url = try client.presignedGetURL(
            key: "test.txt",
            expirySeconds: 3600,
            now: Date(timeIntervalSince1970: 1_440_938_160)
        )
        let s = url.absoluteString
        #expect(s.contains("X-Amz-Algorithm=AWS4-HMAC-SHA256"))
        #expect(s.contains("X-Amz-Credential=AKIAIOSFODNN7EXAMPLE"))
        #expect(s.contains("X-Amz-Date=20150830T123600Z"))
        #expect(s.contains("X-Amz-Expires=3600"))
        #expect(s.contains("X-Amz-SignedHeaders=host"))
        #expect(s.contains("X-Amz-Signature="))
    }

    @Test("Object URL percent-encodes path with the same AWS rules used for signing")
    func objectURLUsesAWSPathEncoding() {
        let client = makeClient()
        let url = client.objectURL(key: "folder/a+b(1);=.txt")
        let components = URLComponents(url: url, resolvingAgainstBaseURL: false)!

        #expect(components.percentEncodedPath == "/examplebucket/folder/a%2Bb%281%29%3B%3D.txt")
    }

    @Test("Presigned URL wire path is AWS-encoded for sub-delimiter keys")
    func presignedURLUsesAWSPathEncoding() throws {
        let client = makeClient()
        let url = try client.presignedGetURL(
            key: "folder/a+b(1);=.txt",
            expirySeconds: 3600,
            now: Date(timeIntervalSince1970: 1_440_938_160)
        )
        let components = URLComponents(url: url, resolvingAgainstBaseURL: false)!

        #expect(components.percentEncodedPath == "/examplebucket/folder/a%2Bb%281%29%3B%3D.txt")
    }

    @Test("Expiry clamped to 7 days max")
    func expiryClamp() throws {
        let client = makeClient()
        let url = try client.presignedGetURL(
            key: "x",
            expirySeconds: 999_999_999,
            now: Date(timeIntervalSince1970: 1_440_938_160)
        )
        #expect(url.absoluteString.contains("X-Amz-Expires=604800"))
    }
}

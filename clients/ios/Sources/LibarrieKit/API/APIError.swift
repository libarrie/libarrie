import Foundation

/// A failed API call. `code` is the stable error code from the server
/// (`page_number_conflict`, `processing_limit_reached`, ...) or a local one
/// (`network`, `unauthenticated`, `invalid_response`).
public struct APIError: Error, Sendable, Equatable, LocalizedError {
    public var status: Int
    public var code: String
    public var message: String
    public var retryAfter: Int?
    public var details: [String: String]

    public init(status: Int, code: String, message: String, retryAfter: Int? = nil, details: [String: String] = [:]) {
        self.status = status
        self.code = code
        self.message = message
        self.retryAfter = retryAfter
        self.details = details
    }

    public var errorDescription: String? { message }

    /// No response arrived; whether the server acted is unknown.
    public var isNetwork: Bool { code == "network" }

    /// Worth retrying later without user action.
    public var isTransient: Bool {
        isNetwork || status == 429 || status == 502 || status == 503 || status == 504 || status == 500
    }

    public static func network(_ error: Error) -> APIError {
        APIError(status: 0, code: "network", message: "The connection failed. Check your network and try again.")
    }

    public static let unauthenticated = APIError(
        status: 401, code: "unauthenticated", message: "Your sign-in expired. Sign in again to continue.")

    static func decode(status: Int, data: Data, retryAfter: Int?) -> APIError {
        struct Body: Decodable {
            struct Inner: Decodable {
                var code: String
                var message: String
                var details: [String: Scalar]?
            }
            var error: Inner
        }
        guard let body = try? JSON.decoder.decode(Body.self, from: data) else {
            return APIError(status: status, code: "http_\(status)", message: "The server returned an error (\(status)).", retryAfter: retryAfter)
        }
        var details: [String: String] = [:]
        for (key, value) in body.error.details ?? [:] { details[key] = value.text }
        return APIError(status: status, code: body.error.code, message: body.error.message, retryAfter: retryAfter, details: details)
    }
}

/// Error detail values are flattened to text; nested values are dropped.
struct Scalar: Decodable {
    var text: String
    init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if let s = try? c.decode(String.self) { text = s }
        else if let i = try? c.decode(Int.self) { text = String(i) }
        else if let b = try? c.decode(Bool.self) { text = String(b) }
        else { text = "" }
    }
}

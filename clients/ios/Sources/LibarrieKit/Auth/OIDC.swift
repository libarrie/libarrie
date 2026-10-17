import CryptoKit
import Foundation

/// Base64url without padding (RFC 7636).
func base64url(_ data: Data) -> String {
    data.base64EncodedString()
        .replacingOccurrences(of: "+", with: "-")
        .replacingOccurrences(of: "/", with: "_")
        .replacingOccurrences(of: "=", with: "")
}

func randomToken(bytes: Int = 32) -> String {
    var generator = SystemRandomNumberGenerator()
    return base64url(Data((0..<bytes).map { _ in UInt8.random(in: .min ... .max, using: &generator) }))
}

/// One authorization attempt: PKCE verifier, state and nonce, kept only in
/// memory until the callback returns (section 6: Authorization Code + PKCE
/// through the system browser).
public struct AuthorizationRequest: Sendable, Equatable {
    public let url: URL
    public let state: String
    public let nonce: String
    public let verifier: String
    public let redirectURI: String
    public let callbackScheme: String

    /// - Parameter reauthenticate: force a fresh sign-in (`prompt=login`,
    ///   `max_age=0`) before account deletion or permanent purge.
    public init(configuration: OIDCConfiguration, reauthenticate: Bool = false) {
        verifier = randomToken(bytes: 48)
        state = randomToken(bytes: 24)
        nonce = randomToken(bytes: 24)
        redirectURI = configuration.redirectUri
        callbackScheme = URL(string: configuration.redirectUri)?.scheme ?? "libarrie"
        let challenge = base64url(Data(SHA256.hash(data: Data(verifier.utf8))))
        var components = URLComponents(url: configuration.authorizationEndpoint, resolvingAgainstBaseURL: false)!
        var items = components.queryItems ?? []
        items += [
            URLQueryItem(name: "response_type", value: "code"),
            URLQueryItem(name: "client_id", value: configuration.clientId),
            URLQueryItem(name: "redirect_uri", value: configuration.redirectUri),
            URLQueryItem(name: "scope", value: configuration.scopes.joined(separator: " ")),
            URLQueryItem(name: "state", value: state),
            URLQueryItem(name: "nonce", value: nonce),
            URLQueryItem(name: "code_challenge", value: challenge),
            URLQueryItem(name: "code_challenge_method", value: "S256"),
        ]
        if reauthenticate {
            items += [URLQueryItem(name: "prompt", value: "login"), URLQueryItem(name: "max_age", value: "0")]
        }
        components.queryItems = items
        url = components.url!
    }

    /// Extract the code from the redirect, checking state and errors.
    public func code(from callback: URL) throws -> String {
        guard callback.absoluteString.hasPrefix(redirectURI) else { throw SignInError.unexpectedRedirect }
        let items = URLComponents(url: callback, resolvingAgainstBaseURL: false)?.queryItems ?? []
        let value = { (name: String) in items.first { $0.name == name }?.value }
        if let error = value("error") {
            throw error == "access_denied" ? SignInError.cancelled : SignInError.provider(error)
        }
        guard value("state") == state else { throw SignInError.stateMismatch }
        guard let code = value("code"), !code.isEmpty else { throw SignInError.missingCode }
        return code
    }
}

public enum SignInError: Error, Equatable, LocalizedError {
    case cancelled
    case notConfigured
    case unexpectedRedirect
    case stateMismatch
    case missingCode
    case provider(String)
    case tokenEndpoint(String)
    case invalidIDToken(String)

    public var errorDescription: String? {
        switch self {
        case .cancelled: "Sign-in was cancelled."
        case .notConfigured: "This server does not support sign-in from the app yet."
        case .unexpectedRedirect, .stateMismatch, .missingCode: "Sign-in could not be completed. Please try again."
        case .provider(let code): "The sign-in service reported an error (\(code))."
        case .tokenEndpoint(let reason): "Sign-in could not be completed (\(reason))."
        case .invalidIDToken(let reason): "The sign-in response could not be verified (\(reason))."
        }
    }
}

/// Tokens from the token endpoint.
public struct TokenResponse: Decodable, Sendable {
    public var accessToken: String
    public var idToken: String?
    public var refreshToken: String?
    public var expiresIn: Int?
}

/// The identity facts the app keeps from the ID token.
public struct IDTokenClaims: Codable, Sendable, Equatable {
    public var issuer: String
    public var subject: String
    public var name: String?
    public var authTime: Int?
}

/// Token endpoint calls (public client: no secret).
public struct TokenClient: Sendable {
    let configuration: OIDCConfiguration
    let transport: HTTPTransport
    var now: @Sendable () -> Date = { Date() }

    public init(configuration: OIDCConfiguration, transport: HTTPTransport) {
        self.configuration = configuration
        self.transport = transport
    }

    public func exchange(code: String, request: AuthorizationRequest) async throws -> Credentials {
        let response = try await post([
            "grant_type": "authorization_code",
            "code": code,
            "code_verifier": request.verifier,
            "client_id": configuration.clientId,
            "redirect_uri": request.redirectURI,
        ])
        guard let idToken = response.idToken else { throw SignInError.invalidIDToken("missing ID token") }
        let claims = try validate(idToken: idToken, nonce: request.nonce)
        return credentials(from: response, claims: claims, previousRefresh: nil)
    }

    public func refresh(_ credentials: Credentials) async throws -> Credentials {
        guard let refreshToken = credentials.refreshToken else { throw APIError.unauthenticated }
        let response = try await post([
            "grant_type": "refresh_token",
            "refresh_token": refreshToken,
            "client_id": configuration.clientId,
        ])
        // Keep the original identity and sign-in time; providers may omit
        // the ID token on refresh.
        var claims = credentials.claims
        if let idToken = response.idToken, let refreshed = try? validate(idToken: idToken, nonce: nil),
           refreshed.subject == claims.subject {
            claims.name = refreshed.name ?? claims.name
        }
        return self.credentials(from: response, claims: claims, previousRefresh: refreshToken)
    }

    private func credentials(from response: TokenResponse, claims: IDTokenClaims, previousRefresh: String?) -> Credentials {
        Credentials(
            accessToken: response.accessToken,
            refreshToken: response.refreshToken ?? previousRefresh,
            expiresAt: now().addingTimeInterval(TimeInterval(response.expiresIn ?? 300)),
            claims: claims)
    }

    private func post(_ form: [String: String]) async throws -> TokenResponse {
        var request = URLRequest(url: configuration.tokenEndpoint)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        var components = URLComponents()
        components.queryItems = form.sorted { $0.key < $1.key }.map { URLQueryItem(name: $0.key, value: $0.value) }
        request.httpBody = components.percentEncodedQuery?
            .replacingOccurrences(of: "+", with: "%2B")
            .data(using: .utf8)
        let (data, response): (Data, HTTPURLResponse)
        do {
            (data, response) = try await transport.send(request)
        } catch {
            throw APIError.network(error)
        }
        guard response.statusCode == 200 else {
            struct Failure: Decodable { var error: String }
            let reason = (try? JSON.decoder.decode(Failure.self, from: data))?.error ?? "HTTP \(response.statusCode)"
            if reason == "invalid_grant" { throw APIError.unauthenticated }
            throw SignInError.tokenEndpoint(reason)
        }
        do {
            return try JSON.decoder.decode(TokenResponse.self, from: data)
        } catch {
            throw SignInError.tokenEndpoint("unreadable response")
        }
    }

    /// Checks issuer, audience, expiry and nonce. The ID token arrives
    /// directly from the token endpoint over TLS in the code flow, which
    /// OIDC Core 3.1.3.7 accepts in place of client-side signature checks;
    /// the API independently verifies every access token's signature.
    func validate(idToken: String, nonce: String?) throws -> IDTokenClaims {
        let parts = idToken.split(separator: ".")
        guard parts.count == 3, let payload = Data(base64urlEncoded: String(parts[1])) else {
            throw SignInError.invalidIDToken("malformed")
        }
        struct Payload: Decodable {
            var iss: String
            var sub: String
            var aud: Audience
            var exp: Int
            var nonce: String?
            var name: String?
            var authTime: Int?
        }
        guard let claims = try? JSON.decoder.decode(Payload.self, from: payload) else {
            throw SignInError.invalidIDToken("unreadable claims")
        }
        guard claims.iss == configuration.issuer else { throw SignInError.invalidIDToken("issuer") }
        guard claims.aud.values.contains(configuration.clientId) else { throw SignInError.invalidIDToken("audience") }
        guard Double(claims.exp) > now().timeIntervalSince1970 - 60 else { throw SignInError.invalidIDToken("expired") }
        if let nonce, claims.nonce != nonce { throw SignInError.invalidIDToken("nonce") }
        return IDTokenClaims(issuer: claims.iss, subject: claims.sub, name: claims.name, authTime: claims.authTime)
    }
}

/// `aud` may be a string or an array.
struct Audience: Decodable {
    var values: [String]
    init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if let one = try? c.decode(String.self) { values = [one] } else { values = try c.decode([String].self) }
    }
}

extension Data {
    init?(base64urlEncoded text: String) {
        var base64 = text.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        while base64.count % 4 != 0 { base64 += "=" }
        self.init(base64Encoded: base64)
    }
}

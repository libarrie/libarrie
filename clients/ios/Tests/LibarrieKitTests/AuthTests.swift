import Foundation
import Testing
@testable import LibarrieKit

let oidc = OIDCConfiguration(
    issuer: "http://localhost:8080/dev-issuer",
    authorizationEndpoint: URL(string: "http://localhost:8080/dev-issuer/authorize")!,
    tokenEndpoint: URL(string: "http://localhost:8080/dev-issuer/token")!,
    clientId: "libarrie-native",
    redirectUri: "libarrie://oauth/callback",
    scopes: ["openid", "profile", "offline_access"])

func jwt(_ claims: [String: Any]) -> String {
    func encode(_ object: Any) -> String { base64url(json(object)) }
    return encode(["alg": "HS256"]) + "." + encode(claims) + ".signature"
}

@Suite struct AuthTests {
    @Test func authorizationURLUsesPKCE() throws {
        let request = AuthorizationRequest(configuration: oidc)
        let items = URLComponents(url: request.url, resolvingAgainstBaseURL: false)!.queryItems!
        let value = { (name: String) in items.first { $0.name == name }?.value }
        #expect(value("response_type") == "code")
        #expect(value("code_challenge_method") == "S256")
        #expect(value("code_challenge") != request.verifier)
        #expect(value("state") == request.state)
        #expect(value("prompt") == nil)
        #expect(request.callbackScheme == "libarrie")
        let reauth = AuthorizationRequest(configuration: oidc, reauthenticate: true)
        let reauthItems = URLComponents(url: reauth.url, resolvingAgainstBaseURL: false)!.queryItems!
        #expect(reauthItems.contains(URLQueryItem(name: "prompt", value: "login")))
        #expect(reauthItems.contains(URLQueryItem(name: "max_age", value: "0")))
    }

    @Test func callbackChecksStateAndErrors() throws {
        let request = AuthorizationRequest(configuration: oidc)
        let good = URL(string: "libarrie://oauth/callback?code=abc&state=\(request.state)")!
        #expect(try request.code(from: good) == "abc")
        #expect(throws: SignInError.stateMismatch) {
            try request.code(from: URL(string: "libarrie://oauth/callback?code=abc&state=other")!)
        }
        #expect(throws: SignInError.cancelled) {
            try request.code(from: URL(string: "libarrie://oauth/callback?error=access_denied")!)
        }
        #expect(throws: SignInError.unexpectedRedirect) {
            try request.code(from: URL(string: "evil://oauth/callback?code=abc&state=\(request.state)")!)
        }
    }

    @Test func exchangeValidatesTheIDToken() async throws {
        let request = AuthorizationRequest(configuration: oidc)
        let now = Date().timeIntervalSince1970
        var claims: [String: Any] = [
            "iss": oidc.issuer, "aud": "libarrie-native", "sub": "user-1", "name": "Ada",
            "nonce": request.nonce, "auth_time": Int(now), "exp": Int(now) + 600,
        ]
        let transport = ScriptedTransport { request in
            let form = String(data: request.httpBody!, encoding: .utf8)!
            #expect(form.contains("grant_type=authorization_code"))
            #expect(form.contains("code_verifier="))
            return (200, json(["access_token": "access", "id_token": jwt(claims), "refresh_token": "refresh", "expires_in": 600]))
        }
        let client = TokenClient(configuration: oidc, transport: transport)
        let credentials = try await client.exchange(code: "code", request: request)
        #expect(credentials.accessToken == "access")
        #expect(credentials.refreshToken == "refresh")
        #expect(credentials.claims.subject == "user-1")
        #expect(credentials.isRecentSignIn())

        claims["nonce"] = "replayed"
        await #expect(throws: SignInError.invalidIDToken("nonce")) { try await client.exchange(code: "code", request: request) }
        claims["nonce"] = request.nonce
        claims["aud"] = "someone-else"
        await #expect(throws: SignInError.invalidIDToken("audience")) { try await client.exchange(code: "code", request: request) }
    }

    @Test func sessionRefreshesOnceForConcurrentCallers() async throws {
        let clock = Clock()
        let refreshes = ScriptedTransport { request in
            let form = String(data: request.httpBody!, encoding: .utf8)!
            #expect(form.contains("grant_type=refresh_token"))
            Thread.sleep(forTimeInterval: 0.05)
            return (200, json(["access_token": "fresh", "refresh_token": "rotated", "expires_in": 600]))
        }
        let credentials = Credentials(
            accessToken: "stale", refreshToken: "refresh", expiresAt: clock.now.addingTimeInterval(30),
            claims: IDTokenClaims(issuer: oidc.issuer, subject: "u", name: nil, authTime: 1))
        let store = MemorySessionStore(StoredSession(
            serverURL: URL(string: "http://localhost:8080")!,
            configuration: ClientConfiguration(oidc: oidc, uploads: UploadPolicy(integrity: "sha256", maxBytes: 1, contentTypes: [])),
            credentials: credentials, accountId: "a", displayName: nil))
        let manager = SessionManager(store: store, transport: refreshes, now: { clock.now })
        async let a = manager.accessToken()
        async let b = manager.accessToken()
        let tokens = try await [a, b]
        #expect(tokens == ["fresh", "fresh"])
        #expect(refreshes.sent.count == 1)
        // The rotated refresh token and the original sign-in time persist.
        let saved = try #require(try store.load())
        #expect(saved.credentials.refreshToken == "rotated")
        #expect(saved.credentials.claims.authTime == 1)
    }

    @Test func apiRetriesOnceAfterRefreshingOn401() async throws {
        final class Tokens: AccessTokenProvider, @unchecked Sendable {
            var refreshed = 0
            func accessToken() async throws -> String { "old" }
            func refreshAfterRejection(of token: String) async throws -> String { refreshed += 1; return "new" }
        }
        let tokens = Tokens()
        let transport = ScriptedTransport { request in
            let auth = request.value(forHTTPHeaderField: "Authorization")
            #expect(request.value(forHTTPHeaderField: "Cookie") == nil)
            return auth == "Bearer new" ? (200, try fixture("me").body) : (401, errorBody("authentication_required"))
        }
        let api = APIClient(baseURL: URL(string: "http://localhost:8080")!, transport: transport, tokens: tokens)
        let me = try await api.me()
        #expect(me.account.status == "active")
        #expect(tokens.refreshed == 1)
        #expect(transport.sent.count == 2)
    }
}

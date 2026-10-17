import Foundation

/// Owns the signed-in session: hands out access tokens, refreshes them a
/// minute before expiry or after a 401 (one refresh at a time), and persists
/// rotated refresh tokens.
public actor SessionManager: AccessTokenProvider {
    private let store: SessionStore
    private let transport: HTTPTransport
    private var session: StoredSession?
    private var refreshing: Task<Credentials, Error>?
    private let now: @Sendable () -> Date

    public init(store: SessionStore, transport: HTTPTransport, now: @escaping @Sendable () -> Date = { Date() }) {
        self.store = store
        self.transport = transport
        self.now = now
        self.session = try? store.load()
    }

    public var current: StoredSession? { session }

    public func begin(_ session: StoredSession) throws {
        try store.save(session)
        self.session = session
    }

    public func bind(accountId: String, displayName: String) throws {
        guard var session else { return }
        session.accountId = accountId
        session.displayName = displayName
        try store.save(session)
        self.session = session
    }

    /// Replace credentials after a fresh (re-)authentication.
    public func replaceCredentials(_ credentials: Credentials) throws {
        guard var session else { return }
        session.credentials = credentials
        try store.save(session)
        self.session = session
    }

    public func signOut() throws {
        refreshing?.cancel()
        refreshing = nil
        session = nil
        try store.clear()
    }

    public func accessToken() async throws -> String {
        guard let session else { throw APIError.unauthenticated }
        if session.credentials.expiresAt.timeIntervalSince(now()) > 60 {
            return session.credentials.accessToken
        }
        return try await refresh().accessToken
    }

    public func refreshAfterRejection(of token: String) async throws -> String {
        guard let session else { throw APIError.unauthenticated }
        // Another caller already refreshed past the rejected token.
        if session.credentials.accessToken != token { return session.credentials.accessToken }
        return try await refresh().accessToken
    }

    private func refresh() async throws -> Credentials {
        if let refreshing { return try await refreshing.value }
        guard let session, let oidc = session.configuration.oidc else { throw APIError.unauthenticated }
        let client = TokenClient(configuration: oidc, transport: transport)
        let previous = session.credentials
        let task = Task { try await client.refresh(previous) }
        refreshing = task
        defer { refreshing = nil }
        do {
            let fresh = try await task.value
            // Signed out (or switched) while refreshing: drop the result.
            guard self.session?.credentials == previous else { throw APIError.unauthenticated }
            try replaceCredentials(fresh)
            return fresh
        } catch let error as APIError where error.isNetwork {
            throw error
        } catch {
            throw APIError.unauthenticated
        }
    }
}

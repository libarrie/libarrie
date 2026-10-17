import Foundation
import Security

/// What the app keeps for a signed-in user. Stored only in the Keychain,
/// device-only, so device backups and transfers never carry tokens.
public struct Credentials: Codable, Sendable, Equatable {
    public var accessToken: String
    public var refreshToken: String?
    public var expiresAt: Date
    public var claims: IDTokenClaims

    /// Sign-in within the last five minutes, as required before account
    /// deletion and permanent purge (the server enforces this too).
    public func isRecentSignIn(now: Date = Date()) -> Bool {
        guard let authTime = claims.authTime else { return false }
        return now.timeIntervalSince1970 - Double(authTime) <= 300
    }
}

/// One signed-in session: the server and the credentials for it.
public struct StoredSession: Codable, Sendable, Equatable {
    public var serverURL: URL
    public var configuration: ClientConfiguration
    public var credentials: Credentials
    /// Filled after the first `/v1/me`; binds local captures to the account.
    public var accountId: String?
    public var displayName: String?

    public init(serverURL: URL, configuration: ClientConfiguration, credentials: Credentials, accountId: String?, displayName: String?) {
        self.serverURL = serverURL
        self.configuration = configuration
        self.credentials = credentials
        self.accountId = accountId
        self.displayName = displayName
    }
}

public protocol SessionStore: Sendable {
    func load() throws -> StoredSession?
    func save(_ session: StoredSession) throws
    func clear() throws
}

/// Keychain storage. `AfterFirstUnlockThisDeviceOnly` lets background
/// uploads refresh tokens while the device is locked, and keeps tokens out
/// of backups and device transfers.
public struct KeychainSessionStore: SessionStore {
    let service: String
    let account = "session"

    public init(service: String = "app.libarrie.session") { self.service = service }

    private var query: [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: service,
         kSecAttrAccount as String: account]
    }

    public func load() throws -> StoredSession? {
        var query = self.query
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = item as? Data else { throw KeychainError(status: status) }
        return try JSONDecoder().decode(StoredSession.self, from: data)
    }

    public func save(_ session: StoredSession) throws {
        let data = try JSONEncoder().encode(session)
        let attributes: [String: Any] = [
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
        ]
        let status = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        if status == errSecItemNotFound {
            let added = SecItemAdd(query.merging(attributes) { $1 } as CFDictionary, nil)
            guard added == errSecSuccess else { throw KeychainError(status: added) }
        } else if status != errSecSuccess {
            throw KeychainError(status: status)
        }
    }

    public func clear() throws {
        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw KeychainError(status: status) }
    }
}

public struct KeychainError: Error, Equatable { public var status: OSStatus }

/// For tests and previews.
public final class MemorySessionStore: SessionStore, @unchecked Sendable {
    private let lock = NSLock()
    private var session: StoredSession?
    public init(_ session: StoredSession? = nil) { self.session = session }
    public func load() throws -> StoredSession? { lock.withLock { session } }
    public func save(_ session: StoredSession) throws { lock.withLock { self.session = session } }
    public func clear() throws { lock.withLock { session = nil } }
}

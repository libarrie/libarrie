import Foundation
import LibarrieKit
import Observation
import SwiftUI

/// User preferences (UserDefaults; nothing sensitive).
@MainActor @Observable public final class AppSettings {
    private let defaults: UserDefaults

    public var serverAddress: String { didSet { defaults.set(serverAddress, forKey: "serverAddress") } }
    public var theme: ThemePreference { didSet { defaults.set(theme.rawValue, forKey: "theme") } }
    /// Keep GPS location in uploaded photos (off by default, section 6).
    public var keepLocation: Bool { didSet { defaults.set(keepLocation, forKey: "keepLocation") } }
    /// Include photos not yet backed up by Libarrie in device backups.
    public var backUpPendingCaptures: Bool { didSet { defaults.set(backUpPendingCaptures, forKey: "backUpPendingCaptures") } }

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        serverAddress = defaults.string(forKey: "serverAddress") ?? "http://localhost:8080"
        theme = ThemePreference(rawValue: defaults.string(forKey: "theme") ?? "") ?? .system
        keepLocation = defaults.bool(forKey: "keepLocation")
        backUpPendingCaptures = defaults.object(forKey: "backUpPendingCaptures") as? Bool ?? true
    }
}

/// Services for one signed-in account.
public struct AccountServices: Sendable {
    public let api: APIClient
    public let engine: UploadEngine
    public let images: ImageCache
    public let configuration: ClientConfiguration
    public let serverURL: URL
    public let accountId: String
}

/// The app's root state: sign-in, the signed-in account and the capture queue.
@MainActor @Observable public final class AppModel {
    public enum Phase: Equatable {
        case starting
        case signedOut
        case signedIn
        /// Closing or closed: only the deletion status is available.
        case accountClosing
        /// The account for this sign-in was purged.
        case accountPurged
    }

    public var phase: Phase = .starting
    public var signInError: String?
    public var isWorking = false
    public private(set) var me: Me?
    public private(set) var services: AccountServices?
    /// Every capture on this device (all accounts), newest batches last.
    public private(set) var queue: [CaptureItem] = []
    public private(set) var uploadsNeedSignIn = false

    public let settings: AppSettings
    let sessions: SessionManager
    let transport: HTTPTransport
    let store: CaptureStore
    let transfers: BackgroundUploads
    let authenticator: WebAuthenticating

    public init(
        settings: AppSettings = AppSettings(),
        sessionStore: SessionStore = KeychainSessionStore(),
        transfers: BackgroundUploads = BackgroundUploads(),
        authenticator: WebAuthenticating = SystemWebAuthenticator()
    ) throws {
        self.settings = settings
        transport = URLSessionTransport()
        sessions = SessionManager(store: sessionStore, transport: transport)
        store = try CaptureStore(directory: CaptureStore.defaultDirectory())
        self.transfers = transfers
        self.authenticator = authenticator
    }

    // MARK: Session

    public func start() async {
        try? await store.setIncludedInBackups(settings.backUpPendingCaptures)
        await refreshQueue()
        if let session = await sessions.current {
            await activate(session)
        } else {
            phase = .signedOut
        }
    }

    public func signIn() async {
        signInError = nil
        isWorking = true
        defer { isWorking = false }
        do {
            let server = try normalizedServer(settings.serverAddress)
            let configuration = try await APIClient.clientConfiguration(server: server, transport: transport)
            guard let oidc = configuration.oidc else { throw SignInError.notConfigured }
            let credentials = try await authorize(oidc, reauthenticate: false)
            let session = StoredSession(serverURL: server, configuration: configuration, credentials: credentials,
                                        accountId: nil, displayName: credentials.claims.name)
            let previous = await sessions.current?.accountId
            try await sessions.begin(session)
            if previous != nil { ImageCache.clearAll() }
            await activate(session)
        } catch SignInError.cancelled {
            // The user closed the sign-in sheet.
        } catch {
            signInError = error.localizedDescription
        }
    }

    /// A fresh sign-in for the same identity, required within five minutes
    /// before account deletion and permanent purge.
    public func reauthenticate() async throws {
        guard let session = await sessions.current, let oidc = session.configuration.oidc else { throw APIError.unauthenticated }
        let credentials = try await authorize(oidc, reauthenticate: true)
        guard credentials.claims.subject == session.credentials.claims.subject,
              credentials.claims.issuer == session.credentials.claims.issuer else {
            throw SignInError.invalidIDToken("signed in as a different person")
        }
        try await sessions.replaceCredentials(credentials)
    }

    public func hasRecentSignIn() async -> Bool {
        await sessions.current?.credentials.isRecentSignIn() ?? false
    }

    private func authorize(_ oidc: OIDCConfiguration, reauthenticate: Bool) async throws -> Credentials {
        let request = AuthorizationRequest(configuration: oidc, reauthenticate: reauthenticate)
        let callback = try await authenticator.authenticate(url: request.url, callbackScheme: request.callbackScheme)
        let code = try request.code(from: callback)
        return try await TokenClient(configuration: oidc, transport: transport).exchange(code: code, request: request)
    }

    private func normalizedServer(_ text: String) throws -> URL {
        var trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.contains("://") { trimmed = "https://" + trimmed }
        while trimmed.hasSuffix("/") { trimmed.removeLast() }
        guard let url = URL(string: trimmed), let scheme = url.scheme, ["http", "https"].contains(scheme), url.host != nil else {
            throw APIError(status: 0, code: "invalid_address", message: "Enter the address of your Libarrie server.")
        }
        return url
    }

    private func activate(_ session: StoredSession) async {
        let api = APIClient(baseURL: session.serverURL, transport: transport, tokens: sessions)
        do {
            let me = try await api.me()
            if let bound = session.accountId, bound != me.account.id { ImageCache.clearAll() }
            try await sessions.bind(accountId: me.account.id, displayName: me.user.displayName)
            self.me = me
            let engine = UploadEngine(
                api: api, store: store, transfers: transfers, accountId: me.account.id, serverURL: session.serverURL,
                policy: .init(integrity: session.configuration.uploads.integrity))
            transfers.setHandler { result in
                Task { await engine.transferFinished(result); await self.refreshQueue() }
            }
            services = AccountServices(
                api: api, engine: engine, images: ImageCache(api: api, accountId: me.account.id),
                configuration: session.configuration, serverURL: session.serverURL, accountId: me.account.id)
            phase = .signedIn
            await runQueue()
        } catch let error as APIError where error.code == "account_closing" {
            services = AccountServices(
                api: api, engine: UploadEngine(api: api, store: store, transfers: transfers, accountId: session.accountId ?? "",
                                               serverURL: session.serverURL, policy: .init(integrity: "sha256")),
                images: ImageCache(api: api, accountId: session.accountId ?? "none"),
                configuration: session.configuration, serverURL: session.serverURL, accountId: session.accountId ?? "")
            phase = .accountClosing
        } catch let error as APIError where error.code == "account_closed" {
            services = nil
            phase = .accountPurged
        } catch let error as APIError where error.code == "unauthenticated" {
            phase = .signedOut
            signInError = error.message
        } catch {
            // Offline at launch: stay signed in with what we know.
            if let accountId = session.accountId {
                let engine = UploadEngine(api: api, store: store, transfers: transfers, accountId: accountId,
                                          serverURL: session.serverURL, policy: .init(integrity: session.configuration.uploads.integrity))
                transfers.setHandler { result in Task { await engine.transferFinished(result); await self.refreshQueue() } }
                services = AccountServices(api: api, engine: engine, images: ImageCache(api: api, accountId: accountId),
                                           configuration: session.configuration, serverURL: session.serverURL, accountId: accountId)
                phase = .signedIn
            } else {
                phase = .signedOut
                signInError = (error as? LocalizedError)?.errorDescription ?? "Could not reach the server."
            }
        }
    }

    /// Explicitly start a new account after the old one was purged.
    public func startNewAccount() async {
        guard let session = await sessions.current else { return }
        let api = APIClient(baseURL: session.serverURL, transport: transport, tokens: sessions)
        do {
            _ = try await api.createAccountAfterPurge()
            await activate(session)
        } catch {
            signInError = (error as? LocalizedError)?.errorDescription
        }
    }

    /// Signs out. Captures stay on this device, bound to their account; they
    /// upload again only after that same account signs back in.
    public func signOut() async {
        try? await sessions.signOut()
        ImageCache.clearAll()
        services = nil
        me = nil
        phase = .signedOut
    }

    // MARK: Queue

    public func refreshQueue() async {
        queue = await store.items
        if let engine = services?.engine { uploadsNeedSignIn = await engine.needsSignIn }
    }

    public func runQueue() async {
        guard let engine = services?.engine else { return }
        await engine.run()
        await refreshQueue()
    }

    /// Captures for the signed-in account; others are listed separately.
    public var accountQueue: [CaptureItem] {
        guard let services else { return [] }
        return queue.filter { $0.accountId == services.accountId && $0.serverURL == services.serverURL }
    }

    public var otherAccountsQueue: [CaptureItem] {
        guard let services else { return queue }
        return queue.filter { $0.accountId != services.accountId || $0.serverURL != services.serverURL }
    }

    var preparer: ImagePreparer {
        ImagePreparer(keepLocation: settings.keepLocation, maxBytes: services?.configuration.uploads.maxBytes ?? 20_000_000)
    }

    /// Save photos immediately ("saved on this device"), before review.
    public func capture(_ photos: [Data], batch: UUID) async -> [String] {
        guard let services else { return ["Sign in to add pages."] }
        var problems: [String] = []
        let existing = queue.filter { $0.batchId == batch }.count
        for (offset, data) in photos.enumerated() {
            do {
                let prepared = try preparer.prepare(data)
                try await store.capture(prepared, batchId: batch, sequence: existing + offset,
                                        accountId: services.accountId, serverURL: services.serverURL)
            } catch {
                problems.append((error as? LocalizedError)?.errorDescription ?? "A photo could not be saved.")
            }
        }
        await refreshQueue()
        return problems
    }

    /// Finish review: assign notebook and numbers in the reviewed order and queue them.
    public func commit(batch: UUID, order: [UUID], notebook: Notebook, startPage: Int) async {
        for (index, id) in order.enumerated() {
            _ = try? await store.update(id) {
                $0.notebookId = notebook.id
                $0.notebookName = notebook.name
                $0.pageNumber = startPage + index
                $0.sequence = index
                $0.state = .ready
            }
        }
        await runQueue()
    }

    /// Queue a replacement scan for a page (always processed immediately).
    public func replace(page: Page, with photo: Data) async throws {
        guard let services else { throw APIError.unauthenticated }
        let prepared = try preparer.prepare(photo)
        let item = try await store.capture(prepared, batchId: UUID(), sequence: 0,
                                           accountId: services.accountId, serverURL: services.serverURL)
        try await store.update(item.id) {
            $0.replacesPageId = page.id
            $0.replacesContentVersion = page.contentVersion
            $0.notebookId = page.notebook.id
            $0.notebookName = page.notebook.name
            $0.pageNumber = page.pageNumber
            $0.state = .ready
        }
        await runQueue()
    }

    public func discard(_ id: UUID) async {
        try? await store.remove(id)
        await refreshQueue()
    }

    public func cancel(_ id: UUID) async throws {
        if let engine = services?.engine { try await engine.cancel(id) } else { try await store.remove(id) }
        await refreshQueue()
    }

    public func retry(_ id: UUID) async {
        try? await services?.engine.retryNow(id)
        await refreshQueue()
    }

    public func renumber(_ id: UUID, to number: Int) async {
        try? await services?.engine.renumber(id, to: number)
        await refreshQueue()
    }

    public func decide(_ decision: DeferredDecision, batch: UUID) async {
        try? await services?.engine.decide(decision, batch: batch)
        await refreshQueue()
    }

    /// Remove the device copy of an accepted photo before backup verification.
    public func removeLocalCopy(_ id: UUID) async {
        try? await store.removeFile(of: id)
        await refreshQueue()
    }

    public func setBackUpPendingCaptures(_ included: Bool) async {
        settings.backUpPendingCaptures = included
        try? await store.setIncludedInBackups(included)
    }

    public func imageURL(for item: CaptureItem) async -> URL? {
        await store.fileURL(for: item)
    }
}

import Foundation

/// Supplies bearer tokens; refreshes on demand.
public protocol AccessTokenProvider: Sendable {
    func accessToken() async throws -> String
    /// Called after a 401: refresh and return a new token, or throw.
    func refreshAfterRejection(of token: String) async throws -> String
}

/// The `/v1` JSON API. Every call carries the bearer token; a 401 triggers
/// one refresh and retry. Mutations that can be retried carry a stable
/// operation ID chosen by the caller (the server deduplicates by it).
public final class APIClient: Sendable {
    public let baseURL: URL
    private let transport: HTTPTransport
    private let tokens: AccessTokenProvider

    public init(baseURL: URL, transport: HTTPTransport, tokens: AccessTokenProvider) {
        self.baseURL = baseURL
        self.transport = transport
        self.tokens = tokens
    }

    // MARK: Requests

    struct Empty: Encodable {}

    func url(_ path: String, query: [URLQueryItem] = []) -> URL {
        var components = URLComponents(url: baseURL.appending(path: path), resolvingAgainstBaseURL: false)!
        if !query.isEmpty { components.queryItems = query }
        return components.url!
    }

    func send<Response: Decodable>(
        _ method: String,
        _ path: String,
        query: [URLQueryItem] = [],
        body: (any Encodable)? = nil,
        ifMatch: String? = nil,
        as type: Response.Type = Response.self
    ) async throws -> Response {
        let data = try await raw(method, path, query: query, body: body, ifMatch: ifMatch)
        do {
            return try JSON.decoder.decode(Response.self, from: data)
        } catch {
            throw APIError(status: 200, code: "invalid_response", message: "The server's response could not be read.")
        }
    }

    func raw(
        _ method: String,
        _ path: String,
        query: [URLQueryItem] = [],
        body: (any Encodable)? = nil,
        ifMatch: String? = nil
    ) async throws -> Data {
        var request = URLRequest(url: url(path, query: query))
        request.httpMethod = method
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if let body {
            request.httpBody = try JSON.encoder.encode(body)
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        if let ifMatch { request.setValue(ifMatch, forHTTPHeaderField: "If-Match") }
        let token = try await tokens.accessToken()
        let (data, response) = try await perform(request, token: token)
        // "Sign in again to confirm" is not an expired token: surface it.
        if response.statusCode == 401,
           APIError.decode(status: 401, data: data, retryAfter: nil).code == "reauthentication_required" {
            throw APIError.decode(status: 401, data: data, retryAfter: nil)
        }
        if response.statusCode == 401 {
            let fresh = try await tokens.refreshAfterRejection(of: token)
            let (data, response) = try await perform(request, token: fresh)
            return try check(data, response)
        }
        return try check(data, response)
    }

    private func perform(_ request: URLRequest, token: String) async throws -> (Data, HTTPURLResponse) {
        var request = request
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        do {
            return try await transport.send(request)
        } catch let error as APIError {
            throw error
        } catch {
            throw APIError.network(error)
        }
    }

    private func check(_ data: Data, _ response: HTTPURLResponse) throws -> Data {
        if (200..<300).contains(response.statusCode) { return data }
        if response.statusCode == 401 {
            let error = APIError.decode(status: 401, data: data, retryAfter: nil)
            throw error.code == "reauthentication_required" ? error : APIError.unauthenticated
        }
        let retryAfter = response.value(forHTTPHeaderField: "Retry-After").flatMap(Int.init)
        throw APIError.decode(status: response.statusCode, data: data, retryAfter: retryAfter)
    }

    // MARK: Account

    public func me() async throws -> Me { try await send("GET", "/v1/me") }
    public func usage() async throws -> Usage { try await send("GET", "/v1/usage") }

    public func settings() async throws -> ServerSettings { try await send("GET", "/v1/settings") }

    public func updateSettings(autoProcessDeferred: Bool) async throws -> ServerSettings {
        struct Body: Encodable { var autoProcessDeferred: Bool }
        return try await send("PUT", "/v1/settings", body: Body(autoProcessDeferred: autoProcessDeferred))
    }

    /// After purge, an explicit choice to start a new account for this
    /// sign-in (it inherits the identity's prior lifetime-allowance usage).
    public func createAccountAfterPurge() async throws -> Me {
        try await send("POST", "/v1/accounts", body: Empty())
    }

    /// Unauthenticated: what this server needs from the app.
    public static func clientConfiguration(server: URL, transport: HTTPTransport) async throws -> ClientConfiguration {
        var request = URLRequest(url: server.appending(path: "/v1/client-configuration"))
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        let (data, response): (Data, HTTPURLResponse)
        do { (data, response) = try await transport.send(request) } catch { throw APIError.network(error) }
        guard response.statusCode == 200 else {
            throw APIError(status: response.statusCode, code: "not_libarrie",
                           message: "This address does not look like a Libarrie server.")
        }
        do { return try JSON.decoder.decode(ClientConfiguration.self, from: data) } catch {
            throw APIError(status: 200, code: "not_libarrie", message: "This address does not look like a Libarrie server.")
        }
    }

    public func accountDeletionStatus() async throws -> AccountDeletionStatus {
        try await send("GET", "/v1/account-deletion")
    }

    public func scheduleAccountDeletion(acknowledgeCoverageEnd: Bool) async throws -> AccountDeletionStatus {
        struct Body: Encodable { var acknowledgeCoverageEnd: Bool }
        return try await send("POST", "/v1/account-deletion", body: Body(acknowledgeCoverageEnd: acknowledgeCoverageEnd))
    }

    public func cancelAccountDeletion(lifecycleRevision: Int) async throws -> AccountDeletionStatus {
        try await send("DELETE", "/v1/account-deletion", ifMatch: "\"\(lifecycleRevision)\"")
    }

    // MARK: Notebooks

    public struct NotebookInput: Encodable, Sendable {
        public var name: String?
        public var description: String?
        /// `#RRGGBB`; an empty string clears the color.
        public var color: String?
        public init(name: String? = nil, description: String? = nil, color: String? = nil) {
            self.name = name; self.description = description; self.color = color
        }
    }

    public func notebooks(cursor: String? = nil) async throws -> NotebookList {
        try await send("GET", "/v1/notebooks", query: cursor.map { [URLQueryItem(name: "cursor", value: $0)] } ?? [])
    }

    public func notebook(_ id: String) async throws -> Notebook { try await send("GET", "/v1/notebooks/\(id)") }

    public func createNotebook(_ input: NotebookInput) async throws -> Notebook {
        try await send("POST", "/v1/notebooks", body: input)
    }

    public func updateNotebook(_ id: String, version: Int, _ input: NotebookInput) async throws -> Notebook {
        try await send("PATCH", "/v1/notebooks/\(id)", body: input, ifMatch: "\"\(version)\"")
    }

    public func trashNotebook(_ id: String, version: Int) async throws {
        _ = try await raw("DELETE", "/v1/notebooks/\(id)", ifMatch: "\"\(version)\"")
    }

    public func restoreNotebook(_ id: String) async throws {
        _ = try await raw("POST", "/v1/notebooks/\(id)/restore", body: Empty())
    }

    public func pages(notebookId: String, after cursor: String? = nil, limit: Int = 50) async throws -> PageList {
        var query = [URLQueryItem(name: "limit", value: String(limit))]
        if let cursor { query.append(URLQueryItem(name: "cursor", value: cursor)) }
        return try await send("GET", "/v1/notebooks/\(notebookId)/pages", query: query)
    }

    public func numbering(notebookId: String) async throws -> Numbering {
        try await send("GET", "/v1/notebooks/\(notebookId)/renumber")
    }

    public func shiftPages(notebookId: String, numberingRevision: Int, from: Int, to: Int, by: Int) async throws {
        struct Shift: Encodable { var from: Int; var to: Int; var by: Int }
        struct Body: Encodable { var shift: Shift }
        _ = try await raw(
            "POST", "/v1/notebooks/\(notebookId)/renumber",
            body: Body(shift: Shift(from: from, to: to, by: by)), ifMatch: "\"n\(numberingRevision)\"")
    }

    // MARK: Pages

    public func page(_ id: String) async throws -> PageDetail { try await send("GET", "/v1/pages/\(id)") }

    public func movePage(_ id: String, version: Int, pageNumber: Int?, notebookId: String?) async throws -> Page {
        struct Body: Encodable { var pageNumber: Int?; var notebookId: String? }
        struct Reply: Decodable { var page: Page }
        let reply: Reply = try await send(
            "PATCH", "/v1/pages/\(id)", body: Body(pageNumber: pageNumber, notebookId: notebookId), ifMatch: "\"v\(version)\"")
        return reply.page
    }

    public func trashPage(_ id: String, version: Int) async throws {
        _ = try await raw("DELETE", "/v1/pages/\(id)", ifMatch: "\"v\(version)\"")
    }

    public func restorePage(_ id: String) async throws {
        _ = try await raw("POST", "/v1/pages/\(id)/restore", body: Empty())
    }

    public enum TranscriptAction: String, Encodable, Sendable { case save, acceptCandidate = "accept_candidate", confirmBlank = "confirm_blank" }

    public func saveTranscript(
        pageId: String, contentVersion: Int, sourceRevisionId: String,
        baseTranscriptRevisionId: String?, action: TranscriptAction, text: String? = nil, ocrResultId: String? = nil
    ) async throws {
        struct Body: Encodable {
            var sourceRevisionId: String
            var baseTranscriptRevisionId: String?
            var action: TranscriptAction
            var text: String?
            var ocrResultId: String?
        }
        _ = try await raw(
            "PUT", "/v1/pages/\(pageId)/transcript",
            body: Body(sourceRevisionId: sourceRevisionId, baseTranscriptRevisionId: baseTranscriptRevisionId,
                       action: action, text: text, ocrResultId: ocrResultId),
            ifMatch: "\"c\(contentVersion)\"")
    }

    public func rescan(pageId: String, contentVersion: Int, sourceRevisionId: String, operationId: String) async throws -> Operation {
        struct Body: Encodable { var operationId: String; var sourceRevisionId: String }
        return try await send(
            "POST", "/v1/pages/\(pageId)/reprocess",
            body: Body(operationId: operationId, sourceRevisionId: sourceRevisionId), ifMatch: "\"c\(contentVersion)\"")
    }

    public func originalImageURL(pageId: String) async throws -> SignedURL {
        try await send("GET", "/v1/pages/\(pageId)/image-url")
    }

    /// Thumbnail or preview bytes from the authorized same-origin route.
    public func imageData(path: String) async throws -> Data {
        try await raw("GET", path)
    }

    /// Pages uploaded for later processing that still wait (up to 100).
    public func awaitingProcessing() async throws -> [Page] {
        struct Reply: Decodable { var pages: [Page] }
        let reply: Reply = try await send("GET", "/v1/pages/awaiting-processing")
        return reply.pages
    }

    public func processDeferred(_ items: [(pageId: String, sourceRevisionId: String, operationId: String)]) async throws -> [DeferredResult] {
        struct Item: Encodable { var pageId: String; var sourceRevisionId: String; var operationId: String }
        struct Body: Encodable { var items: [Item] }
        let body = Body(items: items.map { Item(pageId: $0.pageId, sourceRevisionId: $0.sourceRevisionId, operationId: $0.operationId) })
        let reply: DeferredResults = try await send("POST", "/v1/pages/process-deferred", body: body)
        return reply.results
    }

    // MARK: Trash

    public func trash() async throws -> TrashList { try await send("GET", "/v1/trash") }

    public func purge(pageIds: [String] = [], notebookIds: [String] = [], all: Bool = false) async throws {
        struct Body: Encodable { var pageIds: [String]; var notebookIds: [String]; var all: Bool }
        _ = try await raw("POST", "/v1/trash/purge", body: Body(pageIds: pageIds, notebookIds: notebookIds, all: all))
    }

    // MARK: Search

    public func search(_ query: String, notebookId: String? = nil, limit: Int = 20) async throws -> SearchResponse {
        struct Body: Encodable { var query: String; var notebookId: String?; var limit: Int }
        return try await send("POST", "/v1/search", body: Body(query: query, notebookId: notebookId, limit: limit))
    }

    // MARK: Exports

    public func exports() async throws -> [Export] { try await send("GET", "/v1/exports", as: ExportList.self).exports }

    public func createExport(notebookIds: [String]?, includeTrash: Bool) async throws -> Export {
        struct Body: Encodable { var notebookIds: [String]?; var includeTrash: Bool }
        return try await send("POST", "/v1/exports", body: Body(notebookIds: notebookIds, includeTrash: includeTrash), as: ExportCreated.self).export
    }

    public func export(_ id: String) async throws -> ExportDetail { try await send("GET", "/v1/exports/\(id)") }

    public func exportPartURL(exportId: String, part: Int) async throws -> SignedURL {
        try await send("GET", "/v1/exports/\(exportId)/parts/\(part)/download-url")
    }

    // MARK: Uploads (used by the capture queue)

    public struct UploadRequest: Encodable, Sendable, Equatable {
        public var operationId: String
        public var notebookId: String?
        public var pageNumber: Int?
        public var pageId: String?
        public var bytes: Int
        public var contentType: String
        public var checksumSha256: String
        public var checksumMd5: String?
        public var processingMode: String
        public var clientLabel: String
        public var transfer: String
        public var retryOfOperationId: String?
    }

    /// Creates (or, for the same operation and body, replays) a reservation.
    public func createUploadSession(_ request: UploadRequest, ifMatchContentVersion: Int?) async throws -> UploadSession {
        try await send("POST", "/v1/upload-sessions", body: request, ifMatch: ifMatchContentVersion.map { "\"c\($0)\"" })
    }

    public func refreshUploadSession(_ id: String) async throws -> UploadSession {
        struct Body: Encodable { var transfer = "background" }
        return try await send("POST", "/v1/upload-sessions/\(id)/refresh", body: Body())
    }

    public func completeUploadSession(_ id: String) async throws -> AcceptedUpload {
        try await send("POST", "/v1/upload-sessions/\(id)/complete", body: Empty())
    }

    /// Resolves an operation by the client's own UUID (recovers lost responses).
    public func operation(_ id: String) async throws -> Operation { try await send("GET", "/v1/operations/\(id)") }

    public func cancelOperation(_ id: String) async throws -> Operation {
        try await send("POST", "/v1/operations/\(id)/cancel", body: Empty())
    }
}

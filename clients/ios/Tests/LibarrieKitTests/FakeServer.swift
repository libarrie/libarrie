import Foundation
@testable import LibarrieKit

/// An in-memory model of the upload protocol: operation-ID deduplication
/// with request-body checks, page-number conflicts, processing allowance,
/// URL and reservation expiry, completion and backup status. Faults can
/// drop a response after the server acted, to test lost-response recovery.
final class FakeServer: @unchecked Sendable {
    enum Fault { case dropResponse, networkBeforeServer }

    struct Op {
        var id: String
        var body: [String: String]
        var pageId: String
        var sessionId: String
        var status = "awaiting_upload"
        var uploaded = false
        var accepted = false
        var urlVersion = 1
    }

    let lock = NSLock()
    var ops: [String: Op] = [:]
    var takenNumbers: Set<String> = []
    var processingAllowance = 100
    var faults: [String: [Fault]] = [:]
    var expiredURLs = false
    var backup: [String: String] = [:]
    var log: [String] = []
    var clock: Clock

    init(clock: Clock) { self.clock = clock }

    func fault(_ route: String, _ fault: Fault) { lock.withLock { faults[route, default: []].append(fault) } }

    var transport: ScriptedTransport {
        ScriptedTransport { [self] request in try self.handle(request) }
    }

    func operation(_ id: String) -> Op? { lock.withLock { ops[id] } }

    private func takeFault(_ route: String) -> Fault? {
        guard var list = faults[route], !list.isEmpty else { return nil }
        let first = list.removeFirst()
        faults[route] = list
        return first
    }

    func handle(_ request: URLRequest) throws -> (Int, Data) {
        try lock.withLock {
            let path = request.url!.path
            let route = "\(request.httpMethod!) \(path.replacingOccurrences(of: #"[0-9a-f-]{36}"#, with: "{id}", options: .regularExpression))"
            log.append(route)
            let fault = takeFault(route)
            if fault == .networkBeforeServer { throw URLError(.networkConnectionLost) }
            let result = try respond(route, path: path, request: request)
            if fault == .dropResponse { throw URLError(.networkConnectionLost) }
            return result
        }
    }

    private func respond(_ route: String, path: String, request: URLRequest) throws -> (Int, Data) {
        let segments = path.split(separator: "/").map(String.init)
        switch route {
        case "POST /v1/upload-sessions":
            let fields = body(request).mapValues { "\($0)" }
            let id = fields["operation_id"]!
            if let op = ops[id] {
                guard op.body == fields else { return (409, errorBody("operation_conflict")) }
                return (200, session(op))
            }
            if let pageId = fields["page_id"] {
                guard request.value(forHTTPHeaderField: "If-Match") != nil else { return (428, errorBody("precondition_required")) }
                _ = pageId
            } else {
                let key = "\(fields["notebook_id"]!)#\(fields["page_number"]!)"
                if takenNumbers.contains(key) { return (409, errorBody("page_number_conflict", "That page number is already in use.")) }
                if fields["processing_mode"] == "immediate" && processingAllowance <= 0 {
                    return (409, errorBody("processing_limit_reached"))
                }
                takenNumbers.insert(key)
            }
            if fields["processing_mode"] == "immediate" { processingAllowance -= 1 }
            expiredURLs = false
            let op = Op(id: id, body: fields, pageId: fields["page_id"] ?? UUID().uuidString.lowercased(),
                        sessionId: UUID().uuidString.lowercased())
            ops[id] = op
            return (201, session(op))
        case "POST /v1/upload-sessions/{id}/refresh":
            guard let key = ops.first(where: { $0.value.sessionId == segments[2] })?.key else { return (404, errorBody("not_found")) }
            if ops[key]!.status == "expired" { return (409, errorBody("upload_expired")) }
            ops[key]!.urlVersion += 1
            expiredURLs = false
            return (200, session(ops[key]!))
        case "POST /v1/upload-sessions/{id}/complete":
            guard let key = ops.first(where: { $0.value.sessionId == segments[2] })?.key else { return (404, errorBody("not_found")) }
            if ops[key]!.status == "expired" { return (409, errorBody("upload_expired")) }
            guard ops[key]!.uploaded else { return (409, errorBody("upload_missing")) }
            ops[key]!.accepted = true
            ops[key]!.status = "queued"
            return (200, json(["operation": operationJSON(ops[key]!), "page_visibility": "active"]))
        case "GET /v1/operations/{id}":
            guard let op = ops[segments[2]] else { return (404, errorBody("not_found")) }
            return (200, json(operationJSON(op)))
        case "POST /v1/operations/{id}/cancel":
            guard ops[segments[2]] != nil else { return (404, errorBody("not_found")) }
            ops[segments[2]]!.status = "cancelled"
            return (200, json(operationJSON(ops[segments[2]]!)))
        case "GET /v1/pages/{id}":
            var detail = try JSONSerialization.jsonObject(with: fixture("page_detail").body) as! [String: Any]
            var page = detail["page"] as! [String: Any]
            page["id"] = segments[2]
            page["backup_status"] = backup[segments[2]] ?? "pending"
            detail["page"] = page
            return (200, json(detail))
        default:
            return (404, errorBody("not_found"))
        }
    }

    /// What a finished transfer to the staging URL does.
    func receiveUpload(url: URL) -> Int {
        lock.withLock {
            if expiredURLs { return 403 }
            guard let key = ops.first(where: { url.path.hasSuffix($0.value.sessionId) })?.key else { return 404 }
            let version = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.first { $0.name == "v" }?.value
            guard version == String(ops[key]!.urlVersion) else { return 403 }
            ops[key]!.uploaded = true
            return 200
        }
    }

    /// Expiry releases the reserved page number, as on the real server.
    func expire(operation id: String) {
        lock.withLock {
            ops[id]?.status = "expired"
            if let op = ops[id], let notebook = op.body["notebook_id"], let number = op.body["page_number"] {
                takenNumbers.remove("\(notebook)#\(number)")
            }
        }
    }

    private func operationJSON(_ op: Op) -> [String: Any] {
        [
            "operation_id": op.id, "kind": op.body["page_id"] == nil ? "upload" : "replacement",
            "status": op.status, "failure_fault": NSNull(), "error_code": NSNull(), "client_label": "ios",
            "notebook_id": op.body["notebook_id"] ?? NSNull(), "page_id": op.pageId, "revision_id": UUID().uuidString,
            "processing_mode": op.body["processing_mode"] ?? "immediate",
            "upload_accepted_at": op.accepted ? "2026-10-14T12:00:00.000000Z" : NSNull(),
            "parent_operation_id": op.body["retry_of_operation_id"] ?? NSNull(),
        ]
    }

    private func session(_ op: Op) -> Data {
        let upload: Any = op.status == "awaiting_upload" && !op.accepted
            ? ["method": "PUT", "url": "http://storage.test/staging/\(op.sessionId)?v=\(op.urlVersion)",
               "headers": ["content-type": op.body["content_type"]!, "x-amz-checksum-sha256": "abc"],
               "expires_in_seconds": 21600]
            : NSNull()
        return json([
            "upload_session_id": op.sessionId, "status": op.status, "expires_at": "2026-10-15T12:00:00Z",
            "upload": upload, "operation": operationJSON(op),
        ])
    }
}

/// Records started transfers; the test finishes them.
actor FakeTransfers: UploadTransferring {
    var started: [(UUID, URLRequest)] = []
    var active: Set<UUID> = []

    func start(itemID: UUID, request: URLRequest, fileURL: URL) async {
        started.append((itemID, request))
        active.insert(itemID)
    }

    func activeItemIDs() async -> Set<UUID> { active }

    /// Deliver every pending transfer to the server and the engine.
    func finishAll(server: FakeServer, engine: UploadEngine) async {
        // Only the newest transfer per item is live (a retry replaces it).
        var latest: [UUID: URLRequest] = [:]
        for (id, request) in started where active.contains(id) { latest[id] = request }
        for (id, request) in latest.sorted(by: { $0.key.uuidString < $1.key.uuidString }) {
            active.remove(id)
            let status = server.receiveUpload(url: request.url!)
            await engine.transferFinished(TransferResult(itemID: id, statusCode: status, failed: false))
        }
    }

    /// The app was terminated: transfers are gone, results never arrive.
    func forgetAll() { active = [] }
}

import Foundation

/// Drives captures through reserve → upload → confirm and keeps tracking
/// them until their independent backup is verified. Implements the
/// recovery rules of sections 7 and 13:
///
/// - The operation UUID is chosen once and reused for every retry, so a lost
///   reservation or completion response is recovered by replaying the same
///   request (the server returns the existing result) or by looking the
///   operation up; no duplicate pages or quota charges.
/// - Expired or cancelled operations are terminal: the user's explicit
///   retry uses a new operation UUID that references the old one.
/// - Expired upload URLs are refreshed on the same reservation.
/// - Only captures bound to the signed-in account and server are uploaded.
/// - Photos stay on the device until the server reports the source
///   independently backed up (`backup_status: verified`).
public actor UploadEngine {
    public struct Policy: Sendable {
        public var integrity: String
        public var clientLabel: String
        public var backupCheckInterval: TimeInterval
        public init(integrity: String, clientLabel: String = "ios", backupCheckInterval: TimeInterval = 15 * 60) {
            self.integrity = integrity; self.clientLabel = clientLabel; self.backupCheckInterval = backupCheckInterval
        }
    }

    private let api: APIClient
    private let store: CaptureStore
    private let transfers: UploadTransferring
    private let accountId: String
    private let serverURL: URL
    private let policy: Policy
    private let now: @Sendable () -> Date
    private var running = false
    private var pausedForSignIn = false

    public init(
        api: APIClient, store: CaptureStore, transfers: UploadTransferring,
        accountId: String, serverURL: URL, policy: Policy, now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.api = api
        self.store = store
        self.transfers = transfers
        self.accountId = accountId
        self.serverURL = serverURL
        self.policy = policy
        self.now = now
    }

    /// True after a 401 that refresh could not fix; the app asks the user
    /// to sign in again. Nothing is lost meanwhile.
    public var needsSignIn: Bool { pausedForSignIn }

    func owned(_ item: CaptureItem) -> Bool {
        item.accountId == accountId && item.serverURL == serverURL
    }

    // MARK: Running

    /// Process everything that is due. Safe to call often (app launch,
    /// foreground, connectivity change, background refresh).
    public func run() async {
        guard !running else { return }
        running = true
        defer { running = false }
        pausedForSignIn = false
        let active = await transfers.activeItemIDs()
        for item in await store.items where owned(item) {
            if pausedForSignIn { return }
            guard let current = await store.item(item.id) else { continue }
            await step(current, active: active)
        }
    }

    private func step(_ item: CaptureItem, active: Set<UUID>) async {
        switch item.state {
        case .ready:
            await reserve(item)
        case .retryableError where (item.nextAttemptAt ?? .distantPast) <= now():
            await resume(item, at: item.resumePoint ?? .reserve)
        // Interrupted mid-request (app terminated): repeat the same step.
        case .reserving:
            await reserve(item)
        case .confirming:
            await confirm(item)
        case .uploading where !active.contains(item.id):
            // No live transfer (relaunch, restore or a lost callback).
            await resume(item, at: .upload)
        case .serverAccepted:
            await checkBackup(item)
        default:
            break
        }
    }

    private func resume(_ item: CaptureItem, at point: ResumePoint) async {
        switch point {
        case .reserve: await reserve(item)
        case .upload: await upload(item)
        case .confirm: await confirm(item)
        }
    }

    // MARK: Reserve

    private func reserve(_ item: CaptureItem) async {
        guard await store.verifyFile(of: item) else { return await reconcileMissingFile(item) }
        guard let request = uploadRequest(item) else {
            return await attention(item, .rejected, "Choose a notebook and page number for this photo.")
        }
        await save(item.id) { $0.state = .reserving }
        do {
            let session = try await api.createUploadSession(request, ifMatchContentVersion: item.replacesContentVersion)
            await save(item.id) {
                $0.uploadSessionId = session.uploadSessionId
                $0.pageId = session.operation.pageId ?? $0.pageId
            }
            if let target = session.upload {
                await startTransfer(item.id, target: target)
            } else {
                // A replay of an operation that is already past the upload.
                await apply(session.operation, to: item.id)
            }
        } catch let error as APIError {
            await handleReserveError(item, error)
        } catch {
            await retry(item, at: .reserve, error.localizedDescription)
        }
    }

    private func uploadRequest(_ item: CaptureItem) -> APIClient.UploadRequest? {
        let replacement = item.replacesPageId
        guard replacement != nil || (item.notebookId != nil && item.pageNumber != nil) else { return nil }
        return APIClient.UploadRequest(
            operationId: item.operationId,
            notebookId: replacement == nil ? item.notebookId : nil,
            pageNumber: replacement == nil ? item.pageNumber : nil,
            pageId: replacement,
            bytes: item.byteCount,
            contentType: item.contentType,
            checksumSha256: item.sha256,
            checksumMd5: policy.integrity == "md5" ? item.md5 : nil,
            // Replacements are never deferred (section 7).
            processingMode: replacement == nil ? item.processingMode : "immediate",
            clientLabel: policy.clientLabel,
            transfer: "background",
            retryOfOperationId: item.retryOfOperationId)
    }

    private func handleReserveError(_ item: CaptureItem, _ error: APIError) async {
        if error.code == "unauthenticated" { return await pause(item, at: .reserve) }
        // Unknown outcome or temporary refusal: replay the same operation later.
        if error.isTransient { return await retry(item, at: .reserve, error.message, after: error.retryAfter) }
        switch error.code {
        case "page_number_conflict":
            await attention(item, .pageNumberConflict, error.message)
        case "processing_limit_reached" where item.isReplacement:
            // Replacements stay queued until processing is available again.
            await retry(item, at: .reserve, "Waiting for processing allowance.", after: 3600)
        case "processing_limit_reached":
            await processingLimitReached(item)
        case "storage_limit_reached":
            await attention(item, .storageFull, error.message)
        case "version_conflict":
            await attention(item, .pageChanged, "The page changed since you chose to replace its scan.")
        case "not_found":
            await attention(item, item.isReplacement ? .pageChanged : .notebookMissing, error.message)
        case "account_closing", "account_closed":
            await attention(item, .accountClosing, error.message)
        case "operation_terminal", "upload_expired":
            await lookUp(item)
        default:
            await attention(item, .rejected, error.message)
        }
    }

    /// Ask once per batch (section 13): apply an earlier answer silently.
    private func processingLimitReached(_ item: CaptureItem) async {
        switch await store.decision(for: item.batchId) {
        case .uploadAndProcessLater?:
            // The refused request created nothing; a changed body needs a new UUID.
            await save(item.id) {
                $0.processingMode = "deferred"
                $0.operationId = UUID().uuidString.lowercased()
                $0.state = .ready
                $0.attention = nil
            }
            if let updated = await store.item(item.id) { await reserve(updated) }
        case .keepOnDevice?:
            await retry(item, at: .reserve, "Kept on this device until processing allowance is available.", after: 6 * 3600)
        case nil:
            await attention(item, .processingLimit, "Your processing allowance is used up.")
        }
    }

    // MARK: Upload

    private func startTransfer(_ id: UUID, target: UploadTarget) async {
        guard let item = await store.item(id), let file = await store.fileURL(for: item) else { return }
        var request = URLRequest(url: target.url)
        request.httpMethod = target.method
        for (name, value) in target.headers { request.setValue(value, forHTTPHeaderField: name) }
        await save(id) {
            $0.state = .uploading
            $0.uploadURL = target.url
            $0.uploadHeaders = target.headers
            $0.uploadURLExpiresAt = self.now().addingTimeInterval(TimeInterval(target.expiresInSeconds))
            $0.resumePoint = nil
            $0.lastError = nil
        }
        await transfers.start(itemID: id, request: request, fileURL: file)
    }

    private func upload(_ item: CaptureItem) async {
        guard let sessionId = item.uploadSessionId else { return await reserve(item) }
        guard await store.verifyFile(of: item) else { return await reconcileMissingFile(item) }
        if let url = item.uploadURL, let headers = item.uploadHeaders,
           let expires = item.uploadURLExpiresAt, expires.timeIntervalSince(now()) > 120 {
            return await startTransfer(item.id, target: UploadTarget(
                method: "PUT", url: url, headers: headers,
                expiresInSeconds: Int(expires.timeIntervalSince(now()))))
        }
        // The URL expired: refresh it on the same reservation.
        do {
            let session = try await api.refreshUploadSession(sessionId)
            if let target = session.upload {
                await startTransfer(item.id, target: target)
            } else {
                await apply(session.operation, to: item.id)
            }
        } catch let error as APIError {
            if error.code == "unauthenticated" { return await pause(item, at: .upload) }
            if error.isTransient { return await retry(item, at: .upload, error.message, after: error.retryAfter) }
            // The reservation is gone: find out what happened to the operation.
            await lookUp(item)
        } catch {
            await retry(item, at: .upload, error.localizedDescription)
        }
    }

    /// Called when a background transfer ends.
    public func transferFinished(_ result: TransferResult) async {
        guard let item = await store.item(result.itemID), item.state == .uploading, owned(item) else { return }
        switch result.statusCode {
        case let status? where (200..<300).contains(status):
            await confirm(item)
        case 400?, 403?:
            // Usually an expired signature; refresh on the next pass.
            // Retry at once a couple of times, then back off, so a refusal
            // that is not an expired link cannot loop.
            await save(item.id) { $0.uploadURLExpiresAt = .distantPast }
            await retry(item, at: .upload, "The upload link expired; renewing it.", after: item.attempts < 2 ? 0 : nil)
        default:
            await retry(item, at: .upload, "The upload was interrupted.")
        }
    }

    // MARK: Confirm

    private func confirm(_ item: CaptureItem) async {
        guard let sessionId = item.uploadSessionId else { return await reserve(item) }
        await save(item.id) { $0.state = .confirming }
        do {
            let accepted = try await api.completeUploadSession(sessionId)
            await apply(accepted.operation, to: item.id)
        } catch let error as APIError {
            if error.code == "unauthenticated" { return await pause(item, at: .confirm) }
            if error.isTransient { return await retry(item, at: .confirm, error.message, after: error.retryAfter) }
            switch error.code {
            case "upload_missing":
                // The bytes never arrived (or were cut short): upload again.
                await save(item.id) { $0.uploadURLExpiresAt = $0.uploadURLExpiresAt ?? .distantPast }
                await retry(item, at: .upload, error.message, after: 0)
            case "upload_changed":
                await retry(item, at: .confirm, error.message, after: 0)
            case "unsupported_image":
                await attention(item, .rejected, error.message)
            default:
                await lookUp(item)
            }
        } catch {
            await retry(item, at: .confirm, error.localizedDescription)
        }
    }

    // MARK: Operation outcomes

    /// Resolve an operation by its UUID and move the item accordingly.
    private func lookUp(_ item: CaptureItem) async {
        do {
            let operation = try await api.operation(item.operationId)
            await apply(operation, to: item.id)
        } catch let error as APIError where error.status == 404 {
            // Never created: the original UUID may be retried as is.
            await save(item.id) { $0.uploadSessionId = nil; $0.uploadURL = nil; $0.uploadHeaders = nil }
            await retry(item, at: .reserve, error.message, after: 0)
        } catch let error as APIError {
            if error.code == "unauthenticated" { return await pause(item, at: item.resumePoint ?? .reserve) }
            await retry(item, at: item.resumePoint ?? .reserve, error.message, after: error.retryAfter)
        } catch {
            await retry(item, at: item.resumePoint ?? .reserve, error.localizedDescription)
        }
    }

    private func apply(_ operation: Operation, to id: UUID) async {
        if operation.uploadAcceptedAt != nil {
            await save(id) {
                $0.state = .serverAccepted
                $0.pageId = operation.pageId ?? $0.pageId
                $0.acceptedAt = $0.acceptedAt ?? self.now()
                $0.backup = $0.backup ?? .pending
                $0.attention = nil
                $0.lastError = nil
                $0.resumePoint = nil
                $0.uploadURL = nil
                $0.uploadHeaders = nil
            }
            return
        }
        guard let item = await store.item(id) else { return }
        switch operation.status {
        case "awaiting_upload":
            await upload(item)
        case "expired", "cancelled":
            await attention(item, .expired, "This upload expired before it finished. Try again to upload the photo.")
        case "failed":
            await attention(item, .rejected, "Libarrie could not use this photo (\(operation.errorCode ?? "unsupported image")).")
        default:
            await retry(item, at: .confirm, nil)
        }
    }

    /// The photo is missing or damaged. Still look the operation up: an
    /// accepted upload is safe on the server; otherwise the user decides.
    private func reconcileMissingFile(_ item: CaptureItem) async {
        if item.uploadSessionId != nil || item.attempts > 0 {
            if let operation = try? await api.operation(item.operationId), operation.uploadAcceptedAt != nil {
                await apply(operation, to: item.id)
                await save(item.id) { $0.localFileRemoved = true }
                return
            }
        }
        await attention(item, .captureMissing, "The photo on this device is missing or damaged, and Libarrie never received it.")
    }

    // MARK: Backup tracking

    private func checkBackup(_ item: CaptureItem) async {
        guard item.backup != .verified, let pageId = item.pageId else { return }
        if let checked = item.backupCheckedAt, now().timeIntervalSince(checked) < policy.backupCheckInterval { return }
        do {
            let detail = try await api.page(pageId)
            let status = BackupState(rawValue: detail.page.backupStatus ?? "pending") ?? .pending
            await save(item.id) { $0.backup = status; $0.backupCheckedAt = self.now() }
            // Verified: the device copy is no longer the only safe one.
            if status == .verified && !item.localFileRemoved { try? await store.removeFile(of: item.id) }
        } catch {
            await save(item.id) { $0.backupCheckedAt = self.now() }
        }
    }

    // MARK: Transitions

    private func retry(_ item: CaptureItem, at point: ResumePoint, _ message: String?, after seconds: Int? = nil) async {
        let attempts = item.attempts + 1
        let delay = seconds.map(TimeInterval.init) ?? Self.backoff(attempts)
        await save(item.id) {
            $0.state = .retryableError
            $0.resumePoint = point
            $0.attempts = attempts
            $0.lastError = message
            $0.nextAttemptAt = self.now().addingTimeInterval(delay)
        }
    }

    /// Exponential backoff from 5 seconds up to 30 minutes.
    static func backoff(_ attempts: Int) -> TimeInterval {
        min(5 * pow(2, Double(max(0, attempts - 1))), 1800)
    }

    private func pause(_ item: CaptureItem, at point: ResumePoint) async {
        pausedForSignIn = true
        await save(item.id) {
            $0.state = .retryableError
            $0.resumePoint = point
            $0.nextAttemptAt = nil
            $0.lastError = "Sign in again to continue uploading."
        }
    }

    private func attention(_ item: CaptureItem, _ reason: AttentionReason, _ message: String) async {
        await save(item.id) {
            $0.state = .needsUserAction
            $0.attention = reason
            $0.lastError = message
            $0.nextAttemptAt = nil
        }
    }

    private func save(_ id: UUID, _ change: @Sendable (inout CaptureItem) -> Void) async {
        _ = try? await store.update(id, change)
    }

    // MARK: User decisions

    /// Retry a needs-attention or waiting item now.
    public func retryNow(_ id: UUID) async throws {
        guard let item = await store.item(id), owned(item) else { return }
        switch item.attention {
        case .expired?:
            // Terminal on the server: a linked new operation.
            try await store.update(id) {
                $0.retryOfOperationId = $0.operationId
                $0.operationId = UUID().uuidString.lowercased()
                $0.uploadSessionId = nil; $0.uploadURL = nil; $0.uploadHeaders = nil; $0.uploadURLExpiresAt = nil
                $0.state = .ready; $0.attention = nil; $0.lastError = nil; $0.attempts = 0
            }
        case .pageChanged?, .rejected?, .storageFull?, .notebookMissing?, .accountClosing?, .captureMissing?,
             .pageNumberConflict?, .processingLimit?:
            // Nothing was created on the server for these refusals.
            try await store.update(id) {
                $0.operationId = UUID().uuidString.lowercased()
                $0.state = .ready; $0.attention = nil; $0.lastError = nil; $0.attempts = 0
            }
        case nil:
            try await store.update(id) { $0.nextAttemptAt = nil }
        }
        await run()
    }

    /// Resolve a page-number conflict with a number the user chose.
    public func renumber(_ id: UUID, to pageNumber: Int) async throws {
        try await store.update(id) {
            $0.pageNumber = pageNumber
            $0.operationId = UUID().uuidString.lowercased()
            $0.state = .ready; $0.attention = nil; $0.lastError = nil; $0.attempts = 0
        }
        await run()
    }

    /// The once-per-batch answer to "processing allowance used up".
    public func decide(_ decision: DeferredDecision, batch: UUID) async throws {
        try await store.setDecision(decision, for: batch)
        for item in await store.items where item.batchId == batch && item.attention == .processingLimit {
            try await store.update(item.id) { $0.state = .ready; $0.attention = nil }
        }
        await run()
    }

    /// Cancel an upload. If the server may know the operation, cancel it
    /// there first (idempotent); the photo is deleted afterwards.
    public func cancel(_ id: UUID) async throws {
        guard let item = await store.item(id) else { return }
        if owned(item) && !item.neverReachedServer && item.state != .serverAccepted {
            do {
                _ = try await api.cancelOperation(item.operationId)
            } catch let error as APIError where error.status == 404 {
                // Never created.
            }
        }
        try await store.remove(id)
    }
}

package app.libarrie.core.queue

import app.libarrie.core.api.ApiClient
import app.libarrie.core.api.ApiError
import app.libarrie.core.api.Operation
import app.libarrie.core.api.UploadTarget
import kotlinx.coroutines.sync.Mutex
import java.io.File
import java.util.UUID
import kotlin.math.min
import kotlin.math.pow

/**
 * Moves bytes to the presigned staging URL. On Android this is WorkManager,
 * so uploads finish after the app leaves the foreground or is killed;
 * tests substitute a scripted implementation.
 */
interface UploadTransfers {
    suspend fun start(itemId: String, url: String, method: String, headers: Map<String, String>, file: File)
    suspend fun activeItemIds(): Set<String>
}

/** A finished transfer: the HTTP status, or null when no response arrived. */
data class TransferResult(val itemId: String, val statusCode: Int?)

/**
 * Drives captures through reserve → upload → confirm and tracks them until
 * their independent backup is verified. The same recovery rules as the iOS
 * engine (sections 7 and 13):
 *
 * - One operation UUID per upload, reused for every retry: a lost response
 *   is recovered by replaying the request or looking the operation up.
 * - Expired or cancelled operations are terminal; the user's retry uses a
 *   new UUID that references the old one.
 * - Expired upload URLs are refreshed on the same reservation.
 * - Only captures bound to the signed-in account and server are uploaded.
 * - Photos stay on the device until the server reports a verified backup.
 */
class UploadEngine(
    private val api: ApiClient,
    private val store: CaptureStore,
    private val transfers: UploadTransfers,
    private val accountId: String,
    private val serverUrl: String,
    private val integrity: String,
    private val clientLabel: String = "android",
    private val backupCheckIntervalSeconds: Long = 15 * 60,
    private val now: () -> Long = { System.currentTimeMillis() / 1000 },
) {
    private val running = Mutex()

    /** True after a 401 that refresh could not fix; nothing is lost meanwhile. */
    @Volatile var needsSignIn = false
        private set

    fun owned(item: CaptureItem) = item.accountId == accountId && item.serverUrl == serverUrl

    /** Process everything that is due. Safe to call often. */
    suspend fun run() {
        if (!running.tryLock()) return
        try {
            needsSignIn = false
            val active = transfers.activeItemIds()
            for (item in store.items().filter(::owned)) {
                if (needsSignIn) return
                val current = store.item(item.id) ?: continue
                step(current, active)
            }
        } finally {
            running.unlock()
        }
    }

    private suspend fun step(item: CaptureItem, active: Set<String>) {
        when (item.state) {
            CaptureState.Ready -> reserve(item)
            CaptureState.RetryableError -> if ((item.nextAttemptAt ?: 0) <= now()) resume(item, item.resumePoint ?: ResumePoint.Reserve)
            // Interrupted mid-request (process killed): repeat the same step.
            CaptureState.Reserving -> reserve(item)
            CaptureState.Confirming -> confirm(item)
            CaptureState.Uploading -> if (item.id !in active) resume(item, ResumePoint.Upload)
            CaptureState.ServerAccepted -> checkBackup(item)
            else -> Unit
        }
    }

    private suspend fun resume(item: CaptureItem, point: ResumePoint) = when (point) {
        ResumePoint.Reserve -> reserve(item)
        ResumePoint.Upload -> upload(item)
        ResumePoint.Confirm -> confirm(item)
    }

    // Reserve -----------------------------------------------------------------------------------

    private suspend fun reserve(item: CaptureItem) {
        if (!store.verifyFile(item)) return reconcileMissingFile(item)
        val request = uploadRequest(item) ?: return attention(item, AttentionReason.Rejected, "Choose a notebook and page number for this photo.")
        save(item.id) { it.copy(state = CaptureState.Reserving) }
        try {
            val session = api.createUploadSession(request, item.replacesContentVersion)
            save(item.id) { it.copy(uploadSessionId = session.uploadSessionId, pageId = session.operation.pageId ?: it.pageId) }
            val target = session.upload
            if (target != null) startTransfer(item.id, target) else apply(session.operation, item.id)
        } catch (e: ApiError) {
            handleReserveError(item, e)
        }
    }

    private fun uploadRequest(item: CaptureItem): ApiClient.UploadRequest? {
        val replacement = item.replacesPageId
        if (replacement == null && (item.notebookId == null || item.pageNumber == null)) return null
        return ApiClient.UploadRequest(
            operationId = item.operationId,
            notebookId = if (replacement == null) item.notebookId else null,
            pageNumber = if (replacement == null) item.pageNumber else null,
            pageId = replacement,
            bytes = item.byteCount,
            contentType = item.contentType,
            checksumSha256 = item.sha256,
            checksumMd5 = if (integrity == "md5") item.md5 else null,
            // Replacements are never deferred (section 7).
            processingMode = if (replacement == null) item.processingMode else "immediate",
            clientLabel = clientLabel,
            transfer = "background",
            retryOfOperationId = item.retryOfOperationId,
        )
    }

    private suspend fun handleReserveError(item: CaptureItem, error: ApiError) {
        if (error.code == "unauthenticated") return pause(item, ResumePoint.Reserve)
        // Unknown outcome or temporary refusal: replay the same operation later.
        if (error.isTransient) return retry(item, ResumePoint.Reserve, error.message, error.retryAfter?.toLong())
        when {
            error.code == "page_number_conflict" -> attention(item, AttentionReason.PageNumberConflict, error.message)
            // Replacements stay queued until processing is available again.
            error.code == "processing_limit_reached" && item.isReplacement ->
                retry(item, ResumePoint.Reserve, "Waiting for processing allowance.", 3600)
            error.code == "processing_limit_reached" -> processingLimitReached(item)
            error.code == "storage_limit_reached" -> attention(item, AttentionReason.StorageFull, error.message)
            error.code == "version_conflict" -> attention(item, AttentionReason.PageChanged, "The page changed since you chose to replace its scan.")
            error.code == "not_found" ->
                attention(item, if (item.isReplacement) AttentionReason.PageChanged else AttentionReason.NotebookMissing, error.message)
            error.code in setOf("account_closing", "account_closed") -> attention(item, AttentionReason.AccountClosing, error.message)
            error.code in setOf("operation_terminal", "upload_expired") -> lookUp(item)
            else -> attention(item, AttentionReason.Rejected, error.message)
        }
    }

    /** Ask once per batch (section 13): apply an earlier answer silently. */
    private suspend fun processingLimitReached(item: CaptureItem) {
        when (store.decision(item.batchId)) {
            DeferredDecision.UploadAndProcessLater -> {
                // The refused request created nothing; a changed body needs a new UUID.
                val updated = store.update(item.id) {
                    it.copy(processingMode = "deferred", operationId = newId(), state = CaptureState.Ready, attention = null)
                }
                if (updated != null) reserve(updated)
            }
            DeferredDecision.KeepOnDevice ->
                retry(item, ResumePoint.Reserve, "Kept on this device until processing allowance is available.", 6 * 3600)
            null -> attention(item, AttentionReason.ProcessingLimit, "Your processing allowance is used up.")
        }
    }

    // Upload ------------------------------------------------------------------------------------

    private suspend fun startTransfer(id: String, target: UploadTarget) {
        val item = store.item(id) ?: return
        val file = store.fileFor(item) ?: return
        save(id) {
            it.copy(
                state = CaptureState.Uploading, uploadUrl = target.url, uploadHeaders = target.headers,
                uploadUrlExpiresAt = now() + target.expiresInSeconds, resumePoint = null, lastError = null,
            )
        }
        transfers.start(id, target.url, target.method, target.headers, file)
    }

    private suspend fun upload(item: CaptureItem) {
        val sessionId = item.uploadSessionId ?: return reserve(item)
        if (!store.verifyFile(item)) return reconcileMissingFile(item)
        val url = item.uploadUrl
        val headers = item.uploadHeaders
        val expires = item.uploadUrlExpiresAt
        if (url != null && headers != null && expires != null && expires - now() > 120) {
            return startTransfer(item.id, UploadTarget("PUT", url, headers, (expires - now()).toInt()))
        }
        // The URL expired: refresh it on the same reservation.
        try {
            val session = api.refreshUploadSession(sessionId)
            val target = session.upload
            if (target != null) startTransfer(item.id, target) else apply(session.operation, item.id)
        } catch (e: ApiError) {
            when {
                e.code == "unauthenticated" -> pause(item, ResumePoint.Upload)
                e.isTransient -> retry(item, ResumePoint.Upload, e.message, e.retryAfter?.toLong())
                // The reservation is gone: find out what happened to the operation.
                else -> lookUp(item)
            }
        }
    }

    /** Called when a background transfer ends. */
    suspend fun transferFinished(result: TransferResult) {
        val item = store.item(result.itemId) ?: return
        if (item.state != CaptureState.Uploading || !owned(item)) return
        val status = result.statusCode
        when {
            status != null && status in 200..299 -> confirm(item)
            status == 400 || status == 403 -> {
                // Usually an expired signature: renew at once a couple of times, then back off.
                save(item.id) { it.copy(uploadUrlExpiresAt = 0) }
                retry(item, ResumePoint.Upload, "The upload link expired; renewing it.", if (item.attempts < 2) 0 else null)
            }
            else -> retry(item, ResumePoint.Upload, "The upload was interrupted.")
        }
    }

    // Confirm -----------------------------------------------------------------------------------

    private suspend fun confirm(item: CaptureItem) {
        val sessionId = item.uploadSessionId ?: return reserve(item)
        save(item.id) { it.copy(state = CaptureState.Confirming) }
        try {
            apply(api.completeUploadSession(sessionId).operation, item.id)
        } catch (e: ApiError) {
            when {
                e.code == "unauthenticated" -> pause(item, ResumePoint.Confirm)
                e.isTransient -> retry(item, ResumePoint.Confirm, e.message, e.retryAfter?.toLong())
                // The bytes never arrived (or were cut short): upload again.
                e.code == "upload_missing" -> retry(item, ResumePoint.Upload, e.message, 0)
                e.code == "upload_changed" -> retry(item, ResumePoint.Confirm, e.message, 0)
                e.code == "unsupported_image" -> attention(item, AttentionReason.Rejected, e.message)
                else -> lookUp(item)
            }
        }
    }

    // Operation outcomes ----------------------------------------------------------------------------

    /** Resolve an operation by its UUID and move the item accordingly. */
    private suspend fun lookUp(item: CaptureItem) {
        try {
            apply(api.operation(item.operationId), item.id)
        } catch (e: ApiError) {
            when {
                // Never created: the original UUID may be retried as is.
                e.status == 404 -> {
                    save(item.id) { it.copy(uploadSessionId = null, uploadUrl = null, uploadHeaders = null) }
                    retry(item, ResumePoint.Reserve, e.message, 0)
                }
                e.code == "unauthenticated" -> pause(item, item.resumePoint ?: ResumePoint.Reserve)
                else -> retry(item, item.resumePoint ?: ResumePoint.Reserve, e.message, e.retryAfter?.toLong())
            }
        }
    }

    private suspend fun apply(operation: Operation, id: String) {
        if (operation.uploadAcceptedAt != null) {
            save(id) {
                it.copy(
                    state = CaptureState.ServerAccepted, pageId = operation.pageId ?: it.pageId, acceptedAt = it.acceptedAt ?: now(),
                    backup = it.backup ?: BackupState.Pending, attention = null, lastError = null, resumePoint = null,
                    uploadUrl = null, uploadHeaders = null,
                )
            }
            return
        }
        val item = store.item(id) ?: return
        when (operation.status) {
            "awaiting_upload" -> upload(item)
            "expired", "cancelled" -> attention(item, AttentionReason.Expired, "This upload expired before it finished. Try again to upload the photo.")
            "failed" -> attention(item, AttentionReason.Rejected, "Libarrie could not use this photo (${operation.errorCode ?: "unsupported image"}).")
            else -> retry(item, ResumePoint.Confirm, null)
        }
    }

    /** The photo is missing or damaged: an accepted upload is safe; otherwise the user decides. */
    private suspend fun reconcileMissingFile(item: CaptureItem) {
        if (item.uploadSessionId != null || item.attempts > 0) {
            val operation = runCatching { api.operation(item.operationId) }.getOrNull()
            if (operation?.uploadAcceptedAt != null) {
                apply(operation, item.id)
                save(item.id) { it.copy(localFileRemoved = true) }
                return
            }
        }
        attention(item, AttentionReason.CaptureMissing, "The photo on this device is missing or damaged, and Libarrie never received it.")
    }

    // Backup tracking -------------------------------------------------------------------------------

    private suspend fun checkBackup(item: CaptureItem) {
        val pageId = item.pageId ?: return
        if (item.backup == BackupState.Verified) return
        if (item.backupCheckedAt != null && now() - item.backupCheckedAt < backupCheckIntervalSeconds) return
        try {
            val status = when (api.page(pageId).page.backupStatus) {
                "verified" -> BackupState.Verified
                "missing" -> BackupState.Missing
                else -> BackupState.Pending
            }
            save(item.id) { it.copy(backup = status, backupCheckedAt = now()) }
            // Verified: the device copy is no longer the only safe one.
            if (status == BackupState.Verified && !item.localFileRemoved) store.removeFile(item.id)
        } catch (e: ApiError) {
            save(item.id) { it.copy(backupCheckedAt = now()) }
        }
    }

    // Transitions -----------------------------------------------------------------------------------

    private suspend fun retry(item: CaptureItem, point: ResumePoint, message: String?, afterSeconds: Long? = null) {
        val attempts = item.attempts + 1
        val delay = afterSeconds ?: backoff(attempts)
        save(item.id) {
            it.copy(state = CaptureState.RetryableError, resumePoint = point, attempts = attempts, lastError = message, nextAttemptAt = now() + delay)
        }
    }

    private suspend fun pause(item: CaptureItem, point: ResumePoint) {
        needsSignIn = true
        save(item.id) {
            it.copy(state = CaptureState.RetryableError, resumePoint = point, nextAttemptAt = null, lastError = "Sign in again to continue uploading.")
        }
    }

    private suspend fun attention(item: CaptureItem, reason: AttentionReason, message: String) {
        save(item.id) { it.copy(state = CaptureState.NeedsUserAction, attention = reason, lastError = message, nextAttemptAt = null) }
    }

    private suspend fun save(id: String, change: (CaptureItem) -> CaptureItem) {
        store.update(id, change)
    }

    // User decisions ----------------------------------------------------------------------------------

    /** Retry a needs-attention or waiting item now. */
    suspend fun retryNow(id: String) {
        val item = store.item(id)?.takeIf(::owned) ?: return
        when (item.attention) {
            // Terminal on the server: a linked new operation.
            AttentionReason.Expired -> store.update(id) {
                it.copy(
                    retryOfOperationId = it.operationId, operationId = newId(), uploadSessionId = null, uploadUrl = null,
                    uploadHeaders = null, uploadUrlExpiresAt = null, state = CaptureState.Ready, attention = null, lastError = null, attempts = 0,
                )
            }
            // Nothing was created on the server for the other refusals.
            null -> store.update(id) { it.copy(nextAttemptAt = null) }
            else -> store.update(id) {
                it.copy(operationId = newId(), state = CaptureState.Ready, attention = null, lastError = null, attempts = 0)
            }
        }
        run()
    }

    /** Resolve a page-number conflict with a number the user chose. */
    suspend fun renumber(id: String, pageNumber: Int) {
        store.update(id) {
            it.copy(pageNumber = pageNumber, operationId = newId(), state = CaptureState.Ready, attention = null, lastError = null, attempts = 0)
        }
        run()
    }

    /** The once-per-batch answer to "processing allowance used up". */
    suspend fun decide(decision: DeferredDecision, batch: String) {
        store.setDecision(decision, batch)
        for (item in store.items().filter { it.batchId == batch && it.attention == AttentionReason.ProcessingLimit }) {
            store.update(item.id) { it.copy(state = CaptureState.Ready, attention = null) }
        }
        run()
    }

    /** Cancel an upload: cancel on the server first if it may know it, then forget the photo. */
    suspend fun cancel(id: String) {
        val item = store.item(id) ?: return
        if (owned(item) && !item.neverReachedServer && item.state != CaptureState.ServerAccepted) {
            try {
                api.cancelOperation(item.operationId)
            } catch (e: ApiError) {
                if (e.status != 404) throw e
            }
        }
        store.remove(id)
    }

    companion object {
        /** Exponential backoff from 5 seconds up to 30 minutes. */
        fun backoff(attempts: Int): Long = min(5.0 * 2.0.pow((attempts - 1).coerceAtLeast(0)), 1800.0).toLong()
        private fun newId() = UUID.randomUUID().toString()
    }
}

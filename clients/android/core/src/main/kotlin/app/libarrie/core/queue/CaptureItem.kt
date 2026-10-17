package app.libarrie.core.queue

import kotlinx.serialization.SerialName
import kotlinx.serialization.Serializable
import java.security.MessageDigest

/** Local queue states (section 13, "Local queue state machine"). */
@Serializable
enum class CaptureState {
    /** Saved on this device, not yet reviewed into a batch. */
    @SerialName("captured") Captured,
    /** Reviewed and waiting to upload. */
    @SerialName("ready") Ready,
    @SerialName("reserving") Reserving,
    @SerialName("uploading") Uploading,
    @SerialName("confirming") Confirming,
    /** Stored by Libarrie (not yet independently backed up). */
    @SerialName("server_accepted") ServerAccepted,
    @SerialName("retryable_error") RetryableError,
    @SerialName("needs_user_action") NeedsUserAction,
    @SerialName("cancelled") Cancelled,
}

/** Where a retry resumes. */
@Serializable enum class ResumePoint { @SerialName("reserve") Reserve, @SerialName("upload") Upload, @SerialName("confirm") Confirm }

/** Why an item waits for the user. */
@Serializable
enum class AttentionReason {
    /** Another page already has this number; choose a new one. */
    @SerialName("page_number_conflict") PageNumberConflict,
    /** Processing allowance used up: upload now and process later, or keep it here. */
    @SerialName("processing_limit") ProcessingLimit,
    @SerialName("storage_full") StorageFull,
    @SerialName("notebook_missing") NotebookMissing,
    /** The page this scan replaces changed since it was chosen. */
    @SerialName("page_changed") PageChanged,
    @SerialName("rejected") Rejected,
    /** The reservation expired or was cancelled; a retry starts a linked new upload. */
    @SerialName("expired") Expired,
    /** The photo on this device is missing or damaged and Libarrie never stored it. */
    @SerialName("capture_missing") CaptureMissing,
    @SerialName("account_closing") AccountClosing,
}

/** Independent backup of an accepted source (section 7, step 9). */
@Serializable enum class BackupState { @SerialName("pending") Pending, @SerialName("verified") Verified, @SerialName("missing") Missing }

/** The batch-wide answer to "allowance used up", asked once per batch. */
@Serializable enum class DeferredDecision { @SerialName("upload_and_process_later") UploadAndProcessLater, @SerialName("keep_on_device") KeepOnDevice }

@Serializable
data class CaptureItem(
    val id: String,
    val batchId: String,
    /** Position within the batch (review order). */
    val sequence: Int,
    /** Stable operation UUID: the server's deduplication key for this upload. */
    val operationId: String,
    val retryOfOperationId: String? = null,
    /** The account and server this capture belongs to; never uploaded anywhere else. */
    val accountId: String,
    val serverUrl: String,
    val notebookId: String? = null,
    val notebookName: String? = null,
    val pageNumber: Int? = null,
    val replacesPageId: String? = null,
    val replacesContentVersion: Int? = null,
    /** `immediate` or `deferred`. */
    val processingMode: String = "immediate",
    /** Image file name, relative to the capture directory. */
    val fileName: String,
    val byteCount: Long,
    val contentType: String,
    val sha256: String,
    val md5: String,
    val state: CaptureState,
    val resumePoint: ResumePoint? = null,
    val attention: AttentionReason? = null,
    val lastError: String? = null,
    val attempts: Int = 0,
    val nextAttemptAt: Long? = null,
    val uploadSessionId: String? = null,
    val uploadUrl: String? = null,
    val uploadHeaders: Map<String, String>? = null,
    val uploadUrlExpiresAt: Long? = null,
    /** Server page ID, known once the reservation exists. */
    val pageId: String? = null,
    val acceptedAt: Long? = null,
    val backup: BackupState? = null,
    val backupCheckedAt: Long? = null,
    /** The local photo was removed (after backup verification, or by the user). */
    val localFileRemoved: Boolean = false,
    val createdAt: Long,
    val updatedAt: Long,
) {
    val isReplacement get() = replacesPageId != null

    /** Nothing has been sent to the server yet. */
    val neverReachedServer get() = uploadSessionId == null && state in setOf(CaptureState.Captured, CaptureState.Ready)
}

/** A prepared photo: exact bytes to upload. */
class PreparedImage(val bytes: ByteArray, val contentType: String) {
    val sha256: String = Checksums.sha256Hex(bytes)
    val md5: String = Checksums.md5Hex(bytes)
}

object Checksums {
    fun sha256Hex(bytes: ByteArray) = hex(MessageDigest.getInstance("SHA-256").digest(bytes))
    fun md5Hex(bytes: ByteArray) = hex(MessageDigest.getInstance("MD5").digest(bytes))
    private fun hex(bytes: ByteArray) = bytes.joinToString("") { "%02x".format(it) }
}

/** The recovery manifest (section 13). */
@Serializable
internal data class Manifest(
    val version: Int = 1,
    val items: List<CaptureItem> = emptyList(),
    val decisions: Map<String, DeferredDecision> = emptyMap(),
)

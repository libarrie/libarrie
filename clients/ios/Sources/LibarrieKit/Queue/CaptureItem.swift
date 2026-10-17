import Foundation

/// Local queue states (section 13, "Local queue state machine").
public enum CaptureState: String, Codable, Sendable {
    /// Saved on this device, not yet reviewed into a batch.
    case captured
    /// Reviewed and waiting to upload.
    case ready
    case reserving
    case uploading
    case confirming
    /// Stored by Libarrie (not yet independently backed up).
    case serverAccepted = "server_accepted"
    case retryableError = "retryable_error"
    case needsUserAction = "needs_user_action"
    case cancelled
}

/// Where a retry resumes.
public enum ResumePoint: String, Codable, Sendable { case reserve, upload, confirm }

/// Why an item waits for the user.
public enum AttentionReason: String, Codable, Sendable {
    /// Another page already has this number; choose a new one.
    case pageNumberConflict = "page_number_conflict"
    /// Processing allowance used up: upload now and process later, or keep it here.
    case processingLimit = "processing_limit"
    case storageFull = "storage_full"
    case notebookMissing = "notebook_missing"
    /// The page this scan replaces changed since it was chosen.
    case pageChanged = "page_changed"
    /// The server refused the image.
    case rejected
    /// The reservation expired or the upload was cancelled; retry starts a linked new upload.
    case expired
    /// The photo on this device is missing or damaged and was never stored by Libarrie.
    case captureMissing = "capture_missing"
    case accountClosing = "account_closing"
}

/// Independent backup of an accepted source (section 7, step 9).
public enum BackupState: String, Codable, Sendable { case pending, verified, missing }

public struct CaptureItem: Codable, Sendable, Equatable, Identifiable {
    public var id: UUID
    public var batchId: UUID
    /// Position within the batch (review order).
    public var sequence: Int
    /// Stable operation UUID: the server's deduplication key for this upload.
    public var operationId: String
    public var retryOfOperationId: String?
    /// The account and server this capture belongs to. Never uploaded
    /// anywhere else (section 13: queued images cannot leak across accounts).
    public var accountId: String
    public var serverURL: URL

    // Target: a new page, or a replacement scan for an existing page.
    public var notebookId: String?
    public var notebookName: String?
    public var pageNumber: Int?
    public var replacesPageId: String?
    public var replacesContentVersion: Int?
    /// `immediate` or `deferred`.
    public var processingMode: String

    /// Image file name, relative to the capture directory.
    public var fileName: String
    public var byteCount: Int
    public var contentType: String
    public var sha256: String
    public var md5: String

    public var state: CaptureState
    public var resumePoint: ResumePoint?
    public var attention: AttentionReason?
    public var lastError: String?
    public var attempts: Int
    public var nextAttemptAt: Date?

    public var uploadSessionId: String?
    public var uploadURL: URL?
    public var uploadHeaders: [String: String]?
    public var uploadURLExpiresAt: Date?

    /// Server page ID, known once the reservation exists.
    public var pageId: String?
    public var acceptedAt: Date?
    public var backup: BackupState?
    public var backupCheckedAt: Date?
    /// The local photo was removed (after backup verification, or by the user).
    public var localFileRemoved: Bool

    public var createdAt: Date
    public var updatedAt: Date

    public var isReplacement: Bool { replacesPageId != nil }

    /// Sent to the server; nothing has been reserved yet.
    var neverReachedServer: Bool {
        uploadSessionId == nil && [.captured, .ready].contains(state)
    }
}

/// A batch-wide answer to "allowance used up": asked once per batch.
public enum DeferredDecision: String, Codable, Sendable { case uploadAndProcessLater, keepOnDevice }

/// The recovery manifest (section 13): everything needed to resume or
/// reconcile captures after relaunch, restore or device transfer.
struct Manifest: Codable {
    var version = 1
    var items: [CaptureItem] = []
    var decisions: [UUID: DeferredDecision] = [:]
}

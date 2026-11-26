package app.libarrie.core.api

import kotlinx.serialization.KSerializer
import kotlinx.serialization.Serializable
import kotlinx.serialization.descriptors.buildClassSerialDescriptor
import kotlinx.serialization.encoding.Decoder
import kotlinx.serialization.encoding.Encoder
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonDecoder
import kotlinx.serialization.json.JsonEncoder
import kotlinx.serialization.json.JsonNamingStrategy
import kotlinx.serialization.json.buildJsonObject
import kotlinx.serialization.json.int
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.jsonPrimitive
import kotlinx.serialization.json.put

// Local models for the /v1 JSON API (contracts/openapi.yaml). Unknown
// additive fields are ignored, so newer servers never break older apps.

val ApiJson = Json {
    namingStrategy = JsonNamingStrategy.SnakeCase
    ignoreUnknownKeys = true
    explicitNulls = false
    encodeDefaults = true
}

@Serializable
data class ClientConfiguration(val oidc: OidcConfiguration? = null, val uploads: UploadPolicy)

@Serializable
data class OidcConfiguration(
    val issuer: String,
    val authorizationEndpoint: String,
    val tokenEndpoint: String,
    val clientId: String,
    val redirectUri: String,
    val scopes: List<String>,
)

/** `integrity` is `sha256` or `md5` (Cloudflare R2 verifies only Content-MD5). */
@Serializable
data class UploadPolicy(val integrity: String, val maxBytes: Int, val contentTypes: List<String>)

@Serializable
data class Me(val user: User, val account: Account, val capabilities: Capabilities) {
    @Serializable data class User(val id: String, val displayName: String)
    @Serializable data class Account(val id: String, val status: String)
    @Serializable data class Capabilities(val deferredProcessing: Boolean, val backgroundUploadUrls: Boolean)
}

/** `{"kind":"limited","value":n}` or `{"kind":"unlimited"}`. */
@Serializable(with = LimitSerializer::class)
data class Limit(val value: Int?) {
    val unlimited get() = value == null
    override fun toString() = value?.toString() ?: "unlimited"
}

object LimitSerializer : KSerializer<Limit> {
    override val descriptor = buildClassSerialDescriptor("Limit")
    override fun deserialize(decoder: Decoder): Limit {
        val obj = (decoder as JsonDecoder).decodeJsonElement().jsonObject
        return if (obj["kind"]?.jsonPrimitive?.content == "limited") Limit(obj.getValue("value").jsonPrimitive.int) else Limit(null)
    }
    override fun serialize(encoder: Encoder, value: Limit) {
        (encoder as JsonEncoder).encodeJsonElement(buildJsonObject {
            if (value.value != null) { put("kind", "limited"); put("value", value.value) } else put("kind", "unlimited")
        })
    }
}

@Serializable
data class Usage(
    val limits: Limits,
    val storedPages: Int,
    val reservedPageSlots: Int,
    val notebooks: Int,
    /** `none`, `above_80_percent`, `above_90_percent` or `at_capacity`. */
    val capacityWarning: String,
    /** Present for lifetime allowances. */
    val lifetimeAllowance: Allowance? = null,
) {
    @Serializable data class Limits(val storedPages: Limit, val notebooks: Limit)
    @Serializable data class Allowance(val limit: Limit, val used: Int, val reserved: Int)
}

/** Account preferences stored by the server. */
@Serializable data class ServerSettings(val autoProcessDeferred: Boolean)

@Serializable data class NotebookRef(val id: String, val name: String)

@Serializable
data class Notebook(
    val id: String,
    val name: String,
    val description: String = "",
    val color: String? = null,
    val version: Int,
    val numberingRevision: Int,
    val pageCount: Int,
    val deletedAt: String? = null,
    /**
     * Searches show where its pages match, never the text (ADR 0017). A
     * server older than private notebooks sends none, which reads as false.
     */
    val private: Boolean = false,
)

@Serializable data class NotebookList(val notebooks: List<Notebook>, val nextCursor: String? = null)

@Serializable
data class Page(
    val id: String,
    val notebook: NotebookRef,
    val pageNumber: Int,
    val visibility: String,
    val version: Int,
    val contentVersion: Int,
    val revisionId: String? = null,
    val pendingRevisionId: String? = null,
    val transcriptRevisionId: String? = null,
    val processingStatus: String,
    val indexingPending: Boolean = false,
    val liveOperationId: String? = null,
    /** `pending`, `verified` or `missing`: independent backup of the source. */
    val backupStatus: String? = null,
    val deletedAt: String? = null,
    /** Same-origin, cacheable `/img/{object}/{variant}` paths; null until derived. */
    val thumbnailUrl: String? = null,
    val previewUrl: String? = null,
) {
    /** The immutable source object ID, used as the image cache key. */
    val imageObjectId: String? get() = (thumbnailUrl ?: previewUrl)?.split('/')?.filter { it.isNotEmpty() }?.getOrNull(1)
}

@Serializable data class PageList(val notebookId: String, val numberingRevision: Int, val pages: List<Page>, val nextCursor: String? = null)

@Serializable
data class Numbering(val notebookId: String, val numberingRevision: Int, val pages: List<Entry>) {
    @Serializable data class Entry(val pageId: String, val pageNumber: Int, val version: Int)
    val nextFree: Int get() = (pages.maxOfOrNull { it.pageNumber } ?: 0) + 1
}

@Serializable data class Transcript(val transcriptRevisionId: String? = null, val text: String, val origin: String, val blank: Boolean)
@Serializable data class OcrCandidate(val ocrResultId: String, val text: String)

@Serializable
data class Operation(
    val operationId: String,
    val kind: String,
    val status: String,
    val failureFault: String? = null,
    val errorCode: String? = null,
    val notebookId: String? = null,
    val pageId: String? = null,
    val revisionId: String? = null,
    val processingMode: String = "immediate",
    val uploadAcceptedAt: String? = null,
    val parentOperationId: String? = null,
)

@Serializable
data class PageDetail(val page: Page, val transcript: Transcript? = null, val ocrCandidate: OcrCandidate? = null, val latestOperation: Operation? = null)

@Serializable data class UploadTarget(val method: String, val url: String, val headers: Map<String, String>, val expiresInSeconds: Int)

@Serializable
data class UploadSession(val uploadSessionId: String, val status: String, val expiresAt: String, val upload: UploadTarget? = null, val operation: Operation)

@Serializable data class AcceptedUpload(val operation: Operation, val pageVisibility: String? = null)

@Serializable
data class SearchHit(
    val pageId: String,
    val notebook: NotebookRef,
    val pageNumber: Int,
    /** Absent, with [highlights], for a page in a private notebook. */
    val snippet: String? = null,
    val highlights: List<Highlight> = emptyList(),
    val matchKind: String,
    val indexingPending: Boolean = false,
) {
    @Serializable data class Highlight(val start: Int, val end: Int)
}

/** `searchMode` is `hybrid` or `lexical_only`. */
@Serializable data class SearchResponse(val searchMode: String, val indexMigrationPending: Boolean = false, val results: List<SearchHit>)

@Serializable data class TrashList(val retentionDays: Int, val notebooks: List<Notebook>, val pages: List<Page>, val nextCursor: String? = null)

@Serializable
data class Export(
    val id: String,
    /** assembling, completed, failed, expired, cancelled or invalidated. */
    val state: String,
    val includeTrash: Boolean,
    val itemCount: Int,
    val totalBytes: Long,
    val createdAt: String,
    val expiresAt: String? = null,
    val errorCode: String? = null,
)

@Serializable data class ExportPart(val partNumber: Int, val itemCount: Int, val bytes: Long? = null, val checksumSha256: String? = null, val downloadable: Boolean)
@Serializable data class ExportList(val exports: List<Export>)
@Serializable data class ExportCreated(val export: Export)
@Serializable data class ExportDetail(val export: Export, val parts: List<ExportPart>)
@Serializable data class SignedUrl(val url: String, val expiresInSeconds: Int)

@Serializable
data class AccountDeletionStatus(val status: String, val milestone: String, val lifecycleRevision: Int? = null, val effectiveAt: String? = null, val notice: String? = null)

/** `result` is admitted, already_admitted, conflict or limit. */
@Serializable data class DeferredResult(val pageId: String, val operationId: String? = null, val result: String)
@Serializable data class DeferredResults(val results: List<DeferredResult>)

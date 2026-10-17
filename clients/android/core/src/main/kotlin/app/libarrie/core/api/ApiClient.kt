package app.libarrie.core.api

import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext
import kotlinx.serialization.Serializable
import kotlinx.serialization.serializer
import okhttp3.HttpUrl
import okhttp3.HttpUrl.Companion.toHttpUrl
import okhttp3.MediaType.Companion.toMediaType
import okhttp3.OkHttpClient
import okhttp3.Request
import okhttp3.RequestBody.Companion.toRequestBody
import java.io.IOException
import java.util.concurrent.TimeUnit

/** Supplies bearer tokens; refreshes on demand. */
interface AccessTokenProvider {
    suspend fun accessToken(): String
    /** Called after a 401: refresh and return a new token, or throw. */
    suspend fun refreshAfterRejection(token: String): String
}

/**
 * OkHttp without a CookieJar: the app authenticates only with bearer
 * tokens, so a web session cookie can never mix into API requests
 * (section 13).
 */
fun defaultHttpClient(): OkHttpClient = OkHttpClient.Builder()
    .connectTimeout(15, TimeUnit.SECONDS)
    .readTimeout(30, TimeUnit.SECONDS)
    .retryOnConnectionFailure(false)
    .build()

/**
 * The `/v1` JSON API. Every call carries the bearer token; a 401 triggers
 * one refresh and retry. Retried mutations carry a stable operation ID
 * chosen by the caller (the server deduplicates by it).
 */
class ApiClient(val baseUrl: String, private val http: OkHttpClient, private val tokens: AccessTokenProvider) {
    private val jsonType = "application/json".toMediaType()

    fun url(path: String, query: Map<String, String> = emptyMap()): HttpUrl {
        val builder = baseUrl.trimEnd('/').toHttpUrl().newBuilder()
        path.trim('/').split('/').filter { it.isNotEmpty() }.forEach { builder.addPathSegment(it) }
        query.forEach { (k, v) -> builder.addQueryParameter(k, v) }
        return builder.build()
    }

    suspend fun raw(method: String, path: String, body: String? = null, ifMatch: String? = null, query: Map<String, String> = emptyMap()): String {
        val builder = Request.Builder().url(url(path, query)).header("Accept", "application/json")
        val requestBody = body?.toRequestBody(jsonType) ?: if (method in setOf("POST", "PUT", "PATCH")) "{}".toRequestBody(jsonType) else null
        builder.method(method, requestBody)
        if (ifMatch != null) builder.header("If-Match", ifMatch)
        val request = builder.build()
        val token = tokens.accessToken()
        val (status, text, retryAfter) = perform(request, token)
        if (status == 401) {
            val error = ApiError.decode(401, text, null)
            // "Sign in again to confirm" is not an expired token: surface it.
            if (error.code == "reauthentication_required") throw error
            val fresh = tokens.refreshAfterRejection(token)
            val (status2, text2, retryAfter2) = perform(request, fresh)
            return check(status2, text2, retryAfter2)
        }
        return check(status, text, retryAfter)
    }

    private suspend fun perform(request: Request, token: String): Triple<Int, String, Int?> = withContext(Dispatchers.IO) {
        val authorized = request.newBuilder().header("Authorization", "Bearer $token").build()
        try {
            http.newCall(authorized).execute().use { response ->
                Triple(response.code, response.body.string(), response.header("Retry-After")?.toIntOrNull())
            }
        } catch (e: IOException) {
            throw ApiError.network(e)
        }
    }

    private fun check(status: Int, text: String, retryAfter: Int?): String {
        if (status in 200..299) return text
        if (status == 401) {
            val error = ApiError.decode(401, text, null)
            throw if (error.code == "reauthentication_required") error else ApiError.unauthenticated()
        }
        throw ApiError.decode(status, text, retryAfter)
    }

    suspend inline fun <reified T> send(method: String, path: String, body: String? = null, ifMatch: String? = null, query: Map<String, String> = emptyMap()): T {
        val text = raw(method, path, body, ifMatch, query)
        return try {
            ApiJson.decodeFromString(serializer<T>(), text)
        } catch (e: Exception) {
            throw ApiError(200, "invalid_response", "The server's response could not be read.")
        }
    }

    inline fun <reified T> encode(value: T): String = ApiJson.encodeToString(serializer<T>(), value)

    // Account ------------------------------------------------------------------------------

    suspend fun me(): Me = send("GET", "/v1/me")
    suspend fun usage(): Usage = send("GET", "/v1/usage")
    suspend fun settings(): ServerSettings = send("GET", "/v1/settings")
    suspend fun updateSettings(autoProcessDeferred: Boolean): ServerSettings =
        send("PUT", "/v1/settings", encode(ServerSettings(autoProcessDeferred)))
    suspend fun createAccountAfterPurge(): Me = send("POST", "/v1/accounts")
    suspend fun accountDeletionStatus(): AccountDeletionStatus = send("GET", "/v1/account-deletion")

    @Serializable private data class ScheduleBody(val acknowledgeCoverageEnd: Boolean)
    suspend fun scheduleAccountDeletion(acknowledgeCoverageEnd: Boolean): AccountDeletionStatus =
        send("POST", "/v1/account-deletion", encode(ScheduleBody(acknowledgeCoverageEnd)))

    suspend fun cancelAccountDeletion(lifecycleRevision: Int): AccountDeletionStatus =
        send("DELETE", "/v1/account-deletion", ifMatch = "\"$lifecycleRevision\"")

    // Notebooks ----------------------------------------------------------------------------

    /** `color` is `#RRGGBB`; an empty string clears it. */
    @Serializable data class NotebookInput(val name: String? = null, val description: String? = null, val color: String? = null)

    suspend fun notebooks(cursor: String? = null): NotebookList =
        send("GET", "/v1/notebooks", query = cursor?.let { mapOf("cursor" to it) } ?: emptyMap())

    suspend fun allNotebooks(): List<Notebook> {
        val all = mutableListOf<Notebook>()
        var cursor: String? = null
        do {
            val page = notebooks(cursor)
            all += page.notebooks
            cursor = page.nextCursor
        } while (cursor != null)
        return all
    }

    suspend fun notebook(id: String): Notebook = send("GET", "/v1/notebooks/$id")
    suspend fun createNotebook(input: NotebookInput): Notebook = send("POST", "/v1/notebooks", encode(input))
    suspend fun updateNotebook(id: String, version: Int, input: NotebookInput): Notebook =
        send("PATCH", "/v1/notebooks/$id", encode(input), ifMatch = "\"$version\"")
    suspend fun trashNotebook(id: String, version: Int) { raw("DELETE", "/v1/notebooks/$id", ifMatch = "\"$version\"") }
    suspend fun restoreNotebook(id: String) { raw("POST", "/v1/notebooks/$id/restore") }

    suspend fun pages(notebookId: String, after: String? = null, limit: Int = 50): PageList =
        send("GET", "/v1/notebooks/$notebookId/pages", query = buildMap {
            put("limit", limit.toString())
            if (after != null) put("cursor", after)
        })

    suspend fun numbering(notebookId: String): Numbering = send("GET", "/v1/notebooks/$notebookId/renumber")

    @Serializable private data class Shift(val from: Int, val to: Int, val by: Int)
    @Serializable private data class ShiftBody(val shift: Shift)
    suspend fun shiftPages(notebookId: String, numberingRevision: Int, from: Int, to: Int, by: Int) {
        raw("POST", "/v1/notebooks/$notebookId/renumber", encode(ShiftBody(Shift(from, to, by))), ifMatch = "\"n$numberingRevision\"")
    }

    // Pages ------------------------------------------------------------------------------------

    suspend fun page(id: String): PageDetail = send("GET", "/v1/pages/$id")

    @Serializable private data class MoveBody(val pageNumber: Int? = null, val notebookId: String? = null)
    @Serializable private data class PageReply(val page: Page)
    suspend fun movePage(id: String, version: Int, pageNumber: Int?, notebookId: String?): Page =
        send<PageReply>("PATCH", "/v1/pages/$id", encode(MoveBody(pageNumber, notebookId)), ifMatch = "\"v$version\"").page

    suspend fun trashPage(id: String, version: Int) { raw("DELETE", "/v1/pages/$id", ifMatch = "\"v$version\"") }
    suspend fun restorePage(id: String) { raw("POST", "/v1/pages/$id/restore") }

    enum class TranscriptAction(val wire: String) { Save("save"), AcceptCandidate("accept_candidate"), ConfirmBlank("confirm_blank") }

    @Serializable private data class TranscriptBody(
        val sourceRevisionId: String,
        val baseTranscriptRevisionId: String? = null,
        val action: String,
        val text: String? = null,
        val ocrResultId: String? = null,
    )

    suspend fun saveTranscript(
        pageId: String, contentVersion: Int, sourceRevisionId: String, baseTranscriptRevisionId: String?,
        action: TranscriptAction, text: String? = null, ocrResultId: String? = null,
    ) {
        raw("PUT", "/v1/pages/$pageId/transcript",
            encode(TranscriptBody(sourceRevisionId, baseTranscriptRevisionId, action.wire, text, ocrResultId)),
            ifMatch = "\"c$contentVersion\"")
    }

    @Serializable private data class RescanBody(val operationId: String, val sourceRevisionId: String)
    suspend fun rescan(pageId: String, contentVersion: Int, sourceRevisionId: String, operationId: String): Operation =
        send("POST", "/v1/pages/$pageId/reprocess", encode(RescanBody(operationId, sourceRevisionId)), ifMatch = "\"c$contentVersion\"")

    suspend fun originalImageUrl(pageId: String): SignedUrl = send("GET", "/v1/pages/$pageId/image-url")

    /** Thumbnail or preview bytes from the authorized same-origin route. */
    suspend fun imageBytes(path: String): ByteArray = withContext(Dispatchers.IO) {
        val token = tokens.accessToken()
        val request = Request.Builder().url(url(path)).header("Authorization", "Bearer $token").build()
        try {
            http.newCall(request).execute().use { response ->
                if (!response.isSuccessful) throw ApiError.decode(response.code, response.body.string(), null)
                response.body.bytes()
            }
        } catch (e: IOException) {
            throw ApiError.network(e)
        }
    }

    @Serializable private data class Awaiting(val pages: List<Page>)
    /** Pages uploaded for later processing that still wait (up to 100). */
    suspend fun awaitingProcessing(): List<Page> = send<Awaiting>("GET", "/v1/pages/awaiting-processing").pages

    @Serializable data class DeferredItem(val pageId: String, val sourceRevisionId: String, val operationId: String)
    @Serializable private data class DeferredBody(val items: List<DeferredItem>)
    suspend fun processDeferred(items: List<DeferredItem>): List<DeferredResult> =
        send<DeferredResults>("POST", "/v1/pages/process-deferred", encode(DeferredBody(items))).results

    // Trash ----------------------------------------------------------------------------------

    suspend fun trash(): TrashList = send("GET", "/v1/trash")

    @Serializable private data class PurgeBody(val pageIds: List<String>, val notebookIds: List<String>, val all: Boolean)
    suspend fun purge(pageIds: List<String> = emptyList(), notebookIds: List<String> = emptyList(), all: Boolean = false) {
        raw("POST", "/v1/trash/purge", encode(PurgeBody(pageIds, notebookIds, all)))
    }

    // Search ---------------------------------------------------------------------------------

    @Serializable private data class SearchBody(val query: String, val notebookId: String? = null, val limit: Int)
    suspend fun search(query: String, notebookId: String? = null, limit: Int = 20): SearchResponse =
        send("POST", "/v1/search", encode(SearchBody(query, notebookId, limit)))

    // Exports --------------------------------------------------------------------------------

    suspend fun exports(): List<Export> = send<ExportList>("GET", "/v1/exports").exports

    @Serializable private data class ExportBody(val notebookIds: List<String>? = null, val includeTrash: Boolean)
    suspend fun createExport(notebookIds: List<String>?, includeTrash: Boolean): Export =
        send<ExportCreated>("POST", "/v1/exports", encode(ExportBody(notebookIds, includeTrash))).export

    suspend fun export(id: String): ExportDetail = send("GET", "/v1/exports/$id")
    suspend fun exportPartUrl(exportId: String, part: Int): SignedUrl = send("GET", "/v1/exports/$exportId/parts/$part/download-url")

    // Uploads (used by the capture queue) ---------------------------------------------------------

    @Serializable
    data class UploadRequest(
        val operationId: String,
        val notebookId: String? = null,
        val pageNumber: Int? = null,
        val pageId: String? = null,
        val bytes: Long,
        val contentType: String,
        val checksumSha256: String,
        val checksumMd5: String? = null,
        val processingMode: String,
        val clientLabel: String,
        val transfer: String,
        val retryOfOperationId: String? = null,
    )

    /** Creates (or, for the same operation and body, replays) a reservation. */
    suspend fun createUploadSession(request: UploadRequest, ifMatchContentVersion: Int?): UploadSession =
        send("POST", "/v1/upload-sessions", encode(request), ifMatch = ifMatchContentVersion?.let { "\"c$it\"" })

    @Serializable private data class RefreshBody(val transfer: String = "background")
    suspend fun refreshUploadSession(id: String): UploadSession =
        send("POST", "/v1/upload-sessions/$id/refresh", encode(RefreshBody()))

    suspend fun completeUploadSession(id: String): AcceptedUpload = send("POST", "/v1/upload-sessions/$id/complete")

    /** Resolves an operation by the client's own UUID (recovers lost responses). */
    suspend fun operation(id: String): Operation = send("GET", "/v1/operations/$id")
    suspend fun cancelOperation(id: String): Operation = send("POST", "/v1/operations/$id/cancel")

    companion object {
        /** Unauthenticated: what this server needs from the app. */
        suspend fun clientConfiguration(server: String, http: OkHttpClient): ClientConfiguration = withContext(Dispatchers.IO) {
            val notLibarrie = ApiError(0, "not_libarrie", "This address does not look like a Libarrie server.")
            val url = runCatching { "${server.trimEnd('/')}/v1/client-configuration".toHttpUrl() }.getOrElse { throw notLibarrie }
            try {
                http.newCall(Request.Builder().url(url).header("Accept", "application/json").build()).execute().use { response ->
                    if (response.code != 200) throw notLibarrie
                    runCatching { ApiJson.decodeFromString<ClientConfiguration>(response.body.string()) }.getOrElse { throw notLibarrie }
                }
            } catch (e: IOException) {
                throw ApiError.network(e)
            }
        }
    }
}

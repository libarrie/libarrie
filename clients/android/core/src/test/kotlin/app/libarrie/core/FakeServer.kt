package app.libarrie.core

import app.libarrie.core.queue.TransferResult
import app.libarrie.core.queue.UploadEngine
import app.libarrie.core.queue.UploadTransfers
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.JsonElement
import kotlinx.serialization.json.JsonNull
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.buildJsonObject
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.put
import okhttp3.HttpUrl.Companion.toHttpUrl
import okhttp3.Request
import java.io.File
import java.io.IOException
import java.util.UUID

/**
 * An in-memory model of the upload protocol: operation-ID deduplication with
 * body checks, page-number conflicts, processing allowance, URL and
 * reservation expiry, completion and backup status. Faults can drop a
 * response after the server acted, to test lost-response recovery.
 */
class FakeServer {
    enum class Fault { DropResponse, NetworkBeforeServer }

    data class Op(
        val id: String,
        val body: Map<String, String>,
        val pageId: String,
        val sessionId: String,
        var status: String = "awaiting_upload",
        var uploaded: Boolean = false,
        var accepted: Boolean = false,
        var urlVersion: Int = 1,
    )

    val ops = mutableMapOf<String, Op>()
    val takenNumbers = mutableSetOf<String>()
    var processingAllowance = 100
    var expiredUrls = false
    val backup = mutableMapOf<String, String>()
    val log = mutableListOf<String>()
    private val faults = mutableMapOf<String, ArrayDeque<Fault>>()

    fun fault(route: String, fault: Fault) = synchronized(this) { faults.getOrPut(route) { ArrayDeque() }.add(fault) }

    val http = scriptedClient { request -> handle(request) }

    @Synchronized
    fun handle(request: Request): Pair<Int, String> {
        val path = request.url.encodedPath
        val route = "${request.method} ${path.replace(Regex("[0-9a-f-]{36}"), "{id}")}"
        log += route
        val fault = faults[route]?.removeFirstOrNull()
        if (fault == Fault.NetworkBeforeServer) throw IOException("connection lost")
        val result = respond(route, path.split('/').filter { it.isNotEmpty() }, request)
        if (fault == Fault.DropResponse) throw IOException("connection lost")
        return result
    }

    private fun flat(text: String): Map<String, String> =
        Json.parseToJsonElement(text).jsonObject.mapNotNull { (k, v) -> (v as? JsonPrimitive)?.let { k to it.content } }.toMap()

    private fun respond(route: String, segments: List<String>, request: Request): Pair<Int, String> {
        fun bySession(id: String) = ops.values.firstOrNull { it.sessionId == id }
        return when (route) {
            "POST /v1/upload-sessions" -> {
                val fields = flat(bodyText(request))
                val id = fields.getValue("operation_id")
                ops[id]?.let { return if (it.body == fields) 200 to session(it) else 409 to errorBody("operation_conflict") }
                if (fields["page_id"] != null) {
                    if (request.header("If-Match") == null) return 428 to errorBody("precondition_required")
                } else {
                    val key = "${fields["notebook_id"]}#${fields["page_number"]}"
                    if (key in takenNumbers) return 409 to errorBody("page_number_conflict", "That page number is already in use.")
                    if (fields["processing_mode"] == "immediate" && processingAllowance <= 0) return 409 to errorBody("processing_limit_reached")
                    takenNumbers += key
                }
                if (fields["processing_mode"] == "immediate") processingAllowance--
                expiredUrls = false
                val op = Op(id, fields, fields["page_id"] ?: UUID.randomUUID().toString(), UUID.randomUUID().toString())
                ops[id] = op
                201 to session(op)
            }
            "POST /v1/upload-sessions/{id}/refresh" -> {
                val op = bySession(segments[2]) ?: return 404 to errorBody("not_found")
                if (op.status == "expired") return 409 to errorBody("upload_expired")
                op.urlVersion++
                expiredUrls = false
                200 to session(op)
            }
            "POST /v1/upload-sessions/{id}/complete" -> {
                val op = bySession(segments[2]) ?: return 404 to errorBody("not_found")
                if (op.status == "expired") return 409 to errorBody("upload_expired")
                if (!op.uploaded) return 409 to errorBody("upload_missing")
                op.accepted = true
                op.status = "queued"
                200 to JsonObject(mapOf("operation" to operationJson(op), "page_visibility" to JsonPrimitive("active"))).toString()
            }
            "GET /v1/operations/{id}" -> ops[segments[2]]?.let { 200 to operationJson(it).toString() } ?: (404 to errorBody("not_found"))
            "POST /v1/operations/{id}/cancel" -> {
                val op = ops[segments[2]] ?: return 404 to errorBody("not_found")
                op.status = "cancelled"
                200 to operationJson(op).toString()
            }
            "GET /v1/pages/{id}" -> {
                val detail = Json.parseToJsonElement(fixture("page_detail").second).jsonObject
                val page = detail.getValue("page").jsonObject.toMutableMap()
                page["id"] = JsonPrimitive(segments[2])
                page["backup_status"] = JsonPrimitive(backup[segments[2]] ?: "pending")
                200 to JsonObject(detail + ("page" to JsonObject(page))).toString()
            }
            else -> 404 to errorBody("not_found")
        }
    }

    /** What a finished transfer to the staging URL does. */
    @Synchronized
    fun receiveUpload(url: String): Int {
        if (expiredUrls) return 403
        val parsed = url.toHttpUrl()
        val op = ops.values.firstOrNull { parsed.encodedPath.endsWith(it.sessionId) } ?: return 404
        if (parsed.queryParameter("v") != op.urlVersion.toString()) return 403
        op.uploaded = true
        return 200
    }

    /** Expiry releases the reserved page number, as on the real server. */
    @Synchronized
    fun expire(id: String) {
        val op = ops[id] ?: return
        op.status = "expired"
        takenNumbers -= "${op.body["notebook_id"]}#${op.body["page_number"]}"
    }

    private fun operationJson(op: Op): JsonObject = buildJsonObject {
        put("operation_id", op.id)
        put("kind", if (op.body["page_id"] == null) "upload" else "replacement")
        put("status", op.status)
        put("client_label", "android")
        op.body["notebook_id"]?.let { put("notebook_id", it) }
        put("page_id", op.pageId)
        put("processing_mode", op.body["processing_mode"] ?: "immediate")
        if (op.accepted) put("upload_accepted_at", "2026-10-14T12:00:00.000000Z") else put("upload_accepted_at", JsonNull)
        op.body["retry_of_operation_id"]?.let { put("parent_operation_id", it) }
    }

    private fun session(op: Op): String {
        val upload: JsonElement = if (op.status == "awaiting_upload" && !op.accepted) buildJsonObject {
            put("method", "PUT")
            put("url", "http://storage.test/staging/${op.sessionId}?v=${op.urlVersion}")
            put("headers", buildJsonObject { put("content-type", op.body.getValue("content_type")); put("x-amz-checksum-sha256", "abc") })
            put("expires_in_seconds", 21600)
        } else JsonNull
        return buildJsonObject {
            put("upload_session_id", op.sessionId)
            put("status", op.status)
            put("expires_at", "2026-10-15T12:00:00Z")
            put("upload", upload)
            put("operation", operationJson(op))
        }.toString()
    }
}

/** Records started transfers; the test finishes them. */
class FakeTransfers : UploadTransfers {
    data class Started(val itemId: String, val url: String, val method: String, val headers: Map<String, String>)

    val started = mutableListOf<Started>()
    val active = mutableSetOf<String>()

    override suspend fun start(itemId: String, url: String, method: String, headers: Map<String, String>, file: File) {
        started += Started(itemId, url, method, headers)
        active += itemId
    }

    override suspend fun activeItemIds(): Set<String> = active.toSet()

    /** Deliver the newest transfer per item to the server and the engine. */
    suspend fun finishAll(server: FakeServer, engine: UploadEngine) {
        val latest = started.filter { it.itemId in active }.associateBy { it.itemId }
        for ((id, transfer) in latest.toSortedMap()) {
            active -= id
            engine.transferFinished(TransferResult(id, server.receiveUpload(transfer.url)))
        }
    }

    /** The process was killed: transfers are gone and results never arrive. */
    fun forgetAll() = active.clear()
}

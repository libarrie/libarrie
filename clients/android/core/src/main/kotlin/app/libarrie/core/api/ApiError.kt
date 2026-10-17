package app.libarrie.core.api

import kotlinx.serialization.Serializable
import kotlinx.serialization.json.JsonElement
import kotlinx.serialization.json.JsonPrimitive

/**
 * A failed API call. [code] is the server's stable error code
 * (`page_number_conflict`, `processing_limit_reached`, ...) or a local one
 * (`network`, `unauthenticated`, `invalid_response`).
 */
class ApiError(
    val status: Int,
    val code: String,
    override val message: String,
    val retryAfter: Int? = null,
    val details: Map<String, String> = emptyMap(),
) : Exception(message) {
    /** No response arrived; whether the server acted is unknown. */
    val isNetwork get() = code == "network"

    /** Worth retrying later without user action. */
    val isTransient get() = isNetwork || status in setOf(429, 500, 502, 503, 504)

    override fun toString() = "ApiError($status, $code)"

    companion object {
        fun network(cause: Throwable? = null) =
            ApiError(0, "network", "The connection failed. Check your network and try again.").also { if (cause != null) it.initCause(cause) }

        fun unauthenticated() = ApiError(401, "unauthenticated", "Your sign-in expired. Sign in again to continue.")

        @Serializable private data class Body(val error: Inner) {
            @Serializable data class Inner(val code: String, val message: String, val details: Map<String, JsonElement>? = null)
        }

        fun decode(status: Int, body: String, retryAfter: Int?): ApiError {
            val parsed = runCatching { ApiJson.decodeFromString<Body>(body) }.getOrNull()
                ?: return ApiError(status, "http_$status", "The server returned an error ($status).", retryAfter)
            val details = parsed.error.details.orEmpty().mapNotNull { (key, value) ->
                (value as? JsonPrimitive)?.let { key to it.content }
            }.toMap()
            return ApiError(status, parsed.error.code, parsed.error.message, retryAfter, details)
        }
    }
}

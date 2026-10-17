package app.libarrie.core

import app.libarrie.core.api.AccessTokenProvider
import app.libarrie.core.api.ApiError
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.int
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.jsonPrimitive
import okhttp3.Interceptor
import okhttp3.MediaType.Companion.toMediaType
import okhttp3.OkHttpClient
import okhttp3.Protocol
import okhttp3.Request
import okhttp3.Response
import okhttp3.ResponseBody.Companion.toResponseBody
import okio.Buffer
import java.io.File
import java.nio.file.Files

/** A server-generated fixture: (status, body). */
fun fixture(name: String): Pair<Int, String> {
    val dir = System.getProperty("libarrie.fixtures") ?: error("libarrie.fixtures not set")
    val doc = Json.parseToJsonElement(File(dir, "$name.json").readText()).jsonObject
    return doc.getValue("status").jsonPrimitive.int to doc.getValue("body").jsonPrimitive.content
}

fun bodyText(request: Request): String = request.body?.let { b -> Buffer().also { b.writeTo(it) }.readUtf8() } ?: ""

fun errorBody(code: String, message: String = "refused") =
    """{"error":{"code":"$code","message":"$message","details":{},"request_id":"test"}}"""

/** An OkHttp client answered entirely by [handler]: no sockets. */
fun scriptedClient(handler: (Request) -> Pair<Int, String>): OkHttpClient = OkHttpClient.Builder()
    .addInterceptor(Interceptor { chain ->
        val request = chain.request()
        val (status, body) = handler(request)
        Response.Builder().request(request).protocol(Protocol.HTTP_1_1).code(status).message("test")
            .body(body.toResponseBody("application/json".toMediaType())).build()
    })
    .build()

class StaticTokens(private val token: String = "token") : AccessTokenProvider {
    override suspend fun accessToken() = token
    override suspend fun refreshAfterRejection(token: String): String = throw ApiError.unauthenticated()
}

fun tempDir(): File = Files.createTempDirectory("libarrie-test").toFile()

class Clock(var now: Long = 1_800_000_000L) {
    fun advance(seconds: Long) { now += seconds }
}

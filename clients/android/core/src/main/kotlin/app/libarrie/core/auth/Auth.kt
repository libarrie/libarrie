package app.libarrie.core.auth

import app.libarrie.core.api.ApiError
import app.libarrie.core.api.ApiJson
import app.libarrie.core.api.ClientConfiguration
import app.libarrie.core.api.OidcConfiguration
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext
import kotlinx.serialization.Serializable
import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.JsonElement
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.contentOrNull
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.jsonPrimitive
import kotlinx.serialization.json.longOrNull
import okhttp3.FormBody
import okhttp3.HttpUrl.Companion.toHttpUrl
import okhttp3.OkHttpClient
import okhttp3.Request
import java.io.IOException
import java.security.MessageDigest
import java.security.SecureRandom
import java.util.Base64

internal fun base64url(bytes: ByteArray): String = Base64.getUrlEncoder().withoutPadding().encodeToString(bytes)

internal fun randomToken(bytes: Int = 32): String = base64url(ByteArray(bytes).also { SecureRandom().nextBytes(it) })

sealed class SignInError(message: String) : Exception(message) {
    object Cancelled : SignInError("Sign-in was cancelled.")
    object NotConfigured : SignInError("This server does not support sign-in from the app yet.")
    object UnexpectedRedirect : SignInError("Sign-in could not be completed. Please try again.")
    object StateMismatch : SignInError("Sign-in could not be completed. Please try again.")
    object MissingCode : SignInError("Sign-in could not be completed. Please try again.")
    class Provider(val code: String) : SignInError("The sign-in service reported an error ($code).")
    class TokenEndpoint(val reason: String) : SignInError("Sign-in could not be completed ($reason).")
    class InvalidIdToken(val reason: String) : SignInError("The sign-in response could not be verified ($reason).")
}

/**
 * One authorization attempt (section 6: Authorization Code + PKCE in the
 * system browser). Verifier, state and nonce stay in memory (or in the
 * activity's saved state) until the redirect returns.
 *
 * @param reauthenticate force a fresh sign-in (`prompt=login`, `max_age=0`)
 *   before account deletion or permanent purge.
 */
class AuthorizationRequest(
    configuration: OidcConfiguration,
    reauthenticate: Boolean = false,
    val verifier: String = randomToken(48),
    val state: String = randomToken(24),
    val nonce: String = randomToken(24),
) {
    val redirectUri = configuration.redirectUri
    val url: String = configuration.authorizationEndpoint.toHttpUrl().newBuilder().apply {
        addQueryParameter("response_type", "code")
        addQueryParameter("client_id", configuration.clientId)
        addQueryParameter("redirect_uri", configuration.redirectUri)
        addQueryParameter("scope", configuration.scopes.joinToString(" "))
        addQueryParameter("state", state)
        addQueryParameter("nonce", nonce)
        addQueryParameter("code_challenge", base64url(MessageDigest.getInstance("SHA-256").digest(verifier.toByteArray())))
        addQueryParameter("code_challenge_method", "S256")
        if (reauthenticate) {
            addQueryParameter("prompt", "login")
            addQueryParameter("max_age", "0")
        }
    }.build().toString()

    /** Extract the code from the redirect, checking state and errors. */
    fun code(callback: String): String {
        if (!callback.startsWith(redirectUri)) throw SignInError.UnexpectedRedirect
        val query = callback.substringAfter('?', "").split('&').filter { it.contains('=') }.associate {
            val (k, v) = it.split('=', limit = 2)
            java.net.URLDecoder.decode(k, "UTF-8") to java.net.URLDecoder.decode(v, "UTF-8")
        }
        query["error"]?.let { throw if (it == "access_denied") SignInError.Cancelled else SignInError.Provider(it) }
        if (query["state"] != state) throw SignInError.StateMismatch
        return query["code"]?.takeIf { it.isNotEmpty() } ?: throw SignInError.MissingCode
    }
}

@Serializable data class IdTokenClaims(val issuer: String, val subject: String, val name: String? = null, val authTime: Long? = null)

/** What the app keeps for a signed-in user (encrypted with an Android Keystore key). */
@Serializable
data class Credentials(val accessToken: String, val refreshToken: String? = null, val expiresAtEpochSeconds: Long, val claims: IdTokenClaims) {
    /** Sign-in within the last five minutes, required before account deletion and purge. */
    fun isRecentSignIn(nowSeconds: Long = System.currentTimeMillis() / 1000): Boolean =
        claims.authTime?.let { nowSeconds - it <= 300 } ?: false
}

@Serializable
data class StoredSession(
    val serverUrl: String,
    val configuration: ClientConfiguration,
    val credentials: Credentials,
    /** Filled after the first `/v1/me`; binds local captures to the account. */
    val accountId: String? = null,
    val displayName: String? = null,
)

interface SessionStore {
    fun load(): StoredSession?
    fun save(session: StoredSession)
    fun clear()
}

class MemorySessionStore(private var session: StoredSession? = null) : SessionStore {
    @Synchronized override fun load() = session
    @Synchronized override fun save(session: StoredSession) { this.session = session }
    @Synchronized override fun clear() { session = null }
}

@Serializable private data class TokenResponse(val accessToken: String, val idToken: String? = null, val refreshToken: String? = null, val expiresIn: Long? = null)

/** Token endpoint calls (public client: no secret). */
class TokenClient(private val configuration: OidcConfiguration, private val http: OkHttpClient, private val now: () -> Long = { System.currentTimeMillis() / 1000 }) {

    suspend fun exchange(code: String, request: AuthorizationRequest): Credentials {
        val response = post(mapOf(
            "grant_type" to "authorization_code",
            "code" to code,
            "code_verifier" to request.verifier,
            "client_id" to configuration.clientId,
            "redirect_uri" to request.redirectUri,
        ))
        val idToken = response.idToken ?: throw SignInError.InvalidIdToken("missing ID token")
        return credentials(response, validate(idToken, request.nonce), null)
    }

    suspend fun refresh(previous: Credentials): Credentials {
        val refreshToken = previous.refreshToken ?: throw ApiError.unauthenticated()
        val response = post(mapOf("grant_type" to "refresh_token", "refresh_token" to refreshToken, "client_id" to configuration.clientId))
        // Keep the original identity and sign-in time; providers may omit the ID token.
        var claims = previous.claims
        response.idToken?.let { token ->
            runCatching { validate(token, null) }.getOrNull()?.takeIf { it.subject == claims.subject }?.let { claims = claims.copy(name = it.name ?: claims.name) }
        }
        return credentials(response, claims, refreshToken)
    }

    private fun credentials(response: TokenResponse, claims: IdTokenClaims, previousRefresh: String?) = Credentials(
        accessToken = response.accessToken,
        refreshToken = response.refreshToken ?: previousRefresh,
        expiresAtEpochSeconds = now() + (response.expiresIn ?: 300),
        claims = claims,
    )

    private suspend fun post(form: Map<String, String>): TokenResponse = withContext(Dispatchers.IO) {
        val body = FormBody.Builder().apply { form.toSortedMap().forEach { (k, v) -> add(k, v) } }.build()
        val request = Request.Builder().url(configuration.tokenEndpoint).post(body).header("Accept", "application/json").build()
        val (status, text) = try {
            http.newCall(request).execute().use { it.code to it.body.string() }
        } catch (e: IOException) {
            throw ApiError.network(e)
        }
        if (status != 200) {
            val reason = runCatching { ApiJson.parseToJsonElement(text).jsonObject["error"]?.jsonPrimitive?.content }.getOrNull() ?: "HTTP $status"
            if (reason == "invalid_grant") throw ApiError.unauthenticated()
            throw SignInError.TokenEndpoint(reason)
        }
        runCatching { ApiJson.decodeFromString<TokenResponse>(text) }.getOrElse { throw SignInError.TokenEndpoint("unreadable response") }
    }

    /**
     * Checks issuer, audience, expiry and nonce. The ID token comes straight
     * from the token endpoint over TLS in the code flow, which OIDC Core
     * 3.1.3.7 accepts in place of a client-side signature check; the API
     * verifies every access token's signature itself.
     */
    fun validate(idToken: String, nonce: String?): IdTokenClaims {
        val parts = idToken.split('.')
        if (parts.size != 3) throw SignInError.InvalidIdToken("malformed")
        val payload = runCatching { String(Base64.getUrlDecoder().decode(parts[1].trimEnd('='))) }.getOrElse { throw SignInError.InvalidIdToken("malformed") }
        val claims = runCatching { ApiJson.parseToJsonElement(payload).jsonObject }.getOrElse { throw SignInError.InvalidIdToken("unreadable claims") }
        fun text(key: String) = (claims[key] as? JsonPrimitive)?.contentOrNull
        val audiences: List<String> = when (val aud: JsonElement? = claims["aud"]) {
            is JsonArray -> aud.mapNotNull { (it as? JsonPrimitive)?.contentOrNull }
            is JsonPrimitive -> listOfNotNull(aud.contentOrNull)
            else -> emptyList()
        }
        if (text("iss") != configuration.issuer) throw SignInError.InvalidIdToken("issuer")
        if (configuration.clientId !in audiences) throw SignInError.InvalidIdToken("audience")
        val exp = (claims["exp"] as? JsonPrimitive)?.longOrNull ?: throw SignInError.InvalidIdToken("expiry")
        if (exp < now() - 60) throw SignInError.InvalidIdToken("expired")
        if (nonce != null && text("nonce") != nonce) throw SignInError.InvalidIdToken("nonce")
        val subject = text("sub") ?: throw SignInError.InvalidIdToken("subject")
        return IdTokenClaims(text("iss")!!, subject, text("name"), (claims["auth_time"] as? JsonPrimitive)?.longOrNull)
    }
}

package app.libarrie.core

import app.libarrie.core.api.AccessTokenProvider
import app.libarrie.core.api.ApiClient
import app.libarrie.core.api.ClientConfiguration
import app.libarrie.core.api.OidcConfiguration
import app.libarrie.core.api.UploadPolicy
import app.libarrie.core.auth.AuthorizationRequest
import app.libarrie.core.auth.Credentials
import app.libarrie.core.auth.IdTokenClaims
import app.libarrie.core.auth.MemorySessionStore
import app.libarrie.core.auth.SessionManager
import app.libarrie.core.auth.SignInError
import app.libarrie.core.auth.StoredSession
import app.libarrie.core.auth.TokenClient
import kotlinx.coroutines.async
import kotlinx.coroutines.awaitAll
import kotlinx.coroutines.runBlocking
import okhttp3.HttpUrl.Companion.toHttpUrl
import java.util.Base64
import java.util.concurrent.atomic.AtomicInteger
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFailsWith
import kotlin.test.assertNotEquals
import kotlin.test.assertNull
import kotlin.test.assertTrue

val oidc = OidcConfiguration(
    issuer = "http://localhost:8080/dev-issuer",
    authorizationEndpoint = "http://localhost:8080/dev-issuer/authorize",
    tokenEndpoint = "http://localhost:8080/dev-issuer/token",
    clientId = "libarrie-native",
    redirectUri = "libarrie://oauth/callback",
    scopes = listOf("openid", "profile", "offline_access"),
)

fun jwt(claims: String): String {
    val enc = Base64.getUrlEncoder().withoutPadding()
    return enc.encodeToString("""{"alg":"HS256"}""".toByteArray()) + "." + enc.encodeToString(claims.toByteArray()) + ".sig"
}

class AuthTest {
    @Test fun authorizationUrlUsesPkce() {
        val request = AuthorizationRequest(oidc)
        val url = request.url.toHttpUrl()
        assertEquals("code", url.queryParameter("response_type"))
        assertEquals("S256", url.queryParameter("code_challenge_method"))
        assertNotEquals(request.verifier, url.queryParameter("code_challenge"))
        assertEquals(request.state, url.queryParameter("state"))
        assertNull(url.queryParameter("prompt"))
        val reauth = AuthorizationRequest(oidc, reauthenticate = true).url.toHttpUrl()
        assertEquals("login", reauth.queryParameter("prompt"))
        assertEquals("0", reauth.queryParameter("max_age"))
    }

    @Test fun callbackChecksStateAndErrors() {
        val request = AuthorizationRequest(oidc)
        assertEquals("abc", request.code("libarrie://oauth/callback?code=abc&state=${request.state}"))
        assertFailsWith<SignInError.StateMismatch> { request.code("libarrie://oauth/callback?code=abc&state=other") }
        assertFailsWith<SignInError.Cancelled> { request.code("libarrie://oauth/callback?error=access_denied") }
        assertFailsWith<SignInError.UnexpectedRedirect> { request.code("evil://oauth/callback?code=abc&state=${request.state}") }
    }

    @Test fun exchangeValidatesTheIdToken() = runBlocking {
        val request = AuthorizationRequest(oidc)
        val now = System.currentTimeMillis() / 1000
        var nonce = request.nonce
        var audience = "libarrie-native"
        val http = scriptedClient { req ->
            val form = bodyText(req)
            assertTrue("grant_type=authorization_code" in form)
            assertTrue("code_verifier=" in form)
            val id = jwt("""{"iss":"${oidc.issuer}","aud":"$audience","sub":"user-1","name":"Ada","nonce":"$nonce","auth_time":$now,"exp":${now + 600}}""")
            200 to """{"access_token":"access","id_token":"$id","refresh_token":"refresh","expires_in":600}"""
        }
        val client = TokenClient(oidc, http)
        val credentials = client.exchange("code", request)
        assertEquals("access", credentials.accessToken)
        assertEquals("refresh", credentials.refreshToken)
        assertEquals("user-1", credentials.claims.subject)
        assertTrue(credentials.isRecentSignIn())
        nonce = "replayed"
        assertEquals("nonce", assertFailsWith<SignInError.InvalidIdToken> { client.exchange("code", request) }.reason)
        nonce = request.nonce
        audience = "someone-else"
        assertEquals("audience", assertFailsWith<SignInError.InvalidIdToken> { client.exchange("code", request) }.reason)
    }

    @Test fun sessionRefreshesOnceForConcurrentCallers() = runBlocking {
        val clock = Clock()
        val refreshes = AtomicInteger()
        val http = scriptedClient { req ->
            assertTrue("grant_type=refresh_token" in bodyText(req))
            refreshes.incrementAndGet()
            Thread.sleep(50)
            200 to """{"access_token":"fresh","refresh_token":"rotated","expires_in":600}"""
        }
        val store = MemorySessionStore(StoredSession(
            serverUrl = "http://localhost:8080",
            configuration = ClientConfiguration(oidc, UploadPolicy("sha256", 1, emptyList())),
            credentials = Credentials("stale", "refresh", clock.now + 30, IdTokenClaims(oidc.issuer, "u", null, 1)),
            accountId = "a",
        ))
        val manager = SessionManager(store, http) { clock.now }
        val tokens = (1..5).map { async { manager.accessToken() } }.awaitAll()
        assertEquals(List(5) { "fresh" }, tokens)
        assertEquals(1, refreshes.get())
        val saved = store.load()!!
        assertEquals("rotated", saved.credentials.refreshToken)
        assertEquals(1L, saved.credentials.claims.authTime)
    }

    @Test fun apiRetriesOnceAfterRefreshingOn401AndSendsNoCookies() = runBlocking {
        val refreshed = AtomicInteger()
        val tokens = object : AccessTokenProvider {
            override suspend fun accessToken() = "old"
            override suspend fun refreshAfterRejection(token: String): String { refreshed.incrementAndGet(); return "new" }
        }
        val calls = AtomicInteger()
        val http = scriptedClient { req ->
            calls.incrementAndGet()
            assertNull(req.header("Cookie"))
            if (req.header("Authorization") == "Bearer new") fixture("me") else 401 to errorBody("authentication_required")
        }
        val me = ApiClient("http://localhost:8080", http, tokens).me()
        assertEquals("active", me.account.status)
        assertEquals(1, refreshed.get())
        assertEquals(2, calls.get())
    }

    @Test fun reauthenticationRequiredIsSurfacedNotRefreshed() = runBlocking {
        val tokens = object : AccessTokenProvider {
            override suspend fun accessToken() = "t"
            override suspend fun refreshAfterRejection(token: String): String = error("must not refresh")
        }
        val http = scriptedClient { 401 to errorBody("reauthentication_required", "Sign in again to confirm this action.") }
        val error = assertFailsWith<app.libarrie.core.api.ApiError> { ApiClient("http://x", http, tokens).purge(all = true) }
        assertEquals("reauthentication_required", error.code)
    }
}

package app.libarrie.core.auth

import app.libarrie.core.api.AccessTokenProvider
import app.libarrie.core.api.ApiError
import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock
import okhttp3.OkHttpClient

/**
 * Owns the signed-in session: hands out access tokens, refreshes them a
 * minute before expiry or after a 401 (one refresh at a time), and persists
 * rotated refresh tokens.
 */
class SessionManager(
    private val store: SessionStore,
    private val http: OkHttpClient,
    private val now: () -> Long = { System.currentTimeMillis() / 1000 },
) : AccessTokenProvider {
    private val lock = Mutex()
    @Volatile private var session: StoredSession? = runCatching { store.load() }.getOrNull()
    private var refreshing: CompletableDeferred<Credentials>? = null

    val current: StoredSession? get() = session

    suspend fun begin(session: StoredSession) = lock.withLock {
        store.save(session)
        this.session = session
    }

    suspend fun bind(accountId: String, displayName: String) = lock.withLock {
        session = session?.copy(accountId = accountId, displayName = displayName)?.also { store.save(it) }
    }

    suspend fun replaceCredentials(credentials: Credentials) = lock.withLock {
        session = session?.copy(credentials = credentials)?.also { store.save(it) }
    }

    suspend fun signOut() = lock.withLock {
        refreshing?.cancel()
        refreshing = null
        session = null
        store.clear()
    }

    override suspend fun accessToken(): String {
        val current = session ?: throw ApiError.unauthenticated()
        if (current.credentials.expiresAtEpochSeconds - now() > 60) return current.credentials.accessToken
        return refresh().accessToken
    }

    override suspend fun refreshAfterRejection(token: String): String {
        val current = session ?: throw ApiError.unauthenticated()
        // Another caller already refreshed past the rejected token.
        if (current.credentials.accessToken != token) return current.credentials.accessToken
        return refresh().accessToken
    }

    private suspend fun refresh(): Credentials {
        val (deferred, owner) = lock.withLock {
            refreshing?.let { return@withLock it to false }
            CompletableDeferred<Credentials>().also { refreshing = it } to true
        }
        if (!owner) return deferred.await()
        val previous = session
        try {
            val oidc = previous?.configuration?.oidc ?: throw ApiError.unauthenticated()
            val fresh = TokenClient(oidc, http, now).refresh(previous.credentials)
            lock.withLock {
                // Signed out (or switched) meanwhile: drop the result.
                if (session?.credentials != previous.credentials) throw ApiError.unauthenticated()
                session = session?.copy(credentials = fresh)?.also { store.save(it) }
            }
            deferred.complete(fresh)
            return fresh
        } catch (e: Exception) {
            val error = if (e is ApiError && e.isNetwork) e else ApiError.unauthenticated()
            deferred.completeExceptionally(error)
            throw error
        } finally {
            lock.withLock { if (refreshing === deferred) refreshing = null }
        }
    }
}

package app.libarrie.android

import android.content.Context
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.setValue
import androidx.core.content.edit
import app.libarrie.android.data.ImagePreparer
import app.libarrie.android.data.KeystoreSessionStore
import app.libarrie.android.data.WorkManagerTransfers
import app.libarrie.core.api.ApiClient
import app.libarrie.core.api.ApiError
import app.libarrie.core.api.ClientConfiguration
import app.libarrie.core.api.Me
import app.libarrie.core.api.Notebook
import app.libarrie.core.api.OidcConfiguration
import app.libarrie.core.api.Page
import app.libarrie.core.api.defaultHttpClient
import app.libarrie.core.auth.AuthorizationRequest
import app.libarrie.core.auth.Credentials
import app.libarrie.core.auth.SessionManager
import app.libarrie.core.auth.SignInError
import app.libarrie.core.auth.StoredSession
import app.libarrie.core.auth.TokenClient
import app.libarrie.core.cache.ImageCache
import app.libarrie.core.queue.CaptureItem
import app.libarrie.core.queue.CaptureState
import app.libarrie.core.queue.CaptureStore
import app.libarrie.core.queue.DeferredDecision
import app.libarrie.core.queue.TransferResult
import app.libarrie.core.queue.UploadEngine
import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.launch
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock
import kotlinx.coroutines.withContext
import okhttp3.HttpUrl.Companion.toHttpUrlOrNull
import java.io.File
import java.util.UUID

enum class ThemePreference { System, Light, Dark }

/** User preferences (backed-up `settings.xml`; nothing sensitive). */
class Settings(context: Context) {
    private val prefs = context.getSharedPreferences("settings", Context.MODE_PRIVATE)
    var serverAddress by mutableStateOf(prefs.getString("serverAddress", "http://localhost:8080")!!)
    var theme by mutableStateOf(ThemePreference.valueOf(prefs.getString("theme", "System")!!))
    /** Keep GPS location in uploaded photos (off by default, section 6). */
    var keepLocation by mutableStateOf(prefs.getBoolean("keepLocation", false))
    /** Include photos not yet backed up by Libarrie in device backups. */
    var backUpPendingCaptures by mutableStateOf(prefs.getBoolean("backUpPendingCaptures", true))

    fun save() = prefs.edit {
        putString("serverAddress", serverAddress)
        putString("theme", theme.name)
        putBoolean("keepLocation", keepLocation)
        putBoolean("backUpPendingCaptures", backUpPendingCaptures)
    }
}

/** Services for one signed-in account. */
class AccountServices(
    val api: ApiClient,
    val engine: UploadEngine,
    val images: ImageCache,
    val configuration: ClientConfiguration,
    val serverUrl: String,
    val accountId: String,
)

enum class Phase { Starting, SignedOut, SignedIn, AccountClosing, AccountPurged }

/**
 * The app's root state: sign-in, the signed-in account and the capture
 * queue. Application-scoped, so uploads continue from WorkManager after the
 * activity is gone.
 */
class AppContainer(private val context: Context) {
    val settings = Settings(context)
    val http = defaultHttpClient()
    val sessions = SessionManager(KeystoreSessionStore(File(context.noBackupFilesDir, "session.bin")), http)
    private val transfers = WorkManagerTransfers(context)
    private val imageRoot = File(context.cacheDir, "images")
    val scope = CoroutineScope(SupervisorJob() + Dispatchers.Main.immediate)
    private val engineLock = Mutex()

    var store: CaptureStore = CaptureStore(captureDirectory(settings.backUpPendingCaptures))
        private set

    var phase by mutableStateOf(Phase.Starting)
    var signInError by mutableStateOf<String?>(null)
    var working by mutableStateOf(false)
    var me by mutableStateOf<Me?>(null)
        private set
    var services by mutableStateOf<AccountServices?>(null)
        private set
    /** Every capture on this device (all accounts). */
    var queue by mutableStateOf<List<CaptureItem>>(emptyList())
        private set
    var uploadsNeedSignIn by mutableStateOf(false)
        private set

    /** Set by the activity: opens a URL in a Custom Tab. */
    var openBrowser: ((String) -> Unit)? = null
    private var pending: Pair<AuthorizationRequest, CompletableDeferred<String>>? = null

    /** Pending captures live under files/ (backed up) or no_backup/ (device-only). */
    private fun captureDirectory(backedUp: Boolean) =
        File(if (backedUp) context.filesDir else context.noBackupFilesDir, "captures")

    // Session -----------------------------------------------------------------------------------

    fun start() = scope.launch {
        if (phase != Phase.Starting) return@launch
        refreshQueue()
        val session = sessions.current
        if (session != null) activate(session) else phase = Phase.SignedOut
    }

    fun signIn() = scope.launch {
        signInError = null
        working = true
        try {
            val server = normalizedServer(settings.serverAddress)
            settings.save()
            val configuration = ApiClient.clientConfiguration(server, http)
            val oidc = configuration.oidc ?: throw SignInError.NotConfigured
            val credentials = authorize(oidc, reauthenticate = false)
            val previous = sessions.current?.accountId
            val session = StoredSession(server, configuration, credentials, null, credentials.claims.name)
            sessions.begin(session)
            if (previous != null) ImageCache.clearAll(imageRoot)
            activate(session)
        } catch (e: SignInError.Cancelled) {
            // The user closed the sign-in page.
        } catch (e: Exception) {
            signInError = describe(e)
        } finally {
            working = false
        }
    }

    /** A fresh sign-in for the same identity, required before deletion and purge. */
    suspend fun reauthenticate() {
        val session = sessions.current ?: throw ApiError.unauthenticated()
        val oidc = session.configuration.oidc ?: throw ApiError.unauthenticated()
        val credentials = authorize(oidc, reauthenticate = true)
        if (credentials.claims.subject != session.credentials.claims.subject || credentials.claims.issuer != session.credentials.claims.issuer) {
            throw SignInError.InvalidIdToken("signed in as a different person")
        }
        sessions.replaceCredentials(credentials)
    }

    fun hasRecentSignIn() = sessions.current?.credentials?.isRecentSignIn() ?: false

    private suspend fun authorize(oidc: OidcConfiguration, reauthenticate: Boolean): Credentials {
        val request = AuthorizationRequest(oidc, reauthenticate)
        val callback = CompletableDeferred<String>()
        pending?.second?.cancel()
        pending = request to callback
        val open = openBrowser ?: throw SignInError.Cancelled
        open(request.url)
        val redirect = try { callback.await() } catch (e: kotlinx.coroutines.CancellationException) { throw SignInError.Cancelled }
        val code = request.code(redirect)
        return TokenClient(oidc, http).exchange(code, request)
    }

    /** The redirect from the browser (MainActivity). */
    fun handleRedirect(uri: String) {
        val (_, callback) = pending ?: return
        pending = null
        callback.complete(uri)
    }

    /** The user came back from the browser without finishing. */
    fun abandonSignIn() {
        pending?.second?.cancel()
        pending = null
    }

    val signInPending get() = pending != null

    private fun normalizedServer(text: String): String {
        var trimmed = text.trim()
        if (!trimmed.contains("://")) trimmed = "https://$trimmed"
        trimmed = trimmed.trimEnd('/')
        val url = trimmed.toHttpUrlOrNull() ?: throw ApiError(0, "invalid_address", "Enter the address of your Libarrie server.")
        return url.toString().trimEnd('/')
    }

    private suspend fun activate(session: StoredSession) {
        val api = ApiClient(session.serverUrl, http, sessions)
        try {
            val me = api.me()
            if (session.accountId != null && session.accountId != me.account.id) ImageCache.clearAll(imageRoot)
            sessions.bind(me.account.id, me.user.displayName)
            this.me = me
            services = buildServices(api, session, me.account.id)
            phase = Phase.SignedIn
            runQueue()
        } catch (e: ApiError) {
            when (e.code) {
                "account_closing" -> { services = buildServices(api, session, session.accountId ?: ""); phase = Phase.AccountClosing }
                "account_closed" -> { services = null; phase = Phase.AccountPurged }
                "unauthenticated" -> { phase = Phase.SignedOut; signInError = e.message }
                else -> {
                    // Offline at launch: stay signed in with what we know.
                    val accountId = session.accountId
                    if (accountId != null) {
                        services = buildServices(api, session, accountId)
                        phase = Phase.SignedIn
                    } else {
                        phase = Phase.SignedOut
                        signInError = e.message
                    }
                }
            }
        }
    }

    private fun buildServices(api: ApiClient, session: StoredSession, accountId: String) = AccountServices(
        api = api,
        engine = UploadEngine(api, store, transfers, accountId, session.serverUrl, session.configuration.uploads.integrity),
        images = ImageCache(api, accountId.ifEmpty { "none" }, imageRoot),
        configuration = session.configuration,
        serverUrl = session.serverUrl,
        accountId = accountId,
    )

    /** Explicitly start a new account after the old one was purged. */
    fun startNewAccount() = scope.launch {
        val session = sessions.current ?: return@launch
        try {
            ApiClient(session.serverUrl, http, sessions).createAccountAfterPurge()
            activate(session)
        } catch (e: Exception) {
            signInError = describe(e)
        }
    }

    /** Captures stay on this device, bound to their account, until it signs in again. */
    fun signOut() = scope.launch {
        sessions.signOut()
        ImageCache.clearAll(imageRoot)
        services = null
        me = null
        phase = Phase.SignedOut
    }

    // Queue (also driven from WorkManager) ---------------------------------------------------------------

    /** Lazily rebuilds the engine when WorkManager starts the process without the UI. */
    private suspend fun engine(): UploadEngine? = engineLock.withLock {
        services?.engine ?: run {
            val session = sessions.current ?: return@withLock null
            val accountId = session.accountId ?: return@withLock null
            val api = ApiClient(session.serverUrl, http, sessions)
            buildServices(api, session, accountId).also { services = it }.engine
        }
    }

    suspend fun runQueue() {
        engine()?.run()
        refreshQueue()
    }

    suspend fun transferFinished(result: TransferResult) {
        engine()?.transferFinished(result)
        refreshQueue()
    }

    suspend fun refreshQueue() {
        val items = store.items()
        val needsSignIn = services?.engine?.needsSignIn ?: false
        withContext(Dispatchers.Main) {
            queue = items
            uploadsNeedSignIn = needsSignIn
        }
    }

    val accountQueue: List<CaptureItem>
        get() = services?.let { s -> queue.filter { it.accountId == s.accountId && it.serverUrl == s.serverUrl } } ?: emptyList()

    val otherAccountsQueue: List<CaptureItem>
        get() = services?.let { s -> queue.filter { it.accountId != s.accountId || it.serverUrl != s.serverUrl } } ?: queue

    private fun preparer() = ImagePreparer(
        keepLocation = settings.keepLocation,
        maxBytes = services?.configuration?.uploads?.maxBytes ?: 20_000_000,
        scratch = context.cacheDir,
    )

    /** Save photos immediately ("saved on this device"), before review. Returns problems. */
    suspend fun capture(photos: List<ByteArray>, batch: String): List<String> {
        val s = services ?: return listOf("Sign in to add pages.")
        val existing = queue.count { it.batchId == batch }
        val problems = mutableListOf<String>()
        withContext(Dispatchers.Default) {
            photos.forEachIndexed { offset, bytes ->
                try {
                    store.capture(preparer().prepare(bytes), batch, existing + offset, s.accountId, s.serverUrl)
                } catch (e: Exception) {
                    problems += describe(e)
                }
            }
        }
        refreshQueue()
        return problems
    }

    /** Finish review: assign notebook and numbers in the reviewed order, and queue them. */
    suspend fun commit(order: List<String>, notebook: Notebook, startPage: Int) {
        order.forEachIndexed { index, id ->
            store.update(id) {
                it.copy(notebookId = notebook.id, notebookName = notebook.name, pageNumber = startPage + index, sequence = index, state = CaptureState.Ready)
            }
        }
        runQueue()
    }

    /** Queue a replacement scan (always processed immediately). */
    suspend fun replace(page: Page, photo: ByteArray) {
        val s = services ?: throw ApiError.unauthenticated()
        val prepared = withContext(Dispatchers.Default) { preparer().prepare(photo) }
        val item = store.capture(prepared, UUID.randomUUID().toString(), 0, s.accountId, s.serverUrl)
        store.update(item.id) {
            it.copy(
                replacesPageId = page.id, replacesContentVersion = page.contentVersion, notebookId = page.notebook.id,
                notebookName = page.notebook.name, pageNumber = page.pageNumber, state = CaptureState.Ready,
            )
        }
        runQueue()
    }

    suspend fun discard(id: String) { store.remove(id); refreshQueue() }
    suspend fun cancel(id: String) { (services?.engine?.cancel(id)) ?: store.remove(id); refreshQueue() }
    suspend fun retry(id: String) { services?.engine?.retryNow(id); refreshQueue() }
    suspend fun renumber(id: String, number: Int) { services?.engine?.renumber(id, number); refreshQueue() }
    suspend fun decide(decision: DeferredDecision, batch: String) { services?.engine?.decide(decision, batch); refreshQueue() }
    suspend fun removeLocalCopy(id: String) { store.removeFile(id); refreshQueue() }
    fun fileFor(item: CaptureItem): File? = store.fileFor(item)

    /** Move pending captures into or out of device backups. */
    suspend fun setBackUpPendingCaptures(included: Boolean) {
        if (included == settings.backUpPendingCaptures) return
        val from = captureDirectory(settings.backUpPendingCaptures)
        val to = captureDirectory(included)
        engineLock.withLock {
            withContext(Dispatchers.IO) {
                to.parentFile?.mkdirs()
                if (from.exists() && !to.exists()) from.renameTo(to)
            }
            settings.backUpPendingCaptures = included
            settings.save()
            store = CaptureStore(to)
            val current = services
            val session = sessions.current
            if (current != null && session != null) services = buildServices(current.api, session, current.accountId)
        }
        refreshQueue()
    }

    companion object {
        fun describe(e: Throwable): String = e.message ?: "Something went wrong. Please try again."
    }
}

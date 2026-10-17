package app.libarrie.core.cache

import app.libarrie.core.api.ApiClient
import app.libarrie.core.api.Page
import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock
import kotlinx.coroutines.withContext
import java.io.File

/**
 * Thumbnails and previews on disk, keyed by account and immutable object ID
 * (never by URL), so they survive restarts and show offline. Kept in the
 * cache directory (never backed up) and cleared on sign-out or account
 * switch (section 6).
 */
class ImageCache(private val api: ApiClient, private val accountId: String, private val root: File) {
    enum class Variant(val wire: String) { Thumb("thumb"), Preview("preview") }

    private val lock = Mutex()
    private val inFlight = mutableMapOf<String, CompletableDeferred<ByteArray>>()
    private val safe = Regex("^[A-Za-z0-9-]+$")

    private fun file(objectId: String, variant: Variant): File? {
        if (!safe.matches(objectId) || !safe.matches(accountId)) return null
        return File(File(root, accountId), "$objectId-${variant.wire}.jpg")
    }

    /** Bytes for a page image: from disk, or fetched once and stored. */
    suspend fun bytes(page: Page, variant: Variant): ByteArray? {
        val objectId = page.imageObjectId ?: return null
        val path = (if (variant == Variant.Thumb) page.thumbnailUrl else page.previewUrl) ?: return null
        val file = file(objectId, variant) ?: return null
        withContext(Dispatchers.IO) { if (file.isFile) return@withContext file.readBytes() else null }?.let { return it }
        val (deferred, owner) = lock.withLock {
            inFlight[file.path]?.let { it to false } ?: (CompletableDeferred<ByteArray>().also { inFlight[file.path] = it } to true)
        }
        if (!owner) return deferred.await()
        try {
            val bytes = api.imageBytes(path)
            withContext(Dispatchers.IO) {
                file.parentFile?.mkdirs()
                val temporary = File(file.parentFile, ".${file.name}.tmp")
                temporary.writeBytes(bytes)
                temporary.renameTo(file)
            }
            deferred.complete(bytes)
            return bytes
        } catch (e: Exception) {
            deferred.completeExceptionally(e)
            throw e
        } finally {
            lock.withLock { inFlight.remove(file.path) }
        }
    }

    companion object {
        fun clearAll(root: File) { root.deleteRecursively() }
    }
}

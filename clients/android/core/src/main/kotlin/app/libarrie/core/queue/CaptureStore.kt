package app.libarrie.core.queue

import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock
import kotlinx.coroutines.withContext
import kotlinx.serialization.json.Json
import java.io.File
import java.nio.file.Files
import java.nio.file.StandardCopyOption
import java.util.UUID

/**
 * Durable storage for captures: immutable image files plus a manifest
 * rewritten atomically after every change, so a crash, relaunch or device
 * restore always sees a consistent state. On Android it lives in app files
 * (included in Auto Backup unless the user opts out); it never holds tokens.
 */
class CaptureStore(val directory: File, private val now: () -> Long = { System.currentTimeMillis() / 1000 }) {
    private val lock = Mutex()
    private val json = Json { ignoreUnknownKeys = true; encodeDefaults = true }
    private val images = File(directory, "images")
    private val manifestFile = File(directory, "manifest.json")
    private var manifest: Manifest

    init {
        images.mkdirs()
        manifest = runCatching { json.decodeFromString<Manifest>(manifestFile.readText()) }.getOrElse { Manifest() }
    }

    suspend fun items(): List<CaptureItem> = lock.withLock { manifest.items.sortedWith(compareBy({ it.createdAt }, { it.sequence })) }

    suspend fun item(id: String): CaptureItem? = lock.withLock { manifest.items.firstOrNull { it.id == id } }

    suspend fun decision(batch: String): DeferredDecision? = lock.withLock { manifest.decisions[batch] }

    /**
     * The file for an item. Names are relative and validated, so they stay
     * valid after restore and a tampered manifest cannot point elsewhere.
     */
    fun fileFor(item: CaptureItem): File? {
        val name = item.fileName
        if (name.isEmpty() || name.contains('/') || name.contains('\\') || name.contains("..") || name.startsWith('.')) return null
        return File(images, name)
    }

    /** The file exists and still has the recorded size and checksum. */
    suspend fun verifyFile(item: CaptureItem): Boolean = withContext(Dispatchers.IO) {
        val file = fileFor(item) ?: return@withContext false
        if (!file.isFile || file.length() != item.byteCount) return@withContext false
        Checksums.sha256Hex(file.readBytes()) == item.sha256
    }

    /** Save a prepared photo immediately ("saved on this device"). */
    suspend fun capture(image: PreparedImage, batchId: String, sequence: Int, accountId: String, serverUrl: String): CaptureItem {
        val id = UUID.randomUUID().toString()
        val fileName = "$id.${if (image.contentType == "image/png") "png" else "jpg"}"
        withContext(Dispatchers.IO) {
            val temporary = File(images, ".$fileName.tmp")
            temporary.writeBytes(image.bytes)
            Files.move(temporary.toPath(), File(images, fileName).toPath(), StandardCopyOption.ATOMIC_MOVE)
        }
        val time = now()
        val item = CaptureItem(
            id = id, batchId = batchId, sequence = sequence, operationId = UUID.randomUUID().toString(),
            accountId = accountId, serverUrl = serverUrl, fileName = fileName, byteCount = image.bytes.size.toLong(),
            contentType = image.contentType, sha256 = image.sha256, md5 = image.md5,
            state = CaptureState.Captured, createdAt = time, updatedAt = time,
        )
        lock.withLock {
            manifest = manifest.copy(items = manifest.items + item)
            persist()
        }
        return item
    }

    /** Apply a change to one item and persist it. */
    suspend fun update(id: String, change: (CaptureItem) -> CaptureItem): CaptureItem? = lock.withLock {
        val index = manifest.items.indexOfFirst { it.id == id }
        if (index < 0) return@withLock null
        val updated = change(manifest.items[index]).copy(updatedAt = now())
        manifest = manifest.copy(items = manifest.items.toMutableList().also { it[index] = updated })
        persist()
        updated
    }

    suspend fun setDecision(decision: DeferredDecision, batch: String) = lock.withLock {
        manifest = manifest.copy(decisions = manifest.decisions + (batch to decision))
        persist()
    }

    /** Delete the local photo (keeps the queue record). */
    suspend fun removeFile(id: String) {
        val item = item(id) ?: return
        withContext(Dispatchers.IO) { fileFor(item)?.delete() }
        update(id) { it.copy(localFileRemoved = true) }
    }

    /** Forget an item and its photo entirely. */
    suspend fun remove(id: String) {
        val item = item(id)
        if (item != null) withContext(Dispatchers.IO) { fileFor(item)?.delete() }
        lock.withLock {
            val items = manifest.items.filterNot { it.id == id }
            val batches = items.map { it.batchId }.toSet()
            manifest = manifest.copy(items = items, decisions = manifest.decisions.filterKeys { it in batches })
            persist()
        }
    }

    private fun persist() {
        val temporary = File(directory, ".manifest.json.tmp")
        temporary.writeText(json.encodeToString(Manifest.serializer(), manifest))
        Files.move(temporary.toPath(), manifestFile.toPath(), StandardCopyOption.ATOMIC_MOVE, StandardCopyOption.REPLACE_EXISTING)
    }
}

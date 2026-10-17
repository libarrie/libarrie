package app.libarrie.android.data

import android.content.Context
import androidx.work.Constraints
import androidx.work.CoroutineWorker
import androidx.work.ExistingPeriodicWorkPolicy
import androidx.work.ExistingWorkPolicy
import androidx.work.NetworkType
import androidx.work.OneTimeWorkRequestBuilder
import androidx.work.OutOfQuotaPolicy
import androidx.work.PeriodicWorkRequestBuilder
import androidx.work.WorkInfo
import androidx.work.WorkManager
import androidx.work.WorkerParameters
import androidx.work.workDataOf
import app.libarrie.android.LibarrieApplication
import app.libarrie.core.queue.TransferResult
import app.libarrie.core.queue.UploadTransfers
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.flow.first
import kotlinx.coroutines.withContext
import kotlinx.serialization.json.Json
import okhttp3.MediaType.Companion.toMediaTypeOrNull
import okhttp3.OkHttpClient
import okhttp3.Request
import okhttp3.RequestBody.Companion.asRequestBody
import java.io.File
import java.io.IOException
import java.util.concurrent.TimeUnit

private const val UPLOAD_TAG = "libarrie-upload"

/**
 * Uploads through WorkManager (section 13: "platform-supported background
 * work/transfers"), so they continue after the app leaves the foreground or
 * its process dies. Each item has one unique work chain; a retry replaces it.
 */
class WorkManagerTransfers(private val context: Context) : UploadTransfers {
    override suspend fun start(itemId: String, url: String, method: String, headers: Map<String, String>, file: File) {
        val request = OneTimeWorkRequestBuilder<UploadWorker>()
            .setInputData(workDataOf(
                "item" to itemId, "url" to url, "method" to method, "file" to file.absolutePath,
                "headers" to Json.encodeToString(headers),
            ))
            .setConstraints(Constraints.Builder().setRequiredNetworkType(NetworkType.CONNECTED).build())
            .setExpedited(OutOfQuotaPolicy.RUN_AS_NON_EXPEDITED_WORK_REQUEST)
            .addTag(UPLOAD_TAG)
            .addTag("item:$itemId")
            .build()
        WorkManager.getInstance(context).enqueueUniqueWork("upload-$itemId", ExistingWorkPolicy.REPLACE, request)
    }

    override suspend fun activeItemIds(): Set<String> =
        WorkManager.getInstance(context).getWorkInfosByTagFlow(UPLOAD_TAG).first()
            .filter { it.state == WorkInfo.State.ENQUEUED || it.state == WorkInfo.State.RUNNING || it.state == WorkInfo.State.BLOCKED }
            .flatMap { info -> info.tags.filter { it.startsWith("item:") }.map { it.removePrefix("item:") } }
            .toSet()

    companion object {
        /** Run the queue now (when online) and every 15 minutes. */
        fun schedule(context: Context) {
            val online = Constraints.Builder().setRequiredNetworkType(NetworkType.CONNECTED).build()
            val manager = WorkManager.getInstance(context)
            manager.enqueueUniquePeriodicWork(
                "queue-periodic", ExistingPeriodicWorkPolicy.KEEP,
                PeriodicWorkRequestBuilder<QueueWorker>(15, TimeUnit.MINUTES).setConstraints(online).build(),
            )
            manager.enqueueUniqueWork(
                "queue-now", ExistingWorkPolicy.KEEP,
                OneTimeWorkRequestBuilder<QueueWorker>().setConstraints(online).build(),
            )
        }
    }
}

/**
 * PUTs one capture file to its presigned staging URL with exactly the
 * returned headers, then reports the status to the upload engine. Sends no
 * credentials and keeps no cookies.
 */
class UploadWorker(context: Context, params: WorkerParameters) : CoroutineWorker(context, params) {
    private val http = OkHttpClient.Builder().writeTimeout(5, TimeUnit.MINUTES).readTimeout(2, TimeUnit.MINUTES).build()

    override suspend fun doWork(): Result {
        val itemId = inputData.getString("item") ?: return Result.failure()
        val file = File(inputData.getString("file") ?: return Result.failure())
        val headers = Json.decodeFromString<Map<String, String>>(inputData.getString("headers") ?: "{}")
        val container = (applicationContext as LibarrieApplication).container
        val status: Int? = withContext(Dispatchers.IO) {
            try {
                val body = file.asRequestBody(headers["content-type"]?.toMediaTypeOrNull())
                val request = Request.Builder().url(inputData.getString("url")!!).method(inputData.getString("method") ?: "PUT", body)
                    .apply { headers.forEach { (name, value) -> header(name, value) } }
                    .build()
                http.newCall(request).execute().use { it.code }
            } catch (e: IOException) {
                null
            }
        }
        container.transferFinished(TransferResult(itemId, status))
        return Result.success()
    }
}

/** Runs the upload engine: retries, confirmations and backup checks. */
class QueueWorker(context: Context, params: WorkerParameters) : CoroutineWorker(context, params) {
    override suspend fun doWork(): Result {
        (applicationContext as LibarrieApplication).container.runQueue()
        return Result.success()
    }
}

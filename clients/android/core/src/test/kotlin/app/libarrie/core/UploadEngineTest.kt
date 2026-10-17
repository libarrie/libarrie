package app.libarrie.core

import app.libarrie.core.api.AccessTokenProvider
import app.libarrie.core.api.ApiClient
import app.libarrie.core.api.ApiError
import app.libarrie.core.queue.AttentionReason
import app.libarrie.core.queue.BackupState
import app.libarrie.core.queue.CaptureItem
import app.libarrie.core.queue.CaptureState
import app.libarrie.core.queue.CaptureStore
import app.libarrie.core.queue.DeferredDecision
import app.libarrie.core.queue.PreparedImage
import app.libarrie.core.queue.ResumePoint
import app.libarrie.core.queue.UploadEngine
import kotlinx.coroutines.runBlocking
import java.util.UUID
import kotlin.random.Random
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFalse
import kotlin.test.assertNotEquals
import kotlin.test.assertNotNull
import kotlin.test.assertNull
import kotlin.test.assertTrue

const val SERVER = "http://localhost:8080"

class World(account: String = "account-1", tokens: AccessTokenProvider = StaticTokens()) {
    val clock = Clock()
    val fake = FakeServer()
    val store = CaptureStore(tempDir()) { clock.now }
    val transfers = FakeTransfers()
    val engine = UploadEngine(ApiClient(SERVER, fake.http, tokens), store, transfers, account, SERVER, "sha256") { clock.now }
    val batch = UUID.randomUUID().toString()

    fun photo() = PreparedImage(Random.nextBytes(2048), "image/jpeg")

    suspend fun queue(count: Int, firstPage: Int = 1, account: String = "account-1"): List<String> = (0 until count).map { index ->
        val item = store.capture(photo(), batch, index, account, SERVER)
        store.update(item.id) { it.copy(notebookId = "n1", notebookName = "Work", pageNumber = firstPage + index, state = CaptureState.Ready) }
        item.id
    }

    suspend fun item(id: String): CaptureItem = store.item(id)!!

    suspend fun settle() {
        engine.run()
        transfers.finishAll(fake, engine)
        engine.run()
    }

    fun later(seconds: Long = 3600) = clock.advance(seconds)
}

class UploadEngineTest {
    @Test fun uploadsThenRemovesThePhotoOnceBackupIsVerified() = runBlocking {
        val w = World()
        val ids = w.queue(2)
        w.engine.run()
        assertEquals(CaptureState.Uploading, w.item(ids[0]).state)
        assertEquals(2, w.transfers.started.size)
        assertEquals("abc", w.transfers.started[0].headers["x-amz-checksum-sha256"])
        w.transfers.finishAll(w.fake, w.engine)
        val accepted = w.item(ids[0])
        assertEquals(CaptureState.ServerAccepted, accepted.state)
        assertEquals(BackupState.Pending, accepted.backup)
        assertFalse(accepted.localFileRemoved)
        // Kept until the independent backup is verified.
        w.fake.backup[accepted.pageId!!] = "verified"
        w.later(16 * 60)
        w.engine.run()
        val verified = w.item(ids[0])
        assertEquals(BackupState.Verified, verified.backup)
        assertTrue(verified.localFileRemoved)
        assertFalse(w.store.fileFor(verified)!!.exists())
    }

    @Test fun aLostReservationResponseIsReplayedNotDuplicated() = runBlocking {
        val w = World()
        val id = w.queue(1)[0]
        w.fake.fault("POST /v1/upload-sessions", FakeServer.Fault.DropResponse)
        w.engine.run()
        val waiting = w.item(id)
        assertEquals(CaptureState.RetryableError, waiting.state)
        assertEquals(ResumePoint.Reserve, waiting.resumePoint)
        w.later()
        w.settle()
        assertEquals(CaptureState.ServerAccepted, w.item(id).state)
        assertEquals(1, w.fake.ops.size)
        assertEquals(99, w.fake.processingAllowance)
        assertNotNull(w.fake.ops[waiting.operationId])
    }

    @Test fun aLostCompletionResponseIsRetriedIdempotently() = runBlocking {
        val w = World()
        val id = w.queue(1)[0]
        w.fake.fault("POST /v1/upload-sessions/{id}/complete", FakeServer.Fault.DropResponse)
        w.engine.run()
        w.transfers.finishAll(w.fake, w.engine)
        assertEquals(ResumePoint.Confirm, w.item(id).resumePoint)
        w.later()
        w.engine.run()
        assertEquals(CaptureState.ServerAccepted, w.item(id).state)
        assertEquals(1, w.fake.ops.size)
    }

    @Test fun aPageNumberConflictWaitsForANewNumber() = runBlocking {
        val w = World()
        w.fake.takenNumbers += "n1#1"
        val id = w.queue(1)[0]
        w.engine.run()
        val blocked = w.item(id)
        assertEquals(AttentionReason.PageNumberConflict, blocked.attention)
        w.engine.renumber(id, 5)
        w.transfers.finishAll(w.fake, w.engine)
        val done = w.item(id)
        assertEquals(CaptureState.ServerAccepted, done.state)
        assertNotEquals(blocked.operationId, done.operationId)
        assertEquals("5", w.fake.ops[done.operationId]?.body?.get("page_number"))
    }

    @Test fun usedUpAllowanceAsksOncePerBatchThenDefers() = runBlocking {
        val w = World()
        w.fake.processingAllowance = 0
        val ids = w.queue(2)
        w.engine.run()
        ids.forEach { assertEquals(AttentionReason.ProcessingLimit, w.item(it).attention) }
        w.engine.decide(DeferredDecision.UploadAndProcessLater, w.batch)
        w.transfers.finishAll(w.fake, w.engine)
        ids.forEach {
            val item = w.item(it)
            assertEquals(CaptureState.ServerAccepted, item.state)
            assertEquals("deferred", w.fake.ops[item.operationId]?.body?.get("processing_mode"))
        }
        // A later item in the same batch follows the answer without asking.
        val late = w.store.capture(w.photo(), w.batch, 9, "account-1", SERVER)
        w.store.update(late.id) { it.copy(notebookId = "n1", pageNumber = 9, state = CaptureState.Ready) }
        w.engine.run()
        assertEquals(CaptureState.Uploading, w.item(late.id).state)
        assertEquals("deferred", w.item(late.id).processingMode)
    }

    @Test fun anExpiredUploadLinkIsRefreshedOnTheSameReservation() = runBlocking {
        val w = World()
        val id = w.queue(1)[0]
        w.engine.run()
        w.fake.expiredUrls = true
        w.transfers.finishAll(w.fake, w.engine)
        assertEquals(ResumePoint.Upload, w.item(id).resumePoint)
        w.settle()
        assertEquals(CaptureState.ServerAccepted, w.item(id).state)
        assertTrue("POST /v1/upload-sessions/{id}/refresh" in w.fake.log)
        assertEquals(1, w.fake.ops.size)
    }

    @Test fun anExpiredReservationNeedsAnExplicitLinkedRetry() = runBlocking {
        val w = World()
        val id = w.queue(1)[0]
        w.engine.run()
        val first = w.item(id).operationId
        w.fake.expire(first)
        w.fake.expiredUrls = true
        w.transfers.finishAll(w.fake, w.engine)
        w.engine.run()
        assertEquals(AttentionReason.Expired, w.item(id).attention)
        w.engine.retryNow(id)
        w.transfers.finishAll(w.fake, w.engine)
        val retried = w.item(id)
        assertEquals(CaptureState.ServerAccepted, retried.state)
        assertNotEquals(first, retried.operationId)
        assertEquals(first, w.fake.ops[retried.operationId]?.body?.get("retry_of_operation_id"))
    }

    @Test fun aRelaunchResumesUploadsWithoutDuplicates() = runBlocking {
        val w = World()
        val id = w.queue(1)[0]
        w.engine.run()
        w.transfers.forgetAll()
        w.settle()
        assertEquals(CaptureState.ServerAccepted, w.item(id).state)
        assertEquals(1, w.fake.ops.size)
        assertEquals(2, w.transfers.started.size)
    }

    @Test fun capturesFromAnotherAccountAreNeverUploaded() = runBlocking {
        val w = World(account = "account-2")
        val id = w.queue(1, account = "account-1")[0]
        w.engine.run()
        assertTrue(w.fake.log.isEmpty())
        assertEquals(CaptureState.Ready, w.item(id).state)
    }

    @Test fun aMissingPhotoIsReconciledWithTheServer() = runBlocking {
        val w = World()
        val ids = w.queue(2)
        // Never sent: the user decides.
        w.store.fileFor(w.item(ids[0]))!!.delete()
        w.engine.run()
        assertEquals(AttentionReason.CaptureMissing, w.item(ids[0]).attention)
        // Already stored by Libarrie (completion result lost, then the photo vanished).
        val second = w.item(ids[1])
        w.fake.ops.getValue(second.operationId).apply { uploaded = true; accepted = true }
        w.transfers.forgetAll()
        w.store.fileFor(second)!!.delete()
        w.engine.run()
        val reconciled = w.item(ids[1])
        assertEquals(CaptureState.ServerAccepted, reconciled.state)
        assertTrue(reconciled.localFileRemoved)
    }

    @Test fun replacementsAreConditionalAndNeverDeferred() = runBlocking {
        val w = World()
        val item = w.store.capture(w.photo(), w.batch, 0, "account-1", SERVER)
        w.store.update(item.id) { it.copy(replacesPageId = "p1", replacesContentVersion = 3, processingMode = "deferred", state = CaptureState.Ready) }
        // A connection failure leaves it queued; the retry carries If-Match (the fake answers 428 without it).
        w.fake.fault("POST /v1/upload-sessions", FakeServer.Fault.NetworkBeforeServer)
        w.engine.run()
        assertEquals(CaptureState.RetryableError, w.item(item.id).state)
        w.later()
        w.engine.run()
        val created = w.item(item.id)
        assertEquals(CaptureState.Uploading, created.state)
        val op = w.fake.ops.getValue(created.operationId)
        assertEquals("p1", op.body["page_id"])
        assertEquals("immediate", op.body["processing_mode"])
        assertNull(op.body["notebook_id"])
    }

    @Test fun cancellingCancelsOnTheServerAndForgetsThePhoto() = runBlocking {
        val w = World()
        val id = w.queue(1)[0]
        w.engine.run()
        val operation = w.item(id).operationId
        w.engine.cancel(id)
        assertNull(w.store.item(id))
        assertEquals("cancelled", w.fake.ops[operation]?.status)
    }

    @Test fun anExpiredSignInPausesWithoutLosingWork() = runBlocking {
        val signedOut = object : AccessTokenProvider {
            override suspend fun accessToken(): String = throw ApiError.unauthenticated()
            override suspend fun refreshAfterRejection(token: String): String = throw ApiError.unauthenticated()
        }
        val w = World(tokens = signedOut)
        val ids = w.queue(2)
        w.engine.run()
        assertTrue(w.engine.needsSignIn)
        assertEquals(CaptureState.RetryableError, w.item(ids[0]).state)
        assertEquals(CaptureState.Ready, w.item(ids[1]).state)
    }

    @Test fun manifestSurvivesRelaunchAndRejectsTampering() = runBlocking {
        val dir = tempDir()
        val first = CaptureStore(dir)
        val item = first.capture(PreparedImage(Random.nextBytes(100), "image/jpeg"), "b", 0, "a", SERVER)
        val reopened = CaptureStore(dir)
        val restored = reopened.item(item.id)!!
        assertEquals(item.operationId, restored.operationId)
        assertTrue(reopened.verifyFile(restored))
        assertNull(reopened.fileFor(restored.copy(fileName = "../../etc/passwd")))
    }
}

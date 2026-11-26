package app.libarrie.core

import app.libarrie.core.api.AcceptedUpload
import app.libarrie.core.api.AccountDeletionStatus
import app.libarrie.core.api.ApiClient
import app.libarrie.core.api.ApiError
import app.libarrie.core.api.ApiJson
import app.libarrie.core.api.ClientConfiguration
import app.libarrie.core.api.ExportCreated
import app.libarrie.core.api.ExportDetail
import app.libarrie.core.api.ExportList
import app.libarrie.core.api.Limit
import app.libarrie.core.api.Me
import app.libarrie.core.api.Notebook
import app.libarrie.core.api.NotebookList
import app.libarrie.core.api.Operation
import app.libarrie.core.api.PageDetail
import app.libarrie.core.api.PageList
import app.libarrie.core.api.SearchResponse
import app.libarrie.core.api.TrashList
import app.libarrie.core.api.UploadSession
import app.libarrie.core.api.Usage
import kotlinx.serialization.Serializable
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFalse
import kotlin.test.assertNotNull
import kotlin.test.assertNull
import kotlin.test.assertTrue

/** Every model decodes the server's real responses (contracts/fixtures/api). */
class FixtureTest {
    private inline fun <reified T> decode(name: String): T = ApiJson.decodeFromString(fixture(name).second)

    @Test fun clientConfiguration() {
        val config = decode<ClientConfiguration>("client_configuration")
        assertEquals("libarrie-native", config.oidc?.clientId)
        assertEquals("libarrie://oauth/callback", config.oidc?.redirectUri)
        assertEquals("sha256", config.uploads.integrity)
    }

    @Test fun accountAndUsage() {
        assertEquals("active", decode<Me>("me").account.status)
        val usage = decode<Usage>("usage")
        assertEquals(Limit(30), usage.limits.storedPages)
        assertNotNull(usage.lifetimeAllowance)
        assertEquals("active", decode<AccountDeletionStatus>("account_deletion_status").milestone)
    }

    @Test fun notebooksAndPages() {
        val listed = decode<NotebookList>("notebook_list").notebooks.first()
        assertEquals("Blue work notebook", listed.name)
        assertFalse(listed.private)
        assertFalse(decode<Notebook>("notebook").private)
        assertEquals(1, decode<PageList>("page_list").pages.first().pageNumber)
        val detail = decode<PageDetail>("page_detail")
        assertEquals("ready", detail.page.processingStatus)
        assertEquals("Met Grace Hopper about the compiler budget", detail.transcript?.text)
        assertEquals("trashed", decode<TrashList>("trash").pages.first().visibility)
        @Serializable data class Awaiting(val pages: List<app.libarrie.core.api.Page>)
        assertEquals("awaiting_processing", decode<Awaiting>("pages_awaiting_processing").pages.first().processingStatus)
    }

    @Test fun uploads() {
        val created = decode<UploadSession>("upload_session_created")
        assertEquals("PUT", created.upload?.method)
        assertNotNull(created.upload?.headers?.get("x-amz-checksum-sha256"))
        assertNotNull(decode<AcceptedUpload>("upload_completed").operation.uploadAcceptedAt)
        assertEquals("upload", decode<Operation>("operation").kind)
    }

    @Test fun searchAndExports() {
        assertEquals(10, decode<SearchResponse>("search").results.first().highlights.first().start)
        // A hit from a private notebook says where, without the text.
        val hidden = decode<SearchResponse>("search_private").results.first()
        assertNull(hidden.snippet)
        assertTrue(hidden.highlights.isEmpty())
        assertEquals("Blue work notebook", hidden.notebook.name)
        assertEquals(1, hidden.pageNumber)
        assertEquals("completed", decode<ExportList>("export_list").exports.first().state)
        assertTrue(decode<ExportDetail>("export_detail").parts.first().downloadable)
        decode<ExportCreated>("export_created")
    }

    @Test fun mixedSearchResults() {
        val response = ApiJson.decodeFromString<SearchResponse>(
            """{"search_mode":"hybrid","index_migration_pending":false,"results":[
              {"page_id":"p1","notebook":{"id":"n1","name":"Work"},"page_number":1,"snippet":"met Grace",
               "highlights":[{"start":4,"end":9}],"match_kind":"hybrid","indexing_pending":false},
              {"page_id":"p2","notebook":{"id":"n2","name":"Diary"},"page_number":4,"match_kind":"lexical",
               "indexing_pending":false}]}""",
        )
        assertEquals(listOf("met Grace", null), response.results.map { it.snippet })
        assertEquals(listOf(1, 0), response.results.map { it.highlights.size })
    }

    @Test fun notebookInputKeys() {
        // The server reads `private`; a key such as `is_private` would be ignored.
        assertEquals("""{"private":true}""", ApiJson.encodeToString(ApiClient.NotebookInput(private = true)))
        assertEquals("{}", ApiJson.encodeToString(ApiClient.NotebookInput(private = null)))
    }

    @Test fun savesThatDidNotMakeANotebookPrivateAreNotConfirmed() {
        fun saved(extra: String) = ApiJson.decodeFromString<Notebook>(
            """{"id":"n","name":"Diary","description":"","color":null,"version":2,"numbering_revision":1,
               "page_count":0,"deleted_at":null$extra}""",
        )
        // A server older than private notebooks sends no `private`.
        val older = saved("")
        assertFalse(ApiClient.NotebookInput(private = true).privacyConfirmedBy(older))
        assertTrue(ApiClient.NotebookInput(private = true).privacyConfirmedBy(saved(""","private":true""")))
        // Turning privacy off, or leaving it off, needs no warning.
        assertTrue(ApiClient.NotebookInput(private = false).privacyConfirmedBy(older))
        assertTrue(ApiClient.NotebookInput(private = null).privacyConfirmedBy(older))
    }

    @Test fun serverSettings() {
        assertEquals(false, decode<app.libarrie.core.api.ServerSettings>("settings").autoProcessDeferred)
    }

    @Test fun errors() {
        val (status, body) = fixture("error_page_number_conflict")
        val error = ApiError.decode(status, body, null)
        assertEquals("page_number_conflict", error.code)
        assertEquals("1", error.details["page_number"])
        val (s2, b2) = fixture("error_version_conflict")
        assertEquals("version_conflict", ApiError.decode(s2, b2, null).code)
    }
}

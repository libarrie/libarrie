package app.libarrie.core

import app.libarrie.core.api.ApiJson
import app.libarrie.core.api.Notebook
import app.libarrie.core.api.NotebookDraft
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFalse
import kotlin.test.assertTrue

/** The notebook editor's starting values and the request a save sends. */
class NotebookDraftTest {
    private fun notebook(extra: String) = ApiJson.decodeFromString<Notebook>(
        """{"id":"n","name":"Diary","description":"Blue cover","color":"#2F6F9F","version":3,
           "numbering_revision":1,"page_count":2,"deleted_at":null$extra}""",
    )

    @Test fun aNewNotebookStartsPublic() {
        val draft = NotebookDraft.of(null)
        assertEquals(NotebookDraft("", "", "", isPrivate = false), draft)
        assertEquals(false, draft.input().private)
    }

    @Test fun aPrivateNotebookStaysPrivateWhenRenamed() {
        val draft = NotebookDraft.of(notebook(""","private":true"""))
        assertTrue(draft.isPrivate)
        val renamed = draft.copy(name = "  Diary 2026 ").input()
        assertEquals(true, renamed.private)
        assertEquals("Diary 2026", renamed.name)
        assertEquals("Blue cover", renamed.description)
        assertEquals("#2f6f9f", renamed.color)
        assertEquals(false, draft.copy(isPrivate = false).input().private)
    }

    @Test fun aNotebookFromAnOlderServerStartsPublic() {
        assertFalse(NotebookDraft.of(notebook("")).isPrivate)
    }
}

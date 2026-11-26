package app.libarrie.core.api

/**
 * A notebook editor's fields. They start from the notebook being edited,
 * privacy included, so a save that only renames a private notebook keeps it
 * private.
 */
data class NotebookDraft(val name: String, val description: String, val color: String, val isPrivate: Boolean) {
    /** The request a save sends. */
    fun input() = ApiClient.NotebookInput(name.trim(), description, color, isPrivate)

    companion object {
        fun of(editing: Notebook?) = NotebookDraft(
            name = editing?.name ?: "",
            description = editing?.description ?: "",
            color = editing?.color?.lowercase() ?: "",
            isPrivate = editing?.private ?: false,
        )
    }
}

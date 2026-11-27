package app.libarrie.android.ui

import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.grid.GridCells
import androidx.compose.foundation.lazy.grid.GridItemSpan
import androidx.compose.foundation.lazy.grid.LazyVerticalGrid
import androidx.compose.foundation.lazy.grid.items
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.selection.selectable
import androidx.compose.foundation.selection.toggleable
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.outlined.ArrowBack
import androidx.compose.material.icons.outlined.Add
import androidx.compose.material.icons.outlined.CameraAlt
import androidx.compose.material.icons.outlined.MoreVert
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.DropdownMenu
import androidx.compose.material3.DropdownMenuItem
import androidx.compose.material3.HorizontalDivider
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.ListItem
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.RadioButton
import androidx.compose.material3.Scaffold
import androidx.compose.material3.Switch
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.material3.TopAppBar
import androidx.compose.material3.pulltorefresh.PullToRefreshBox
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.text.input.KeyboardType
import androidx.compose.ui.unit.dp
import androidx.lifecycle.ViewModel
import androidx.lifecycle.viewModelScope
import androidx.lifecycle.viewmodel.compose.viewModel
import androidx.navigation.NavController
import app.libarrie.android.AppContainer
import app.libarrie.core.api.ApiClient
import app.libarrie.core.api.ApiError
import app.libarrie.core.api.Notebook
import app.libarrie.core.api.NotebookDraft
import app.libarrie.core.api.Numbering
import app.libarrie.core.api.Page
import app.libarrie.core.cache.ImageCache
import kotlinx.coroutines.delay
import kotlinx.coroutines.launch

/**
 * Create or edit a notebook's name, description, color and privacy. The
 * fields live in one [NotebookDraft], which `core` tests: it starts from the
 * notebook being edited and builds the request a save sends.
 */
class NotebookEditor(val editing: Notebook?) {
    private var draft by mutableStateOf(NotebookDraft.of(editing))
    var name: String
        get() = draft.name
        set(value) { draft = draft.copy(name = value) }
    var description: String
        get() = draft.description
        set(value) { draft = draft.copy(description = value) }
    var color: String
        get() = draft.color
        set(value) { draft = draft.copy(color = value) }
    var isPrivate: Boolean
        get() = draft.isPrivate
        set(value) { draft = draft.copy(isPrivate = value) }
    var error by mutableStateOf<String?>(null)
    /** Set by a save that succeeded but didn't make the notebook private. */
    var notice by mutableStateOf<String?>(null)
    var saving by mutableStateOf(false)
    val canSave get() = name.isNotBlank() && name.length <= 200 && !saving
    fun input() = draft.input()
}

class NotebooksViewModel(private val container: AppContainer) : ViewModel() {
    var notebooks by mutableStateOf<List<Notebook>>(emptyList())
    var loading by mutableStateOf(false)
    var message by mutableStateOf<Message?>(null)
    var editor by mutableStateOf<NotebookEditor?>(null)

    fun load() = viewModelScope.launch {
        val api = container.services?.api ?: return@launch
        loading = true
        try {
            notebooks = api.allNotebooks()
            message = null
        } catch (e: Exception) {
            message = StatusInfo.Kind.Danger to describe(e)
        } finally {
            loading = false
        }
    }

    suspend fun save(editor: NotebookEditor): Boolean {
        if (!saveNotebook(container, editor)) return false
        // Return without suspending, so the dialog closes at once: the save has
        // turned Create and Save back on, and a second tap would submit again.
        val reload = load()
        // A successful load clears the message, so the notice waits for this
        // one. It runs in this model's scope, which closing the dialog or
        // recreating the activity doesn't cancel.
        editor.notice?.let { notice ->
            viewModelScope.launch {
                reload.join()
                message = StatusInfo.Kind.Warning to notice
            }
        }
        return true
    }
}

suspend fun saveNotebook(container: AppContainer, editor: NotebookEditor): Boolean {
    val api = container.services?.api ?: return false
    editor.saving = true
    try {
        val input = editor.input()
        val existing = editor.editing
        val saved = if (existing != null) api.updateNotebook(existing.id, existing.version, input) else api.createNotebook(input)
        // The save went through, so the editor closes either way.
        if (!input.privacyConfirmedBy(saved)) {
            editor.notice = "Saved, but this server doesn't support private notebooks yet, so \"${saved.name}\" isn't private."
        }
        return true
    } catch (e: ApiError) {
        editor.error = when (e.code) {
            "version_conflict" -> "This notebook changed on another device. Close and try again."
            "notebook_limit_reached" -> "You have reached your notebook limit."
            else -> e.message
        }
    } catch (e: Exception) {
        editor.error = describe(e)
    } finally {
        editor.saving = false
    }
    return false
}

@Composable
fun NotebooksScreen(container: AppContainer, nav: NavController) {
    val model = viewModel { NotebooksViewModel(container) }
    LaunchedEffect(Unit) { model.load() }
    Scaffold(topBar = {
        TopAppBar(title = { Text("Notebooks") }, actions = {
            IconButton(onClick = { nav.navigate(Routes.capture()) }) { Icon(Icons.Outlined.CameraAlt, "Add pages") }
            IconButton(onClick = { model.editor = NotebookEditor(null) }) { Icon(Icons.Outlined.Add, "New notebook") }
        })
    }) { padding ->
        PullToRefreshBox(isRefreshing = model.loading, onRefresh = { model.load() }, modifier = Modifier.padding(padding)) {
            LazyColumn(Modifier.fillMaxSize()) {
                item { MessageBanner(model.message, Modifier.padding(16.dp)) }
                if (model.notebooks.isEmpty() && !model.loading) item {
                    Text("No notebooks yet. Create one, then photograph its pages.", Modifier.padding(16.dp), color = LocalBrand.current.textMuted)
                }
                items(model.notebooks, key = { it.id }) { notebook ->
                    ListItem(
                        headlineContent = { Text(notebook.name) },
                        supportingContent = {
                            Column {
                                if (notebook.description.isNotEmpty()) Text(notebook.description, maxLines = 2)
                                Text(plural(notebook.pageCount, "page"), style = MaterialTheme.typography.bodySmall)
                            }
                        },
                        leadingContent = { NotebookDot(notebook.color) },
                        modifier = Modifier.clickable { nav.navigate(Routes.notebook(notebook.id)) },
                    )
                    HorizontalDivider()
                }
            }
        }
    }
    model.editor?.let { editor ->
        NotebookEditorDialog(editor, onDismiss = { model.editor = null }) {
            if (model.save(editor)) model.editor = null
        }
    }
}

@Composable
fun NotebookEditorDialog(editor: NotebookEditor, onDismiss: () -> Unit, onSave: suspend () -> Unit) {
    val scope = androidx.compose.runtime.rememberCoroutineScope()
    AlertDialog(
        onDismissRequest = onDismiss,
        title = { Text(if (editor.editing == null) "New notebook" else "Edit notebook") },
        text = {
            LazyColumn(verticalArrangement = Arrangement.spacedBy(8.dp)) {
                item { editor.error?.let { Banner(StatusInfo.Kind.Danger, it) } }
                item {
                    OutlinedTextField(editor.name, { editor.name = it }, label = { Text("Name") },
                        placeholder = { Text("For example, Blue work notebook") }, singleLine = true, modifier = Modifier.fillMaxWidth())
                }
                item {
                    OutlinedTextField(editor.description, { editor.description = it }, label = { Text("Description (optional)") },
                        minLines = 2, maxLines = 4, modifier = Modifier.fillMaxWidth())
                }
                item { Text("Color (optional)", style = MaterialTheme.typography.titleSmall) }
                items(listOf("" to "None") + NotebookColors) { (hex, label) ->
                    Row(
                        Modifier.fillMaxWidth().selectable(editor.color == hex, role = Role.RadioButton) { editor.color = hex },
                        verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(8.dp),
                    ) {
                        RadioButton(selected = editor.color == hex, onClick = null)
                        NotebookDot(hex.ifEmpty { null })
                        Text(label)
                    }
                }
                item { Text("Privacy", style = MaterialTheme.typography.titleSmall) }
                item {
                    Row(
                        Modifier.fillMaxWidth().toggleable(editor.isPrivate, role = Role.Switch) { editor.isPrivate = it },
                        verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(8.dp),
                    ) {
                        Text("Private notebook", Modifier.weight(1f))
                        Switch(checked = editor.isPrivate, onCheckedChange = null)
                    }
                }
                item {
                    Text(
                        "Searches, including an AI agent's, show which of its pages match, but not the matching text. AI agents connected to Libarrie can't open its pages. Anything that uses your own sign-in, such as an assistant in your browser, still can. Libarrie still sends its pages to the AI services that transcribe them and make them searchable.",
                        style = MaterialTheme.typography.bodySmall, color = LocalBrand.current.textMuted,
                    )
                }
            }
        },
        confirmButton = {
            TextButton(onClick = { scope.launch { onSave() } }, enabled = editor.canSave) {
                Text(if (editor.editing == null) "Create" else "Save")
            }
        },
        dismissButton = { TextButton(onClick = onDismiss) { Text("Cancel") } },
    )
}

// Notebook detail -------------------------------------------------------------------------------

class RenumberForm(val numbering: Numbering) {
    var from by mutableStateOf("")
    var to by mutableStateOf("")
    var by by mutableStateOf("1")
    var error by mutableStateOf<String?>(null)

    /** `1–3, 5, 7–8`. */
    val ranges: String
        get() {
            val runs = mutableListOf<IntArray>()
            for (n in numbering.pages.map { it.pageNumber }.sorted()) {
                val last = runs.lastOrNull()
                if (last != null && n == last[1] + 1) last[1] = n else runs += intArrayOf(n, n)
            }
            return runs.joinToString(", ") { if (it[0] == it[1]) "${it[0]}" else "${it[0]}–${it[1]}" }
        }
}

class NotebookViewModel(private val container: AppContainer, val id: String) : ViewModel() {
    var notebook by mutableStateOf<Notebook?>(null)
    var pages by mutableStateOf<List<Page>>(emptyList())
    var nextCursor by mutableStateOf<String?>(null)
    var loading by mutableStateOf(false)
    var message by mutableStateOf<Message?>(null)
    var editor by mutableStateOf<NotebookEditor?>(null)
    var renumber by mutableStateOf<RenumberForm?>(null)
    var confirmTrash by mutableStateOf(false)

    init {
        // Poll while pages are processing.
        viewModelScope.launch {
            while (true) {
                delay(4000)
                if (pages.any { isProcessing(it.processingStatus) }) load()
            }
        }
    }

    fun load() = viewModelScope.launch {
        val api = container.services?.api ?: return@launch
        loading = true
        try {
            notebook = api.notebook(id)
            val list = api.pages(id)
            pages = list.pages
            nextCursor = list.nextCursor
        } catch (e: ApiError) {
            message = if (e.status == 404) StatusInfo.Kind.Warning to "This notebook is no longer available." else StatusInfo.Kind.Danger to e.message
        } finally {
            loading = false
        }
    }

    fun loadMore() = viewModelScope.launch {
        val cursor = nextCursor ?: return@launch
        nextCursor = null
        runCatching { container.services?.api?.pages(id, cursor) }.getOrNull()?.let {
            pages = pages + it.pages
            nextCursor = it.nextCursor
        }
    }

    fun openRenumber() = viewModelScope.launch {
        val numbering = runCatching { container.services?.api?.numbering(id) }.getOrNull()
        if (numbering == null) message = StatusInfo.Kind.Danger to "Page numbers could not be loaded." else renumber = RenumberForm(numbering)
    }

    suspend fun applyRenumber(form: RenumberForm): Boolean {
        val api = container.services?.api ?: return false
        val from = form.from.trim().toIntOrNull()
        val to = form.to.trim().toIntOrNull()
        val by = form.by.trim().toIntOrNull()
        if (from == null || to == null || by == null || from < 1 || to < from || by == 0) {
            form.error = "Enter a first page of at least 1, a last page no lower than the first, and a move other than 0."
            return false
        }
        return try {
            api.shiftPages(id, form.numbering.numberingRevision, from, to, by)
            message = StatusInfo.Kind.Ok to "Pages renumbered."
            load()
            true
        } catch (e: ApiError) {
            form.error = when (e.code) {
                "page_number_conflict" -> "That would give two pages the same number. Choose free numbers, or move a wider range."
                "version_conflict" -> "Page numbers changed on another device. Close and try again."
                else -> e.message
            }
            false
        }
    }

    suspend fun trash(): Boolean {
        val notebook = notebook ?: return false
        return try {
            container.services?.api?.trashNotebook(notebook.id, notebook.version)
            true
        } catch (e: Exception) {
            message = StatusInfo.Kind.Danger to describe(e)
            false
        }
    }

    suspend fun saveEditor(editor: NotebookEditor) = saveNotebook(container, editor).also { saved ->
        if (saved) {
            load()
            // This screen's load sets the message only on errors.
            editor.notice?.let { message = StatusInfo.Kind.Warning to it }
        }
    }
}

@Composable
fun NotebookScreen(container: AppContainer, nav: NavController, id: String) {
    val model = viewModel(key = "notebook-$id") { NotebookViewModel(container, id) }
    val scope = androidx.compose.runtime.rememberCoroutineScope()
    var menu by remember { mutableStateOf(false) }
    LaunchedEffect(id) { model.load() }
    Scaffold(topBar = {
        TopAppBar(
            title = { Text(model.notebook?.name ?: "Notebook") },
            navigationIcon = { IconButton(onClick = { nav.popBackStack() }) { Icon(Icons.AutoMirrored.Outlined.ArrowBack, "Back") } },
            actions = {
                IconButton(onClick = { nav.navigate(Routes.capture(notebook = id)) }, enabled = model.notebook != null) {
                    Icon(Icons.Outlined.CameraAlt, "Add pages")
                }
                IconButton(onClick = { menu = true }) { Icon(Icons.Outlined.MoreVert, "Notebook settings") }
                DropdownMenu(expanded = menu, onDismissRequest = { menu = false }) {
                    DropdownMenuItem(text = { Text("Edit notebook") }, onClick = { menu = false; model.editor = model.notebook?.let { NotebookEditor(it) } })
                    DropdownMenuItem(text = { Text("Renumber pages") }, onClick = { menu = false; model.openRenumber() })
                    DropdownMenuItem(text = { Text("Move to trash") }, onClick = { menu = false; model.confirmTrash = true })
                }
            },
        )
    }) { padding ->
        PullToRefreshBox(isRefreshing = model.loading, onRefresh = { model.load() }, modifier = Modifier.padding(padding)) {
            LazyVerticalGrid(GridCells.Adaptive(110.dp), Modifier.fillMaxSize(), contentPadding = PaddingValues(16.dp),
                horizontalArrangement = Arrangement.spacedBy(12.dp), verticalArrangement = Arrangement.spacedBy(16.dp)) {
                item(span = { GridItemSpan(maxLineSpan) }) {
                    Column(verticalArrangement = Arrangement.spacedBy(8.dp)) {
                        MessageBanner(model.message)
                        model.notebook?.description?.takeIf { it.isNotEmpty() }?.let { Text(it, color = LocalBrand.current.textMuted) }
                        if (model.pages.isEmpty() && !model.loading) Text("No pages yet. Photograph this notebook's pages to add them.")
                    }
                }
                items(model.pages, key = { it.id }) { page ->
                    Column(Modifier.clickable { nav.navigate(Routes.page(page.id)) }, verticalArrangement = Arrangement.spacedBy(4.dp)) {
                        PageImage(page, ImageCache.Variant.Thumb, container.services?.images)
                        Text("Page ${page.pageNumber}", style = MaterialTheme.typography.titleSmall)
                        StatusBadge(page.processingStatus)
                    }
                    if (page == model.pages.last()) LaunchedEffect(page.id) { model.loadMore() }
                }
            }
        }
    }
    model.editor?.let { editor -> NotebookEditorDialog(editor, { model.editor = null }) { if (model.saveEditor(editor)) model.editor = null } }
    model.renumber?.let { form -> RenumberDialog(form, { model.renumber = null }) { if (model.applyRenumber(form)) model.renumber = null } }
    if (model.confirmTrash) AlertDialog(
        onDismissRequest = { model.confirmTrash = false },
        title = { Text("Move this notebook to trash?") },
        text = { Text("The notebook and its pages move to trash. You can restore them for 30 days.") },
        confirmButton = {
            TextButton(onClick = { scope.launch { model.confirmTrash = false; if (model.trash()) nav.popBackStack() } }) { Text("Move to trash") }
        },
        dismissButton = { TextButton(onClick = { model.confirmTrash = false }) { Text("Cancel") } },
    )
}

@Composable
fun RenumberDialog(form: RenumberForm, onDismiss: () -> Unit, onApply: suspend () -> Unit) {
    val scope = androidx.compose.runtime.rememberCoroutineScope()
    val number = KeyboardOptions(keyboardType = KeyboardType.Number)
    AlertDialog(
        onDismissRequest = onDismiss,
        title = { Text("Renumber pages") },
        text = {
            Column(verticalArrangement = Arrangement.spacedBy(8.dp)) {
                Text("Current page numbers", style = MaterialTheme.typography.titleSmall)
                Text(form.ranges.ifEmpty { "No pages yet." }, fontFamily = FontFamily.Monospace)
                Text("Every page from the first to the last number moves by the same amount. All pages move together, or none do.",
                    style = MaterialTheme.typography.bodySmall)
                OutlinedTextField(form.from, { form.from = it }, label = { Text("First page") }, keyboardOptions = number, singleLine = true)
                OutlinedTextField(form.to, { form.to = it }, label = { Text("Last page") }, keyboardOptions = number, singleLine = true)
                OutlinedTextField(form.by, { form.by = it }, label = { Text("Move by (negative moves earlier)") }, singleLine = true)
                form.error?.let { Banner(StatusInfo.Kind.Danger, it) }
            }
        },
        confirmButton = { TextButton(onClick = { scope.launch { onApply() } }) { Text("Renumber") } },
        dismissButton = { TextButton(onClick = onDismiss) { Text("Cancel") } },
    )
}

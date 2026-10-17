package app.libarrie.android.ui

import android.net.Uri
import androidx.activity.compose.rememberLauncherForActivityResult
import androidx.activity.result.PickVisualMediaRequest
import androidx.activity.result.contract.ActivityResultContracts
import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.foundation.verticalScroll
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.outlined.ArrowBack
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.Button
import androidx.compose.material3.DropdownMenuItem
import androidx.compose.material3.ExposedDropdownMenuAnchorType
import androidx.compose.material3.ExposedDropdownMenuBox
import androidx.compose.material3.ExposedDropdownMenuDefaults
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.OutlinedButton
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.Scaffold
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.material3.TopAppBar
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.setValue
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.platform.LocalUriHandler
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.semantics
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
import app.libarrie.core.api.PageDetail
import app.libarrie.core.cache.ImageCache
import kotlinx.coroutines.delay
import kotlinx.coroutines.launch
import java.util.UUID

class MoveForm(pageNumber: Int, notebookId: String) {
    var pageNumber by mutableStateOf(pageNumber.toString())
    var notebookId by mutableStateOf(notebookId)
    var error by mutableStateOf<String?>(null)
}

class PageViewModel(private val container: AppContainer, val id: String) : ViewModel() {
    var detail by mutableStateOf<PageDetail?>(null)
    var text by mutableStateOf("")
    /** The text the user had typed when a save was refused, kept so nothing is lost. */
    var unsavedText by mutableStateOf<String?>(null)
    var message by mutableStateOf<Message?>(null)
    var saving by mutableStateOf(false)
    var gone by mutableStateOf(false)
    var move by mutableStateOf<MoveForm?>(null)
    var notebooks by mutableStateOf<List<Notebook>>(emptyList())
    var confirmTrash by mutableStateOf(false)
    var confirmRescan by mutableStateOf(false)
    private var rescanOperationId = UUID.randomUUID().toString()

    val page get() = detail?.page
    val processing get() = page?.let { isProcessing(it.processingStatus) } ?: false
    val dirty get() = text != (detail?.transcript?.text ?: "")
    private val api get() = container.services?.api

    init {
        viewModelScope.launch {
            while (true) {
                delay(3000)
                if (processing) load(keepText = true)
            }
        }
    }

    fun load(keepText: Boolean = false) = viewModelScope.launch {
        val api = api ?: return@launch
        try {
            val fresh = api.page(id)
            val wasDirty = dirty
            detail = fresh
            if (!keepText || !wasDirty) text = fresh.transcript?.text ?: ""
        } catch (e: ApiError) {
            if (e.status == 404) gone = true else message = StatusInfo.Kind.Danger to e.message
        }
    }

    fun save(action: ApiClient.TranscriptAction = ApiClient.TranscriptAction.Save) = viewModelScope.launch {
        val api = api ?: return@launch
        val detail = detail ?: return@launch
        val revision = detail.page.revisionId ?: return@launch
        val typed = text
        saving = true
        try {
            api.saveTranscript(
                id, detail.page.contentVersion, revision, detail.page.transcriptRevisionId, action,
                text = if (action == ApiClient.TranscriptAction.Save) typed else null,
                ocrResultId = if (action == ApiClient.TranscriptAction.AcceptCandidate) detail.ocrCandidate?.ocrResultId else null,
            )
            unsavedText = null
            message = StatusInfo.Kind.Ok to if (action == ApiClient.TranscriptAction.ConfirmBlank) "Marked as a blank page." else "Transcript saved."
            load()
        } catch (e: ApiError) {
            // Keep the user's text; show the current version.
            unsavedText = typed
            message = StatusInfo.Kind.Warning to when (e.code) {
                "version_conflict" -> "This page changed since you opened it (perhaps on another device). The current text is shown; your text is kept below."
                "processing_conflict" -> "The page is being processed. Wait for it to finish, then save again; your text is kept below."
                else -> e.message
            }
            load()
        } finally {
            saving = false
        }
    }

    fun openMove() = viewModelScope.launch {
        val page = page ?: return@launch
        if (notebooks.isEmpty()) notebooks = runCatching { api?.allNotebooks() }.getOrNull().orEmpty()
        move = MoveForm(page.pageNumber, page.notebook.id)
    }

    suspend fun applyMove(form: MoveForm): Boolean {
        val api = api ?: return false
        val page = page ?: return false
        val number = form.pageNumber.trim().toIntOrNull()
        if (number == null || number < 1) { form.error = "Enter a page number of at least 1."; return false }
        return try {
            api.movePage(id, page.version, number.takeIf { it != page.pageNumber }, form.notebookId.takeIf { it != page.notebook.id })
            message = StatusInfo.Kind.Ok to "Page updated."
            load(keepText = true)
            true
        } catch (e: ApiError) {
            form.error = when (e.code) {
                "page_number_conflict" -> "Another page already has that number. Choose a free number."
                "version_conflict" -> "This page changed on another device. Close and try again."
                else -> e.message
            }
            false
        }
    }

    fun rescan() = viewModelScope.launch {
        val page = page ?: return@launch
        val revision = page.revisionId ?: return@launch
        try {
            api?.rescan(id, page.contentVersion, revision, rescanOperationId)
            rescanOperationId = UUID.randomUUID().toString()
            message = StatusInfo.Kind.Ok to "Rescanning. The transcript updates when it finishes."
            load()
        } catch (e: Exception) {
            message = StatusInfo.Kind.Danger to describe(e)
        }
    }

    fun replace(bytes: ByteArray) = viewModelScope.launch {
        val page = page ?: return@launch
        try {
            container.replace(page, bytes)
            message = StatusInfo.Kind.Ok to "Replacement saved. It uploads and is processed automatically; see Uploads for progress."
        } catch (e: Exception) {
            message = StatusInfo.Kind.Danger to describe(e)
        }
    }

    suspend fun trash(): Boolean {
        val page = page ?: return false
        return try { api?.trashPage(id, page.version); true } catch (e: Exception) { message = StatusInfo.Kind.Danger to describe(e); false }
    }

    suspend fun originalUrl(): String? = try { api?.originalImageUrl(id)?.url } catch (e: Exception) { message = StatusInfo.Kind.Danger to describe(e); null }
}

@Composable
fun PageScreen(container: AppContainer, nav: NavController, id: String) {
    val model = viewModel(key = "page-$id") { PageViewModel(container, id) }
    val scope = rememberCoroutineScope()
    val context = LocalContext.current
    val uris = LocalUriHandler.current
    val brand = LocalBrand.current
    LaunchedEffect(id) { model.load() }
    val pickReplacement = rememberLauncherForActivityResult(ActivityResultContracts.PickVisualMedia()) { uri ->
        if (uri != null) readBytes(context, uri)?.let { model.replace(it) }
    }
    val camera = rememberCameraCapture { bytes -> model.replace(bytes) }

    Scaffold(topBar = {
        TopAppBar(
            title = { Text(model.page?.let { "Page ${it.pageNumber}" } ?: "Page") },
            navigationIcon = { IconButton(onClick = { nav.popBackStack() }) { Icon(Icons.AutoMirrored.Outlined.ArrowBack, "Back") } },
        )
    }) { padding ->
        Column(
            Modifier.fillMaxSize().padding(padding).verticalScroll(rememberScrollState()).padding(16.dp),
            verticalArrangement = Arrangement.spacedBy(16.dp),
        ) {
            if (model.gone) Banner(StatusInfo.Kind.Muted, "This page was moved to trash or deleted.")
            MessageBanner(model.message)
            val page = model.page ?: return@Column
            PageImage(page, ImageCache.Variant.Preview, container.services?.images,
                Modifier.background(brand.surface, RoundedCornerShape(10.dp)).padding(8.dp))
            Row(horizontalArrangement = Arrangement.SpaceBetween, modifier = Modifier.fillMaxWidth()) {
                Text(page.notebook.name, color = brand.textMuted)
                StatusBadge(page.processingStatus)
            }
            val explanation = when (page.processingStatus) {
                "needs_user_action" -> when (model.detail?.latestOperation?.errorCode) {
                    "unreadable" -> "The handwriting could not be read reliably. You can type the text below or rescan the page."
                    "no_text_detected" -> "No text was detected. If the page is blank, mark it blank below; otherwise type the text."
                    else -> "This page needs your attention: its content could not be recognized."
                }
                "failed" -> "Processing failed for a temporary reason. Your allowance for this page is held for a retry."
                "awaiting_processing" -> "Stored but not yet searchable. Process it from Account › Usage, or type the text yourself."
                else -> null
            }
            explanation?.let { Text(it) }
            if (page.indexingPending && page.processingStatus == "ready") {
                Text("Search is catching up with your latest edit.", style = MaterialTheme.typography.bodySmall, color = brand.textMuted)
            }

            Text("Transcript", style = MaterialTheme.typography.titleLarge)
            model.detail?.transcript?.let { t ->
                Text(
                    when { t.blank -> "Confirmed blank page."; t.origin == "user" -> "Edited by you."
                        else -> "Recognized text. Recognition can make mistakes; correct anything that looks wrong." },
                    style = MaterialTheme.typography.bodySmall, color = brand.textMuted,
                )
            }
            model.detail?.ocrCandidate?.let { candidate ->
                Column(Modifier.background(brand.surfaceRaised, RoundedCornerShape(8.dp)).padding(10.dp)) {
                    Text("A newer recognition of this photo is available:", style = MaterialTheme.typography.labelLarge)
                    Text(candidate.text, maxLines = 4, style = MaterialTheme.typography.bodySmall)
                    TextButton(onClick = { model.save(ApiClient.TranscriptAction.AcceptCandidate) }) { Text("Use the new recognition") }
                }
            }
            OutlinedTextField(
                model.text, { model.text = it },
                modifier = Modifier.fillMaxWidth().heightIn(min = 220.dp).semantics { contentDescription = "Transcript text" },
                textStyle = MaterialTheme.typography.bodyLarge.copy(fontFamily = FontFamily.Monospace),
                enabled = page.revisionId != null,
            )
            model.unsavedText?.let { unsaved ->
                Column(Modifier.background(brand.surfaceRaised, RoundedCornerShape(8.dp)).padding(10.dp)) {
                    Text("Your unsaved text", style = MaterialTheme.typography.labelLarge)
                    Text(unsaved, fontFamily = FontFamily.Monospace, style = MaterialTheme.typography.bodySmall)
                    TextButton(onClick = { model.text = unsaved }) { Text("Use my text") }
                }
            }
            Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                Button(onClick = { model.save() }, enabled = model.dirty && !model.saving && page.revisionId != null) {
                    Text(if (model.saving) "Saving…" else "Save transcript")
                }
                OutlinedButton(onClick = { model.save(ApiClient.TranscriptAction.ConfirmBlank) }, enabled = !model.saving && page.revisionId != null) {
                    Text("Mark as blank page")
                }
            }

            Text("Page", style = MaterialTheme.typography.titleLarge)
            TextButton(onClick = { model.openMove() }) { Text("Change page number or notebook") }
            TextButton(onClick = { scope.launch { model.originalUrl()?.let { uris.openUri(it) } } }) { Text("Open original photo") }
            if (model.processing) {
                Text("Rescanning and replacing are available when processing finishes.", style = MaterialTheme.typography.bodySmall, color = brand.textMuted)
            } else if (page.revisionId != null) {
                TextButton(onClick = { model.confirmRescan = true }) { Text("Rescan this photo") }
                TextButton(onClick = { pickReplacement.launch(PickVisualMediaRequest(ActivityResultContracts.PickVisualMedia.ImageOnly)) }) {
                    Text("Replace with a photo from the library")
                }
                if (camera.available) TextButton(onClick = { camera.launch() }) { Text("Replace with a new photo") }
            }
            TextButton(onClick = { model.confirmTrash = true }) { Text("Move page to trash", color = brand.danger) }
        }
    }

    model.move?.let { form ->
        MoveDialog(form, model.notebooks, { model.move = null }) { if (model.applyMove(form)) model.move = null }
    }
    if (model.confirmRescan) AlertDialog(
        onDismissRequest = { model.confirmRescan = false },
        title = { Text("Rescan this photo?") },
        text = { Text("The handwriting is read again. This uses one page of processing allowance; your edits stay in the page history.") },
        confirmButton = { TextButton(onClick = { model.confirmRescan = false; model.rescan() }) { Text("Rescan") } },
        dismissButton = { TextButton(onClick = { model.confirmRescan = false }) { Text("Cancel") } },
    )
    if (model.confirmTrash) AlertDialog(
        onDismissRequest = { model.confirmTrash = false },
        title = { Text("Move this page to trash?") },
        text = { Text("You can restore it from Trash for 30 days.") },
        confirmButton = { TextButton(onClick = { scope.launch { model.confirmTrash = false; if (model.trash()) nav.popBackStack() } }) { Text("Move to trash") } },
        dismissButton = { TextButton(onClick = { model.confirmTrash = false }) { Text("Cancel") } },
    )
}

@Composable
fun MoveDialog(form: MoveForm, notebooks: List<Notebook>, onDismiss: () -> Unit, onApply: suspend () -> Unit) {
    val scope = rememberCoroutineScope()
    var expanded by remember { mutableStateOf(false) }
    AlertDialog(
        onDismissRequest = onDismiss,
        title = { Text("Move page") },
        text = {
            Column(verticalArrangement = Arrangement.spacedBy(8.dp)) {
                OutlinedTextField(form.pageNumber, { form.pageNumber = it }, label = { Text("Page number") },
                    keyboardOptions = KeyboardOptions(keyboardType = KeyboardType.Number), singleLine = true)
                NotebookPicker(notebooks, form.notebookId, expanded, { expanded = it }) { form.notebookId = it }
                form.error?.let { Banner(StatusInfo.Kind.Danger, it) }
            }
        },
        confirmButton = { TextButton(onClick = { scope.launch { onApply() } }) { Text("Save") } },
        dismissButton = { TextButton(onClick = onDismiss) { Text("Cancel") } },
    )
}

@Composable
fun NotebookPicker(notebooks: List<Notebook>, selected: String?, expanded: Boolean, onExpanded: (Boolean) -> Unit, onSelect: (String) -> Unit) {
    ExposedDropdownMenuBox(expanded = expanded, onExpandedChange = onExpanded) {
        OutlinedTextField(
            value = notebooks.firstOrNull { it.id == selected }?.name ?: "Choose a notebook",
            onValueChange = {}, readOnly = true, label = { Text("Notebook") },
            trailingIcon = { ExposedDropdownMenuDefaults.TrailingIcon(expanded) },
            modifier = Modifier.menuAnchor(ExposedDropdownMenuAnchorType.PrimaryNotEditable).fillMaxWidth(),
        )
        ExposedDropdownMenu(expanded = expanded, onDismissRequest = { onExpanded(false) }) {
            notebooks.forEach { notebook ->
                DropdownMenuItem(text = { Text(notebook.name) }, onClick = { onSelect(notebook.id); onExpanded(false) })
            }
        }
    }
}

fun readBytes(context: android.content.Context, uri: Uri): ByteArray? =
    runCatching { context.contentResolver.openInputStream(uri)?.use { it.readBytes() } }.getOrNull()

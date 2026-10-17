package app.libarrie.android.ui

import android.content.Context
import android.content.pm.PackageManager
import android.graphics.BitmapFactory
import android.net.Uri
import androidx.activity.compose.rememberLauncherForActivityResult
import androidx.activity.result.PickVisualMediaRequest
import androidx.activity.result.contract.ActivityResultContracts
import androidx.compose.foundation.Image
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.itemsIndexed
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.outlined.ArrowDownward
import androidx.compose.material.icons.outlined.ArrowUpward
import androidx.compose.material.icons.outlined.CameraAlt
import androidx.compose.material.icons.outlined.Close
import androidx.compose.material.icons.outlined.Delete
import androidx.compose.material.icons.outlined.PhotoLibrary
import androidx.compose.material3.Button
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.LinearProgressIndicator
import androidx.compose.material3.ListItem
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.OutlinedButton
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.Scaffold
import androidx.compose.material3.Text
import androidx.compose.material3.TopAppBar
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.setValue
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.ImageBitmap
import androidx.compose.ui.graphics.asImageBitmap
import androidx.compose.ui.layout.ContentScale
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.text.input.KeyboardType
import androidx.compose.ui.unit.dp
import androidx.core.content.FileProvider
import androidx.lifecycle.ViewModel
import androidx.lifecycle.viewModelScope
import androidx.lifecycle.viewmodel.compose.viewModel
import androidx.navigation.NavController
import app.libarrie.android.AppContainer
import app.libarrie.core.api.Notebook
import app.libarrie.core.queue.CaptureItem
import app.libarrie.core.queue.CaptureState
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import java.io.File
import java.util.UUID

/**
 * Capture or import several photos, choose the notebook once, set the
 * starting page number, review the order, then queue them (section 2,
 * journey 2). Photos are saved on the device as soon as they are taken.
 */
class CaptureViewModel(private val container: AppContainer, batch: String, notebookId: String) : ViewModel() {
    val batch = batch.ifEmpty { UUID.randomUUID().toString() }
    var notebooks by mutableStateOf<List<Notebook>>(emptyList())
    var notebookId by mutableStateOf(notebookId.ifEmpty { null })
    var startPage by mutableStateOf("1")
    var order by mutableStateOf<List<String>>(emptyList())
    var importing by mutableStateOf(false)
    var problems by mutableStateOf<List<String>>(emptyList())

    init { syncOrder(); load() }

    val items: List<CaptureItem>
        get() {
            val byId = container.queue.filter { it.batchId == batch && it.state == CaptureState.Captured }.associateBy { it.id }
            return order.mapNotNull { byId[it] }
        }

    val notebook get() = notebooks.firstOrNull { it.id == notebookId }
    val canQueue get() = items.isNotEmpty() && notebook != null && (startPage.trim().toIntOrNull() ?: 0) >= 1 && !importing

    fun syncOrder() {
        val captured = container.queue.filter { it.batchId == batch && it.state == CaptureState.Captured }.sortedBy { it.sequence }
        val ids = captured.map { it.id }
        order = order.filter { it in ids } + ids.filter { it !in order }
    }

    private fun load() = viewModelScope.launch {
        notebooks = runCatching { container.services?.api?.allNotebooks() }.getOrNull().orEmpty()
        if (notebookId == null) notebookId = notebooks.firstOrNull()?.id
        suggestStartPage()
    }

    fun selectNotebook(id: String) {
        notebookId = id
        viewModelScope.launch { suggestStartPage() }
    }

    private suspend fun suggestStartPage() {
        val id = notebookId ?: return
        runCatching { container.services?.api?.numbering(id) }.getOrNull()?.let { startPage = it.nextFree.toString() }
    }

    fun add(photos: List<ByteArray>) = viewModelScope.launch {
        importing = true
        problems = problems + container.capture(photos, batch)
        syncOrder()
        importing = false
    }

    fun move(index: Int, delta: Int) {
        val target = index + delta
        if (target !in order.indices) return
        order = order.toMutableList().also { val item = it.removeAt(index); it.add(target, item) }
    }

    fun remove(id: String) = viewModelScope.launch { container.discard(id); syncOrder() }

    suspend fun queue(): Boolean {
        val notebook = notebook ?: return false
        val start = startPage.trim().toIntOrNull()?.takeIf { it >= 1 } ?: return false
        container.commit(order, notebook, start)
        return true
    }
}

/** The system camera writing to a private file; returns the JPEG bytes. */
class CameraCapture(val available: Boolean, val launch: () -> Unit)

@Composable
fun rememberCameraCapture(onPhoto: (ByteArray) -> Unit): CameraCapture {
    val context = LocalContext.current
    var target by remember { mutableStateOf<Pair<File, Uri>?>(null) }
    val launcher = rememberLauncherForActivityResult(ActivityResultContracts.TakePicture()) { saved ->
        val (file, _) = target ?: return@rememberLauncherForActivityResult
        if (saved && file.length() > 0) onPhoto(file.readBytes())
        file.delete()
        target = null
    }
    val available = context.packageManager.hasSystemFeature(PackageManager.FEATURE_CAMERA_ANY)
    return CameraCapture(available) {
        val file = cameraFile(context)
        val uri = FileProvider.getUriForFile(context, "${context.packageName}.files", file)
        target = file to uri
        launcher.launch(uri)
    }
}

private fun cameraFile(context: Context): File =
    File(context.cacheDir, "camera").apply { mkdirs() }.let { File(it, "${UUID.randomUUID()}.jpg") }

@Composable
fun CaptureScreen(container: AppContainer, nav: NavController, batch: String, notebookId: String) {
    val model = viewModel(key = "capture-$batch-$notebookId") { CaptureViewModel(container, batch, notebookId) }
    val context = LocalContext.current
    val scope = rememberCoroutineScope()
    var notebookMenu by remember { mutableStateOf(false) }
    val library = rememberLauncherForActivityResult(ActivityResultContracts.PickMultipleVisualMedia(100)) { uris ->
        scope.launch {
            val photos = withContext(Dispatchers.IO) { uris.mapNotNull { readBytes(context, it) } }
            if (photos.size < uris.size) model.problems = model.problems + "A photo from the library could not be read."
            model.add(photos)
        }
    }
    val camera = rememberCameraCapture { model.add(listOf(it)) }
    LaunchedEffect(container.queue) { model.syncOrder() }

    Scaffold(topBar = {
        TopAppBar(
            title = { Text("Add pages") },
            navigationIcon = {
                // Photos stay saved on the device; finish them later from Uploads.
                IconButton(onClick = { nav.popBackStack() }) { Icon(Icons.Outlined.Close, "Later") }
            },
        )
    }) { padding ->
        LazyColumn(Modifier.fillMaxSize().padding(padding), contentPadding = androidx.compose.foundation.layout.PaddingValues(16.dp),
            verticalArrangement = Arrangement.spacedBy(12.dp)) {
            item {
                NotebookPicker(model.notebooks, model.notebookId, notebookMenu, { notebookMenu = it }) { model.selectNotebook(it) }
            }
            item {
                OutlinedTextField(model.startPage, { model.startPage = it }, label = { Text("Starting page number") },
                    keyboardOptions = KeyboardOptions(keyboardType = KeyboardType.Number), singleLine = true, modifier = Modifier.fillMaxWidth())
                Text("Each photo becomes one page, numbered in the order below. Crop a two-page spread into two photos first.",
                    style = MaterialTheme.typography.bodySmall, color = LocalBrand.current.textMuted)
            }
            item {
                Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                    if (camera.available) OutlinedButton(onClick = camera.launch) {
                        Icon(Icons.Outlined.CameraAlt, null); Text(" Take a photo")
                    }
                    OutlinedButton(onClick = { library.launch(PickVisualMediaRequest(ActivityResultContracts.PickVisualMedia.ImageOnly)) }) {
                        Icon(Icons.Outlined.PhotoLibrary, null); Text(" Choose from library")
                    }
                }
            }
            if (model.importing) item { LinearProgressIndicator(Modifier.fillMaxWidth()) }
            model.problems.forEach { problem -> item { Banner(StatusInfo.Kind.Warning, problem) } }
            if (model.items.isNotEmpty()) item { Text("Review order", style = MaterialTheme.typography.titleMedium) }
            itemsIndexed(model.items, key = { _, item -> item.id }) { index, item ->
                val number = (model.startPage.trim().toIntOrNull() ?: 1) + index
                ListItem(
                    leadingContent = { LocalThumbnail(container, item) },
                    headlineContent = { Text("Page $number") },
                    supportingContent = { Text("Saved on this device") },
                    trailingContent = {
                        Row {
                            IconButton(onClick = { model.move(index, -1) }, enabled = index > 0) { Icon(Icons.Outlined.ArrowUpward, "Move page $number earlier") }
                            IconButton(onClick = { model.move(index, 1) }, enabled = index < model.items.lastIndex) { Icon(Icons.Outlined.ArrowDownward, "Move page $number later") }
                            IconButton(onClick = { model.remove(item.id) }) { Icon(Icons.Outlined.Delete, "Remove page $number") }
                        }
                    },
                )
            }
            item {
                Button(onClick = { scope.launch { if (model.queue()) nav.popBackStack() } }, enabled = model.canQueue, modifier = Modifier.fillMaxWidth()) {
                    Text("Upload ${plural(model.items.size, "page")}")
                }
            }
        }
    }
}

@Composable
fun LocalThumbnail(container: AppContainer, item: CaptureItem) {
    var bitmap by remember(item.id) { mutableStateOf<ImageBitmap?>(null) }
    LaunchedEffect(item.id) {
        bitmap = withContext(Dispatchers.IO) {
            container.fileFor(item)?.takeIf { it.isFile }?.let { file ->
                val options = BitmapFactory.Options().apply { inSampleSize = 8 }
                BitmapFactory.decodeFile(file.path, options)?.asImageBitmap()
            }
        }
    }
    bitmap?.let { Image(it, contentDescription = null, contentScale = ContentScale.Crop, modifier = Modifier.size(56.dp, 72.dp)) }
}

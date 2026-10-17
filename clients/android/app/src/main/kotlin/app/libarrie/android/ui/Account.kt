package app.libarrie.android.ui

import android.content.Intent
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.selection.selectable
import androidx.compose.foundation.selection.toggleable
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.outlined.ArrowBack
import androidx.compose.material.icons.outlined.Delete
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.Button
import androidx.compose.material3.Checkbox
import androidx.compose.material3.HorizontalDivider
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.ListItem
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.OutlinedButton
import androidx.compose.material3.RadioButton
import androidx.compose.material3.Scaffold
import androidx.compose.material3.Switch
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
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.platform.LocalUriHandler
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.unit.dp
import androidx.core.content.FileProvider
import androidx.lifecycle.ViewModel
import androidx.lifecycle.viewModelScope
import androidx.lifecycle.viewmodel.compose.viewModel
import androidx.navigation.NavController
import app.libarrie.android.AppContainer
import app.libarrie.android.ThemePreference
import app.libarrie.core.api.AccountDeletionStatus
import app.libarrie.core.api.ApiClient
import app.libarrie.core.api.ApiError
import app.libarrie.core.api.Export
import app.libarrie.core.api.ExportPart
import app.libarrie.core.api.Notebook
import app.libarrie.core.api.Page
import app.libarrie.core.api.TrashList
import app.libarrie.core.api.Usage
import app.libarrie.core.queue.CaptureState
import kotlinx.coroutines.delay
import kotlinx.coroutines.launch
import java.util.UUID

/** Runs an action that needs a sign-in within five minutes, asking for one first if needed. */
suspend fun AppContainer.withRecentSignIn(action: suspend () -> Unit) {
    if (!hasRecentSignIn()) reauthenticate()
    try {
        action()
    } catch (e: ApiError) {
        if (e.code != "reauthentication_required") throw e
        reauthenticate()
        action()
    }
}

@Composable
private fun BackBar(title: String, nav: NavController) {
    TopAppBar(title = { Text(title) }, navigationIcon = { IconButton(onClick = { nav.popBackStack() }) { Icon(Icons.AutoMirrored.Outlined.ArrowBack, "Back") } })
}

class AccountViewModel(private val container: AppContainer) : ViewModel() {
    var deletion by mutableStateOf<AccountDeletionStatus?>(null)
    var message by mutableStateOf<Message?>(null)
    var working by mutableStateOf(false)
    var confirmed by mutableStateOf(false)
    var acknowledgement by mutableStateOf<String?>(null)
    var acknowledged by mutableStateOf(false)

    fun load() = viewModelScope.launch { deletion = runCatching { container.services?.api?.accountDeletionStatus() }.getOrNull() }

    suspend fun scheduleDeletion(): Boolean {
        val api = container.services?.api ?: return false
        working = true
        return try {
            container.withRecentSignIn { deletion = api.scheduleAccountDeletion(acknowledged) }
            message = StatusInfo.Kind.Warning to "Account deletion scheduled."
            load()
            true
        } catch (e: ApiError) {
            if (e.code == "acknowledgement_required") acknowledgement = e.message else message = StatusInfo.Kind.Danger to e.message
            false
        } catch (e: Exception) {
            message = StatusInfo.Kind.Danger to describe(e)
            false
        } finally {
            working = false
        }
    }

    fun cancelDeletion() = viewModelScope.launch {
        val api = container.services?.api ?: return@launch
        val revision = deletion?.lifecycleRevision ?: return@launch
        working = true
        try {
            container.withRecentSignIn { deletion = api.cancelAccountDeletion(revision) }
            message = StatusInfo.Kind.Ok to "Account deletion cancelled. Your account is fully active again."
            load()
        } catch (e: Exception) {
            message = StatusInfo.Kind.Danger to describe(e)
        } finally {
            working = false
        }
    }
}

@Composable
fun AccountScreen(container: AppContainer, nav: NavController) {
    val model = viewModel { AccountViewModel(container) }
    var confirmSignOut by remember { mutableStateOf(false) }
    val brand = LocalBrand.current
    LaunchedEffect(Unit) { model.load() }
    Scaffold(topBar = { TopAppBar(title = { Text("Account") }) }) { padding ->
        LazyColumn(Modifier.fillMaxSize().padding(padding)) {
            item { MessageBanner(model.message, Modifier.padding(16.dp)) }
            item {
                ListItem(headlineContent = { Text(container.me?.user?.displayName ?: "Signed in") },
                    supportingContent = { container.services?.serverUrl?.let { Text(it) } })
            }
            if (model.deletion?.status == "closure_scheduled") item {
                Column(Modifier.padding(16.dp), verticalArrangement = Arrangement.spacedBy(8.dp)) {
                    Banner(StatusInfo.Kind.Warning, "Your account will be deleted ${model.deletion?.effectiveAt?.let { "on ${formatDate(it)}" } ?: "soon"}. Until then you can read, search and export, but not add or change notes.")
                    Button(onClick = { model.cancelDeletion() }, enabled = !model.working) { Text("Keep my account") }
                }
            }
            listOf("Usage" to Routes.Usage, "Trash" to Routes.Trash, "Export your notes" to Routes.Exports, "Settings" to Routes.Settings).forEach { (label, route) ->
                item { ListItem(headlineContent = { Text(label) }, modifier = Modifier.clickable { nav.navigate(route) }); HorizontalDivider() }
            }
            item { ListItem(headlineContent = { Text("Sign out") }, modifier = Modifier.clickable { confirmSignOut = true }) }
            if (model.deletion?.status != "closure_scheduled") item {
                ListItem(headlineContent = { Text("Delete account", color = brand.danger) }, modifier = Modifier.clickable { nav.navigate(Routes.DeleteAccount) })
            }
        }
    }
    if (confirmSignOut) {
        val pending = container.accountQueue.count { it.state != CaptureState.ServerAccepted }
        AlertDialog(
            onDismissRequest = { confirmSignOut = false },
            title = { Text("Sign out?") },
            text = {
                Text(if (pending == 0) "Cached images are removed from this device."
                else "${plural(pending, "photo")} not uploaded yet. They stay on this device and upload when you sign in to this account again.")
            },
            confirmButton = { TextButton(onClick = { confirmSignOut = false; container.signOut() }) { Text("Sign out") } },
            dismissButton = { TextButton(onClick = { confirmSignOut = false }) { Text("Cancel") } },
        )
    }
}

@Composable
fun DeleteAccountScreen(container: AppContainer, nav: NavController) {
    val model = viewModel { AccountViewModel(container) }
    val scope = rememberCoroutineScope()
    Scaffold(topBar = { BackBar("Delete account", nav) }) { padding ->
        LazyColumn(Modifier.fillMaxSize().padding(padding), contentPadding = PaddingValues(16.dp), verticalArrangement = Arrangement.spacedBy(12.dp)) {
            item { MessageBanner(model.message) }
            item { Text("What happens", style = MaterialTheme.typography.titleMedium) }
            item { Text("Right away, you can no longer add or change notes. Uploads and processing in progress stop.") }
            item { Text("During a grace period you can still read, search and export your notes, and cancel the deletion.") }
            item { Text("After that, all notebooks, photos, transcripts and exports are deleted permanently.") }
            item { TextButton(onClick = { nav.navigate(Routes.Exports) }) { Text("Export your notes first") } }
            model.acknowledgement?.let { ack ->
                item { Banner(StatusInfo.Kind.Warning, ack) }
                item { CheckRow("I understand", model.acknowledged) { model.acknowledged = it } }
            }
            item { CheckRow("I want to delete my account and all of my notes", model.confirmed) { model.confirmed = it } }
            item {
                Button(
                    onClick = { scope.launch { if (model.scheduleDeletion()) nav.popBackStack() } },
                    enabled = model.confirmed && !model.working && (model.acknowledgement == null || model.acknowledged),
                ) { Text("Delete account") }
                Text("You will be asked to sign in again to confirm.", style = MaterialTheme.typography.bodySmall)
            }
        }
    }
}

@Composable
fun CheckRow(label: String, checked: Boolean, onChange: (Boolean) -> Unit) {
    Row(Modifier.fillMaxWidth().toggleable(checked, role = Role.Checkbox, onValueChange = onChange), verticalAlignment = Alignment.CenterVertically) {
        Checkbox(checked, onCheckedChange = null)
        Text(label, Modifier.padding(start = 8.dp))
    }
}

// Usage ---------------------------------------------------------------------------------------

class UsageViewModel(private val container: AppContainer) : ViewModel() {
    var usage by mutableStateOf<Usage?>(null)
    var awaiting by mutableStateOf<List<Page>>(emptyList())
    var message by mutableStateOf<Message?>(null)
    var processing by mutableStateOf(false)

    fun load() = viewModelScope.launch {
        val api = container.services?.api ?: return@launch
        try {
            usage = api.usage()
            awaiting = api.awaitingProcessing()
        } catch (e: Exception) {
            message = StatusInfo.Kind.Danger to describe(e)
        }
    }

    fun processNow() = viewModelScope.launch {
        val api = container.services?.api ?: return@launch
        val items = awaiting.mapNotNull { page -> page.revisionId?.let { ApiClient.DeferredItem(page.id, it, UUID.randomUUID().toString()) } }
        if (items.isEmpty()) return@launch
        processing = true
        try {
            val results = api.processDeferred(items)
            val started = results.count { it.result == "admitted" || it.result == "already_admitted" }
            val limited = results.count { it.result == "limit" }
            message = if (limited == 0) StatusInfo.Kind.Ok to "${plural(started, "page")} started processing."
            else StatusInfo.Kind.Warning to "$started started; $limited still wait because your processing allowance is used up."
            load()
        } catch (e: Exception) {
            message = StatusInfo.Kind.Danger to describe(e)
        } finally {
            processing = false
        }
    }
}

@Composable
fun UsageScreen(container: AppContainer, nav: NavController) {
    val model = viewModel { UsageViewModel(container) }
    LaunchedEffect(Unit) { model.load() }
    Scaffold(topBar = { BackBar("Usage", nav) }) { padding ->
        LazyColumn(Modifier.fillMaxSize().padding(padding), contentPadding = PaddingValues(16.dp), verticalArrangement = Arrangement.spacedBy(12.dp)) {
            item { MessageBanner(model.message) }
            model.usage?.let { usage ->
                when (usage.capacityWarning) {
                    "at_capacity" -> item { Banner(StatusInfo.Kind.Warning, "You have reached your page limit. Existing notes stay readable and searchable; new pages cannot be added.") }
                    "above_90_percent" -> item { Banner(StatusInfo.Kind.Warning, "You have used more than 90% of your page limit.") }
                    "above_80_percent" -> item { Banner(StatusInfo.Kind.Muted, "You have used more than 80% of your page limit.") }
                }
                item { Stat("Stored pages", "${usage.storedPages} of ${usage.limits.storedPages}") }
                item { Stat("Uploads in progress", "${usage.reservedPageSlots}") }
                item { Stat("Notebooks", "${usage.notebooks} of ${usage.limits.notebooks}") }
                usage.lifetimeAllowance?.let { a ->
                    item { Stat("Pages processed", "${a.used} of ${a.limit}" + if (a.reserved > 0) " (${a.reserved} in progress)" else "") }
                }
            }
            if (model.awaiting.isNotEmpty()) {
                item { Text("Waiting for processing", style = MaterialTheme.typography.titleMedium) }
                item { Text("${plural(model.awaiting.size, "page")} uploaded to be processed later. They are stored and viewable, but not yet searchable.") }
                item { Button(onClick = { model.processNow() }, enabled = !model.processing) { Text(if (model.processing) "Starting…" else "Process now") } }
            }
        }
    }
}

@Composable
private fun Stat(label: String, value: String) {
    Row(Modifier.fillMaxWidth(), horizontalArrangement = Arrangement.SpaceBetween) {
        Text(label, style = MaterialTheme.typography.titleSmall)
        Text(value)
    }
}

// Trash ---------------------------------------------------------------------------------------

sealed interface PurgeTarget {
    data class OnePage(val page: Page) : PurgeTarget
    data class OneNotebook(val notebook: Notebook) : PurgeTarget
    data object Everything : PurgeTarget
}

class TrashViewModel(private val container: AppContainer) : ViewModel() {
    var trash by mutableStateOf<TrashList?>(null)
    var message by mutableStateOf<Message?>(null)
    var purgeTarget by mutableStateOf<PurgeTarget?>(null)

    fun load() = viewModelScope.launch {
        try { trash = container.services?.api?.trash() } catch (e: Exception) { message = StatusInfo.Kind.Danger to describe(e) }
    }

    fun restorePage(page: Page) = viewModelScope.launch {
        try { container.services?.api?.restorePage(page.id); message = StatusInfo.Kind.Ok to "Restoring. It will reappear shortly."; load() }
        catch (e: Exception) { message = StatusInfo.Kind.Danger to describe(e) }
    }

    fun restoreNotebook(notebook: Notebook) = viewModelScope.launch {
        try { container.services?.api?.restoreNotebook(notebook.id); message = StatusInfo.Kind.Ok to "Restoring. It will appear in your notebooks shortly."; load() }
        catch (e: Exception) { message = StatusInfo.Kind.Danger to describe(e) }
    }

    fun purge(target: PurgeTarget) = viewModelScope.launch {
        val api = container.services?.api ?: return@launch
        try {
            container.withRecentSignIn {
                when (target) {
                    is PurgeTarget.OnePage -> api.purge(pageIds = listOf(target.page.id))
                    is PurgeTarget.OneNotebook -> api.purge(notebookIds = listOf(target.notebook.id))
                    PurgeTarget.Everything -> api.purge(all = true)
                }
            }
            message = StatusInfo.Kind.Ok to "Deleting permanently. This can take a few minutes to finish."
            load()
        } catch (e: ApiError) {
            message = if (e.code == "recovery_pending") StatusInfo.Kind.Warning to "Your previous change to this item is still being recorded safely. Try again in a minute."
            else StatusInfo.Kind.Danger to e.message
        } catch (e: Exception) {
            message = StatusInfo.Kind.Danger to describe(e)
        }
    }
}

@Composable
fun TrashScreen(container: AppContainer, nav: NavController) {
    val model = viewModel { TrashViewModel(container) }
    LaunchedEffect(Unit) { model.load() }
    val trash = model.trash
    Scaffold(topBar = {
        TopAppBar(
            title = { Text("Trash") },
            navigationIcon = { IconButton(onClick = { nav.popBackStack() }) { Icon(Icons.AutoMirrored.Outlined.ArrowBack, "Back") } },
            actions = {
                if (trash != null && (trash.pages.isNotEmpty() || trash.notebooks.isNotEmpty())) {
                    TextButton(onClick = { model.purgeTarget = PurgeTarget.Everything }) { Text("Empty trash") }
                }
            },
        )
    }) { padding ->
        LazyColumn(Modifier.fillMaxSize().padding(padding), contentPadding = PaddingValues(16.dp), verticalArrangement = Arrangement.spacedBy(8.dp)) {
            item { MessageBanner(model.message) }
            item { Text("Items in trash are deleted permanently after ${trash?.retentionDays ?: 30} days.", style = MaterialTheme.typography.bodySmall) }
            if (trash != null && trash.pages.isEmpty() && trash.notebooks.isEmpty()) item { Text("Trash is empty.") }
            if (!trash?.notebooks.isNullOrEmpty()) item { Text("Notebooks", style = MaterialTheme.typography.titleMedium) }
            items(trash?.notebooks.orEmpty(), key = { "n" + it.id }) { notebook ->
                TrashRow(notebook.name, { model.restoreNotebook(notebook) }) { model.purgeTarget = PurgeTarget.OneNotebook(notebook) }
            }
            if (!trash?.pages.isNullOrEmpty()) item { Text("Pages", style = MaterialTheme.typography.titleMedium) }
            items(trash?.pages.orEmpty(), key = { "p" + it.id }) { page ->
                TrashRow("${page.notebook.name} · Page ${page.pageNumber}", { model.restorePage(page) }) { model.purgeTarget = PurgeTarget.OnePage(page) }
            }
        }
    }
    model.purgeTarget?.let { target ->
        AlertDialog(
            onDismissRequest = { model.purgeTarget = null },
            title = { Text("Delete permanently?") },
            text = { Text("This removes the photos, transcripts and search data and cannot be undone. You will be asked to sign in again to confirm.") },
            confirmButton = { TextButton(onClick = { model.purgeTarget = null; model.purge(target) }) { Text("Delete permanently") } },
            dismissButton = { TextButton(onClick = { model.purgeTarget = null }) { Text("Cancel") } },
        )
    }
}

@Composable
private fun TrashRow(title: String, restore: () -> Unit, purge: () -> Unit) {
    Row(Modifier.fillMaxWidth(), verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(8.dp)) {
        Text(title, Modifier.weight(1f))
        OutlinedButton(onClick = restore) { Text("Restore") }
        IconButton(onClick = purge) { Icon(Icons.Outlined.Delete, "Delete $title permanently", tint = LocalBrand.current.danger) }
    }
}

// Exports -------------------------------------------------------------------------------------

class ExportsViewModel(private val container: AppContainer) : ViewModel() {
    var exports by mutableStateOf<List<Export>>(emptyList())
    var parts by mutableStateOf<Map<String, List<ExportPart>>>(emptyMap())
    var includeTrash by mutableStateOf(false)
    var message by mutableStateOf<Message?>(null)
    var working by mutableStateOf(false)

    init {
        viewModelScope.launch {
            while (true) {
                delay(5000)
                if (exports.any { it.state == "assembling" }) load()
            }
        }
    }

    fun load() = viewModelScope.launch {
        val api = container.services?.api ?: return@launch
        try {
            exports = api.exports()
            val known = parts.toMutableMap()
            for (export in exports.filter { it.state == "completed" && it.id !in known }) {
                runCatching { api.export(export.id).parts }.getOrNull()?.let { known[export.id] = it }
            }
            parts = known
        } catch (e: Exception) {
            message = StatusInfo.Kind.Danger to describe(e)
        }
    }

    fun start() = viewModelScope.launch {
        val api = container.services?.api ?: return@launch
        working = true
        try {
            api.createExport(null, includeTrash)
            message = StatusInfo.Kind.Ok to "Export started. This screen updates when your files are ready."
            load()
        } catch (e: Exception) {
            message = StatusInfo.Kind.Danger to describe(e)
        } finally {
            working = false
        }
    }

    suspend fun url(export: Export, part: ExportPart): String? =
        try { container.services?.api?.exportPartUrl(export.id, part.partNumber)?.url } catch (e: Exception) { message = StatusInfo.Kind.Danger to describe(e); null }
}

@Composable
fun ExportsScreen(container: AppContainer, nav: NavController) {
    val model = viewModel { ExportsViewModel(container) }
    val uris = LocalUriHandler.current
    val scope = rememberCoroutineScope()
    LaunchedEffect(Unit) { model.load() }
    Scaffold(topBar = { BackBar("Exports", nav) }) { padding ->
        LazyColumn(Modifier.fillMaxSize().padding(padding), contentPadding = PaddingValues(16.dp), verticalArrangement = Arrangement.spacedBy(12.dp)) {
            item { MessageBanner(model.message) }
            item { Text("Every original photo with its transcript, in ZIP files. Downloads stay available for 7 days.") }
            item { CheckRow("Include pages in trash", model.includeTrash) { model.includeTrash = it } }
            item { Button(onClick = { model.start() }, enabled = !model.working) { Text(if (model.working) "Starting…" else "Export everything") } }
            item { Text("Your exports", style = MaterialTheme.typography.titleMedium) }
            if (model.exports.isEmpty()) item { Text("No exports yet.", color = LocalBrand.current.textMuted) }
            items(model.exports, key = { it.id }) { export ->
                Column(verticalArrangement = Arrangement.spacedBy(4.dp)) {
                    Row(Modifier.fillMaxWidth(), horizontalArrangement = Arrangement.SpaceBetween) {
                        Text(formatDate(export.createdAt), style = MaterialTheme.typography.titleSmall)
                        Text(when (export.state) { "assembling" -> "Preparing"; "completed" -> "Ready"; "expired" -> "Expired"; "failed" -> "Failed"; else -> export.state })
                    }
                    Text(plural(export.itemCount, "page") + (if (export.totalBytes > 0) " · ${formatBytes(export.totalBytes)}" else "") +
                        (if (export.state == "completed") " · until ${formatDate(export.expiresAt)}" else ""),
                        style = MaterialTheme.typography.bodySmall, color = LocalBrand.current.textMuted)
                    model.parts[export.id].orEmpty().forEach { part ->
                        TextButton(onClick = { scope.launch { model.url(export, part)?.let { uris.openUri(it) } } }) {
                            Text("Download part ${part.partNumber}" + (part.bytes?.let { " (${formatBytes(it)})" } ?: ""))
                        }
                    }
                    HorizontalDivider()
                }
            }
        }
    }
}

// Settings ------------------------------------------------------------------------------------

/** The server-side processing preference. */
class ServerSettingsViewModel(private val container: AppContainer) : ViewModel() {
    var autoProcessDeferred by mutableStateOf<Boolean?>(null)
    var message by mutableStateOf<Message?>(null)

    init {
        viewModelScope.launch { autoProcessDeferred = runCatching { container.services?.api?.settings() }.getOrNull()?.autoProcessDeferred }
    }

    fun set(value: Boolean) = viewModelScope.launch {
        val previous = autoProcessDeferred
        autoProcessDeferred = value
        try {
            autoProcessDeferred = container.services?.api?.updateSettings(value)?.autoProcessDeferred
        } catch (e: Exception) {
            autoProcessDeferred = previous
            message = StatusInfo.Kind.Danger to describe(e)
        }
    }
}

@Composable
fun SettingsScreen(container: AppContainer, nav: NavController) {
    val settings = container.settings
    val server = viewModel { ServerSettingsViewModel(container) }
    val scope = rememberCoroutineScope()
    val context = LocalContext.current
    Scaffold(topBar = { BackBar("Settings", nav) }) { padding ->
        LazyColumn(Modifier.fillMaxSize().padding(padding), contentPadding = PaddingValues(16.dp), verticalArrangement = Arrangement.spacedBy(12.dp)) {
            item { Text("Appearance", style = MaterialTheme.typography.titleMedium) }
            items(ThemePreference.entries) { theme ->
                Row(Modifier.fillMaxWidth().selectable(settings.theme == theme, role = Role.RadioButton) { settings.theme = theme; settings.save() },
                    verticalAlignment = Alignment.CenterVertically) {
                    RadioButton(settings.theme == theme, onClick = null)
                    Text(theme.name, Modifier.padding(start = 8.dp))
                }
            }
            item { MessageBanner(server.message) }
            server.autoProcessDeferred?.let { automatic ->
                item {
                    SwitchRow("Process pages uploaded for later automatically", automatic) { server.set(it) }
                    Text("When processing allowance becomes available, pages you uploaded to process later start on their own. Off: they wait until you choose Process now under Usage.",
                        style = MaterialTheme.typography.bodySmall)
                }
            }
            item {
                SwitchRow("Keep location in photos", settings.keepLocation) { settings.keepLocation = it; settings.save() }
                Text("Off by default: GPS location is removed from photos before they are saved or uploaded.", style = MaterialTheme.typography.bodySmall)
            }
            item {
                SwitchRow("Include photos waiting to upload in device backups", settings.backUpPendingCaptures) {
                    scope.launch { container.setBackUpPendingCaptures(it) }
                }
                Text(
                    if (settings.backUpPendingCaptures) "Photos not yet backed up by Libarrie are included in your device backup, if you have one enabled."
                    else "Photos not yet backed up by Libarrie exist only on this device until they upload. Losing the device loses them.",
                    style = MaterialTheme.typography.bodySmall,
                )
            }
            val pending = container.queue.filter { it.state != CaptureState.ServerAccepted && !it.localFileRemoved }
            if (pending.isNotEmpty()) item {
                OutlinedButton(onClick = {
                    // A portable copy of photos not yet stored by Libarrie.
                    // Copied to cache/share first: captures may live in no_backup, which FileProvider cannot serve.
                    val shareDir = java.io.File(context.cacheDir, "share").apply { deleteRecursively(); mkdirs() }
                    val uris = ArrayList(pending.mapNotNull { container.fileFor(it) }.filter { it.isFile }.map {
                        val copy = it.copyTo(java.io.File(shareDir, it.name), overwrite = true)
                        FileProvider.getUriForFile(context, "${context.packageName}.files", copy)
                    })
                    val send = Intent(Intent.ACTION_SEND_MULTIPLE).apply {
                        type = "image/*"
                        putParcelableArrayListExtra(Intent.EXTRA_STREAM, uris)
                        addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
                    }
                    context.startActivity(Intent.createChooser(send, "Save photos waiting to upload"))
                }) { Text("Save ${plural(pending.size, "photo")} waiting to upload") }
            }
        }
    }
}

@Composable
private fun SwitchRow(label: String, checked: Boolean, onChange: (Boolean) -> Unit) {
    Row(Modifier.fillMaxWidth().toggleable(checked, role = Role.Switch, onValueChange = onChange), verticalAlignment = Alignment.CenterVertically) {
        Text(label, Modifier.weight(1f))
        Switch(checked, onCheckedChange = null)
    }
}

package app.libarrie.android.ui

import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.LazyListScope
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.HorizontalDivider
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
import androidx.compose.ui.text.input.KeyboardType
import androidx.compose.ui.unit.dp
import androidx.navigation.NavController
import app.libarrie.android.AppContainer
import app.libarrie.core.queue.AttentionReason
import app.libarrie.core.queue.BackupState
import app.libarrie.core.queue.CaptureItem
import app.libarrie.core.queue.CaptureState
import app.libarrie.core.queue.DeferredDecision
import kotlinx.coroutines.delay
import kotlinx.coroutines.launch

/**
 * The capture queue, with the distinct states the design requires: saved on
 * this device, uploaded to Libarrie, independent backup verified.
 */
@Composable
fun UploadsScreen(container: AppContainer, nav: NavController) {
    val scope = rememberCoroutineScope()
    val brand = LocalBrand.current
    var renumbering by remember { mutableStateOf<CaptureItem?>(null) }
    var newNumber by remember { mutableStateOf("") }
    var removing by remember { mutableStateOf<CaptureItem?>(null) }
    LaunchedEffect(Unit) {
        while (true) {
            container.runQueue()
            delay(10_000)
        }
    }
    val items = container.accountQueue
    val attention = items.filter { it.state == CaptureState.NeedsUserAction }
    val unreviewed = items.filter { it.state == CaptureState.Captured }.groupBy { it.batchId }
    val moving = items.filter { it.state in setOf(CaptureState.Ready, CaptureState.Reserving, CaptureState.Uploading, CaptureState.Confirming, CaptureState.RetryableError) }
    val accepted = items.filter { it.state == CaptureState.ServerAccepted && it.backup != BackupState.Verified }
    val verified = items.filter { it.state == CaptureState.ServerAccepted && it.backup == BackupState.Verified }

    Scaffold(topBar = { TopAppBar(title = { Text("Uploads") }) }) { padding ->
        LazyColumn(Modifier.fillMaxSize().padding(padding), contentPadding = androidx.compose.foundation.layout.PaddingValues(16.dp),
            verticalArrangement = Arrangement.spacedBy(12.dp)) {
            if (container.uploadsNeedSignIn) item {
                Banner(StatusInfo.Kind.Warning, "Your sign-in expired. Sign in again to continue uploading; nothing is lost.")
                TextButton(onClick = { scope.launch { runCatching { container.reauthenticate() }; container.runQueue() } }) { Text("Sign in again") }
            }
            if (items.isEmpty() && container.otherAccountsQueue.isEmpty()) item {
                Text("Nothing waiting. Photos you add appear here until Libarrie has them safely.", color = brand.textMuted)
            }
            section("Needs your attention", attention) { item ->
                Text(title(item), style = MaterialTheme.typography.titleSmall, color = brand.warning)
                Text(item.lastError ?: "This photo needs your attention.")
                Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                    when (item.attention) {
                        AttentionReason.PageNumberConflict -> OutlinedButton(onClick = { newNumber = ""; renumbering = item }) { Text("Choose number") }
                        AttentionReason.ProcessingLimit -> {
                            OutlinedButton(onClick = { scope.launch { container.decide(DeferredDecision.UploadAndProcessLater, item.batchId) } }) { Text("Process later") }
                            OutlinedButton(onClick = { scope.launch { container.decide(DeferredDecision.KeepOnDevice, item.batchId) } }) { Text("Keep on device") }
                        }
                        AttentionReason.CaptureMissing -> Unit
                        else -> OutlinedButton(onClick = { scope.launch { container.retry(item.id) } }) { Text("Try again") }
                    }
                    TextButton(onClick = { scope.launch { runCatching { container.cancel(item.id) } } }) { Text("Remove", color = brand.danger) }
                }
            }
            if (unreviewed.isNotEmpty()) {
                item { Text("Not yet added to a notebook", style = MaterialTheme.typography.titleMedium) }
                unreviewed.forEach { (batch, photos) ->
                    item(key = "batch-$batch") {
                        Row(Modifier.fillMaxWidth(), horizontalArrangement = Arrangement.SpaceBetween) {
                            Text("${plural(photos.size, "photo")} saved on this device")
                            TextButton(onClick = { nav.navigate(Routes.capture(batch = batch)) }) { Text("Review") }
                        }
                    }
                }
            }
            section("Uploading", moving) { item ->
                Text(title(item))
                Text(
                    when (item.state) {
                        CaptureState.Uploading -> "Uploading"
                        CaptureState.RetryableError -> "Saved on this device. ${item.lastError ?: "Will retry automatically."}"
                        else -> "Saved on this device, waiting to upload"
                    },
                    style = MaterialTheme.typography.bodySmall, color = brand.textMuted,
                )
                if (item.state == CaptureState.RetryableError) TextButton(onClick = { scope.launch { container.retry(item.id) } }) { Text("Try now") }
            }
            section("Uploaded to Libarrie", accepted) { item ->
                val overdue = item.acceptedAt?.let { System.currentTimeMillis() / 1000 - it > 24 * 3600 } ?: false
                Text(title(item))
                Text(if (overdue) "Backup is taking longer than usual" else "Waiting for independent backup",
                    style = MaterialTheme.typography.bodySmall, color = if (overdue) brand.warning else brand.textMuted)
                if (!item.localFileRemoved) TextButton(onClick = { removing = item }) { Text("Remove from this device") }
            }
            if (accepted.isNotEmpty()) item {
                Text("Photos stay on this device until Libarrie confirms an independent backup.", style = MaterialTheme.typography.bodySmall, color = brand.textMuted)
            }
            if (verified.isNotEmpty()) item {
                Text("Independent backup verified", style = MaterialTheme.typography.titleMedium)
                Text("${plural(verified.size, "page")} safely backed up; the device copies were removed.")
                TextButton(onClick = { scope.launch { verified.forEach { container.discard(it.id) } } }) { Text("Clear this list") }
            }
            if (container.otherAccountsQueue.isNotEmpty()) {
                item {
                    Text("Saved for another account", style = MaterialTheme.typography.titleMedium)
                    Text("These photos belong to a different account and never upload to this one. Sign in to that account to upload them.",
                        style = MaterialTheme.typography.bodySmall, color = brand.textMuted)
                }
                items(container.otherAccountsQueue, key = { it.id }) { item ->
                    Row(Modifier.fillMaxWidth(), horizontalArrangement = Arrangement.SpaceBetween) {
                        Text(title(item))
                        TextButton(onClick = { scope.launch { container.discard(item.id) } }) { Text("Delete", color = brand.danger) }
                    }
                }
            }
        }
    }

    renumbering?.let { item ->
        AlertDialog(
            onDismissRequest = { renumbering = null },
            title = { Text("Choose a page number") },
            text = {
                Column {
                    Text("Another page in this notebook already has that number.")
                    OutlinedTextField(newNumber, { newNumber = it }, label = { Text("Page number") },
                        keyboardOptions = KeyboardOptions(keyboardType = KeyboardType.Number), singleLine = true)
                }
            },
            confirmButton = {
                TextButton(onClick = {
                    newNumber.trim().toIntOrNull()?.takeIf { it >= 1 }?.let { n -> scope.launch { container.renumber(item.id, n) } }
                    renumbering = null
                }) { Text("Upload") }
            },
            dismissButton = { TextButton(onClick = { renumbering = null }) { Text("Cancel") } },
        )
    }
    removing?.let { item ->
        AlertDialog(
            onDismissRequest = { removing = null },
            title = { Text("Remove the photo from this device?") },
            text = { Text("Libarrie has the photo, but its independent backup is not confirmed yet. Until it is, a server failure could lose it and this device copy is the only other one.") },
            confirmButton = { TextButton(onClick = { scope.launch { container.removeLocalCopy(item.id) }; removing = null }) { Text("Remove from this device") } },
            dismissButton = { TextButton(onClick = { removing = null }) { Text("Keep") } },
        )
    }
}

private fun title(item: CaptureItem): String {
    val name = item.notebookName ?: "Photo"
    if (item.isReplacement) return "$name: new scan for page ${item.pageNumber ?: 0}"
    return item.pageNumber?.let { "$name, page $it" } ?: name
}

private fun LazyListScope.section(title: String, items: List<CaptureItem>, row: @Composable (CaptureItem) -> Unit) {
    if (items.isEmpty()) return
    item(key = "title-$title") { Text(title, style = MaterialTheme.typography.titleMedium) }
    items(items, key = { it.id }) { item ->
        Column(verticalArrangement = Arrangement.spacedBy(4.dp)) {
            row(item)
            HorizontalDivider()
        }
    }
}

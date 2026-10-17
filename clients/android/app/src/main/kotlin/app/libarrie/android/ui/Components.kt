package app.libarrie.android.ui

import android.graphics.BitmapFactory
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.aspectRatio
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.outlined.CheckCircle
import androidx.compose.material.icons.outlined.ErrorOutline
import androidx.compose.material.icons.outlined.Info
import androidx.compose.material.icons.outlined.Schedule
import androidx.compose.material.icons.outlined.Sync
import androidx.compose.material.icons.outlined.WarningAmber
import androidx.compose.material3.Icon
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.ImageBitmap
import androidx.compose.ui.graphics.asImageBitmap
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.layout.ContentScale
import androidx.compose.ui.semantics.LiveRegionMode
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.liveRegion
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import app.libarrie.core.api.ApiError
import app.libarrie.core.api.Page
import app.libarrie.core.cache.ImageCache
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext
import java.text.DateFormat
import java.time.Instant
import java.util.Date

/** Status with words and an icon, never color alone (section 13). */
data class StatusInfo(val label: String, val icon: ImageVector, val kind: Kind) {
    enum class Kind { Ok, Muted, Warning, Danger }
}

fun describeStatus(status: String): StatusInfo = when (status) {
    "ready" -> StatusInfo("Searchable", Icons.Outlined.CheckCircle, StatusInfo.Kind.Ok)
    "ready_empty" -> StatusInfo("Blank page", Icons.Outlined.CheckCircle, StatusInfo.Kind.Ok)
    "awaiting_processing" -> StatusInfo("Waiting for processing", Icons.Outlined.Schedule, StatusInfo.Kind.Muted)
    "queued", "accepted", "validating" -> StatusInfo("Queued", Icons.Outlined.Schedule, StatusInfo.Kind.Muted)
    "recognizing" -> StatusInfo("Reading handwriting", Icons.Outlined.Sync, StatusInfo.Kind.Muted)
    "indexing" -> StatusInfo("Indexing", Icons.Outlined.Sync, StatusInfo.Kind.Muted)
    "awaiting_upload" -> StatusInfo("Uploading", Icons.Outlined.Sync, StatusInfo.Kind.Muted)
    "needs_user_action" -> StatusInfo("Needs your attention", Icons.Outlined.WarningAmber, StatusInfo.Kind.Warning)
    "failed" -> StatusInfo("Processing failed", Icons.Outlined.ErrorOutline, StatusInfo.Kind.Danger)
    "cancelled" -> StatusInfo("Cancelled", Icons.Outlined.Info, StatusInfo.Kind.Muted)
    else -> StatusInfo(status.replace('_', ' '), Icons.Outlined.Info, StatusInfo.Kind.Muted)
}

fun isProcessing(status: String) = status in setOf("queued", "accepted", "validating", "recognizing", "indexing", "awaiting_upload")

@Composable
fun kindColor(kind: StatusInfo.Kind): Color {
    val brand = LocalBrand.current
    return when (kind) {
        StatusInfo.Kind.Ok -> brand.success
        StatusInfo.Kind.Muted -> brand.textMuted
        StatusInfo.Kind.Warning -> brand.warning
        StatusInfo.Kind.Danger -> brand.danger
    }
}

@Composable
fun StatusBadge(status: String, modifier: Modifier = Modifier) {
    val info = describeStatus(status)
    val color = kindColor(info.kind)
    Row(modifier.semantics(mergeDescendants = true) { contentDescription = "Status: ${info.label}" },
        verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(4.dp)) {
        Icon(info.icon, contentDescription = null, tint = color, modifier = Modifier.size(16.dp))
        Text(info.label, color = color, style = MaterialTheme.typography.labelMedium, fontWeight = FontWeight.SemiBold)
    }
}

/** An inline message, announced by TalkBack when it appears. */
@Composable
fun Banner(kind: StatusInfo.Kind, text: String, modifier: Modifier = Modifier) {
    val brand = LocalBrand.current
    val color = kindColor(kind)
    val icon = when (kind) {
        StatusInfo.Kind.Ok -> Icons.Outlined.CheckCircle
        StatusInfo.Kind.Muted -> Icons.Outlined.Info
        StatusInfo.Kind.Warning -> Icons.Outlined.WarningAmber
        StatusInfo.Kind.Danger -> Icons.Outlined.ErrorOutline
    }
    Row(
        modifier.fillMaxWidth()
            .background(brand.surfaceRaised, RoundedCornerShape(10.dp))
            .border(1.5.dp, color, RoundedCornerShape(10.dp))
            .padding(12.dp)
            .semantics(mergeDescendants = true) { liveRegion = LiveRegionMode.Polite },
        horizontalArrangement = Arrangement.spacedBy(8.dp),
    ) {
        Icon(icon, contentDescription = null, tint = color)
        Text(text, color = brand.text, style = MaterialTheme.typography.bodyMedium)
    }
}

typealias Message = Pair<StatusInfo.Kind, String>

@Composable
fun MessageBanner(message: Message?, modifier: Modifier = Modifier) {
    if (message != null) Banner(message.first, message.second, modifier)
}

@Composable
fun NotebookDot(hex: String?) {
    val color = notebookColor(hex) ?: return
    Box(Modifier.size(14.dp).clip(CircleShape).background(color).border(1.dp, LocalBrand.current.border, CircleShape))
}

/** A page thumbnail or preview from the account's image cache. */
@Composable
fun PageImage(page: Page, variant: ImageCache.Variant, cache: ImageCache?, modifier: Modifier = Modifier) {
    var bitmap by remember(page.imageObjectId, variant) { mutableStateOf<ImageBitmap?>(null) }
    LaunchedEffect(page.imageObjectId, variant) {
        val bytes = runCatching { cache?.bytes(page, variant) }.getOrNull() ?: return@LaunchedEffect
        bitmap = withContext(Dispatchers.Default) { BitmapFactory.decodeByteArray(bytes, 0, bytes.size)?.asImageBitmap() }
    }
    val description = if (variant == ImageCache.Variant.Thumb) "Page ${page.pageNumber}" else "Scan of page ${page.pageNumber}"
    val image = bitmap
    if (image != null) {
        androidx.compose.foundation.Image(image, description, modifier.fillMaxWidth(), contentScale = ContentScale.Fit)
    } else {
        Box(
            modifier.fillMaxWidth().aspectRatio(3f / 4f).background(LocalBrand.current.surface, RoundedCornerShape(6.dp))
                .semantics { contentDescription = description },
            contentAlignment = Alignment.Center,
        ) { Text("${page.pageNumber}", style = MaterialTheme.typography.titleLarge, color = LocalBrand.current.textMuted) }
    }
}

fun describe(e: Throwable): String = (e as? ApiError)?.message ?: e.message ?: "Something went wrong. Please try again."

fun formatDate(timestamp: String?): String = timestamp?.let {
    runCatching { DateFormat.getDateTimeInstance(DateFormat.MEDIUM, DateFormat.SHORT).format(Date.from(Instant.parse(it))) }.getOrDefault(it)
} ?: ""

fun formatBytes(bytes: Long): String = when {
    bytes >= 1L shl 30 -> "%.1f GB".format(bytes / (1L shl 30).toDouble())
    bytes >= 1L shl 20 -> "%.1f MB".format(bytes / (1L shl 20).toDouble())
    bytes >= 1L shl 10 -> "%.1f KB".format(bytes / (1L shl 10).toDouble())
    else -> "$bytes bytes"
}

fun plural(n: Int, word: String) = "$n $word${if (n == 1) "" else "s"}"

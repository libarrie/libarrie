package app.libarrie.android.ui

import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.text.KeyboardActions
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.outlined.Search
import androidx.compose.material3.HorizontalDivider
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.LinearProgressIndicator
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.Scaffold
import androidx.compose.material3.Text
import androidx.compose.material3.TopAppBar
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Modifier
import androidx.compose.ui.text.AnnotatedString
import androidx.compose.ui.text.SpanStyle
import androidx.compose.ui.text.buildAnnotatedString
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.input.ImeAction
import androidx.compose.ui.text.withStyle
import androidx.compose.ui.unit.dp
import androidx.lifecycle.ViewModel
import androidx.lifecycle.viewModelScope
import androidx.lifecycle.viewmodel.compose.viewModel
import androidx.navigation.NavController
import app.libarrie.android.AppContainer
import app.libarrie.core.api.ApiError
import app.libarrie.core.api.Notebook
import app.libarrie.core.api.SearchHit
import app.libarrie.core.api.SearchResponse
import kotlinx.coroutines.launch
import java.text.BreakIterator

class SearchViewModel(private val container: AppContainer) : ViewModel() {
    var query by mutableStateOf("")
    var notebookId by mutableStateOf<String?>(null)
    var notebooks by mutableStateOf<List<Notebook>>(emptyList())
    var response by mutableStateOf<SearchResponse?>(null)
    var searching by mutableStateOf(false)
    var error by mutableStateOf<String?>(null)

    init {
        viewModelScope.launch { notebooks = runCatching { container.services?.api?.allNotebooks() }.getOrNull().orEmpty() }
    }

    fun search() = viewModelScope.launch {
        val text = query.trim()
        val api = container.services?.api ?: return@launch
        if (text.isEmpty()) return@launch
        searching = true
        try {
            response = api.search(text, notebookId)
            error = null
        } catch (e: ApiError) {
            error = if (e.code == "rate_limited") "Too many searches in a short time. Wait a moment and try again." else e.message
        } finally {
            searching = false
        }
    }
}

/** Grapheme cluster boundaries, matching the server's highlight offsets. */
fun graphemes(text: String): List<String> {
    val iterator = BreakIterator.getCharacterInstance().apply { setText(text) }
    val result = mutableListOf<String>()
    var start = iterator.first()
    var end = iterator.next()
    while (end != BreakIterator.DONE) {
        result += text.substring(start, end)
        start = end
        end = iterator.next()
    }
    return result
}

/**
 * The snippet with matches highlighted (offsets are in graphemes), or null
 * for a hit from a private notebook, which has no snippet.
 */
fun highlighted(hit: SearchHit, background: androidx.compose.ui.graphics.Color, foreground: androidx.compose.ui.graphics.Color): AnnotatedString? {
    val snippet = hit.snippet ?: return null
    val characters = graphemes(snippet)
    var position = 0
    return buildAnnotatedString {
        for (range in hit.highlights.sortedBy { it.start }) {
            if (range.start < position || range.end > characters.size || range.end <= range.start) continue
            append(characters.subList(position, range.start).joinToString(""))
            withStyle(SpanStyle(background = background, color = foreground, fontWeight = FontWeight.SemiBold)) {
                append(characters.subList(range.start, range.end).joinToString(""))
            }
            position = range.end
        }
        append(characters.subList(position, characters.size).joinToString(""))
    }
}

@Composable
fun SearchScreen(container: AppContainer, nav: NavController) {
    val model = viewModel { SearchViewModel(container) }
    val brand = LocalBrand.current
    var picker by remember { mutableStateOf(false) }
    Scaffold(topBar = { TopAppBar(title = { Text("Search") }) }) { padding ->
        LazyColumn(Modifier.fillMaxSize().padding(padding), contentPadding = androidx.compose.foundation.layout.PaddingValues(16.dp),
            verticalArrangement = Arrangement.spacedBy(12.dp)) {
            item {
                OutlinedTextField(
                    model.query, { model.query = it },
                    label = { Text("Search your notes") },
                    placeholder = { Text("A name, an ID, or what the note was about") },
                    singleLine = true,
                    keyboardOptions = KeyboardOptions(imeAction = ImeAction.Search),
                    keyboardActions = KeyboardActions(onSearch = { model.search() }),
                    trailingIcon = { IconButton(onClick = { model.search() }) { Icon(Icons.Outlined.Search, "Search") } },
                    modifier = Modifier.fillMaxWidth(),
                )
            }
            item {
                NotebookPicker(listOf(Notebook("", "All notebooks", "", null, 0, 0, 0)) + model.notebooks, model.notebookId ?: "",
                    picker, { picker = it }) { model.notebookId = it.ifEmpty { null }; model.search() }
            }
            if (model.searching) item { LinearProgressIndicator(Modifier.fillMaxWidth()) }
            model.error?.let { item { Banner(StatusInfo.Kind.Warning, it) } }
            model.response?.let { response ->
                when {
                    response.searchMode == "lexical_only" -> item { Banner(StatusInfo.Kind.Muted, "Showing exact-word matches only; meaning-based search is temporarily unavailable.") }
                    response.indexMigrationPending -> item { Banner(StatusInfo.Kind.Muted, "Search is being upgraded; some pages match by exact words only for now.") }
                }
                if (response.results.isEmpty()) item { Text("No matching pages found.", color = brand.textMuted) }
                items(response.results, key = { it.pageId }) { hit ->
                    Column(Modifier.fillMaxWidth().clickable { nav.navigate(Routes.page(hit.pageId)) }.padding(vertical = 4.dp)) {
                        Text("${hit.notebook.name} · Page ${hit.pageNumber}", style = MaterialTheme.typography.titleSmall)
                        val snippet = highlighted(hit, brand.highlight, brand.onHighlight)
                        if (snippet != null) {
                            Text(snippet, style = MaterialTheme.typography.bodyMedium)
                        } else {
                            Text("Private notebook. The matching text isn't shown.", style = MaterialTheme.typography.bodySmall, color = brand.textMuted)
                        }
                        if (hit.indexingPending) Text("This page was edited since it was indexed.", style = MaterialTheme.typography.bodySmall, color = brand.textMuted)
                    }
                    HorizontalDivider()
                }
            }
        }
    }
}

package app.libarrie.android.ui

import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.widthIn
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.foundation.verticalScroll
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.outlined.AccountCircle
import androidx.compose.material.icons.outlined.CloudUpload
import androidx.compose.material.icons.automirrored.outlined.LibraryBooks
import androidx.compose.material.icons.outlined.Search
import androidx.compose.material3.Badge
import androidx.compose.material3.BadgedBox
import androidx.compose.material3.Button
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.Icon
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.NavigationBar
import androidx.compose.material3.NavigationBarItem
import androidx.compose.material3.OutlinedButton
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.Scaffold
import androidx.compose.material3.Surface
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.text.input.KeyboardType
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.unit.dp
import androidx.navigation.NavHostController
import androidx.navigation.NavType
import androidx.navigation.compose.NavHost
import androidx.navigation.compose.composable
import androidx.navigation.compose.currentBackStackEntryAsState
import androidx.navigation.compose.rememberNavController
import androidx.navigation.navArgument
import app.libarrie.android.AppContainer
import app.libarrie.android.Phase
import app.libarrie.core.queue.CaptureState

@Composable
fun LibarrieRoot(container: AppContainer) {
    LibarrieTheme(container.settings.theme) {
        Surface(Modifier.fillMaxSize(), color = MaterialTheme.colorScheme.background) {
            when (container.phase) {
                Phase.Starting -> Column(Modifier.fillMaxSize(), verticalArrangement = Arrangement.Center, horizontalAlignment = Alignment.CenterHorizontally) {
                    CircularProgressIndicator()
                }
                Phase.SignedOut -> SignInScreen(container)
                Phase.SignedIn -> MainScreen(container)
                Phase.AccountClosing -> ClosingScreen(container)
                Phase.AccountPurged -> PurgedScreen(container)
            }
        }
    }
}

@Composable
fun SignInScreen(container: AppContainer) {
    val brand = LocalBrand.current
    Column(
        Modifier.fillMaxSize().verticalScroll(rememberScrollState()).padding(24.dp),
        horizontalAlignment = Alignment.CenterHorizontally,
        verticalArrangement = Arrangement.spacedBy(16.dp, Alignment.CenterVertically),
    ) {
        Column(Modifier.widthIn(max = 520.dp), verticalArrangement = Arrangement.spacedBy(16.dp)) {
            Text("Find what you wrote.", style = MaterialTheme.typography.headlineLarge, textAlign = TextAlign.Center, modifier = Modifier.fillMaxWidth())
            Text("Photograph your handwritten notebooks, then search them to find the notebook and page you need.",
                color = brand.textMuted, textAlign = TextAlign.Center, modifier = Modifier.fillMaxWidth())
            OutlinedTextField(
                value = container.settings.serverAddress,
                onValueChange = { container.settings.serverAddress = it },
                label = { Text("Server") },
                placeholder = { Text("libarrie.example.com") },
                singleLine = true,
                keyboardOptions = KeyboardOptions(keyboardType = KeyboardType.Uri),
                modifier = Modifier.fillMaxWidth(),
            )
            container.signInError?.let { Banner(StatusInfo.Kind.Danger, it) }
            Button(onClick = { container.signIn() }, enabled = !container.working, modifier = Modifier.fillMaxWidth()) {
                Text(if (container.working) "Signing in…" else "Sign in")
            }
            if (container.queue.isNotEmpty()) {
                Text("${plural(container.queue.size, "photo")} saved on this device. They upload after their account signs in again.",
                    style = MaterialTheme.typography.bodySmall, color = brand.textMuted, textAlign = TextAlign.Center, modifier = Modifier.fillMaxWidth())
            }
        }
    }
}

object Routes {
    const val Notebooks = "notebooks"
    const val Search = "search"
    const val Uploads = "uploads"
    const val Account = "account"
    const val Notebook = "notebook/{id}"
    const val Page = "page/{id}"
    const val Capture = "capture?batch={batch}&notebook={notebook}"
    const val Usage = "usage"
    const val Trash = "trash"
    const val Exports = "exports"
    const val Settings = "settings"
    const val DeleteAccount = "delete-account"

    fun notebook(id: String) = "notebook/$id"
    fun page(id: String) = "page/$id"
    fun capture(batch: String? = null, notebook: String? = null) =
        "capture?batch=${batch.orEmpty()}&notebook=${notebook.orEmpty()}"
}

@Composable
fun MainScreen(container: AppContainer) {
    val nav = rememberNavController()
    val current by nav.currentBackStackEntryAsState()
    val route = current?.destination?.route
    val tabs = listOf(
        Triple(Routes.Notebooks, "Notebooks", Icons.AutoMirrored.Outlined.LibraryBooks),
        Triple(Routes.Search, "Search", Icons.Outlined.Search),
        Triple(Routes.Uploads, "Uploads", Icons.Outlined.CloudUpload),
        Triple(Routes.Account, "Account", Icons.Outlined.AccountCircle),
    )
    val attention = container.accountQueue.count { it.state == CaptureState.NeedsUserAction }
    Scaffold(
        bottomBar = {
            if (route != Routes.Capture) NavigationBar {
                tabs.forEach { (tab, label, icon) ->
                    NavigationBarItem(
                        selected = current?.destination?.hierarchy?.any { it.route == tab } == true || route == tab,
                        onClick = {
                            nav.navigate(tab) {
                                popUpTo(nav.graph.startDestinationId) { saveState = true }
                                launchSingleTop = true
                                restoreState = true
                            }
                        },
                        icon = {
                            if (tab == Routes.Uploads && attention > 0) BadgedBox(badge = { Badge { Text("$attention") } }) { Icon(icon, null) }
                            else Icon(icon, null)
                        },
                        label = { Text(label) },
                    )
                }
            }
        },
    ) { padding ->
        AppNavHost(container, nav, Modifier.padding(padding))
    }
}

private val androidx.navigation.NavDestination.hierarchy get() = generateSequence(this) { it.parent }

@Composable
fun AppNavHost(container: AppContainer, nav: NavHostController, modifier: Modifier) {
    NavHost(nav, startDestination = Routes.Notebooks, modifier = modifier) {
        composable(Routes.Notebooks) { NotebooksScreen(container, nav) }
        composable(Routes.Search) { SearchScreen(container, nav) }
        composable(Routes.Uploads) { UploadsScreen(container, nav) }
        composable(Routes.Account) { AccountScreen(container, nav) }
        composable(Routes.Notebook, listOf(navArgument("id") { type = NavType.StringType })) {
            NotebookScreen(container, nav, it.arguments?.getString("id")!!)
        }
        composable(Routes.Page, listOf(navArgument("id") { type = NavType.StringType })) {
            PageScreen(container, nav, it.arguments?.getString("id")!!)
        }
        composable(Routes.Capture, listOf(
            navArgument("batch") { type = NavType.StringType; defaultValue = "" },
            navArgument("notebook") { type = NavType.StringType; defaultValue = "" },
        )) {
            CaptureScreen(container, nav, it.arguments?.getString("batch").orEmpty(), it.arguments?.getString("notebook").orEmpty())
        }
        composable(Routes.Usage) { UsageScreen(container, nav) }
        composable(Routes.Trash) { TrashScreen(container, nav) }
        composable(Routes.Exports) { ExportsScreen(container, nav) }
        composable(Routes.Settings) { SettingsScreen(container, nav) }
        composable(Routes.DeleteAccount) { DeleteAccountScreen(container, nav) }
    }
}

@Composable
fun ClosingScreen(container: AppContainer) {
    Column(Modifier.fillMaxSize().padding(32.dp), verticalArrangement = Arrangement.spacedBy(16.dp, Alignment.CenterVertically),
        horizontalAlignment = Alignment.CenterHorizontally) {
        Text("Account closing", style = MaterialTheme.typography.headlineMedium)
        Text("This account is being closed. Notes can no longer be viewed, and uploads have stopped.", textAlign = TextAlign.Center)
        OutlinedButton(onClick = { container.signOut() }) { Text("Sign out") }
    }
}

/** After purge only a keyed hash of the identity survives. */
@Composable
fun PurgedScreen(container: AppContainer) {
    Column(Modifier.fillMaxSize().padding(32.dp), verticalArrangement = Arrangement.spacedBy(16.dp, Alignment.CenterVertically),
        horizontalAlignment = Alignment.CenterHorizontally) {
        Text("Account closed", style = MaterialTheme.typography.headlineMedium)
        Text("The account for this sign-in was closed and its notes were deleted. You can start a new, empty account; it continues from your earlier processing allowance.",
            textAlign = TextAlign.Center)
        container.signInError?.let { Banner(StatusInfo.Kind.Danger, it) }
        Button(onClick = { container.startNewAccount() }) { Text("Start a new account") }
        OutlinedButton(onClick = { container.signOut() }) { Text("Sign out") }
    }
}

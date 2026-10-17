package app.libarrie.android

import android.content.Intent
import android.os.Bundle
import androidx.activity.ComponentActivity
import androidx.activity.compose.setContent
import androidx.activity.enableEdgeToEdge
import androidx.browser.customtabs.CustomTabsIntent
import androidx.core.net.toUri
import androidx.lifecycle.lifecycleScope
import app.libarrie.android.ui.LibarrieRoot
import kotlinx.coroutines.delay
import kotlinx.coroutines.launch

class MainActivity : ComponentActivity() {
    private val container get() = (application as LibarrieApplication).container
    private var awaitingBrowser = false

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        enableEdgeToEdge()
        // Sign-in opens in a Custom Tab (the system browser), never a WebView.
        container.openBrowser = { url ->
            awaitingBrowser = true
            CustomTabsIntent.Builder().setShowTitle(true).build().launchUrl(this, url.toUri())
        }
        handle(intent)
        container.start()
        setContent { LibarrieRoot(container) }
    }

    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        handle(intent)
    }

    private fun handle(intent: Intent?) {
        val data = intent?.data ?: return
        if (data.scheme == "libarrie" && data.host == "oauth") {
            awaitingBrowser = false
            container.handleRedirect(data.toString())
        }
    }

    override fun onResume() {
        super.onResume()
        lifecycleScope.launch { container.runQueue() }
        // Back from the browser without a redirect: the user closed it.
        if (awaitingBrowser) {
            lifecycleScope.launch {
                delay(800)
                if (awaitingBrowser && container.signInPending) {
                    awaitingBrowser = false
                    container.abandonSignIn()
                }
            }
        }
    }

    override fun onDestroy() {
        if (container.openBrowser != null && isFinishing) container.openBrowser = null
        super.onDestroy()
    }
}

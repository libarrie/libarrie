package app.libarrie.android.ui

import androidx.compose.foundation.isSystemInDarkTheme
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.darkColorScheme
import androidx.compose.material3.lightColorScheme
import androidx.compose.runtime.Composable
import androidx.compose.runtime.CompositionLocalProvider
import androidx.compose.runtime.Immutable
import androidx.compose.runtime.staticCompositionLocalOf
import androidx.compose.ui.graphics.Color
import app.libarrie.android.ThemePreference

/** Semantic colors from DESIGN.md section 3 (the same tokens as the web). */
@Immutable
data class BrandColors(
    val background: Color, val surface: Color, val surfaceRaised: Color, val text: Color, val textMuted: Color,
    val border: Color, val primary: Color, val onPrimary: Color, val link: Color, val success: Color,
    val warning: Color, val danger: Color,
) {
    val highlight = Color(0xFFF5BC2F)
    val onHighlight = Color(0xFF0E2444)
}

val LightBrand = BrandColors(
    background = Color(0xFFFEF8EA), surface = Color(0xFFFFFDF7), surfaceRaised = Color(0xFFFCEFD2), text = Color(0xFF0E2444),
    textMuted = Color(0xFF56616C), border = Color(0xFF887861), primary = Color(0xFF0E2444), onPrimary = Color(0xFFFEF8EA),
    link = Color(0xFFA43E28), success = Color(0xFF0D3F2E), warning = Color(0xFF795600), danger = Color(0xFF9F3028),
)

val DarkBrand = BrandColors(
    background = Color(0xFF0E2444), surface = Color(0xFF173354), surfaceRaised = Color(0xFF214466), text = Color(0xFFFCEFD2),
    textMuted = Color(0xFFB1CDDF), border = Color(0xFF809BB0), primary = Color(0xFFF8926E), onPrimary = Color(0xFF0E2444),
    link = Color(0xFFFFA887), success = Color(0xFF9CD4B4), warning = Color(0xFFF5BC2F), danger = Color(0xFFFFB09E),
)

val LocalBrand = staticCompositionLocalOf { LightBrand }

/** Notebook identifying colors (same palette as the web and iOS). */
val NotebookColors = listOf(
    "#0e2444" to "Navy", "#2f6f9f" to "Blue", "#0d3f2e" to "Green", "#5b3a8c" to "Purple",
    "#a43e28" to "Brick", "#c2185b" to "Rose", "#f5bc2f" to "Gold", "#887861" to "Stone",
)

fun notebookColor(hex: String?): Color? =
    hex?.takeIf { it.length == 7 && it.startsWith("#") }?.substring(1)?.toLongOrNull(16)?.let { Color(0xFF000000 or it) }

/** System / Light / Dark (section 3). */
@Composable
fun LibarrieTheme(preference: ThemePreference, content: @Composable () -> Unit) {
    val dark = when (preference) {
        ThemePreference.System -> isSystemInDarkTheme()
        ThemePreference.Light -> false
        ThemePreference.Dark -> true
    }
    val brand = if (dark) DarkBrand else LightBrand
    val scheme = (if (dark) darkColorScheme() else lightColorScheme()).copy(
        primary = brand.primary, onPrimary = brand.onPrimary, background = brand.background, onBackground = brand.text,
        surface = brand.background, onSurface = brand.text, surfaceVariant = brand.surface, onSurfaceVariant = brand.textMuted,
        surfaceContainer = brand.surface, surfaceContainerHigh = brand.surfaceRaised, outline = brand.border,
        error = brand.danger, secondary = brand.link, tertiary = brand.link,
    )
    CompositionLocalProvider(LocalBrand provides brand) {
        MaterialTheme(colorScheme = scheme, content = content)
    }
}

package com.grocerypos.v11.util

import android.content.Context

/**
 * One color palette for the whole app — light or dark.
 * Every activity should pull its hex colors from here instead of hardcoding them,
 * so adding/adjusting a theme only ever needs to happen in ONE place.
 */
data class AppPalette(
    val bg: String,
    val cardWhite: String,
    val navy: String,
    val teal: String,
    val red: String,
    val textDark: String,
    val textMuted: String,
    val border: String,
    val amber: String,
    val fieldFill: String,
    val headerSubtitleColor: String,
    val headerBadgeOverlay: String,
    val savedHighlightBg: String,

    // --- Flat-minimal design system (app-wide UI redesign, added 2026-09) ---
    // Every screen is being migrated to pull ONLY from this block instead of
    // gradients/hardcoded hex. Old fields above are kept until every screen
    // is migrated, then can be removed.
    // Soft "chip" background + matching icon/text color per category. Pick
    // ONE category per screen/action type and reuse it everywhere that type
    // appears (e.g. Sale = flatPurple everywhere, Purchase = flatCoral everywhere).
    val flatPurpleBg: String,
    val flatPurpleFg: String,
    val flatCoralBg: String,
    val flatCoralFg: String,
    val flatBlueBg: String,
    val flatBlueFg: String,
    val flatPinkBg: String,
    val flatPinkFg: String,
    val flatTealBg: String,
    val flatTealFg: String,
    val flatAmberBg: String,
    val flatAmberFg: String
)

/**
 * App-wide theme state. This is the ONLY place dark_mode is read from / written to
 * SharedPreferences — every activity should go through this object rather than rolling
 * its own prefs logic, so a toggle in one screen is guaranteed to be seen everywhere else.
 */
object ThemeManager {

    private const val PREFS_NAME = "app_prefs"
    private const val KEY_DARK_MODE = "dark_mode"

    // Khatabook-style ledger palette: deep navy header, white cards on a soft grey
    // canvas, and fixed green(get)/red(give) semantics — see partyGreen/partyRed
    // in MainActivity for where the get/give colors are actually consumed.
    val LIGHT = AppPalette(
        bg = "#F4F5F9",
        cardWhite = "#FFFFFF",
        navy = "#0D1B4C",
        teal = "#0F9B8E",
        red = "#E5484D",
        textDark = "#14162B",
        textMuted = "#7C8798",
        border = "#E7E9F2",
        amber = "#FF8A00",
        fieldFill = "#F4F5F9",
        headerSubtitleColor = "#AEB8E0",
        headerBadgeOverlay = "#33FFFFFF",
        savedHighlightBg = "#E9FBF9",

        flatPurpleBg = "#E7E9FB", flatPurpleFg = "#2D3796",
        flatCoralBg = "#FDEAE3", flatCoralFg = "#C1440E",
        flatBlueBg = "#E3ECFE", flatBlueFg = "#1450C7",
        flatPinkBg = "#FBEAF0", flatPinkFg = "#993556",
        flatTealBg = "#DFF6EC", flatTealFg = "#0A8A4E",
        flatAmberBg = "#FFEFD9", flatAmberFg = "#B85C00"
    )

    val DARK = AppPalette(
        bg = "#0B0F1E",
        cardWhite = "#161B2E",
        navy = "#0D1B4C",
        teal = "#14B8A6",
        red = "#F0666B",
        textDark = "#EAEFF7",
        textMuted = "#8B95A8",
        border = "#262C42",
        amber = "#FF9E33",
        fieldFill = "#161D2C",
        headerSubtitleColor = "#AEB8E0",
        headerBadgeOverlay = "#33FFFFFF",
        savedHighlightBg = "#12332F",

        flatPurpleBg = "#2C2F7A", flatPurpleFg = "#C7CBF6",
        flatCoralBg = "#6E2E10", flatCoralFg = "#F6C4A9",
        flatBlueBg = "#0E3A78", flatBlueFg = "#BAD3F8",
        flatPinkBg = "#72243E", flatPinkFg = "#F4C0D1",
        flatTealBg = "#0A4A34", flatTealFg = "#8FE7C0",
        flatAmberBg = "#5C3A05", flatAmberFg = "#FFC26A"
    )

    fun isDarkMode(context: Context): Boolean =
        context.getSharedPreferences(PREFS_NAME, Context.MODE_PRIVATE)
            .getBoolean(KEY_DARK_MODE, false)

    fun setDarkMode(context: Context, enabled: Boolean) {
        context.getSharedPreferences(PREFS_NAME, Context.MODE_PRIVATE)
            .edit()
            .putBoolean(KEY_DARK_MODE, enabled)
            .apply()
    }

    /** Flips the current setting and returns the new value. */
    fun toggleDarkMode(context: Context): Boolean {
        val newValue = !isDarkMode(context)
        setDarkMode(context, newValue)
        return newValue
    }

    fun palette(context: Context): AppPalette =
        if (isDarkMode(context)) DARK else LIGHT
}

package com.grocerypos.v11.util

import android.content.Context

/**
 * Very small localization helper — no Android resource/locale system involved.
 * The chosen language ("en" or "ur") is stored in plain SharedPreferences
 * (same pattern already used for the login "session" prefs elsewhere in the
 * app), so it can be read synchronously while a screen's UI is being built.
 *
 * Usage in any Activity:
 *   Loc.t(this, "Item Name", "آئٹم کا نام")
 *
 * Changing the language only affects screens built AFTER the change (i.e.
 * the next time each Activity's onCreate runs) — there is no live UI
 * recomposition, matching how the rest of this codebase builds views
 * imperatively in onCreate.
 */
object Loc {

    private const val PREFS = "app_prefs"
    private const val KEY_LANGUAGE = "language"

    /** "en" or "ur". Defaults to "en". */
    fun currentLanguage(context: Context): String {
        return context.getSharedPreferences(PREFS, Context.MODE_PRIVATE)
            .getString(KEY_LANGUAGE, "en") ?: "en"
    }

    fun isUrdu(context: Context): Boolean = currentLanguage(context) == "ur"

    fun setLanguage(context: Context, language: String) {
        context.getSharedPreferences(PREFS, Context.MODE_PRIVATE)
            .edit()
            .putString(KEY_LANGUAGE, language)
            .apply()
    }

    /** Returns [urdu] if Urdu is selected, otherwise [english]. */
    fun t(context: Context, english: String, urdu: String): String {
        return if (isUrdu(context)) urdu else english
    }
}

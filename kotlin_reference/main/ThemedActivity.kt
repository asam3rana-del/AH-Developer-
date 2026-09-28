package com.grocerypos.v11.ui

import android.os.Bundle
import androidx.appcompat.app.AppCompatActivity
import com.grocerypos.v11.util.AppPalette
import com.grocerypos.v11.util.ThemeManager

/**
 * Base class for every screen in the app that wants day/night mode support.
 *
 * Replace ": AppCompatActivity()" with ": ThemedActivity()" on each activity (ProductActivity,
 * PurchaseActivity, SaleActivity, MainActivity, ...). Each activity still builds its own colors
 * from [palette] inside its own onCreate(), exactly like before — this base class only takes
 * care of:
 *
 * 1. Knowing which theme was active when this screen was created ([themeAtCreate]).
 * 2. Detecting, in onResume(), if the theme was changed elsewhere (e.g. the user toggled it on
 *    a different screen and came back here) and recreating this activity automatically so it
 *    picks up the new colors — without any manual wiring between activities.
 */
abstract class ThemedActivity : AppCompatActivity() {

    /** Current palette for this screen — read this instead of hardcoding hex colors. */
    protected val palette: AppPalette
        get() = ThemeManager.palette(this)

    protected val isDarkMode: Boolean
        get() = ThemeManager.isDarkMode(this)

    private var themeAtCreate: Boolean = false

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        themeAtCreate = ThemeManager.isDarkMode(this)
    }

    override fun onResume() {
        super.onResume()
        if (ThemeManager.isDarkMode(this) != themeAtCreate) {
            recreate()
        }
    }

    /** Call this from a toggle button's onClick anywhere in the app. */
    protected fun toggleAppTheme() {
        ThemeManager.toggleDarkMode(this)
        recreate()
    }
}

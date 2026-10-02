package com.grocerypos.v11.util

import android.app.Activity
import android.view.View
import androidx.core.view.ViewCompat
import androidx.core.view.WindowCompat
import androidx.core.view.WindowInsetsCompat

/**
 * FIX (numeric keypad / Gboard covers Paid & Due amount): reported bug — on the Purchase
 * screen, opening the system keyboard for "Paid Amount" hid the Total/Paid/Due card and the
 * Save button behind it, so there was no way to see how much was due while typing.
 *
 * Root cause: this app targets SDK 35 (Android 15), which makes every activity edge-to-edge
 * by default. Once that's true, `android:windowSoftInputMode="adjustResize"` in the manifest
 * stops working the old way — the decor view no longer physically shrinks when the keyboard
 * opens, so the keyboard just draws on top of the bottom of the screen instead of pushing
 * content up. `PurchaseActivity` and `SaleActivity` had no code reacting to the keyboard's
 * height at all, so their pinned Total/Paid/Due/Save footer simply disappeared underneath it.
 *
 * Call this once, right after setContentView(root), on any screen with content pinned to the
 * bottom that needs to stay visible while a field is being typed into (Paid Amount, Discount,
 * etc.). It listens for IME (keyboard) insets and pads the root view's bottom by exactly the
 * keyboard's height, restoring the pre-edge-to-edge "content moves up, nothing gets hidden"
 * behavior.
 */
fun Activity.keepContentAboveKeyboard(root: View) {
    WindowCompat.setDecorFitsSystemWindows(window, false)
    val basePaddingBottom = root.paddingBottom
    ViewCompat.setOnApplyWindowInsetsListener(root) { view, insets ->
        val imeHeight = insets.getInsets(WindowInsetsCompat.Type.ime()).bottom
        val navBarHeight = insets.getInsets(WindowInsetsCompat.Type.systemBars()).bottom
        // When the keyboard is open, imeHeight already accounts for the nav bar sitting
        // underneath it, so just use whichever inset is currently larger.
        view.setPadding(view.paddingLeft, view.paddingTop, view.paddingRight, basePaddingBottom + maxOf(imeHeight, navBarHeight))
        insets
    }
    ViewCompat.requestApplyInsets(root)
}

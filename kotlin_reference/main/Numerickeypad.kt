package com.grocerypos.v11.ui.widget

import android.app.Dialog
import android.content.Context
import android.graphics.Color
import android.graphics.Typeface
import android.graphics.drawable.GradientDrawable
import android.text.InputType
import android.view.Gravity
import android.view.View
import android.view.ViewGroup
import android.view.Window
import android.view.WindowManager
import android.widget.EditText
import android.widget.GridLayout
import android.widget.LinearLayout
import android.widget.TextView

/**
 * Custom numeric keypad — a bottom-anchored dialog with 0-9, decimal point, backspace and
 * Done. Used instead of the system (Gboard) numeric keyboard for fields where a fully
 * app-controlled input experience is wanted (Quantity, Rate, Discount, Amount Paid, etc.).
 *
 * Usage:
 *     qty.useNumericKeypad(allowDecimal = true)
 *     paidInput.useNumericKeypad(allowDecimal = false)
 *
 * That single call:
 *   1. Disables the system keyboard for that EditText (inputType NULL + showSoftInputOnFocus
 *      = false on API 21+, plus a click/focus listener as a fallback on older devices).
 *   2. Opens this dialog anchored to the bottom of the screen whenever the field is tapped
 *      or gains focus.
 *   3. Writes digits directly into the EditText's Editable as buttons are tapped, keeping
 *      any TextWatcher you already attached (stock preview, live totals, etc.) working
 *      exactly as before — the keypad never bypasses the normal text-change pipeline.
 */
object NumericKeypad {

    fun attach(editText: EditText, allowDecimal: Boolean = true, onDone: (() -> Unit)? = null) {
        // Stop the system keyboard from ever appearing for this field.
        editText.inputType = InputType.TYPE_NULL
        editText.isCursorVisible = true
        editText.showSoftInputOnFocusCompat(false)

        val opener = View.OnClickListener { show(editText, allowDecimal, onDone) }
        editText.setOnClickListener(opener)
        editText.setOnFocusChangeListener { _, hasFocus -> if (hasFocus) show(editText, allowDecimal, onDone) }
    }

    private fun EditText.showSoftInputOnFocusCompat(show: Boolean) {
        try {
            // showSoftInputOnFocus is API 21+; reflection avoids a hard version check here
            // since min/target SDK isn't known from this file alone.
            val m = EditText::class.java.getMethod("setShowSoftInputOnFocus", Boolean::class.javaPrimitiveType)
            m.invoke(this, show)
        } catch (e: Exception) {
            // Fallback: older devices simply rely on inputType TYPE_NULL above, which already
            // prevents the system keyboard from opening in almost all cases.
        }
    }

    private fun show(target: EditText, allowDecimal: Boolean, onDone: (() -> Unit)?) {
        val context = target.context
        // CHANGED (brought onto the central theme system — was hardcoded hex, now
        // matches Sale/Purchase/Items/Settings/Reports and respects dark mode).
        val p = com.grocerypos.v11.util.ThemeManager.palette(context)
        val navy = p.flatBlueFg
        val keyBg = p.fieldFill
        val keyText = p.textDark
        val dialog = Dialog(context, android.R.style.Theme_Black_NoTitleBar)
        dialog.requestWindowFeature(Window.FEATURE_NO_TITLE)

        val panel = LinearLayout(context).apply {
            orientation = LinearLayout.VERTICAL
            setPadding(dp(context, 18), dp(context, 16), dp(context, 18), dp(context, 18))
            background = GradientDrawable().apply {
                setColor(Color.parseColor(p.cardWhite))
                cornerRadii = floatArrayOf(
                    dp(context, 22).toFloat(), dp(context, 22).toFloat(),
                    dp(context, 22).toFloat(), dp(context, 22).toFloat(),
                    0f, 0f, 0f, 0f
                )
            }
        }

        // Small preview of the field's current label + live value, so the user isn't typing
        // "blind" with the system keyboard gone.
        val previewRow = LinearLayout(context).apply {
            orientation = LinearLayout.HORIZONTAL
            gravity = Gravity.CENTER_VERTICAL
            setPadding(dp(context, 6), 0, dp(context, 6), dp(context, 14))
        }
        val hintLabel = TextView(context).apply {
            text = target.hint ?: ""
            textSize = 12f
            setTextColor(Color.parseColor(p.textMuted))
            layoutParams = LinearLayout.LayoutParams(0, LinearLayout.LayoutParams.WRAP_CONTENT, 1f)
        }
        val valuePreview = TextView(context).apply {
            text = if (target.text.isNullOrEmpty()) "0" else target.text.toString()
            textSize = 20f
            setTypeface(typeface, Typeface.BOLD)
            setTextColor(Color.parseColor(navy))
        }
        previewRow.addView(hintLabel)
        previewRow.addView(valuePreview)
        panel.addView(previewRow)

        fun refreshPreview() {
            valuePreview.text = if (target.text.isNullOrEmpty()) "0" else target.text.toString()
        }

        val grid = GridLayout(context).apply {
            columnCount = 3
            rowCount = 4
            layoutParams = LinearLayout.LayoutParams(LinearLayout.LayoutParams.MATCH_PARENT, LinearLayout.LayoutParams.WRAP_CONTENT)
        }

        fun insertAtCursor(chars: String) {
            val editable = target.text
            val start = target.selectionStart.coerceAtLeast(0)
            val end = target.selectionEnd.coerceAtLeast(0)
            editable.replace(minOf(start, end), maxOf(start, end), chars)
            refreshPreview()
        }

        fun backspace() {
            val editable = target.text
            val start = target.selectionStart.coerceAtLeast(0)
            val end = target.selectionEnd.coerceAtLeast(0)
            if (start != end) {
                editable.replace(minOf(start, end), maxOf(start, end), "")
            } else if (start > 0) {
                editable.delete(start - 1, start)
            }
            refreshPreview()
        }

        fun key(label: String, isAccent: Boolean = false, onClick: () -> Unit): TextView =
            TextView(context).apply {
                text = label
                textSize = 20f
                gravity = Gravity.CENTER
                setTypeface(typeface, Typeface.BOLD)
                setTextColor(if (isAccent) Color.WHITE else Color.parseColor(keyText))
                background = GradientDrawable().apply {
                    setColor(Color.parseColor(if (isAccent) navy else keyBg))
                    cornerRadius = dp(context, 14).toFloat()
                }
                layoutParams = GridLayout.LayoutParams(
                    GridLayout.spec(GridLayout.UNDEFINED, 1f),
                    GridLayout.spec(GridLayout.UNDEFINED, 1f)
                ).apply {
                    width = 0
                    height = dp(context, 56)
                    setMargins(dp(context, 6), dp(context, 6), dp(context, 6), dp(context, 6))
                }
                setOnClickListener { onClick() }
            }

        val digits = listOf("1", "2", "3", "4", "5", "6", "7", "8", "9")
        digits.forEach { d -> grid.addView(key(d) { insertAtCursor(d) }) }

        grid.addView(
            if (allowDecimal) {
                key(".") { if (target.text?.contains(".") != true) insertAtCursor(".") }
            } else {
                key("") {}.apply { isEnabled = false; background = null }
            }
        )
        grid.addView(key("0") { insertAtCursor("0") })
        grid.addView(key("⌫") { backspace() })

        panel.addView(grid)
        panel.addView(View(context).apply {
            layoutParams = LinearLayout.LayoutParams(LinearLayout.LayoutParams.MATCH_PARENT, dp(context, 12))
        })

        panel.addView(TextView(context).apply {
            text = "✓  Done"
            textSize = 15f
            gravity = Gravity.CENTER
            setTypeface(typeface, Typeface.BOLD)
            setTextColor(Color.WHITE)
            background = GradientDrawable().apply {
                setColor(Color.parseColor(navy))
                cornerRadius = dp(context, 14).toFloat()
            }
            setPadding(0, dp(context, 22), 0, dp(context, 22))
            setOnClickListener {
                dialog.dismiss()
                onDone?.invoke()
            }
        })

        dialog.setContentView(panel)
        dialog.window?.apply {
            setLayout(WindowManager.LayoutParams.MATCH_PARENT, WindowManager.LayoutParams.WRAP_CONTENT)
            setGravity(Gravity.BOTTOM)
            setBackgroundDrawableResource(android.R.color.transparent)
            attributes = attributes.apply { dimAmount = 0.35f }
            setDimAmount(0.35f)
        }
        dialog.show()
    }

    private fun dp(context: Context, value: Int): Int =
        (value * context.resources.displayMetrics.density).toInt()
}

/** Convenience extension: `qty.useNumericKeypad()` */
fun EditText.useNumericKeypad(allowDecimal: Boolean = true, onDone: (() -> Unit)? = null) {
    NumericKeypad.attach(this, allowDecimal, onDone)
}

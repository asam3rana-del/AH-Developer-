package com.grocerypos.v11.util

import android.content.Context
import android.widget.EditText
import android.widget.Toast

/**
 * ================= Fix: numeric fields silently becoming 0.0 on parse-fail =================
 *
 * Audit finding (see "Bug assessment" #4): 77 places across the app used the
 * pattern
 *
 *   xInput.text.toString().toDoubleOrNull() ?: 0.0
 *
 * directly. That pattern can't tell "field left blank" apart from "field has
 * text that failed to parse" — both silently become 0.0 with nothing shown
 * to the user. toDoubleOrNull() is locale-independent and only accepts '.'
 * as the decimal separator, so a device with a non-standard locale, or an
 * unexpected character from a numeric keypad, would make a real rate /
 * amount / balance get saved as 0 with no warning at all.
 *
 * Fixing all 77 blindly would also be wrong: most of them run inside live
 * TextWatchers that recompute an on-screen total on every keystroke — 0.0
 * while the shopkeeper is still mid-way through typing a number is correct
 * there, not a bug, and popping a toast on every keystroke would be worse
 * than the original issue. Some others already have a "<= 0 -> show error"
 * guard right after the parse, which already catches an unparseable value.
 *
 * This fix targets the money-critical SAVE points that had neither: opening
 * cash/bank balances, party credit limit / opening / stuck balance, product
 * cost/sale/wholesale price, sale discount/paid, purchase paid amount, and
 * Zakat assets. Each of those call sites now uses parseMoneyOrWarn() below
 * instead of the bare `?: 0.0`, so a non-empty-but-invalid value blocks the
 * save with a clear message instead of quietly becoming 0.
 *
 * Usage at a save function's top (replacing the old pattern):
 *   val paid = paidInput.parseMoneyOrWarn(this, "Paid Amount", "ادا شدہ رقم")
 *       ?: return   // (or return@setOnClickListener / return@setPositiveButton)
 */
fun EditText.parseMoneyOrWarn(context: Context, fieldLabelEn: String, fieldLabelUr: String): Double? {
    val raw = text.toString().trim()
    if (raw.isEmpty()) return 0.0
    val value = raw.toDoubleOrNull()
    if (value == null) {
        Toast.makeText(
            context,
            Loc.t(
                context,
                "Invalid amount in \"$fieldLabelEn\" (\"$raw\") \u2014 please correct it.",
                "\u201c$fieldLabelUr\u201d میں غلط رقم (\u201c$raw\u201d) \u2014 براہ کرم درست کریں۔"
            ),
            Toast.LENGTH_LONG
        ).show()
        requestFocus()
        return null
    }
    return value
}

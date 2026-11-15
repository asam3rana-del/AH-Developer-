package com.grocerypos.v11.ui

import com.grocerypos.v11.R

/*
 * Sale screen — Quick Sale dialog (single-item fast checkout, launched from
 * the header pill). Split out of SaleActivity.kt as part of the "Oversized
 * Activity files" cleanup (see IMPROVEMENT-PLAN.md). Declared as extension
 * functions on SaleActivity so they still reach the screen's theme colors,
 * product/customer lists, and helper builders directly. No behavior change —
 * the previous private saveQuickSale() wrapper was inlined into a direct
 * viewModel.saveQuickSale(...) call since it added no logic of its own.
 */

import android.graphics.Color
import android.text.InputType
import android.view.Gravity
import android.view.View
import android.view.inputmethod.EditorInfo
import android.widget.AdapterView
import android.widget.ArrayAdapter
import android.widget.AutoCompleteTextView
import android.widget.EditText
import android.widget.ImageView
import android.widget.LinearLayout
import android.widget.ScrollView
import android.widget.Spinner
import android.widget.TextView
import android.widget.Toast
import androidx.appcompat.app.AlertDialog
import androidx.lifecycle.lifecycleScope
import com.grocerypos.v11.*
import com.grocerypos.v11.ui.components.*
import kotlinx.coroutines.launch

// Local copy of the tintedDrawable/setLeadingIcon pair used across the Activity
// files for item #6 (emoji -> vector icon). This file is a set of extension
// functions (not an Activity subclass), so it can't reach SaleActivity's
// private copy — kept as a private top-level pair scoped to this file only,
// same signature/behavior as everywhere else.
private fun SaleActivity.tintedDrawable(iconRes: Int, tintHex: String, sizeDp: Int = 16): android.graphics.drawable.Drawable? {
    val d = androidx.core.content.ContextCompat.getDrawable(this, iconRes)?.mutate() ?: return null
    d.setTint(Color.parseColor(tintHex))
    val size = (sizeDp * resources.displayMetrics.density).toInt()
    d.setBounds(0, 0, size, size)
    return d
}

private fun TextView.setLeadingIcon(activity: SaleActivity, iconRes: Int, tintHex: String, sizeDp: Int = 16, paddingDp: Int = 8) {
    setCompoundDrawablesRelative(activity.tintedDrawable(iconRes, tintHex, sizeDp), null, null, null)
    compoundDrawablePadding = (paddingDp * resources.displayMetrics.density).toInt()
}

internal fun SaleActivity.quickSaleDialog() {
    lifecycleScope.launch {
        showQuickSaleDialog(viewModel.topSellingProducts())
    }
}

internal fun SaleActivity.showQuickSaleDialog(topNames: List<String>) {
    var qsSelectedProduct: Product? = null
    var qsLastMainPrice: Double = 0.0

    // ---- helpers scoped to this dialog ----
    fun qsUnitsFor(p: Product): List<String> {
        val list = mutableListOf(p.unit)
        if (p.secondaryUnit.isNotEmpty()) {
            list.add(p.secondaryUnit)
            if (p.tertiaryUnit.isNotEmpty() && p.tertiaryUnitQty > 0) list.add(p.tertiaryUnit)
        }
        return list
    }
    fun qsToMainPrice(p: Product, entered: Double, unit: String): Double =
        p.toPrimaryUnitRate(entered, unit)
    fun qsFromMainPrice(p: Product, mainPrice: Double, unit: String): Double =
        p.fromPrimaryUnitRate(mainPrice, unit)
    fun qsAvailableInUnit(p: Product, unit: String): Double {
        val perUnitFactor = p.toSmallestUnits(1.0, unit)
        return if (perUnitFactor > 0) p.stock / perUnitFactor else p.stock.toDouble()
    }

    val container = LinearLayout(this).apply {
        orientation = LinearLayout.VERTICAL
        setPadding(dp(24), dp(20), dp(24), dp(4))
    }

    container.addView(TextView(this).apply {
        text = com.grocerypos.v11.util.Loc.t(this@showQuickSaleDialog, "Item Name", "آئٹم کا نام")
        setLeadingIcon(this@showQuickSaleDialog, R.drawable.ic_box, textGray, 13, 6)
        textSize = 11f
        setTextColor(Color.parseColor(textGray))
        setPadding(0, 0, 0, 6)
    })
    val qsItemName = AutoCompleteTextView(this).apply {
        hint = com.grocerypos.v11.util.Loc.t(this@showQuickSaleDialog, "Type to search…", "تلاش کے لیے لکھیں…")
        setHintTextColor(Color.parseColor(textGray))
        setTextColor(Color.parseColor(textDark))
        background = strokedBg(border, cardBg, 12)
        setPadding(dp(16), dp(14), dp(16), dp(14))
        threshold = 0
        textSize = 15f
        imeOptions = EditorInfo.IME_ACTION_NEXT
    }
    val topAvailable = topNames.filter { name -> products.any { it.name == name } }
    val remaining = products.map { it.name }.filter { it !in topAvailable }
    val orderedNames = (topAvailable + remaining).distinct()
    // FIX (English/Urdu search not working in Quick Sale): this dialog used a
    // plain ArrayAdapter(orderedNames), which relies on Android's built-in
    // dropdown filter — that only ever does a prefix match against each item's
    // own toString() (the raw product name), so it never checked searchTag
    // (the English alias for an Urdu-named item) and never matched mid-name
    // substrings either. SaleActivity/PurchaseActivity's own item boxes were
    // already fixed to use ProductNameAdapter (drives its own Filter off
    // Product.matchesQuery(), which checks name + searchTag) — Quick Sale was
    // just never switched over to it. Preserves the same top-selling-first
    // ordering by feeding it the ordered Product list instead of just names.
    val orderedProducts = orderedNames.mapNotNull { name -> products.find { it.name == name } }
    qsItemName.setAdapter(ProductNameAdapter(this) { orderedProducts })
    // FIX (English keyboard: typing didn't open the dropdown): forcing
    // showDropDown() below with empty text when the dialog first opens (so the
    // full list shows immediately) leaves AutoCompleteTextView's popup in a
    // state where, inside a Dialog window, it sometimes stops auto-reopening
    // once the user starts typing and the adapter's Filter completes — a known
    // AutoCompleteTextView quirk, not something specific to any keyboard/layout.
    // Forcing it back open after every keystroke's filter pass works around it
    // reliably.
    qsItemName.addTextChangedListener(simpleWatcher {
        if (qsItemName.adapter != null && qsItemName.isFocused) qsItemName.post { qsItemName.showDropDown() }
    })
    container.addView(qsItemName)
    container.addView(spacer(4))

    val qsStockText = TextView(this).apply {
        text = ""
        textSize = 12f
        setTextColor(Color.parseColor(teal))
        setPadding(2, 0, 0, 0)
    }
    container.addView(qsStockText)
    container.addView(spacer(8))

    container.addView(TextView(this).apply {
        text = com.grocerypos.v11.util.Loc.t(this@showQuickSaleDialog, "Unit", "یونٹ")
        setLeadingIcon(this@showQuickSaleDialog, R.drawable.ic_ruler, textGray, 13, 6)
        textSize = 11f
        setTextColor(Color.parseColor(textGray))
        setPadding(0, 0, 0, 6)
    })
    val qsUnitSpinner = Spinner(this).apply {
        adapter = ArrayAdapter(this@showQuickSaleDialog, android.R.layout.simple_spinner_dropdown_item, listOf("pcs"))
        background = null
    }
    // FIX (user report: Unit box looked like plain static text, not changeable):
    // the Spinner above already had real tap-to-change behavior and already
    // defaults correctly (defaultUnitIndexFor() — 3-tier picks the 2nd/secondary
    // unit, fewer tiers fall back to the only/last one), but giving it the same
    // flat strokedBg() as the other fields replaced Android's default spinner
    // chrome, which is what normally draws the dropdown arrow — so nothing on
    // screen signaled it was tappable. Wrapping it with a visible chevron here,
    // same ic_chevron_down + textGray treatment SettingsActivity's chevronText()
    // uses for its own flat dropdown fields, fixes that without touching the
    // (already-correct) selection logic.
    val qsUnitSpinnerRow = LinearLayout(this).apply {
        orientation = LinearLayout.HORIZONTAL
        gravity = Gravity.CENTER_VERTICAL
        background = strokedBg(border, cardBg, 12)
        setPadding(dp(12), dp(4), dp(12), dp(4))
        addView(qsUnitSpinner, LinearLayout.LayoutParams(0, LinearLayout.LayoutParams.WRAP_CONTENT, 1f))
        addView(ImageView(this@showQuickSaleDialog).apply {
            setImageDrawable(this@showQuickSaleDialog.tintedDrawable(R.drawable.ic_chevron_down, textGray, 14))
        })
    }
    container.addView(qsUnitSpinnerRow)
    container.addView(spacer(12))

    container.addView(TextView(this).apply {
        text = com.grocerypos.v11.util.Loc.t(this@showQuickSaleDialog, "Quantity", "مقدار")
        setLeadingIcon(this@showQuickSaleDialog, R.drawable.ic_number, textGray, 13, 6)
        textSize = 11f
        setTextColor(Color.parseColor(textGray))
        setPadding(0, 0, 0, 6)
    })
    val qsQty = EditText(this).apply {
        hint = "1"
        setHintTextColor(Color.parseColor(textGray))
        setTextColor(Color.parseColor(textDark))
        background = strokedBg(border, cardBg, 12)
        setPadding(dp(16), dp(14), dp(16), dp(14))
        inputType = InputType.TYPE_CLASS_NUMBER or InputType.TYPE_NUMBER_FLAG_DECIMAL
        imeOptions = EditorInfo.IME_ACTION_NEXT
        layoutParams = LinearLayout.LayoutParams(0, LinearLayout.LayoutParams.WRAP_CONTENT, 1f)
    }
    val qsQtyRow = LinearLayout(this).apply { orientation = LinearLayout.HORIZONTAL; gravity = Gravity.CENTER_VERTICAL }
    qsQtyRow.addView(qsQty)
    qsQtyRow.addView(View(this).apply { layoutParams = LinearLayout.LayoutParams(dp(8), 1) })
    qsQtyRow.addView(circleIcon("+", teal, 36) {
        val current = qsQty.text.toString().toDoubleOrNull() ?: 0.0
        val next = current + 1
        qsQty.setText(if (next == next.toLong().toDouble()) next.toLong().toString() else next.toString())
        qsQty.setSelection(qsQty.text.length)
    })
    container.addView(qsQtyRow)
    container.addView(spacer(12))

    container.addView(TextView(this).apply {
        text = com.grocerypos.v11.util.Loc.t(this@showQuickSaleDialog, "Rate", "ریٹ")
        setLeadingIcon(this@showQuickSaleDialog, R.drawable.ic_wallet, textGray, 13, 6)
        textSize = 11f
        setTextColor(Color.parseColor(textGray))
        setPadding(0, 0, 0, 6)
    })
    val qsPrice = EditText(this).apply {
        hint = com.grocerypos.v11.util.Loc.t(this@showQuickSaleDialog, "Auto-filled, editable", "خودکار، قابل ترمیم")
        setHintTextColor(Color.parseColor(textGray))
        setTextColor(Color.parseColor(textDark))
        background = strokedBg(border, cardBg, 12)
        setPadding(dp(16), dp(14), dp(16), dp(14))
        inputType = InputType.TYPE_CLASS_NUMBER or InputType.TYPE_NUMBER_FLAG_DECIMAL
        imeOptions = EditorInfo.IME_ACTION_NEXT
    }
    container.addView(qsPrice)
    container.addView(spacer(12))

    container.addView(TextView(this).apply {
        text = com.grocerypos.v11.util.Loc.t(this@showQuickSaleDialog, "Customer (blank = Cash Sale)", "کسٹمر (خالی = کیش سیل)")
        setLeadingIcon(this@showQuickSaleDialog, R.drawable.ic_person, textGray, 13, 6)
        textSize = 11f
        setTextColor(Color.parseColor(textGray))
        setPadding(0, 0, 0, 6)
    })
    val qsCustomer = AutoCompleteTextView(this).apply {
        hint = com.grocerypos.v11.util.Loc.t(this@showQuickSaleDialog, "Blank = Cash, Name = Credit", "خالی = کیش، نام = ادھار")
        setHintTextColor(Color.parseColor(textGray))
        setTextColor(Color.parseColor(textDark))
        background = strokedBg(border, cardBg, 12)
        setPadding(dp(16), dp(14), dp(16), dp(14))
        threshold = 1
        textSize = 15f
        imeOptions = EditorInfo.IME_ACTION_DONE
    }
    qsCustomer.setAdapter(ArrayAdapter(this, android.R.layout.simple_dropdown_item_1line, customers.map { it.name }))
    container.addView(qsCustomer)
    container.addView(spacer(10))

    val qsTotalText = TextView(this).apply {
        text = "Total: Rs 0.00"
        textSize = 15f
        setTextColor(Color.parseColor(textDark))
        setTypeface(typeface, android.graphics.Typeface.BOLD)
        setPadding(2, 0, 0, 4)
    }
    container.addView(qsTotalText)
    container.addView(spacer(4))

    fun qsRefreshTotal() {
        val q = qsQty.text.toString().toDoubleOrNull() ?: 0.0
        val price = qsPrice.text.toString().toDoubleOrNull() ?: 0.0
        qsTotalText.text = "Total: Rs %.2f".format(q * price)
    }
    fun qsRefreshStock() {
        val p = qsSelectedProduct
        if (p == null) { qsStockText.text = ""; return }
        val unit = qsUnitSpinner.selectedItem?.toString() ?: p.unit
        val avail = qsAvailableInUnit(p, unit)
        qsStockText.text = com.grocerypos.v11.util.Loc.t(
            this,
            "Available: %s %s".format(formatQty(avail), unit),
            "دستیاب: %s %s".format(formatQty(avail), unit)
        )
    }

    qsQty.addTextChangedListener(simpleWatcher { qsRefreshTotal() })
    qsPrice.addTextChangedListener(simpleWatcher { qsRefreshTotal() })

    qsItemName.setOnEditorActionListener { _, actionId, _ ->
        if (actionId == EditorInfo.IME_ACTION_NEXT) {
            val typed = qsItemName.text.toString().trim()
            val match = products.find { it.name.equals(typed, ignoreCase = true) }
            if (match != null) {
                qsSelectedProduct = match
                qsLastMainPrice = 0.0
                val qsUnits = qsUnitsFor(match)
                // FIX (unit auto-selection): uses the Quick Sale-specific default
                // (quickSaleDefaultUnitIndexFor()) instead of normal Sale's — lets a
                // product default to a different unit here than in Add Item, since
                // the smaller unit tends to get used more in Quick Sale. Falls back
                // to the same Auto guess (1-tier -> only unit, 2-tier by category,
                // 3-tier -> 2nd/secondary unit) when no override is set.
                val qsDefaultIndex = quickSaleDefaultUnitIndexFor(match)
                qsUnitSpinner.adapter = ArrayAdapter(this, android.R.layout.simple_spinner_dropdown_item, qsUnits)
                qsUnitSpinner.setSelection(qsDefaultIndex)
                if (qsQty.text.toString().isBlank()) qsQty.setText("1")
                val defaultUnit = qsUnits[qsDefaultIndex]
                val price = qsFromMainPrice(match, match.salePrice, defaultUnit)
                qsPrice.setText(if (price > 0) "%.2f".format(price) else "")
                qsRefreshStock(); qsRefreshTotal()
            }
            qsQty.requestFocus()
            qsQty.setSelection(qsQty.text.length)
            true
        } else false
    }
    qsQty.setOnEditorActionListener { _, actionId, _ ->
        if (actionId == EditorInfo.IME_ACTION_NEXT) { qsPrice.requestFocus(); true } else false
    }
    qsPrice.setOnEditorActionListener { _, actionId, _ ->
        if (actionId == EditorInfo.IME_ACTION_NEXT) { qsCustomer.requestFocus(); true } else false
    }

    qsItemName.setOnItemClickListener { _, _, position, _ ->
        val name = qsItemName.adapter.getItem(position).toString()
        val p = products.find { it.name.equals(name, ignoreCase = true) }
        qsSelectedProduct = p
        qsLastMainPrice = 0.0
        if (p != null) {
            val qsUnits = qsUnitsFor(p)
            // FIX (unit auto-selection): same rule as above — see quickSaleDefaultUnitIndexFor().
            val qsDefaultIndex = quickSaleDefaultUnitIndexFor(p)
            qsUnitSpinner.adapter = ArrayAdapter(this, android.R.layout.simple_spinner_dropdown_item, qsUnits)
            qsUnitSpinner.setSelection(qsDefaultIndex)
            qsQty.setText(if (qsQty.text.toString().isBlank()) "1" else qsQty.text.toString())
            val defaultUnit = qsUnits[qsDefaultIndex]
            val price = qsFromMainPrice(p, p.salePrice, defaultUnit)
            qsPrice.setText(if (price > 0) "%.2f".format(price) else "")
            qsQty.requestFocus()
            qsQty.setSelection(qsQty.text.length)
            qsRefreshStock(); qsRefreshTotal()
        }
    }

    qsUnitSpinner.onItemSelectedListener = object : AdapterView.OnItemSelectedListener {
        override fun onItemSelected(parent: AdapterView<*>?, v: View?, pos: Int, id: Long) {
            val p = qsSelectedProduct ?: return
            val unit = qsUnitSpinner.selectedItem?.toString() ?: p.unit
            val base = if (qsLastMainPrice > 0) qsLastMainPrice else p.salePrice
            val price = qsFromMainPrice(p, base, unit)
            qsPrice.setText(if (price > 0) "%.2f".format(price) else "")
            qsRefreshStock(); qsRefreshTotal()
        }
        override fun onNothingSelected(parent: AdapterView<*>?) {}
    }
    qsPrice.addTextChangedListener(simpleWatcher {
        val p = qsSelectedProduct ?: return@simpleWatcher
        val unit = qsUnitSpinner.selectedItem?.toString() ?: p.unit
        val entered = qsPrice.text.toString().toDoubleOrNull() ?: 0.0
        qsLastMainPrice = qsToMainPrice(p, entered, unit)
    })

    val scroll = ScrollView(this).apply { addView(container) }

    val dialog = AlertDialog.Builder(this)
        .setTitle(com.grocerypos.v11.util.Loc.t(this, "Quick Sale", "فوری سیل"))
        .setView(scroll)
        .setPositiveButton(com.grocerypos.v11.util.Loc.t(this, "SAVE", "محفوظ کریں"), null)
        .setNegativeButton(com.grocerypos.v11.util.Loc.t(this, "Cancel", "منسوخ"), null)
        .create()

    dialog.setOnShowListener {
        qsItemName.post { qsItemName.showDropDown() }
        val positiveBtn = dialog.getButton(AlertDialog.BUTTON_POSITIVE)
        positiveBtn.setOnClickListener {
            val typedName = qsItemName.text.toString().trim()
            val product = qsSelectedProduct?.takeIf { it.name.equals(typedName, ignoreCase = true) }
                ?: products.find { it.name.equals(typedName, ignoreCase = true) }
            if (product == null) {
                Toast.makeText(this, "Ye item product list mein nahi hai", Toast.LENGTH_SHORT).show()
                return@setOnClickListener
            }
            val q = qsQty.text.toString().toDoubleOrNull() ?: 0.0
            if (q <= 0) {
                Toast.makeText(this, "Quantity theek se likhen", Toast.LENGTH_SHORT).show()
                return@setOnClickListener
            }
            val chosenUnit = qsUnitSpinner.selectedItem?.toString() ?: product.unit
            val price = qsPrice.text.toString().toDoubleOrNull() ?: product.salePrice
            val neededSmallest = product.toSmallestUnits(q, chosenUnit)
            if (product.stock < neededSmallest) {
                Toast.makeText(
                    this,
                    "Stock kam hai (available: ${formatQty(product.stock.toDouble())} ${product.smallestUnitName()})",
                    Toast.LENGTH_SHORT
                ).show()
                return@setOnClickListener
            }
            val custName = qsCustomer.text.toString().trim()
            // NEW (10/10 Priority #7): stashed so a possible CreditLimitExceeded
            // confirm dialog (raised after this dialog is already dismissed) can
            // re-submit the same inputs — see SaleActivity.PendingQuickSale.
            pendingQuickSale = SaleActivity.PendingQuickSale(product, q, price, chosenUnit, custName)
            viewModel.saveQuickSale(product, q, price, chosenUnit, custName)
            dialog.dismiss()
        }
    }
    dialog.show()

    // ---- ADDED (tablet / desktop-style layout): AlertDialog defaults to
    // stretching almost full-width, which looks like an oversized phone popup
    // on a tablet. Capping it to a fixed, comfortable width on tablet-wide
    // screens makes it read like a proper desktop dialog box instead. ----
    if (isTabletWide) {
        val widthPx = (560 * resources.displayMetrics.density).toInt()
        dialog.window?.setLayout(widthPx, android.view.ViewGroup.LayoutParams.WRAP_CONTENT)
    }
}

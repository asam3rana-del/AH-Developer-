package com.grocerypos.v11.ui

/*
 * Sale screen — shopping-cart subsystem: picking an item, choosing its unit,
 * auto-filling price, adding/removing lines, and keeping the subtotal /
 * discount / total / due amounts in sync. Split out of SaleActivity.kt as
 * part of the "Oversized Activity files" cleanup (see IMPROVEMENT-PLAN.md) —
 * these functions are declared as extension functions on SaleActivity so
 * they still read/write the screen's views and state directly, exactly as
 * before, just from a separate file. No behavior change.
 */

import android.content.Context
import android.graphics.Color
import android.view.Gravity
import android.view.View
import android.view.ViewGroup
import android.view.inputmethod.InputMethodManager
import android.widget.ArrayAdapter
import android.widget.LinearLayout
import android.widget.ScrollView
import android.widget.TextView
import android.widget.Toast
import androidx.appcompat.app.AlertDialog
import androidx.lifecycle.lifecycleScope
import com.grocerypos.v11.*
import com.grocerypos.v11.domain.SaleLine
import com.grocerypos.v11.pricing.DiscountCalculator
import com.grocerypos.v11.ui.components.*
import kotlinx.coroutines.launch

// Pulled out of defaultUnitIndexFor() below as a plain top-level function (no
// SaleActivity receiver needed) so BulkDefaultUnitActivity can show the same
// "Auto would pick..." suggestion for a product without needing a SaleActivity
// instance. Only the fixed 1/2/3-tier + Beverages-category rule — the manual
// per-product override lives in defaultUnitIndexFor() below.
fun autoDefaultUnitIndexFor(product: Product): Int {
    val hasSecondary = product.secondaryUnit.isNotEmpty()
    val hasTertiary = hasSecondary && product.tertiaryUnit.isNotEmpty() && product.tertiaryUnitQty > 0

    if (!hasSecondary) return 0          // 1-tier: only one unit exists
    if (hasTertiary) return 1            // 3-tier: always default to the 2nd unit

    // 2-tier, Auto: Beverages keep the 1st (primary) unit; everything else
    // defaults to the 2nd (secondary) unit.
    val isBeverage = product.category.equals(SaleActivity.BEVERAGE_CATEGORY, ignoreCase = true)
    return if (isBeverage) 0 else 1
}

internal fun SaleActivity.defaultUnitIndexFor(product: Product): Int {
    val hasSecondary = product.secondaryUnit.isNotEmpty()
    val hasTertiary = hasSecondary && product.tertiaryUnit.isNotEmpty() && product.tertiaryUnitQty > 0
    val tierCount = if (hasTertiary) 3 else if (hasSecondary) 2 else 1

    // NEW (manual default-unit override): a shopkeeper-chosen tier from the
    // "Add Item Unit" dialog (or from BulkDefaultUnitActivity's queue) always
    // wins over the automatic guess below — this is what lets a product opt
    // out of the Beverages-only special case without touching code. -1 (or an
    // out-of-range value left over from before the product's unit count was
    // last edited) falls through to Auto.
    if (product.defaultUnitIndex in 0 until tierCount) return product.defaultUnitIndex

    return autoDefaultUnitIndexFor(product)
}

// NEW (Quick Sale-specific default unit): same shape as defaultUnitIndexFor()
// above, but reads the separate quickSaleDefaultUnitIndex override instead —
// lets a product default to a different tier in Quick Sale than in the normal
// Sale screen (e.g. shopkeeper picks the smallest unit for Quick Sale since
// that's what gets used there most often, while Sale keeps defaulting per the
// Auto/defaultUnitIndex rule). Falls back to the same Auto guess when unset.
internal fun SaleActivity.quickSaleDefaultUnitIndexFor(product: Product): Int {
    val hasSecondary = product.secondaryUnit.isNotEmpty()
    val hasTertiary = hasSecondary && product.tertiaryUnit.isNotEmpty() && product.tertiaryUnitQty > 0
    val tierCount = if (hasTertiary) 3 else if (hasSecondary) 2 else 1

    if (product.quickSaleDefaultUnitIndex in 0 until tierCount) return product.quickSaleDefaultUnitIndex

    return autoDefaultUnitIndexFor(product)
}

internal fun SaleActivity.onItemPicked(name: String) {
    val product = products.find { it.name.equals(name, ignoreCase = true) } ?: return
    selectedProduct = product
    val unitChoices = mutableListOf(product.unit)
    if (product.secondaryUnit.isNotEmpty()) {
        unitChoices.add(product.secondaryUnit)
        if (product.tertiaryUnit.isNotEmpty() && product.tertiaryUnitQty > 0) {
            unitChoices.add(product.tertiaryUnit)
        }
    }
    val defaultIndex = defaultUnitIndexFor(product)
    unitSpinner.adapter = ArrayAdapter(this, android.R.layout.simple_spinner_dropdown_item, unitChoices)
    unitSpinner.setSelection(defaultIndex)
    buildUnitChips(unitChoices, unitChoices[defaultIndex])
    conversionInfo.text = buildString {
        if (unitChoices.size > 1 && product.secondaryUnitQty > 0) append("1 ${product.unit} = ${product.secondaryUnitQty} ${product.secondaryUnit}")
        if (unitChoices.size > 2 && product.tertiaryUnitQty > 0) { if (isNotEmpty()) append("   •   "); append("1 ${product.secondaryUnit} = ${product.tertiaryUnitQty} ${product.tertiaryUnit}") }
    }
    conversionInfo.visibility = if (conversionInfo.text.isNotEmpty()) View.VISIBLE else View.GONE
    lastMainPrice = 0.0
    refillAutoPrice()
    qty.requestFocus()
    qty.selectAll()
    qty.post {
        val imm = getSystemService(Context.INPUT_METHOD_SERVICE) as? InputMethodManager
        imm?.showSoftInput(qty, InputMethodManager.SHOW_IMPLICIT)
    }
}

internal fun SaleActivity.buildUnitChips(options: List<String>, selected: String) {
    unitToggleRow.removeAllViews()
    if (options.size < 2) { unitToggleRow.visibility = View.GONE; return }
    unitToggleRow.visibility = View.VISIBLE
    options.forEachIndexed { index, unitLabel ->
        val isSelected = unitLabel == selected
        val chip = TextView(this).apply {
            text = unitLabel; textSize = 13f; setTypeface(typeface, android.graphics.Typeface.BOLD); setPadding(28, 13, 28, 13)
            setTextColor(if (isSelected) Color.WHITE else Color.parseColor(teal))
            background = if (isSelected) roundedBg(teal, 30) else strokedBg(teal, cardBg, 30)
            layoutParams = LinearLayout.LayoutParams(LinearLayout.LayoutParams.WRAP_CONTENT, LinearLayout.LayoutParams.WRAP_CONTENT).apply { setMargins(if (index == 0) 0 else 8, 0, 0, 0) }
            setOnClickListener { unitSpinner.setSelection(options.indexOf(unitLabel)); buildUnitChips(options, unitLabel) }
        }
        unitToggleRow.addView(chip)
    }
}

// ---- delegated to Database.kt's toPrimaryUnitRate()/fromPrimaryUnitRate() —
// the same central unitLadder() that backs toSmallestUnits()/fromSmallestUnits() —
// instead of a duplicated inline formula (was previously copy-pasted separately in
// PurchaseActivity too — any future fix now only needs to happen in one place). ----
internal fun SaleActivity.toMainUnitPrice(entered: Double): Double {
    val product = selectedProduct ?: return entered
    val chosenUnit = unitSpinner.selectedItem?.toString() ?: product.unit
    return product.toPrimaryUnitRate(entered, chosenUnit)
}

internal fun SaleActivity.fromMainUnitPrice(mainPrice: Double, chosenUnit: String): Double {
    val product = selectedProduct ?: return mainPrice
    return product.fromPrimaryUnitRate(mainPrice, chosenUnit)
}

internal fun SaleActivity.refillAutoPrice() {
    val product = selectedProduct ?: return
    val isWholesale = saleTypeSpinner.selectedItem?.toString() == "Wholesale"
    val basePrice = if (isWholesale) product.wholesalePrice else product.salePrice
    val chosenUnit = unitSpinner.selectedItem?.toString() ?: product.unit
    val base = if (lastMainPrice > 0) lastMainPrice else basePrice
    val price = fromMainUnitPrice(base, chosenUnit)
    suppressPriceWatcher = true
    unitPrice.setText(if (price > 0) "%.2f".format(price) else "")
    suppressPriceWatcher = false
    customerRateHint.visibility = View.GONE
    updateItemLineTotal()
    updateMarginWarning()
    suggestCustomerRate()
}

// NEW: "customer ka apna rate" auto-suggest — if this exact customer has been
// charged a (possibly discounted/increased) rate for this exact item before,
// use THAT rate instead of the standard retail/wholesale price, so a
// deliberately custom-priced regular customer doesn't need their rate
// re-typed by hand every single bill. Falls back silently to the standard
// price when there's no match (new customer, or never sold this item to them
// before) or when the shopkeeper has already started typing their own number.
internal fun SaleActivity.suggestCustomerRate() {
    val product = selectedProduct ?: return
    val enteredName = customerName.text.toString().trim()
    if (enteredName.isEmpty()) return
    val customer = customers.find { it.name.equals(enteredName, ignoreCase = true) } ?: return
    val priceBeforeLookup = unitPrice.text.toString()
    val barcodeAtLookup = product.barcode
    lifecycleScope.launch {
        val rate = PosDatabase.get(this@suggestCustomerRate).saleDao().lastRateForCustomerItem(customer.id, barcodeAtLookup) ?: return@launch
        // Bail if the item row or price changed while we were querying (user
        // picked a different item, or already typed their own rate).
        if (selectedProduct?.barcode != barcodeAtLookup) return@launch
        if (unitPrice.text.toString() != priceBeforeLookup) return@launch
        val chosenUnit = unitSpinner.selectedItem?.toString() ?: product.unit
        val primaryRate = product.toPrimaryUnitRate(rate.unitPrice, rate.unit.ifBlank { product.unit })
        val priceInChosenUnit = product.fromPrimaryUnitRate(primaryRate, chosenUnit)
        if (priceInChosenUnit <= 0) return@launch
        lastMainPrice = primaryRate
        suppressPriceWatcher = true
        unitPrice.setText("%.2f".format(priceInChosenUnit))
        suppressPriceWatcher = false
        updateItemLineTotal()
        updateMarginWarning()
        customerRateHint.visibility = View.VISIBLE
        customerRateHint.text = com.grocerypos.v11.util.Loc.t(this@suggestCustomerRate,
            "${customer.name}'s usual rate applied: Rs %.2f / %s".format(priceInChosenUnit, chosenUnit),
            "${customer.name} کا معمول کا ریٹ لگا دیا گیا: روپے %.2f / %s".format(priceInChosenUnit, chosenUnit))
    }
}

// NEW ("10/10 Sale screen" — loss protection, mirrors PurchaseActivity's
// updateMarginWarning()): warns right where the rate is being typed if it's at or
// below this item's cost, instead of that only being discoverable later in reports.
internal fun SaleActivity.updateMarginWarning() {
    val product = selectedProduct
    val cost = product?.cost ?: 0.0
    if (product == null || cost <= 0.0) {
        marginWarningText.visibility = View.GONE
        return
    }
    val typedPrice = unitPrice.text.toString().toDoubleOrNull() ?: 0.0
    if (typedPrice <= 0.0) {
        marginWarningText.visibility = View.GONE
        return
    }
    val chosenUnit = unitSpinner.selectedItem?.toString() ?: product.unit
    val costInChosenUnit = fromMainUnitPrice(cost, chosenUnit)
    val margin = typedPrice - costInChosenUnit
    val marginPct = if (costInChosenUnit > 0) (margin / costInChosenUnit) * 100.0 else 0.0
    marginWarningText.visibility = View.VISIBLE
    when {
        margin <= 0 -> {
            marginWarningText.setTextColor(Color.parseColor(red))
            marginWarningText.text = com.grocerypos.v11.util.Loc.t(this,
                "⚠ Loss! Sale rate ≤ Cost (Rs %.2f)".format(costInChosenUnit),
                "⚠ نقصان! سیل ریٹ لاگت (روپے %.2f) کے برابر یا کم ہے".format(costInChosenUnit))
        }
        marginPct < 10.0 -> {
            marginWarningText.setTextColor(Color.parseColor(amber))
            marginWarningText.text = com.grocerypos.v11.util.Loc.t(this,
                "⚠ Low margin: Rs %.2f (%.1f%%) vs Cost Rs %.2f".format(margin, marginPct, costInChosenUnit),
                "⚠ کم منافع: روپے %.2f (%.1f%%) بمقابلہ لاگت روپے %.2f".format(margin, marginPct, costInChosenUnit))
        }
        else -> {
            marginWarningText.setTextColor(Color.parseColor(teal))
            marginWarningText.text = com.grocerypos.v11.util.Loc.t(this,
                "Margin: Rs %.2f (%.1f%%) vs Cost Rs %.2f".format(margin, marginPct, costInChosenUnit),
                "منافع: روپے %.2f (%.1f%%) بمقابلہ لاگت روپے %.2f".format(margin, marginPct, costInChosenUnit))
        }
    }
}

// NEW (Retail <-> Wholesale switch reprices existing cart lines): previously,
// switching Sale Type only auto-filled the price of whichever item was being
// typed into the entry row — items already added to the cart kept whatever rate
// they were added at. Now, when the user actually taps/picks a different Sale
// Type (guarded by saleTypeUserInteracted, so this never fires on a
// programmatic selection like loading an old invoice for edit or restoring a
// draft), every line already in the cart is repriced against ITS OWN product's
// retail/wholesale price, converted into that line's own unit — and its amount
// is recalculated to match. A line's cost (used for margin/profit reporting)
// is left untouched, since that's the purchase cost and has nothing to do with
// which sale type is selected.
internal fun SaleActivity.repriceLinesForSaleType() {
    if (lines.isEmpty()) return
    val isWholesale = saleTypeSpinner.selectedItem?.toString() == "Wholesale"
    var changed = false
    for (i in lines.indices) {
        val line = lines[i]
        val product = products.find { it.barcode == line.barcode }
            ?: products.find { it.name.equals(line.itemName, ignoreCase = true) }
            ?: continue
        val basePrice = if (isWholesale) product.wholesalePrice else product.salePrice
        // Product has no rate configured for the target type — leave this
        // line's existing price alone instead of zeroing it out.
        if (basePrice <= 0.0) continue
        val newPrice = product.fromPrimaryUnitRate(basePrice, line.unit)
        if (newPrice == line.unitPrice) continue
        lines[i] = line.copy(unitPrice = newPrice, amount = line.qty * newPrice)
        changed = true
    }
    if (changed) {
        renderItemsList()
        updateTotals()
        if (editInvoice == null) saveDraft()
    }
}

internal fun SaleActivity.toggleQtyAmountMode() {
    qtyIsAmountMode = !qtyIsAmountMode
    qty.text.clear()
    refreshQtyModeUi()
    updateItemLineTotal()
}

// Updates the Quantity box's hint + the "Rs" pill's look to match the current
// mode. Called on toggle and whenever the entry fields are reset, so the pill
// never shows stale state after Add/Cancel/edit-load.
internal fun SaleActivity.refreshQtyModeUi() {
    if (qtyIsAmountMode) {
        qty.hint = com.grocerypos.v11.util.Loc.t(this, "Amount in Rs", "روپے میں رقم")
        amountModeToggle.setTextColor(Color.WHITE)
        amountModeToggle.background = roundedBg(teal, 20)
    } else {
        qty.hint = "0"
        amountModeToggle.setTextColor(Color.parseColor(textGray))
        amountModeToggle.background = strokedBg(border, cardBg, 20)
    }
}

internal fun SaleActivity.updateItemLineTotal() {
    val price = unitPrice.text.toString().toDoubleOrNull() ?: 0.0
    if (qtyIsAmountMode) {
        // Amount mode: what's typed IS the total, and the quantity is the
        // derived value — shown so the shopkeeper can see roughly how much
        // they're about to hand over before adding it to the bill.
        val enteredAmount = qty.text.toString().toDoubleOrNull() ?: 0.0
        val chosenUnit = unitSpinner.selectedItem?.toString() ?: (selectedProduct?.unit ?: "")
        if (price > 0 && enteredAmount > 0) {
            val computedQty = kotlin.math.round((enteredAmount / price) * 1000) / 1000.0
            itemLineTotalText.text = "\u2248 ${formatQty(computedQty)} $chosenUnit   •   Total Amount: Rs %.0f".format(Math.round(enteredAmount).toDouble())
        } else {
            itemLineTotalText.text = "Total Amount: Rs 0"
        }
        return
    }
    val q = qty.text.toString().toDoubleOrNull() ?: 0.0
    itemLineTotalText.text = "Total Amount: Rs %.0f".format(Math.round(q * price).toDouble())
}

// ================= Add item to bill =================
internal fun SaleActivity.addItem() {
    val n = itemName.text.toString().trim()
    val price = unitPrice.text.toString().toDoubleOrNull() ?: 0.0

    // NEW (Buy-by-amount): in Rs mode, the qty field holds a Rupee amount, not
    // a quantity — work out the quantity from the rate before anything below
    // (stock check, line building) touches it, so the rest of addItem() never
    // needs to know which mode the shopkeeper was typing in.
    if (qtyIsAmountMode) {
        if (price <= 0) {
            Toast.makeText(this, "Pehle Rate likhein, phir Rs se qty nikalegi", Toast.LENGTH_SHORT).show()
            return
        }
        val enteredAmount = qty.text.toString().toDoubleOrNull() ?: 0.0
        if (enteredAmount <= 0) {
            Toast.makeText(this, "Rs amount theek se likhen", Toast.LENGTH_SHORT).show()
            return
        }
        val computedQty = kotlin.math.round((enteredAmount / price) * 1000) / 1000.0
        qty.setText(formatQty(computedQty))
    }

    val q = qty.text.toString().toDoubleOrNull() ?: 0.0
    val product = products.find { it.name.equals(n, ignoreCase = true) }

    if (product == null) {
        Toast.makeText(this, "Ye item product list mein nahi hai", Toast.LENGTH_SHORT).show()
        return
    }
    if (q <= 0) {
        Toast.makeText(this, "Quantity theek se likhen", Toast.LENGTH_SHORT).show()
        return
    }

    val chosenUnit = unitSpinner.selectedItem?.toString() ?: product.unit

    // ---- CHANGED (inline edit): when updating an existing line, that line's own
    // qty must not count against itself in the stock check, or editing (e.g.
    // raising the qty) could be wrongly rejected as "stock kam hai".
    val editIndex = editingLineIndex
    val alreadyInCartSmallest = lines.filterIndexed { i, l -> l.barcode == product.barcode && i != editIndex }
        .sumOf { product.toSmallestUnits(it.qty, it.unit) }
    val neededSmallest = product.toSmallestUnits(q, chosenUnit)

    // FIX (fraction control): reject a cart-add whose qty doesn't resolve to a
    // whole smallest-unit for non-fractional items (Piece/Dabbi/Bottle etc.) —
    // catches the bad entry here instead of at save time.
    if (!product.isValidSmallestQty(neededSmallest)) {
        Toast.makeText(this, "Qty ($q $chosenUnit) whole ${product.smallestUnitName()} mein convert nahi hoti", Toast.LENGTH_SHORT).show()
        return
    }

    val availableForThisAdd = product.stock - alreadyInCartSmallest

    if (availableForThisAdd < neededSmallest) {
        Toast.makeText(
            this,
            "Stock kam hai (available: ${formatQty(availableForThisAdd.coerceAtLeast(0.0))} ${product.smallestUnitName()})",
            Toast.LENGTH_SHORT
        ).show()
        return
    }

    val amount = q * price
    val smallestQtyForCost = product.toSmallestUnits(q, chosenUnit)
    val factor = product.smallestUnitFactor()
    val costPerSmallest = if (factor > 0) product.cost / factor else product.cost
    val lineCost = smallestQtyForCost * costPerSmallest

    val newLine = SaleLine(
        barcode = product.barcode,
        itemName = product.name,
        qty = q,
        unit = chosenUnit,
        unitPrice = price,
        cost = lineCost,
        amount = amount,
        mainUnit = product.unit,
        secondaryUnit = product.secondaryUnit,
        secondaryUnitQty = product.secondaryUnitQty,
        tertiaryUnit = product.tertiaryUnit,
        tertiaryUnitQty = product.tertiaryUnitQty
    )
    // ---- ADDED (Billed Items inline edit): editing an existing line updates it
    // in place instead of appending a duplicate.
    if (editIndex != null && editIndex in lines.indices) {
        lines[editIndex] = newLine
    } else {
        lines.add(newLine)
    }
    endLineEdit()
    renderItemsList()
    updateTotals()

    // REMOVED (per request): this used to jump the ScrollView back to the very top
    // after every item add. User wants the screen to stay exactly where it is —
    // wherever they were scrolled to — no matter how many items they add in a row,
    // instead of snapping back to top each time.

    itemName.text.clear(); qty.text.clear(); unitPrice.text.clear()
    selectedProduct = null
    lastMainPrice = 0.0
    qtyIsAmountMode = false
    refreshQtyModeUi()
    unitSpinner.adapter = ArrayAdapter(this, android.R.layout.simple_spinner_dropdown_item, listOf("pcs"))
    conversionInfo.visibility = View.GONE
    unitToggleRow.visibility = View.GONE
    marginWarningText.visibility = View.GONE
    itemLineTotalText.text = "Total Amount: Rs 0"
    itemName.requestFocus()

    if (editInvoice == null) saveDraft()
    if (lines.isNotEmpty() && paidInput.text.toString().isBlank()) {
        paymentSection.background = strokedBg(amber, amberBg, 18)
        paymentSection.postDelayed({ paymentSection.background = strokedBg(border, cardBg, 18) }, 2000)
    }
}

internal fun SaleActivity.renderItemsList() {
    itemsContainer.removeAllViews()
    lines.forEachIndexed { index, line ->
        itemsContainer.addView(LinearLayout(this).apply {
            orientation = LinearLayout.VERTICAL
            setPadding(20, 16, 20, 16)
            background = strokedBg(border, cardBg, 18)
            layoutParams = LinearLayout.LayoutParams(
                LinearLayout.LayoutParams.MATCH_PARENT, LinearLayout.LayoutParams.WRAP_CONTENT
            ).apply { setMargins(0, 0, 0, 10) }
            applyElevation(this, 2f)

            val top = LinearLayout(this@renderItemsList).apply { orientation = LinearLayout.HORIZONTAL; gravity = Gravity.CENTER_VERTICAL }
            top.addView(TextView(this@renderItemsList).apply {
                text = line.itemName; textSize = 15f
                setTextColor(Color.parseColor(textDark))
                setTypeface(typeface, android.graphics.Typeface.BOLD)
                layoutParams = LinearLayout.LayoutParams(0, LinearLayout.LayoutParams.WRAP_CONTENT, 1f)
            })
            top.addView(TextView(this@renderItemsList).apply {
                text = "Rs %.2f".format(line.amount)
                setTextColor(Color.parseColor(teal))
                textSize = 15f
                setTypeface(typeface, android.graphics.Typeface.BOLD)
            })
            addView(top)
            addView(TextView(this@renderItemsList).apply {
                text = "Qty: ${line.qty} ${line.unit}   •   Rate: ${line.unitPrice}"
                textSize = 12.5f
                setTextColor(Color.parseColor(textGray))
                setPadding(0, 6, 0, 0)
            })
            val actionsRow = LinearLayout(this@renderItemsList).apply {
                orientation = LinearLayout.HORIZONTAL
                gravity = Gravity.CENTER_VERTICAL
            }
            // ---- ADDED (Billed Items inline edit): ✎ refills the entry fields with
            // this line so qty/rate/unit can be corrected without delete + re-add —
            // matches the pattern already in PurchaseActivity's billed items list.
            actionsRow.addView(TextView(this@renderItemsList).apply {
                text = "\u270E " + com.grocerypos.v11.util.Loc.t(this@renderItemsList, "Edit", "ترمیم")
                textSize = 12f
                setTextColor(Color.parseColor(teal))
                setTypeface(typeface, android.graphics.Typeface.BOLD)
                setPadding(0, 10, 0, 10)
                setOnClickListener {
                    billedItemsDialog?.dismiss()
                    editLine(index)
                }
            })
            actionsRow.addView(TextView(this@renderItemsList).apply {
                text = "   \u2715 " + com.grocerypos.v11.util.Loc.t(this@renderItemsList, "Remove", "ہٹائیں")
                textSize = 12f
                setTextColor(Color.parseColor(red))
                setTypeface(typeface, android.graphics.Typeface.BOLD)
                setPadding(0, 10, 0, 10)
                setOnClickListener {
                    // Keep an in-progress edit pointed at the right line if a row
                    // earlier in the list gets removed out from under it.
                    val editing = editingLineIndex
                    when {
                        editing == index -> endLineEdit()
                        editing != null && editing > index -> editingLineIndex = editing - 1
                    }
                    lines.removeAt(index)
                    renderItemsList()
                    updateTotals()
                    if (editInvoice == null) saveDraft()
                    if (lines.isEmpty()) billedItemsDialog?.dismiss()
                }
            })
            addView(actionsRow)
        })
    }
    updateBilledItemsTrigger()
}

// ---- ADDED (Billed Items inline edit): populates the item-entry fields from an
// already-billed line so the user can correct a mistake instead of deleting the
// line and retyping it — mirrors PurchaseActivity.editLine().
internal fun SaleActivity.editLine(index: Int) {
    if (index !in lines.indices) return
    val line = lines[index]
    editingLineIndex = index

    val product = products.find { it.barcode == line.barcode } ?: products.find { it.name.equals(line.itemName, ignoreCase = true) }
    if (product != null) {
        selectedProduct = product
        itemName.setText(product.name)
        val unitChoices = mutableListOf(product.unit)
        if (product.secondaryUnit.isNotEmpty()) {
            unitChoices.add(product.secondaryUnit)
            if (product.tertiaryUnit.isNotEmpty() && product.tertiaryUnitQty > 0) {
                unitChoices.add(product.tertiaryUnit)
            }
        }
        unitSpinner.adapter = ArrayAdapter(this, android.R.layout.simple_spinner_dropdown_item, unitChoices)
        val unitIndex = unitChoices.indexOf(line.unit).let { if (it >= 0) it else 0 }
        unitSpinner.setSelection(unitIndex)
        buildUnitChips(unitChoices, unitChoices.getOrElse(unitIndex) { line.unit })
        conversionInfo.text = buildString {
            if (unitChoices.size > 1 && product.secondaryUnitQty > 0) append("1 ${product.unit} = ${product.secondaryUnitQty} ${product.secondaryUnit}")
            if (unitChoices.size > 2 && product.tertiaryUnitQty > 0) { if (isNotEmpty()) append("   •   "); append("1 ${product.secondaryUnit} = ${product.tertiaryUnitQty} ${product.tertiaryUnit}") }
        }
        conversionInfo.visibility = if (conversionInfo.text.isNotEmpty()) View.VISIBLE else View.GONE
    } else {
        // Product no longer in the catalog (renamed/removed) — still let the
        // qty/rate be corrected, just without unit-conversion assist.
        itemName.setText(line.itemName)
    }

    qty.setText(formatQty(line.qty))
    qtyIsAmountMode = false
    refreshQtyModeUi()
    lastMainPrice = 0.0
    suppressPriceWatcher = true
    unitPrice.setText(if (line.unitPrice == line.unitPrice.toLong().toDouble()) line.unitPrice.toLong().toString() else line.unitPrice.toString())
    suppressPriceWatcher = false
    updateItemLineTotal()
    updateMarginWarning()

    addItemButton.text = com.grocerypos.v11.util.Loc.t(this, "UPDATE ITEM", "آئٹم اپ ڈیٹ کریں")
    cancelEditButton.visibility = View.VISIBLE
    scrollView.post { scrollView.smoothScrollTo(0, 0) }
    qty.requestFocus()
    qty.selectAll()
    qty.post {
        val imm = getSystemService(Context.INPUT_METHOD_SERVICE) as? InputMethodManager
        imm?.showSoftInput(qty, InputMethodManager.SHOW_IMPLICIT)
    }
}

internal fun SaleActivity.endLineEdit() {
    editingLineIndex = null
    addItemButton.text = com.grocerypos.v11.util.Loc.t(this, "ADD ITEM", "آئٹم شامل کریں")
    cancelEditButton.visibility = View.GONE
}

internal fun SaleActivity.updateBilledItemsTrigger() {
    if (!isBilledItemsTriggerReady()) return
    val count = lines.size
    val total = lines.sumOf { it.amount }
    billedItemsTrigger.text = com.grocerypos.v11.util.Loc.t(
        this,
        "Billed Items",
        "بل کردہ آئٹمز"
    ) + "  ($count)  ·  Rs %.0f".format(total)
}

// ---- CHANGED (per user feedback: checking Billed Items mid-sale is routine, not
// an "I'm done" signal — a normal sale has several items, and being force-jumped
// to Paid Amount every time you glance at Billed Items meant scrolling all the way
// back up to add the next item. Dismiss now just cleans up and leaves focus where
// it was (usually back on the item-name field), instead of stealing focus/keyboard
// to Paid Amount. The orange highlight on the Payment section (see updateTotals())
// already nudges toward Paid once items exist and it's still blank — that's a
// enough of a reminder without hijacking the cursor. ----
internal fun SaleActivity.openBilledItemsDialog() {
    if (lines.isEmpty()) {
        Toast.makeText(
            this,
            com.grocerypos.v11.util.Loc.t(this, "No items added yet", "ابھی تک کوئی آئٹم شامل نہیں"),
            Toast.LENGTH_SHORT
        ).show()
        return
    }

    (itemsContainer.parent as? ViewGroup)?.removeView(itemsContainer)
    renderItemsList()
    val wrapper = ScrollView(this).apply {
        setPadding(20, 10, 20, 4)
        addView(itemsContainer)
    }

    val dialog = AlertDialog.Builder(this)
        .setTitle(com.grocerypos.v11.util.Loc.t(this, "Billed Items", "بل کردہ آئٹمز"))
        .setView(wrapper)
        .setPositiveButton(com.grocerypos.v11.util.Loc.t(this, "Close", "بند کریں"), null)
        .setOnDismissListener {
            (itemsContainer.parent as? ViewGroup)?.removeView(itemsContainer)
            billedItemsDialog = null
        }
        .create()
    billedItemsDialog = dialog
    dialog.show()
}

// ---- Purchase-style live totals: subtotal/discount/total mirror what the save
// path will actually persist, computed through the same DiscountCalculator. ----
internal fun SaleActivity.recomputeAmounts(): Double {
    val subtotal = lines.sumOf { it.amount }
    val enteredDiscount = discountInput.text.toString().toDoubleOrNull() ?: 0.0
    val totals = DiscountCalculator.compute(subtotal, enteredDiscount, 0.0)
    subtotalText.text = "Rs %.2f".format(subtotal)
    totalText.text = "Rs %.2f".format(totals.total)
    return totals.total
}

// FIX (Paid amount bug): this used to auto-fill Paid = Total whenever Paid was
// blank. That meant Paid silently got stamped with whatever the *first* item's
// total happened to be (since Paid was blank right after the first add), and then
// stayed stuck at that stale number as more items were added — while also fighting
// with the "Paid khali hai - Udhaar jayega" warning below, which assumes Paid
// starts blank. Paid is now left exactly as the user typed it; nothing auto-fills it.
internal fun SaleActivity.updateTotals() {
    recomputeAmounts()
    refreshDue()
    updateBilledItemsTrigger()
}

internal fun SaleActivity.refreshDue() {
    val total = recomputeAmounts()
    val enteredPaid = paidInput.text.toString().toDoubleOrNull() ?: 0.0
    val paidClamped = enteredPaid.coerceIn(0.0, total)
    val due = (total - paidClamped).coerceAtLeast(0.0)
    dueAmountText.text = "Rs %.2f".format(due)
    dueAmountText.setTextColor(Color.parseColor(if (due > 0.009) red else green))
    isCashSale = due <= 0.009
    if (isPaidWarningTextReady()) {
        if (enteredPaid <= 0.009 && total > 0) {
            paidWarningText.visibility = View.VISIBLE
            paidWarningText.text = "Paid khali hai - Rs %.2f Udhaar jayega".format(due)
        } else {
            paidWarningText.visibility = View.GONE
        }
    }
}

internal fun SaleActivity.clearAll() {
    lines.clear()
    endLineEdit()
    renderItemsList()
    customerName.text.clear()
    discountInput.text.clear()
    itemName.text.clear(); qty.text.clear(); unitPrice.text.clear()
    selectedProduct = null
    lastMainPrice = 0.0
    qtyIsAmountMode = false
    refreshQtyModeUi()
    conversionInfo.visibility = View.GONE
    unitToggleRow.visibility = View.GONE
    marginWarningText.visibility = View.GONE
    itemLineTotalText.text = "Total Amount: Rs 0"
    paidInput.text.clear()
    // NEW (Split Payment): a fresh sale always starts back in single-method mode.
    clearSplitPayments()
    updateTotals()
    saleDateMillis = System.currentTimeMillis()
    dateValueText.text = formatDate(saleDateMillis)
    clearDraft()
}

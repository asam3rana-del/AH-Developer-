package com.grocerypos.v11.ui

import android.graphics.Color
import android.graphics.Typeface
import android.graphics.drawable.GradientDrawable
import android.os.Bundle
import android.text.InputType
import android.util.Log
import android.view.Gravity
import android.view.View
import android.widget.EditText
import android.widget.LinearLayout
import android.widget.ScrollView
import android.widget.TextView
import android.widget.Toast
import androidx.lifecycle.lifecycleScope
import com.grocerypos.v11.PosDatabase
import com.grocerypos.v11.Product
import com.grocerypos.v11.R
import com.grocerypos.v11.SyncQueueHelper
import com.grocerypos.v11.util.parseMoneyOrWarn
import com.grocerypos.v11.fromPrimaryUnitRate
import com.grocerypos.v11.toPrimaryUnitRate
import com.grocerypos.v11.ui.components.*
import kotlinx.coroutines.launch

/**
 * Bulk "Missing Rates" review — REPLACES the old "Rate List" button's CSV
 * export/import round trip (Excel/Sheets editing felt heavy just to fill in a
 * few missing prices). Same one-at-a-time stepper pattern as
 * BulkDefaultUnitActivity/BulkTranslateActivity: goes through every product
 * that has no Retail (salePrice) and/or no Wholesale rate entered yet (still
 * 0), shows both fields pre-filled with whatever IS already set, and lets the
 * shopkeeper fill in just what's missing and tap Save & Next — no CSV, no
 * external app, no scrolling through the whole catalog to find the gaps.
 */
class BulkMissingRatesActivity : ThemedActivity() {

    private var bg = "#F3F2FA"
    private var cardBg = "#FFFFFF"
    private var primary = "#4A3AFF"
    private var primaryDark = "#3527D6"
    private var textDark = "#1A1A2E"
    private var textGray = "#8A8A9E"
    private var border = "#E7E5F3"
    private var teal = "#0F9B8E"
    private var tealDark = "#0C7C71"
    private var amber = "#F5A524"

    private fun tintedDrawable(iconRes: Int, tintHex: String, sizeDp: Int = 16): android.graphics.drawable.Drawable? {
        val d = androidx.core.content.ContextCompat.getDrawable(this, iconRes)?.mutate() ?: return null
        d.setTint(Color.parseColor(tintHex))
        val size = (sizeDp * resources.displayMetrics.density).toInt()
        d.setBounds(0, 0, size, size)
        return d
    }

    private fun TextView.setLeadingIcon(iconRes: Int, tintHex: String, sizeDp: Int = 16, paddingDp: Int = 8) {
        setCompoundDrawablesRelative(tintedDrawable(iconRes, tintHex, sizeDp), null, null, null)
        compoundDrawablePadding = (paddingDp * resources.displayMetrics.density).toInt()
    }

    private fun loadThemeColors() {
        val p = com.grocerypos.v11.util.ThemeManager.palette(this)
        bg = p.bg
        cardBg = p.cardWhite
        primary = p.flatPurpleFg
        primaryDark = p.flatPurpleFg
        textDark = p.textDark
        textGray = p.textMuted
        border = p.border
        teal = p.flatTealFg
        tealDark = p.flatTealFg
        amber = p.flatAmberFg
    }

    companion object {
        private const val TAG = "BulkMissingRates"
    }

    private var queue: MutableList<Product> = mutableListOf()
    private var total: Int = 0

    private lateinit var progressText: TextView
    private lateinit var card: LinearLayout
    private lateinit var nameLabel: TextView
    private lateinit var categoryLabel: TextView
    private lateinit var costUnitPanel: LinearLayout
    private lateinit var retailField: EditText
    private lateinit var wholesaleField: EditText
    private lateinit var retailUnitRow: LinearLayout
    private lateinit var wholesaleUnitRow: LinearLayout
    private var retailChosenUnit: String = ""
    private var wholesaleChosenUnit: String = ""
    private lateinit var retailMissingTag: TextView
    private lateinit var wholesaleMissingTag: TextView
    private lateinit var saveNextBtn: TextView
    private lateinit var allDoneText: TextView
    private lateinit var loadingText: TextView

    override fun onCreate(b: Bundle?) {
        super.onCreate(b)
        loadThemeColors()

        val root = LinearLayout(this).apply {
            orientation = LinearLayout.VERTICAL
            setPadding(24, 48, 24, 40)
            setBackgroundColor(Color.parseColor(bg))
        }

        val header = LinearLayout(this).apply {
            orientation = LinearLayout.VERTICAL
            setPadding(26, 22, 26, 22)
            background = GradientDrawable(
                GradientDrawable.Orientation.TL_BR,
                intArrayOf(Color.parseColor(primary), Color.parseColor(primaryDark))
            ).apply { cornerRadius = 22f }
            layoutParams = LinearLayout.LayoutParams(
                LinearLayout.LayoutParams.MATCH_PARENT, LinearLayout.LayoutParams.WRAP_CONTENT
            ).apply { setMargins(0, 0, 0, 20) }
        }
        header.addView(TextView(this).apply {
            text = "Missing Rates"
            setLeadingIcon(R.drawable.ic_document, "#FFFFFF", 18, 8)
            textSize = 19f
            setTextColor(Color.WHITE)
            setTypeface(typeface, Typeface.BOLD)
        })
        header.addView(TextView(this).apply {
            text = "Only products missing a Retail or Wholesale rate show up here. Fill in what's missing and tap Save & Next — one product at a time, no spreadsheet needed."
            textSize = 12f
            setTextColor(Color.parseColor("#DAD5FF"))
            setPadding(0, 6, 0, 0)
        })
        root.addView(header)

        loadingText = TextView(this).apply {
            text = "Loading…"
            textSize = 13.5f
            setTextColor(Color.parseColor(textGray))
            gravity = Gravity.CENTER
            setPadding(0, 40, 0, 40)
        }
        root.addView(loadingText)

        progressText = TextView(this).apply {
            textSize = 12f
            setTextColor(Color.parseColor(textGray))
            setPadding(4, 0, 0, 10)
            visibility = View.GONE
        }
        root.addView(progressText)

        card = LinearLayout(this).apply {
            orientation = LinearLayout.VERTICAL
            setPadding(18, 18, 18, 18)
            background = strokedBg(border, cardBg, 14)
            visibility = View.GONE
        }
        nameLabel = TextView(this).apply {
            textSize = 15.5f
            setTypeface(typeface, Typeface.BOLD)
            setTextColor(Color.parseColor(textDark))
        }
        card.addView(nameLabel)
        categoryLabel = TextView(this).apply {
            textSize = 12f
            setTextColor(Color.parseColor(textGray))
            setPadding(0, 3, 0, 0)
        }
        card.addView(categoryLabel)
        card.addView(spacer(12))

        // NEW: Purchase Rate + unit tiers panel — a product might be bought as
        // one unit (e.g. Ctn) but sold in another (Pcs/Dzn), so knowing the cost
        // AND which unit each rate below applies to is needed to fill Retail/
        // Wholesale correctly, not just the bare product name.
        costUnitPanel = LinearLayout(this).apply {
            orientation = LinearLayout.VERTICAL
            setPadding(16, 12, 16, 12)
            background = strokedBg(border, "#F6F7FB", 12)
        }
        card.addView(costUnitPanel)
        card.addView(spacer(16))

        // ---- Retail Rate field, with a small amber "Missing" tag when it's the
        // reason this product is in the queue (still 0). ----
        val retailLabelRow = LinearLayout(this).apply { orientation = LinearLayout.HORIZONTAL; gravity = Gravity.CENTER_VERTICAL }
        retailLabelRow.addView(TextView(this).apply {
            text = "RETAIL RATE (SALE PRICE)"
            textSize = 11f
            setTypeface(typeface, Typeface.BOLD)
            setTextColor(Color.parseColor(textGray))
            layoutParams = LinearLayout.LayoutParams(0, LinearLayout.LayoutParams.WRAP_CONTENT, 1f)
        })
        retailMissingTag = TextView(this).apply {
            text = "MISSING"
            textSize = 9.5f
            setTypeface(typeface, Typeface.BOLD)
            setTextColor(Color.WHITE)
            background = roundedBg(amber, 8)
            setPadding(12, 4, 12, 4)
            visibility = View.GONE
        }
        retailLabelRow.addView(retailMissingTag)
        card.addView(retailLabelRow)
        card.addView(spacer(6))
        // NEW: unit chips (Ctn / Dzn / pcs etc.) so this rate can be entered in
        // whichever unit is easiest — same conversion math as the Purchase screen.
        retailUnitRow = LinearLayout(this).apply { orientation = LinearLayout.HORIZONTAL; visibility = View.GONE }
        card.addView(retailUnitRow)
        card.addView(spacer(8))
        val retailBox = LinearLayout(this).apply {
            orientation = LinearLayout.HORIZONTAL
            gravity = Gravity.CENTER_VERTICAL
            background = strokedBg(border, "#FAFBFD", 14)
            setPadding(16, 4, 16, 4)
        }
        retailField = EditText(this).apply {
            hint = "0.00"
            setHintTextColor(Color.parseColor(textGray))
            setTextColor(Color.parseColor(textDark))
            background = null
            inputType = InputType.TYPE_CLASS_NUMBER or InputType.TYPE_NUMBER_FLAG_DECIMAL
            textSize = 15f
            layoutParams = LinearLayout.LayoutParams(0, LinearLayout.LayoutParams.WRAP_CONTENT, 1f)
        }
        retailField.setOnFocusChangeListener { _, hasFocus -> if (hasFocus) retailField.post { retailField.selectAll() } }
        retailBox.addView(retailField)
        card.addView(retailBox)
        card.addView(spacer(16))

        // ---- Wholesale Rate field, same shape. ----
        val wholesaleLabelRow = LinearLayout(this).apply { orientation = LinearLayout.HORIZONTAL; gravity = Gravity.CENTER_VERTICAL }
        wholesaleLabelRow.addView(TextView(this).apply {
            text = "WHOLESALE RATE"
            textSize = 11f
            setTypeface(typeface, Typeface.BOLD)
            setTextColor(Color.parseColor(textGray))
            layoutParams = LinearLayout.LayoutParams(0, LinearLayout.LayoutParams.WRAP_CONTENT, 1f)
        })
        wholesaleMissingTag = TextView(this).apply {
            text = "MISSING"
            textSize = 9.5f
            setTypeface(typeface, Typeface.BOLD)
            setTextColor(Color.WHITE)
            background = roundedBg(amber, 8)
            setPadding(12, 4, 12, 4)
            visibility = View.GONE
        }
        wholesaleLabelRow.addView(wholesaleMissingTag)
        card.addView(wholesaleLabelRow)
        card.addView(spacer(6))
        wholesaleUnitRow = LinearLayout(this).apply { orientation = LinearLayout.HORIZONTAL; visibility = View.GONE }
        card.addView(wholesaleUnitRow)
        card.addView(spacer(8))
        val wholesaleBox = LinearLayout(this).apply {
            orientation = LinearLayout.HORIZONTAL
            gravity = Gravity.CENTER_VERTICAL
            background = strokedBg(border, "#FAFBFD", 14)
            setPadding(16, 4, 16, 4)
        }
        wholesaleField = EditText(this).apply {
            hint = "0.00"
            setHintTextColor(Color.parseColor(textGray))
            setTextColor(Color.parseColor(textDark))
            background = null
            inputType = InputType.TYPE_CLASS_NUMBER or InputType.TYPE_NUMBER_FLAG_DECIMAL
            textSize = 15f
            layoutParams = LinearLayout.LayoutParams(0, LinearLayout.LayoutParams.WRAP_CONTENT, 1f)
        }
        wholesaleField.setOnFocusChangeListener { _, hasFocus -> if (hasFocus) wholesaleField.post { wholesaleField.selectAll() } }
        wholesaleBox.addView(wholesaleField)
        card.addView(wholesaleBox)
        card.addView(spacer(18))

        saveNextBtn = TextView(this).apply {
            text = "SAVE & NEXT"
            setLeadingIcon(R.drawable.ic_save, "#FFFFFF", 15, 6)
            textSize = 13.5f
            gravity = Gravity.CENTER
            setTextColor(Color.WHITE)
            setTypeface(typeface, Typeface.BOLD)
            background = GradientDrawable(
                GradientDrawable.Orientation.TL_BR,
                intArrayOf(Color.parseColor(teal), Color.parseColor(tealDark))
            ).apply { cornerRadius = 14f }
            setPadding(0, 22, 0, 22)
            setOnClickListener { saveCurrentAndAdvance() }
        }
        card.addView(saveNextBtn)
        root.addView(card)

        allDoneText = TextView(this).apply {
            text = "Every product has both rates set"
            setCompoundDrawablesRelative(null, null, tintedDrawable(R.drawable.ic_check, teal, 16), null)
            compoundDrawablePadding = (6 * resources.displayMetrics.density).toInt()
            textSize = 14f
            setTextColor(Color.parseColor(textGray))
            gravity = Gravity.CENTER
            setPadding(0, 60, 0, 60)
            visibility = View.GONE
        }
        root.addView(allDoneText)

        setContentView(ScrollView(this).apply {
            setBackgroundColor(Color.parseColor(bg))
            addView(root)
        })

        loadQueue()
    }

    private fun loadQueue() {
        lifecycleScope.launch {
            try {
                val db = PosDatabase.get(this@BulkMissingRatesActivity)
                queue = db.productDao().productsWithMissingRates().toMutableList()
                total = queue.size
                loadingText.visibility = View.GONE
                showCurrent()
            } catch (e: Exception) {
                Log.e(TAG, "loadQueue failed", e)
                loadingText.visibility = View.GONE
                Toast.makeText(
                    this@BulkMissingRatesActivity,
                    "Could not load products: ${e.message ?: "unknown error"}",
                    Toast.LENGTH_LONG
                ).show()
            }
        }
    }

    private fun trimNum(v: Double): String = if (v == 0.0) "" else if (v == v.toLong().toDouble()) v.toLong().toString() else v.toString()

    // Same as trimNum but rounds to 2dp first, since unit-converted rates
    // (e.g. Rs 500/Ctn -> Rs per pcs) rarely land on a clean number.
    private fun formatConvertedRate(v: Double): String {
        if (v <= 0.0) return ""
        val rounded = Math.round(v * 100) / 100.0
        return if (rounded == rounded.toLong().toDouble()) rounded.toLong().toString() else "%.2f".format(rounded)
    }

    private fun unitOptionsFor(product: Product): List<String> {
        val opts = mutableListOf(product.unit)
        if (product.secondaryUnit.isNotBlank()) opts.add(product.secondaryUnit)
        if (product.tertiaryUnit.isNotBlank()) opts.add(product.tertiaryUnit)
        return opts.distinct()
    }

    // Builds the unit chip row for one rate field. Tapping a different unit
    // converts whatever's currently typed (via the product's primary-unit
    // basis) so the number follows the unit instead of just relabeling it —
    // same toPrimaryUnitRate/fromPrimaryUnitRate math the Purchase screen uses.
    private fun buildRateUnitChips(
        row: LinearLayout,
        product: Product,
        field: EditText,
        selectedUnit: String,
        onUnitChanged: (String) -> Unit
    ) {
        row.removeAllViews()
        val options = unitOptionsFor(product)
        if (options.size < 2) { row.visibility = View.GONE; return }
        row.visibility = View.VISIBLE
        options.forEachIndexed { index, unitLabel ->
            val isSelected = unitLabel == selectedUnit
            row.addView(TextView(this).apply {
                text = unitLabel
                textSize = 12f
                setTypeface(typeface, Typeface.BOLD)
                setPadding(24, 10, 24, 10)
                setTextColor(if (isSelected) Color.WHITE else Color.parseColor(teal))
                background = if (isSelected) roundedBg(teal, 30) else strokedBg(teal, cardBg, 30)
                layoutParams = LinearLayout.LayoutParams(
                    LinearLayout.LayoutParams.WRAP_CONTENT, LinearLayout.LayoutParams.WRAP_CONTENT
                ).apply { setMargins(if (index == 0) 0 else 8, 0, 0, 0) }
                setOnClickListener {
                    if (unitLabel == selectedUnit) return@setOnClickListener
                    val typed = field.text.toString().toDoubleOrNull() ?: 0.0
                    if (typed > 0) {
                        val primaryRate = product.toPrimaryUnitRate(typed, selectedUnit)
                        field.setText(formatConvertedRate(product.fromPrimaryUnitRate(primaryRate, unitLabel)))
                        field.post { field.selectAll() }
                    }
                    onUnitChanged(unitLabel)
                }
            })
        }
    }

    private fun refreshRetailUnitChips(product: Product) {
        buildRateUnitChips(retailUnitRow, product, retailField, retailChosenUnit) { newUnit ->
            retailChosenUnit = newUnit
            refreshRetailUnitChips(product)
        }
    }

    private fun refreshWholesaleUnitChips(product: Product) {
        buildRateUnitChips(wholesaleUnitRow, product, wholesaleField, wholesaleChosenUnit) { newUnit ->
            wholesaleChosenUnit = newUnit
            refreshWholesaleUnitChips(product)
        }
    }

    private fun showCurrent() {
        val current = queue.firstOrNull()
        if (current == null) {
            card.visibility = View.GONE
            progressText.visibility = View.GONE
            allDoneText.visibility = View.VISIBLE
            return
        }
        allDoneText.visibility = View.GONE
        card.visibility = View.VISIBLE
        progressText.visibility = View.VISIBLE

        val doneCount = total - queue.size
        progressText.text = "${doneCount + 1} of $total"
        nameLabel.text = current.name
        categoryLabel.text = current.category.ifBlank { "General" }

        // Rates are stored per PRIMARY unit, so every fresh product starts
        // with both chips on the primary unit — matches what's already saved.
        retailChosenUnit = current.unit
        wholesaleChosenUnit = current.unit
        retailField.setText(trimNum(current.salePrice))
        wholesaleField.setText(trimNum(current.wholesalePrice))
        retailMissingTag.visibility = if (current.salePrice <= 0.0) View.VISIBLE else View.GONE
        wholesaleMissingTag.visibility = if (current.wholesalePrice <= 0.0) View.VISIBLE else View.GONE
        refreshRetailUnitChips(current)
        refreshWholesaleUnitChips(current)
        renderCostUnitPanel(current)
    }

    // NEW: shows the Purchase Rate (cost) per primary unit, plus every unit
    // tier this product has (Primary always; Secondary/Tertiary only if set,
    // with their pack-size conversion) — so it's clear which unit the Retail/
    // Wholesale rate above should be priced against before typing a number in.
    private fun costUnitPanel_row(label: String, value: String, bold: Boolean = false) = LinearLayout(this).apply {
        orientation = LinearLayout.HORIZONTAL
        addView(TextView(this@BulkMissingRatesActivity).apply {
            text = label
            textSize = 12.5f
            setTextColor(Color.parseColor(textGray))
            layoutParams = LinearLayout.LayoutParams(0, LinearLayout.LayoutParams.WRAP_CONTENT, 1f)
        })
        addView(TextView(this@BulkMissingRatesActivity).apply {
            text = value
            textSize = 12.5f
            setTypeface(typeface, if (bold) Typeface.BOLD else Typeface.NORMAL)
            setTextColor(Color.parseColor(textDark))
        })
    }

    private fun renderCostUnitPanel(product: Product) {
        costUnitPanel.removeAllViews()
        costUnitPanel.addView(costUnitPanel_row(
            "Purchase Rate (Cost)",
            "Rs %.2f / %s".format(product.cost, product.unit),
            bold = true
        ))
        costUnitPanel.addView(spacer(6))
        costUnitPanel.addView(costUnitPanel_row("Primary Unit", product.unit))
        if (product.secondaryUnit.isNotBlank()) {
            costUnitPanel.addView(spacer(4))
            val qtyText = if (product.secondaryUnitQty > 0)
                " (1 ${product.secondaryUnit} = ${trimNum(product.secondaryUnitQty)} ${product.unit})" else ""
            costUnitPanel.addView(costUnitPanel_row("Secondary Unit", product.secondaryUnit + qtyText))
        }
        if (product.tertiaryUnit.isNotBlank()) {
            costUnitPanel.addView(spacer(4))
            val qtyText = if (product.tertiaryUnitQty > 0)
                " (1 ${product.tertiaryUnit} = ${trimNum(product.tertiaryUnitQty)} ${product.unit})" else ""
            costUnitPanel.addView(costUnitPanel_row("Tertiary Unit", product.tertiaryUnit + qtyText))
        }
        costUnitPanel.addView(spacer(6))
        costUnitPanel.addView(TextView(this).apply {
            text = if (unitOptionsFor(product).size > 1)
                "Tap a unit chip above Retail/Wholesale (e.g. Ctn, Dzn, ${product.unit}) to enter that rate in whichever unit is easiest — it converts automatically."
            else
                "Enter Retail/Wholesale below per ${product.unit} (the primary unit)."
            textSize = 11f
            setTextColor(Color.parseColor(textGray))
            setPadding(0, 4, 0, 0)
        })
    }

    // Saves whatever the shopkeeper entered for this product (both fields —
    // not just the one that was missing, so a typo in an already-set rate can
    // be fixed here too) then advances to the next product in the queue.
    private fun saveCurrentAndAdvance() {
        val current = queue.firstOrNull() ?: return
        val retailTyped = retailField.parseMoneyOrWarn(this, "Retail Price", "خوردہ قیمت") ?: return
        val wholesaleTyped = wholesaleField.parseMoneyOrWarn(this, "Wholesale Price", "ہول سیل قیمت") ?: return
        saveNextBtn.isEnabled = false
        lifecycleScope.launch {
            try {
                // Convert whatever unit each chip is currently set to back down
                // to the PRIMARY unit before saving — salePrice/wholesalePrice
                // are always stored per primary unit (same basis productDao's
                // missing-rate query and every other screen read them against).
                val retail = if (retailTyped > 0) current.toPrimaryUnitRate(retailTyped, retailChosenUnit) else 0.0
                val wholesale = if (wholesaleTyped > 0) current.toPrimaryUnitRate(wholesaleTyped, wholesaleChosenUnit) else 0.0
                val db = PosDatabase.get(this@BulkMissingRatesActivity)
                db.productDao().updateRatesReview(current.barcode, retail, wholesale, System.currentTimeMillis())
                db.productDao().find(current.barcode)?.let { updated ->
                    SyncQueueHelper.enqueueProduct(db, updated)
                }
                SyncQueueHelper.trigger(this@BulkMissingRatesActivity)
                queue.removeAt(0)
                showCurrent()
            } catch (e: Exception) {
                Log.e(TAG, "saveCurrentAndAdvance failed", e)
                Toast.makeText(
                    this@BulkMissingRatesActivity,
                    "Could not save: ${e.message ?: "unknown error"}",
                    Toast.LENGTH_LONG
                ).show()
            } finally {
                saveNextBtn.isEnabled = true
            }
        }
    }
}

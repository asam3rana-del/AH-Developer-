package com.grocerypos.v11.ui

import android.graphics.Color
import android.graphics.Typeface
import android.graphics.drawable.GradientDrawable
import android.os.Bundle
import android.text.Editable
import android.text.TextWatcher
import android.view.Gravity
import android.view.View
import android.widget.EditText
import android.widget.LinearLayout
import android.widget.ScrollView
import android.widget.TextView
import androidx.appcompat.app.AppCompatActivity
import androidx.lifecycle.lifecycleScope
import com.grocerypos.v11.PosDatabase
import com.grocerypos.v11.Product
import com.grocerypos.v11.Purchase
import com.grocerypos.v11.R
import com.grocerypos.v11.Sale
import com.grocerypos.v11.util.Loc
import kotlinx.coroutines.launch
import java.text.SimpleDateFormat
import java.util.Date
import java.util.Locale
import com.grocerypos.v11.ui.components.*

// NEW (user request — "Total sale aur total purchase bhi honi chahiye month year
// wise" + "sale purchase custom search b add kr do, by party, by item, suggestions
// do"): Total Sale vs Total Purchase grouped by month or year, most-recent first,
// with optional search filters by party (customer/supplier) and by item, each with a
// type-ahead suggestion list.
//
// Unfiltered totals reuse SaleDao.allRaw()/PurchaseDao.allRaw(); an item filter reuses
// SaleDao.saleRecordsForItem()/PurchaseDao.purchaseRecordsForItem() (already used for
// per-item history). Grouping happens in Kotlin — no new grouped-SUM queries and no
// schema/migration change for a read-only report.
// NOTE: saleRecordsForItem/purchaseRecordsForItem carry no status column, so an
// item-filtered breakdown can't exclude a returned bill's line the way the unfiltered
// totals (status != 'returned') do — same limitation those queries already have
// wherever else they're used.
private enum class GroupMode { MONTH, YEAR }
private data class PeriodTotals(val key: String, val label: String, val sale: Double, val purchase: Double)
private data class PartyOption(val id: Long, val name: String, val isCustomer: Boolean)
private data class AmountEntry(val createdAt: Long, val amount: Double)

class MonthlySalesPurchaseActivity : AppCompatActivity() {

    private var bg = "#F3F4F9"
    private var cardWhite = "#FFFFFF"
    private var textDark = "#1A1D2E"
    private var textMuted = "#8A8FA3"
    private var green = "#2E7D32"
    private var red = "#C62828"
    private var teal = "#0F9B8E"
    private var border = "#E6E8F0"
    private var headerOverlay = "#22FFFFFF"

    private fun loadThemeColors() {
        val p = com.grocerypos.v11.util.ThemeManager.palette(this)
        bg = p.bg
        cardWhite = p.cardWhite
        textDark = p.textDark
        textMuted = p.textMuted
        green = p.flatTealFg
        red = p.red
        teal = p.flatTealFg
        border = p.border
        headerOverlay = p.headerBadgeOverlay
    }

    private lateinit var listContainer: LinearLayout
    private lateinit var chipMonth: TextView
    private lateinit var chipYear: TextView
    private lateinit var totalSaleText: TextView
    private lateinit var totalPurchaseText: TextView
    private lateinit var totalSaleLabel: TextView
    private lateinit var totalPurchaseLabel: TextView

    private lateinit var partyField: EditText
    private lateinit var partySuggestions: LinearLayout
    private lateinit var itemField: EditText
    private lateinit var itemSuggestions: LinearLayout
    private lateinit var filterStatusText: TextView

    private var mode: GroupMode = GroupMode.MONTH
    private var monthly: List<PeriodTotals> = emptyList()
    private var yearly: List<PeriodTotals> = emptyList()

    private var sales: List<Sale> = emptyList()
    private var purchases: List<Purchase> = emptyList()
    private var allParties: List<PartyOption> = emptyList()
    private var allProducts: List<Product> = emptyList()

    private var selectedParty: PartyOption? = null
    private var selectedItem: Product? = null
    // Stops the EditText's own TextWatcher from re-opening suggestions when we set
    // its text programmatically after a suggestion is tapped / filters are cleared.
    private var suppressPartyWatcher = false
    private var suppressItemWatcher = false

    override fun onCreate(b: Bundle?) {
        super.onCreate(b)
        loadThemeColors()

        val root = LinearLayout(this).apply {
            orientation = LinearLayout.VERTICAL
            setPadding(0, 0, 0, 32)
            setBackgroundColor(Color.parseColor(bg))
        }

        val header = LinearLayout(this).apply {
            orientation = LinearLayout.HORIZONTAL
            gravity = Gravity.CENTER_VERTICAL
            setPadding(26, 40, 22, 26)
            background = gradientBg(teal, teal)
        }
        header.addView(TextView(this).apply {
            text = "\u2039"
            textSize = 22f
            setTextColor(Color.WHITE)
            gravity = Gravity.CENTER
            background = ovalBg(headerOverlay)
            val px = (36 * resources.displayMetrics.density).toInt()
            layoutParams = LinearLayout.LayoutParams(px, px).apply { marginEnd = 14 }
            setOnClickListener { finish() }
        })
        header.addView(iconBadge(R.drawable.ic_chart, "#FFFFFF", bgHex = headerOverlay, sizeDp = 40, iconSizeDp = 18))
        header.addView(spacer(12).apply { layoutParams = LinearLayout.LayoutParams((12 * resources.displayMetrics.density).toInt(), 1) })
        header.addView(TextView(this).apply {
            text = Loc.t(this@MonthlySalesPurchaseActivity, "Sale vs Purchase \u2014 Month/Year", "\u0633\u06CC\u0644 \u0628\u0645\u0642\u0627\u0628\u0644\u06C1 \u062E\u0631\u06CC\u062F\u0627\u0631\u06CC \u2014 \u0645\u06C1\u06CC\u0646\u06C1/\u0633\u0627\u0644")
            textSize = 17f
            setTextColor(Color.WHITE)
            setTypeface(typeface, Typeface.BOLD)
            layoutParams = LinearLayout.LayoutParams(0, LinearLayout.LayoutParams.WRAP_CONTENT, 1f)
        })
        root.addView(header)

        val body = LinearLayout(this).apply {
            orientation = LinearLayout.VERTICAL
            setPadding(24, 18, 24, 0)
        }

        // ---- Monthly / Yearly toggle ----
        val modeRow = LinearLayout(this).apply {
            orientation = LinearLayout.HORIZONTAL
            setPadding(0, 0, 0, 16)
        }
        fun modeChip(label: String, m: GroupMode): TextView = TextView(this).apply {
            text = label
            textSize = 12.5f
            setTypeface(typeface, Typeface.BOLD)
            setPadding(24, 12, 24, 12)
            val lp = LinearLayout.LayoutParams(0, LinearLayout.LayoutParams.WRAP_CONTENT, 1f)
            lp.marginEnd = 8
            layoutParams = lp
            gravity = Gravity.CENTER
            setOnClickListener {
                mode = m
                updateModeChipStyles()
                renderList()
            }
        }
        chipMonth = modeChip(Loc.t(this, "Monthly", "\u0645\u0627\u06C1\u0627\u0646\u06C1"), GroupMode.MONTH)
        chipYear = modeChip(Loc.t(this, "Yearly", "\u0633\u0627\u0644\u0627\u0646\u06C1"), GroupMode.YEAR)
        listOf(chipMonth, chipYear).forEach { modeRow.addView(it) }
        body.addView(modeRow)
        updateModeChipStyles()

        // ---- FILTER: by Party (customer/supplier), with suggestions ----
        body.addView(sectionLabel(Loc.t(this, "Filter by Party (customer/supplier)", "\u067E\u0627\u0631\u0679\u06CC \u06A9\u06D2 \u0645\u0637\u0627\u0628\u0642 (\u06A9\u0633\u0679\u0645\u0631/\u0633\u067E\u0644\u0627\u0626\u06CC\u0631)")))
        val partyBox = searchBoxContainer()
        partyField = EditText(this).apply {
            hint = Loc.t(this@MonthlySalesPurchaseActivity, "Type a customer or supplier name\u2026", "\u06A9\u0633\u0679\u0645\u0631 \u06CC\u0627 \u0633\u067E\u0644\u0627\u0626\u06CC\u0631 \u06A9\u0627 \u0646\u0627\u0645 \u0644\u06A9\u06BE\u06CC\u06BA\u2026")
            background = null
            textSize = 14f
            setSingleLine(true)
            addTextChangedListener(object : TextWatcher {
                override fun beforeTextChanged(s: CharSequence?, start: Int, count: Int, after: Int) {}
                override fun onTextChanged(s: CharSequence?, start: Int, before: Int, count: Int) {}
                override fun afterTextChanged(s: Editable?) {
                    if (suppressPartyWatcher) return
                    // Typing again after a pick means the earlier pick no longer applies.
                    if (selectedParty != null) { selectedParty = null; applyFiltersAndRender() }
                    renderPartySuggestions(s?.toString().orEmpty())
                }
            })
        }
        partyBox.addView(partyField)
        body.addView(partyBox)
        partySuggestions = LinearLayout(this).apply { orientation = LinearLayout.VERTICAL }
        body.addView(partySuggestions)

        body.addView(spacer(10))

        // ---- FILTER: by Item, with suggestions ----
        body.addView(sectionLabel(Loc.t(this, "Filter by Item", "\u0622\u0626\u0679\u0645 \u06A9\u06D2 \u0645\u0637\u0627\u0628\u0642")))
        val itemBox = searchBoxContainer()
        itemField = EditText(this).apply {
            hint = Loc.t(this@MonthlySalesPurchaseActivity, "Type an item name\u2026", "\u0622\u0626\u0679\u0645 \u06A9\u0627 \u0646\u0627\u0645 \u0644\u06A9\u06BE\u06CC\u06BA\u2026")
            background = null
            textSize = 14f
            setSingleLine(true)
            addTextChangedListener(object : TextWatcher {
                override fun beforeTextChanged(s: CharSequence?, start: Int, count: Int, after: Int) {}
                override fun onTextChanged(s: CharSequence?, start: Int, before: Int, count: Int) {}
                override fun afterTextChanged(s: Editable?) {
                    if (suppressItemWatcher) return
                    if (selectedItem != null) { selectedItem = null; applyFiltersAndRender() }
                    renderItemSuggestions(s?.toString().orEmpty())
                }
            })
        }
        itemBox.addView(itemField)
        body.addView(itemBox)
        itemSuggestions = LinearLayout(this).apply { orientation = LinearLayout.VERTICAL }
        body.addView(itemSuggestions)

        filterStatusText = TextView(this).apply {
            textSize = 11.5f
            setTextColor(Color.parseColor(teal))
            setTypeface(typeface, Typeface.BOLD)
            setPadding(4, 10, 4, 4)
            visibility = View.GONE
            setOnClickListener { clearFilters() }
        }
        body.addView(filterStatusText)

        body.addView(spacer(14))

        // ---- Summary (Total Sale / Total Purchase — reflects active filters) ----
        val summaryRow = LinearLayout(this).apply {
            orientation = LinearLayout.HORIZONTAL
            layoutParams = LinearLayout.LayoutParams(LinearLayout.LayoutParams.MATCH_PARENT, LinearLayout.LayoutParams.WRAP_CONTENT).apply { setMargins(0, 0, 0, 20) }
        }
        fun summaryCard(label: String, color: String, last: Boolean): Pair<TextView, TextView> {
            val card = LinearLayout(this).apply {
                orientation = LinearLayout.VERTICAL
                setPadding(20, 16, 20, 16)
                background = roundedBg(cardWhite, 16)
                elevation = 2f
                val lp = LinearLayout.LayoutParams(0, LinearLayout.LayoutParams.WRAP_CONTENT, 1f)
                lp.marginEnd = if (last) 0 else 10
                layoutParams = lp
            }
            val labelText = TextView(this).apply {
                text = label
                textSize = 11f
                setTextColor(Color.parseColor(textMuted))
            }
            card.addView(labelText)
            val valueText = TextView(this).apply {
                text = "Rs 0.00"
                textSize = 15f
                setTypeface(typeface, Typeface.BOLD)
                setTextColor(Color.parseColor(color))
                setPadding(0, 6, 0, 0)
            }
            card.addView(valueText)
            summaryRow.addView(card)
            return Pair(labelText, valueText)
        }
        val saleCard = summaryCard(Loc.t(this, "Total Sale", "\u06A9\u0644 \u0633\u06CC\u0644"), green, false)
        totalSaleLabel = saleCard.first
        totalSaleText = saleCard.second
        val purchaseCard = summaryCard(Loc.t(this, "Total Purchase", "\u06A9\u0644 \u062E\u0631\u06CC\u062F\u0627\u0631\u06CC"), red, true)
        totalPurchaseLabel = purchaseCard.first
        totalPurchaseText = purchaseCard.second
        body.addView(summaryRow)

        listContainer = LinearLayout(this).apply { orientation = LinearLayout.VERTICAL }
        body.addView(listContainer)
        body.addView(spacer(30))

        root.addView(body)
        setContentView(ScrollView(this).apply {
            setBackgroundColor(Color.parseColor(bg))
            addView(root)
        })

        loadData()
    }

    private fun sectionLabel(label: String): TextView = TextView(this).apply {
        text = label
        textSize = 11.5f
        setTypeface(typeface, Typeface.BOLD)
        setTextColor(Color.parseColor(textMuted))
        setPadding(2, 0, 0, 6)
    }

    private fun searchBoxContainer(): LinearLayout = LinearLayout(this).apply {
        orientation = LinearLayout.VERTICAL
        setPadding(18, 4, 18, 4)
        background = strokedBg(border, "#F7F8FC", 10)
        layoutParams = LinearLayout.LayoutParams(LinearLayout.LayoutParams.MATCH_PARENT, LinearLayout.LayoutParams.WRAP_CONTENT)
    }

    private fun suggestionRow(title: String, subtitle: String, onClick: () -> Unit): LinearLayout {
        return LinearLayout(this).apply {
            orientation = LinearLayout.VERTICAL
            setPadding(16, 10, 16, 10)
            background = GradientDrawable().apply {
                setColor(Color.parseColor(cardWhite))
                cornerRadius = 10f
                setStroke(1, Color.parseColor(border))
            }
            layoutParams = LinearLayout.LayoutParams(LinearLayout.LayoutParams.MATCH_PARENT, LinearLayout.LayoutParams.WRAP_CONTENT).apply { setMargins(0, 6, 0, 0) }
            isClickable = true
            setOnClickListener { onClick() }
            addView(TextView(this@MonthlySalesPurchaseActivity).apply {
                text = title
                textSize = 13f
                setTypeface(typeface, Typeface.BOLD)
                setTextColor(Color.parseColor(textDark))
            })
            if (subtitle.isNotEmpty()) {
                addView(TextView(this@MonthlySalesPurchaseActivity).apply {
                    text = subtitle
                    textSize = 10.5f
                    setTextColor(Color.parseColor(textMuted))
                })
            }
        }
    }

    private fun renderPartySuggestions(query: String) {
        partySuggestions.removeAllViews()
        val q = query.trim().lowercase()
        if (q.isEmpty()) return
        allParties.filter { it.name.lowercase().contains(q) }.take(6).forEach { po ->
            partySuggestions.addView(suggestionRow(
                title = po.name,
                subtitle = if (po.isCustomer) Loc.t(this, "Customer", "\u06A9\u0633\u0679\u0645\u0631") else Loc.t(this, "Supplier", "\u0633\u067E\u0644\u0627\u0626\u06CC\u0631")
            ) {
                selectedParty = po
                suppressPartyWatcher = true
                partyField.setText(po.name)
                partyField.setSelection(partyField.text.length)
                suppressPartyWatcher = false
                partySuggestions.removeAllViews()
                applyFiltersAndRender()
            })
        }
    }

    private fun renderItemSuggestions(query: String) {
        itemSuggestions.removeAllViews()
        val q = query.trim().lowercase()
        if (q.isEmpty()) return
        allProducts.filter { it.name.lowercase().contains(q) }.take(6).forEach { prod ->
            itemSuggestions.addView(suggestionRow(title = prod.name, subtitle = prod.barcode) {
                selectedItem = prod
                suppressItemWatcher = true
                itemField.setText(prod.name)
                itemField.setSelection(itemField.text.length)
                suppressItemWatcher = false
                itemSuggestions.removeAllViews()
                applyFiltersAndRender()
            })
        }
    }

    private fun clearFilters() {
        selectedParty = null
        selectedItem = null
        suppressPartyWatcher = true; partyField.setText(""); suppressPartyWatcher = false
        suppressItemWatcher = true; itemField.setText(""); suppressItemWatcher = false
        partySuggestions.removeAllViews()
        itemSuggestions.removeAllViews()
        applyFiltersAndRender()
    }

    private fun updateModeChipStyles() {
        fun style(chip: TextView, m: GroupMode) {
            val active = mode == m
            chip.background = roundedBg(if (active) teal else "#EEF0F7", 20)
            chip.setTextColor(if (active) Color.WHITE else Color.parseColor(textMuted))
        }
        style(chipMonth, GroupMode.MONTH)
        style(chipYear, GroupMode.YEAR)
    }

    private fun loadData() {
        lifecycleScope.launch {
            val db = PosDatabase.get(this@MonthlySalesPurchaseActivity)
            // Same "exclude returned" convention as SaleDao.totalSalesBetween /
            // PurchaseDao.totalBetween, so this matches the totals shown elsewhere.
            sales = db.saleDao().allRaw().filter { it.status != "returned" }
            purchases = db.purchaseDao().allRaw().filter { it.status != "returned" }

            val customers = db.customerDao().allList().map { PartyOption(it.id, it.name, true) }
            val suppliers = db.supplierDao().allList().map { PartyOption(it.id, it.name, false) }
            allParties = (customers + suppliers).sortedBy { it.name.lowercase() }
            allProducts = db.productDao().allList().sortedBy { it.name.lowercase() }

            applyFiltersAndRender()
        }
    }

    // Re-derives sale/purchase entries for the selected party/item (or everything, with
    // neither selected), regroups into monthly/yearly totals and redraws. Runs on load
    // and every time a suggestion is tapped or a filter is cleared.
    private fun applyFiltersAndRender() {
        lifecycleScope.launch {
            val db = PosDatabase.get(this@MonthlySalesPurchaseActivity)
            val party = selectedParty
            val item = selectedItem

            val saleEntries: List<AmountEntry>
            val purchaseEntries: List<AmountEntry>

            if (item != null) {
                // Item filter: use this item's own qty x rate per bill, not the whole
                // bill's total.
                val saleRecords = db.saleDao().saleRecordsForItem(item.barcode)
                val purchaseRecords = db.purchaseDao().purchaseRecordsForItem(item.barcode)
                saleEntries = when {
                    party == null -> saleRecords.map { AmountEntry(it.createdAt, it.qty * it.unitPrice) }
                    party.isCustomer -> saleRecords.filter { it.customerName == party.name }.map { AmountEntry(it.createdAt, it.qty * it.unitPrice) }
                    else -> emptyList() // supplier picked: sale side doesn't apply
                }
                purchaseEntries = when {
                    party == null -> purchaseRecords.map { AmountEntry(it.createdAt, it.qty * it.unitCost) }
                    !party.isCustomer -> purchaseRecords.filter { it.supplierName == party.name }.map { AmountEntry(it.createdAt, it.qty * it.unitCost) }
                    else -> emptyList() // customer picked: purchase side doesn't apply
                }
            } else {
                saleEntries = when {
                    party == null -> sales.map { AmountEntry(it.createdAt, it.total) }
                    party.isCustomer -> sales.filter { it.customerId == party.id }.map { AmountEntry(it.createdAt, it.total) }
                    else -> emptyList()
                }
                purchaseEntries = when {
                    party == null -> purchases.map { AmountEntry(it.createdAt, it.total) }
                    !party.isCustomer -> purchases.filter { it.supplierId == party.id }.map { AmountEntry(it.createdAt, it.total) }
                    else -> emptyList()
                }
            }

            totalSaleText.text = "Rs %.2f".format(saleEntries.sumOf { it.amount })
            totalPurchaseText.text = "Rs %.2f".format(purchaseEntries.sumOf { it.amount })
            totalSaleLabel.text = if (party != null && !party.isCustomer)
                Loc.t(this@MonthlySalesPurchaseActivity, "Total Sale (n/a for supplier)", "\u06A9\u0644 \u0633\u06CC\u0644 (\u0633\u067E\u0644\u0627\u0626\u06CC\u0631 \u067E\u0631 \u0644\u0627\u06AF\u0648 \u0646\u06C1\u06CC\u06BA)")
            else Loc.t(this@MonthlySalesPurchaseActivity, "Total Sale", "\u06A9\u0644 \u0633\u06CC\u0644")
            totalPurchaseLabel.text = if (party != null && party.isCustomer)
                Loc.t(this@MonthlySalesPurchaseActivity, "Total Purchase (n/a for customer)", "\u06A9\u0644 \u062E\u0631\u06CC\u062F\u0627\u0631\u06CC (\u06A9\u0633\u0679\u0645\u0631 \u067E\u0631 \u0644\u0627\u06AF\u0648 \u0646\u06C1\u06CC\u06BA)")
            else Loc.t(this@MonthlySalesPurchaseActivity, "Total Purchase", "\u06A9\u0644 \u062E\u0631\u06CC\u062F\u0627\u0631\u06CC")

            val monthKeyFmt = SimpleDateFormat("yyyy-MM", Locale.getDefault())
            val monthLabelFmt = SimpleDateFormat("MMMM yyyy", Locale.getDefault())
            val yearFmt = SimpleDateFormat("yyyy", Locale.getDefault())

            val saleByMonth = saleEntries.groupBy { monthKeyFmt.format(Date(it.createdAt)) }
            val purchaseByMonth = purchaseEntries.groupBy { monthKeyFmt.format(Date(it.createdAt)) }
            val monthKeys = (saleByMonth.keys + purchaseByMonth.keys).sortedDescending()
            monthly = monthKeys.map { key ->
                val labelDate = monthKeyFmt.parse(key) ?: Date()
                PeriodTotals(
                    key = key,
                    label = monthLabelFmt.format(labelDate),
                    sale = saleByMonth[key]?.sumOf { it.amount } ?: 0.0,
                    purchase = purchaseByMonth[key]?.sumOf { it.amount } ?: 0.0
                )
            }

            val saleByYear = saleEntries.groupBy { yearFmt.format(Date(it.createdAt)) }
            val purchaseByYear = purchaseEntries.groupBy { yearFmt.format(Date(it.createdAt)) }
            val yearKeys = (saleByYear.keys + purchaseByYear.keys).sortedDescending()
            yearly = yearKeys.map { key ->
                PeriodTotals(
                    key = key,
                    label = key,
                    sale = saleByYear[key]?.sumOf { it.amount } ?: 0.0,
                    purchase = purchaseByYear[key]?.sumOf { it.amount } ?: 0.0
                )
            }

            val filterParts = mutableListOf<String>()
            if (party != null) {
                val kind = if (party.isCustomer) Loc.t(this@MonthlySalesPurchaseActivity, "Customer", "\u06A9\u0633\u0679\u0645\u0631") else Loc.t(this@MonthlySalesPurchaseActivity, "Supplier", "\u0633\u067E\u0644\u0627\u0626\u06CC\u0631")
                filterParts.add(kind + ": " + party.name)
            }
            if (item != null) {
                filterParts.add(Loc.t(this@MonthlySalesPurchaseActivity, "Item", "\u0622\u0626\u0679\u0645") + ": " + item.name)
            }
            if (filterParts.isEmpty()) {
                filterStatusText.visibility = View.GONE
            } else {
                filterStatusText.visibility = View.VISIBLE
                filterStatusText.text = filterParts.joinToString("  \u2022  ") + "   \u2715 " + Loc.t(this@MonthlySalesPurchaseActivity, "Clear", "\u06C1\u0679\u0627\u0626\u06CC\u06BA")
            }

            renderList()
        }
    }

    private fun renderList() {
        val rows = if (mode == GroupMode.MONTH) monthly else yearly
        listContainer.removeAllViews()
        if (rows.isEmpty()) {
            listContainer.addView(TextView(this).apply {
                text = Loc.t(this@MonthlySalesPurchaseActivity, "No sales or purchases found", "\u06A9\u0648\u0626\u06CC \u0633\u06CC\u0644 \u06CC\u0627 \u062E\u0631\u06CC\u062F\u0627\u0631\u06CC \u0646\u06C1\u06CC\u06BA \u0645\u0644\u06CC")
                setTextColor(Color.parseColor(textMuted))
                textSize = 13f
                gravity = Gravity.CENTER
                setPadding(0, 40, 0, 40)
            })
            return
        }
        rows.forEach { p -> listContainer.addView(periodRow(p)) }
    }

    private fun periodRow(p: PeriodTotals): LinearLayout {
        val net = p.sale - p.purchase
        return LinearLayout(this).apply {
            orientation = LinearLayout.VERTICAL
            setPadding(18, 14, 18, 14)
            background = GradientDrawable().apply {
                setColor(Color.parseColor(cardWhite))
                cornerRadius = 16f
                setStroke(1, Color.parseColor(border))
            }
            elevation = 2f
            layoutParams = LinearLayout.LayoutParams(LinearLayout.LayoutParams.MATCH_PARENT, LinearLayout.LayoutParams.WRAP_CONTENT).apply { setMargins(0, 0, 0, 10) }

            addView(TextView(this@MonthlySalesPurchaseActivity).apply {
                text = p.label
                textSize = 13.5f
                setTypeface(typeface, Typeface.BOLD)
                setTextColor(Color.parseColor(textDark))
                setPadding(0, 0, 0, 8)
            })

            val amountsRow = LinearLayout(this@MonthlySalesPurchaseActivity).apply {
                orientation = LinearLayout.HORIZONTAL
            }
            fun amountCol(label: String, value: Double, color: String): LinearLayout = LinearLayout(this@MonthlySalesPurchaseActivity).apply {
                orientation = LinearLayout.VERTICAL
                layoutParams = LinearLayout.LayoutParams(0, LinearLayout.LayoutParams.WRAP_CONTENT, 1f)
                addView(TextView(this@MonthlySalesPurchaseActivity).apply {
                    text = label
                    textSize = 10.5f
                    setTextColor(Color.parseColor(textMuted))
                })
                addView(TextView(this@MonthlySalesPurchaseActivity).apply {
                    text = "Rs %.2f".format(value)
                    textSize = 13.5f
                    setTypeface(typeface, Typeface.BOLD)
                    setTextColor(Color.parseColor(color))
                    setPadding(0, 2, 0, 0)
                })
            }
            amountsRow.addView(amountCol(Loc.t(this@MonthlySalesPurchaseActivity, "Total Sale", "\u06A9\u0644 \u0633\u06CC\u0644"), p.sale, green))
            amountsRow.addView(amountCol(Loc.t(this@MonthlySalesPurchaseActivity, "Total Purchase", "\u06A9\u0644 \u062E\u0631\u06CC\u062F\u0627\u0631\u06CC"), p.purchase, red))
            amountsRow.addView(amountCol(Loc.t(this@MonthlySalesPurchaseActivity, "Net", "\u062E\u0627\u0644\u0635"), net, if (net >= 0) green else red))
            addView(amountsRow)
        }
    }
}

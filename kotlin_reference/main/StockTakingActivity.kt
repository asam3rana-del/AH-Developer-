package com.grocerypos.v11.ui

import android.graphics.Color
import android.graphics.Typeface
import android.os.Bundle
import android.text.Editable
import android.text.TextWatcher
import android.view.Gravity
import android.view.View
import android.widget.EditText
import android.widget.LinearLayout
import android.widget.ScrollView
import android.widget.TextView
import android.widget.Toast
import androidx.appcompat.app.AlertDialog
import androidx.appcompat.app.AppCompatActivity
import androidx.lifecycle.lifecycleScope
import androidx.room.withTransaction
import com.grocerypos.v11.Product
import com.grocerypos.v11.PosDatabase
import com.grocerypos.v11.R
import com.grocerypos.v11.SyncQueueHelper
import com.grocerypos.v11.formatStockBreakdown
import com.grocerypos.v11.matchesQuery
import com.grocerypos.v11.smallestUnitFactor
import com.grocerypos.v11.ui.widget.useNumericKeypad
import com.grocerypos.v11.util.Loc
import kotlinx.coroutines.flow.first
import kotlinx.coroutines.launch
import com.grocerypos.v11.ui.components.*
import java.text.SimpleDateFormat
import java.util.Date
import java.util.Locale

/**
 * NEW (10/10 Priority #9 — Stock Taking): a physical inventory count screen —
 * search/scroll the whole catalog, enter what's actually on the shelf next to
 * each item's current system stock, review a variance summary, then commit.
 *
 * Design choices, deliberately kept low-risk against the existing schema:
 *   - No new table/entity/migration. Every variance line is written through the
 *     SAME SyncQueueHelper.increaseProductStock()/decreaseProductStock()
 *     wrappers every other stock change in the app already goes through — type
 *     "STOCK_TAKE", reference = one shared session id for this run. That means
 *     it automatically gets a stock_movements ledger row, a sync delta, AND
 *     already shows up in the existing Stock History screen's per-product
 *     timeline — nothing else needs to change to "know about" a stock take.
 *   - Only products the cashier actually typed a counted quantity for are
 *     touched; leaving a field blank means "didn't count this one this
 *     session" (not "count is zero") — very different things for a POS.
 *   - All the resulting stock/ledger writes for one session commit inside a
 *     single db.withTransaction {}, same atomicity guarantee as
 *     RoomSaleRepository.saveSale/deleteSale.
 *   - One summary Audit entry per session (who, how many items counted, how
 *     many had variance, total value impact) — see Audit/AuditDao in
 *     Database.kt and SyncQueueHelper.logAudit — Priority #10.
 */
class StockTakingActivity : AppCompatActivity() {

    private var bg = "#F4F6F8"
    private var cardBg = "#FFFFFF"
    private var primary = "#534AB7"
    private var green = "#085041"
    private var red = "#D32F4A"
    private var textDark = "#0B2545"
    private var textGray = "#7C8798"
    private var border = "#E3E8EE"

    private fun loadThemeColors() {
        val p = com.grocerypos.v11.util.ThemeManager.palette(this)
        bg = p.bg
        cardBg = p.cardWhite
        primary = p.flatPurpleFg
        green = p.flatTealFg
        red = p.red
        textDark = p.textDark
        textGray = p.textMuted
        border = p.border
    }

    private lateinit var listContainer: androidx.recyclerview.widget.RecyclerView
    private lateinit var searchField: EditText
    private lateinit var summaryText: TextView
    private lateinit var noteInput: EditText

    private var allProducts: List<Product> = emptyList()
    // Stable across rebuilds triggered by search filtering — keyed by barcode so
    // re-filtering (which rebuilds the row Views) never loses what was already
    // typed for a product that's still visible or gets filtered back in later.
    private val enteredCounts = LinkedHashMap<String, String>()

    override fun onCreate(b: Bundle?) {
        super.onCreate(b)
        loadThemeColors()

        val root = LinearLayout(this).apply {
            orientation = LinearLayout.VERTICAL
            setPadding(24, 48, 24, 24)
            setBackgroundColor(Color.parseColor(bg))
        }

        root.addView(premiumHeader(
            R.drawable.ic_list,
            Loc.t(this, "Stock Taking", "اسٹاک گنتی"),
            Loc.t(this, "Physical count vs system stock", "اصل گنتی بمقابلہ سسٹم اسٹاک")
        ))

        summaryText = TextView(this).apply {
            text = Loc.t(this@StockTakingActivity, "0 items counted", "0 آئٹم گنے گئے")
            textSize = 12.5f
            setTextColor(Color.parseColor(textGray))
            setPadding(4, 0, 4, 14)
        }
        root.addView(summaryText)

        val searchBox = LinearLayout(this).apply {
            orientation = LinearLayout.HORIZONTAL
            gravity = Gravity.CENTER_VERTICAL
            setPadding(18, 4, 18, 4)
            background = strokedBg(border, "#FAFAFF", 14)
            layoutParams = LinearLayout.LayoutParams(LinearLayout.LayoutParams.MATCH_PARENT, LinearLayout.LayoutParams.WRAP_CONTENT).apply { setMargins(0, 0, 0, 16) }
        }
        searchField = EditText(this).apply {
            hint = Loc.t(this@StockTakingActivity, "Search item or category…", "آئٹم یا کیٹیگری تلاش کریں…")
            setHintTextColor(Color.parseColor(textGray))
            setTextColor(Color.parseColor(textDark))
            background = null
            textSize = 14.5f
            layoutParams = LinearLayout.LayoutParams(0, LinearLayout.LayoutParams.WRAP_CONTENT, 1f)
        }
        searchBox.addView(searchField)
        root.addView(searchBox)

        listContainer = recyclerListView()
        root.addView(listContainer)
        root.addView(spacer(16))

        noteInput = EditText(this).apply {
            hint = Loc.t(this@StockTakingActivity, "Note for this count (optional)", "اس گنتی کے لیے نوٹ (اختیاری)")
            setPadding(20, 18, 20, 18)
            background = strokedBg(border, "#FAFAFF", 14)
            layoutParams = LinearLayout.LayoutParams(LinearLayout.LayoutParams.MATCH_PARENT, LinearLayout.LayoutParams.WRAP_CONTENT).apply { setMargins(0, 0, 0, 14) }
        }
        root.addView(noteInput)

        val saveButton = TextView(this).apply {
            text = Loc.t(this@StockTakingActivity, "Review & Save Stock Take", "جائزہ لیں اور محفوظ کریں")
            textSize = 15f
            setTypeface(typeface, Typeface.BOLD)
            gravity = Gravity.CENTER
            setTextColor(Color.WHITE)
            background = roundedBg(primary, 14)
            setPadding(0, 30, 0, 30)
            isClickable = true
            isFocusable = true
            layoutParams = LinearLayout.LayoutParams(LinearLayout.LayoutParams.MATCH_PARENT, LinearLayout.LayoutParams.WRAP_CONTENT)
            setOnClickListener { reviewAndSave() }
        }
        root.addView(saveButton)

        val scroll = ScrollView(this).apply {
            setBackgroundColor(Color.parseColor(bg))
            addView(root)
        }
        setContentView(scroll)

        searchField.addTextChangedListener(object : TextWatcher {
            override fun beforeTextChanged(s: CharSequence?, a: Int, b: Int, c: Int) {}
            override fun onTextChanged(s: CharSequence?, a: Int, b: Int, c: Int) {}
            override fun afterTextChanged(s: Editable?) = renderList(s?.toString().orEmpty())
        })

        loadProducts()
    }

    private fun loadProducts() = lifecycleScope.launch {
        val db = PosDatabase.get(this@StockTakingActivity)
        allProducts = db.productDao().all().first().sortedBy { it.name.lowercase() }
        renderList(searchField.text?.toString().orEmpty())
    }

    private fun updateSummary() {
        val counted = enteredCounts.count { it.value.toDoubleOrNull() != null }
        summaryText.text = if (counted == 0)
            Loc.t(this, "0 items counted", "0 آئٹم گنے گئے")
        else
            "$counted " + Loc.t(this, "item(s) counted so far", "آئٹم اب تک گنے گئے")
    }

    private fun renderList(query: String) {
        val q = query.trim().lowercase()
        val filtered = if (q.isEmpty()) allProducts else allProducts.filter { p ->
            p.matchesQuery(q) || p.category.lowercase().contains(q) || p.barcode.lowercase().contains(q)
        }
        val rows = filtered.map { p -> buildRow(p) }
        listContainer.submitRows(rows)
    }

    private fun buildRow(p: Product): View {
        val card = LinearLayout(this).apply {
            orientation = LinearLayout.HORIZONTAL
            gravity = Gravity.CENTER_VERTICAL
            setPadding(20, 16, 20, 16)
            background = strokedBg(border, cardBg, 14)
            layoutParams = LinearLayout.LayoutParams(LinearLayout.LayoutParams.MATCH_PARENT, LinearLayout.LayoutParams.WRAP_CONTENT).apply { setMargins(0, 0, 0, 10) }
        }
        val col = LinearLayout(this).apply { orientation = LinearLayout.VERTICAL; layoutParams = LinearLayout.LayoutParams(0, LinearLayout.LayoutParams.WRAP_CONTENT, 1f) }
        col.addView(TextView(this).apply { text = p.name; textSize = 14f; setTypeface(typeface, Typeface.BOLD); setTextColor(Color.parseColor(textDark)) })
        col.addView(TextView(this).apply {
            text = Loc.t(this@StockTakingActivity, "System: ", "سسٹم: ") + p.formatStockBreakdown()
            textSize = 12f; setTextColor(Color.parseColor(textGray)); setPadding(0, 3, 0, 0)
        })
        card.addView(col)

        val countedField = EditText(this).apply {
            hint = Loc.t(this@StockTakingActivity, "Counted", "گنتی")
            setText(enteredCounts[p.barcode] ?: "")
            textSize = 14f
            gravity = Gravity.CENTER
            setTextColor(Color.parseColor(textDark))
            background = strokedBg(border, "#FAFAFF", 10)
            setPadding(12, 14, 12, 14)
            layoutParams = LinearLayout.LayoutParams((92 * resources.displayMetrics.density).toInt(), LinearLayout.LayoutParams.WRAP_CONTENT)
            useNumericKeypad(allowDecimal = true) {
                enteredCounts[p.barcode] = text.toString()
                updateSummary()
            }
        }
        // Keep the backing map in sync even if the field loses focus without the
        // keypad's "Done" (e.g. user just scrolls away) — same defensive pattern
        // the keypad's onDone already covers for the common case.
        countedField.addTextChangedListener(object : TextWatcher {
            override fun beforeTextChanged(s: CharSequence?, a: Int, b: Int, c: Int) {}
            override fun onTextChanged(s: CharSequence?, a: Int, b: Int, c: Int) {}
            override fun afterTextChanged(s: Editable?) {
                enteredCounts[p.barcode] = s?.toString().orEmpty()
                updateSummary()
            }
        })
        card.addView(countedField)
        return card
    }

    /** A variance line ready to commit: system vs counted, already resolved
     * against the live Product row (not a possibly-stale in-memory copy). */
    private data class Variance(val product: Product, val counted: Double, val delta: Double)

    // FIX (Audit finding — same unit-basis bug as BalanceSheetActivity/StockReportActivity/
    // InventoryInsightsActivity's Damage report): `v.delta` (counted − system stock) is in
    // the product's SMALLEST unit, same basis as Product.stock, while `product.cost` is the
    // rate per PRIMARY unit. `delta * cost` directly overstated the value-impact figure by
    // the unit-conversion factor for any product sold as a carton/dozen/etc — used below in
    // both the confirmation dialog and the audit-log summary.
    private fun valueImpact(v: Variance): Double {
        val factor = v.product.smallestUnitFactor()
        val costPerSmallestUnit = if (factor > 0) v.product.cost / factor else v.product.cost
        return v.delta * costPerSmallestUnit
    }

    private fun reviewAndSave() = lifecycleScope.launch {
        val db = PosDatabase.get(this@StockTakingActivity)
        val latest = db.productDao().all().first().associateBy { it.barcode }

        val variances = mutableListOf<Variance>()
        for ((barcode, text) in enteredCounts) {
            val counted = text.toDoubleOrNull() ?: continue
            val p = latest[barcode] ?: continue
            val delta = counted - p.stock
            if (Math.abs(delta) > 0.0001) variances.add(Variance(p, counted, delta))
        }

        if (enteredCounts.none { it.value.toDoubleOrNull() != null }) {
            Toast.makeText(this@StockTakingActivity, Loc.t(this@StockTakingActivity, "Kam az kam ek item count karen", "کم از کم ایک آئٹم گنیں"), Toast.LENGTH_SHORT).show()
            return@launch
        }

        if (variances.isEmpty()) {
            Toast.makeText(this@StockTakingActivity, Loc.t(this@StockTakingActivity, "Koi farq nahi — sab system stock se match karta hai", "کوئی فرق نہیں — سب سسٹم اسٹاک سے میچ کرتا ہے"), Toast.LENGTH_LONG).show()
            return@launch
        }

        val totalValueImpact = variances.sumOf { valueImpact(it) }
        val summary = buildString {
            append(variances.size).append(" ")
            append(Loc.t(this@StockTakingActivity, "item(s) have a variance:\n\n", "آئٹمز میں فرق ہے:\n\n"))
            variances.take(15).forEach { v ->
                val sign = if (v.delta > 0) "+" else ""
                append("${v.product.name}: ${formatQty(v.product.stock)} \u2192 ${formatQty(v.counted)} ($sign${formatQty(v.delta)})\n")
            }
            if (variances.size > 15) append("… +${variances.size - 15} more\n")
            append("\n").append(Loc.t(this@StockTakingActivity, "Estimated value impact: ", "قدر پر اثر: ")).append("Rs.").append(formatQty(totalValueImpact))
        }

        AlertDialog.Builder(this@StockTakingActivity)
            .setTitle(Loc.t(this@StockTakingActivity, "Confirm Stock Take", "اسٹاک گنتی کی تصدیق کریں"))
            .setMessage(summary)
            .setPositiveButton(Loc.t(this@StockTakingActivity, "Confirm & Save", "تصدیق کریں")) { _, _ -> commit(variances) }
            .setNegativeButton(Loc.t(this@StockTakingActivity, "Cancel", "منسوخ"), null)
            .show()
    }

    private fun commit(variances: List<Variance>) = lifecycleScope.launch {
        val db = PosDatabase.get(this@StockTakingActivity)
        val sessionId = "ST" + SimpleDateFormat("yyMMddHHmmss", Locale.getDefault()).format(Date())
        val note = noteInput.text.toString().trim()

        db.withTransaction {
            variances.forEach { v ->
                val lineNote = "system=${formatQty(v.product.stock)} counted=${formatQty(v.counted)}" + if (note.isNotEmpty()) " — $note" else ""
                if (v.delta > 0) {
                    SyncQueueHelper.increaseProductStock(db, v.product.barcode, v.delta, "STOCK_TAKE", sessionId, note = lineNote)
                } else {
                    SyncQueueHelper.decreaseProductStockForce(db, v.product.barcode, -v.delta, "STOCK_TAKE", sessionId, note = lineNote)
                }
            }
        }
        SyncQueueHelper.trigger(this@StockTakingActivity)

        // 10/10 Priority #10 — one summary audit entry for the whole session.
        SyncQueueHelper.logAudit(
            db, this@StockTakingActivity,
            action = "stock_take",
            reference = sessionId,
            details = "items_with_variance=${variances.size} value_impact=${variances.sumOf { valueImpact(it) }} note=$note"
        )

        Toast.makeText(this@StockTakingActivity, Loc.t(this@StockTakingActivity, "Stock take saved", "اسٹاک گنتی محفوظ ہو گئی"), Toast.LENGTH_SHORT).show()
        enteredCounts.clear()
        noteInput.setText("")
        loadProducts()
    }

    internal fun formatQty(v: Double): String =
        if (v == v.toLong().toDouble()) v.toLong().toString() else String.format(Locale.getDefault(), "%.2f", v)
}

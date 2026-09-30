package com.grocerypos.v11.ui
import com.grocerypos.v11.SyncQueueHelper

import android.graphics.Color
import android.graphics.Typeface
import android.os.Bundle
import android.text.Editable
import android.text.TextWatcher
import android.view.Gravity
import android.view.View
import android.widget.*
import androidx.appcompat.app.AppCompatActivity
import androidx.lifecycle.lifecycleScope
import androidx.recyclerview.widget.RecyclerView
import com.grocerypos.v11.BarcodeStockSum
import com.grocerypos.v11.Product
import com.grocerypos.v11.PosDatabase
import com.grocerypos.v11.formatStockBreakdown
import com.grocerypos.v11.matchesQuery
import com.grocerypos.v11.util.Loc
import kotlinx.coroutines.flow.first
import kotlinx.coroutines.launch
import com.grocerypos.v11.ui.components.*

// NEW (Stock Audit report — auto-detect the "stock doesn't match its own
// history" class of bug): every product's `stock` SHOULD always equal the sum
// of its own stock_movements ledger rows (StockMovementDao.sumByBarcode()) —
// that ledger is the one place every purchase/sale/reversal/adjustment is
// supposed to funnel through (see SyncQueueHelper's increase/decreaseProductStock).
// When the two disagree, `stock` was changed by something OUTSIDE that path —
// a sync race, a pre-fix unit-ladder edit that didn't rescale, a direct DB
// write — exactly the class of bug the انڈے investigation turned up by hand.
// This screen runs that same check for every product at once, so a mismatch
// surfaces on its own instead of only being found when a customer notices
// stock looks wrong for one specific item.
class StockAuditActivity : AppCompatActivity() {

    // ================= PREMIUM PALETTE (shared with Items / Reports / Stock History) =================
    private var bg = "#F3F2FA"
    private var cardBg = "#FFFFFF"
    private var primary = "#4A3AFF"
    private var amber = "#F5A524"
    private var teal = "#0F9B8E"
    private var red = "#E5484D"
    private var textDark = "#1A1A2E"
    private var textGray = "#8A8A9E"
    private var border = "#E7E5F3"
    private var fieldFill = "#FAFAFF"

    private fun loadThemeColors() {
        val p = com.grocerypos.v11.util.ThemeManager.palette(this)
        bg = p.bg
        cardBg = p.cardWhite
        primary = p.flatPurpleFg
        amber = p.flatAmberFg
        teal = p.flatTealFg
        red = p.red
        textDark = p.textDark
        textGray = p.textMuted
        border = p.border
        fieldFill = p.fieldFill
    }

    // A product whose |ledger sum − product.stock| exceeds this many smallest
    // units is flagged. Kept just above float/rounding noise (movements and
    // stock are both Doubles derived from repeated +/- arithmetic), not a
    // "close enough" business tolerance — even a small real drift matters for
    // stock, so this stays tiny.
    private val EPSILON = 0.01

    private data class AuditRow(val product: Product, val ledgerStock: Double, val diff: Double)

    private lateinit var summaryText: TextView
    private lateinit var fixAllButton: TextView
    private lateinit var searchField: EditText
    private lateinit var resultsBox: RecyclerView
    private var allMismatches: List<AuditRow> = emptyList()
    private var totalChecked: Int = 0

    override fun onCreate(b: Bundle?) {
        super.onCreate(b)
        loadThemeColors()

        val root = LinearLayout(this).apply {
            orientation = LinearLayout.VERTICAL
            setPadding(24, 48, 24, 24)
            setBackgroundColor(Color.parseColor(bg))
        }

        root.addView(premiumHeader(
            "\uD83E\uDDFE",
            Loc.t(this, "Stock Audit", "اسٹاک آڈٹ"),
            Loc.t(this, "Stock vs its own purchase/sale history", "اسٹاک بمقابلہ اپنی خریداری/سیل تاریخ")
        ))

        summaryText = TextView(this).apply {
            textSize = 13f
            setTextColor(Color.parseColor(textGray))
            setPadding(4, 0, 4, 8)
        }
        root.addView(summaryText)

        // NEW (Stock Audit — "fix once, proper system going forward"): closes
        // every currently-listed mismatch in one tap by adding an
        // AUDIT_RECONCILE ledger entry per product (see
        // SyncQueueHelper.recordAuditReconciliation's comment) — current live
        // stock is never changed, so this is safe to run even while the shop
        // is actively selling.
        fixAllButton = TextView(this).apply {
            text = Loc.t(this@StockAuditActivity, "\u2699\uFE0F Sab mismatches fix karo", "\u2699\uFE0F تمام فرق درست کریں")
            textSize = 13.5f
            setTypeface(typeface, Typeface.BOLD)
            setTextColor(Color.WHITE)
            gravity = Gravity.CENTER
            setPadding(0, 22, 0, 22)
            background = strokedBg(teal, teal, 14)
            layoutParams = LinearLayout.LayoutParams(LinearLayout.LayoutParams.MATCH_PARENT, LinearLayout.LayoutParams.WRAP_CONTENT)
                .apply { setMargins(0, 0, 0, 14) }
            setOnClickListener { confirmFixAll() }
        }
        root.addView(fixAllButton)

        val searchBox = LinearLayout(this).apply {
            orientation = LinearLayout.HORIZONTAL
            gravity = Gravity.CENTER_VERTICAL
            setPadding(18, 4, 18, 4)
            background = strokedBg(border, fieldFill, 14)
            layoutParams = LinearLayout.LayoutParams(LinearLayout.LayoutParams.MATCH_PARENT, LinearLayout.LayoutParams.WRAP_CONTENT)
                .apply { setMargins(0, 0, 0, 14) }
        }
        searchBox.addView(TextView(this).apply { text = "\uD83D\uDD0D  "; textSize = 14f })
        searchField = EditText(this).apply {
            hint = Loc.t(this@StockAuditActivity, "Search item…", "آئٹم تلاش کریں…")
            setHintTextColor(Color.parseColor(textGray))
            setTextColor(Color.parseColor(textDark))
            background = null
            textSize = 14.5f
            layoutParams = LinearLayout.LayoutParams(0, LinearLayout.LayoutParams.WRAP_CONTENT, 1f)
            addTextChangedListener(object : TextWatcher {
                override fun beforeTextChanged(s: CharSequence?, a: Int, b: Int, c: Int) {}
                override fun onTextChanged(s: CharSequence?, a: Int, b: Int, c: Int) {}
                override fun afterTextChanged(s: Editable?) = renderRows(s?.toString().orEmpty())
            })
        }
        searchBox.addView(searchField)
        root.addView(searchBox)

        resultsBox = recyclerListView()
        root.addView(resultsBox)
        root.addView(spacer(30))

        val scroll = ScrollView(this).apply {
            setBackgroundColor(Color.parseColor(bg))
            addView(root)
        }
        setContentView(scroll)

        loadAudit()
    }

    private fun loadAudit() = lifecycleScope.launch {
        val db = PosDatabase.get(this@StockAuditActivity)
        val products = db.productDao().all().first()
        val ledgerSums: Map<String, Double> = db.stockMovementDao().sumByBarcode()
            .associate { it.barcode to it.total }

        totalChecked = products.size
        allMismatches = products.mapNotNull { p ->
            val ledgerStock = ledgerSums[p.barcode] ?: 0.0
            val diff = p.stock - ledgerStock
            if (Math.abs(diff) > EPSILON) AuditRow(p, ledgerStock, diff) else null
        }.sortedByDescending { Math.abs(it.diff) }

        summaryText.text = if (allMismatches.isEmpty())
            Loc.t(
                this@StockAuditActivity,
                "✓ Sab $totalChecked products ka stock apni history se match karta hai.",
                "✓ تمام $totalChecked پروڈکٹس کا اسٹاک ان کی تاریخ سے میچ کرتا ہے۔"
            )
        else
            Loc.t(
                this@StockAuditActivity,
                "⚠ ${allMismatches.size} of $totalChecked products ka stock apni history se match nahi karta.",
                "⚠ ${allMismatches.size} از $totalChecked پروڈکٹس کا اسٹاک ان کی تاریخ سے میچ نہیں کرتا۔"
            )
        fixAllButton.visibility = if (allMismatches.isEmpty()) View.GONE else View.VISIBLE
        renderRows(searchField.text?.toString().orEmpty())
    }

    // NEW (Stock Audit — "fix once, proper system going forward"): explains what
    // the fix actually does (adds a history entry per product; never changes the
    // stock number cashiers currently see) before touching anything, since this
    // writes data for potentially hundreds of products at once.
    private fun confirmFixAll() {
        if (allMismatches.isEmpty()) return
        android.app.AlertDialog.Builder(this)
            .setTitle(Loc.t(this, "Sab mismatches fix karen?", "تمام فرق درست کریں؟"))
            .setMessage(Loc.t(
                this,
                "${allMismatches.size} products ke liye history mein ek adjustment entry add hogi taake wo apne current stock se match ho jaye. Current stock (jo abhi bik raha hai) BILKUL NAHI badlega.",
                "${allMismatches.size} پروڈکٹس کی تاریخ میں ایک ایڈجسٹمنٹ اندراج شامل ہوگا تاکہ وہ موجودہ اسٹاک سے میچ ہو جائے۔ موجودہ اسٹاک بالکل تبدیل نہیں ہوگا۔"
            ))
            .setPositiveButton(Loc.t(this, "Haan, fix karen", "جی ہاں")) { _, _ -> fixAll() }
            .setNegativeButton(Loc.t(this, "Cancel", "منسوخ"), null)
            .show()
    }

    private fun fixAll() = lifecycleScope.launch {
        val db = PosDatabase.get(this@StockAuditActivity)
        val rows = allMismatches
        fixAllButton.isEnabled = false
        for (row in rows) {
            com.grocerypos.v11.SyncQueueHelper.recordAuditReconciliation(
                db, row.product.barcode, row.diff, "Stock Audit — bulk fix"
            )
        }
        fixAllButton.isEnabled = true
        Toast.makeText(this@StockAuditActivity,
            Loc.t(this@StockAuditActivity, "${rows.size} products fix ho gaye", "${rows.size} پروڈکٹس درست ہو گئیں"),
            Toast.LENGTH_SHORT).show()
        loadAudit()
    }

    // Same reconciliation as fixAll(), for a single product — the tap target on
    // each mismatch card.
    private fun reconcileOne(row: AuditRow) = lifecycleScope.launch {
        val db = PosDatabase.get(this@StockAuditActivity)
        com.grocerypos.v11.SyncQueueHelper.recordAuditReconciliation(
            db, row.product.barcode, row.diff, "Stock Audit — single fix"
        )
        Toast.makeText(this@StockAuditActivity,
            Loc.t(this@StockAuditActivity, "\"${row.product.name}\" fix ho gaya", "\"${row.product.name}\" درست ہو گیا"),
            Toast.LENGTH_SHORT).show()
        loadAudit()
    }

    private fun renderRows(query: String) {
        val q = query.trim().lowercase()
        val filtered = if (q.isEmpty()) allMismatches else allMismatches.filter { it.product.matchesQuery(q) }
        val rows = mutableListOf<View>()
        if (filtered.isEmpty()) {
            rows.add(TextView(this).apply {
                text = if (allMismatches.isEmpty())
                    Loc.t(this@StockAuditActivity, "Koi mismatch nahi mila \uD83C\uDF89", "کوئی فرق نہیں ملا")
                else
                    Loc.t(this@StockAuditActivity, "No matching item", "کوئی آئٹم نہیں ملا")
                setTextColor(Color.parseColor(textGray))
                textSize = 13f
                gravity = Gravity.CENTER
                setPadding(0, 40, 0, 40)
            })
            resultsBox.submitRows(rows)
            return
        }
        filtered.forEach { rows.add(auditCard(it)) }
        resultsBox.submitRows(rows)
    }

    private fun auditCard(row: AuditRow): LinearLayout {
        val p = row.product
        val card = LinearLayout(this).apply {
            orientation = LinearLayout.VERTICAL
            setPadding(20, 16, 20, 16)
            background = strokedBg(red, cardBg, 18)
            layoutParams = LinearLayout.LayoutParams(LinearLayout.LayoutParams.MATCH_PARENT, LinearLayout.LayoutParams.WRAP_CONTENT)
                .apply { setMargins(0, 0, 0, 10) }
            applyElevation(this, 2f)
            setOnClickListener {
                val i = android.content.Intent(this@StockAuditActivity, StockMovementActivity::class.java)
                i.putExtra(StockMovementActivity.EXTRA_MODE, StockMovementActivity.MODE_STOCK)
                startActivity(i)
            }
        }
        card.addView(TextView(this).apply {
            text = p.name
            textSize = 14.5f
            setTypeface(typeface, Typeface.BOLD)
            setTextColor(Color.parseColor(textDark))
        })
        card.addView(spacer(8))

        fun statLine(label: String, valueText: String, valueColor: String) {
            card.addView(LinearLayout(this@StockAuditActivity).apply {
                orientation = LinearLayout.HORIZONTAL
                gravity = Gravity.CENTER_VERTICAL
                setPadding(0, 2, 0, 2)
                addView(TextView(this@StockAuditActivity).apply {
                    text = label
                    textSize = 12f
                    setTextColor(Color.parseColor(textGray))
                    layoutParams = LinearLayout.LayoutParams(0, LinearLayout.LayoutParams.WRAP_CONTENT, 1f)
                })
                addView(TextView(this@StockAuditActivity).apply {
                    text = valueText
                    textSize = 13f
                    setTypeface(typeface, Typeface.BOLD)
                    setTextColor(Color.parseColor(valueColor))
                })
            })
        }

        statLine(
            Loc.t(this, "System stock (app)", "سسٹم اسٹاک"),
            p.formatStockBreakdown(),
            textDark
        )
        statLine(
            Loc.t(this, "Ledger says (history)", "تاریخ کے مطابق"),
            p.copy(stock = row.ledgerStock).formatStockBreakdown(),
            teal
        )
        val sign = if (row.diff > 0) "+" else ""
        statLine(
            Loc.t(this, "Difference", "فرق"),
            "$sign${p.copy(stock = row.diff).formatStockBreakdown()}",
            red
        )

        card.addView(spacer(10))
        card.addView(TextView(this).apply {
            text = Loc.t(this@StockAuditActivity, "\u2713 Isko fix karo", "\u2713 اسے درست کریں")
            textSize = 12.5f
            setTypeface(typeface, Typeface.BOLD)
            setTextColor(Color.parseColor(teal))
            gravity = Gravity.CENTER
            setPadding(0, 12, 0, 12)
            background = strokedBg(teal, "#FFFFFF", 10)
            setOnClickListener {
                // Stop this tap from also bubbling to the card's own
                // click-through-to-history listener above.
                android.app.AlertDialog.Builder(this@StockAuditActivity)
                    .setTitle(Loc.t(this@StockAuditActivity, "\"${p.name}\" fix karen?", "\"${p.name}\" درست کریں؟"))
                    .setMessage(Loc.t(
                        this@StockAuditActivity,
                        "History mein ek adjustment entry add hogi taake ye apne current stock se match ho jaye. Current stock bilkul nahi badlega.",
                        "تاریخ میں ایک ایڈجسٹمنٹ اندراج شامل ہوگا تاکہ یہ موجودہ اسٹاک سے میچ ہو جائے۔ موجودہ اسٹاک بالکل تبدیل نہیں ہوگا۔"
                    ))
                    .setPositiveButton(Loc.t(this@StockAuditActivity, "Haan, fix karen", "جی ہاں")) { _, _ -> reconcileOne(row) }
                    .setNegativeButton(Loc.t(this@StockAuditActivity, "Cancel", "منسوخ"), null)
                    .show()
            }
        })
        return card
    }
}

package com.grocerypos.v11.ui
import com.grocerypos.v11.SyncQueueHelper

import android.graphics.Color
import android.graphics.Typeface
import android.os.Build
import android.os.Bundle
import android.text.Editable
import android.text.TextWatcher
import android.view.Gravity
import android.view.View
import android.view.ViewOutlineProvider
import android.widget.*
import androidx.appcompat.app.AppCompatActivity
import androidx.lifecycle.lifecycleScope
import androidx.recyclerview.widget.RecyclerView
import com.grocerypos.v11.Product
import com.grocerypos.v11.matchesQuery
import com.grocerypos.v11.PosDatabase
import com.grocerypos.v11.StockMovement
import com.grocerypos.v11.util.Loc
import kotlinx.coroutines.flow.first
import kotlinx.coroutines.launch
import java.text.SimpleDateFormat
import java.util.Date
import java.util.Locale
import com.grocerypos.v11.ui.components.*

// ADDED (Inventory Accounting upgrade): single Activity backing BOTH the "Stock
// History" and "Cost History" screens recommended alongside the stock_movements
// table — the data (StockMovementDao) and the product-picker UI are identical
// for both; only which rows get shown (forProduct() = every movement, vs
// costHistoryForProduct() = only the cost-affecting types) and a couple of
// labels differ, controlled by EXTRA_MODE. Two nav entries in ReportsActivity
// launch this same class with different extras rather than duplicating the
// whole screen.
class StockMovementActivity : AppCompatActivity() {

    companion object {
        const val EXTRA_MODE = "mode"
        const val MODE_STOCK = "stock"
        const val MODE_COST = "cost"
    }

    // ================= PREMIUM PALETTE (shared with Items / Categories / Reports) =================
    // Pulled from ThemeManager so this screen respects dark mode. Header was a
    // primary→primaryDark gradient; now flat like the rest of the app.
    private var bg = "#F3F2FA"
    private var cardBg = "#FFFFFF"
    private var primary = "#4A3AFF"
    private var primaryDark = "#4A3AFF"
    private var purple = "#8B5CF6"
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
        primaryDark = p.flatPurpleFg
        purple = p.flatPurpleFg
        amber = p.flatAmberFg
        teal = p.flatTealFg
        red = p.red
        textDark = p.textDark
        textGray = p.textMuted
        border = p.border
        fieldFill = p.fieldFill
    }

    private var mode: String = MODE_STOCK

    private lateinit var headerBox: LinearLayout
    private lateinit var searchField: EditText
    // ---- Item #2 (RecyclerView migration): was a LinearLayout that
    // renderProductList()/renderMovements() addView()'d rows into directly;
    // now a RecyclerView backed by the shared ViewListAdapter (see
    // UiHelpers.kt), so only on-screen rows get inflated instead of the
    // whole list living as permanent child views. ----
    private lateinit var resultsBox: RecyclerView

    private var allProducts: List<Product> = emptyList()
    private var selectedProduct: Product? = null

    private val dateFmt = SimpleDateFormat("dd MMM yyyy, hh:mm a", Locale.getDefault())

    override fun onCreate(b: Bundle?) {
        super.onCreate(b)
        loadThemeColors()
        mode = intent.getStringExtra(EXTRA_MODE) ?: MODE_STOCK

        val root = LinearLayout(this).apply {
            orientation = LinearLayout.VERTICAL
            setPadding(24, 48, 24, 24)
            setBackgroundColor(Color.parseColor(bg))
        }

        headerBox = LinearLayout(this).apply { orientation = LinearLayout.VERTICAL }
        root.addView(headerBox)

        searchField = EditText(this)
        resultsBox = recyclerListView()

        val searchBox = LinearLayout(this).apply {
            orientation = LinearLayout.HORIZONTAL
            gravity = Gravity.CENTER_VERTICAL
            setPadding(18, 4, 18, 4)
            background = strokedBg(border, fieldFill, 14)
            layoutParams = LinearLayout.LayoutParams(LinearLayout.LayoutParams.MATCH_PARENT, LinearLayout.LayoutParams.WRAP_CONTENT).apply { setMargins(0, 0, 0, 14) }
        }
        searchBox.addView(TextView(this).apply { text = "\uD83D\uDD0D  "; textSize = 14f })
        searchField.apply {
            hint = Loc.t(this@StockMovementActivity, "Search item…", "آئٹم تلاش کریں…")
            setHintTextColor(Color.parseColor(textGray))
            setTextColor(Color.parseColor(textDark))
            background = null
            textSize = 14.5f
            layoutParams = LinearLayout.LayoutParams(0, LinearLayout.LayoutParams.WRAP_CONTENT, 1f)
            addTextChangedListener(object : TextWatcher {
                override fun beforeTextChanged(s: CharSequence?, a: Int, b: Int, c: Int) {}
                override fun onTextChanged(s: CharSequence?, a: Int, b: Int, c: Int) {}
                override fun afterTextChanged(s: Editable?) = renderProductList(s?.toString().orEmpty())
            })
        }
        searchBox.addView(searchField)

        root.addView(searchBox)
        root.addView(resultsBox)
        root.addView(spacer(30))

        val scroll = ScrollView(this).apply {
            setBackgroundColor(Color.parseColor(bg))
            addView(root)
        }
        setContentView(scroll)

        renderHeader()
        loadProducts()
    }

    override fun onBackPressed() {
        if (selectedProduct != null) {
            selectedProduct = null
            renderHeader()
            searchField.visibility = View.VISIBLE
            renderProductList(searchField.text?.toString().orEmpty())
        } else {
            super.onBackPressed()
        }
    }

    private fun titleFor(): String = if (mode == MODE_COST)
        Loc.t(this, "Cost History", "لاگت کی تاریخ")
    else
        Loc.t(this, "Stock History", "اسٹاک کی تاریخ")

    private fun subtitleFor(): String = if (selectedProduct != null)
        selectedProduct!!.name
    else if (mode == MODE_COST)
        Loc.t(this, "How a product's cost changed over time", "پروڈکٹ کی لاگت وقت کے ساتھ کیسے بدلی")
    else
        Loc.t(this, "Every purchase, sale & adjustment", "ہر خریداری، سیل اور ایڈجسٹمنٹ")

    private fun renderHeader() {
        headerBox.removeAllViews()
        headerBox.addView(premiumHeader(if (mode == MODE_COST) "\uD83D\uDCC8" else "\uD83D\uDCE6", titleFor(), subtitleFor()) {
            if (selectedProduct != null) { onBackPressed() } else { finish() }
        })
    }

    private fun loadProducts() = lifecycleScope.launch {
        val db = PosDatabase.get(this@StockMovementActivity)
        allProducts = db.productDao().all().first().sortedBy { it.name.lowercase() }
        renderProductList("")
    }

    private fun renderProductList(query: String) {
        if (selectedProduct != null) return
        searchField.visibility = View.VISIBLE
        val q = query.trim().lowercase()
        val filtered = allProducts.filter { p ->
            q.isEmpty() || p.matchesQuery(q) || p.category.lowercase().contains(q) || p.barcode.lowercase().contains(q)
        }
        val rows = mutableListOf<View>()
        if (filtered.isEmpty()) {
            rows.add(TextView(this).apply {
                text = Loc.t(this@StockMovementActivity, "No items found", "کوئی آئٹم نہیں ملا")
                setTextColor(Color.parseColor(textGray))
                textSize = 13f
                gravity = Gravity.CENTER
                setPadding(0, 40, 0, 40)
            })
            resultsBox.submitRows(rows)
            return
        }
        for (p in filtered) {
            val row = LinearLayout(this).apply {
                orientation = LinearLayout.HORIZONTAL
                gravity = Gravity.CENTER_VERTICAL
                setPadding(20, 16, 20, 16)
                background = strokedBg(border, cardBg, 16)
                layoutParams = LinearLayout.LayoutParams(LinearLayout.LayoutParams.MATCH_PARENT, LinearLayout.LayoutParams.WRAP_CONTENT).apply { setMargins(0, 0, 0, 10) }
                applyElevation(this, 2f)
                setOnClickListener {
                    selectedProduct = p
                    renderHeader()
                    searchField.visibility = View.GONE
                    loadMovements(p)
                }
            }
            val nameCol = LinearLayout(this).apply { orientation = LinearLayout.VERTICAL; layoutParams = LinearLayout.LayoutParams(0, LinearLayout.LayoutParams.WRAP_CONTENT, 1f) }
            nameCol.addView(TextView(this).apply { text = p.name; textSize = 14.5f; setTypeface(typeface, Typeface.BOLD); setTextColor(Color.parseColor(textDark)) })
            if (p.category.isNotBlank()) {
                nameCol.addView(TextView(this).apply { text = p.category; textSize = 12f; setTextColor(Color.parseColor(textGray)); setPadding(0, 2, 0, 0) })
            }
            row.addView(nameCol)
            row.addView(TextView(this).apply { text = "\u203A"; textSize = 18f; setTextColor(Color.parseColor(textGray)) })
            rows.add(row)
        }
        resultsBox.submitRows(rows)
    }

    private fun loadMovements(p: Product) = lifecycleScope.launch {
        val db = PosDatabase.get(this@StockMovementActivity)
        val movements = if (mode == MODE_COST) {
            db.stockMovementDao().costHistoryForProduct(p.barcode).first()
        } else {
            db.stockMovementDao().forProduct(p.barcode).first()
        }
        renderMovements(movements)
    }

    private fun renderMovements(movements: List<StockMovement>) {
        val rows = mutableListOf<View>()
        if (movements.isEmpty()) {
            rows.add(TextView(this).apply {
                text = Loc.t(this@StockMovementActivity, "No movements recorded yet", "ابھی تک کوئی ریکارڈ نہیں")
                setTextColor(Color.parseColor(textGray))
                textSize = 13f
                gravity = Gravity.CENTER
                setPadding(0, 40, 0, 40)
            })
            resultsBox.submitRows(rows)
            return
        }
        for (m in movements) {
            rows.add(movementCard(m))
        }
        resultsBox.submitRows(rows)
    }

    private fun typeLabel(type: String): Pair<String, String> = when (type) {
        "PURCHASE" -> Loc.t(this, "PURCHASE", "خریداری") to teal
        "PURCHASE_EDIT" -> Loc.t(this, "PURCHASE EDIT", "خریداری میں ترمیم") to teal
        "PURCHASE_REVERSAL" -> Loc.t(this, "PURCHASE REVERSED", "خریداری واپس") to amber
        "PURCHASE_ITEM_DELETE" -> Loc.t(this, "PURCHASE ITEM DELETED", "خریداری آئٹم حذف") to red
        // FIX (found during Stock Audit review): HistoryActivity/PurchaseHistoryActivity
        // have both written this type (purchase-return-to-supplier) since that feature
        // shipped, but it fell through to the plain fallback below same as STOCK_TAKE.
        "PURCHASE_RETURN" -> Loc.t(this, "PURCHASE RETURNED", "خریداری واپس") to red
        "SALE" -> Loc.t(this, "SALE", "سیل") to primary
        "SALE_EDIT" -> Loc.t(this, "SALE EDIT", "سیل میں ترمیم") to primary
        "SALE_EDIT_REVERSAL" -> Loc.t(this, "SALE EDIT (OLD REVERSED)", "سیل ترمیم (پرانا واپس)") to amber
        "SALE_REVERSAL" -> Loc.t(this, "SALE RETURNED/DELETED", "سیل واپس/حذف") to amber
        "SALE_ITEM_DELETE" -> Loc.t(this, "SALE ITEM DELETED", "سیل آئٹم حذف") to red
        "OPENING_STOCK" -> Loc.t(this, "OPENING STOCK", "ابتدائی اسٹاک") to purple
        // NEW: written by StockAdjustmentActivity via SyncQueueHelper.
        "DAMAGE" -> Loc.t(this, "DAMAGE / LOSS", "نقصان") to red
        "ADJUSTMENT" -> Loc.t(this, "ADJUSTMENT", "ایڈجسٹمنٹ") to amber
        // FIX (found during Stock Audit review): StockTakingActivity has written
        // this type since Stock Taking shipped, but it fell through to the plain
        // `type to textGray` fallback below instead of getting a proper label
        // like every other type here — Stock History showed the raw string
        // "STOCK_TAKE" for every physical-count variance line.
        "STOCK_TAKE" -> Loc.t(this, "STOCK TAKE", "اسٹاک گنتی") to purple
        // NEW (Stock Audit — recordAuditReconciliation): see StockAuditActivity's
        // Reconcile action / SyncQueueHelper.recordAuditReconciliation's comment.
        "AUDIT_RECONCILE" -> Loc.t(this, "AUDIT FIX", "آڈٹ درستگی") to teal
        else -> type to textGray
    }

    private fun movementCard(m: StockMovement): LinearLayout {
        val (label, accent) = typeLabel(m.type)
        val isPositive = m.qty >= 0
        val card = LinearLayout(this).apply {
            orientation = LinearLayout.VERTICAL
            setPadding(20, 16, 20, 16)
            background = strokedBg(border, cardBg, 18)
            layoutParams = LinearLayout.LayoutParams(LinearLayout.LayoutParams.MATCH_PARENT, LinearLayout.LayoutParams.WRAP_CONTENT).apply { setMargins(0, 0, 0, 10) }
            applyElevation(this, 2f)
        }
        val topRow = LinearLayout(this).apply { orientation = LinearLayout.HORIZONTAL; gravity = Gravity.CENTER_VERTICAL }
        topRow.addView(TextView(this).apply {
            text = label
            textSize = 10.5f
            setTypeface(typeface, Typeface.BOLD)
            setTextColor(Color.WHITE)
            background = roundedBg(accent, 8)
            setPadding(14, 5, 14, 5)
        })
        topRow.addView(View(this).apply { layoutParams = LinearLayout.LayoutParams(0, 1, 1f) })
        topRow.addView(TextView(this).apply {
            text = (if (isPositive) "+" else "") + formatQtyValue(m.qty) + (if (m.unit.isNotBlank()) " ${m.unit}" else "")
            textSize = 14.5f
            setTypeface(typeface, Typeface.BOLD)
            setTextColor(Color.parseColor(if (isPositive) teal else red))
        })
        card.addView(topRow)
        card.addView(spacer(8))

        val midRow = LinearLayout(this).apply { orientation = LinearLayout.HORIZONTAL; gravity = Gravity.CENTER_VERTICAL }
        midRow.addView(TextView(this).apply {
            text = Loc.t(this@StockMovementActivity, "Cost: ", "لاگت: ") + "Rs %.2f".format(m.cost)
            textSize = 13f
            setTextColor(Color.parseColor(textDark))
            layoutParams = LinearLayout.LayoutParams(0, LinearLayout.LayoutParams.WRAP_CONTENT, 1f)
        })
        if (m.reference.isNotBlank()) {
            midRow.addView(TextView(this).apply {
                text = "# ${m.reference}"
                textSize = 12f
                setTextColor(Color.parseColor(textGray))
            })
        }
        card.addView(midRow)

        card.addView(TextView(this).apply {
            text = dateFmt.format(Date(m.createdAt))
            textSize = 11.5f
            setTextColor(Color.parseColor(textGray))
            setPadding(0, 6, 0, 0)
        })
        return card
    }

    private fun formatQtyValue(qty: Double): String {
        val rounded = Math.round(qty * 1000.0) / 1000.0
        return if (rounded == Math.floor(rounded)) rounded.toLong().toString() else rounded.toString()
    }

    // ================= PREMIUM HEADER (matches Items/Categories/Reports) =================

    // ================= SHARED UI HELPERS (matches Items/Categories/Reports) =================
    private fun circleIcon(label: String, colorHex: String, sizeDp: Int) = TextView(this).apply {
        text = label
        textSize = 18f
        gravity = Gravity.CENTER
        background = ovalBg(colorHex)
        val px = (sizeDp * resources.displayMetrics.density).toInt()
        layoutParams = android.view.ViewGroup.LayoutParams(px, px)
    }

    // spacer() now comes from the shared UiHelpers.kt (item #24 dedup) — was a
    // byte-identical private copy here before.
}

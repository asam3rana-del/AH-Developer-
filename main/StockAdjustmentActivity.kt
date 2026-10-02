package com.grocerypos.v11.ui

import android.graphics.Color
import android.graphics.Typeface
import android.graphics.drawable.GradientDrawable
import android.os.Build
import android.os.Bundle
import android.text.Editable
import android.text.TextWatcher
import android.view.Gravity
import android.view.View
import android.view.ViewOutlineProvider
import android.widget.*
import androidx.appcompat.app.AlertDialog
import androidx.appcompat.app.AppCompatActivity
import androidx.lifecycle.lifecycleScope
import com.grocerypos.v11.Product
import com.grocerypos.v11.PosDatabase
import com.grocerypos.v11.R
import com.grocerypos.v11.SyncQueueHelper
import com.grocerypos.v11.formatStockBreakdown
import com.grocerypos.v11.matchesQuery
import com.grocerypos.v11.smallestUnitName
import com.grocerypos.v11.util.Loc
import kotlinx.coroutines.flow.first
import kotlinx.coroutines.launch
import com.grocerypos.v11.ui.components.*

// NEW (Stock Adjustment): search a product, then log either a "Damage / Loss" (always
// reduces stock, feeds the Damage/Loss Report in InventoryInsightsActivity) or a plain
// "Correction" (+/-, for recounts and data-entry mistakes) against it. Both write through
// SyncQueueHelper.increaseProductStock()/decreaseProductStock(), which already updates
// Product.stock, writes the stock_movements ledger row, and enqueues the sync delta —
// nothing here touches those tables directly, so behaviour stays identical across devices.
class StockAdjustmentActivity : AppCompatActivity() {

    // Pulled from ThemeManager so this screen respects dark mode. Header was a
    // primary→primaryDark gradient; now flat like the rest of the app.
    private var bg = "#F3F2FA"
    private var cardBg = "#FFFFFF"
    private var primary = "#4A3AFF"
    private var primaryDark = "#4A3AFF"
    private var red = "#E5484D"
    private var amber = "#F5A524"
    private var textDark = "#1A1A2E"
    private var textGray = "#8A8A9E"
    private var border = "#E7E5F3"

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
        red = p.red
        amber = p.flatAmberFg
        textDark = p.textDark
        textGray = p.textMuted
        border = p.border
    }

    private lateinit var resultsBox: LinearLayout
    private lateinit var searchField: EditText
    private var allProducts: List<Product> = emptyList()

    override fun onCreate(b: Bundle?) {
        super.onCreate(b)
        loadThemeColors()

        val root = LinearLayout(this).apply {
            orientation = LinearLayout.VERTICAL
            setPadding(24, 48, 24, 24)
            setBackgroundColor(Color.parseColor(bg))
        }

        root.addView(premiumHeader(R.drawable.ic_wrench,
            Loc.t(this, "Stock Adjustment", "اسٹاک ایڈجسٹمنٹ"),
            Loc.t(this, "Log damage, loss, or a manual correction", "نقصان یا خودکار درستگی درج کریں")))

        val searchBox = LinearLayout(this).apply {
            orientation = LinearLayout.HORIZONTAL
            gravity = Gravity.CENTER_VERTICAL
            setPadding(18, 4, 18, 4)
            background = strokedBg(border, "#FAFAFF", 14)
            layoutParams = LinearLayout.LayoutParams(LinearLayout.LayoutParams.MATCH_PARENT, LinearLayout.LayoutParams.WRAP_CONTENT).apply { setMargins(0, 0, 0, 16) }
        }
        searchBox.addView(ImageView(this).apply {
            setImageDrawable(tintedDrawable(R.drawable.ic_search, textGray, 15))
            layoutParams = LinearLayout.LayoutParams(LinearLayout.LayoutParams.WRAP_CONTENT, LinearLayout.LayoutParams.WRAP_CONTENT).apply { marginEnd = (8 * resources.displayMetrics.density).toInt() }
        })
        searchField = EditText(this).apply {
            hint = Loc.t(this@StockAdjustmentActivity, "Search item or category…", "آئٹم یا کیٹیگری تلاش کریں…")
            setHintTextColor(Color.parseColor(textGray))
            setTextColor(Color.parseColor(textDark))
            background = null
            textSize = 14.5f
            layoutParams = LinearLayout.LayoutParams(0, LinearLayout.LayoutParams.WRAP_CONTENT, 1f)
        }
        searchBox.addView(searchField)
        root.addView(searchBox)

        resultsBox = LinearLayout(this).apply { orientation = LinearLayout.VERTICAL }
        root.addView(resultsBox)
        root.addView(spacer(30))

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
        val db = PosDatabase.get(this@StockAdjustmentActivity)
        allProducts = db.productDao().all().first().sortedBy { it.name.lowercase() }
        renderList(searchField.text?.toString().orEmpty())
    }

    private fun renderList(query: String) {
        resultsBox.removeAllViews()
        val q = query.trim().lowercase()
        // Empty search shows nothing (rather than the whole catalog) — this screen is
        // for a quick, deliberate adjustment, not browsing; StockReportActivity already
        // covers "show me everything".
        if (q.isEmpty()) {
            resultsBox.addView(TextView(this).apply {
                text = Loc.t(this@StockAdjustmentActivity, "Search for an item to adjust its stock", "اسٹاک ایڈجسٹ کرنے کے لیے آئٹم تلاش کریں")
                setTextColor(Color.parseColor(textGray))
                textSize = 13f
                gravity = Gravity.CENTER
                setPadding(0, 40, 0, 0)
            })
            return
        }
        val filtered = allProducts.filter { p ->
            p.matchesQuery(q) || p.category.lowercase().contains(q) || p.barcode.lowercase().contains(q)
        }
        if (filtered.isEmpty()) {
            resultsBox.addView(TextView(this).apply {
                text = Loc.t(this@StockAdjustmentActivity, "No items found", "کوئی آئٹم نہیں ملا")
                setTextColor(Color.parseColor(textGray))
                textSize = 13f
                gravity = Gravity.CENTER
                setPadding(0, 40, 0, 0)
            })
            return
        }
        filtered.forEach { p ->
            val card = LinearLayout(this).apply {
                orientation = LinearLayout.HORIZONTAL
                gravity = Gravity.CENTER_VERTICAL
                setPadding(20, 16, 20, 16)
                background = strokedBg(border, cardBg, 18)
                layoutParams = LinearLayout.LayoutParams(LinearLayout.LayoutParams.MATCH_PARENT, LinearLayout.LayoutParams.WRAP_CONTENT).apply { setMargins(0, 0, 0, 10) }
                applyElevation(this, 2f)
                isClickable = true
                isFocusable = true
                setOnClickListener { showAdjustDialog(p) }
            }
            val col = LinearLayout(this).apply { orientation = LinearLayout.VERTICAL; layoutParams = LinearLayout.LayoutParams(0, LinearLayout.LayoutParams.WRAP_CONTENT, 1f) }
            col.addView(TextView(this).apply { text = p.name; textSize = 14.5f; setTypeface(typeface, Typeface.BOLD); setTextColor(Color.parseColor(textDark)) })
            col.addView(TextView(this).apply { text = Loc.t(this@StockAdjustmentActivity, "Current stock: ", "موجودہ اسٹاک: ") + p.formatStockBreakdown(); textSize = 12.5f; setTextColor(Color.parseColor(textGray)); setPadding(0, 3, 0, 0) })
            card.addView(col)
            card.addView(TextView(this).apply {
                text = "\u203A"
                textSize = 18f
                setTextColor(Color.parseColor(textGray))
            })
            resultsBox.addView(card)
        }
    }

    // ---------------- Adjustment dialog ----------------
    private fun showAdjustDialog(product: Product) {
        var isDamage = true  // default reason; switched by the two toggle chips below
        var isPlus = true    // only meaningful for Correction mode

        val root = LinearLayout(this).apply {
            orientation = LinearLayout.VERTICAL
            setPadding(36, 20, 36, 8)
        }
        root.addView(TextView(this).apply {
            text = Loc.t(this@StockAdjustmentActivity, "Current stock: ", "موجودہ اسٹاک: ") + product.formatStockBreakdown()
            textSize = 13f
            setTextColor(Color.parseColor(textGray))
            setPadding(0, 0, 0, 16)
        })

        // Reason chips: Damage/Loss vs Correction
        val reasonRow = LinearLayout(this).apply { orientation = LinearLayout.HORIZONTAL; layoutParams = LinearLayout.LayoutParams(LinearLayout.LayoutParams.MATCH_PARENT, LinearLayout.LayoutParams.WRAP_CONTENT).apply { setMargins(0, 0, 0, 16) } }
        val damageChip = TextView(this).apply {
            text = Loc.t(this@StockAdjustmentActivity, "Damage / Loss", "نقصان")
            setLeadingIcon(R.drawable.ic_warning, red, 14, 6)
            textSize = 13f; setTypeface(typeface, Typeface.BOLD); setPadding(20, 16, 20, 16)
            layoutParams = LinearLayout.LayoutParams(0, LinearLayout.LayoutParams.WRAP_CONTENT, 1f).apply { marginEnd = 8 }
        }
        val correctionChip = TextView(this).apply {
            text = Loc.t(this@StockAdjustmentActivity, "Correction", "درستگی")
            setLeadingIcon(R.drawable.ic_edit, amber, 14, 6)
            textSize = 13f; setTypeface(typeface, Typeface.BOLD); setPadding(20, 16, 20, 16)
            layoutParams = LinearLayout.LayoutParams(0, LinearLayout.LayoutParams.WRAP_CONTENT, 1f).apply { marginStart = 8 }
        }
        reasonRow.addView(damageChip); reasonRow.addView(correctionChip)
        root.addView(reasonRow)

        // Correction-only +/- toggle (hidden for Damage, since damage is always a loss)
        val signRow = LinearLayout(this).apply { orientation = LinearLayout.HORIZONTAL; visibility = View.GONE; layoutParams = LinearLayout.LayoutParams(LinearLayout.LayoutParams.MATCH_PARENT, LinearLayout.LayoutParams.WRAP_CONTENT).apply { setMargins(0, 0, 0, 16) } }
        val plusChip = TextView(this).apply {
            text = "+ " + Loc.t(this@StockAdjustmentActivity, "Add stock", "اسٹاک بڑھائیں")
            textSize = 13f; setTypeface(typeface, Typeface.BOLD); setPadding(20, 14, 20, 14)
            layoutParams = LinearLayout.LayoutParams(0, LinearLayout.LayoutParams.WRAP_CONTENT, 1f).apply { marginEnd = 8 }
        }
        val minusChip = TextView(this).apply {
            text = "\u2212 " + Loc.t(this@StockAdjustmentActivity, "Remove stock", "اسٹاک کم کریں")
            textSize = 13f; setTypeface(typeface, Typeface.BOLD); setPadding(20, 14, 20, 14)
            layoutParams = LinearLayout.LayoutParams(0, LinearLayout.LayoutParams.WRAP_CONTENT, 1f).apply { marginStart = 8 }
        }
        signRow.addView(plusChip); signRow.addView(minusChip)
        root.addView(signRow)

        val qtyInput = EditText(this).apply {
            hint = Loc.t(this@StockAdjustmentActivity, "Quantity (in ${product.smallestUnitName()})", "مقدار (${product.smallestUnitName()})")
            inputType = android.text.InputType.TYPE_CLASS_NUMBER or android.text.InputType.TYPE_NUMBER_FLAG_DECIMAL
            setPadding(20, 18, 20, 18)
            background = strokedBg(border, "#FAFAFF", 14)
            layoutParams = LinearLayout.LayoutParams(LinearLayout.LayoutParams.MATCH_PARENT, LinearLayout.LayoutParams.WRAP_CONTENT).apply { setMargins(0, 0, 0, 12) }
        }
        root.addView(qtyInput)

        val noteInput = EditText(this).apply {
            hint = Loc.t(this@StockAdjustmentActivity, "Reason / note (optional)", "وجہ / نوٹ (اختیاری)")
            setPadding(20, 18, 20, 18)
            background = strokedBg(border, "#FAFAFF", 14)
            layoutParams = LinearLayout.LayoutParams(LinearLayout.LayoutParams.MATCH_PARENT, LinearLayout.LayoutParams.WRAP_CONTENT)
        }
        root.addView(noteInput)

        fun styleReasonChips() {
            damageChip.background = if (isDamage) roundedBg(red, 14) else strokedBg(border, cardBg, 14)
            damageChip.setTextColor(if (isDamage) Color.WHITE else Color.parseColor(textGray))
            correctionChip.background = if (!isDamage) roundedBg(primary, 14) else strokedBg(border, cardBg, 14)
            correctionChip.setTextColor(if (!isDamage) Color.WHITE else Color.parseColor(textGray))
            signRow.visibility = if (isDamage) View.GONE else View.VISIBLE
        }
        fun styleSignChips() {
            plusChip.background = if (isPlus) roundedBg("#0F9B8E", 14) else strokedBg(border, cardBg, 14)
            plusChip.setTextColor(if (isPlus) Color.WHITE else Color.parseColor(textGray))
            minusChip.background = if (!isPlus) roundedBg(amber, 14) else strokedBg(border, cardBg, 14)
            minusChip.setTextColor(if (!isPlus) Color.WHITE else Color.parseColor(textGray))
        }
        damageChip.setOnClickListener { isDamage = true; styleReasonChips() }
        correctionChip.setOnClickListener { isDamage = false; styleReasonChips() }
        plusChip.setOnClickListener { isPlus = true; styleSignChips() }
        minusChip.setOnClickListener { isPlus = false; styleSignChips() }
        styleReasonChips(); styleSignChips()

        val scroll = ScrollView(this).apply { addView(root) }

        AlertDialog.Builder(this)
            .setTitle(product.name)
            .setView(scroll)
            .setNegativeButton(Loc.t(this, "Cancel", "منسوخ کریں"), null)
            .setPositiveButton(Loc.t(this, "Save", "محفوظ کریں"), null)
            .create()
            .also { dialog ->
                dialog.setOnShowListener {
                    dialog.getButton(AlertDialog.BUTTON_POSITIVE).setOnClickListener {
                        val qty = qtyInput.text.toString().toDoubleOrNull()
                        if (qty == null || qty <= 0.0) {
                            Toast.makeText(this, Loc.t(this, "Enter a valid quantity", "درست مقدار درج کریں"), Toast.LENGTH_SHORT).show()
                            return@setOnClickListener
                        }
                        val note = noteInput.text.toString().trim()
                        saveAdjustment(product, isDamage, if (isDamage) false else isPlus, qty, note)
                        dialog.dismiss()
                    }
                }
            }
            .show()
    }

    private fun saveAdjustment(product: Product, isDamage: Boolean, isPlus: Boolean, qty: Double, note: String) = lifecycleScope.launch {
        val db = PosDatabase.get(this@StockAdjustmentActivity)
        val type = if (isDamage) "DAMAGE" else "ADJUSTMENT"
        if (isDamage || !isPlus) {
            // Damage always reduces stock; Correction "Remove stock" does too.
            val rows = SyncQueueHelper.decreaseProductStock(db, product.barcode, qty, type, unitCost = product.cost, note = note)
            if (rows == 0) {
                Toast.makeText(this@StockAdjustmentActivity,
                    Loc.t(this@StockAdjustmentActivity, "Not enough stock to remove that much", "اتنا اسٹاک کم کرنے کے لیے کافی نہیں ہے"),
                    Toast.LENGTH_LONG).show()
                return@launch
            }
        } else {
            SyncQueueHelper.increaseProductStock(db, product.barcode, qty, type, unitCost = product.cost, note = note)
        }
        Toast.makeText(this@StockAdjustmentActivity,
            Loc.t(this@StockAdjustmentActivity, "Stock updated", "اسٹاک اپ ڈیٹ ہو گیا"),
            Toast.LENGTH_SHORT).show()
        loadProducts()
    }

    // ================= SHARED UI HELPERS (matches StockReportActivity) =================

    // spacer() now comes from the shared UiHelpers.kt (item #24 dedup) — was a
    // byte-identical private copy here before.
}

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
import androidx.appcompat.app.AppCompatActivity
import androidx.lifecycle.lifecycleScope
import com.grocerypos.v11.PosDatabase
import com.grocerypos.v11.Product
import com.grocerypos.v11.R
import com.grocerypos.v11.formatStockBreakdown
import com.grocerypos.v11.matchesQuery
import com.grocerypos.v11.smallestUnitFactor
import com.grocerypos.v11.util.Loc
import kotlinx.coroutines.flow.first
import kotlinx.coroutines.launch
import com.grocerypos.v11.ui.components.*

class StockReportActivity : AppCompatActivity() {

    companion object {
        // ---- ADDED (dashboard "Low Stock" card): when this extra is true, the
        // screen opens with the Low Stock filter already switched on. ----
        const val EXTRA_LOW_STOCK_ONLY = "low_stock_only"
    }

    // ================= PREMIUM PALETTE (shared with Items / Categories / Reports) =================
    // Pulled from ThemeManager so this screen respects dark mode. Header was a
    // primary→primaryDark gradient; now flat like the rest of the app.
    private var bg = "#F3F2FA"
    private var cardBg = "#FFFFFF"
    private var primary = "#1450C7"
    private var primaryDark = "#1450C7"
    private var purple = "#1450C7"
    private var amber = "#F5A524"
    private var teal = "#0F9B8E"
    private var red = "#E5484D"
    private var textDark = "#1A1A2E"
    private var textGray = "#8A8A9E"
    private var border = "#E7E5F3"
    private var fieldFill = "#FAFAFF"
    private var purpleBg = "#E3ECFE"
    private var amberBg = "#FFF3E0"
    private var tealBg = "#E0F2F1"

    private fun loadThemeColors() {
        val p = com.grocerypos.v11.util.ThemeManager.palette(this)
        bg = p.bg
        cardBg = p.cardWhite
        primary = p.flatBlueFg
        primaryDark = p.flatBlueFg
        purple = p.flatBlueFg
        amber = p.flatAmberFg
        teal = p.flatTealFg
        red = p.red
        textDark = p.textDark
        textGray = p.textMuted
        border = p.border
        fieldFill = p.fieldFill
        purpleBg = p.flatBlueBg
        amberBg = p.flatAmberBg
        tealBg = p.flatTealBg
    }

    private lateinit var resultsBox: LinearLayout
    private lateinit var searchField: EditText
    private lateinit var lowStockToggle: TextView
    private lateinit var summaryBox: LinearLayout

    private var allProducts: List<Product> = emptyList()
    private var lowStockOnly = false

    override fun onCreate(b: Bundle?) {
        super.onCreate(b)
        loadThemeColors()
        // ---- ADDED (dashboard "Low Stock" card) ----
        lowStockOnly = intent.getBooleanExtra(EXTRA_LOW_STOCK_ONLY, false)

        val root = LinearLayout(this).apply {
            orientation = LinearLayout.VERTICAL
            setPadding(24, 48, 24, 24)
            setBackgroundColor(Color.parseColor(bg))
        }

        root.addView(premiumHeader(R.drawable.ic_box, Loc.t(this, "Stock Report", "اسٹاک رپورٹ"), Loc.t(this, "Current inventory levels", "موجودہ انوینٹری کی سطح")))

        val searchBox = LinearLayout(this).apply {
            orientation = LinearLayout.HORIZONTAL
            gravity = Gravity.CENTER_VERTICAL
            setPadding(18, 4, 18, 4)
            background = strokedBg(border, fieldFill, 14)
            layoutParams = LinearLayout.LayoutParams(LinearLayout.LayoutParams.MATCH_PARENT, LinearLayout.LayoutParams.WRAP_CONTENT).apply { setMargins(0, 0, 0, 14) }
        }
        searchBox.addView(ImageView(this).apply {
            setImageDrawable(tintedDrawable(R.drawable.ic_search, textGray, 15))
            layoutParams = LinearLayout.LayoutParams(LinearLayout.LayoutParams.WRAP_CONTENT, LinearLayout.LayoutParams.WRAP_CONTENT).apply { marginEnd = (8 * resources.displayMetrics.density).toInt() }
        })
        searchField = EditText(this).apply {
            hint = Loc.t(this@StockReportActivity, "Search item or category…", "آئٹم یا کیٹیگری تلاش کریں…")
            setHintTextColor(Color.parseColor(textGray))
            setTextColor(Color.parseColor(textDark))
            background = null
            textSize = 14.5f
            layoutParams = LinearLayout.LayoutParams(0, LinearLayout.LayoutParams.WRAP_CONTENT, 1f)
        }
        searchBox.addView(searchField)
        root.addView(searchBox)

        lowStockToggle = TextView(this).apply {
            text = Loc.t(this@StockReportActivity, "LOW STOCK ONLY", "صرف کم اسٹاک")
            setLeadingIcon(R.drawable.ic_warning, red, 13, 6)
            textSize = 11.5f
            setTypeface(typeface, Typeface.BOLD)
            setPadding(24, 14, 24, 14)
            layoutParams = LinearLayout.LayoutParams(LinearLayout.LayoutParams.WRAP_CONTENT, LinearLayout.LayoutParams.WRAP_CONTENT).apply { setMargins(0, 0, 0, 16) }
            setOnClickListener {
                lowStockOnly = !lowStockOnly
                refreshToggleStyle()
                renderList(searchField.text?.toString().orEmpty())
            }
        }
        root.addView(lowStockToggle)

        summaryBox = LinearLayout(this).apply { orientation = LinearLayout.VERTICAL }
        root.addView(summaryBox)
        root.addView(spacer(14))

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

        refreshToggleStyle()
        loadReport()
    }

    private fun refreshToggleStyle() {
        if (lowStockOnly) {
            lowStockToggle.background = roundedBg(red, 14)
            lowStockToggle.setTextColor(Color.WHITE)
            lowStockToggle.setLeadingIcon(R.drawable.ic_warning, "#FFFFFF", 13, 6)
        } else {
            lowStockToggle.background = strokedBg(border, cardBg, 14)
            lowStockToggle.setTextColor(Color.parseColor(textGray))
            lowStockToggle.setLeadingIcon(R.drawable.ic_warning, red, 13, 6)
        }
    }

    // FIX: stock value everywhere in this screen is computed per SMALLEST unit
    // (cost/salePrice divided by the product's unit-ladder factor) before being
    // multiplied by `stock`, since `stock` is stored in smallest units while
    // `cost`/`salePrice` are per PRIMARY unit. Multiplying them directly (as the
    // old raw SQL SUM(stock*cost) used to do elsewhere) overstates value by the
    // unit-conversion factor — this is the same fix applied to BalanceSheetActivity.
    private fun costPerSmallestUnit(p: Product): Double {
        val factor = p.smallestUnitFactor()
        return if (factor > 0) p.cost / factor else p.cost
    }
    private fun salePerSmallestUnit(p: Product): Double {
        val factor = p.smallestUnitFactor()
        return if (factor > 0) p.salePrice / factor else p.salePrice
    }

    private fun loadReport() = lifecycleScope.launch {
        val db = PosDatabase.get(this@StockReportActivity)
        allProducts = db.productDao().all().first().sortedBy { it.name.lowercase() }
        renderSummary()
        renderList(searchField.text?.toString().orEmpty())
    }

    private fun renderSummary() {
        summaryBox.removeAllViews()
        val totalProducts = allProducts.size
        val lowStockCount = allProducts.count { it.stock <= it.reorderLevel }
        val totalStockValue = allProducts.sumOf { it.stock * costPerSmallestUnit(it) }
        val totalSaleValue = allProducts.sumOf { it.stock * salePerSmallestUnit(it) }

        summaryBox.addView(summaryCard(R.drawable.ic_box, Loc.t(this, "Total Products", "کل آئٹمز"), "$totalProducts", primary, purpleBg))
        summaryBox.addView(summaryCard(R.drawable.ic_warning, Loc.t(this, "Low Stock Items", "کم اسٹاک آئٹمز"), "$lowStockCount", red, "#FDE8E8"))
        summaryBox.addView(summaryCard(R.drawable.ic_wallet, Loc.t(this, "Stock Value (Cost)", "اسٹاک ویلیو (لاگت)"), "Rs %.2f".format(totalStockValue), amber, amberBg))
        summaryBox.addView(summaryCard(R.drawable.ic_trending, Loc.t(this, "Stock Value (Sale)", "اسٹاک ویلیو (سیل)"), "Rs %.2f".format(totalSaleValue), teal, tealBg))
    }

    private fun renderList(query: String) {
        resultsBox.removeAllViews()
        val q = query.trim().lowercase()
        var filtered = allProducts.filter { p ->
            q.isEmpty() || p.matchesQuery(q) || p.category.lowercase().contains(q) || p.barcode.lowercase().contains(q)
        }
        if (lowStockOnly) filtered = filtered.filter { it.stock <= it.reorderLevel }

        if (filtered.isEmpty()) {
            resultsBox.addView(TextView(this).apply {
                text = Loc.t(this@StockReportActivity, "No items found", "کوئی آئٹم نہیں ملا")
                setTextColor(Color.parseColor(textGray))
                textSize = 13f
                gravity = Gravity.CENTER
                setPadding(0, 40, 0, 0)
            })
            return
        }

        filtered.forEach { p ->
            val isLow = p.stock <= p.reorderLevel
            val stockValue = p.stock * costPerSmallestUnit(p)
            val card = LinearLayout(this).apply {
                orientation = LinearLayout.VERTICAL
                setPadding(20, 16, 20, 16)
                background = strokedBg(border, cardBg, 18)
                layoutParams = LinearLayout.LayoutParams(LinearLayout.LayoutParams.MATCH_PARENT, LinearLayout.LayoutParams.WRAP_CONTENT).apply { setMargins(0, 0, 0, 10) }
                applyElevation(this, 2f)
            }
            val topRow = LinearLayout(this).apply { orientation = LinearLayout.HORIZONTAL; gravity = Gravity.CENTER_VERTICAL }
            val nameCol = LinearLayout(this).apply { orientation = LinearLayout.VERTICAL; layoutParams = LinearLayout.LayoutParams(0, LinearLayout.LayoutParams.WRAP_CONTENT, 1f) }
            nameCol.addView(TextView(this).apply { text = p.name; textSize = 14.5f; setTypeface(typeface, Typeface.BOLD); setTextColor(Color.parseColor(textDark)) })
            if (p.category.isNotBlank()) {
                nameCol.addView(TextView(this).apply { text = p.category; textSize = 12f; setTextColor(Color.parseColor(textGray)); setPadding(0, 2, 0, 0) })
            }
            topRow.addView(nameCol)
            if (isLow) {
                topRow.addView(TextView(this).apply {
                    text = Loc.t(this@StockReportActivity, "LOW", "کم")
                    textSize = 10.5f
                    setTypeface(typeface, Typeface.BOLD)
                    setTextColor(Color.WHITE)
                    background = roundedBg(red, 8)
                    setPadding(14, 5, 14, 5)
                })
            }
            card.addView(topRow)
            card.addView(spacer(8))
            val bottomRow = LinearLayout(this).apply { orientation = LinearLayout.HORIZONTAL; gravity = Gravity.CENTER_VERTICAL }
            bottomRow.addView(TextView(this).apply {
                text = p.formatStockBreakdown()
                textSize = 13f
                setTextColor(Color.parseColor(if (isLow) red else textDark))
                setTypeface(typeface, Typeface.BOLD)
                layoutParams = LinearLayout.LayoutParams(0, LinearLayout.LayoutParams.WRAP_CONTENT, 1f)
            })
            bottomRow.addView(TextView(this).apply {
                text = "Rs %.2f".format(stockValue)
                textSize = 13f
                setTextColor(Color.parseColor(primary))
                setTypeface(typeface, Typeface.BOLD)
            })
            card.addView(bottomRow)
            resultsBox.addView(card)
        }
    }

    // ================= PREMIUM HEADER (matches Items/Categories/Reports) =================

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

    private fun summaryCard(iconRes: Int, label: String, value: String, accentHex: String, tintHex: String): LinearLayout {
        return LinearLayout(this).apply {
            orientation = LinearLayout.HORIZONTAL
            gravity = Gravity.CENTER_VERTICAL
            setPadding(22, 20, 22, 20)
            background = strokedBg(border, cardBg, 18)
            layoutParams = LinearLayout.LayoutParams(LinearLayout.LayoutParams.MATCH_PARENT, LinearLayout.LayoutParams.WRAP_CONTENT).apply { setMargins(0, 0, 0, 10) }
            applyElevation(this, 2f)

            addView(FrameLayout(this@StockReportActivity).apply {
                val size = (40 * resources.displayMetrics.density).toInt()
                layoutParams = LinearLayout.LayoutParams(size, size)
                background = GradientDrawable().apply {
                    shape = GradientDrawable.OVAL
                    setColor(Color.parseColor(tintHex))
                }
                addView(ImageView(this@StockReportActivity).apply {
                    setImageDrawable(tintedDrawable(iconRes, accentHex, 18))
                    layoutParams = FrameLayout.LayoutParams(FrameLayout.LayoutParams.WRAP_CONTENT, FrameLayout.LayoutParams.WRAP_CONTENT).apply { gravity = Gravity.CENTER }
                })
            })

            val textCol = LinearLayout(this@StockReportActivity).apply {
                orientation = LinearLayout.VERTICAL
                setPadding(18, 0, 0, 0)
            }
            textCol.addView(TextView(this@StockReportActivity).apply {
                text = label; setTextColor(Color.parseColor(textGray)); textSize = 12.5f
                setTypeface(typeface, Typeface.BOLD)
            })
            textCol.addView(TextView(this@StockReportActivity).apply {
                text = value; setTextColor(Color.parseColor(accentHex)); textSize = 18f
                setTypeface(typeface, Typeface.BOLD)
                setPadding(0, 4, 0, 0)
            })
            addView(textCol)
        }
    }

    // ================= SHARED UI HELPERS (matches Items/Categories/Reports) =================
    // circleIcon() and spacer() now come from the shared PremiumHeader.kt/UiHelpers.kt
    // (item #24 dedup) — both were byte-identical private copies here before.
}

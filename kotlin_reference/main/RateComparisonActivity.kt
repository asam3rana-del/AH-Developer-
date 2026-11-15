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
import androidx.lifecycle.lifecycleScope
import com.grocerypos.v11.PosDatabase
import com.grocerypos.v11.Product
import com.grocerypos.v11.matchesQuery
import com.grocerypos.v11.toPrimaryUnitRate
import com.grocerypos.v11.util.Loc
import kotlinx.coroutines.flow.collectLatest
import kotlinx.coroutines.flow.first
import kotlinx.coroutines.launch
import java.text.SimpleDateFormat
import java.util.Date
import java.util.Locale
import com.grocerypos.v11.ui.components.*

/**
 * Supplier Rate Comparison.
 *
 * Kai bar ek hi item alag-alag suppliers se, alag-alag rate par milta hai. Yeh
 * screen ek product select karne par us item ki poori purchase history ko
 * supplier-wise group karke dikhati hai — Last Rate, Lowest Rate, Highest Rate,
 * aur kitni dafa liya gaya — taake agli purchase karte waqt best supplier chuna
 * ja sake. Rates product ke PRIMARY unit par normalize hoti hain (toPrimaryUnitRate,
 * wahi central conversion jo PurchaseActivity/ProductActivity use karte hain),
 * isliye agar ek purchase "Ctn" mein aur dusri "pcs" mein hui ho, tab bhi compare
 * fair rehta hai.
 *
 * Launch from anywhere with:
 *   startActivity(Intent(this, RateComparisonActivity::class.java))
 *
 * Suggested entry point: add a navRow() to ReportsActivity's navCard, e.g.
 *   navCard.addView(navRow(
 *       iconRes = R.drawable.ic_chart, accentHex = teal, tintHex = "#E0F2F1",
 *       title = Loc.t(this, "Rate Comparison", "ریٹ کا موازنہ"),
 *       subtitle = Loc.t(this, "Compare supplier rates per item", "فی آئٹم سپلائرز کے ریٹ کا موازنہ")
 *   ) { startActivity(Intent(this@ReportsActivity, RateComparisonActivity::class.java)) })
 */
class RateComparisonActivity : ThemedActivity() {

    private data class SupplierRateRow(
        val supplierId: Long,
        val supplierName: String,
        val lastRate: Double,
        val lastDate: Long,
        val minRate: Double,
        val maxRate: Double,
        val timesPurchased: Int
    )

    // ---- Palette kept consistent with ProductActivity / PurchaseActivity ----
    // Pulled from ThemeManager so this screen respects dark mode.
    private var bg = "#F4F6F8"
    private var cardWhite = "#FFFFFF"
    private var navy = "#0B2545"
    private var navyLight = "#173863"
    private var teal = "#0F9B8E"
    private var red = "#E5484D"
    private var amber = "#F5A524"
    private var textDark = "#0B2545"
    private var textMuted = "#7C8798"
    private var border = "#E3E8EE"
    private var fieldFill = "#FAFBFC"
    private var bestBg = "#E9FBF9"
    private var headerSubtitleColor = "#9FB4CC"
    private var headerBadgeOverlay = "#33FFFFFF"

    private fun loadThemeColors() {
        val p = com.grocerypos.v11.util.ThemeManager.palette(this)
        bg = p.bg
        cardWhite = p.cardWhite
        navy = p.navy
        navyLight = p.navy
        teal = p.teal
        red = p.red
        amber = p.amber
        textDark = p.textDark
        textMuted = p.textMuted
        border = p.border
        fieldFill = p.fieldFill
        bestBg = p.savedHighlightBg
        headerSubtitleColor = p.headerSubtitleColor
        headerBadgeOverlay = p.headerBadgeOverlay
    }

    private lateinit var searchField: EditText
    private lateinit var productListContainer: LinearLayout
    private lateinit var productListSection: LinearLayout
    private lateinit var comparisonSection: LinearLayout
    private lateinit var comparisonHeader: TextView
    private lateinit var comparisonSubHeader: TextView
    private lateinit var comparisonBody: LinearLayout
    private lateinit var changeProductChip: TextView
    private lateinit var loadingText: TextView

    private var allProducts: List<Product> = emptyList()
    private var selectedProduct: Product? = null

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        loadThemeColors()

        val root = LinearLayout(this).apply {
            orientation = LinearLayout.VERTICAL
            setPadding(24, 40, 24, 32)
            setBackgroundColor(Color.parseColor(bg))
        }

        buildHeader(root)
        buildProductPicker(root)
        buildComparisonSection(root)

        setContentView(ScrollView(this).apply {
            setBackgroundColor(Color.parseColor(bg))
            addView(root)
        })

        loadProducts()
    }

    // ---------------- Header ----------------

    private fun buildHeader(root: LinearLayout) {
        val header = LinearLayout(this).apply {
            orientation = LinearLayout.HORIZONTAL
            gravity = Gravity.CENTER_VERTICAL
            setPadding(26, 22, 22, 22)
            background = gradientBg(navy, navyLight, cornerTop = 20, cornerBottom = 20)
            layoutParams = LinearLayout.LayoutParams(-1, -2).apply { setMargins(0, 0, 0, 18) }
            applyElevation(this, 6f)
        }
        header.addView(TextView(this).apply {
            text = "\u2190"
            textSize = 18f
            setTextColor(Color.WHITE)
            setPadding(0, 0, 16, 0)
            setOnClickListener { finish() }
        })
        val col = LinearLayout(this).apply {
            orientation = LinearLayout.VERTICAL
            layoutParams = LinearLayout.LayoutParams(0, -2, 1f)
        }
        col.addView(TextView(this).apply {
            text = "\u2696\uFE0F  " + Loc.t(this@RateComparisonActivity, "Rate Comparison", "ریٹ کا موازنہ")
            textSize = 18.5f
            setTextColor(Color.WHITE)
            setTypeface(typeface, Typeface.BOLD)
        })
        col.addView(TextView(this).apply {
            text = Loc.t(this@RateComparisonActivity, "See which supplier gives the best rate", "دیکھیں کون سا سپلائر بہترین ریٹ دیتا ہے")
            textSize = 11f
            setTextColor(Color.parseColor(headerSubtitleColor))
            setPadding(0, 3, 0, 0)
        })
        header.addView(col)
        root.addView(header)
    }

    // ---------------- Product search / picker ----------------

    private fun buildProductPicker(root: LinearLayout) {
        productListSection = LinearLayout(this).apply { orientation = LinearLayout.VERTICAL }

        val searchBox = LinearLayout(this).apply {
            orientation = LinearLayout.HORIZONTAL
            gravity = Gravity.CENTER_VERTICAL
            setPadding(20, 6, 20, 6)
            background = strokedBg(border, cardWhite, 30)
            layoutParams = LinearLayout.LayoutParams(-1, -2).apply { setMargins(0, 0, 0, 14) }
            applyElevation(this, 1.5f)
        }
        searchBox.addView(TextView(this).apply { text = "\uD83D\uDD0D  "; textSize = 15f })
        searchField = EditText(this).apply {
            hint = Loc.t(this@RateComparisonActivity, "Search a product to compare rates…", "موازنے کے لیے پروڈکٹ تلاش کریں…")
            setHintTextColor(Color.parseColor(textMuted))
            setTextColor(Color.parseColor(textDark))
            background = null
            textSize = 14.5f
            maxLines = 1
            layoutParams = LinearLayout.LayoutParams(0, -2, 1f)
        }
        searchBox.addView(searchField)
        productListSection.addView(searchBox)

        productListContainer = LinearLayout(this).apply { orientation = LinearLayout.VERTICAL }
        productListSection.addView(productListContainer)

        searchField.addTextChangedListener(object : TextWatcher {
            override fun beforeTextChanged(s: CharSequence?, a: Int, b: Int, c: Int) {}
            override fun onTextChanged(s: CharSequence?, a: Int, b: Int, c: Int) {}
            override fun afterTextChanged(s: Editable?) {
                renderProductList(s?.toString().orEmpty())
            }
        })

        root.addView(productListSection)
    }

    private fun renderProductList(query: String) {
        productListContainer.removeAllViews()
        val q = query.trim()
        val filtered = if (q.isEmpty()) {
            emptyList()
        } else {
            allProducts.filter { it.matchesQuery(q) }.take(20)
        }

        if (q.isEmpty()) {
            productListContainer.addView(hintText(
                Loc.t(this, "Start typing a product name above to see its supplier rates.", "اوپر پروڈکٹ کا نام لکھنا شروع کریں تاکہ اس کے سپلائر ریٹ نظر آئیں۔")
            ))
            return
        }

        if (filtered.isEmpty()) {
            productListContainer.addView(hintText(
                Loc.t(this, "No matching products", "کوئی مماثل پروڈکٹ نہیں ملی")
            ))
            return
        }

        filtered.forEach { product ->
            val row = LinearLayout(this).apply {
                orientation = LinearLayout.HORIZONTAL
                gravity = Gravity.CENTER_VERTICAL
                setPadding(18, 16, 18, 16)
                background = strokedBg(border, cardWhite, 14)
                layoutParams = LinearLayout.LayoutParams(-1, -2).apply { setMargins(0, 0, 0, 8) }
                setOnClickListener { selectProduct(product) }
            }
            row.addView(TextView(this).apply {
                text = product.name
                textSize = 14.5f
                setTextColor(Color.parseColor(textDark))
                setTypeface(typeface, Typeface.BOLD)
                layoutParams = LinearLayout.LayoutParams(0, -2, 1f)
            })
            row.addView(TextView(this).apply {
                text = product.category
                textSize = 11f
                setTextColor(Color.parseColor(textMuted))
            })
            productListContainer.addView(row)
        }
    }

    private fun hintText(msg: String) = TextView(this).apply {
        text = msg
        textSize = 12.5f
        setTextColor(Color.parseColor(textMuted))
        setPadding(6, 14, 6, 14)
    }

    // ---------------- Comparison section ----------------

    private fun buildComparisonSection(root: LinearLayout) {
        comparisonSection = LinearLayout(this).apply {
            orientation = LinearLayout.VERTICAL
            visibility = View.GONE
        }

        val topRow = LinearLayout(this).apply { orientation = LinearLayout.HORIZONTAL; gravity = Gravity.CENTER_VERTICAL }
        comparisonHeader = TextView(this).apply {
            textSize = 15.5f
            setTypeface(typeface, Typeface.BOLD)
            setTextColor(Color.parseColor(textDark))
            layoutParams = LinearLayout.LayoutParams(0, -2, 1f)
        }
        topRow.addView(comparisonHeader)
        changeProductChip = TextView(this).apply {
            text = "\u2715  " + Loc.t(this@RateComparisonActivity, "Change", "تبدیل کریں")
            textSize = 12f
            setTextColor(Color.WHITE)
            setTypeface(typeface, Typeface.BOLD)
            background = roundedBg(textMuted, 30)
            setPadding(20, 10, 20, 10)
            setOnClickListener { showProductPicker() }
        }
        topRow.addView(changeProductChip)
        comparisonSection.addView(topRow)

        comparisonSubHeader = TextView(this).apply {
            textSize = 11.5f
            setTextColor(Color.parseColor(textMuted))
            setPadding(2, 6, 0, 14)
        }
        comparisonSection.addView(comparisonSubHeader)

        loadingText = TextView(this).apply {
            text = Loc.t(this@RateComparisonActivity, "Loading purchase history…", "خریداری کی تاریخ لوڈ ہو رہی ہے…")
            textSize = 12.5f
            setTextColor(Color.parseColor(textMuted))
            visibility = View.GONE
        }
        comparisonSection.addView(loadingText)

        comparisonBody = LinearLayout(this).apply { orientation = LinearLayout.VERTICAL }
        comparisonSection.addView(comparisonBody)

        root.addView(comparisonSection)
    }

    private fun selectProduct(product: Product) {
        selectedProduct = product
        hideKeyboard()
        productListSection.visibility = View.GONE
        comparisonSection.visibility = View.VISIBLE
        comparisonHeader.text = "\uD83D\uDCE6  ${product.name}"
        comparisonSubHeader.text = Loc.t(
            this,
            "Rates shown per ${product.unit} (converted from any unit that was purchased)",
            "ریٹ فی ${product.unit} دکھایا گیا ہے (جس بھی یونٹ میں خریدا گیا اسے تبدیل کر کے)"
        )
        comparisonBody.removeAllViews()
        loadingText.visibility = View.VISIBLE
        loadComparison(product)
    }

    private fun showProductPicker() {
        selectedProduct = null
        comparisonSection.visibility = View.GONE
        productListSection.visibility = View.VISIBLE
        searchField.requestFocus()
    }

    private fun hideKeyboard() {
        currentFocus?.let { focused ->
            val imm = getSystemService(INPUT_METHOD_SERVICE) as? android.view.inputmethod.InputMethodManager
            imm?.hideSoftInputFromWindow(focused.windowToken, 0)
            focused.clearFocus()
        }
    }

    // ---------------- Data loading ----------------

    private fun loadProducts() {
        lifecycleScope.launch {
            PosDatabase.get(this@RateComparisonActivity).productDao().all().collectLatest { list ->
                allProducts = list
            }
        }
    }

    /**
     * Har purchase bill ke items scan karke us barcode ke matches nikalta hai, phir
     * unhe supplierId ke against group karta hai. Rate ko product ke primary unit
     * par normalize kiya jata hai (toPrimaryUnitRate) taake mukhtalif units mein
     * hui purchases bhi fairly compare ho sakein.
     */
    private fun loadComparison(product: Product) {
        lifecycleScope.launch {
            try {
                val db = PosDatabase.get(this@RateComparisonActivity)
                val suppliers = db.supplierDao().all().first()

                // supplierId -> list of (normalized rate, purchase date)
                val bySupplier = mutableMapOf<Long, MutableList<Pair<Double, Long>>>()

                // NOTE: purchaseDao().allPurchases() returns PurchaseWithSupplier (a join
                // read-model with supplierName, not supplierId), so it can't be used here.
                // Instead we go supplier-by-supplier via purchasesBySupplier(), which returns
                // real Purchase entities that do carry supplierId.
                for (supplier in suppliers) {
                    val purchases = db.purchaseDao().purchasesBySupplier(supplier.id)
                    for (purchase in purchases) {
                        val items = db.purchaseDao().itemsForBill(purchase.billNo)
                        val matches = items.filter { it.barcode == product.barcode }
                        if (matches.isEmpty()) continue
                        val bucket = bySupplier.getOrPut(supplier.id) { mutableListOf() }
                        matches.forEach { item ->
                            val unitForRate = item.unit.ifBlank { product.unit }
                            val normalizedRate = product.toPrimaryUnitRate(item.unitCost, unitForRate)
                            bucket.add(normalizedRate to purchase.createdAt)
                        }
                    }
                }

                val rows = bySupplier.mapNotNull { (supplierId, entries) ->
                    val supplierName = suppliers.find { it.id == supplierId }?.name ?: return@mapNotNull null
                    val mostRecent = entries.maxByOrNull { it.second } ?: return@mapNotNull null
                    SupplierRateRow(
                        supplierId = supplierId,
                        supplierName = supplierName,
                        lastRate = mostRecent.first,
                        lastDate = mostRecent.second,
                        minRate = entries.minOf { it.first },
                        maxRate = entries.maxOf { it.first },
                        timesPurchased = entries.size
                    )
                }.sortedBy { it.lastRate }

                loadingText.visibility = View.GONE
                renderComparison(rows)
            } catch (e: Exception) {
                loadingText.visibility = View.GONE
                comparisonBody.removeAllViews()
                comparisonBody.addView(hintText(
                    Loc.t(this@RateComparisonActivity, "Could not load rate history: ${e.message}", "ریٹ کی تاریخ لوڈ نہیں ہو سکی: ${e.message}")
                ))
            }
        }
    }

    // ---------------- Rendering ----------------

    private fun renderComparison(rows: List<SupplierRateRow>) {
        comparisonBody.removeAllViews()

        if (rows.isEmpty()) {
            comparisonBody.addView(hintText(
                Loc.t(
                    this,
                    "No purchase history found for this product yet from any supplier.",
                    "اس پروڈکٹ کی کسی بھی سپلائر سے کوئی خریداری کی تاریخ نہیں ملی۔"
                )
            ))
            return
        }

        val bestSupplierId = rows.first().supplierId
        val fmtDate = SimpleDateFormat("dd MMM yyyy", Locale.getDefault())

        rows.forEachIndexed { index, r ->
            val isBest = r.supplierId == bestSupplierId
            val card = LinearLayout(this).apply {
                orientation = LinearLayout.VERTICAL
                setPadding(20, 18, 20, 18)
                background = if (isBest) strokedBg(teal, bestBg, 18) else strokedBg(border, cardWhite, 18)
                layoutParams = LinearLayout.LayoutParams(-1, -2).apply { setMargins(0, 0, 0, 12) }
                applyElevation(this, if (isBest) 4f else 2f)
            }

            val top = LinearLayout(this).apply { orientation = LinearLayout.HORIZONTAL; gravity = Gravity.CENTER_VERTICAL }
            top.addView(TextView(this).apply {
                text = r.supplierName
                textSize = 15f
                setTypeface(typeface, Typeface.BOLD)
                setTextColor(Color.parseColor(if (isBest) teal else textDark))
                layoutParams = LinearLayout.LayoutParams(0, -2, 1f)
            })
            if (isBest) {
                top.addView(TextView(this).apply {
                    text = "\u2705  " + Loc.t(this@RateComparisonActivity, "Best Rate", "بہترین ریٹ")
                    textSize = 10.5f
                    setTextColor(Color.WHITE)
                    setTypeface(typeface, Typeface.BOLD)
                    background = roundedBg(teal, 30)
                    setPadding(16, 8, 16, 8)
                })
            }
            card.addView(top)
            card.addView(View(this).apply {
                setBackgroundColor(Color.parseColor(border))
                layoutParams = LinearLayout.LayoutParams(-1, 1).apply { setMargins(0, 12, 0, 12) }
            })

            val statsRow = LinearLayout(this).apply { orientation = LinearLayout.HORIZONTAL }
            statsRow.addView(statChip(
                Loc.t(this, "Last Rate", "آخری ریٹ"),
                "%.2f".format(r.lastRate),
                if (isBest) teal else textDark
            ), LinearLayout.LayoutParams(0, -2, 1f).apply { setMargins(0, 0, 6, 0) })
            statsRow.addView(statChip(
                Loc.t(this, "Lowest", "کم ترین"),
                "%.2f".format(r.minRate),
                teal
            ), LinearLayout.LayoutParams(0, -2, 1f).apply { setMargins(6, 0, 6, 0) })
            statsRow.addView(statChip(
                Loc.t(this, "Highest", "زیادہ ترین"),
                "%.2f".format(r.maxRate),
                red
            ), LinearLayout.LayoutParams(0, -2, 1f).apply { setMargins(6, 0, 0, 0) })
            card.addView(statsRow)

            card.addView(TextView(this).apply {
                text = Loc.t(
                    this@RateComparisonActivity,
                    "Purchased ${r.timesPurchased} time(s)  •  Last on ${fmtDate.format(Date(r.lastDate))}",
                    "${r.timesPurchased} بار خریدا گیا  •  آخری بار ${fmtDate.format(Date(r.lastDate))}"
                )
                textSize = 11f
                setTextColor(Color.parseColor(textMuted))
                setPadding(2, 12, 0, 0)
            })

            comparisonBody.addView(card)
        }
    }

    private fun statChip(label: String, value: String, accentHex: String) = LinearLayout(this).apply {
        orientation = LinearLayout.VERTICAL
        background = strokedBg(border, fieldFill, 12)
        setPadding(12, 10, 12, 10)
        addView(TextView(this@RateComparisonActivity).apply {
            text = label.uppercase()
            textSize = 9.5f
            setTextColor(Color.parseColor(textMuted))
            setTypeface(typeface, Typeface.BOLD)
            letterSpacing = 0.01f
        })
        addView(TextView(this@RateComparisonActivity).apply {
            text = value
            textSize = 13.5f
            setTextColor(Color.parseColor(accentHex))
            setTypeface(typeface, Typeface.BOLD)
            setPadding(0, 3, 0, 0)
        })
    }

    // ---------------- UI helpers (same style as ProductActivity) ----------------

    private fun gradientBg(startHex: String, endHex: String, cornerTop: Int = 0, cornerBottom: Int = 0) =
        GradientDrawable(
            GradientDrawable.Orientation.TL_BR,
            intArrayOf(Color.parseColor(startHex), Color.parseColor(endHex))
        ).apply {
            val density = resources.displayMetrics.density
            cornerRadii = floatArrayOf(
                cornerTop * density, cornerTop * density,
                cornerTop * density, cornerTop * density,
                cornerBottom * density, cornerBottom * density,
                cornerBottom * density, cornerBottom * density
            )
        }

}

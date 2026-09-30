package com.grocerypos.v11.ui

import com.grocerypos.v11.R

import android.graphics.Color
import android.graphics.drawable.GradientDrawable
import android.os.Bundle
import android.text.Editable
import android.text.TextWatcher
import android.view.Gravity
import android.view.View
import android.widget.*
import androidx.appcompat.app.AppCompatActivity
import androidx.lifecycle.lifecycleScope
import com.grocerypos.v11.*
import kotlinx.coroutines.flow.collectLatest
import kotlinx.coroutines.flow.first
import kotlinx.coroutines.launch
import java.text.SimpleDateFormat
import java.util.Date
import java.util.Locale
import com.grocerypos.v11.ui.components.*

/**
 * Standalone "check the rate" screen: search for any item and see every sale
 * (who bought it, at what rate, when) and every purchase (which supplier, at
 * what rate, when) for that item — newest first, so the current going rate
 * is always the first row in each list.
 *
 * Can be opened two ways:
 *  1) Plain (from menu) — user types to search, exactly as before.
 *  2) With extras "product_id" / "product_name" (from Dashboard search result
 *     tap) — skips the typing step and shows that item's history directly.
 */
class ItemSearchActivity : ThemedActivity() {

    // ---- Same navy + teal palette as PurchaseActivity / SaleActivity ----
    // Pulled from ThemeManager so this screen respects dark mode.
    private var bg = "#F4F6F8"
    private var cardWhite = "#FFFFFF"
    private var navy = "#0B2545"
    private var teal = "#0F9B8E"
    private var orange = "#F5A15C"
    private var textDark = "#0B2545"
    private var textMuted = "#7C8798"
    private var border = "#E3E8EE"

    private fun tintedDrawable(iconRes: Int, tintHex: String, sizeDp: Int = 16): android.graphics.drawable.Drawable? {
        val d = androidx.core.content.ContextCompat.getDrawable(this, iconRes)?.mutate() ?: return null
        d.setTint(Color.parseColor(tintHex))
        val size = (sizeDp * resources.displayMetrics.density).toInt()
        d.setBounds(0, 0, size, size)
        return d
    }

    private fun loadThemeColors() {
        val p = com.grocerypos.v11.util.ThemeManager.palette(this)
        bg = p.bg
        cardWhite = p.cardWhite
        navy = p.navy
        teal = p.teal
        orange = p.amber
        textDark = p.textDark
        textMuted = p.textMuted
        border = p.border
    }

    private lateinit var searchInput: EditText
    private lateinit var resultsContainer: LinearLayout
    private lateinit var detailContainer: LinearLayout
    private lateinit var detailTitle: TextView

    private var products = listOf<Product>()

    // Purchase/cost information (Compare Suppliers, Purchase Rate History, best
    // purchase rate, profit margin) is only for Admin / Manager. Cashier never
    // sees it and it is not even queried for them.
    private val canSeeCost: Boolean
        get() = (getSharedPreferences("session", MODE_PRIVATE).getString("role", "cashier") ?: "cashier")
            .let { it == "admin" || it == "manager" }

    // Where showItemHistory()/addCollapsibleRows() currently add their views:
    // detailContainer normally, switched to the hidden cost container for the
    // purchase-side sections.
    private lateinit var target: LinearLayout

    // Extras passed in from Dashboard's live search result tap
    private var preselectProductBarcode: String? = null
    private var preselectProductName: String? = null

    override fun onCreate(b: Bundle?) {
        super.onCreate(b)
        loadThemeColors()

        preselectProductBarcode = intent.getStringExtra("product_barcode")
        preselectProductName = intent.getStringExtra("product_name")

        val root = LinearLayout(this).apply {
            orientation = LinearLayout.VERTICAL
            setPadding(24, 44, 24, 28)
            setBackgroundColor(Color.parseColor(bg))
        }

        // ================= HEADER =================
        root.addView(LinearLayout(this).apply {
            orientation = LinearLayout.HORIZONTAL
            gravity = Gravity.CENTER_VERTICAL
            setPadding(4, 0, 4, 18)
            addView(TextView(this@ItemSearchActivity).apply {
                text = "Item Rate Search"
                textSize = 20f
                setTextColor(Color.parseColor(textDark))
                setTypeface(typeface, android.graphics.Typeface.BOLD)
                layoutParams = LinearLayout.LayoutParams(0, LinearLayout.LayoutParams.WRAP_CONTENT, 1f)
            })
        })
        root.addView(TextView(this).apply {
            text = "Search any item to see its sale rates (Carton / Dozen / Pcs)"
            textSize = 12f
            setTextColor(Color.parseColor(textMuted))
            setPadding(4, 0, 4, 16)
        })

        // ================= SEARCH BOX =================
        val searchBox = card()
        val searchRow = LinearLayout(this).apply { orientation = LinearLayout.HORIZONTAL; gravity = Gravity.CENTER_VERTICAL }
        searchRow.addView(ImageView(this).apply {
            setImageDrawable(tintedDrawable(R.drawable.ic_search, textMuted, 16))
            setPadding(0, 0, 12, 0)
        })
        searchInput = EditText(this).apply {
            hint = "Type item name…"
            setHintTextColor(Color.parseColor(textMuted))
            setTextColor(Color.parseColor(textDark))
            background = null
            textSize = 15f
            layoutParams = LinearLayout.LayoutParams(0, LinearLayout.LayoutParams.WRAP_CONTENT, 1f)
        }
        searchRow.addView(searchInput)
        searchBox.addView(searchRow)
        root.addView(searchBox)

        // ================= RESULTS (matching products) =================
        resultsContainer = LinearLayout(this).apply { orientation = LinearLayout.VERTICAL }
        root.addView(resultsContainer)
        root.addView(spacer(8))

        // ================= DETAIL (selected item's rate history) =================
        detailTitle = TextView(this).apply {
            textSize = 15f
            setTypeface(typeface, android.graphics.Typeface.BOLD)
            setTextColor(Color.parseColor(textDark))
            setPadding(4, 8, 4, 10)
            visibility = View.GONE
        }
        root.addView(detailTitle)

        detailContainer = LinearLayout(this).apply { orientation = LinearLayout.VERTICAL }
        root.addView(detailContainer)

        setContentView(ScrollView(this).apply {
            setBackgroundColor(Color.parseColor(bg))
            addView(root)
        })

        loadProducts()

        searchInput.addTextChangedListener(object : TextWatcher {
            override fun beforeTextChanged(s: CharSequence?, a: Int, b: Int, c: Int) {}
            override fun onTextChanged(s: CharSequence?, a: Int, b: Int, c: Int) {}
            override fun afterTextChanged(s: Editable?) {
                renderResults(s?.toString()?.trim() ?: "")
            }
        })
    }

    private fun loadProducts() {
        lifecycleScope.launch {
            PosDatabase.get(this@ItemSearchActivity).productDao().all().collectLatest { list ->
                products = list

                // If opened directly from Dashboard's search result with a specific
                // product, jump straight to its history instead of showing the
                // type-to-search box empty — no retyping needed.
                if (preselectProductBarcode != null) {
                    val match = products.firstOrNull { it.barcode == preselectProductBarcode }
                        ?: preselectProductName?.let { name -> products.firstOrNull { it.name == name } }
                    if (match != null) {
                        searchInput.setText(match.name)
                        showItemHistory(match)
                        preselectProductBarcode = null // only auto-open once
                        preselectProductName = null
                        return@collectLatest
                    }
                }

                renderResults(searchInput.text.toString().trim())
            }
        }
    }

    private fun renderResults(query: String) {
        resultsContainer.removeAllViews()
        if (query.isEmpty()) return

        val matches = products.filter { it.matchesQuery(query) }.take(15)
        if (matches.isEmpty()) {
            resultsContainer.addView(TextView(this).apply {
                text = "No matching item"
                textSize = 13f
                setTextColor(Color.parseColor(textMuted))
                setPadding(4, 10, 4, 4)
            })
            return
        }
        matches.forEach { product ->
            resultsContainer.addView(card().apply {
                orientation = LinearLayout.VERTICAL
                setOnClickListener { showItemHistory(product) }
                addView(LinearLayout(this@ItemSearchActivity).apply {
                    orientation = LinearLayout.HORIZONTAL
                    gravity = Gravity.CENTER_VERTICAL
                    addView(TextView(this@ItemSearchActivity).apply {
                        text = product.name
                        textSize = 14.5f
                        setTextColor(Color.parseColor(textDark))
                        setTypeface(typeface, android.graphics.Typeface.BOLD)
                        layoutParams = LinearLayout.LayoutParams(0, LinearLayout.LayoutParams.WRAP_CONTENT, 1f)
                    })
                    addView(TextView(this@ItemSearchActivity).apply {
                        // Product.stock is a SMALLEST-unit count; formatStockBreakdown()
                        // is the shared helper every other screen uses.
                        text = "Stock: ${product.formatStockBreakdown()}"
                        textSize = 11.5f
                        setTextColor(Color.parseColor(textMuted))
                    })
                })
                // Sale rate in every tier, right in the list — no need to open the item.
                addView(TextView(this@ItemSearchActivity).apply {
                    text = if (product.salePrice > 0) product.tierRateLine(product.salePrice) else "Sale rate set nahi"
                    textSize = 12.5f
                    setTextColor(Color.parseColor(if (product.salePrice > 0) teal else textMuted))
                    setTypeface(typeface, android.graphics.Typeface.BOLD)
                    setPadding(0, 6, 0, 0)
                })
            })
        }
    }

    private fun fmtRate(v: Double): String =
        if (v % 1.0 == 0.0) "%.0f".format(v) else "%.2f".format(v)

    // "Ctn Rs 2880  •  Dzn Rs 720  •  Pcs Rs 60" — [primaryRate] is a PRIMARY-unit
    // price (how salePrice / wholesalePrice are stored), converted through the same
    // unit ladder the Sale screen uses. 1- or 2-tier products show only their tiers.
    private fun Product.tierRateLine(primaryRate: Double): String =
        unitLadder().asReversed().joinToString("  •  ") { tier ->
            "${tier.unit} Rs ${fmtRate(fromPrimaryUnitRate(primaryRate, tier.unit))}"
        }

    // Big "Sale Rate" card shown first when an item is opened: every tier in a large
    // font, and the (smaller) wholesale rate underneath if one is set.
    private fun saleRateCard(product: Product): LinearLayout = LinearLayout(this).apply {
        orientation = LinearLayout.VERTICAL
        setPadding(24, 20, 24, 20)
        background = strokedBg(teal, cardWhite, 14)
        layoutParams = LinearLayout.LayoutParams(
            LinearLayout.LayoutParams.MATCH_PARENT, LinearLayout.LayoutParams.WRAP_CONTENT
        ).apply { setMargins(0, 0, 0, 14) }

        addView(TextView(this@ItemSearchActivity).apply {
            text = "SALE RATE"
            textSize = 10.5f
            setTextColor(Color.parseColor(teal))
            setTypeface(typeface, android.graphics.Typeface.BOLD)
            setPadding(0, 0, 0, 8)
        })
        if (product.salePrice > 0) {
            product.unitLadder().asReversed().forEach { tier ->
                addView(LinearLayout(this@ItemSearchActivity).apply {
                    orientation = LinearLayout.HORIZONTAL
                    gravity = Gravity.CENTER_VERTICAL
                    setPadding(0, 2, 0, 2)
                    addView(TextView(this@ItemSearchActivity).apply {
                        text = tier.unit
                        textSize = 14f
                        setTextColor(Color.parseColor(textMuted))
                        layoutParams = LinearLayout.LayoutParams(0, LinearLayout.LayoutParams.WRAP_CONTENT, 1f)
                    })
                    addView(TextView(this@ItemSearchActivity).apply {
                        text = "Rs ${fmtRate(product.fromPrimaryUnitRate(product.salePrice, tier.unit))}"
                        textSize = 22f
                        setTextColor(Color.parseColor(textDark))
                        setTypeface(typeface, android.graphics.Typeface.BOLD)
                    })
                })
            }
        } else {
            addView(TextView(this@ItemSearchActivity).apply {
                text = "Is item ka sale rate abhi set nahi hai"
                textSize = 13f
                setTextColor(Color.parseColor(textMuted))
            })
        }
        if (product.wholesalePrice > 0) {
            addView(View(this@ItemSearchActivity).apply {
                setBackgroundColor(Color.parseColor(border))
                layoutParams = LinearLayout.LayoutParams(LinearLayout.LayoutParams.MATCH_PARENT, 2).apply { setMargins(0, 10, 0, 10) }
            })
            addView(TextView(this@ItemSearchActivity).apply {
                text = "Wholesale:  " + product.tierRateLine(product.wholesalePrice)
                textSize = 12.5f
                setTextColor(Color.parseColor(orange))
                setTypeface(typeface, android.graphics.Typeface.BOLD)
            })
        }
    }

    private fun showItemHistory(product: Product) {
        detailTitle.visibility = View.VISIBLE
        detailTitle.text = product.name
        detailContainer.removeAllViews()
        resultsContainer.removeAllViews()
        target = detailContainer
        val showCostSections = canSeeCost

        lifecycleScope.launch {
            val db = PosDatabase.get(this@ItemSearchActivity)
            val saleRecords = db.saleDao().saleRecordsForItem(product.barcode)
            val purchaseRecords = if (showCostSections) db.purchaseDao().purchaseRecordsForItem(product.barcode) else emptyList()
            val fmt = SimpleDateFormat("dd MMM yyyy, hh:mm a", Locale.getDefault())

            // ---- Build the per-supplier summaries ONCE up front (not inline inside
            // the Compare Suppliers section like before) — the new Quick Summary
            // card above it needs the same "who's cheapest" answer, so both read
            // off this single list instead of computing it twice. ----
            val supplierSummaries: List<SupplierSummary> = if (purchaseRecords.isEmpty()) emptyList() else {
                val bySupplier = purchaseRecords.groupBy { it.supplierName }
                bySupplier.map { (supplier, records) ->
                    // records are already newest-first (query orders by createdAt DESC),
                    // so the first one per supplier is that supplier's latest rate and
                    // the second (if any) is the rate just before it, for the trend arrow.
                    val lastUnit = records.first().unit.ifBlank { product.unit }
                    val lastRate = records.first().unitCost
                    // FIX: different purchases (even from the same supplier, and
                    // definitely across different suppliers) can be rung up in
                    // different tiers — one per-Carton, another per-Piece. Comparing
                    // or averaging those raw numbers directly would be comparing
                    // apples to oranges (a Rs 60/Pcs line is NOT cheaper than a
                    // Rs 2650/Ctn line just because 60 < 2650). Every record is
                    // normalized to the product's PRIMARY-unit rate first — that's
                    // the only fair common basis — and only the headline "Rs X"
                    // figure stays in the transaction's own unit for readability.
                    val primaryLastRate = product.toPrimaryUnitRate(lastRate, lastUnit)
                    val avgPrimaryRate = records.sumOf { product.toPrimaryUnitRate(it.unitCost, it.unit.ifBlank { product.unit }) } / records.size
                    SupplierSummary(
                        supplier = supplier,
                        lastRate = lastRate,
                        lastUnit = lastUnit,
                        primaryLastRate = primaryLastRate,
                        avgRate = product.fromPrimaryUnitRate(avgPrimaryRate, lastUnit),
                        purchaseCount = records.size,
                        lastPurchaseAt = records.first().createdAt,
                        prevPrimaryRate = records.getOrNull(1)?.let { product.toPrimaryUnitRate(it.unitCost, it.unit.ifBlank { product.unit }) }
                    )
                }.sortedBy { it.primaryLastRate }
            }
            val bestSupplier = supplierSummaries.minByOrNull { it.primaryLastRate }

            // ---- NEW: Quick Summary — the single "am I making money, and who's
            // cheapest" card at the very top, so a shopkeeper doesn't have to read
            // three separate lists just to get today's answer. Only shown when
            // there's at least a sale or a purchase to summarize. ----
            // Big Sale Rate card first (all tiers + wholesale), then the summary.
            detailContainer.addView(saleRateCard(product))
            detailContainer.addView(quickSummaryCard(product, saleRecords.firstOrNull(), bestSupplier, showCostSections))
            detailContainer.addView(spacer(14))

            // ---- Sale rate history (newest first, so latest sale rate is on top) ----
            detailContainer.addView(sectionHeader("Sale Rate History", teal))
            detailContainer.addView(sectionSubtitle("Jis rate par yeh item becha gaya, sabse naya pehle"))
            if (saleRecords.isEmpty()) {
                detailContainer.addView(emptyRow("No sales of this item yet"))
            } else {
                val saleRows = saleRecords.mapIndexed { index, r ->
                    rateRow(
                        party = r.customerName,
                        // FIX: use the unit THAT LINE was actually sold in (si.unit),
                        // not product.unit (the product's primary unit) — a sale
                        // rung up in Pcs must not be relabelled as Ctn just because
                        // Ctn happens to be this product's default unit.
                        qtyLabel = "${r.qty} ${r.unit.ifBlank { product.unit }}",
                        rate = r.unitPrice,
                        unit = r.unit.ifBlank { product.unit },
                        date = fmt.format(Date(r.createdAt)),
                        colorHex = teal,
                        isLatest = index == 0,
                        product = product
                    )
                }
                // NEW: collapse long history to the latest 3 with a "Show more"
                // toggle, so an item with dozens of sales doesn't turn this screen
                // into an endless scroll before the user even reaches Purchase History.
                addCollapsibleRows(saleRows, visibleCount = 3, colorHex = teal)
            }

            detailContainer.addView(spacer(14))

            // ---- Purchase-side sections: hidden until "Show cost" is tapped, and
            // only exist at all for Admin / Manager. ----
            if (!showCostSections) return@launch
            val costContainer = LinearLayout(this@ItemSearchActivity).apply {
                orientation = LinearLayout.VERTICAL
                visibility = View.GONE
            }
            lateinit var costToggle: TextView
            costToggle = TextView(this@ItemSearchActivity).apply {
                text = "Show cost ▾"
                textSize = 13f
                gravity = Gravity.CENTER
                setTextColor(Color.parseColor(orange))
                setTypeface(typeface, android.graphics.Typeface.BOLD)
                background = strokedBg(orange, cardWhite, 12)
                setPadding(20, 16, 20, 16)
                layoutParams = LinearLayout.LayoutParams(
                    LinearLayout.LayoutParams.MATCH_PARENT, LinearLayout.LayoutParams.WRAP_CONTENT
                ).apply { setMargins(0, 0, 0, 12) }
                setOnClickListener {
                    val opening = costContainer.visibility == View.GONE
                    costContainer.visibility = if (opening) View.VISIBLE else View.GONE
                    costToggle.text = if (opening) "Hide cost ▴" else "Show cost ▾"
                }
            }
            detailContainer.addView(costToggle)
            detailContainer.addView(costContainer)
            target = costContainer

            // ---- NEW: Compare Suppliers — groups the same purchase records by
            // supplier so the user can see, at a glance, who is currently cheapest
            // for this item (last rate) and who tends to be cheapest overall (avg
            // rate), without reading through the full chronological list above. ----
            target.addView(sectionHeader("Compare Suppliers", navy))
            target.addView(sectionSubtitle("Har supplier ka aakhri rate — sabse sasta upar, BEST RATE badge ke sath"))
            if (supplierSummaries.isEmpty()) {
                target.addView(emptyRow("No supplier data yet for this item"))
            } else {
                val cheapestPrimaryRate = supplierSummaries.minOf { it.primaryLastRate }
                // NEW: savings badge on the best-rate card — how much cheaper the
                // best rate is than the next-cheapest DISTINCT rate (so a tie between
                // two suppliers at the same rate doesn't show "Rs 0.00 cheaper").
                // Kept in primary-unit terms here since the two suppliers being
                // compared may not share a display unit; supplierCompareRow converts
                // it into that row's own lastUnit right before showing it.
                val distinctPrimaryRates = supplierSummaries.map { it.primaryLastRate }.distinct().sorted()
                val savingsVsNextPrimary = if (distinctPrimaryRates.size > 1) distinctPrimaryRates[1] - distinctPrimaryRates[0] else null
                val now = System.currentTimeMillis()
                supplierSummaries.forEach { s ->
                    target.addView(
                        supplierCompareRow(
                            summary = s,
                            isBest = s.primaryLastRate == cheapestPrimaryRate,
                            savingsVsNextPrimary = savingsVsNextPrimary,
                            daysSincePurchase = ((now - s.lastPurchaseAt) / (1000L * 60 * 60 * 24)).toInt(),
                            product = product
                        )
                    )
                }
            }

            target.addView(spacer(14))

            // ---- Purchase rate history (newest first, so latest cost rate is on top) ----
            target.addView(sectionHeader("Purchase Rate History", orange))
            target.addView(sectionSubtitle("Jis rate par yeh item khareeda gaya, sabse naya pehle"))
            if (purchaseRecords.isEmpty()) {
                target.addView(emptyRow("No purchases of this item yet"))
            } else {
                val purchaseRows = purchaseRecords.mapIndexed { index, r ->
                    rateRow(
                        party = r.supplierName,
                        // FIX: same as sale rows above — use that purchase line's
                        // own unit (pi.unit), not product.unit.
                        qtyLabel = "${r.qty} ${r.unit.ifBlank { product.unit }}",
                        rate = r.unitCost,
                        unit = r.unit.ifBlank { product.unit },
                        date = fmt.format(Date(r.createdAt)),
                        colorHex = orange,
                        isLatest = index == 0,
                        product = product
                    )
                }
                addCollapsibleRows(purchaseRows, visibleCount = 3, colorHex = orange)
            }
        }
    }

    // NEW: one-line plain-language explainer shown under each section header, so
    // someone opening this screen for the first time doesn't have to guess what
    // "Compare Suppliers" or "Sale Rate History" actually means.
    private fun sectionSubtitle(text: String) = TextView(this).apply {
        this.text = text
        textSize = 11f
        setTextColor(Color.parseColor(textMuted))
        setPadding(4, 0, 4, 10)
    }

    // NEW: shows the latest N rows, and — only if there are more than that —
    // a tappable "Show N more / Show less" toggle that reveals the rest without
    // a second screen or a separate tap-through. Extra rows are pre-built and
    // just hidden/shown, so toggling is instant.
    private fun addCollapsibleRows(rows: List<View>, visibleCount: Int, colorHex: String) {
        rows.take(visibleCount).forEach { target.addView(it) }
        val remaining = rows.size - visibleCount
        if (remaining <= 0) return
        val extra = LinearLayout(this).apply {
            orientation = LinearLayout.VERTICAL
            visibility = View.GONE
        }
        rows.drop(visibleCount).forEach { extra.addView(it) }
        target.addView(extra)
        lateinit var toggle: TextView
        toggle = TextView(this).apply {
            text = "Show $remaining more ▾"
            textSize = 12.5f
            setTextColor(Color.parseColor(colorHex))
            setTypeface(typeface, android.graphics.Typeface.BOLD)
            setPadding(4, 2, 4, 14)
            setOnClickListener {
                val expanding = extra.visibility == View.GONE
                extra.visibility = if (expanding) View.VISIBLE else View.GONE
                toggle.text = if (expanding) "Show less ▴" else "Show $remaining more ▾"
            }
        }
        target.addView(toggle)
    }

    // NEW: the "am I making money, and who's cheapest" card — one glance instead
    // of reading three separate lists. Shows the latest sale rate, the currently
    // cheapest supplier's rate, and the margin between them (converted onto the
    // SAME unit basis via toPrimaryUnitRate/fromPrimaryUnitRate before subtracting,
    // since a sale rung up per-Pcs and a purchase rung up per-Ctn are not directly
    // comparable numbers otherwise). Any piece that's missing (no sales yet, or no
    // purchases yet) is simply left out rather than shown as a misleading zero.
    private fun quickSummaryCard(product: Product, latestSale: ItemSaleRecord?, bestSupplier: SupplierSummary?, showCost: Boolean): LinearLayout {
        return LinearLayout(this).apply {
            orientation = LinearLayout.VERTICAL
            setPadding(20, 16, 20, 16)
            background = strokedBg(navy, "#F0F4FA", 14)
            layoutParams = LinearLayout.LayoutParams(
                LinearLayout.LayoutParams.MATCH_PARENT, LinearLayout.LayoutParams.WRAP_CONTENT
            )

            addView(TextView(this@ItemSearchActivity).apply {
                text = "QUICK SUMMARY"
                textSize = 10.5f
                setTextColor(Color.parseColor(navy))
                setTypeface(typeface, android.graphics.Typeface.BOLD)
                setPadding(0, 0, 0, 10)
            })

            fun statRow(label: String, valueText: String, valueColor: String) {
                addView(LinearLayout(this@ItemSearchActivity).apply {
                    orientation = LinearLayout.HORIZONTAL
                    gravity = Gravity.CENTER_VERTICAL
                    setPadding(0, 0, 0, 8)
                    addView(TextView(this@ItemSearchActivity).apply {
                        text = label
                        textSize = 12.5f
                        setTextColor(Color.parseColor(textMuted))
                        layoutParams = LinearLayout.LayoutParams(0, LinearLayout.LayoutParams.WRAP_CONTENT, 1f)
                    })
                    addView(TextView(this@ItemSearchActivity).apply {
                        text = valueText
                        textSize = 13.5f
                        setTypeface(typeface, android.graphics.Typeface.BOLD)
                        setTextColor(Color.parseColor(valueColor))
                    })
                })
            }

            // NEW: Current Stock — this card is the first thing shown when a user
            // searches an item, so "kitna stock pada hai" should be answerable
            // right here instead of only on the Products/Items screen. Uses the
            // same formatStockBreakdown() helper as everywhere else so the number
            // always matches Products/Purchase/Sale/Dashboard screens.
            statRow("Current Stock", product.formatStockBreakdown(), navy)

            if (latestSale != null) {
                val saleUnit = latestSale.unit.ifBlank { product.unit }
                statRow("Last Sold At", "Rs %.2f / %s".format(latestSale.unitPrice, saleUnit), teal)
            }
            if (showCost && bestSupplier != null) {
                statRow("Best Purchase Rate", "Rs %.2f / %s  (${bestSupplier.supplier})".format(bestSupplier.lastRate, bestSupplier.lastUnit), orange)
            }
            // Margin only makes sense once we have BOTH a sale rate and a purchase
            // rate to compare — and only once they're put on the same unit basis.
            if (showCost && latestSale != null && bestSupplier != null) {
                val saleUnit = latestSale.unit.ifBlank { product.unit }
                val costInSaleUnit = product.fromPrimaryUnitRate(bestSupplier.primaryLastRate, saleUnit)
                if (costInSaleUnit > 0) {
                    val margin = latestSale.unitPrice - costInSaleUnit
                    val marginPct = (margin / costInSaleUnit) * 100
                    val marginColor = if (margin >= 0) teal else "#D9534F"
                    statRow(
                        "Profit Margin",
                        "%s Rs %.2f / %s  (%.1f%%)".format(if (margin >= 0) "+" else "", margin, saleUnit, marginPct),
                        marginColor
                    )
                }
            }
        }
    }

    // NEW: given a rate entered in [enteredUnit] (may be ANY tier — Pcs, Dzn, Ctn,
    // whatever that specific sale/purchase line actually used), format the same
    // rate in every OTHER tier of the product's unit ladder, e.g.
    // "Rs 2880.00 / Ctn  •  Rs 720.00 / Dzn" when the line itself was rung up
    // per-Pcs. Converts through the primary-unit rate as a common pivot (via
    // toPrimaryUnitRate/fromPrimaryUnitRate — the same conversion Sale/Purchase
    // screens use) so this can never drift out of sync with actual pricing math.
    // FIX: previously this always treated the incoming rate as if it were a
    // PRIMARY-unit (Ctn) rate and only dropped the primary tier from the
    // breakdown — correct only when the sale/purchase itself happened to be in
    // the primary unit. A line sold in Pcs got its Pcs rate silently relabelled
    // as a Ctn rate and divided down from there, producing a wrong Dzn/Pcs
    // breakdown. Now it pivots off whichever unit the line was ACTUALLY in.
    // Returns "" for a 1-tier product (nothing to break down).
    private fun Product.rateBreakdownLabel(enteredRate: Double, enteredUnit: String): String {
        val ladder = unitLadder()
        if (ladder.size <= 1) return ""
        val primaryRate = toPrimaryUnitRate(enteredRate, enteredUnit)
        // unitLadder() is smallest-first; reverse to largest-first ([primary, ...,
        // smallest]) and drop whichever tier IS enteredUnit, since that's already
        // the main "Rs X" figure shown above this line.
        return ladder.asReversed()
            .filterNot { it.unit.trim().equals(enteredUnit.trim(), ignoreCase = true) }
            .joinToString("   •   ") { tier ->
                "Rs %.2f / ${tier.unit}".format(fromPrimaryUnitRate(primaryRate, tier.unit))
            }
    }

    private fun unitBreakdownRow(product: Product, rate: Double, unit: String, colorHex: String): TextView? {
        val label = product.rateBreakdownLabel(rate, unit)
        if (label.isEmpty()) return null
        return TextView(this).apply {
            text = label
            textSize = 11f
            setTextColor(Color.parseColor(colorHex))
            setPadding(0, 4, 0, 0)
        }
    }

    // NEW: one grouped-by-supplier summary row for the Compare Suppliers table.
    private data class SupplierSummary(
        val supplier: String,
        val lastRate: Double,       // headline figure, in lastUnit (the unit that purchase line actually used)
        val lastUnit: String,       // unit that supplier's LATEST purchase line was actually rung up in
        val primaryLastRate: Double, // same rate normalized to the product's PRIMARY unit — for cross-supplier comparison only, never displayed directly
        val avgRate: Double,        // average cost, normalized then converted back into lastUnit so it reads naturally next to the headline figure
        val purchaseCount: Int,
        val lastPurchaseAt: Long,
        val prevPrimaryRate: Double? // primary-unit-normalized rate from the purchase just before the latest one, for the trend arrow
    )

    // Below this many days since the last purchase, we warn that the rate might
    // no longer be current (supplier may have since changed it).
    private val STALE_RATE_DAYS = 30

    // NEW: one row of the Compare Suppliers table — supplier name, their last rate
    // and running average, purchase count, a "BEST RATE" badge + savings-vs-next
    // on whoever is currently cheapest, a trend arrow vs their own previous rate,
    // and a staleness warning if their last purchase was a while ago.
    private fun supplierCompareRow(summary: SupplierSummary, isBest: Boolean, savingsVsNextPrimary: Double?, daysSincePurchase: Int, product: Product): LinearLayout {
        val supplier = summary.supplier
        val lastRate = summary.lastRate
        return LinearLayout(this).apply {
            orientation = LinearLayout.VERTICAL
            setPadding(18, 14, 18, 14)
            background = strokedBg(if (isBest) navy else border, if (isBest) "#EAF2FF" else cardWhite, 12)
            layoutParams = LinearLayout.LayoutParams(
                LinearLayout.LayoutParams.MATCH_PARENT, LinearLayout.LayoutParams.WRAP_CONTENT
            ).apply { setMargins(0, 0, 0, 8) }

            val top = LinearLayout(this@ItemSearchActivity).apply { orientation = LinearLayout.HORIZONTAL; gravity = Gravity.CENTER_VERTICAL }
            top.addView(TextView(this@ItemSearchActivity).apply {
                text = supplier
                textSize = 13.5f
                setTextColor(Color.parseColor(textDark))
                setTypeface(typeface, android.graphics.Typeface.BOLD)
                layoutParams = LinearLayout.LayoutParams(0, LinearLayout.LayoutParams.WRAP_CONTENT, 1f)
            })
            if (isBest) {
                top.addView(TextView(this@ItemSearchActivity).apply {
                    text = "BEST RATE"
                    textSize = 9.5f
                    setTextColor(Color.WHITE)
                    setTypeface(typeface, android.graphics.Typeface.BOLD)
                    background = roundedBg(navy, 20)
                    setPadding(14, 4, 14, 4)
                })
                top.addView(View(this@ItemSearchActivity).apply { layoutParams = LinearLayout.LayoutParams(8, 1) })
            }
            // NEW: trend arrow — how this supplier's rate moved vs their own
            // previous purchase (not vs other suppliers). Compared on the
            // primary-unit-normalized rate, since the previous purchase may have
            // been rung up in a different unit tier than the latest one — comparing
            // the raw entered numbers directly would be meaningless in that case.
            // Rising cost = orange ▲, falling cost = teal ▼. No arrow on a single
            // purchase or an unchanged (normalized) rate.
            summary.prevPrimaryRate?.let { prevPrimary ->
                if (summary.primaryLastRate > prevPrimary) {
                    top.addView(TextView(this@ItemSearchActivity).apply {
                        text = "▲"
                        textSize = 11f
                        setTextColor(Color.parseColor(orange))
                        setPadding(0, 0, 6, 0)
                    })
                } else if (summary.primaryLastRate < prevPrimary) {
                    top.addView(TextView(this@ItemSearchActivity).apply {
                        text = "▼"
                        textSize = 11f
                        setTextColor(Color.parseColor(teal))
                        setPadding(0, 0, 6, 0)
                    })
                }
            }
            top.addView(TextView(this@ItemSearchActivity).apply {
                text = "Rs %.2f".format(lastRate)
                textSize = 14f
                setTextColor(Color.parseColor(if (isBest) navy else textDark))
                setTypeface(typeface, android.graphics.Typeface.BOLD)
            })
            addView(top)
            unitBreakdownRow(product, lastRate, summary.lastUnit, if (isBest) navy else textMuted)?.let { addView(it) }
            addView(TextView(this@ItemSearchActivity).apply {
                text = "Last rate  •  Avg Rs %.2f over %d purchase%s".format(summary.avgRate, summary.purchaseCount, if (summary.purchaseCount == 1) "" else "s")
                textSize = 11.5f
                setTextColor(Color.parseColor(textMuted))
                setPadding(0, 4, 0, 0)
            })
            // NEW: savings badge — only on the best-rate card, only when there's a
            // genuinely different (non-tied) next rate to compare against. Converted
            // from the primary-unit difference into THIS row's own lastUnit so it
            // reads naturally next to the headline "Rs X" figure above.
            val savingsVsNext = savingsVsNextPrimary?.let { product.fromPrimaryUnitRate(it, summary.lastUnit) }
            if (isBest && savingsVsNext != null && savingsVsNext > 0) {
                addView(TextView(this@ItemSearchActivity).apply {
                    text = "Rs %.2f cheaper than the next best rate".format(savingsVsNext)
                    textSize = 11.5f
                    setTextColor(Color.parseColor(teal))
                    setTypeface(typeface, android.graphics.Typeface.BOLD)
                    setPadding(0, 4, 0, 0)
                })
            }
            // NEW: staleness warning — this supplier's rate hasn't been confirmed
            // by a purchase in a while, so it may no longer reflect what they'd
            // actually charge today.
            if (daysSincePurchase >= STALE_RATE_DAYS) {
                addView(TextView(this@ItemSearchActivity).apply {
                    text = "⚠ Rate may be outdated — last bought $daysSincePurchase days ago"
                    textSize = 11f
                    setTextColor(Color.parseColor(orange))
                    setPadding(0, 4, 0, 0)
                })
            }
        }
    }

    private fun sectionHeader(label: String, colorHex: String) = TextView(this).apply {
        text = label
        textSize = 12.5f
        setTextColor(Color.parseColor(colorHex))
        setTypeface(typeface, android.graphics.Typeface.BOLD)
        setPadding(4, 0, 4, 8)
    }

    private fun emptyRow(text: String) = TextView(this).apply {
        this.text = text
        textSize = 12.5f
        setTextColor(Color.parseColor(textMuted))
        setPadding(4, 4, 4, 12)
    }

    private fun rateRow(party: String, qtyLabel: String, rate: Double, unit: String, date: String, colorHex: String, isLatest: Boolean, product: Product): LinearLayout {
        return LinearLayout(this).apply {
            orientation = LinearLayout.VERTICAL
            setPadding(18, 14, 18, 14)
            background = strokedBg(if (isLatest) colorHex else border, cardWhite, 12)
            layoutParams = LinearLayout.LayoutParams(
                LinearLayout.LayoutParams.MATCH_PARENT, LinearLayout.LayoutParams.WRAP_CONTENT
            ).apply { setMargins(0, 0, 0, 8) }

            val top = LinearLayout(this@ItemSearchActivity).apply { orientation = LinearLayout.HORIZONTAL; gravity = Gravity.CENTER_VERTICAL }
            top.addView(TextView(this@ItemSearchActivity).apply {
                text = party
                textSize = 13.5f
                setTextColor(Color.parseColor(textDark))
                setTypeface(typeface, android.graphics.Typeface.BOLD)
                layoutParams = LinearLayout.LayoutParams(0, LinearLayout.LayoutParams.WRAP_CONTENT, 1f)
            })
            if (isLatest) {
                top.addView(TextView(this@ItemSearchActivity).apply {
                    text = "LATEST"
                    textSize = 9.5f
                    setTextColor(Color.WHITE)
                    setTypeface(typeface, android.graphics.Typeface.BOLD)
                    background = roundedBg(colorHex, 20)
                    setPadding(14, 4, 14, 4)
                    setPadding(paddingLeft, paddingTop, paddingRight, paddingBottom)
                })
                top.addView(View(this@ItemSearchActivity).apply { layoutParams = LinearLayout.LayoutParams(8, 1) })
            }
            top.addView(TextView(this@ItemSearchActivity).apply {
                text = "Rs %.2f".format(rate)
                textSize = 14f
                setTextColor(Color.parseColor(colorHex))
                setTypeface(typeface, android.graphics.Typeface.BOLD)
            })
            addView(top)
            unitBreakdownRow(product, rate, unit, colorHex)?.let { addView(it) }
            addView(TextView(this@ItemSearchActivity).apply {
                text = "$qtyLabel  •  $date"
                textSize = 11.5f
                setTextColor(Color.parseColor(textMuted))
                setPadding(0, 4, 0, 0)
            })
        }
    }

    private fun card() = LinearLayout(this).apply {
        orientation = LinearLayout.VERTICAL
        setPadding(20, 14, 20, 14)
        background = strokedBg(border, cardWhite, 14)
        layoutParams = LinearLayout.LayoutParams(
            LinearLayout.LayoutParams.MATCH_PARENT, LinearLayout.LayoutParams.WRAP_CONTENT
        ).apply { setMargins(0, 0, 0, 10) }
        elevation = 2f
    }

    // spacer() now comes from the shared UiHelpers.kt (item #24 dedup) — was a
    // byte-identical private copy here before.
}

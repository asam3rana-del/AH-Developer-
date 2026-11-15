package com.grocerypos.v11.ui

import android.content.Intent
import android.graphics.Color
import android.os.Bundle
import android.view.Gravity
import android.view.View
import android.view.ViewGroup
import android.widget.*
import androidx.lifecycle.lifecycleScope
import androidx.recyclerview.widget.LinearLayoutManager
import androidx.recyclerview.widget.RecyclerView
import androidx.room.withTransaction
import com.grocerypos.v11.*
import kotlinx.coroutines.launch
import com.grocerypos.v11.ui.components.*

class SaleHistoryActivity : ThemedActivity() {

    // ---- Same navy + teal palette as PurchaseActivity / SaleActivity ----
    // Pulled from ThemeManager so this screen respects dark mode.
    private var bg = "#F4F6F8"
    private var cardWhite = "#FFFFFF"
    private var navy = "#0B2545"
    private var teal = "#0F9B8E"
    private var textDark = "#0B2545"
    private var textMuted = "#7C8798"
    private var border = "#E3E8EE"
    private var red = "#E5484D"

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
        textDark = p.textDark
        textMuted = p.textMuted
        border = p.border
        red = p.red
    }

    // ---- Item #2 (RecyclerView migration): the header/sale/expanded-item rows
    // that used to be addView()'d into a LinearLayout inside a ScrollView are now
    // a flat list of Row values bound to a RecyclerView, so only on-screen rows
    // get inflated instead of the whole history living as permanent child views.
    private sealed class Row {
        data class Header(val name: String, val count: Int, val total: Double, val profit: Double) : Row()
        data class SaleRow(val sale: SaleWithCustomer, val profit: Double?) : Row()
        data class ItemRow(val invoice: String, val text: String) : Row()
        data class ItemsEmpty(val invoice: String) : Row()
    }

    private inner class RowAdapter : RecyclerView.Adapter<RowAdapter.Holder>() {
        inner class Holder(val container: FrameLayout) : RecyclerView.ViewHolder(container)

        var rows: List<Row> = emptyList()
            private set

        fun submit(newRows: List<Row>) {
            rows = newRows
            notifyDataSetChanged()
        }

        override fun onCreateViewHolder(parent: ViewGroup, viewType: Int) = Holder(
            FrameLayout(parent.context).apply {
                layoutParams = ViewGroup.LayoutParams(ViewGroup.LayoutParams.MATCH_PARENT, ViewGroup.LayoutParams.WRAP_CONTENT)
            }
        )

        override fun onBindViewHolder(holder: Holder, position: Int) {
            val view = when (val row = rows[position]) {
                is Row.Header -> customerHeader(row.name, row.count, row.total, row.profit)
                is Row.SaleRow -> saleRow(row.sale, row.profit)
                is Row.ItemRow -> itemLine(row.text, muted = false)
                is Row.ItemsEmpty -> itemLine("No items on this sale.", muted = true)
            }
            holder.container.removeAllViews()
            holder.container.addView(view)
        }

        override fun getItemCount() = rows.size
    }

    private lateinit var recyclerView: RecyclerView
    private val adapter = RowAdapter()
    private lateinit var emptyText: TextView
    // ADDED (Khatabook-style summary cards + search — matches PartyDashboardActivity/
    // PurchaseHistoryActivity): total sales amount + total returned amount, plus a
    // search box to filter by customer name.
    private lateinit var totalSalesValue: TextView
    private lateinit var totalReturnedValue: TextView
    private lateinit var searchField: EditText
    private var searchQuery: String = ""

    // invoice -> whether its item breakdown is currently expanded
    private val expandedSales = mutableSetOf<String>()
    // invoice -> cached items once loaded, so re-collapsing/expanding doesn't re-hit the DB
    private val loadedItems = mutableMapOf<String, List<SaleItem>>()
    // last grouped-by-customer sales fetched from the DB, so toggling expand/collapse
    // can rebuild the flat row list without a fresh query
    private var groupedSales: List<Pair<String, List<SaleWithCustomer>>> = emptyList()
    // NEW (bill-wise profit): invoice -> profit for that bill, and whether this
    // logged-in user is allowed to see profit at all (cashiers don't, same as
    // MainActivity's "Today's Profit" card and every other profit figure in the app).
    private var saleProfits: Map<String, Double> = emptyMap()
    private val isAdmin: Boolean
        get() = getSharedPreferences("session", MODE_PRIVATE).getString("role", "cashier") == "admin"

    override fun onCreate(b: Bundle?) {
        super.onCreate(b)
        loadThemeColors()

        val outer = LinearLayout(this).apply {
            orientation = LinearLayout.VERTICAL
            setBackgroundColor(Color.parseColor(bg))
        }
        outer.addView(premiumHeader(
            iconRes = R.drawable.ic_receipt,
            title = "Sale History",
            subtitle = "All past sales, grouped by customer",
            primaryHex = navy,
            primaryDarkHex = navy
        ))

        val root = LinearLayout(this).apply {
            orientation = LinearLayout.VERTICAL
            setPadding(24, 22, 24, 28)
        }

        root.addView(LinearLayout(this).apply {
            orientation = LinearLayout.HORIZONTAL
            gravity = Gravity.CENTER_VERTICAL
            setPadding(4, 0, 4, 18)
            addView(View(this@SaleHistoryActivity).apply {
                layoutParams = LinearLayout.LayoutParams(0, LinearLayout.LayoutParams.WRAP_CONTENT, 1f)
            })
            addView(TextView(this@SaleHistoryActivity).apply {
                text = "+ New"
                textSize = 13f
                setTextColor(Color.parseColor(teal))
                setTypeface(typeface, android.graphics.Typeface.BOLD)
                setLeadingIcon(R.drawable.ic_add, teal, 14, 5)
                setOnClickListener {
                    startActivity(Intent(this@SaleHistoryActivity, SaleActivity::class.java))
                }
            })
        })

        // ADDED (Khatabook-style summary cards): Total Sales / Total Returned, same
        // visual language as PartyDashboardActivity's You'll Get/You'll Give cards.
        root.addView(buildSummaryCards())
        root.addView(spacer(16))

        // ADDED (Khatabook-style search box): filter the party-grouped list by
        // customer name, matching PartyDashboardActivity/PurchaseHistoryActivity.
        val searchBox = LinearLayout(this).apply {
            orientation = LinearLayout.HORIZONTAL
            gravity = Gravity.CENTER_VERTICAL
            setPadding(18, 8, 18, 8)
            background = strokedBg(border, cardWhite, 24)
            layoutParams = LinearLayout.LayoutParams(LinearLayout.LayoutParams.MATCH_PARENT, LinearLayout.LayoutParams.WRAP_CONTENT).apply { setMargins(0, 0, 0, 16) }
        }
        searchBox.addView(ImageView(this).apply { setImageDrawable(tintedDrawable(R.drawable.ic_search, navy, 15)); setPadding(0, 0, 10, 0) })
        searchField = EditText(this).apply {
            hint = "Search customer"
            background = null
            textSize = 13.5f
            setHintTextColor(Color.parseColor(textMuted))
            layoutParams = LinearLayout.LayoutParams(0, LinearLayout.LayoutParams.WRAP_CONTENT, 1f)
            addTextChangedListener(object : android.text.TextWatcher {
                override fun beforeTextChanged(s: CharSequence?, a: Int, b: Int, c: Int) {}
                override fun onTextChanged(s: CharSequence?, a: Int, b: Int, c: Int) { searchQuery = s?.toString().orEmpty(); rebuildRows() }
                override fun afterTextChanged(s: android.text.Editable?) {}
            })
        }
        searchBox.addView(searchField)
        root.addView(searchBox)

        recyclerView = RecyclerView(this).apply {
            layoutManager = LinearLayoutManager(this@SaleHistoryActivity)
            adapter = this@SaleHistoryActivity.adapter
            isNestedScrollingEnabled = false
            layoutParams = LinearLayout.LayoutParams(LinearLayout.LayoutParams.MATCH_PARENT, LinearLayout.LayoutParams.WRAP_CONTENT)
        }
        root.addView(recyclerView)

        emptyText = TextView(this).apply {
            text = "No sales yet."
            textSize = 14f
            setTextColor(Color.parseColor(textMuted))
            setPadding(4, 20, 4, 4)
            visibility = View.GONE
        }
        root.addView(emptyText)

        outer.addView(ScrollView(this).apply {
            setBackgroundColor(Color.parseColor(bg))
            addView(root)
        })
        setContentView(outer)
    }

    override fun onResume() {
        super.onResume()
        refresh()
    }

    // ADDED (Khatabook-style summary cards): two elevated cards side-by-side, same
    // layout as PartyDashboardActivity.buildSummaryCards()/summaryCard() — teal for
    // total sold, red for total returned across all sales.
    private fun buildSummaryCards(): LinearLayout {
        val row = LinearLayout(this).apply { orientation = LinearLayout.HORIZONTAL }

        val salesCard = summaryCard("\u2193", "Total Sales", teal)
        val returnedCard = summaryCard("\u2191", "Total Returned", red)
        totalSalesValue = salesCard.second
        totalReturnedValue = returnedCard.second

        salesCard.first.layoutParams = LinearLayout.LayoutParams(0, LinearLayout.LayoutParams.WRAP_CONTENT, 1f).apply { setMargins(0, 0, 8, 0) }
        returnedCard.first.layoutParams = LinearLayout.LayoutParams(0, LinearLayout.LayoutParams.WRAP_CONTENT, 1f).apply { setMargins(8, 0, 0, 0) }

        row.addView(salesCard.first)
        row.addView(returnedCard.first)
        return row
    }

    private fun summaryCard(arrow: String, label: String, accentHex: String): Pair<LinearLayout, TextView> {
        val card = LinearLayout(this).apply {
            orientation = LinearLayout.VERTICAL
            setPadding(20, 18, 20, 18)
            background = strokedBg(border, cardWhite, 16)
            applyElevation(this, 3f)
        }
        val topRow = LinearLayout(this).apply { orientation = LinearLayout.HORIZONTAL; gravity = Gravity.CENTER_VERTICAL }
        topRow.addView(TextView(this).apply {
            text = arrow
            setTextColor(Color.parseColor(accentHex))
            textSize = 14f
            setTypeface(typeface, android.graphics.Typeface.BOLD)
        })
        topRow.addView(TextView(this).apply {
            text = "  $label"
            setTextColor(Color.parseColor(textMuted))
            textSize = 12.5f
        })
        card.addView(topRow)
        val value = TextView(this).apply {
            text = "Rs 0"
            textSize = 19f
            setTypeface(typeface, android.graphics.Typeface.BOLD)
            setTextColor(Color.parseColor(textDark))
            setPadding(0, 8, 0, 0)
        }
        card.addView(value)
        return Pair(card, value)
    }

    private fun refresh() {
        lifecycleScope.launch {
            val db = PosDatabase.get(this@SaleHistoryActivity)
            val allSales = db.saleDao().allSales() // invoice, customerName, total, paymentMethod, createdAt, status
            // ---- Party-wise: grouped by customer, most recently active customer first ----
            groupedSales = allSales.groupBy { it.customerName }
                .toList()
                .sortedByDescending { (_, sales) -> sales.maxOf { it.createdAt } }

            // NEW (bill-wise profit): only fetched/shown for admins — cashiers never see
            // profit figures anywhere else in the app, so this stays consistent.
            saleProfits = if (isAdmin) {
                db.saleDao().allSaleProfits().associate { it.invoice to it.profit }
            } else emptyMap()

            // ADDED (Khatabook-style summary cards): active sales count toward Total
            // Sales; returned sales count toward Total Returned instead.
            totalSalesValue.text = "Rs %.2f".format(allSales.filter { it.status != "returned" }.sumOf { it.total })
            totalReturnedValue.text = "Rs %.2f".format(allSales.filter { it.status == "returned" }.sumOf { it.total })

            loadedItems.clear()
            emptyText.visibility = if (allSales.isEmpty()) View.VISIBLE else View.GONE
            rebuildRows()
        }
    }

    // Rebuilds the flat row list from the last-fetched groupedSales + current
    // expand/collapse state + whatever item rows are already cached — no DB hit.
    private fun rebuildRows() {
        val rows = mutableListOf<Row>()
        val q = searchQuery.trim().lowercase()
        groupedSales
            .filter { (customerName, _) -> q.isEmpty() || customerName.lowercase().contains(q) }
            .forEach { (customerName, sales) ->
            val customerTotal = sales.sumOf { it.total }
            val customerProfit = sales.sumOf { saleProfits[it.invoice] ?: 0.0 }
            rows.add(Row.Header(customerName, sales.size, customerTotal, customerProfit))
            sales.sortedByDescending { it.createdAt }.forEach { sale ->
                rows.add(Row.SaleRow(sale, saleProfits[sale.invoice]))
                if (expandedSales.contains(sale.invoice)) {
                    val items = loadedItems[sale.invoice]
                    if (items != null) {
                        if (items.isEmpty()) {
                            rows.add(Row.ItemsEmpty(sale.invoice))
                        } else {
                            items.forEach { si ->
                                rows.add(Row.ItemRow(sale.invoice, "${si.product}  —  ${si.qty} ${si.unit} × Rs ${si.unitPrice} = Rs %.2f".format(si.amount)))
                            }
                        }
                    }
                }
            }
        }
        adapter.submit(rows)
    }

    private fun customerHeader(name: String, count: Int, total: Double, profit: Double) = LinearLayout(this).apply {
        orientation = LinearLayout.VERTICAL
        setPadding(4, 18, 4, 8)
        addView(LinearLayout(this@SaleHistoryActivity).apply {
            orientation = LinearLayout.HORIZONTAL
            addView(TextView(this@SaleHistoryActivity).apply {
                text = name
                textSize = 15f
                setTextColor(Color.parseColor(textDark))
                setTypeface(typeface, android.graphics.Typeface.BOLD)
                layoutParams = LinearLayout.LayoutParams(0, LinearLayout.LayoutParams.WRAP_CONTENT, 1f)
            })
            addView(TextView(this@SaleHistoryActivity).apply {
                text = "$count sales · Rs %.2f".format(total)
                textSize = 12f
                setTextColor(Color.parseColor(textMuted))
            })
        })
        // NEW (bill-wise profit): total profit across this customer's bills, admin-only.
        if (isAdmin) {
            addView(TextView(this@SaleHistoryActivity).apply {
                text = "Profit: Rs %.2f".format(profit)
                textSize = 11.5f
                setTextColor(Color.parseColor(teal))
                setTypeface(typeface, android.graphics.Typeface.BOLD)
                setPadding(0, 2, 0, 0)
            })
        }
    }

    // ---- Invoice number is intentionally never shown — date is the visible identifier ----
    // profit is null when this user isn't admin (see isAdmin) or the sale was returned —
    // either way, no profit line is shown for the bill.
    private fun saleRow(sale: SaleWithCustomer, profit: Double?) = outlinedBox().apply {
        orientation = LinearLayout.HORIZONTAL
        gravity = Gravity.CENTER_VERTICAL
        setOnClickListener { toggleSale(sale.invoice) }

        addView(LinearLayout(this@SaleHistoryActivity).apply {
            orientation = LinearLayout.VERTICAL
            layoutParams = LinearLayout.LayoutParams(0, LinearLayout.LayoutParams.WRAP_CONTENT, 1f)
            addView(TextView(this@SaleHistoryActivity).apply {
                text = formatDate(sale.createdAt)
                textSize = 13.5f
                setTextColor(Color.parseColor(textDark))
                setTypeface(typeface, android.graphics.Typeface.BOLD)
            })
            addView(TextView(this@SaleHistoryActivity).apply {
                text = if (sale.status == "returned") "Returned" else sale.paymentMethod.replaceFirstChar { it.uppercase() }
                textSize = 11f
                setTextColor(Color.parseColor(textMuted))
            })
        })
        addView(LinearLayout(this@SaleHistoryActivity).apply {
            orientation = LinearLayout.VERTICAL
            gravity = Gravity.END
            addView(TextView(this@SaleHistoryActivity).apply {
                text = "Rs %.2f".format(sale.total)
                textSize = 13f
                setTextColor(Color.parseColor(if (sale.status == "returned") red else teal))
                setTypeface(typeface, android.graphics.Typeface.BOLD)
            })
            // NEW (bill-wise profit): this specific bill's profit, admin-only.
            if (isAdmin && profit != null) {
                addView(TextView(this@SaleHistoryActivity).apply {
                    text = "Profit: Rs %.2f".format(profit)
                    textSize = 10.5f
                    setTextColor(Color.parseColor(textMuted))
                })
            }
        }.apply { setPadding(8, 0, 12, 0) })
        // ---- FIX (reprint bug): previously there was no way to print a sale again
        // after it was first saved — the row only toggled expand/collapse, and
        // Return/Delete were the only per-row actions. Added a Print icon that
        // pulls the full Sale + its items straight from the DB and opens
        // BillPreviewActivity directly, mirroring SaleActivity.openBillPreview()'s
        // extras/encoding exactly so the reprinted bill matches the original. ----
        addView(ImageView(this@SaleHistoryActivity).apply {
            setImageDrawable(tintedDrawable(R.drawable.ic_printer, navy, 16))
            setPadding(10, 0, 4, 0)
            setOnClickListener { printSale(sale.invoice) }
        })
        // NEW ("10/10 Sale screen" — mirrors PurchaseHistoryActivity's edit-to-correct
        // flow): previously Sale History had Print/Return/Delete but no way to fix a
        // mistake (wrong qty/rate) without deleting the whole sale and re-entering it.
        // Not shown on a returned sale — same as the Return icon below.
        if (sale.status != "returned") {
            addView(ImageView(this@SaleHistoryActivity).apply {
                setImageDrawable(tintedDrawable(R.drawable.ic_edit, teal, 16))
                setPadding(10, 0, 4, 0)
                setOnClickListener {
                    startActivity(Intent(this@SaleHistoryActivity, SaleActivity::class.java).apply {
                        putExtra(SaleActivity.EXTRA_INVOICE, sale.invoice)
                    })
                }
            })
        }
        if (sale.status != "returned") {
            addView(ImageView(this@SaleHistoryActivity).apply {
                setImageDrawable(tintedDrawable(R.drawable.ic_undo, teal, 16))
                setPadding(10, 0, 4, 0)
                setOnClickListener { confirmReturn(sale.invoice) }
            })
        }
        addView(ImageView(this@SaleHistoryActivity).apply {
            setImageDrawable(tintedDrawable(R.drawable.ic_delete, red, 16))
            setPadding(10, 0, 4, 0)
            setOnClickListener { confirmDelete(sale.invoice) }
        })
    }

    // ---- FIX (reprint bug) — see comment above the Print icon in saleRow(). ----
    private fun printSale(invoice: String) {
        lifecycleScope.launch {
            val db = PosDatabase.get(this@SaleHistoryActivity)
            val sale = db.saleDao().findSale(invoice) ?: return@launch
            val items = loadedItems[invoice] ?: db.saleDao().itemsForInvoice(invoice).also { loadedItems[invoice] = it }
            val customerName = groupedSales.firstOrNull { grp -> grp.second.any { it.invoice == invoice } }
                ?.second?.firstOrNull { it.invoice == invoice }?.customerName ?: ""

            val itemsEncoded = items.joinToString("\u0002") { item ->
                val qtyText = if (item.qty == item.qty.toLong().toDouble()) item.qty.toLong().toString() else item.qty.toString()
                listOf(item.product, qtyText, item.unit, item.unitPrice, item.amount).joinToString("\u0003")
            }

            val previewIntent = Intent(this@SaleHistoryActivity, BillPreviewActivity::class.java).apply {
                putExtra(BillPreviewActivity.EXTRA_TYPE, "sale")
                putExtra(BillPreviewActivity.EXTRA_REFERENCE, invoice)
                putExtra(BillPreviewActivity.EXTRA_PARTY_NAME, customerName)
                putExtra(BillPreviewActivity.EXTRA_PARTY_LABEL, "Customer")
                if (sale.customerId != null) putExtra(BillPreviewActivity.EXTRA_PARTY_ID, sale.customerId)
                putExtra(BillPreviewActivity.EXTRA_DATE_MILLIS, sale.createdAt)
                putExtra(BillPreviewActivity.EXTRA_SUBTOTAL, sale.subtotal)
                putExtra(BillPreviewActivity.EXTRA_DISCOUNT, sale.discount)
                putExtra(BillPreviewActivity.EXTRA_TOTAL, sale.total)
                putExtra(BillPreviewActivity.EXTRA_PAID, sale.paid)
                putExtra(BillPreviewActivity.EXTRA_PAYMENT_METHOD, sale.paymentMethod)
                putExtra(BillPreviewActivity.EXTRA_ITEMS_ENCODED, itemsEncoded)
            }
            startActivity(previewIntent)
        }
    }

    private fun itemLine(text: String, muted: Boolean) = TextView(this).apply {
        this.text = text
        textSize = 12f
        setTextColor(Color.parseColor(if (muted) textMuted else textDark))
        setPadding(28, 6, 4, 6)
    }

    private fun toggleSale(invoice: String) {
        if (expandedSales.contains(invoice)) {
            expandedSales.remove(invoice)
            rebuildRows()
        } else {
            expandedSales.add(invoice)
            rebuildRows() // shows the row expanded immediately; item rows fill in once loaded
            if (!loadedItems.containsKey(invoice)) loadSaleItems(invoice)
        }
    }

    private fun loadSaleItems(invoice: String) {
        lifecycleScope.launch {
            val db = PosDatabase.get(this@SaleHistoryActivity)
            val items = db.saleDao().itemsForInvoice(invoice)
            loadedItems[invoice] = items
            if (expandedSales.contains(invoice)) rebuildRows()
        }
    }

    private fun confirmReturn(invoice: String) {
        android.app.AlertDialog.Builder(this)
            .setTitle("Return sale")
            .setMessage("Return this sale? Stock will be added back and any outstanding customer balance from it will be reversed.")
            .setPositiveButton("Return") { _, _ -> returnSale(invoice) }
            .setNegativeButton("Cancel", null)
            .show()
    }

    // Mirrors HistoryActivity.returnSale() — same atomic transaction: stock reversal,
    // ReturnLine insert (so it shows up in Reports > Sale Returns), customer balance
    // reversal, and markReturned — kept in sync so both entry points behave identically.
    private fun returnSale(invoice: String) {
        lifecycleScope.launch {
            val db = PosDatabase.get(this@SaleHistoryActivity)
            val sale = db.saleDao().findSale(invoice) ?: return@launch
            if (sale.status == "returned") return@launch
            val items = db.saleDao().itemsForInvoice(invoice)

            db.withTransaction {
                items.forEach { si ->
                    val p = db.productDao().find(si.barcode)
                    val smallestQty = si.smallestQty(p)
                    SyncQueueHelper.increaseProductStock(db, si.barcode, smallestQty, "SALE_REVERSAL", invoice)
                    val returnId = db.returnDao().insert(ReturnLine(reference = invoice, type = "sale", barcode = si.barcode, qty = si.qty, amount = si.amount))
                    SyncQueueHelper.enqueueReturn(db, ReturnLine(id = returnId, reference = invoice, type = "sale", barcode = si.barcode, qty = si.qty, amount = si.amount))
                }
                // FIX (overpaid-bill → party balance gap): was `paid < total`, so returning an
                // overpaid sale (paid > total, credited to the customer as an advance) never
                // reversed that advance, permanently stranding it.
                val returnOutstanding = sale.total - sale.paid
                if (sale.customerId != null && kotlin.math.abs(returnOutstanding) > 0.009) {
                    SyncQueueHelper.adjustCustomerBalance(db, sale.customerId, -returnOutstanding)
                }
                // FIX (sale return had no visible effect in Cash Book/Day Book): used to
                // delete the sale's cash_transactions row outright, which erased the
                // original sale day's cash history AND left no trace of the return
                // happening today. Now records a dated reversal instead — see
                // SyncQueueHelper.reverseCashByReference()'s doc comment.
                SyncQueueHelper.reverseCashByReference(db, invoice, sale.paid, "OUT", "Sale Return")
                // FIX (audit): also refund/drop bill-linked payments — see HistoryActivity.returnSale().
                SyncQueueHelper.voidLinkedPayments(db, invoice, "OUT", "Sale Return")
                // FIX (returned sale never syncs to other devices — see HistoryActivity.
                // returnSale()'s matching comment): markReturned() was a raw SQL UPDATE
                // with no enqueueSale() afterward, so this status change never pushed.
                val returnedSale = sale.copy(status = "returned")
                db.saleDao().updateSale(returnedSale)
                SyncQueueHelper.enqueueSale(db, returnedSale)
            }

            SyncQueueHelper.trigger(this@SaleHistoryActivity)
            Toast.makeText(this@SaleHistoryActivity, "Sale returned", Toast.LENGTH_SHORT).show()
            refresh()
        }
    }

    private fun confirmDelete(invoice: String) {
        android.app.AlertDialog.Builder(this)
            .setTitle("Delete sale")
            .setMessage("Delete this sale? This will reverse its stock and customer balance changes. This can't be undone.")
            .setPositiveButton("Delete") { _, _ -> deleteSale(invoice) }
            .setNegativeButton("Cancel", null)
            .show()
    }

    // ---- FIX: stock reversal ab stored si.unit ke sath Product.toSmallestUnits()
    // (multiply-only) use karta hai — pehle `SyncQueueHelper.increaseProductStock(db, it.barcode, it.qty)`
    // primary-unit qty seedha smallest-unit stock mein add kar raha tha, jo unit-tier
    // products (secondary/tertiary unit wale) ke liye galat stock reverse karta tha.
    // Ab SaleActivity.deleteSale() / PurchaseActivity.reverseStockForItems() jaisa hi. ----
    // FIX (Phase 1 - Data Safety): all writes below now run as one atomic Room transaction
    // instead of separate sequential writes (same pattern as SaleActivity/HistoryActivity).
    private fun deleteSale(invoice: String) {
        lifecycleScope.launch {
            val db = PosDatabase.get(this@SaleHistoryActivity)
            val sale = db.saleDao().findSale(invoice) ?: return@launch
            val items = db.saleDao().itemsForInvoice(invoice)

            db.withTransaction {
                items.forEach { si ->
                    val p = db.productDao().find(si.barcode)
                    val smallestQty = si.smallestQty(p)
                    SyncQueueHelper.increaseProductStock(db, si.barcode, smallestQty, "SALE_REVERSAL", invoice)
                }

                // Reverse any outstanding balance this sale added to the customer.
                // FIX (overpaid-bill → party balance gap): was `outstanding > 0`, so deleting an
                // overpaid sale (outstanding negative — credited as an advance) never reversed it.
                val outstanding = sale.total - sale.paid
                if (sale.customerId != null && kotlin.math.abs(outstanding) > 0.009) {
                    SyncQueueHelper.adjustCustomerBalance(db, sale.customerId, -outstanding)
                }

                db.saleDao().deleteItems(invoice)
                db.saleDao().deleteSale(invoice)
                // FIX (deleted-payment-survives-sync bug — see RoomPurchaseRepository.
                // deletePurchase()'s matching comment): raw deleteByReference() calls
                // never enqueued the removal, leaving these rows behind on every other
                // device/Firestore even after the sale itself was gone here.
                SyncQueueHelper.deletePaymentsByReference(db, invoice)
                SyncQueueHelper.deleteCashTransactionsByReference(db, invoice)
                // FIX (audit): bill-linked payments would otherwise live on as orphan payments.
                SyncQueueHelper.voidLinkedPayments(db, invoice, null, "")
            }
            // FIX (deleted sale never disappears on other devices): this screen's
            // own delete path never enqueued a "sale" delete entry at all — mirrors
            // RoomSaleRepository.deleteSale()'s matching fix.
            SyncQueueHelper.enqueueDelete(db, "sale", SyncQueueHelper.saleEntityId(sale))
            SyncQueueHelper.trigger(this@SaleHistoryActivity)

            expandedSales.remove(invoice)
            loadedItems.remove(invoice)
            Toast.makeText(this@SaleHistoryActivity, "Sale deleted", Toast.LENGTH_SHORT).show()
            refresh()
        }
    }

    private fun outlinedBox() = LinearLayout(this).apply {
        setPadding(20, 14, 12, 14)
        background = strokedBg(border, cardWhite, 12)
        applyElevation(this, 2f)
        layoutParams = LinearLayout.LayoutParams(
            LinearLayout.LayoutParams.MATCH_PARENT, LinearLayout.LayoutParams.WRAP_CONTENT
        ).apply { setMargins(0, 0, 0, 8) }
    }

    private fun formatDate(millis: Long) =
        java.text.SimpleDateFormat("dd MMM yyyy, hh:mm a", java.util.Locale.getDefault()).format(java.util.Date(millis))
}

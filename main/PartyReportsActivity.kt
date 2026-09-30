package com.grocerypos.v11.ui
import com.grocerypos.v11.SyncQueueHelper

import android.graphics.Color
import android.graphics.Typeface
import android.graphics.drawable.GradientDrawable
import android.os.Build
import android.os.Bundle
import android.view.Gravity
import android.view.View
import android.view.ViewOutlineProvider
import android.widget.*
import androidx.appcompat.app.AlertDialog
import androidx.appcompat.app.AppCompatActivity
import androidx.lifecycle.lifecycleScope
// FIX (list truncation): RecyclerView import no longer needed here — see
// listContainer below for why this screen stopped using recyclerListView().
import com.grocerypos.v11.Customer
import com.grocerypos.v11.PosDatabase
import com.grocerypos.v11.R
import com.grocerypos.v11.Supplier
import com.grocerypos.v11.data.PartyRepository
import com.grocerypos.v11.util.Loc
import kotlinx.coroutines.flow.first
import kotlinx.coroutines.launch
import java.text.SimpleDateFormat
import java.util.Date
import java.util.Locale
import com.grocerypos.v11.ui.components.*

/**
 * ---- CHANGE (ultra-premium UI pass) ----
 * Restyled to match ReportsActivity / StockReportActivity exactly: same palette,
 * premiumHeader(), strokedBg cards with applyElevation(), same pill-tab treatment as
 * Reports' period filter, and the same summaryCard/listCard/navRow/plRow language.
 * This now reaches "andar tak" (all the way in) — every nested report dialog (Item
 * Report, Ledger, Payment History, Statement, Transactions, Profit & Loss) uses the
 * same card styling instead of the old plain AlertDialog rows.
 * No business logic changed — every DB query, calculation, and Dr/Cr/give-get sign
 * rule below is identical to before; only the view-building code changed.
 */
class PartyReportsActivity : AppCompatActivity() {

    // ================= PREMIUM PALETTE (shared with Reports / Stock Report) =================
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
    }

    // ---- Item #2 (RecyclerView migration): was a LinearLayout that
    // loadParties() addView()'d rows into directly; now a RecyclerView backed
    // by the shared ViewListAdapter (see UiHelpers.kt), so only on-screen
    // rows get inflated instead of the whole list living as permanent child
    // views. ----
    // FIX (list truncation): this was a RecyclerView built via recyclerListView()
    // (WRAP_CONTENT height, nested scrolling disabled, sized by the outer
    // ScrollView). With a long supplier/customer list that combo under-measures
    // on first layout — RecyclerView's wrap_content sizing inside a ScrollView
    // doesn't always re-request layout correctly when notifyDataSetChanged()
    // swaps in a bigger row set (loadParties() runs after the initial empty
    // layout pass), so the screen renders only however many rows fit the stale
    // measured height and neither the RecyclerView nor the outer ScrollView
    // scrolls past that point — this is what made suppliers past "Amir Gourmet"
    // (alphabetically, e.g. "Arfan Brothers") impossible to reach by scrolling,
    // even though the row itself was being added to the adapter's data.
    // PartyActivity's own Customers & Suppliers list never had this problem
    // because it's a plain LinearLayout inside a ScrollView — no wrap_content
    // RecyclerView measurement involved — so this screen now matches that
    // proven pattern instead.
    private lateinit var listContainer: LinearLayout
    private lateinit var customersTab: TextView
    private lateinit var suppliersTab: TextView
    private var showingCustomers = true

    data class ItemAgg(val product: String, val qty: Double, val amount: Double)

    // ---- Used by Payment History. There's no dedicated Payment/installment table in
    // the current schema, so each sale/purchase's `paid` field is treated as a single
    // payment entry dated at the transaction's createdAt. If a separate payments/
    // installments table gets added later, swap the two loops in showPaymentHistory()
    // to read from it instead. ----
    data class PaymentEntry(val date: Long, val amount: Double, val against: String)

    override fun onCreate(b: Bundle?) {
        super.onCreate(b)
        loadThemeColors()

        val root = LinearLayout(this).apply {
            orientation = LinearLayout.VERTICAL
            setPadding(24, 48, 24, 24)
            setBackgroundColor(Color.parseColor(bg))
        }

        root.addView(premiumHeader(R.drawable.ic_people, Loc.t(this, "Party Reports", "پارٹی رپورٹس"), Loc.t(this, "Customer & supplier balances", "کسٹمر اور سپلائر کا بیلنس")))

        // ================= TAB PILLS (matches Reports' period-filter row) =================
        val tabRow = LinearLayout(this).apply {
            orientation = LinearLayout.HORIZONTAL
            background = strokedBg(border, cardBg, 14)
            setPadding(6, 6, 6, 6)
            layoutParams = LinearLayout.LayoutParams(LinearLayout.LayoutParams.MATCH_PARENT, LinearLayout.LayoutParams.WRAP_CONTENT)
                .apply { setMargins(0, 0, 0, 16) }
        }
        customersTab = filterPill(Loc.t(this, "CUSTOMERS", "کسٹمرز")) { showingCustomers = true; refreshTabs(); loadParties() }
        suppliersTab = filterPill(Loc.t(this, "SUPPLIERS", "سپلائرز")) { showingCustomers = false; refreshTabs(); loadParties() }
        tabRow.addView(customersTab)
        tabRow.addView(suppliersTab)
        root.addView(tabRow)

        root.addView(sectionHeader(Loc.t(this, "Tap a party to select a report", "رپورٹ منتخب کرنے کے لیے پارٹی پر ٹیپ کریں")))

        listContainer = LinearLayout(this).apply { orientation = LinearLayout.VERTICAL }
        root.addView(listContainer)
        root.addView(spacer(30))

        val scroll = ScrollView(this).apply {
            setBackgroundColor(Color.parseColor(bg))
            addView(root)
        }
        setContentView(scroll)

        refreshTabs()
        loadParties()
    }

    private fun refreshTabs() {
        if (showingCustomers) {
            customersTab.background = roundedBg(primary, 10)
            customersTab.setTextColor(Color.WHITE)
            suppliersTab.setBackgroundColor(Color.TRANSPARENT)
            suppliersTab.setTextColor(Color.parseColor(textGray))
        } else {
            suppliersTab.background = roundedBg(amber, 10)
            suppliersTab.setTextColor(Color.WHITE)
            customersTab.setBackgroundColor(Color.TRANSPARENT)
            customersTab.setTextColor(Color.parseColor(textGray))
        }
    }

    private fun loadParties() {
        lifecycleScope.launch {
            val db = PosDatabase.get(this@PartyReportsActivity)
            val rows = mutableListOf<View>()
            // PERMANENT FIX (balance drift — "paid supplier still shows You'll Get"):
            // closing read from PartyRepository's live ledger balance, not the stored,
            // driftable .balance field / totalPayable(). See
            // PartyRepository.liveCustomerBalances() for why.
            val partyRepo = PartyRepository(db, applicationContext)
            if (showingCustomers) {
                val customers = db.customerDao().all().first()
                val liveBal = partyRepo.liveCustomerBalances()
                if (customers.isEmpty()) rows.add(emptyText(Loc.t(this@PartyReportsActivity, "No customers yet", "کوئی کسٹمر نہیں ہے")))
                customers.forEach { c ->
                    // NEW (Stuck Balance): the list figure is the TOTAL payable (daily + stuck);
                    // for a customer with no stuck amount this is the same as before.
                    val closing = c.openingBalance + (liveBal[c.id] ?: 0.0) + c.stuckBalance
                    rows.add(partyRow(c.name, closing, isCustomer = true) {
                        showReportMenu(true, c.id, c.name, c.openingBalance, c.stuckBalance)
                    })
                }
            } else {
                val suppliers = db.supplierDao().all().first()
                val liveBal = partyRepo.liveSupplierBalances()
                if (suppliers.isEmpty()) rows.add(emptyText(Loc.t(this@PartyReportsActivity, "No suppliers yet", "کوئی سپلائر نہیں ہے")))
                suppliers.forEach { s ->
                    val closing = s.openingBalance + (liveBal[s.id] ?: 0.0)
                    rows.add(partyRow(s.name, closing, isCustomer = false) {
                        showReportMenu(false, s.id, s.name, s.openingBalance)
                    })
                }
            }
            listContainer.removeAllViews()
            rows.forEach { listContainer.addView(it) }
        }
    }

    // FIX (Phase 2 - Accounting): balance color is customer/supplier-aware (isCustomer
    // param) instead of coloring any positive balance the same — a positive customer
    // balance means they owe us (red/"give" convention elsewhere), but a positive
    // supplier balance means WE owe them, which previously showed the wrong color. Also
    // receives the closing balance (opening + running) instead of just the running
    // balance, matching PartyActivity/PartyDashboardActivity/MainActivity.
    private fun partyRow(name: String, closing: Double, isCustomer: Boolean, onClick: () -> Unit): LinearLayout {
        val isGive = if (isCustomer) closing < 0 else closing > 0
        val accentHex = if (isCustomer) primary else amber
        val tintHex = if (isCustomer) "#E9E6FF" else "#FFF3E0"
        return LinearLayout(this).apply {
            orientation = LinearLayout.HORIZONTAL
            gravity = Gravity.CENTER_VERTICAL
            setPadding(20, 18, 20, 18)
            background = strokedBg(border, cardBg, 18)
            layoutParams = LinearLayout.LayoutParams(
                LinearLayout.LayoutParams.MATCH_PARENT, LinearLayout.LayoutParams.WRAP_CONTENT
            ).apply { setMargins(0, 0, 0, 10) }
            applyElevation(this, 2f)
            isClickable = true
            setOnClickListener { onClick() }

            addView(iconCircle(if (isCustomer) R.drawable.ic_person else R.drawable.ic_box, accentHex, tintHex, 40))

            addView(TextView(this@PartyReportsActivity).apply {
                text = name
                textSize = 14.5f
                setTextColor(Color.parseColor(textDark))
                setTypeface(typeface, Typeface.BOLD)
                setPadding(16, 0, 8, 0)
                layoutParams = LinearLayout.LayoutParams(0, LinearLayout.LayoutParams.WRAP_CONTENT, 1f)
            })
            addView(TextView(this@PartyReportsActivity).apply {
                text = "Rs %.2f".format(closing)
                textSize = 13.5f
                setTextColor(Color.parseColor(if (isGive) red else teal))
                setTypeface(typeface, Typeface.BOLD)
            })
        }
    }

    // ---- Tap a party -> choose which report (custom-styled sheet, matches navRow list) ----
    private fun showReportMenu(isCustomer: Boolean, id: Long, name: String, opening: Double, stuck: Double = 0.0) {
        val plLabel = if (isCustomer)
            Loc.t(this, "Customer-wise Profit", "کسٹمر کے لحاظ سے منافع")
        else
            Loc.t(this, "Purchase Summary", "خریداری کا خلاصہ")

        val statementLabel = if (isCustomer)
            Loc.t(this, "Customer Statement", "کسٹمر اسٹیٹمنٹ")
        else
            Loc.t(this, "Supplier Statement", "سپلائر اسٹیٹمنٹ")

        val entries = listOf(
            Triple(R.drawable.ic_box, Loc.t(this, "Party Report by Item", "آئٹم کے لحاظ سے پارٹی رپورٹ"), 0),
            Triple(R.drawable.ic_book, Loc.t(this, "Customer Ledger", "کسٹمر لیجر"), 1),
            Triple(R.drawable.ic_wallet, Loc.t(this, "Payment History", "ادائیگی کی تاریخ"), 2),
            Triple(R.drawable.ic_document, statementLabel, 3),
            Triple(R.drawable.ic_receipt, Loc.t(this, "Sale/Purchase by Party", "پارٹی کے لحاظ سے سیل/خریداری"), 4),
            Triple(R.drawable.ic_chart, plLabel, 5)
        )

        val menuCard = LinearLayout(this).apply {
            orientation = LinearLayout.VERTICAL
            background = strokedBg(border, cardBg, 18)
            setPadding(6, 6, 6, 6)
            applyElevation(this, 3f)
        }
        val dialog = AlertDialog.Builder(this).setView(menuCard).create()

        entries.forEachIndexed { idx, (icon, label, which) ->
            menuCard.addView(navRow(icon, primary, "#E9E6FF", label, "") {
                dialog.dismiss()
                when (which) {
                    0 -> showItemReport(isCustomer, id, name)
                    1 -> showLedger(isCustomer, id, name, opening, stuck)
                    2 -> showPaymentHistory(isCustomer, id, name)
                    3 -> showStatement(isCustomer, id, name, opening, stuck)
                    4 -> showTransactions(isCustomer, id, name)
                    5 -> showPartyPL(isCustomer, id, name)
                }
            })
            if (idx != entries.lastIndex) menuCard.addView(navDivider())
        }

        dialog.setTitle(name)
        dialog.show()
    }

    // FIX (returned bills inflating every Party Report below): all six reports in
    // this file (Item Report, Ledger, Payment History, Statement, Transactions,
    // P&L) used to read salesByCustomer()/purchasesBySupplier() raw, with no
    // `.filter { it.status != "returned" }` — unlike the real balance field
    // (customer.balance/supplier.balance, adjusted correctly on return by
    // SyncQueueHelper.adjustCustomerBalance/adjustSupplierBalance) and unlike the
    // global reports (which already exclude returned via the DB queries'
    // `status!='returned'`). A returned bill's total/paid still don't change (only
    // its `status` does — see returnSale()), so a returned credit sale kept adding
    // its full total to a customer's Ledger/Statement closing balance forever,
    // making these per-party reports disagree with the real (correct) outstanding
    // balance shown everywhere else, and inflating per-party Revenue/Cost/Profit
    // and Item Report totals with items that were given back.
    // ================= 1) Party Report by Item =================
    private fun showItemReport(isCustomer: Boolean, id: Long, name: String) {
        lifecycleScope.launch {
            val db = PosDatabase.get(this@PartyReportsActivity)
            val items: List<ItemAgg> = if (isCustomer) {
                val sales = db.saleDao().salesByCustomer(id).filter { it.status != "returned" }
                val map = LinkedHashMap<String, ItemAgg>()
                sales.forEach { s ->
                    db.saleDao().itemsForInvoice(s.invoice).forEach { it ->
                        val ex = map[it.product]
                        map[it.product] = if (ex == null) ItemAgg(it.product, it.qty.toDouble(), it.amount)
                        else ItemAgg(it.product, ex.qty + it.qty.toDouble(), ex.amount + it.amount)
                    }
                }
                map.values.sortedByDescending { it.amount }
            } else {
                val purchases = db.purchaseDao().purchasesBySupplier(id).filter { it.status != "returned" }
                val map = LinkedHashMap<String, ItemAgg>()
                purchases.forEach { p ->
                    db.purchaseDao().itemsForBill(p.billNo).forEach { it ->
                        // FIX (item name "gayab" after sync): prefer the name
                        // snapshotted on this row; only fall back to the live
                        // product lookup for pre-migration rows.
                        val productName = it.itemName.ifBlank { db.productDao().find(it.barcode)?.name ?: it.barcode }
                        val ex = map[productName]
                        map[productName] = if (ex == null) ItemAgg(productName, it.qty.toDouble(), it.amount)
                        else ItemAgg(productName, ex.qty + it.qty.toDouble(), ex.amount + it.amount)
                    }
                }
                map.values.sortedByDescending { it.amount }
            }

            val content = reportContainer(R.drawable.ic_box, primary, "#E9E6FF", Loc.t(this@PartyReportsActivity, "Item Report", "آئٹم رپورٹ"), name)
            val body = (content.getChildAt(1) as ScrollView).getChildAt(0) as LinearLayout
            if (items.isEmpty()) {
                body.addView(emptyText(Loc.t(this@PartyReportsActivity, "No items found", "کوئی آئٹم نہیں ملا")))
            } else {
                items.forEach { i -> body.addView(rowText(i.product, "${formatQty(i.qty)} × — Rs %.2f".format(i.amount))) }
            }
            AlertDialog.Builder(this@PartyReportsActivity)
                .setView(content)
                .setPositiveButton(Loc.t(this@PartyReportsActivity, "Close", "بند کریں"), null)
                .show()
        }
    }

    // ================= 2) Customer / Supplier Ledger (Dr / Cr table) =================
    // Classic accounting ledger: every transaction posts a Debit (sale/purchase total)
    // and a Credit (amount paid at that time) with a running balance carried forward.
    // This is more detailed than the Statement below — it shows Dr and Cr side by side
    // per entry instead of just the net outstanding change.
    private fun showLedger(isCustomer: Boolean, id: Long, name: String, opening: Double, stuck: Double = 0.0) {
        lifecycleScope.launch {
            val db = PosDatabase.get(this@PartyReportsActivity)
            val fmt = SimpleDateFormat("dd MMM yyyy", Locale.getDefault())
            var running = opening

            val content = reportContainer(R.drawable.ic_book, primary, "#E9E6FF", Loc.t(this@PartyReportsActivity, "Ledger", "لیجر"), name)
            val body = (content.getChildAt(1) as ScrollView).getChildAt(0) as LinearLayout

            body.addView(ledgerHeaderRow())
            body.addView(plDivider())

            body.addView(
                ledgerRow(
                    Loc.t(this@PartyReportsActivity, "Opening Balance", "ابتدائی بیلنس"),
                    dr = if (opening > 0) opening else 0.0,
                    cr = if (opening < 0) -opening else 0.0,
                    balance = running,
                    bold = true
                )
            )

            // FIX (Ledger missing general payments — Audit finding): a payment recorded
            // WITHOUT linking it to a specific bill (PartyTransactionActivity's optional
            // "Link to a bill" left on "no bill" — see Payment.billReference's doc
            // comment) still correctly adjusts customer.balance/supplier.balance (so
            // Balance Sheet/Party list/Dashboard all stay right), but this screen used to
            // reconstruct its running balance purely from each bill's total/paid — so a
            // general payment never showed as a row here and the Closing Balance drifted
            // away from the party's real balance shown everywhere else. Bill-LINKED
            // payments are deliberately excluded from this merge (billReference.isBlank()
            // filter) since those are already folded into the linked bill's own `paid`
            // field below and would otherwise be double-counted.
            data class LedgerLine(val time: Long, val dr: Double, val cr: Double, val delta: Double)
            val lines = mutableListOf<LedgerLine>()
            val partyType = if (isCustomer) "customer" else "supplier"
            // FIX (audit — bug introduced by the fix above): billReference.isBlank() alone also
            // lets through the bill-EMBEDDED "Purchase payment" row (reference == billNo), which
            // is already the bill's own `paid`. Suppliers' ledger therefore counted every
            // purchase payment twice and the Closing Balance came out too low. Exclude any row
            // whose reference is one of this party's own bills.
            val ownBillIds: Set<String> = if (isCustomer) db.saleDao().salesByCustomer(id).map { it.invoice }.toHashSet()
                else db.purchaseDao().purchasesBySupplier(id).map { it.billNo }.toHashSet()
            val generalPayments = db.paymentDao().listByParty(partyType, id)
                .filter { it.billReference.isBlank() && it.reference !in ownBillIds }

            if (isCustomer) {
                val sales = db.saleDao().salesByCustomer(id).filter { it.status != "returned" }
                sales.forEach { s -> lines.add(LedgerLine(s.createdAt, s.total, s.paid, s.total - s.paid)) }
            } else {
                val purchases = db.purchaseDao().purchasesBySupplier(id).filter { it.status != "returned" }
                purchases.forEach { p -> lines.add(LedgerLine(p.createdAt, p.total, p.paid, p.total - p.paid)) }
            }
            // A general payment is pure Credit (reduces what's owed either way) with no
            // Debit side — mirrors adjustCustomerBalance/adjustSupplierBalance(-amount)
            // in PartyTransactionActivity.savePayment().
            generalPayments.forEach { pay -> lines.add(LedgerLine(pay.createdAt, 0.0, pay.amount, -pay.amount)) }
            lines.sortBy { it.time }

            if (lines.isEmpty()) {
                body.addView(emptyText(Loc.t(this@PartyReportsActivity, "No transactions yet", "کوئی لین دین نہیں ہے")))
            }
            lines.forEach { ln ->
                running += ln.delta
                body.addView(ledgerRow(fmt.format(Date(ln.time)), dr = ln.dr, cr = ln.cr, balance = running))
            }

            body.addView(plDivider())
            // NEW (Stuck Balance): with a stuck amount the running column above is the DAILY
            // part only — label it so, then list Stuck and Total Payable underneath.
            val ledgerClosingLabel = if (stuck != 0.0) Loc.t(this@PartyReportsActivity, "Daily Payable", "روزانہ واجب الادا")
                else Loc.t(this@PartyReportsActivity, "Closing Balance", "اختتامی بیلنس")
            body.addView(rowText(ledgerClosingLabel, "Rs %.2f".format(running)).apply {
                (getChildAt(0) as TextView).setTypeface(null, Typeface.BOLD)
                (getChildAt(1) as TextView).setTextColor(Color.parseColor(if (running > 0) red else teal))
            })
            addStuckSummary(body, running, stuck, if (running + stuck > 0) red else teal)

            AlertDialog.Builder(this@PartyReportsActivity)
                .setView(content)
                .setPositiveButton(Loc.t(this@PartyReportsActivity, "Close", "بند کریں"), null)
                .show()
        }
    }

    // NEW (Stuck Balance): appends "Stuck (Purana)" and a bold "Total Payable" row under a
    // Ledger/Statement's (now "Daily Payable") closing row. No-op when stuck == 0.0, so
    // every ordinary customer and every supplier sees exactly the report they saw before.
    private fun addStuckSummary(body: LinearLayout, dailyClosing: Double, stuck: Double, totalColorHex: String) {
        if (stuck == 0.0) return
        body.addView(rowText(Loc.t(this, "Stuck (Purana)", "اسٹک (پرانا)"), "Rs %.2f".format(stuck)))
        body.addView(plDivider())
        body.addView(rowText(Loc.t(this, "Total Payable", "کل واجب الادا"), "Rs %.2f".format(dailyClosing + stuck)).apply {
            (getChildAt(0) as TextView).setTypeface(null, Typeface.BOLD)
            (getChildAt(1) as TextView).setTextColor(Color.parseColor(totalColorHex))
            (getChildAt(1) as TextView).setTypeface(null, Typeface.BOLD)
        })
    }

    private fun ledgerHeaderRow(): LinearLayout {
        return LinearLayout(this).apply {
            orientation = LinearLayout.HORIZONTAL
            setPadding(4, 2, 4, 8)
            addView(TextView(this@PartyReportsActivity).apply {
                text = Loc.t(this@PartyReportsActivity, "Date", "تاریخ")
                textSize = 11f
                setTextColor(Color.parseColor(textGray))
                setTypeface(typeface, Typeface.BOLD)
                layoutParams = LinearLayout.LayoutParams(0, LinearLayout.LayoutParams.WRAP_CONTENT, 1.4f)
            })
            addView(TextView(this@PartyReportsActivity).apply {
                text = Loc.t(this@PartyReportsActivity, "Debit", "ڈیبٹ")
                textSize = 11f
                gravity = Gravity.END
                setTextColor(Color.parseColor(red))
                setTypeface(typeface, Typeface.BOLD)
                layoutParams = LinearLayout.LayoutParams(0, LinearLayout.LayoutParams.WRAP_CONTENT, 1f)
            })
            addView(TextView(this@PartyReportsActivity).apply {
                text = Loc.t(this@PartyReportsActivity, "Credit", "کریڈٹ")
                textSize = 11f
                gravity = Gravity.END
                setTextColor(Color.parseColor(teal))
                setTypeface(typeface, Typeface.BOLD)
                layoutParams = LinearLayout.LayoutParams(0, LinearLayout.LayoutParams.WRAP_CONTENT, 1f)
                setPadding(12, 0, 0, 0)
            })
        }
    }

    private fun ledgerRow(date: String, dr: Double, cr: Double, balance: Double, bold: Boolean = false): LinearLayout {
        return LinearLayout(this).apply {
            orientation = LinearLayout.VERTICAL
            setPadding(4, 8, 4, 8)
            val top = LinearLayout(this@PartyReportsActivity).apply { orientation = LinearLayout.HORIZONTAL }
            top.addView(TextView(this@PartyReportsActivity).apply {
                text = date
                textSize = if (bold) 13.5f else 13f
                setTextColor(Color.parseColor(textDark))
                if (bold) setTypeface(typeface, Typeface.BOLD)
                layoutParams = LinearLayout.LayoutParams(0, LinearLayout.LayoutParams.WRAP_CONTENT, 1.4f)
            })
            top.addView(TextView(this@PartyReportsActivity).apply {
                text = if (dr > 0) "Rs %.2f".format(dr) else "—"
                textSize = 13f
                gravity = Gravity.END
                setTextColor(Color.parseColor(if (dr > 0) red else textGray))
                layoutParams = LinearLayout.LayoutParams(0, LinearLayout.LayoutParams.WRAP_CONTENT, 1f)
            })
            top.addView(TextView(this@PartyReportsActivity).apply {
                text = if (cr > 0) "Rs %.2f".format(cr) else "—"
                textSize = 13f
                gravity = Gravity.END
                setTextColor(Color.parseColor(if (cr > 0) teal else textGray))
                layoutParams = LinearLayout.LayoutParams(0, LinearLayout.LayoutParams.WRAP_CONTENT, 1f)
                setPadding(12, 0, 0, 0)
            })
            addView(top)
            addView(TextView(this@PartyReportsActivity).apply {
                text = Loc.t(this@PartyReportsActivity, "Balance", "بیلنس") + ": Rs %.2f".format(balance)
                textSize = 11.5f
                setTextColor(Color.parseColor(if (balance > 0) red else teal))
                setTypeface(typeface, Typeface.BOLD)
                setPadding(0, 3, 0, 0)
            })
        }
    }

    // ================= 3) Payment History =================
    // Reads each sale/purchase's `paid` amount as one payment entry dated at the
    // transaction's createdAt (see PaymentEntry doc comment above — there's no
    // separate installment/payment table in the current schema).
    private fun showPaymentHistory(isCustomer: Boolean, id: Long, name: String) {
        lifecycleScope.launch {
            val db = PosDatabase.get(this@PartyReportsActivity)
            val fmt = SimpleDateFormat("dd MMM yyyy, hh:mm a", Locale.getDefault())

            val content = reportContainer(R.drawable.ic_wallet, teal, "#E0F2F1", Loc.t(this@PartyReportsActivity, "Payment History", "ادائیگی کی تاریخ"), name)
            val body = (content.getChildAt(1) as ScrollView).getChildAt(0) as LinearLayout

            val payments = mutableListOf<PaymentEntry>()
            if (isCustomer) {
                db.saleDao().salesByCustomer(id).filter { it.status != "returned" }.forEach { s ->
                    if (s.paid > 0) payments.add(PaymentEntry(s.createdAt, s.paid, Loc.t(this@PartyReportsActivity, "Against Sale", "سیل کے مقابلے میں")))
                }
            } else {
                db.purchaseDao().purchasesBySupplier(id).filter { it.status != "returned" }.forEach { p ->
                    if (p.paid > 0) payments.add(PaymentEntry(p.createdAt, p.paid, Loc.t(this@PartyReportsActivity, "Against Purchase", "خریداری کے مقابلے میں")))
                }
            }
            payments.sortByDescending { it.date }

            if (payments.isEmpty()) {
                body.addView(emptyText(Loc.t(this@PartyReportsActivity, "No payments recorded yet", "ابھی تک کوئی ادائیگی درج نہیں ہوئی")))
            } else {
                var total = 0.0
                payments.forEach { pe ->
                    total += pe.amount
                    body.addView(paymentRow(fmt.format(Date(pe.date)), pe.against, pe.amount))
                }
                body.addView(plDivider())
                val totalLabel = if (isCustomer)
                    Loc.t(this@PartyReportsActivity, "Total Received", "کل موصول شدہ")
                else
                    Loc.t(this@PartyReportsActivity, "Total Paid", "کل ادا شدہ")
                body.addView(rowText(totalLabel, "Rs %.2f".format(total)).apply {
                    (getChildAt(0) as TextView).setTypeface(null, Typeface.BOLD)
                    (getChildAt(1) as TextView).setTextColor(Color.parseColor(teal))
                })
            }

            AlertDialog.Builder(this@PartyReportsActivity)
                .setView(content)
                .setPositiveButton(Loc.t(this@PartyReportsActivity, "Close", "بند کریں"), null)
                .show()
        }
    }

    private fun paymentRow(date: String, against: String, amount: Double): LinearLayout {
        return LinearLayout(this).apply {
            orientation = LinearLayout.HORIZONTAL
            gravity = Gravity.CENTER_VERTICAL
            setPadding(4, 10, 4, 10)

            addView(iconCircle(R.drawable.ic_wallet, teal, "#E0F2F1", 32))

            val col = LinearLayout(this@PartyReportsActivity).apply {
                orientation = LinearLayout.VERTICAL
                setPadding(14, 0, 8, 0)
                layoutParams = LinearLayout.LayoutParams(0, LinearLayout.LayoutParams.WRAP_CONTENT, 1f)
            }
            col.addView(TextView(this@PartyReportsActivity).apply {
                text = date
                textSize = 13f
                setTypeface(typeface, Typeface.BOLD)
                setTextColor(Color.parseColor(textDark))
            })
            col.addView(TextView(this@PartyReportsActivity).apply {
                text = against
                textSize = 11f
                setTextColor(Color.parseColor(textGray))
            })
            addView(col)

            addView(TextView(this@PartyReportsActivity).apply {
                text = "Rs %.2f".format(amount)
                textSize = 13.5f
                setTypeface(typeface, Typeface.BOLD)
                setTextColor(Color.parseColor(teal))
            })
        }
    }

    // ================= 4) Party Statement (running balance) =================
    private fun showStatement(isCustomer: Boolean, id: Long, name: String, opening: Double, stuck: Double = 0.0) {
        lifecycleScope.launch {
            val db = PosDatabase.get(this@PartyReportsActivity)
            val fmt = SimpleDateFormat("dd MMM yyyy", Locale.getDefault())
            var running = opening

            val content = reportContainer(R.drawable.ic_document, purple, "#F0EBFF", Loc.t(this@PartyReportsActivity, "Statement", "اسٹیٹمنٹ"), name)
            val body = (content.getChildAt(1) as ScrollView).getChildAt(0) as LinearLayout

            body.addView(rowText(Loc.t(this@PartyReportsActivity, "Opening Balance", "ابتدائی بیلنس"), "Rs %.2f".format(opening)).apply {
                (getChildAt(0) as TextView).setTypeface(null, Typeface.BOLD)
            })
            body.addView(plDivider())

            // FIX (Ledger/Statement missing general payments — Audit finding): same gap
            // and same fix as showLedger() above — a payment made WITHOUT linking it to a
            // specific bill correctly adjusts the party's real balance but used to be
            // invisible here, so the Closing Balance shown on this Statement drifted away
            // from the balance shown on the Party list/Dashboard/Balance Sheet. Bill-
            // linked payments stay excluded (billReference.isBlank() filter) since those
            // are already folded into their bill's own `paid` field below.
            data class StatementLine(val time: Long, val amount: Double, val delta: Double, val label: String)
            val lines = mutableListOf<StatementLine>()
            val partyType = if (isCustomer) "customer" else "supplier"
            // FIX (audit): same embedded-payment double count as showLedger() above.
            val ownBillIds: Set<String> = if (isCustomer) db.saleDao().salesByCustomer(id).map { it.invoice }.toHashSet()
                else db.purchaseDao().purchasesBySupplier(id).map { it.billNo }.toHashSet()
            val generalPayments = db.paymentDao().listByParty(partyType, id)
                .filter { it.billReference.isBlank() && it.reference !in ownBillIds }
            val paymentLabel = if (isCustomer) Loc.t(this@PartyReportsActivity, "Payment received", "ادائیگی وصول ہوئی") else Loc.t(this@PartyReportsActivity, "Payment made", "ادائیگی کی گئی")

            if (isCustomer) {
                val sales = db.saleDao().salesByCustomer(id).filter { it.status != "returned" }
                sales.forEach { s -> lines.add(StatementLine(s.createdAt, s.total, s.total - s.paid, "")) }
            } else {
                val purchases = db.purchaseDao().purchasesBySupplier(id).filter { it.status != "returned" }
                purchases.forEach { p -> lines.add(StatementLine(p.createdAt, p.total, p.total - p.paid, "")) }
            }
            generalPayments.forEach { pay -> lines.add(StatementLine(pay.createdAt, pay.amount, -pay.amount, paymentLabel)) }
            lines.sortBy { it.time }

            if (lines.isEmpty()) body.addView(emptyText(Loc.t(this@PartyReportsActivity, "No transactions yet", "کوئی لین دین نہیں ہے")))
            lines.forEach { ln ->
                running += ln.delta
                // ---- No invoice/bill number shown — date is the row's identifier ----
                body.addView(statementRow(fmt.format(Date(ln.time)), ln.amount, running, isCustomer = isCustomer, label = ln.label))
            }

            body.addView(plDivider())
            // FIX (Phase 2 - Accounting): closing-balance color is customer/supplier-aware
            // (a positive supplier balance means WE owe them, which is not the same "red"
            // meaning as a positive customer balance) — same isGive pattern used elsewhere.
            val closingIsGive = if (isCustomer) running < 0 else running > 0
            // NEW (Stuck Balance): same Daily / Stuck / Total split as the Ledger.
            val statementClosingLabel = if (stuck != 0.0) Loc.t(this@PartyReportsActivity, "Daily Payable", "روزانہ واجب الادا")
                else Loc.t(this@PartyReportsActivity, "Closing Balance", "اختتامی بیلنس")
            body.addView(rowText(statementClosingLabel, "Rs %.2f".format(running)).apply {
                (getChildAt(0) as TextView).setTypeface(null, Typeface.BOLD)
                (getChildAt(1) as TextView).setTextColor(Color.parseColor(if (closingIsGive) red else teal))
            })
            addStuckSummary(body, running, stuck, if (if (isCustomer) running + stuck < 0 else running + stuck > 0) red else teal)

            AlertDialog.Builder(this@PartyReportsActivity)
                .setView(content)
                .setPositiveButton(Loc.t(this@PartyReportsActivity, "Close", "بند کریں"), null)
                .show()
        }
    }

    // ---- Reference/invoice number removed — date is now the only identifier shown ----
    // FIX (Phase 2 - Accounting): added isCustomer so the per-row balance color follows
    // the same customer/supplier-aware convention as the Closing Balance above it.
    // FIX (Ledger/Statement missing general payments — Audit finding): added an
    // optional `label` so a general-payment row (see showStatement()'s merge) reads
    // distinctly from a bill row instead of looking like an identical, ambiguous
    // amount with the opposite effect on the running balance.
    private fun statementRow(date: String, total: Double, balanceAfter: Double, isCustomer: Boolean, label: String = ""): LinearLayout {
        val isGive = if (isCustomer) balanceAfter < 0 else balanceAfter > 0
        return LinearLayout(this).apply {
            orientation = LinearLayout.VERTICAL
            setPadding(4, 10, 4, 10)
            val top = LinearLayout(this@PartyReportsActivity).apply { orientation = LinearLayout.HORIZONTAL }
            top.addView(TextView(this@PartyReportsActivity).apply {
                text = date; textSize = 13f
                setTypeface(typeface, Typeface.BOLD)
                setTextColor(Color.parseColor(textDark))
                layoutParams = LinearLayout.LayoutParams(0, LinearLayout.LayoutParams.WRAP_CONTENT, 1f)
            })
            top.addView(TextView(this@PartyReportsActivity).apply {
                text = "Rs %.2f".format(total); textSize = 13f
                setTextColor(Color.parseColor(textGray))
            })
            addView(top)
            if (label.isNotEmpty()) {
                addView(TextView(this@PartyReportsActivity).apply {
                    text = label
                    textSize = 11f
                    setTextColor(Color.parseColor(textGray))
                    setPadding(0, 1, 0, 1)
                })
            }
            addView(TextView(this@PartyReportsActivity).apply {
                text = Loc.t(this@PartyReportsActivity, "Balance", "بیلنس") + ": Rs %.2f".format(balanceAfter)
                textSize = 12f
                setTextColor(Color.parseColor(if (isGive) red else teal))
                setTypeface(typeface, Typeface.BOLD)
            })
        }
    }

    // ================= 5) Sale/Purchase by Party (plain transaction list) =================
    private fun showTransactions(isCustomer: Boolean, id: Long, name: String) {
        lifecycleScope.launch {
            val db = PosDatabase.get(this@PartyReportsActivity)
            val fmt = SimpleDateFormat("dd MMM yyyy, hh:mm a", Locale.getDefault())

            val title = if (isCustomer) Loc.t(this@PartyReportsActivity, "Sales", "سیلز") else Loc.t(this@PartyReportsActivity, "Purchases", "خریداریاں")
            val content = reportContainer(R.drawable.ic_receipt, if (isCustomer) primary else amber, if (isCustomer) "#E9E6FF" else "#FFF3E0", title, name)
            val body = (content.getChildAt(1) as ScrollView).getChildAt(0) as LinearLayout

            if (isCustomer) {
                val sales = db.saleDao().salesByCustomer(id).filter { it.status != "returned" }.sortedByDescending { it.createdAt }
                if (sales.isEmpty()) body.addView(emptyText(Loc.t(this@PartyReportsActivity, "No sales yet", "کوئی سیل نہیں ہوئی")))
                var totalAmt = 0.0
                sales.forEach { s ->
                    totalAmt += s.total
                    // ---- Invoice number removed — date is the row's identifier ----
                    body.addView(rowText(fmt.format(Date(s.createdAt)), "Rs %.2f".format(s.total)))
                }
                body.addView(plDivider())
                body.addView(rowText(Loc.t(this@PartyReportsActivity, "Total", "کل"), "Rs %.2f".format(totalAmt)))
            } else {
                val purchases = db.purchaseDao().purchasesBySupplier(id).filter { it.status != "returned" }.sortedByDescending { it.createdAt }
                if (purchases.isEmpty()) body.addView(emptyText(Loc.t(this@PartyReportsActivity, "No purchases yet", "کوئی خریداری نہیں ہوئی")))
                var totalAmt = 0.0
                purchases.forEach { p ->
                    totalAmt += p.total
                    // ---- Bill number removed — date is the row's identifier ----
                    body.addView(rowText(fmt.format(Date(p.createdAt)), "Rs %.2f".format(p.total)))
                }
                body.addView(plDivider())
                body.addView(rowText(Loc.t(this@PartyReportsActivity, "Total", "کل"), "Rs %.2f".format(totalAmt)))
            }

            AlertDialog.Builder(this@PartyReportsActivity)
                .setView(content)
                .setPositiveButton(Loc.t(this@PartyReportsActivity, "Close", "بند کریں"), null)
                .show()
        }
    }

    // ================= 6) Profit & Loss =================
    // Customer: real profit (revenue - cost) from every item they've bought.
    // Supplier: no "profit" concept — show a purchase spend summary instead.
    private fun showPartyPL(isCustomer: Boolean, id: Long, name: String) {
        lifecycleScope.launch {
            val db = PosDatabase.get(this@PartyReportsActivity)
            val title = if (isCustomer) Loc.t(this@PartyReportsActivity, "Profit & Loss", "منافع اور نقصان") else Loc.t(this@PartyReportsActivity, "Purchase Summary", "خریداری کا خلاصہ")
            val content = reportContainer(R.drawable.ic_chart, teal, "#E0F2F1", title, name)
            val body = (content.getChildAt(1) as ScrollView).getChildAt(0) as LinearLayout

            if (isCustomer) {
                val sales = db.saleDao().salesByCustomer(id).filter { it.status != "returned" }
                if (sales.isEmpty()) {
                    body.addView(emptyText(Loc.t(this@PartyReportsActivity, "No sales yet", "کوئی سیل نہیں ہوئی")))
                } else {
                    var revenue = 0.0
                    var cost = 0.0
                    sales.forEach { s ->
                        db.saleDao().itemsForInvoice(s.invoice).forEach { it ->
                            revenue += it.amount
                            cost += it.cost
                        }
                    }
                    val profit = revenue - cost
                    val profitColor = if (profit >= 0) teal else red

                    body.addView(rowText(Loc.t(this@PartyReportsActivity, "Total Sales (bills)", "کل سیلز (بلز)"), "${sales.size}"))
                    body.addView(rowText(Loc.t(this@PartyReportsActivity, "Revenue", "آمدنی"), "Rs %.2f".format(revenue)))
                    body.addView(rowText(Loc.t(this@PartyReportsActivity, "Cost of Goods", "سامان کی لاگت"), "Rs %.2f".format(cost)))
                    body.addView(plDivider())
                    body.addView(rowText(if (profit >= 0) Loc.t(this@PartyReportsActivity, "Net Profit", "خالص منافع") else Loc.t(this@PartyReportsActivity, "Net Loss", "خالص نقصان"), "Rs %.2f".format(profit)).apply {
                        (getChildAt(0) as TextView).setTypeface(null, Typeface.BOLD)
                        (getChildAt(1) as TextView).setTextColor(Color.parseColor(profitColor))
                    })
                }
            } else {
                val purchases = db.purchaseDao().purchasesBySupplier(id).filter { it.status != "returned" }
                if (purchases.isEmpty()) {
                    body.addView(emptyText(Loc.t(this@PartyReportsActivity, "No purchases yet", "کوئی خریداری نہیں ہوئی")))
                } else {
                    val totalBills = purchases.size
                    val totalAmount = purchases.sumOf { it.total }
                    val totalPaid = purchases.sumOf { it.paid }
                    val totalDue = totalAmount - totalPaid

                    body.addView(rowText(Loc.t(this@PartyReportsActivity, "Total Bills", "کل بلز"), "$totalBills"))
                    body.addView(rowText(Loc.t(this@PartyReportsActivity, "Total Purchased", "کل خریداری"), "Rs %.2f".format(totalAmount)))
                    body.addView(rowText(Loc.t(this@PartyReportsActivity, "Total Paid", "کل ادائیگی"), "Rs %.2f".format(totalPaid)))
                    body.addView(plDivider())
                    body.addView(rowText(Loc.t(this@PartyReportsActivity, "Outstanding Due", "باقی واجب الادا"), "Rs %.2f".format(totalDue)).apply {
                        (getChildAt(0) as TextView).setTypeface(null, Typeface.BOLD)
                        (getChildAt(1) as TextView).setTextColor(Color.parseColor(if (totalDue > 0) red else teal))
                    })
                    body.addView(spacer(8))
                    body.addView(TextView(this@PartyReportsActivity).apply {
                        text = Loc.t(
                            this@PartyReportsActivity,
                            "Note: Suppliers don't have their own 'profit' — this is a purchase summary.",
                            "نوٹ: سپلائرز کا اپنا منافع نہیں ہوتا — یہ خریداری کا خلاصہ ہے۔"
                        )
                        textSize = 11.5f
                        setTextColor(Color.parseColor(textGray))
                        setPadding(0, 6, 0, 0)
                    })
                }
            }

            AlertDialog.Builder(this@PartyReportsActivity)
                .setView(content)
                .setPositiveButton(Loc.t(this@PartyReportsActivity, "Close", "بند کریں"), null)
                .show()
        }
    }

    // ---- shared dialog container: icon + title header (matches summaryCard/navRow icon
    // treatment) + scrollable body card. Keeps the same child order the show*() functions
    // above rely on — index 0 header, index 1 ScrollView wrapping the body LinearLayout —
    // so none of that access code had to change. ----
    private fun reportContainer(icon: Int, accentHex: String, tintHex: String, title: String, partyName: String): LinearLayout {
        val outer = LinearLayout(this).apply { orientation = LinearLayout.VERTICAL; setPadding(4, 4, 4, 4) }

        val headerRow = LinearLayout(this).apply {
            orientation = LinearLayout.HORIZONTAL
            gravity = Gravity.CENTER_VERTICAL
            setPadding(20, 20, 20, 12)
        }
        headerRow.addView(iconCircle(icon, accentHex, tintHex, 38))
        val headerCol = LinearLayout(this).apply {
            orientation = LinearLayout.VERTICAL
            setPadding(14, 0, 0, 0)
        }
        headerCol.addView(TextView(this).apply {
            text = title
            textSize = 16f
            setTextColor(Color.parseColor(textDark))
            setTypeface(typeface, Typeface.BOLD)
        })
        headerCol.addView(TextView(this).apply {
            text = partyName
            textSize = 12f
            setTextColor(Color.parseColor(accentHex))
            setTypeface(typeface, Typeface.BOLD)
            setPadding(0, 2, 0, 0)
        })
        headerRow.addView(headerCol)
        outer.addView(headerRow)

        val body = LinearLayout(this).apply {
            orientation = LinearLayout.VERTICAL
            setPadding(18, 14, 18, 14)
            background = strokedBg(border, cardBg, 16)
            applyElevation(this, 1f)
            layoutParams = LinearLayout.LayoutParams(LinearLayout.LayoutParams.MATCH_PARENT, LinearLayout.LayoutParams.WRAP_CONTENT).apply {
                setMargins(20, 0, 20, 20)
            }
        }
        val scroll = ScrollView(this).apply {
            layoutParams = LinearLayout.LayoutParams(
                LinearLayout.LayoutParams.MATCH_PARENT,
                (350 * resources.displayMetrics.density).toInt()
            )
            addView(body)
        }
        // outer.getChildAt(1) == this ScrollView, and its single child is `body` — the
        // show*() functions above rely on exactly that shape to reach the body container.
        outer.addView(scroll)
        return outer
    }

    private fun rowText(left: String, right: String): LinearLayout {
        return LinearLayout(this).apply {
            orientation = LinearLayout.HORIZONTAL
            setPadding(4, 8, 4, 8)
            addView(TextView(this@PartyReportsActivity).apply {
                text = left; textSize = 13.5f
                setTextColor(Color.parseColor(textDark))
                layoutParams = LinearLayout.LayoutParams(0, LinearLayout.LayoutParams.WRAP_CONTENT, 1f)
            })
            addView(TextView(this@PartyReportsActivity).apply {
                text = right; textSize = 13.5f; gravity = Gravity.END
                setTextColor(Color.parseColor(primary))
                setTypeface(typeface, Typeface.BOLD)
            })
        }
    }

    private fun plDivider(): View {
        return View(this).apply {
            setBackgroundColor(Color.parseColor(border))
            layoutParams = LinearLayout.LayoutParams(LinearLayout.LayoutParams.MATCH_PARENT, 2).apply {
                setMargins(0, 8, 0, 8)
            }
        }
    }

    private fun emptyText(text: String): TextView {
        return TextView(this).apply {
            this.text = text
            setTextColor(Color.parseColor(textGray))
            textSize = 13f
            setPadding(0, 6, 0, 6)
        }
    }

    // ---- REMOVED (code maintainability — DRY): shared via UiHelpers.kt now (see
    // comment there) — import com.grocerypos.v11.ui.components.*.

    // ================= PREMIUM HEADER (matches Reports/Stock Report exactly) =================

    // ---- Nav row (matches Reports' navRow used for Sale History / Party Reports / etc.) ----
    private fun navRow(
        icon: Int,
        accentHex: String,
        tintHex: String,
        title: String,
        subtitle: String,
        onClick: () -> Unit
    ): LinearLayout {
        return LinearLayout(this).apply {
            orientation = LinearLayout.HORIZONTAL
            gravity = Gravity.CENTER_VERTICAL
            setPadding(20, 18, 20, 18)
            isClickable = true
            isFocusable = true
            setOnClickListener { onClick() }

            addView(iconCircle(icon, accentHex, tintHex, 42))

            val textCol = LinearLayout(this@PartyReportsActivity).apply {
                orientation = LinearLayout.VERTICAL
                setPadding(16, 0, 8, 0)
                layoutParams = LinearLayout.LayoutParams(0, LinearLayout.LayoutParams.WRAP_CONTENT, 1f)
            }
            textCol.addView(TextView(this@PartyReportsActivity).apply {
                text = title
                textSize = 14.5f
                setTextColor(Color.parseColor(textDark))
                setTypeface(typeface, Typeface.BOLD)
            })
            if (subtitle.isNotBlank()) {
                textCol.addView(TextView(this@PartyReportsActivity).apply {
                    text = subtitle
                    textSize = 11.5f
                    setTextColor(Color.parseColor(textGray))
                    setPadding(0, 3, 0, 0)
                })
            }
            addView(textCol)

            addView(TextView(this@PartyReportsActivity).apply {
                text = "\u203A"
                textSize = 18f
                setTextColor(Color.parseColor(accentHex))
                setTypeface(typeface, Typeface.BOLD)
                setPadding(8, 0, 4, 0)
            })
        }
    }

    private fun navDivider(): View {
        return View(this).apply {
            setBackgroundColor(Color.parseColor(border))
            layoutParams = LinearLayout.LayoutParams(LinearLayout.LayoutParams.MATCH_PARENT, 1).apply {
                setMargins(20, 0, 20, 0)
            }
        }
    }

    private fun sectionHeader(title: String): TextView {
        return TextView(this).apply {
            text = title
            textSize = 12.5f
            setTextColor(Color.parseColor(textGray))
            setTypeface(typeface, Typeface.BOLD)
            setPadding(4, 0, 0, 10)
        }
    }

    private fun filterPill(label: String, onClick: () -> Unit): TextView {
        return TextView(this).apply {
            text = label
            textSize = 12f
            gravity = Gravity.CENTER
            setTypeface(typeface, Typeface.BOLD)
            setPadding(0, 20, 0, 20)
            layoutParams = LinearLayout.LayoutParams(0, LinearLayout.LayoutParams.WRAP_CONTENT, 1f)
            setOnClickListener { onClick() }
        }
    }

    // ================= SHARED UI HELPERS (matches Reports/Stock Report exactly) =================
    // ---- item-6 UI improvement pass: vector-icon circle badge, replaces the old emoji-in-a-
    // TextView pattern that was copy-pasted at every call site (partyRow, paymentRow,
    // reportContainer, navRow). Icon is tinted with accentHex so it reads clearly against the
    // light tintHex background, matching the badge treatment already used in ProductActivity. ----
    private fun tintedDrawable(iconRes: Int, tintHex: String, sizeDp: Int) =
        androidx.core.content.ContextCompat.getDrawable(this, iconRes)?.mutate()?.apply {
            setTint(Color.parseColor(tintHex))
            val px = (sizeDp * resources.displayMetrics.density).toInt()
            setBounds(0, 0, px, px)
        }

    private fun iconCircle(iconRes: Int, accentHex: String, tintHex: String, sizeDp: Int) = FrameLayout(this).apply {
        val size = (sizeDp * resources.displayMetrics.density).toInt()
        layoutParams = LinearLayout.LayoutParams(size, size)
        background = GradientDrawable().apply { shape = GradientDrawable.OVAL; setColor(Color.parseColor(tintHex)) }
        addView(ImageView(this@PartyReportsActivity).apply {
            setImageDrawable(tintedDrawable(iconRes, accentHex, (sizeDp * 0.5).toInt()))
            scaleType = ImageView.ScaleType.CENTER
            layoutParams = FrameLayout.LayoutParams(FrameLayout.LayoutParams.MATCH_PARENT, FrameLayout.LayoutParams.MATCH_PARENT)
        })
    }

    // spacer() now comes from the shared UiHelpers.kt (item #24 dedup) — was a
    // byte-identical private copy here before.
}

package com.grocerypos.v11.ui

import android.app.AlertDialog
import android.content.Intent
import android.graphics.Color
import android.graphics.Typeface
import android.graphics.drawable.GradientDrawable
import android.os.Build
import android.os.Bundle
import android.view.Gravity
import android.view.View
import android.view.ViewOutlineProvider
import android.widget.*
import androidx.appcompat.app.AppCompatActivity
import androidx.lifecycle.lifecycleScope
import androidx.room.withTransaction
import com.grocerypos.v11.PosDatabase
import com.grocerypos.v11.R
import com.grocerypos.v11.ReturnLine
import com.grocerypos.v11.SyncQueueHelper
import com.grocerypos.v11.data.PurchaseRepository
import com.grocerypos.v11.data.RoomPurchaseRepository
import com.grocerypos.v11.smallestUnitFactor
import com.grocerypos.v11.smallestQty
import com.grocerypos.v11.toSmallestUnits
import com.grocerypos.v11.util.Loc
import kotlinx.coroutines.launch
import java.text.SimpleDateFormat
import java.util.Date
import java.util.Locale
import com.grocerypos.v11.ui.components.*

/**
 * ---- CHANGE (ultra-premium UI pass) ----
 * Restyled to match ReportsActivity / StockReportActivity / BalanceSheetActivity /
 * PartyReportsActivity: same palette, premiumHeader(), strokedBg cards with
 * applyElevation(), pill tabs, and icon-badge rows — carried all the way into the
 * Sale/Purchase detail dialogs and their Close/Edit/Return/Delete action buttons.
 * No business logic changed: every DB call, the atomic withTransaction blocks for
 * return/delete, and the stock/cost reversal math are byte-for-byte the same as
 * before — only the view-building code changed.
 */
class HistoryActivity : AppCompatActivity() {

    // FIX (dedup, item #1): purchase delete now goes through PurchaseRepository —
    // this activity used to keep its own byte-for-byte copy of
    // reverseStockAndCostForItems()/deletePurchase() (see PurchaseRepository.kt),
    // which had already drifted from the original: it was missing the
    // SyncQueueHelper.enqueue()/trigger() calls after the transaction, so a
    // purchase deleted from this screen never synced the deletion elsewhere.
    // Routing through the repository's own deletePurchase() removes the copy
    // and the bug at the same time — one implementation to keep correct.
    private val purchaseRepository: PurchaseRepository by lazy {
        RoomPurchaseRepository(PosDatabase.get(this), applicationContext)
    }

    // NEW (P1 security — item #1, HistoryActivity Admin Lock): Sale/Purchase Edit,
    // Return and Delete require Admin. isAdmin() decides which buttons even render;
    // requireAdminOrAbort() is the action-level re-check (item #3) repeated right
    // before the actual DB write in each action function below.
    private fun isAdmin(): Boolean =
        getSharedPreferences("session", MODE_PRIVATE).getString("role", "cashier") == "admin"

    private fun requireAdminOrAbort(): Boolean {
        if (isAdmin()) return true
        Toast.makeText(this, Loc.t(this, "Sirf Admin ye action kar sakta hai", "صرف ایڈمن یہ عمل کر سکتا ہے"), Toast.LENGTH_LONG).show()
        return false
    }

    companion object {
        // ADDED: lets Reports link straight into Sale History or Purchase History
        // without an extra tap on the in-screen SALES/PURCHASES tabs.
        const val EXTRA_MODE = "history_mode"
        const val MODE_SALES = "sales"
        const val MODE_PURCHASES = "purchases"
    }

    // ================= PREMIUM PALETTE (shared with Reports / Stock / Balance Sheet) =================
    // Pulled from ThemeManager so this screen respects dark mode. Headers were two-tone
    // gradients (primary/primaryDark, gold/goldDark); now flat like the rest of the app.
    private var bg = "#F3F2FA"
    private var cardBg = "#FFFFFF"
    private var primary = "#1450C7"
    private var primaryDark = "#1450C7"
    private var amber = "#F5A524"
    private var teal = "#0F9B8E"
    private var gold = "#C9A24B"
    private var goldDark = "#C9A24B"
    private var red = "#E5484D"
    private var textDark = "#1A1A2E"
    private var textGray = "#8A8A9E"
    private var border = "#E7E5F3"
    private var purpleBg = "#E3ECFE"
    private var amberBg = "#F6EFDD"

    private fun loadThemeColors() {
        val p = com.grocerypos.v11.util.ThemeManager.palette(this)
        bg = p.bg
        cardBg = p.cardWhite
        primary = p.flatBlueFg
        primaryDark = p.flatBlueFg
        amber = p.flatAmberFg
        teal = p.flatTealFg
        gold = p.flatAmberFg
        goldDark = p.flatAmberFg
        red = p.red
        textDark = p.textDark
        textGray = p.textMuted
        border = p.border
        purpleBg = p.flatBlueBg
        amberBg = p.flatAmberBg
    }

    private lateinit var tabRow: LinearLayout
    private lateinit var salesTab: TextView
    private lateinit var purchasesTab: TextView
    private lateinit var listContainer: LinearLayout
    private var showingSales = true
    private var singleMode: String? = null
    private lateinit var headerBox: LinearLayout

    override fun onCreate(b: Bundle?) {
        super.onCreate(b)
        loadThemeColors()
        singleMode = intent.getStringExtra(EXTRA_MODE)

        val root = LinearLayout(this).apply {
            orientation = LinearLayout.VERTICAL
            setPadding(24, 48, 24, 24)
            setBackgroundColor(Color.parseColor(bg))
        }

        // CHANGE (dedicated Sale History / Purchase History screens): when opened from
        // the Reports "Sale History" or "Purchase History" tile, this is now a true
        // single-purpose screen — its own icon/title/gradient, no SALES/PURCHASES tab
        // switcher at all, so tapping one tile can never end up showing the other
        // list. The old combined tabbed view (both lists, switchable) is kept as the
        // fallback only for any code path that opens this Activity with no mode extra.
        headerBox = when (singleMode) {
            MODE_SALES -> premiumHeader(
                R.drawable.ic_receipt,
                Loc.t(this, "Sale History", "سیل کی تاریخ"),
                Loc.t(this, "View all sale transactions", "تمام سیل لین دین دیکھیں"),
                primary, primaryDark
            )
            MODE_PURCHASES -> premiumHeader(
                R.drawable.ic_cart,
                Loc.t(this, "Purchase History", "خریداری کی تاریخ"),
                Loc.t(this, "View all purchase transactions", "تمام خریداری لین دین دیکھیں"),
                gold, goldDark
            )
            else -> premiumHeader(
                R.drawable.ic_receipt,
                Loc.t(this, "Sale / Purchase History", "سیل / خریداری کی تاریخ"),
                Loc.t(this, "Tap any entry to view details", "تفصیل دیکھنے کے لیے کسی بھی اندراج پر ٹیپ کریں"),
                primary, primaryDark
            )
        }
        root.addView(headerBox)

        if (singleMode == null) {
            tabRow = LinearLayout(this).apply {
                orientation = LinearLayout.HORIZONTAL
                background = strokedBg(border, cardBg, 14)
                setPadding(6, 6, 6, 6)
                layoutParams = LinearLayout.LayoutParams(LinearLayout.LayoutParams.MATCH_PARENT, LinearLayout.LayoutParams.WRAP_CONTENT)
                    .apply { setMargins(0, 0, 0, 16) }
            }
            salesTab = filterPill(Loc.t(this, "SALES", "سیلز")) { showSales() }
            purchasesTab = filterPill(Loc.t(this, "PURCHASES", "خریداریاں")) { showPurchases() }
            tabRow.addView(salesTab)
            tabRow.addView(purchasesTab)
            root.addView(tabRow)
        }

        listContainer = LinearLayout(this).apply { orientation = LinearLayout.VERTICAL }
        root.addView(listContainer)
        root.addView(spacer(30))

        val scroll = ScrollView(this).apply {
            setBackgroundColor(Color.parseColor(bg))
            addView(root)
        }
        setContentView(scroll)

        if (singleMode == null) refreshTabs()
        // Land directly on the requested list (Sale History vs Purchase History) —
        // no extra tap on the tabs needed when opened from the new separate Reports tiles.
        if (singleMode == MODE_PURCHASES) showPurchases() else showSales()
    }

    override fun onResume() { super.onResume(); if (showingSales) loadSales() else loadPurchases() }

    private fun refreshTabs() {
        if (singleMode != null) return
        if (showingSales) {
            salesTab.background = roundedBg(primary, 10)
            salesTab.setTextColor(Color.WHITE)
            purchasesTab.setBackgroundColor(Color.TRANSPARENT)
            purchasesTab.setTextColor(Color.parseColor(textGray))
        } else {
            purchasesTab.background = roundedBg(teal, 10)
            purchasesTab.setTextColor(Color.WHITE)
            salesTab.setBackgroundColor(Color.TRANSPARENT)
            salesTab.setTextColor(Color.parseColor(textGray))
        }
    }

    private fun showSales() { showingSales = true; refreshTabs(); loadSales() }
    private fun showPurchases() { showingSales = false; refreshTabs(); loadPurchases() }

    // FIX (duplicate rows in Sale/Purchase History): onCreate() -> showSales() and onResume()
    // both call loadSales(), so two coroutines ran at once. Each did removeAllViews() and
    // THEN suspended again on allSaleProfits() before adding rows, so both cleared an empty
    // list and both then added the full list = every sale shown twice (admin only, random).
    // Now (1) a new load cancels the previous one, and (2) all DB work finishes BEFORE
    // removeAllViews(), so clear+add happens in one uninterrupted step on the main thread.
    private var loadJob: kotlinx.coroutines.Job? = null

    private fun loadSales() {
        loadJob?.cancel()
        loadJob = lifecycleScope.launch {
            val db = PosDatabase.get(this@HistoryActivity)
            val list = db.saleDao().allSales()
            // NEW (bill-wise profit): only fetched/shown for admins — cashiers never
            // see profit figures anywhere else in the app, so this stays consistent.
            val profits = if (isAdmin()) db.saleDao().allSaleProfits().associate { it.invoice to it.profit } else emptyMap()
            listContainer.removeAllViews()
            if (list.isEmpty()) { listContainer.addView(emptyText(Loc.t(this@HistoryActivity, "No sales yet", "کوئی سیل نہیں ہوئی"))); return@launch }
            val fmt = SimpleDateFormat("dd MMM yyyy, hh:mm a", Locale.getDefault())
            for (s in list) listContainer.addView(
                row(R.drawable.ic_receipt, s.invoice, s.customerName, s.total, fmt.format(Date(s.createdAt)), primary, purpleBg, s.status == "returned", profits[s.invoice]) { openSaleDetail(s.invoice) }
            )
        }
    }

    private fun loadPurchases() {
        loadJob?.cancel()
        loadJob = lifecycleScope.launch {
            val list = PosDatabase.get(this@HistoryActivity).purchaseDao().allPurchases()
            listContainer.removeAllViews()
            if (list.isEmpty()) { listContainer.addView(emptyText(Loc.t(this@HistoryActivity, "No purchases yet", "کوئی خریداری نہیں ہوئی"))); return@launch }
            val fmt = SimpleDateFormat("dd MMM yyyy, hh:mm a", Locale.getDefault())
            for (p in list) listContainer.addView(
                row(R.drawable.ic_cart, p.billNo, p.supplierName, p.total, fmt.format(Date(p.createdAt)), gold, amberBg, p.status == "returned") { openPurchaseDetail(p.billNo) }
            )
        }
    }

    private fun openSaleDetail(invoice: String) {
        lifecycleScope.launch {
            val db = PosDatabase.get(this@HistoryActivity)
            val sale = db.saleDao().findSale(invoice) ?: return@launch
            val items = db.saleDao().itemsForInvoice(invoice)
            val content = detailContainer(R.drawable.ic_receipt, primary, purpleBg, Loc.t(this@HistoryActivity, "Sale", "سیل"), invoice)
            // body now lives one level deeper, inside the ScrollView detailContainer() wraps it in.
            val body = (content.getChildAt(1) as ScrollView).getChildAt(0) as LinearLayout
            if (sale.status == "returned") body.addView(returnedBanner())
            body.addView(kv(Loc.t(this@HistoryActivity, "Total", "کل"), "Rs %.2f".format(sale.total)))
            body.addView(kv(Loc.t(this@HistoryActivity, "Paid", "ادا شدہ"), "Rs %.2f".format(sale.paid)))
            // NEW (bill-wise profit): this bill's own profit, admin-only, and only
            // when it hasn't been returned (a returned bill has no profit to show —
            // matches allSaleProfits()'s WHERE status != 'returned').
            if (isAdmin() && sale.status != "returned") {
                val profit = sale.total - items.sumOf { it.cost }
                body.addView(kv(Loc.t(this@HistoryActivity, "Profit", "منافع"), "Rs %.2f".format(profit)))
            }
            body.addView(spacer(12))
            body.addView(sectionTitle(Loc.t(this@HistoryActivity, "Items", "آئٹمز")))
            for (it in items) body.addView(itemRow(it.product, "${it.qty} x ${it.unitPrice}", "Rs %.2f".format(it.amount)))
            val dialog = AlertDialog.Builder(this@HistoryActivity).setView(content).create()
            val footer = content.getChildAt(2) as LinearLayout
            footer.addView(outlineButton(Loc.t(this@HistoryActivity, "Close", "بند کریں")) { dialog.dismiss() })
            if (sale.status != "returned" && isAdmin()) {
                footer.addView(spacerH(8))
                footer.addView(filledButton(Loc.t(this@HistoryActivity, "Return", "واپس"), amber) { returnSale(invoice); dialog.dismiss() })
                footer.addView(spacerH(8))
                footer.addView(filledButton(Loc.t(this@HistoryActivity, "Delete", "حذف کریں"), red) { deleteSale(invoice); dialog.dismiss() })
            }
            dialog.show()
        }
    }

    // ---- FIX: stock reversal now converts si.qty (stored in whatever unit was entered,
    // e.g. "dozen") to smallest-unit stock via Product.toSmallestUnits() before touching
    // stock, same as SaleActivity.deleteSale() / SaleHistoryActivity.deleteSale(). Previously
    // this called SyncQueueHelper.increaseProductStock(db, it.barcode, it.qty) directly, which added back the
    // raw entered-unit number as if it were already smallest units — wrong for any product
    // with a secondary/tertiary unit. ----
    // FIX (Phase 1 - Data Safety): stock increase + return-row insert + balance reversal +
    // markReturned are now one atomic transaction (previously separate sequential writes —
    // a crash partway through could leave stock/balance updated but the sale still "active",
    // or vice versa).
    // BUILD FIX: toSmallestUnits(...).roundToInt() is Int, but the `it.qty` fallback is a
    // Double (SaleItem.qty) — mixing them in `?:` produced an unresolved Number/Comparable
    // captured type that increase(barcode, Int) couldn't accept ("Argument type mismatch...
    // but 'kotlin.Int' was expected", :app:compileDebugKotlin failure). Fallback now rounds
    // it.qty to Int too, so both branches of the elvis are the same type.
    private fun returnSale(invoice: String) {
        lifecycleScope.launch {
            if (!requireAdminOrAbort()) return@launch
            val db = PosDatabase.get(this@HistoryActivity); val sale = db.saleDao().findSale(invoice) ?: return@launch; if (sale.status == "returned") return@launch
            val items = db.saleDao().itemsForInvoice(invoice)
            db.withTransaction {
                for (it in items) {
                    val p = db.productDao().find(it.barcode)
                    val smallestQty = it.smallestQty(p)
                    SyncQueueHelper.increaseProductStock(db, it.barcode, smallestQty, "SALE_REVERSAL", invoice)
                    val returnId = db.returnDao().insert(ReturnLine(reference = invoice, type = "sale", barcode = it.barcode, qty = it.qty.toDouble(), amount = it.amount))
                    SyncQueueHelper.enqueueReturn(db, ReturnLine(id = returnId, reference = invoice, type = "sale", barcode = it.barcode, qty = it.qty.toDouble(), amount = it.amount))
                }
                // FIX (overpaid-bill → party balance gap): was `paid < total`, so returning an
                // overpaid sale (paid > total, the excess credited to the customer as an advance —
                // see RoomSaleRepository.saveSale()'s matching comment) never reversed that
                // advance, permanently stranding it. Reversing on any nonzero outstanding (due OR
                // advance) keeps this symmetric with the repository-layer fix.
                val returnOutstanding = sale.total - sale.paid
                if (sale.customerId != null && kotlin.math.abs(returnOutstanding) > 0.009) SyncQueueHelper.adjustCustomerBalance(db, sale.customerId, -returnOutstanding)
                // FIX (sale return had no visible effect in Cash Book/Day Book — mirrors
                // SaleHistoryActivity.returnSale()'s matching fix): records a dated
                // reversal instead of deleting the original cash row outright.
                SyncQueueHelper.reverseCashByReference(db, invoice, sale.paid, "OUT", "Sale Return")
                // FIX (audit): sale.paid includes payments linked to this bill, but the reversal
                // above only sees the bill's own cash rows — refund those too and drop them.
                SyncQueueHelper.voidLinkedPayments(db, invoice, "OUT", "Sale Return")
                // FIX (returned sale never syncs to other devices): markReturned() was a
                // raw SQL UPDATE with no matching enqueueSale() afterward — same "bypasses
                // sync" class of bug as the whole-purchase-return fix above, just missing
                // the local-clobber half since nothing else touched this row afterward.
                // Using updateSale()+enqueueSale() (Room @Update on the actual entity)
                // instead makes the status change persist AND push like every other field.
                val returnedSale = sale.copy(status = "returned")
                db.saleDao().updateSale(returnedSale)
                SyncQueueHelper.enqueueSale(db, returnedSale)
            }
            SyncQueueHelper.trigger(this@HistoryActivity)
            loadSales()
        }
    }

    // FIX (Phase 1 - Data Safety): same atomic-transaction treatment as returnSale() above.
    // BUILD FIX: same Int/Double elvis mismatch as returnSale() above — fallback now rounds
    // it.qty to Int.
    private fun deleteSale(invoice: String) {
        lifecycleScope.launch {
            if (!requireAdminOrAbort()) return@launch
            val db = PosDatabase.get(this@HistoryActivity); val sale = db.saleDao().findSale(invoice) ?: return@launch
            val items = db.saleDao().itemsForInvoice(invoice)
            db.withTransaction {
                for (it in items) {
                    val p = db.productDao().find(it.barcode)
                    val smallestQty = it.smallestQty(p)
                    SyncQueueHelper.increaseProductStock(db, it.barcode, smallestQty, "SALE_REVERSAL", invoice)
                }
                // FIX (overpaid-bill → party balance gap): same reasoning as returnSale() above —
                // was `paid < total`, so deleting an overpaid sale never reversed its advance.
                val deleteOutstanding = sale.total - sale.paid
                if (sale.customerId != null && kotlin.math.abs(deleteOutstanding) > 0.009) SyncQueueHelper.adjustCustomerBalance(db, sale.customerId, -deleteOutstanding)
                SyncQueueHelper.deleteCashTransactionsByReference(db, invoice); db.saleDao().deleteItems(invoice); db.saleDao().deleteSale(invoice)
                // FIX (audit): bill-linked payments would otherwise live on as orphan payments.
                SyncQueueHelper.voidLinkedPayments(db, invoice, null, "")
            }
            // FIX (deleted sale never disappears on other devices): this delete path
            // never enqueued a "sale" delete entry at all — mirrors RoomSaleRepository.
            // deleteSale()'s matching fix.
            SyncQueueHelper.enqueueDelete(db, "sale", SyncQueueHelper.saleEntityId(sale))
            SyncQueueHelper.trigger(this@HistoryActivity)
            loadSales()
        }
    }

    private fun openPurchaseDetail(billNo: String) {
        lifecycleScope.launch {
            val db = PosDatabase.get(this@HistoryActivity)
            val purchase = db.purchaseDao().findPurchase(billNo) ?: return@launch
            val items = db.purchaseDao().itemsForBill(billNo)
            val content = detailContainer(R.drawable.ic_cart, gold, amberBg, Loc.t(this@HistoryActivity, "Purchase", "خریداری"), billNo)
            // body now lives one level deeper, inside the ScrollView detailContainer() wraps it in.
            val body = (content.getChildAt(1) as ScrollView).getChildAt(0) as LinearLayout
            if (purchase.status == "returned") body.addView(returnedBanner())
            body.addView(kv(Loc.t(this@HistoryActivity, "Total", "کل"), "Rs %.2f".format(purchase.total)))
            body.addView(kv(Loc.t(this@HistoryActivity, "Paid", "ادا شدہ"), "Rs %.2f".format(purchase.paid)))
            body.addView(spacer(12))
            body.addView(sectionTitle(Loc.t(this@HistoryActivity, "Items", "آئٹمز")))
            // ---- FIX: was showing the raw barcode (it.barcode) instead of the product name.
            // PurchaseItem only stores the barcode, so look up the product to get its name —
            // same pattern already used by PurchaseHistoryActivity.loadBillItems(). Falls back
            // to the barcode only if the product record itself is missing/deleted. ----
            for (it in items) {
                val product = db.productDao().find(it.barcode)
                // FIX (item name "gayab" after sync): prefer the name snapshotted on
                // this row; only fall back to the live product lookup for
                // pre-migration rows. See PurchaseItem.itemName's comment in Database.kt.
                val displayName = it.itemName.ifBlank { product?.name ?: it.barcode }
                val u = if (it.unit.isBlank()) "" else " ${it.unit}"
                body.addView(itemRow(displayName, "${it.qty}$u x ${it.unitCost}", "Rs %.2f".format(it.amount)))
            }
            val dialog = AlertDialog.Builder(this@HistoryActivity).setView(content).create()
            val footer = content.getChildAt(2) as LinearLayout
            footer.addView(outlineButton(Loc.t(this@HistoryActivity, "Close", "بند کریں")) { dialog.dismiss() })
            if (purchase.status != "returned" && isAdmin()) {
                footer.addView(spacerH(8))
                footer.addView(filledButton(Loc.t(this@HistoryActivity, "Edit", "ترمیم"), primary) {
                    dialog.dismiss()
                    startActivity(Intent(this@HistoryActivity, PurchaseActivity::class.java).putExtra(PurchaseActivity.EXTRA_BILL_NO, billNo))
                })
                footer.addView(spacerH(8))
                footer.addView(filledButton(Loc.t(this@HistoryActivity, "Return", "واپس"), amber) { dialog.dismiss(); openReturnPurchaseDialog(billNo, items) })
                footer.addView(spacerH(8))
                footer.addView(filledButton(Loc.t(this@HistoryActivity, "Delete", "حذف کریں"), red) { deletePurchase(billNo); dialog.dismiss() })
            }
            dialog.show()
        }
    }

    // FIX (partial purchase return): "Return" used to only offer returning the ENTIRE
    // bill in one shot, even when the actual issue was e.g. 3 of 10 units of one line
    // being faulty/short — there was no way to send back just those 3. This now opens a
    // per-line quantity picker so only the lines/quantities actually being sent back get
    // reversed — see processPartialReturn() below (mirrors
    // PurchaseHistoryActivity's identically-named fix). Returning the full qty on every
    // line still behaves exactly like the old whole-bill return.
    private fun openReturnPurchaseDialog(billNo: String, items: List<com.grocerypos.v11.PurchaseItem>) {
        lifecycleScope.launch {
            if (!requireAdminOrAbort()) return@launch
            val db = PosDatabase.get(this@HistoryActivity)
            if (items.isEmpty()) return@launch
            val rowMeta = items.map { item ->
                val product = db.productDao().find(item.barcode)
                // FIX (item name "gayab" after sync): prefer the name snapshotted on
                // this row; only fall back to the live product lookup for
                // pre-migration rows.
                Triple(item, item.itemName.ifBlank { product?.name ?: item.barcode }, item.unit.ifBlank { product?.unit ?: "" })
            }

            // FIX (dialog buttons hidden off-screen): capping just the item list's height
            // wasn't enough — on some devices the dialog's own title+message chrome plus an
            // uncapped list could still add up to taller than the screen, pushing the
            // Return/Cancel buttons out of view with no way to reach them. Now the ENTIRE
            // dialog (title, message, list, buttons) is one custom layout whose total height
            // is hard-capped to a share of the screen — the item list is the only part that
            // flexes/scrolls, so the button row at the bottom is always on-screen.
            val container = LinearLayout(this@HistoryActivity).apply {
                orientation = LinearLayout.VERTICAL
                setPadding(36, 8, 36, 8)
            }
            val fields = LinkedHashMap<Long, EditText>()
            for ((item, name, unit) in rowMeta) {
                val row = LinearLayout(this@HistoryActivity).apply {
                    orientation = LinearLayout.VERTICAL
                    setPadding(0, 14, 0, 14)
                }
                row.addView(TextView(this@HistoryActivity).apply {
                    text = name
                    textSize = 14f
                    setTypeface(typeface, Typeface.BOLD)
                    setTextColor(Color.parseColor(textDark))
                })
                row.addView(TextView(this@HistoryActivity).apply {
                    text = Loc.t(this@HistoryActivity, "Purchased: ${formatQty(item.qty)} $unit", "خریدی گئی مقدار: ${formatQty(item.qty)} $unit")
                    textSize = 12f
                    setTextColor(Color.parseColor(textGray))
                    setPadding(0, 2, 0, 8)
                })
                val input = EditText(this@HistoryActivity).apply {
                    hint = Loc.t(this@HistoryActivity, "Return qty (leave blank to skip)", "واپسی مقدار (چھوڑنے کے لیے خالی رکھیں)")
                    setHintTextColor(Color.parseColor(textGray))
                    setTextColor(Color.parseColor(textDark))
                    inputType = android.text.InputType.TYPE_CLASS_NUMBER or android.text.InputType.TYPE_NUMBER_FLAG_DECIMAL
                    background = strokedBg(border, cardBg, 10)
                    setPadding(22, 16, 22, 16)
                }
                fields[item.id] = input
                row.addView(input)
                container.addView(row)
            }

            val itemsScroll = ScrollView(this@HistoryActivity).apply {
                layoutParams = LinearLayout.LayoutParams(LinearLayout.LayoutParams.MATCH_PARENT, 0, 1f)
                addView(container)
            }

            val itemsById = rowMeta.associateBy({ it.first.id }, { it.first to it.second })

            val titleView = TextView(this@HistoryActivity).apply {
                text = Loc.t(this@HistoryActivity, "Return items", "آئٹمز واپس کریں")
                textSize = 18f
                setTypeface(typeface, Typeface.BOLD)
                setTextColor(Color.parseColor(textDark))
                setPadding(40, 32, 40, 8)
            }
            val messageView = TextView(this@HistoryActivity).apply {
                text = Loc.t(
                    this@HistoryActivity,
                    "Enter how many units of each item are being returned. Stock and supplier balance will be adjusted only for those quantities.",
                    "ہر آئٹم کی کتنی مقدار واپس ہو رہی ہے درج کریں۔ صرف انہی مقداروں کے مطابق اسٹاک اور سپلائر بیلنس ایڈجسٹ ہو گا۔"
                )
                textSize = 13f
                setTextColor(Color.parseColor(textGray))
                setPadding(40, 0, 40, 8)
            }

            val cancelBtn = outlineButton(Loc.t(this@HistoryActivity, "Cancel", "منسوخ کریں")) {}
            val returnBtn = filledButton(Loc.t(this@HistoryActivity, "Return", "واپسی"), amber) {}
            val footer = LinearLayout(this@HistoryActivity).apply {
                orientation = LinearLayout.HORIZONTAL
                setPadding(40, 16, 40, 32)
                addView(cancelBtn)
                addView(spacerH(12))
                addView(returnBtn)
            }

            val maxDialogHeightPx = (resources.displayMetrics.heightPixels * 0.82).toInt()
            val root = object : LinearLayout(this@HistoryActivity) {
                override fun onMeasure(widthMeasureSpec: Int, heightMeasureSpec: Int) {
                    val mode = View.MeasureSpec.getMode(heightMeasureSpec)
                    val size = View.MeasureSpec.getSize(heightMeasureSpec)
                    val cappedSize = if (mode == View.MeasureSpec.UNSPECIFIED) maxDialogHeightPx else size.coerceAtMost(maxDialogHeightPx)
                    val newMode = if (mode == View.MeasureSpec.UNSPECIFIED) View.MeasureSpec.AT_MOST else mode
                    super.onMeasure(widthMeasureSpec, View.MeasureSpec.makeMeasureSpec(cappedSize, newMode))
                }
            }.apply {
                orientation = LinearLayout.VERTICAL
                addView(titleView)
                addView(messageView)
                addView(itemsScroll)
                addView(footer)
            }

            val dialog = AlertDialog.Builder(this@HistoryActivity)
                .setView(root)
                .create()

            cancelBtn.setOnClickListener { dialog.dismiss() }
            returnBtn.setOnClickListener {
                val requested = LinkedHashMap<Long, Double>()
                var errorMsg: String? = null
                for ((id, field) in fields) {
                    val text = field.text.toString().trim()
                    if (text.isEmpty()) continue
                    val qty = text.toDoubleOrNull()
                    val (item, name) = itemsById[id] ?: continue
                    when {
                        qty == null || qty < 0 -> {
                            errorMsg = Loc.t(this@HistoryActivity, "Enter a valid quantity for \"$name\"", "\"$name\" کے لیے درست مقدار درج کریں")
                        }
                        qty == 0.0 -> { /* treated as skip */ }
                        qty > item.qty + 0.0001 -> {
                            errorMsg = Loc.t(
                                this@HistoryActivity,
                                "Return qty for \"$name\" can't exceed purchased qty (${formatQty(item.qty)})",
                                "\"$name\" کی واپسی مقدار خریدی گئی مقدار (${formatQty(item.qty)}) سے زیادہ نہیں ہو سکتی"
                            )
                        }
                        else -> requested[id] = qty
                    }
                    if (errorMsg != null) break
                }
                if (errorMsg != null) {
                    Toast.makeText(this@HistoryActivity, errorMsg, Toast.LENGTH_LONG).show()
                    return@setOnClickListener
                }
                if (requested.isEmpty()) {
                    Toast.makeText(this@HistoryActivity, Loc.t(this@HistoryActivity, "Enter a return quantity for at least one item", "کم از کم ایک آئٹم کے لیے واپسی مقدار درج کریں"), Toast.LENGTH_SHORT).show()
                    return@setOnClickListener
                }
                dialog.dismiss()
                processPartialReturn(billNo, requested)
            }
            dialog.show()
        }
    }

    // ---- REMOVED (code maintainability — DRY): this was a byte-identical copy of
    // formatQty() duplicated across 6 files; now shared via UiHelpers.kt (see comment
    // there) — import com.grocerypos.v11.ui.components.*.

    // Does the actual line-level return picked in openReturnPurchaseDialog() — see
    // PurchaseHistoryActivity.processPartialReturn() for the full reasoning (identical
    // logic, kept in sync so both entry points to Purchase History behave the same way).
    private fun processPartialReturn(billNo: String, requested: Map<Long, Double>) {
        lifecycleScope.launch {
            if (!requireAdminOrAbort()) return@launch
            val db = PosDatabase.get(this@HistoryActivity)
            try {
                db.withTransaction {
                    val purchase = db.purchaseDao().findPurchase(billNo) ?: return@withTransaction
                    if (purchase.status == "returned") return@withTransaction

                    var totalReturnedAmount = 0.0

                    for ((itemId, returnQty) in requested) {
                        if (returnQty <= 0.0) continue
                        val item = db.purchaseDao().findItem(itemId) ?: continue
                        val clampedQty = returnQty.coerceAtMost(item.qty)
                        if (clampedQty <= 0.0) continue

                        val product = db.productDao().find(item.barcode)
                        val smallestQtyToRemove = partialSmallestQty(item, product, clampedQty)
                        val returnedAmount = if (item.qty > 0) item.amount * (clampedQty / item.qty) else item.unitCost * clampedQty

                        if (product != null && smallestQtyToRemove > 0) {
                            if (smallestQtyToRemove > product.stock) {
                                throw IllegalStateException(
                                    "\"${product.name}\" ka stock is purchase ke baad already kam ho chuka hai " +
                                    "(sale ya doosri entry se) — itni miqdaar wapas karna cost ko galat kar dega."
                                )
                            }
                            val newCost = reversePurchaseLineCostPartial(product, smallestQtyToRemove, returnedAmount)
                            SyncQueueHelper.decreaseProductStockForce(db, item.barcode, smallestQtyToRemove, "PURCHASE_RETURN", billNo, newCost)
                            SyncQueueHelper.updateProductCost(db, item.barcode, newCost)
                            db.productDao().find(item.barcode)?.let { p -> SyncQueueHelper.enqueueProduct(db, p) }
                        }

                        val returnId = db.returnDao().insert(ReturnLine(reference = billNo, type = "purchase", barcode = item.barcode, qty = clampedQty, amount = returnedAmount))
                        SyncQueueHelper.enqueueReturn(db, ReturnLine(id = returnId, reference = billNo, type = "purchase", barcode = item.barcode, qty = clampedQty, amount = returnedAmount))

                        val remainingQty = item.qty - clampedQty
                        if (remainingQty <= 0.0001) {
                            db.purchaseDao().deleteItemById(item.id)
                        } else {
                            db.purchaseDao().updateItemRow(item.copy(qty = remainingQty, amount = item.amount - returnedAmount))
                        }

                        totalReturnedAmount += returnedAmount
                    }

                    if (totalReturnedAmount <= 0.0) return@withTransaction

                    val remainingItemCount = db.purchaseDao().itemCountForBill(billNo)
                    val oldOutstanding = purchase.total - purchase.paid

                    if (remainingItemCount == 0) {
                        // Every line on the bill ended up fully returned — same end state
                        // as the old whole-bill returnPurchase().
                        // FIX (overpaid-bill → party balance gap): was `> 0`, so fully returning
                        // an overpaid purchase (oldOutstanding negative — the excess credited to
                        // the supplier as an advance) never reversed that advance.
                        if (purchase.supplierId != null && kotlin.math.abs(oldOutstanding) > 0.009) {
                            SyncQueueHelper.adjustSupplierBalance(db, purchase.supplierId, -oldOutstanding)
                        }
                        // FIX (purchase return had no visible effect in Cash Book/Day
                        // Book — mirrors the sale-return fix): a dated reversal instead
                        // of deleting the original cash row outright.
                        SyncQueueHelper.reverseCashByReference(db, billNo, purchase.paid, "IN", "Purchase Return")
                        SyncQueueHelper.deletePaymentsByReference(db, billNo)
                        // FIX (audit): also take back / drop payments linked to this bill.
                        SyncQueueHelper.voidLinkedPayments(db, billNo, "IN", "Purchase Return")
                        // FIX (whole-bill return silently un-returning itself — see
                        // PurchaseHistoryActivity's matching comment): the updatePurchase()
                        // @Update call right after markReturned() replaces the whole row
                        // using this in-memory copy, whose status was still "active" —
                        // clobbering the just-written "returned" back to "active" both
                        // locally and in what got synced. Set status on the copy instead.
                        val updatedPurchase = purchase.copy(
                            subtotal = (purchase.subtotal - totalReturnedAmount).coerceAtLeast(0.0),
                            total = (purchase.total - totalReturnedAmount).coerceAtLeast(0.0),
                            status = "returned"
                        )
                        db.purchaseDao().updatePurchase(updatedPurchase)
                        SyncQueueHelper.enqueuePurchase(db, updatedPurchase)
                    } else {
                        val newTotal = (purchase.total - totalReturnedAmount).coerceAtLeast(0.0)
                        val newPaid = reconcilePaidAfterReturn(db, billNo, purchase.paid, newTotal)
                        val updatedPurchase = purchase.copy(
                            subtotal = (purchase.subtotal - totalReturnedAmount).coerceAtLeast(0.0),
                            total = newTotal,
                            paid = newPaid
                        )
                        db.purchaseDao().updatePurchase(updatedPurchase)
                        if (purchase.supplierId != null) {
                            val newOutstanding = newTotal - newPaid
                            val delta = newOutstanding - oldOutstanding
                            if (delta != 0.0) SyncQueueHelper.adjustSupplierBalance(db, purchase.supplierId, delta)
                        }
                        SyncQueueHelper.enqueuePurchase(db, updatedPurchase)
                    }
                }
                loadPurchases()
            } catch (e: IllegalStateException) {
                Toast.makeText(this@HistoryActivity, e.message ?: "Return nahi ho saka", Toast.LENGTH_LONG).show()
            }
        }
    }

    // Same frozen-conversionFactor reasoning as PurchaseItem.smallestQty(product) in
    // Database.kt, but for a QUANTITY BEING RETURNED (which may be less than the
    // line's full qty) instead of the whole line.
    private fun partialSmallestQty(item: com.grocerypos.v11.PurchaseItem, product: com.grocerypos.v11.Product?, returnQty: Double): Double =
        if (item.conversionFactor > 0) returnQty * item.conversionFactor
        else product?.toSmallestUnits(returnQty, item.unit.ifBlank { product.unit }) ?: returnQty

    // Same weighted-average reversal math as PurchaseRepository's private
    // reverseStockAndCostForItems(), but taking the qty/amount to remove as
    // parameters so it can be used for a PARTIAL line return instead of always
    // reversing the whole line — no equivalent exists in PurchaseRepository since
    // it doesn't support partial returns.
    private fun reversePurchaseLineCostPartial(product: com.grocerypos.v11.Product, smallestQtyToRemove: Double, amountToRemove: Double): Double {
        if (smallestQtyToRemove <= 0) return product.cost
        val factor = product.smallestUnitFactor()
        val currentCostPerSmallest = if (factor > 0) product.cost / factor else product.cost
        val currentStock = product.stock
        val newStock = currentStock - smallestQtyToRemove
        val totalValueBefore = currentStock * currentCostPerSmallest
        val totalValueAfterRemoval = (totalValueBefore - amountToRemove).coerceAtLeast(0.0)
        val newCostPerSmallest = if (newStock > 0) totalValueAfterRemoval / newStock else 0.0
        return newCostPerSmallest * factor
    }

    // Same "cap paid at the new (smaller) total and shrink the linked cash/payment
    // record by the same amount" reasoning as PartyTransactionActivity's
    // reconcilePaidAndCashRecords(), scoped here to purchases only and to the
    // paid-can-only-go-down direction a return implies.
    private suspend fun reconcilePaidAfterReturn(db: PosDatabase, reference: String, oldPaid: Double, newTotal: Double): Double {
        val newPaid = oldPaid.coerceIn(0.0, newTotal.coerceAtLeast(0.0))
        val paidDelta = newPaid - oldPaid
        if (paidDelta == 0.0) return newPaid

        // FIX (partial purchase return had no visible effect in Cash Book/Day Book):
        // this used to shrink the original cash_transactions row's amount in place,
        // silently rewriting the ORIGINAL purchase day's cash history with no trace
        // of the return itself. Now records a dated reversal for the reduced amount
        // instead — see SyncQueueHelper.reverseCashByReference()'s doc comment.
        SyncQueueHelper.reverseCashByReference(db, reference, -paidDelta, "IN", "Purchase Return")
        db.paymentDao().findByReference(reference)?.let { pay ->
            val updatedPay = pay.copy(amount = (pay.amount + paidDelta).coerceAtLeast(0.0), updatedAt = System.currentTimeMillis(), dirty = true)
            db.paymentDao().update(updatedPay)
            SyncQueueHelper.enqueuePayment(db, updatedPay)
        }
        return newPaid
    }

    // FIX (dedup, item #1): delegates to PurchaseRepository.deletePurchase() instead
    // of reimplementing the reversal/delete transaction here — see the comment on
    // purchaseRepository above for why. Same negative-stock guard + Toast-on-refusal
    // as returnPurchase() above; PurchaseRepository throws the identical
    // IllegalStateException on a line that can't be reversed cleanly.
    private fun deletePurchase(billNo: String) {
        lifecycleScope.launch {
            if (!requireAdminOrAbort()) return@launch
            val db = PosDatabase.get(this@HistoryActivity)
            val purchase = db.purchaseDao().findPurchase(billNo) ?: return@launch
            val items = db.purchaseDao().itemsForBill(billNo)
            try {
                purchaseRepository.deletePurchase(billNo, purchase, items)
                loadPurchases()
            } catch (e: IllegalStateException) {
                Toast.makeText(this@HistoryActivity, e.message ?: "Delete nahi ho saka", Toast.LENGTH_LONG).show()
            }
        }
    }

    // ================= List row (matches summaryCard/navRow icon-badge treatment) =================
    private fun tintedDrawable(iconRes: Int, tintHex: String, sizeDp: Int = 16): android.graphics.drawable.Drawable? {
        val d = androidx.core.content.ContextCompat.getDrawable(this, iconRes)?.mutate() ?: return null
        d.setTint(Color.parseColor(tintHex))
        val px = (sizeDp * resources.displayMetrics.density).toInt()
        d.setBounds(0, 0, px, px)
        return d
    }

    private fun row(iconRes: Int, reference: String, subtitle: String, amount: Double, date: String, accentHex: String, tintHex: String, returned: Boolean, profit: Double? = null, onClick: () -> Unit): LinearLayout {
        return LinearLayout(this).apply {
            orientation = LinearLayout.HORIZONTAL
            gravity = Gravity.CENTER_VERTICAL
            setPadding(18, 16, 18, 16)
            background = strokedBg(border, cardBg, 18)
            layoutParams = LinearLayout.LayoutParams(LinearLayout.LayoutParams.MATCH_PARENT, LinearLayout.LayoutParams.WRAP_CONTENT)
                .apply { setMargins(0, 0, 0, 10) }
            applyElevation(this, 2f)
            isClickable = true
            setOnClickListener { onClick() }

            // NOTE: leading cart/receipt icon circle removed and the bill/invoice
            // number (reference) is no longer shown — the party name is now the
            // prominent bold line instead. See HistoryActivity chat request:
            // trolley icon aur purchase/invoice number hata kar name prominent
            // kiya gaya (same treatment for both Sale and Purchase rows since
            // they share this one row() renderer).
            val infoCol = LinearLayout(this@HistoryActivity).apply {
                orientation = LinearLayout.VERTICAL
                setPadding(0, 0, 8, 0)
                layoutParams = LinearLayout.LayoutParams(0, LinearLayout.LayoutParams.WRAP_CONTENT, 1f)
            }
            val nameRow = LinearLayout(this@HistoryActivity).apply { orientation = LinearLayout.HORIZONTAL; gravity = Gravity.CENTER_VERTICAL }
            nameRow.addView(TextView(this@HistoryActivity).apply {
                text = subtitle
                textSize = 15f
                setTypeface(typeface, Typeface.BOLD)
                setTextColor(Color.parseColor(textDark))
                layoutParams = LinearLayout.LayoutParams(0, LinearLayout.LayoutParams.WRAP_CONTENT, 1f)
            })
            if (returned) {
                nameRow.addView(TextView(this@HistoryActivity).apply {
                    text = Loc.t(this@HistoryActivity, "RETURNED", "واپس")
                    textSize = 10f
                    setTypeface(typeface, Typeface.BOLD)
                    setTextColor(Color.WHITE)
                    background = roundedBg(red, 8)
                    setPadding(12, 4, 12, 4)
                })
            }
            infoCol.addView(nameRow)
            infoCol.addView(TextView(this@HistoryActivity).apply {
                text = date
                textSize = 11.5f
                setTextColor(Color.parseColor(textGray))
                setPadding(0, 3, 0, 0)
            })
            addView(infoCol)

            addView(LinearLayout(this@HistoryActivity).apply {
                orientation = LinearLayout.VERTICAL
                gravity = Gravity.END
                addView(TextView(this@HistoryActivity).apply {
                    text = "Rs %.2f".format(amount)
                    textSize = 14f
                    setTypeface(typeface, Typeface.BOLD)
                    setTextColor(Color.parseColor(accentHex))
                })
                // NEW (bill-wise profit): this bill's own profit, admin-only.
                if (profit != null) {
                    addView(TextView(this@HistoryActivity).apply {
                        text = "Profit: Rs %.2f".format(profit)
                        textSize = 10.5f
                        setTextColor(Color.parseColor(textGray))
                    })
                }
            })
        }
    }

    // ================= Detail dialog shell =================
    // 3-child shape: index 0 = header, index 1 = a ScrollView wrapping body (get the
    // actual body LinearLayout via (getChildAt(1) as ScrollView).getChildAt(0), then
    // body.addView(...) as before), index 2 = footer (horizontal LinearLayout for the
    // action buttons).
    private fun detailContainer(iconRes: Int, accentHex: String, tintHex: String, kind: String, reference: String): LinearLayout {
        val header = LinearLayout(this).apply {
            orientation = LinearLayout.HORIZONTAL
            gravity = Gravity.CENTER_VERTICAL
            setPadding(24, 22, 24, 18)
        }
        header.addView(FrameLayout(this).apply {
            val size = (40 * resources.displayMetrics.density).toInt()
            layoutParams = LinearLayout.LayoutParams(size, size)
            background = GradientDrawable().apply { shape = GradientDrawable.OVAL; setColor(Color.parseColor(tintHex)) }
            addView(ImageView(this@HistoryActivity).apply {
                setImageDrawable(tintedDrawable(iconRes, accentHex, 18))
                scaleType = ImageView.ScaleType.CENTER
                layoutParams = FrameLayout.LayoutParams(FrameLayout.LayoutParams.MATCH_PARENT, FrameLayout.LayoutParams.MATCH_PARENT)
            })
        })
        val headerCol = LinearLayout(this).apply { orientation = LinearLayout.VERTICAL; setPadding(14, 0, 0, 0) }
        headerCol.addView(TextView(this).apply {
            text = kind
            textSize = 12f
            setTextColor(Color.parseColor(accentHex))
            setTypeface(typeface, Typeface.BOLD)
        })
        headerCol.addView(TextView(this).apply {
            text = reference
            textSize = 16f
            setTextColor(Color.parseColor(textDark))
            setTypeface(typeface, Typeface.BOLD)
            setPadding(0, 2, 0, 0)
        })
        header.addView(headerCol)

        val body = LinearLayout(this).apply {
            orientation = LinearLayout.VERTICAL
            setPadding(20, 16, 20, 12)
            background = strokedBg(border, cardBg, 16)
            applyElevation(this, 1f)
            layoutParams = LinearLayout.LayoutParams(LinearLayout.LayoutParams.MATCH_PARENT, LinearLayout.LayoutParams.WRAP_CONTENT)
        }

        // FIX (long sale/purchase bills cut off, not scrollable): body used to be added
        // straight into outer with WRAP_CONTENT height, so a bill with many item rows
        // just grew the AlertDialog past the screen — there was no ScrollView anywhere
        // in this tree, so the extra items were simply unreachable. Same class of bug
        // already fixed for the return-items dialog (see openReturnPurchaseDialog).
        // Now body sits inside a ScrollView that flexes/scrolls, and outer's total
        // height is hard-capped below so the header and footer buttons always stay
        // on screen no matter how many items a bill has.
        val bodyScroll = ScrollView(this).apply {
            layoutParams = LinearLayout.LayoutParams(LinearLayout.LayoutParams.MATCH_PARENT, 0, 1f)
                .apply { setMargins(20, 0, 20, 16) }
            addView(body)
        }

        val footer = LinearLayout(this).apply {
            orientation = LinearLayout.HORIZONTAL
            setPadding(20, 0, 20, 20)
        }

        val maxDialogHeightPx = (resources.displayMetrics.heightPixels * 0.82).toInt()
        val cappedOuter = object : LinearLayout(this) {
            override fun onMeasure(widthMeasureSpec: Int, heightMeasureSpec: Int) {
                val mode = View.MeasureSpec.getMode(heightMeasureSpec)
                val size = View.MeasureSpec.getSize(heightMeasureSpec)
                val cappedSize = if (mode == View.MeasureSpec.UNSPECIFIED) maxDialogHeightPx else size.coerceAtMost(maxDialogHeightPx)
                val newMode = if (mode == View.MeasureSpec.UNSPECIFIED) View.MeasureSpec.AT_MOST else mode
                super.onMeasure(widthMeasureSpec, View.MeasureSpec.makeMeasureSpec(cappedSize, newMode))
            }
        }.apply {
            orientation = LinearLayout.VERTICAL
            addView(header)
            addView(bodyScroll)
            addView(footer)
        }
        return cappedOuter
    }

    private fun returnedBanner() = LinearLayout(this).apply {
        setPadding(16, 10, 16, 10)
        background = strokedBg(red, "#FDE8E8", 10)
        layoutParams = LinearLayout.LayoutParams(LinearLayout.LayoutParams.MATCH_PARENT, LinearLayout.LayoutParams.WRAP_CONTENT).apply { setMargins(0, 0, 0, 14) }
        addView(TextView(this@HistoryActivity).apply {
            text = Loc.t(this@HistoryActivity, "RETURNED", "واپس")
            setTextColor(Color.parseColor(red))
            setTypeface(typeface, Typeface.BOLD)
            textSize = 12.5f
        })
    }

    private fun kv(l: String, v: String) = LinearLayout(this).apply {
        orientation = LinearLayout.HORIZONTAL
        setPadding(0, 6, 0, 6)
        addView(TextView(this@HistoryActivity).apply {
            text = l; textSize = 13.5f
            setTextColor(Color.parseColor(textGray))
            layoutParams = LinearLayout.LayoutParams(0, LinearLayout.LayoutParams.WRAP_CONTENT, 1f)
        })
        addView(TextView(this@HistoryActivity).apply {
            text = v; textSize = 13.5f
            setTextColor(Color.parseColor(textDark))
            setTypeface(typeface, Typeface.BOLD)
        })
    }

    private fun sectionTitle(t: String) = TextView(this).apply {
        text = t
        textSize = 13f
        setTextColor(Color.parseColor(textDark))
        setTypeface(typeface, Typeface.BOLD)
        setPadding(0, 0, 0, 6)
    }

    private fun itemRow(n: String, q: String, a: String) = LinearLayout(this).apply {
        orientation = LinearLayout.VERTICAL
        setPadding(0, 8, 0, 8)
        val top = LinearLayout(this@HistoryActivity).apply { orientation = LinearLayout.HORIZONTAL }
        top.addView(TextView(this@HistoryActivity).apply {
            text = n; textSize = 13.5f
            setTextColor(Color.parseColor(textDark))
            setTypeface(typeface, Typeface.BOLD)
            layoutParams = LinearLayout.LayoutParams(0, LinearLayout.LayoutParams.WRAP_CONTENT, 1f)
        })
        top.addView(TextView(this@HistoryActivity).apply {
            text = a; textSize = 13.5f
            setTextColor(Color.parseColor(primary))
            setTypeface(typeface, Typeface.BOLD)
        })
        addView(top)
        addView(TextView(this@HistoryActivity).apply {
            text = q; textSize = 11.5f
            setTextColor(Color.parseColor(textGray))
            setPadding(0, 2, 0, 0)
        })
        addView(rowDivider())
    }

    private fun rowDivider() = View(this).apply {
        setBackgroundColor(Color.parseColor(border))
        layoutParams = LinearLayout.LayoutParams(LinearLayout.LayoutParams.MATCH_PARENT, 1).apply { setMargins(0, 8, 0, 0) }
    }

    // CHANGE (ultimate premium look): replaced the plain gray placeholder text with an
    // icon-badge empty-state card matching the rest of the app's premium style.
    private fun emptyText(t: String): LinearLayout {
        val accentHex = if (showingSales) primary else gold
        val tintHex = if (showingSales) purpleBg else amberBg
        val iconRes = if (showingSales) R.drawable.ic_receipt else R.drawable.ic_cart
        return LinearLayout(this).apply {
            orientation = LinearLayout.VERTICAL
            gravity = Gravity.CENTER_HORIZONTAL
            setPadding(24, 60, 24, 40)
            addView(circleIconDrawable(iconRes, accentHex, tintHex, 64))
            addView(TextView(this@HistoryActivity).apply {
                text = t
                setTextColor(Color.parseColor(textDark))
                setTypeface(typeface, Typeface.BOLD)
                textSize = 14f
                gravity = Gravity.CENTER
                setPadding(0, 22, 0, 0)
            })
        }
    }

    private fun outlineButton(label: String, onClick: () -> Unit): TextView {
        return TextView(this).apply {
            text = label
            textSize = 13f
            gravity = Gravity.CENTER
            setTypeface(typeface, Typeface.BOLD)
            setTextColor(Color.parseColor(textGray))
            background = strokedBg(border, cardBg, 12)
            setPadding(0, 20, 0, 20)
            layoutParams = LinearLayout.LayoutParams(0, LinearLayout.LayoutParams.WRAP_CONTENT, 1f)
            setOnClickListener { onClick() }
        }
    }

    private fun filledButton(label: String, colorHex: String, onClick: () -> Unit): TextView {
        return TextView(this).apply {
            text = label
            textSize = 13f
            gravity = Gravity.CENTER
            setTypeface(typeface, Typeface.BOLD)
            setTextColor(Color.WHITE)
            background = roundedBg(colorHex, 12)
            setPadding(0, 20, 0, 20)
            layoutParams = LinearLayout.LayoutParams(0, LinearLayout.LayoutParams.WRAP_CONTENT, 1f)
            setOnClickListener { onClick() }
        }
    }

    private fun spacerH(widthDp: Int) = View(this).apply {
        layoutParams = LinearLayout.LayoutParams((widthDp * resources.displayMetrics.density).toInt(), 1)
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

    // ================= PREMIUM HEADER (matches Reports/Stock/Balance Sheet/Party Reports) =================

    // ================= SHARED UI HELPERS (matches Reports/Stock/Balance Sheet/Party Reports) =================
    // circleIcon() and spacer() now come from the shared PremiumHeader.kt/UiHelpers.kt
    // (item #24 dedup) — both were byte-identical private copies here before.
    // circleIconDrawable() below is a genuinely different overload (extra tintHex param)
    // not present in the shared file, so it stays local.

    // ---- Drawable-resource overload of circleIcon(), added alongside the original
    // emoji-string version so this one call site (empty-state badge) can move to a
    // vector icon without touching circleIcon()'s other behavior. ----
    private fun circleIconDrawable(iconRes: Int, tintHex: String, colorHex: String, sizeDp: Int) = ImageView(this).apply {
        setImageDrawable(tintedDrawable(iconRes, tintHex, (sizeDp * 0.4).toInt()))
        scaleType = ImageView.ScaleType.CENTER
        background = ovalBg(colorHex)
        val px = (sizeDp * resources.displayMetrics.density).toInt()
        layoutParams = android.view.ViewGroup.LayoutParams(px, px)
    }
}

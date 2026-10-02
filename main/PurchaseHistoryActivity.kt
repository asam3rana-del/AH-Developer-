package com.grocerypos.v11.ui
import com.grocerypos.v11.SyncQueueHelper

import com.grocerypos.v11.R

import android.content.Intent
import android.graphics.Color
import android.graphics.drawable.GradientDrawable
import android.os.Build
import android.os.Bundle
import android.text.Editable
import android.text.TextWatcher
import android.view.Gravity
import android.view.View
import android.view.ViewOutlineProvider
import android.widget.EditText
import android.widget.ImageView
import android.widget.LinearLayout
import android.widget.ScrollView
import android.widget.TextView
import android.widget.Toast
import androidx.lifecycle.lifecycleScope
import androidx.room.withTransaction
import com.grocerypos.v11.*
import com.grocerypos.v11.data.PurchaseRepository
import com.grocerypos.v11.data.RoomPurchaseRepository
import com.grocerypos.v11.util.ThemeManager
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.launch
import android.util.Log
import java.text.SimpleDateFormat
import java.util.Date
import java.util.Locale
import com.grocerypos.v11.ui.components.*

class PurchaseHistoryActivity : ThemedActivity() {

    companion object {
        private const val TAG = "PurchaseHistoryActivity"
    }

    // FIX (dedup, item #1): purchase delete now goes through PurchaseRepository —
    // this activity used to keep its own byte-for-byte copy of
    // reverseStockAndCostForItems()/deletePurchase() (see PurchaseRepository.kt and
    // HistoryActivity.kt, which had the identical copy), which had already drifted
    // from the original: it was missing the SyncQueueHelper.enqueue()/trigger()
    // calls after the transaction, so a purchase deleted from this screen never
    // synced the deletion elsewhere. Routing through the repository's own
    // deletePurchase() removes the copy and the bug at the same time.
    private val purchaseRepository: PurchaseRepository by lazy {
        RoomPurchaseRepository(PosDatabase.get(this), applicationContext)
    }

    // ---- Own inline copies of the premium styling helpers, mirroring how ProductActivity
    // keeps its own duplicated versions rather than sharing a common base. ----
    private var bg = "#F5F7FA"
    private var cardWhite = "#FFFFFF"
    private var textDark = "#111827"
    private var textMuted = "#8892A0"
    private var border = "#E7EAF0"
    private var red = "#E5484D"
    private var fieldFill = "#FAFBFD"

    private val navy = "#101B33"
    private val navyLight = "#1C2C4F"
    private val teal = "#0EA5A0"
    private val gold = "#C9A24B"
    private val amberBadge = "#F4F1E8"
    private val successGreen = "#1E9E6B"

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

    private fun loadThemePrefs() {
        val p = ThemeManager.palette(this)
        bg = p.bg
        cardWhite = p.cardWhite
        textDark = p.textDark
        textMuted = p.textMuted
        border = p.border
        red = p.red
        fieldFill = p.fieldFill
    }

    private lateinit var listContainer: LinearLayout
    private lateinit var searchField: EditText
    private lateinit var emptyStateText: TextView
    // ADDED (Khatabook-style summary cards — matches PartyDashboardActivity's
    // "You'll Get / You'll Give" cards): total purchase amount + total outstanding
    // due across all bills, so this screen gets the same at-a-glance totals.
    private lateinit var totalPurchasesValue: TextView
    private lateinit var totalDueValue: TextView

    // billNo/supplierName/total/createdAt/status come straight from the joined query;
    // paid is fetched separately per bill (allPurchases() doesn't project it) so we can
    // still show a due/paid-in-full badge.
    private data class HistoryRow(val billNo: String, val supplierName: String, val total: Double, val createdAt: Long, val status: String, val paid: Double)

    private var rows: List<HistoryRow> = emptyList()

    private fun safeLaunch(label: String, block: suspend () -> Unit) {
        lifecycleScope.launch {
            try {
                block()
            } catch (e: CancellationException) {
                throw e
            } catch (e: Exception) {
                Log.e(TAG, "safeLaunch[$label] failed", e)
            }
        }
    }

    override fun onCreate(b: Bundle?) {
        super.onCreate(b)
        try {
            loadThemePrefs()
            buildUi()
            loadPurchases()
        } catch (e: Exception) {
            Log.e(TAG, "onCreate: fatal error building Purchase History screen", e)
            finish()
        }
    }

    // FIX (stale DUE/PAID badge after editing a bill): unlike SaleHistoryActivity,
    // this screen only ever loaded its rows once, in onCreate(). Each card's
    // DUE/PAID pill and "Balance: Rs …" line are computed fresh from `row.paid`/
    // `row.total` on every renderList() call (see the `due = ...` line there), so
    // the calculation itself was never wrong — but `rows` (in-memory) was never
    // re-fetched from the DB after coming back from PurchaseActivity's edit
    // screen (tapping a card opens it, and changing Paid Amount there does
    // persist correctly). Result: a bill just edited from due -> fully paid (or
    // paid -> partial) kept showing whatever badge it had when this screen was
    // first opened, until it was closed and reopened. Mirrors
    // SaleHistoryActivity.onResume()'s existing refresh() call.
    override fun onResume() {
        super.onResume()
        loadPurchases()
    }

    private fun buildUi() {
        val root = LinearLayout(this).apply {
            orientation = LinearLayout.VERTICAL
            setPadding(24, 0, 24, 40)
            setBackgroundColor(Color.parseColor(bg))
        }

        root.addView(premiumHeader(
            R.drawable.ic_cart,
            com.grocerypos.v11.util.Loc.t(this, "Purchase History", "خریداری کی تاریخ"),
            com.grocerypos.v11.util.Loc.t(this, "All supplier bills", "تمام سپلائر بلز"),
            navy, navy
        ))

        // ADDED (Khatabook-style summary cards): Total Purchases / Total Due, same
        // visual language as PartyDashboardActivity's You'll Get/You'll Give cards.
        root.addView(buildSummaryCards())
        root.addView(spacer(16))

        val searchBox = LinearLayout(this).apply {
            orientation = LinearLayout.HORIZONTAL
            gravity = Gravity.CENTER_VERTICAL
            setPadding(20, 4, 20, 4)
            background = strokedBg(border, cardWhite, 16)
            layoutParams = LinearLayout.LayoutParams(LinearLayout.LayoutParams.MATCH_PARENT, LinearLayout.LayoutParams.WRAP_CONTENT).apply { setMargins(0, 0, 0, 16) }
            applyElevation(this, 2f)
        }
        searchBox.addView(ImageView(this).apply {
            setImageDrawable(tintedDrawable(R.drawable.ic_search, textMuted, 15))
            layoutParams = LinearLayout.LayoutParams(LinearLayout.LayoutParams.WRAP_CONTENT, LinearLayout.LayoutParams.WRAP_CONTENT).apply { marginEnd = (8 * resources.displayMetrics.density).toInt() }
        })
        searchField = EditText(this).apply {
            hint = com.grocerypos.v11.util.Loc.t(this@PurchaseHistoryActivity, "Search bill no. or supplier…", "بل نمبر یا سپلائر تلاش کریں…")
            setHintTextColor(Color.parseColor(textMuted))
            setTextColor(Color.parseColor(textDark))
            background = null
            textSize = 14.5f
            layoutParams = LinearLayout.LayoutParams(0, LinearLayout.LayoutParams.WRAP_CONTENT, 1f)
        }
        searchBox.addView(searchField)
        root.addView(searchBox)

        emptyStateText = TextView(this).apply {
            text = com.grocerypos.v11.util.Loc.t(this@PurchaseHistoryActivity, "No purchases yet", "ابھی کوئی خریداری نہیں")
            textSize = 14f
            setTextColor(Color.parseColor(textMuted))
            setTypeface(typeface, android.graphics.Typeface.BOLD)
            gravity = Gravity.CENTER
            setPadding(0, 60, 0, 0)
            visibility = View.GONE
        }
        root.addView(emptyStateText)

        listContainer = LinearLayout(this).apply { orientation = LinearLayout.VERTICAL }
        root.addView(listContainer)

        val scrollArea = ScrollView(this).apply {
            layoutParams = LinearLayout.LayoutParams(LinearLayout.LayoutParams.MATCH_PARENT, LinearLayout.LayoutParams.MATCH_PARENT)
            setBackgroundColor(Color.parseColor(bg))
            addView(root)
        }
        setContentView(scrollArea)

        searchField.addTextChangedListener(object : TextWatcher {
            override fun beforeTextChanged(s: CharSequence?, a: Int, b: Int, c: Int) {}
            override fun onTextChanged(s: CharSequence?, a: Int, b: Int, c: Int) {}
            override fun afterTextChanged(s: Editable?) = renderList(s?.toString().orEmpty())
        })
    }

    // ADDED (Khatabook-style summary cards): two elevated cards side-by-side, same
    // layout as PartyDashboardActivity.buildSummaryCards()/summaryCard() — navy for
    // total purchased, red for total still owed to suppliers across all bills.
    private fun buildSummaryCards(): LinearLayout {
        val row = LinearLayout(this).apply { orientation = LinearLayout.HORIZONTAL }

        val purchasesCard = summaryCard("\u2193", com.grocerypos.v11.util.Loc.t(this, "Total Purchases", "\u06A9\u0644 \u062E\u0631\u06CC\u062F\u0627\u0631\u06CC"), navy)
        val dueCard = summaryCard("\u2191", com.grocerypos.v11.util.Loc.t(this, "Total Due", "\u06A9\u0644 \u0628\u0627\u0642\u06CC"), red)
        totalPurchasesValue = purchasesCard.second
        totalDueValue = dueCard.second

        purchasesCard.first.layoutParams = LinearLayout.LayoutParams(0, LinearLayout.LayoutParams.WRAP_CONTENT, 1f).apply { setMargins(0, 0, 8, 0) }
        dueCard.first.layoutParams = LinearLayout.LayoutParams(0, LinearLayout.LayoutParams.WRAP_CONTENT, 1f).apply { setMargins(8, 0, 0, 0) }

        row.addView(purchasesCard.first)
        row.addView(dueCard.first)
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

    private fun loadPurchases() = safeLaunch("loadPurchases") {
        val db = PosDatabase.get(this@PurchaseHistoryActivity)
        val purchases = db.purchaseDao().allPurchases()
        rows = purchases
            .sortedByDescending { it.createdAt }
            .map { pws ->
                val paid = try { db.purchaseDao().findPurchase(pws.billNo)?.paid ?: 0.0 } catch (e: Exception) {
                    Log.e(TAG, "loadPurchases: paid lookup failed for ${pws.billNo}", e); 0.0
                }
                HistoryRow(pws.billNo, pws.supplierName, pws.total, pws.createdAt, pws.status, paid)
            }
        // ADDED (Khatabook-style summary cards): active (non-returned) bills only —
        // a returned bill's total is no longer real spend or real debt.
        val activeRows = rows.filter { it.status != "returned" }
        totalPurchasesValue.text = "Rs %.2f".format(activeRows.sumOf { it.total })
        totalDueValue.text = "Rs %.2f".format(activeRows.sumOf { (it.total - it.paid).coerceAtLeast(0.0) })
        renderList(searchField.text?.toString().orEmpty())
    }

    private fun renderList(query: String) {
        listContainer.removeAllViews()
        val q = query.trim().lowercase()
        val filtered = if (q.isEmpty()) rows else rows.filter { row ->
            row.billNo.lowercase().contains(q) || row.supplierName.lowercase().contains(q)
        }
        emptyStateText.visibility = if (filtered.isEmpty()) View.VISIBLE else View.GONE
        filtered.forEach { row ->
            val due = (row.total - row.paid).coerceAtLeast(0.0)
            val card = LinearLayout(this).apply {
                orientation = LinearLayout.VERTICAL
                setPadding(22, 18, 22, 18)
                background = strokedBg(border, cardWhite, 18)
                layoutParams = LinearLayout.LayoutParams(LinearLayout.LayoutParams.MATCH_PARENT, LinearLayout.LayoutParams.WRAP_CONTENT).apply { setMargins(0, 0, 0, 12) }
                applyElevation(this, 3f)
                setOnClickListener {
                    startActivity(Intent(this@PurchaseHistoryActivity, PurchaseActivity::class.java).apply {
                        putExtra(PurchaseActivity.EXTRA_BILL_NO, row.billNo)
                    })
                }
            }
            // ---- Card layout below follows the reference "party ledger" card pattern
            // the user asked for: name + PAID/DUE pill on one line, the entry type and
            // date right-aligned above it, the amount as its own bold line, a muted
            // "Balance: Rs …" line, and a bottom-right row of Print / Share / More
            // (⋮) icons — replacing the old bill-number-first layout and inline
            // text-button Return/Delete row. ----
            val topRow = LinearLayout(this).apply { orientation = LinearLayout.HORIZONTAL }
            val nameCol = LinearLayout(this).apply {
                orientation = LinearLayout.HORIZONTAL
                gravity = Gravity.CENTER_VERTICAL
                layoutParams = LinearLayout.LayoutParams(0, LinearLayout.LayoutParams.WRAP_CONTENT, 1f)
            }
            nameCol.addView(TextView(this).apply { text = row.supplierName; textSize = 14.5f; setTypeface(typeface, android.graphics.Typeface.BOLD); setTextColor(Color.parseColor(textDark)) })
            if (row.status == "active") {
                nameCol.addView(TextView(this).apply {
                    text = if (due > 0) com.grocerypos.v11.util.Loc.t(this@PurchaseHistoryActivity, "DUE", "باقی") else com.grocerypos.v11.util.Loc.t(this@PurchaseHistoryActivity, "PAID", "ادا شدہ")
                    textSize = 10.5f
                    setTypeface(typeface, android.graphics.Typeface.BOLD)
                    setTextColor(Color.parseColor(if (due > 0) red else successGreen))
                    background = strokedBg(if (due > 0) "#F4C7C8" else "#BFE7D3", if (due > 0) "#FDF1F1" else "#EEFBF4", 30)
                    setPadding(16, 4, 16, 4)
                    layoutParams = LinearLayout.LayoutParams(LinearLayout.LayoutParams.WRAP_CONTENT, LinearLayout.LayoutParams.WRAP_CONTENT).apply { setMargins(10, 0, 0, 0) }
                })
            }
            topRow.addView(nameCol)
            val typeDateCol = LinearLayout(this).apply { orientation = LinearLayout.VERTICAL; gravity = Gravity.END }
            typeDateCol.addView(TextView(this).apply {
                text = if (row.status == "active") com.grocerypos.v11.util.Loc.t(this@PurchaseHistoryActivity, "Purchase", "خریداری") else row.status.replaceFirstChar { it.uppercase() }
                textSize = 11.5f
                setTextColor(Color.parseColor(textMuted))
            })
            typeDateCol.addView(TextView(this).apply {
                text = SimpleDateFormat("dd MMM, yy", Locale.getDefault()).format(Date(row.createdAt))
                textSize = 11.5f
                setTextColor(Color.parseColor(textMuted))
                setPadding(0, 2, 0, 0)
            })
            topRow.addView(typeDateCol)
            card.addView(topRow)
            card.addView(spacer(10))
            card.addView(TextView(this).apply { text = "Rs %.2f".format(row.total); textSize = 18f; setTypeface(typeface, android.graphics.Typeface.BOLD); setTextColor(Color.parseColor(textDark)) })
            card.addView(spacer(6))
            card.addView(TextView(this).apply {
                text = com.grocerypos.v11.util.Loc.t(this@PurchaseHistoryActivity, "Balance: Rs %.2f", "باقی: Rs %.2f").format(due)
                textSize = 12f
                setTextColor(Color.parseColor(textMuted))
            })

            if (row.status == "active") {
                val actionsRow = LinearLayout(this).apply {
                    orientation = LinearLayout.HORIZONTAL
                    gravity = Gravity.END
                    setPadding(0, 12, 0, 0)
                }
                actionsRow.addView(ImageView(this@PurchaseHistoryActivity).apply {
                    setImageDrawable(tintedDrawable(R.drawable.ic_printer, navy, 17))
                    setPadding(10, 10, 10, 10)
                    setOnClickListener { printPurchase(row.billNo) }
                })
                actionsRow.addView(ImageView(this@PurchaseHistoryActivity).apply {
                    setImageDrawable(tintedDrawable(R.drawable.ic_share, navy, 17))
                    setPadding(10, 10, 10, 10)
                    setOnClickListener { sharePurchase(row, due) }
                })
                actionsRow.addView(ImageView(this@PurchaseHistoryActivity).apply {
                    setImageDrawable(tintedDrawable(R.drawable.ic_more_vert, textMuted, 17))
                    setPadding(10, 10, 0, 10)
                    setOnClickListener { showRowMenu(this, row.billNo) }
                })
                card.addView(actionsRow)
            }

            listContainer.addView(card)
        }
    }

    // ADDED (card redesign — Print icon): mirrors SaleHistoryActivity.printSale(),
    // reloading the bill fresh from the DB (rather than reusing any in-memory
    // "lines" state, which this history screen never has) and resolving each
    // line's product name from its barcode the same way confirmReturnPurchase()
    // already does below, so a reprinted bill matches the original bill exactly.
    private fun printPurchase(billNo: String) = safeLaunch("printPurchase") {
        val db = PosDatabase.get(this@PurchaseHistoryActivity)
        val purchase = db.purchaseDao().findPurchase(billNo) ?: return@safeLaunch
        val items = db.purchaseDao().itemsForBill(billNo)
        val row = rows.firstOrNull { it.billNo == billNo }

        // FIX (build error — "Suspension functions can only be called within
        // coroutine body", PurchaseHistoryActivity.kt:415): joinToString's
        // `transform` lambda is a plain (non-inline) function type, so it cannot
        // call a suspend function like productDao().find() even though this
        // whole block already runs inside safeLaunch's coroutine. Resolving each
        // line with a plain for-loop first — which, unlike the lambda, preserves
        // the surrounding suspend context — then joining the finished strings
        // fixes it.
        val lineTexts = mutableListOf<String>()
        for (item in items) {
            val product = db.productDao().find(item.barcode)
            val qtyText = formatQty(item.qty)
            // FIX (item name "gayab" after sync): prefer the name snapshotted on this
            // row; only fall back to the live product lookup for pre-migration rows.
            val itemName = item.itemName.ifBlank { product?.name ?: item.barcode }
            lineTexts.add(listOf(itemName, qtyText, item.unit.ifBlank { product?.unit ?: "" }, item.unitCost, item.amount).joinToString("\u0003"))
        }
        val itemsEncoded = lineTexts.joinToString("\u0002")

        val previewIntent = Intent(this@PurchaseHistoryActivity, BillPreviewActivity::class.java).apply {
            putExtra(BillPreviewActivity.EXTRA_TYPE, "purchase")
            putExtra(BillPreviewActivity.EXTRA_REFERENCE, billNo)
            putExtra(BillPreviewActivity.EXTRA_PARTY_NAME, row?.supplierName ?: "")
            putExtra(BillPreviewActivity.EXTRA_PARTY_LABEL, "Supplier")
            if (purchase.supplierId != null) putExtra(BillPreviewActivity.EXTRA_PARTY_ID, purchase.supplierId)
            putExtra(BillPreviewActivity.EXTRA_DATE_MILLIS, purchase.createdAt)
            putExtra(BillPreviewActivity.EXTRA_SUBTOTAL, purchase.subtotal)
            putExtra(BillPreviewActivity.EXTRA_DISCOUNT, purchase.discount)
            putExtra(BillPreviewActivity.EXTRA_TOTAL, purchase.total)
            putExtra(BillPreviewActivity.EXTRA_PAID, purchase.paid)
            putExtra(BillPreviewActivity.EXTRA_PAYMENT_METHOD, "Cash")
            putExtra(BillPreviewActivity.EXTRA_ITEMS_ENCODED, itemsEncoded)
        }
        startActivity(previewIntent)
    }

    // ADDED (card redesign — Share icon): same plain-text-via-ACTION_SEND approach
    // as PartyTransactionActivity.shareReceipt() — hands off to whatever the device
    // has (WhatsApp/SMS/etc.) rather than committing to one channel.
    private fun sharePurchase(row: HistoryRow, due: Double) {
        val dateText = SimpleDateFormat("dd MMM yyyy", Locale.getDefault()).format(Date(row.createdAt))
        val lines = listOf(
            com.grocerypos.v11.util.Loc.t(this, "Purchase Bill", "خریداری کا بل"),
            "${com.grocerypos.v11.util.Loc.t(this, "Supplier", "سپلائر")}: ${row.supplierName}",
            "${com.grocerypos.v11.util.Loc.t(this, "Bill No", "بل نمبر")}: ${row.billNo}",
            "${com.grocerypos.v11.util.Loc.t(this, "Amount", "رقم")}: Rs %.2f".format(row.total),
            "${com.grocerypos.v11.util.Loc.t(this, "Balance", "باقی")}: Rs %.2f".format(due),
            "${com.grocerypos.v11.util.Loc.t(this, "Date", "تاریخ")}: $dateText"
        ).joinToString("\n")
        startActivity(Intent.createChooser(Intent(Intent.ACTION_SEND).apply {
            type = "text/plain"
            putExtra(Intent.EXTRA_TEXT, lines)
        }, com.grocerypos.v11.util.Loc.t(this, "Share purchase", "خریداری شیئر کریں")))
    }

    // ADDED (card redesign — ⋮ overflow icon): Return/Delete used to be their own
    // always-visible text buttons on every active row; they now live behind this
    // menu to match the reference card's icon-only action row, without dropping
    // either action.
    private fun showRowMenu(anchor: View, billNo: String) {
        val popup = android.widget.PopupMenu(this, anchor)
        popup.menu.add(0, 1, 0, com.grocerypos.v11.util.Loc.t(this, "Return", "واپسی"))
        popup.menu.add(0, 2, 1, com.grocerypos.v11.util.Loc.t(this, "Delete", "حذف کریں"))
        popup.setOnMenuItemClickListener { item ->
            when (item.itemId) {
                1 -> confirmReturnPurchase(billNo)
                2 -> confirmDeletePurchase(billNo)
            }
            true
        }
        popup.show()
    }

    // FIX (partial purchase return): "Return" used to only offer returning the ENTIRE
    // bill in one shot, even when the actual issue was e.g. 3 of 10 units of one line
    // being faulty/short — there was no way to send back just those 3. This now opens
    // a per-line quantity picker so only the lines/quantities actually being sent back
    // get reversed — see openReturnPurchaseDialog()/processPartialReturn() below.
    // Returning the full qty on every line still works exactly like the old whole-bill
    // return (see the "remainingItemCount == 0" branch in processPartialReturn()).
    private fun confirmReturnPurchase(billNo: String) = safeLaunch("openReturnDialog") {
        val db = PosDatabase.get(this@PurchaseHistoryActivity)
        val purchase = db.purchaseDao().findPurchase(billNo) ?: return@safeLaunch
        if (purchase.status == "returned") return@safeLaunch
        val items = db.purchaseDao().itemsForBill(billNo)
        if (items.isEmpty()) return@safeLaunch
        val rows = items.map { item ->
            val product = db.productDao().find(item.barcode)
            // FIX (item name "gayab" after sync): prefer the name snapshotted on this
            // row; only fall back to the live product lookup for pre-migration rows.
            ReturnRow(item, item.itemName.ifBlank { product?.name ?: item.barcode }, item.unit.ifBlank { product?.unit ?: "" })
        }
        openReturnPurchaseDialog(billNo, rows)
    }

    private data class ReturnRow(val item: PurchaseItem, val productName: String, val unit: String)

    private fun openReturnPurchaseDialog(billNo: String, rows: List<ReturnRow>) {
        // FIX (dialog buttons hidden off-screen): capping just the item list's height
        // wasn't enough — on some devices the AlertDialog's own title+message chrome plus
        // an uncapped list could still add up to taller than the screen, pushing the
        // Return/Cancel buttons out of view with no way to reach them. Now the ENTIRE
        // dialog (title, message, list, buttons) is one custom layout whose total height
        // is hard-capped to a share of the screen — the item list is the only part that
        // flexes/scrolls, so the button row at the bottom is always on-screen.
        val fields = LinkedHashMap<Long, EditText>()
        val itemsById = rows.associateBy { it.item.id }

        val itemsContainer = LinearLayout(this).apply {
            orientation = LinearLayout.VERTICAL
            setPadding(36, 8, 36, 8)
        }
        for (r in rows) {
            val row = LinearLayout(this).apply {
                orientation = LinearLayout.VERTICAL
                setPadding(0, 14, 0, 14)
            }
            row.addView(TextView(this).apply {
                text = r.productName
                textSize = 14f
                setTypeface(typeface, android.graphics.Typeface.BOLD)
                setTextColor(Color.parseColor(textDark))
            })
            row.addView(TextView(this).apply {
                text = com.grocerypos.v11.util.Loc.t(
                    this@PurchaseHistoryActivity,
                    "Purchased: ${formatQty(r.item.qty)} ${r.unit}",
                    "خریدی گئی مقدار: ${formatQty(r.item.qty)} ${r.unit}"
                )
                textSize = 12f
                setTextColor(Color.parseColor(textMuted))
                setPadding(0, 2, 0, 8)
            })
            val input = EditText(this).apply {
                hint = com.grocerypos.v11.util.Loc.t(this@PurchaseHistoryActivity, "Return qty (leave blank to skip)", "واپسی مقدار (چھوڑنے کے لیے خالی رکھیں)")
                setHintTextColor(Color.parseColor(textMuted))
                setTextColor(Color.parseColor(textDark))
                inputType = android.text.InputType.TYPE_CLASS_NUMBER or android.text.InputType.TYPE_NUMBER_FLAG_DECIMAL
                background = strokedBg(border, fieldFill, 10)
                setPadding(22, 16, 22, 16)
            }
            fields[r.item.id] = input
            row.addView(input)
            itemsContainer.addView(row)
        }

        val itemsScroll = ScrollView(this).apply {
            layoutParams = LinearLayout.LayoutParams(LinearLayout.LayoutParams.MATCH_PARENT, 0, 1f)
            addView(itemsContainer)
        }

        val titleView = TextView(this).apply {
            text = com.grocerypos.v11.util.Loc.t(this@PurchaseHistoryActivity, "Return items", "آئٹمز واپس کریں")
            textSize = 18f
            setTypeface(typeface, android.graphics.Typeface.BOLD)
            setTextColor(Color.parseColor(textDark))
            setPadding(40, 32, 40, 8)
        }
        val messageView = TextView(this).apply {
            text = com.grocerypos.v11.util.Loc.t(
                this@PurchaseHistoryActivity,
                "Enter how many units of each item are being returned. Stock and supplier balance will be adjusted only for those quantities.",
                "ہر آئٹم کی کتنی مقدار واپس ہو رہی ہے درج کریں۔ صرف انہی مقداروں کے مطابق اسٹاک اور سپلائر بیلنس ایڈجسٹ ہو گا۔"
            )
            textSize = 13f
            setTextColor(Color.parseColor(textMuted))
            setPadding(40, 0, 40, 8)
        }

        val cancelBtn = TextView(this).apply {
            text = com.grocerypos.v11.util.Loc.t(this@PurchaseHistoryActivity, "Cancel", "منسوخ کریں")
            textSize = 13f
            gravity = Gravity.CENTER
            setTypeface(typeface, android.graphics.Typeface.BOLD)
            setTextColor(Color.parseColor(textMuted))
            background = strokedBg(border, fieldFill, 12)
            setPadding(0, 20, 0, 20)
            layoutParams = LinearLayout.LayoutParams(0, LinearLayout.LayoutParams.WRAP_CONTENT, 1f)
        }
        val returnBtn = TextView(this).apply {
            text = com.grocerypos.v11.util.Loc.t(this@PurchaseHistoryActivity, "Return", "واپسی")
            textSize = 13f
            gravity = Gravity.CENTER
            setTypeface(typeface, android.graphics.Typeface.BOLD)
            setTextColor(Color.WHITE)
            background = roundedBg(gold, 12)
            setPadding(0, 20, 0, 20)
            layoutParams = LinearLayout.LayoutParams(0, LinearLayout.LayoutParams.WRAP_CONTENT, 1f)
        }
        val spacer = View(this).apply {
            layoutParams = LinearLayout.LayoutParams((12 * resources.displayMetrics.density).toInt(), 1)
        }
        val footer = LinearLayout(this).apply {
            orientation = LinearLayout.HORIZONTAL
            setPadding(40, 16, 40, 32)
            addView(cancelBtn)
            addView(spacer)
            addView(returnBtn)
        }

        val maxDialogHeightPx = (resources.displayMetrics.heightPixels * 0.82).toInt()
        val root = object : LinearLayout(this) {
            override fun onMeasure(widthMeasureSpec: Int, heightMeasureSpec: Int) {
                val mode = android.view.View.MeasureSpec.getMode(heightMeasureSpec)
                val size = android.view.View.MeasureSpec.getSize(heightMeasureSpec)
                val cappedSize = if (mode == android.view.View.MeasureSpec.UNSPECIFIED) maxDialogHeightPx else size.coerceAtMost(maxDialogHeightPx)
                val newMode = if (mode == android.view.View.MeasureSpec.UNSPECIFIED) android.view.View.MeasureSpec.AT_MOST else mode
                super.onMeasure(widthMeasureSpec, android.view.View.MeasureSpec.makeMeasureSpec(cappedSize, newMode))
            }
        }.apply {
            orientation = LinearLayout.VERTICAL
            addView(titleView)
            addView(messageView)
            addView(itemsScroll)
            addView(footer)
        }

        val dialog = android.app.AlertDialog.Builder(this)
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
                val row = itemsById[id] ?: continue
                when {
                    qty == null || qty < 0 -> {
                        errorMsg = com.grocerypos.v11.util.Loc.t(this, "Enter a valid quantity for \"${row.productName}\"", "\"${row.productName}\" کے لیے درست مقدار درج کریں")
                    }
                    qty == 0.0 -> { /* treated as skip */ }
                    qty > row.item.qty + 0.0001 -> {
                        errorMsg = com.grocerypos.v11.util.Loc.t(
                            this,
                            "Return qty for \"${row.productName}\" can't exceed purchased qty (${formatQty(row.item.qty)})",
                            "\"${row.productName}\" کی واپسی مقدار خریدی گئی مقدار (${formatQty(row.item.qty)}) سے زیادہ نہیں ہو سکتی"
                        )
                    }
                    else -> requested[id] = qty
                }
                if (errorMsg != null) break
            }
            if (errorMsg != null) {
                Toast.makeText(this, errorMsg, Toast.LENGTH_LONG).show()
                return@setOnClickListener
            }
            if (requested.isEmpty()) {
                Toast.makeText(this, com.grocerypos.v11.util.Loc.t(this, "Enter a return quantity for at least one item", "کم از کم ایک آئٹم کے لیے واپسی مقدار درج کریں"), Toast.LENGTH_SHORT).show()
                return@setOnClickListener
            }
            dialog.dismiss()
            processPartialReturn(billNo, requested)
        }
        dialog.show()
    }

    // ---- REMOVED (code maintainability — DRY): shared via UiHelpers.kt now (see
    // comment there) — import com.grocerypos.v11.ui.components.*.

    private fun confirmDeletePurchase(billNo: String) {
        android.app.AlertDialog.Builder(this)
            .setTitle(com.grocerypos.v11.util.Loc.t(this, "Delete purchase", "خریداری حذف کریں"))
            .setMessage(com.grocerypos.v11.util.Loc.t(
                this,
                "Delete this purchase? This will reverse its stock and cost changes. This can't be undone.",
                "یہ خریداری حذف کریں؟ اس سے اسٹاک اور لاگت واپس ہو جائے گی۔ اسے واپس نہیں لیا جا سکتا۔"
            ))
            .setPositiveButton(com.grocerypos.v11.util.Loc.t(this, "Delete", "حذف کریں")) { _, _ -> deletePurchase(billNo) }
            .setNegativeButton(com.grocerypos.v11.util.Loc.t(this, "Cancel", "منسوخ کریں"), null)
            .show()
    }

    // FIX (partial purchase return): does the actual line-level return picked in
    // openReturnPurchaseDialog(). For each returned quantity: reverses ONLY that
    // portion of stock/cost (using the SAME weighted-average math as
    // PurchaseRepository's private reverseStockAndCostForItems()/
    // PartyTransactionActivity's reversePurchaseLineCost(), just scaled to the
    // returned qty instead of the whole
    // line), shrinks the purchase line by that qty (or removes it if fully returned),
    // logs a ReturnLine for exactly the returned qty/amount, and shrinks the bill's
    // total/paid/supplier-balance by the returned amount instead of reversing the
    // whole bill. If every line ends up fully returned, the bill is marked "returned"
    // exactly like the old whole-bill returnPurchase() path (including clearing its
    // cash/payment records), so a full return via this same dialog still behaves
    // identically to before.
    private fun processPartialReturn(billNo: String, requested: Map<Long, Double>) = safeLaunch("processPartialReturn") {
        val db = PosDatabase.get(this@PurchaseHistoryActivity)
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
                    // Every line on the bill ended up fully returned — same end state as
                    // the old whole-bill returnPurchase().
                    // FIX (overpaid-bill → party balance gap): was `> 0`, so fully returning
                    // an overpaid purchase (oldOutstanding negative — the excess credited to
                    // the supplier as an advance) never reversed that advance.
                    if (purchase.supplierId != null && kotlin.math.abs(oldOutstanding) > 0.009) {
                        SyncQueueHelper.adjustSupplierBalance(db, purchase.supplierId, -oldOutstanding)
                    }
                    // FIX (purchase return had no visible effect in Cash Book/Day Book):
                    // this used to delete the purchase's cash_transactions row outright,
                    // which erased the original purchase day's cash history AND left no
                    // trace of the return happening today. Now records a dated reversal
                    // instead — see SyncQueueHelper.reverseCashByReference()'s doc comment.
                    SyncQueueHelper.reverseCashByReference(db, billNo, purchase.paid, "IN", "Purchase Return")
                    SyncQueueHelper.deletePaymentsByReference(db, billNo)
                    // FIX (audit): also take back / drop payments linked to this bill.
                    SyncQueueHelper.voidLinkedPayments(db, billNo, "IN", "Purchase Return")
                    // FIX (whole-bill return silently un-returning itself): markReturned()
                    // set status='returned' via raw SQL, but the very next line's
                    // updatePurchase(updatedPurchase) is a Room @Update — it REPLACES the
                    // whole row using this in-memory `updatedPurchase`, whose status was
                    // never touched (still "active" from the original `purchase` object),
                    // silently clobbering markReturned()'s write back to "active" a moment
                    // later — both locally AND in what got pushed to sync. A fully-returned
                    // bill never actually ended up "returned" anywhere. Fixed by setting
                    // status on the copy itself instead of relying on the separate raw call.
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
            Toast.makeText(this@PurchaseHistoryActivity, com.grocerypos.v11.util.Loc.t(this@PurchaseHistoryActivity, "Items returned", "آئٹمز واپس ہو گئے"), Toast.LENGTH_SHORT).show()
            loadPurchases()
        } catch (e: IllegalStateException) {
            Toast.makeText(this@PurchaseHistoryActivity, e.message ?: "Return nahi ho saka", Toast.LENGTH_LONG).show()
        }
    }

    // Same frozen-conversionFactor reasoning as PurchaseItem.smallestQty(product) in
    // Database.kt, but for a QUANTITY BEING RETURNED (which may be less than the
    // line's full qty) instead of the whole line.
    private fun partialSmallestQty(item: PurchaseItem, product: Product?, returnQty: Double): Double =
        if (item.conversionFactor > 0) returnQty * item.conversionFactor
        else product?.toSmallestUnits(returnQty, item.unit.ifBlank { product.unit }) ?: returnQty

    // Same weighted-average reversal math as PurchaseRepository's private
    // reverseStockAndCostForItems() (and PartyTransactionActivity.reversePurchaseLineCost()),
    // but taking the qty/amount to remove as parameters so it can be used for a
    // PARTIAL line return instead of always reversing the whole line — no
    // equivalent exists in PurchaseRepository since it doesn't support partial returns.
    private fun reversePurchaseLineCostPartial(product: Product, smallestQtyToRemove: Double, amountToRemove: Double): Double {
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
    // purchaseRepository above for why.
    private fun deletePurchase(billNo: String) = safeLaunch("deletePurchase") {
        val db = PosDatabase.get(this@PurchaseHistoryActivity)
        val purchase = db.purchaseDao().findPurchase(billNo) ?: return@safeLaunch
        val items = db.purchaseDao().itemsForBill(billNo)
        try {
            purchaseRepository.deletePurchase(billNo, purchase, items)
            Toast.makeText(this@PurchaseHistoryActivity, "Purchase deleted", Toast.LENGTH_SHORT).show()
            loadPurchases()
        } catch (e: IllegalStateException) {
            Toast.makeText(this@PurchaseHistoryActivity, e.message ?: "Delete nahi ho saka", Toast.LENGTH_LONG).show()
        }
    }

    // gradientBg() and spacer() now come from the shared UiHelpers.kt (item #24 dedup) —
    // both were byte-identical private copies here before.
}

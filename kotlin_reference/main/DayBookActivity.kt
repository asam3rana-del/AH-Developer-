package com.grocerypos.v11.ui
import com.grocerypos.v11.SyncQueueHelper

import android.app.DatePickerDialog
import android.content.Intent
import android.graphics.Color
import android.graphics.drawable.GradientDrawable
import android.os.Bundle
import android.view.Gravity
import android.view.View
import android.widget.*
import androidx.appcompat.app.AppCompatActivity
import androidx.lifecycle.lifecycleScope
import com.grocerypos.v11.PosDatabase
import com.grocerypos.v11.R
import com.grocerypos.v11.util.Loc
import kotlinx.coroutines.launch
import java.text.SimpleDateFormat
import java.util.Calendar
import java.util.Date
import java.util.Locale
import com.grocerypos.v11.ui.components.*

private data class DayBookEntry(
    val time: Long,
    val iconRes: Int,
    val title: String,
    val subtitle: String,
    val amount: Double,
    val isInflow: Boolean,
    val refType: String? = null,   // "sale" | "purchase" — used for tap-to-open
    val refId: String? = null
)

class DayBookActivity : AppCompatActivity() {

    // ---- Pulled from ThemeManager so this screen respects dark mode. The header used to be
    // a navy→navyLight gradient (out of step with the rest of the app); it's now a flat teal
    // header like Reports/Party, sourced from flatTealFg. In/out (green/red) logic is untouched. ----
    private var bg = "#F3F4F9"
    private var cardWhite = "#FFFFFF"
    private var textDark = "#1A1D2E"
    private var textMuted = "#8A8FA3"
    private var green = "#2E7D32"      // positive — flatTealFg
    private var red = "#C62828"
    private var teal = "#0F9B8E"       // header — flatTealFg (was navy/navyLight gradient)
    private var amber = "#C9A24B"      // flatAmberFg
    private var border = "#E6E8F0"
    private var headerOverlay = "#22FFFFFF"

    private fun loadThemeColors() {
        val p = com.grocerypos.v11.util.ThemeManager.palette(this)
        bg = p.bg
        cardWhite = p.cardWhite
        textDark = p.textDark
        textMuted = p.textMuted
        green = p.flatTealFg
        red = p.red
        teal = p.flatTealFg
        amber = p.flatAmberFg
        border = p.border
        headerOverlay = p.headerBadgeOverlay
    }

    private lateinit var dateValueText: TextView
    private lateinit var summaryRow: LinearLayout
    private lateinit var netText: TextView
    private lateinit var listContainer: LinearLayout
    private lateinit var emptyText: TextView

    private var dayMillis: Long = System.currentTimeMillis()

    override fun onCreate(b: Bundle?) {
        super.onCreate(b)
        loadThemeColors()

        val root = LinearLayout(this).apply {
            orientation = LinearLayout.VERTICAL
            setPadding(0, 0, 0, 32)
            setBackgroundColor(Color.parseColor(bg))
        }

        // ---- Header (flat, no gradient — Reports-style) ----
        val header = LinearLayout(this).apply {
            orientation = LinearLayout.HORIZONTAL
            gravity = Gravity.CENTER_VERTICAL
            setPadding(26, 40, 22, 26)
            background = gradientBg(teal, teal)
        }
        header.addView(iconBadge(R.drawable.ic_book, "#FFFFFF", bgHex = headerOverlay, sizeDp = 40, iconSizeDp = 18))
        header.addView(spacer(12).apply { layoutParams = LinearLayout.LayoutParams((12 * resources.displayMetrics.density).toInt(), 1) })
        header.addView(TextView(this).apply {
            text = Loc.t(this@DayBookActivity, "Day Book", "روزنامچہ")
            textSize = 20f
            setTextColor(Color.WHITE)
            setTypeface(typeface, android.graphics.Typeface.BOLD)
            layoutParams = LinearLayout.LayoutParams(0, LinearLayout.LayoutParams.WRAP_CONTENT, 1f)
        })
        header.addView(TextView(this).apply {
            text = "\u2039"
            textSize = 20f
            setTextColor(Color.WHITE)
            gravity = Gravity.CENTER
            background = ovalBg(headerOverlay)
            val px = (36 * resources.displayMetrics.density).toInt(); layoutParams = android.view.ViewGroup.LayoutParams(px, px)
            setOnClickListener { shiftDay(-1) }
        })
        header.addView(spacer(10).apply { layoutParams = LinearLayout.LayoutParams((10 * resources.displayMetrics.density).toInt(), 1) })
        header.addView(TextView(this).apply {
            text = "\u203A"
            textSize = 20f
            setTextColor(Color.WHITE)
            gravity = Gravity.CENTER
            background = ovalBg(headerOverlay)
            val px = (36 * resources.displayMetrics.density).toInt(); layoutParams = android.view.ViewGroup.LayoutParams(px, px)
            setOnClickListener { shiftDay(1) }
        })
        root.addView(header)

        val body = LinearLayout(this).apply {
            orientation = LinearLayout.VERTICAL
            setPadding(24, 18, 24, 0)
        }

        // ---- Date chip ----
        val dateChip = LinearLayout(this).apply {
            orientation = LinearLayout.HORIZONTAL
            gravity = Gravity.CENTER_VERTICAL
            setPadding(22, 14, 22, 14)
            background = strokedBg(border, cardWhite, 30)
            layoutParams = LinearLayout.LayoutParams(LinearLayout.LayoutParams.WRAP_CONTENT, LinearLayout.LayoutParams.WRAP_CONTENT).apply { setMargins(0, 0, 0, 18) }
            setOnClickListener { openDatePicker() }
        }
        dateChip.addView(ImageView(this).apply { setImageDrawable(tintedDrawable(R.drawable.ic_calendar, teal, 15)); setPadding(0, 0, 10, 0) })
        dateValueText = TextView(this).apply {
            text = formatDate(dayMillis)
            textSize = 14f
            setTextColor(Color.parseColor(textDark))
            setTypeface(typeface, android.graphics.Typeface.BOLD)
        }
        dateChip.addView(dateValueText)
        dateChip.addView(TextView(this).apply { text = "  \u203A"; textSize = 13f; setTextColor(Color.parseColor(teal)) })
        body.addView(dateChip)

        // ---- Summary cards row (wraps to 2 rows via nested layout) ----
        summaryRow = LinearLayout(this).apply { orientation = LinearLayout.VERTICAL }
        body.addView(summaryRow)
        body.addView(spacer(10))

        // ---- Net total banner ----
        val netCard = LinearLayout(this).apply {
            orientation = LinearLayout.HORIZONTAL
            gravity = Gravity.CENTER_VERTICAL
            setPadding(22, 18, 22, 18)
            background = roundedBg(cardWhite, 18)
            elevation = 3f
            layoutParams = LinearLayout.LayoutParams(LinearLayout.LayoutParams.MATCH_PARENT, LinearLayout.LayoutParams.WRAP_CONTENT).apply { setMargins(0, 0, 0, 22) }
        }
        netCard.addView(TextView(this).apply {
            text = Loc.t(this@DayBookActivity, "Net Cash Flow (Today)", "خالص کیش فلو (آج)")
            textSize = 12.5f
            setTextColor(Color.parseColor(textMuted))
            setTypeface(typeface, android.graphics.Typeface.BOLD)
            layoutParams = LinearLayout.LayoutParams(0, LinearLayout.LayoutParams.WRAP_CONTENT, 1f)
        })
        netText = TextView(this).apply {
            text = "Rs 0.00"
            textSize = 17f
            setTypeface(typeface, android.graphics.Typeface.BOLD)
        }
        netCard.addView(netText)
        body.addView(netCard)

        body.addView(sectionLabel(Loc.t(this, "TRANSACTIONS", "لین دین")))
        body.addView(spacer(10))

        listContainer = LinearLayout(this).apply { orientation = LinearLayout.VERTICAL }
        body.addView(listContainer)

        emptyText = TextView(this).apply {
            text = Loc.t(this@DayBookActivity, "No transactions on this day", "اس دن کوئی لین دین نہیں")
            setTextColor(Color.parseColor(textMuted))
            textSize = 13f
            gravity = Gravity.CENTER
            setPadding(0, 40, 0, 40)
            visibility = View.GONE
        }
        body.addView(emptyText)
        body.addView(spacer(30))

        root.addView(body)

        setContentView(ScrollView(this).apply {
            setBackgroundColor(Color.parseColor(bg))
            addView(root)
        })

        loadDay()
    }

    private fun shiftDay(delta: Int) {
        val cal = Calendar.getInstance().apply { timeInMillis = dayMillis }
        cal.add(Calendar.DAY_OF_MONTH, delta)
        dayMillis = cal.timeInMillis
        dateValueText.text = formatDate(dayMillis)
        loadDay()
    }

    private fun openDatePicker() {
        val cal = Calendar.getInstance().apply { timeInMillis = dayMillis }
        DatePickerDialog(this, { _, y, m, d ->
            cal.set(y, m, d)
            dayMillis = cal.timeInMillis
            dateValueText.text = formatDate(dayMillis)
            loadDay()
        }, cal.get(Calendar.YEAR), cal.get(Calendar.MONTH), cal.get(Calendar.DAY_OF_MONTH)).apply {
            // FIX (consistent date picker style across the app): force calendar
            // mode so this matches the grid-calendar picker used everywhere else.
            datePicker.calendarViewShown = true; datePicker.spinnersShown = false
        }.show()
    }

    private fun dayBounds(millis: Long): Pair<Long, Long> {
        val cal = Calendar.getInstance().apply { timeInMillis = millis }
        cal.set(Calendar.HOUR_OF_DAY, 0); cal.set(Calendar.MINUTE, 0)
        cal.set(Calendar.SECOND, 0); cal.set(Calendar.MILLISECOND, 0)
        val start = cal.timeInMillis
        return Pair(start, start + 24 * 60 * 60 * 1000L)
    }

    private fun loadDay() {
        lifecycleScope.launch {
            val db = PosDatabase.get(this@DayBookActivity)
            val (start, end) = dayBounds(dayMillis)

            val sales = db.saleDao().salesBetween(start, end)
            val purchases = db.purchaseDao().purchasesBetween(start, end)
            val expenses = db.expenseDao().between(start, end)
            // Only manual cash entries — sale/purchase payments are already represented
            // by the sale/purchase rows above, via their "Paid" line, so those (whose
            // reference is set to the invoice/billNo) are excluded here.
            // FIX (Payments 10/10): this used to be `it.reference.isBlank()`, which also
            // excluded the standalone "Receive Payment"/"Make Payment" entries from
            // PartyTransactionActivity — those always carry a non-blank "manual-…"
            // reference (so a delete/edit can find their matching Payment row), but
            // they are NOT represented anywhere else in this list, so they were
            // silently missing from Day Book entirely. Now only cash entries tied to
            // an actual sale/purchase bill (reference = that bill's invoice/billNo,
            // never "manual-…") are excluded.
            // FIX (sale/purchase return invisible in Day Book): a return now records a
            // dated "return:<invoice/billNo>" reversal entry (see SyncQueueHelper.
            // reverseCashByReference) instead of deleting/shrinking the original cash
            // row. That reference is neither blank nor "manual-…", so without this it
            // would fall into the same "already represented by the sale/purchase row"
            // exclusion above — except a return has no row of its own on today's date
            // (the sale/purchase row stays on its ORIGINAL date), so the return would
            // never appear anywhere. "return:" entries are let through here so the
            // return itself shows as its own Cash In/Cash Out line on the day it happened.
            val cashTx = db.cashTransactionDao().between(start, end).filter {
                it.reference.isBlank() || it.reference.startsWith("manual-") || it.reference.startsWith("return:")
            }

            val entries = mutableListOf<DayBookEntry>()

            sales.forEach { s ->
                val statusNote = if (s.status == "returned") " (RETURNED)" else if (s.paid < s.total) " • Due Rs %.0f".format(s.total - s.paid) else ""
                entries.add(
                    DayBookEntry(
                        time = s.createdAt,
                        iconRes = R.drawable.ic_cart,
                        title = Loc.t(this@DayBookActivity, "Sale", "سیل") + " \u2022 ${s.customerName}",
                        subtitle = (Loc.t(this@DayBookActivity, "Paid", "ادا شدہ") + ": Rs %.0f".format(s.paid)) + statusNote,
                        amount = s.total,
                        isInflow = true,
                        refType = "sale",
                        refId = s.invoice
                    )
                )
            }
            purchases.forEach { p ->
                val statusNote = if (p.status == "returned") " (RETURNED)" else if (p.paid < p.total) " • Due Rs %.0f".format(p.total - p.paid) else ""
                entries.add(
                    DayBookEntry(
                        time = p.createdAt,
                        iconRes = R.drawable.ic_box,
                        title = Loc.t(this@DayBookActivity, "Purchase", "خریداری") + " \u2022 ${p.supplierName}",
                        subtitle = (Loc.t(this@DayBookActivity, "Paid", "ادا شدہ") + ": Rs %.0f".format(p.paid)) + statusNote,
                        amount = p.total,
                        isInflow = false,
                        refType = "purchase",
                        refId = p.billNo
                    )
                )
            }
            expenses.forEach { e ->
                entries.add(
                    DayBookEntry(
                        time = e.createdAt,
                        iconRes = R.drawable.ic_wallet,
                        title = e.category,
                        subtitle = e.description.ifBlank { Loc.t(this@DayBookActivity, "Expense", "خرچہ") },
                        amount = e.amount,
                        isInflow = false
                    )
                )
            }
            cashTx.forEach { c ->
                entries.add(
                    DayBookEntry(
                        time = c.createdAt,
                        iconRes = if (c.type == "IN") R.drawable.ic_trending else R.drawable.ic_trending_down,
                        title = (if (c.type == "IN") Loc.t(this@DayBookActivity, "Cash In", "کیش ان") else Loc.t(this@DayBookActivity, "Cash Out", "کیش آؤٹ")) + " \u2022 ${c.method.uppercase()}",
                        subtitle = c.reason.ifBlank { Loc.t(this@DayBookActivity, "Manual entry", "دستی اندراج") },
                        amount = c.amount,
                        isInflow = c.type == "IN"
                    )
                )
            }

            entries.sortByDescending { it.time }

            val totalSales = sales.filter { it.status != "returned" }.sumOf { it.total }
            val totalPurchases = purchases.filter { it.status != "returned" }.sumOf { it.total }
            val totalExpenses = expenses.sumOf { it.amount }
            // FIX (audit — Day Book Cash In/Out overstated): a payment linked to a bill is
            // ALREADY inside that bill's `paid` (applyBillPaidDelta) AND is its own manual
            // cash entry counted in cashTx above => counted twice (and on the bill's original
            // day, not the day the money actually moved). Take linked payments back out of
            // the bill's paid so each rupee is counted once, on its own date.
            val linkedByBill = db.paymentDao().allRaw()
                .filter { it.billReference.isNotBlank() }
                .groupBy { it.billReference }
                .mapValues { (_, v) -> v.sumOf { p -> p.amount } }
            val salesPaidOwn = sales.filter { it.status != "returned" }
                .sumOf { (it.paid - (linkedByBill[it.invoice] ?: 0.0)).coerceAtLeast(0.0) }
            val purchasesPaidOwn = purchases.filter { it.status != "returned" }
                .sumOf { (it.paid - (linkedByBill[it.billNo] ?: 0.0)).coerceAtLeast(0.0) }
            val cashIn = cashTx.filter { it.type == "IN" }.sumOf { it.amount } + salesPaidOwn
            val cashOut = cashTx.filter { it.type == "OUT" }.sumOf { it.amount } + purchasesPaidOwn
            val net = cashIn - cashOut - totalExpenses

            renderSummary(totalSales, totalPurchases, totalExpenses, cashIn, cashOut)
            netText.text = "Rs %.2f".format(net)
            netText.setTextColor(Color.parseColor(if (net >= 0) green else red))

            renderList(entries)
        }
    }

    private fun renderSummary(sales: Double, purchases: Double, expenses: Double, cashIn: Double, cashOut: Double) {
        summaryRow.removeAllViews()
        val row1 = LinearLayout(this).apply { orientation = LinearLayout.HORIZONTAL }
        row1.addView(statCard(R.drawable.ic_cart, Loc.t(this, "Sales", "سیل"), sales, green).apply {
            layoutParams = LinearLayout.LayoutParams(0, LinearLayout.LayoutParams.WRAP_CONTENT, 1f).apply { setMargins(0, 0, 8, 10) }
        })
        row1.addView(statCard(R.drawable.ic_box, Loc.t(this, "Purchases", "خریداری"), purchases, amber).apply {
            layoutParams = LinearLayout.LayoutParams(0, LinearLayout.LayoutParams.WRAP_CONTENT, 1f).apply { setMargins(8, 0, 0, 10) }
        })
        summaryRow.addView(row1)
        val row2 = LinearLayout(this).apply { orientation = LinearLayout.HORIZONTAL }
        row2.addView(statCard(R.drawable.ic_trending, Loc.t(this, "Cash In", "کیش ان"), cashIn, green).apply {
            layoutParams = LinearLayout.LayoutParams(0, LinearLayout.LayoutParams.WRAP_CONTENT, 1f).apply { setMargins(0, 0, 8, 10) }
        })
        row2.addView(statCard(R.drawable.ic_trending_down, Loc.t(this, "Cash Out", "کیش آؤٹ"), cashOut + expenses, red).apply {
            layoutParams = LinearLayout.LayoutParams(0, LinearLayout.LayoutParams.WRAP_CONTENT, 1f).apply { setMargins(8, 0, 0, 10) }
        })
        summaryRow.addView(row2)
    }

    private fun statCard(iconRes: Int, label: String, value: Double, accentHex: String): LinearLayout {
        val card = LinearLayout(this).apply {
            orientation = LinearLayout.VERTICAL
            setPadding(18, 16, 18, 16)
            background = roundedBg(cardWhite, 16)
            elevation = 2f
        }
        card.addView(TextView(this).apply {
            text = "  $label"
            textSize = 11.5f
            setTextColor(Color.parseColor(textMuted))
            setTypeface(typeface, android.graphics.Typeface.BOLD)
            setLeadingIcon(iconRes, textMuted, 14, 6)
        })
        card.addView(TextView(this).apply {
            text = "Rs %.0f".format(value)
            textSize = 16f
            setTextColor(Color.parseColor(accentHex))
            setTypeface(typeface, android.graphics.Typeface.BOLD)
            setPadding(0, 6, 0, 0)
        })
        return card
    }

    private fun renderList(entries: List<DayBookEntry>) {
        listContainer.removeAllViews()
        emptyText.visibility = if (entries.isEmpty()) View.VISIBLE else View.GONE
        val fmt = SimpleDateFormat("hh:mm a", Locale.getDefault())
        for (e in entries) {
            listContainer.addView(LinearLayout(this).apply {
                orientation = LinearLayout.HORIZONTAL
                gravity = Gravity.CENTER_VERTICAL
                setPadding(18, 16, 18, 16)
                background = roundedBg(cardWhite, 16)
                elevation = 2f
                layoutParams = LinearLayout.LayoutParams(LinearLayout.LayoutParams.MATCH_PARENT, LinearLayout.LayoutParams.WRAP_CONTENT).apply { setMargins(0, 0, 0, 10) }
                if (e.refType != null && e.refId != null) {
                    setOnClickListener {
                        val intent = if (e.refType == "sale")
                            Intent(this@DayBookActivity, SaleActivity::class.java).putExtra(SaleActivity.EXTRA_INVOICE, e.refId)
                        else
                            Intent(this@DayBookActivity, PurchaseActivity::class.java).putExtra(PurchaseActivity.EXTRA_BILL_NO, e.refId)
                        startActivity(intent)
                    }
                }

                addView(iconBadge(e.iconRes, if (e.isInflow) green else red, sizeDp = 40, iconSizeDp = 18))

                val infoCol = LinearLayout(this@DayBookActivity).apply {
                    orientation = LinearLayout.VERTICAL
                    setPadding(16, 0, 8, 0)
                    layoutParams = LinearLayout.LayoutParams(0, LinearLayout.LayoutParams.WRAP_CONTENT, 1f)
                }
                infoCol.addView(TextView(this@DayBookActivity).apply {
                    text = e.title
                    textSize = 14f
                    setTypeface(typeface, android.graphics.Typeface.BOLD)
                    setTextColor(Color.parseColor(textDark))
                })
                infoCol.addView(TextView(this@DayBookActivity).apply {
                    text = e.subtitle
                    textSize = 11.5f
                    setTextColor(Color.parseColor(textMuted))
                    setPadding(0, 3, 0, 0)
                })
                infoCol.addView(TextView(this@DayBookActivity).apply {
                    text = fmt.format(Date(e.time))
                    textSize = 10.5f
                    setTextColor(Color.parseColor(textMuted))
                    setPadding(0, 3, 0, 0)
                })
                addView(infoCol)

                addView(TextView(this@DayBookActivity).apply {
                    text = (if (e.isInflow) "+ " else "- ") + "Rs %.0f".format(e.amount)
                    setTextColor(Color.parseColor(if (e.isInflow) green else red))
                    setTypeface(typeface, android.graphics.Typeface.BOLD)
                    textSize = 14f
                })
            })
        }
    }

    // ---- UI helpers ----
    private fun sectionLabel(text: String) = TextView(this).apply {
        this.text = text
        textSize = 12f
        setTextColor(Color.parseColor(textMuted))
        setTypeface(typeface, android.graphics.Typeface.BOLD)
        letterSpacing = 0.04f
    }

    private fun lightenHex(hex: String): String {
        val base = Color.parseColor(hex)
        val factor = 0.88f
        val r = (Color.red(base) + (255 - Color.red(base)) * factor).toInt().coerceIn(0, 255)
        val g = (Color.green(base) + (255 - Color.green(base)) * factor).toInt().coerceIn(0, 255)
        val bl = (Color.blue(base) + (255 - Color.blue(base)) * factor).toInt().coerceIn(0, 255)
        return String.format("#%06X", 0xFFFFFF and Color.rgb(r, g, bl))
    }
    private fun gradientBg(startHex: String, endHex: String) = GradientDrawable(
        GradientDrawable.Orientation.TL_BR, intArrayOf(Color.parseColor(startHex), Color.parseColor(endHex))
    )
    // spacer() now comes from the shared UiHelpers.kt (item #24 dedup) — was a
    // byte-identical private copy here before.
    private fun formatDate(millis: Long) = SimpleDateFormat("dd MMM yyyy, EEEE", Locale.getDefault()).format(Date(millis))
}

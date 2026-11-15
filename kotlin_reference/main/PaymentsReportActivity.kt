package com.grocerypos.v11.ui

import android.content.Intent
import android.graphics.Color
import android.graphics.drawable.GradientDrawable
import android.os.Bundle
import android.view.Gravity
import android.view.View
import android.widget.*
import androidx.appcompat.app.AppCompatActivity
import androidx.lifecycle.lifecycleScope
import com.grocerypos.v11.Payment
import com.grocerypos.v11.PosDatabase
import com.grocerypos.v11.R
import com.grocerypos.v11.util.Loc
import kotlinx.coroutines.launch
import java.text.SimpleDateFormat
import java.util.Calendar
import java.util.Date
import java.util.Locale
import com.grocerypos.v11.ui.components.*

// NEW (Payments 10/10 — suggestion #3): a dedicated, all-parties view of every
// standalone "Receive Payment"/"Make Payment" entry, with period totals — separate
// from Day Book (which mixes payments in with sales/purchases/expenses) and from
// PartyReportsActivity's Payment History (which is scoped to one party at a time).
private enum class ReportPeriod { TODAY, WEEK, MONTH, ALL }
private enum class ReportFilter { ALL, RECEIVED, MADE }
private data class ReportRow(val payment: Payment, val partyName: String, val partyId: Long?, val isCustomer: Boolean)

class PaymentsReportActivity : AppCompatActivity() {

    // ---- Same shared flat palette as DayBook/Reports/Party screens ----
    private var bg = "#F3F4F9"
    private var cardWhite = "#FFFFFF"
    private var textDark = "#1A1D2E"
    private var textMuted = "#8A8FA3"
    private var green = "#2E7D32"
    private var red = "#C62828"
    private var teal = "#0F9B8E"
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
        border = p.border
        headerOverlay = p.headerBadgeOverlay
    }

    private lateinit var receivedValueText: TextView
    private lateinit var madeValueText: TextView
    private lateinit var netValueText: TextView
    private lateinit var listContainer: LinearLayout
    private lateinit var searchField: EditText
    private lateinit var chipToday: TextView
    private lateinit var chipWeek: TextView
    private lateinit var chipMonth: TextView
    private lateinit var chipAll: TextView
    private lateinit var chipFilterAll: TextView
    private lateinit var chipFilterReceived: TextView
    private lateinit var chipFilterMade: TextView

    private var period: ReportPeriod = ReportPeriod.MONTH
    private var filter: ReportFilter = ReportFilter.ALL
    private var query: String = ""
    private var allRows: List<ReportRow> = emptyList()

    override fun onCreate(b: Bundle?) {
        super.onCreate(b)
        loadThemeColors()

        val root = LinearLayout(this).apply {
            orientation = LinearLayout.VERTICAL
            setPadding(0, 0, 0, 32)
            setBackgroundColor(Color.parseColor(bg))
        }

        val header = LinearLayout(this).apply {
            orientation = LinearLayout.HORIZONTAL
            gravity = Gravity.CENTER_VERTICAL
            setPadding(26, 40, 22, 26)
            background = gradientBg(teal, teal)
        }
        header.addView(TextView(this).apply {
            text = "\u2039"
            textSize = 22f
            setTextColor(Color.WHITE)
            gravity = Gravity.CENTER
            background = ovalBg(headerOverlay)
            val px = (36 * resources.displayMetrics.density).toInt()
            layoutParams = LinearLayout.LayoutParams(px, px).apply { marginEnd = 14 }
            setOnClickListener { finish() }
        })
        header.addView(iconBadge(R.drawable.ic_wallet, "#FFFFFF", bgHex = headerOverlay, sizeDp = 40, iconSizeDp = 18))
        header.addView(spacer(12).apply { layoutParams = LinearLayout.LayoutParams((12 * resources.displayMetrics.density).toInt(), 1) })
        header.addView(TextView(this).apply {
            text = Loc.t(this@PaymentsReportActivity, "Payments Report", "\u0627\u062F\u0627\u0626\u06CC\u06AF\u06CC\u0648\u06BA \u06A9\u06CC \u0631\u067E\u0648\u0631\u0679")
            textSize = 19f
            setTextColor(Color.WHITE)
            setTypeface(typeface, android.graphics.Typeface.BOLD)
            layoutParams = LinearLayout.LayoutParams(0, LinearLayout.LayoutParams.WRAP_CONTENT, 1f)
        })
        root.addView(header)

        val body = LinearLayout(this).apply {
            orientation = LinearLayout.VERTICAL
            setPadding(24, 18, 24, 0)
        }

        // ---- Period chips: Today / This Week / This Month / All Time ----
        val periodRow = LinearLayout(this).apply {
            orientation = LinearLayout.HORIZONTAL
            setPadding(0, 0, 0, 16)
        }
        fun periodChip(label: String, p: ReportPeriod): TextView = TextView(this).apply {
            text = label
            textSize = 12f
            setTypeface(typeface, android.graphics.Typeface.BOLD)
            setPadding(24, 12, 24, 12)
            val lp = LinearLayout.LayoutParams(0, LinearLayout.LayoutParams.WRAP_CONTENT, 1f)
            lp.marginEnd = 8
            layoutParams = lp
            gravity = Gravity.CENTER
            setOnClickListener {
                period = p
                updatePeriodChipStyles()
                loadReport()
            }
        }
        chipToday = periodChip(Loc.t(this, "Today", "\u0622\u062C"), ReportPeriod.TODAY)
        chipWeek = periodChip(Loc.t(this, "Week", "\u06C1\u0641\u062A\u06C1"), ReportPeriod.WEEK)
        chipMonth = periodChip(Loc.t(this, "Month", "\u0645\u06C1\u06CC\u0646\u06C1"), ReportPeriod.MONTH)
        chipAll = periodChip(Loc.t(this, "All Time", "\u06C1\u0645\u06CC\u0634\u06C1"), ReportPeriod.ALL)
        listOf(chipToday, chipWeek, chipMonth, chipAll).forEach { periodRow.addView(it) }
        body.addView(periodRow)
        updatePeriodChipStyles()

        // ---- Summary cards: Received / Made / Net ----
        val summaryRow = LinearLayout(this).apply {
            orientation = LinearLayout.HORIZONTAL
            layoutParams = LinearLayout.LayoutParams(LinearLayout.LayoutParams.MATCH_PARENT, LinearLayout.LayoutParams.WRAP_CONTENT).apply { setMargins(0, 0, 0, 14) }
        }
        fun summaryCard(label: String, color: String): TextView {
            val card = LinearLayout(this).apply {
                orientation = LinearLayout.VERTICAL
                setPadding(20, 16, 20, 16)
                background = roundedBg(cardWhite, 16)
                elevation = 2f
                val lp = LinearLayout.LayoutParams(0, LinearLayout.LayoutParams.WRAP_CONTENT, 1f)
                lp.marginEnd = 10
                layoutParams = lp
            }
            card.addView(TextView(this).apply {
                text = label
                textSize = 11f
                setTextColor(Color.parseColor(textMuted))
            })
            val valueText = TextView(this).apply {
                text = "Rs 0.00"
                textSize = 15f
                setTypeface(typeface, android.graphics.Typeface.BOLD)
                setTextColor(Color.parseColor(color))
                setPadding(0, 6, 0, 0)
            }
            card.addView(valueText)
            summaryRow.addView(card)
            return valueText
        }
        receivedValueText = summaryCard(Loc.t(this, "Received", "\u0648\u0635\u0648\u0644 \u06C1\u0648\u0626\u06CC"), green)
        madeValueText = summaryCard(Loc.t(this, "Made", "\u0627\u062F\u0627 \u06C1\u0648\u0626\u06CC"), red)
        (summaryRow.getChildAt(1) as LinearLayout).apply { (layoutParams as LinearLayout.LayoutParams).marginEnd = 0 }
        body.addView(summaryRow)

        val netCard = LinearLayout(this).apply {
            orientation = LinearLayout.HORIZONTAL
            gravity = Gravity.CENTER_VERTICAL
            setPadding(22, 16, 22, 16)
            background = roundedBg(cardWhite, 18)
            elevation = 3f
            layoutParams = LinearLayout.LayoutParams(LinearLayout.LayoutParams.MATCH_PARENT, LinearLayout.LayoutParams.WRAP_CONTENT).apply { setMargins(0, 0, 0, 20) }
        }
        netCard.addView(TextView(this).apply {
            text = Loc.t(this@PaymentsReportActivity, "Net (Received \u2212 Made)", "\u062E\u0627\u0644\u0635 (\u0648\u0635\u0648\u0644 \u2212 \u0627\u062F\u0627)")
            textSize = 12.5f
            setTextColor(Color.parseColor(textMuted))
            setTypeface(typeface, android.graphics.Typeface.BOLD)
            layoutParams = LinearLayout.LayoutParams(0, LinearLayout.LayoutParams.WRAP_CONTENT, 1f)
        })
        netValueText = TextView(this).apply {
            text = "Rs 0.00"
            textSize = 16f
            setTypeface(typeface, android.graphics.Typeface.BOLD)
        }
        netCard.addView(netValueText)
        body.addView(netCard)

        // ---- Search + Received/Made filter chips ----
        val searchBox = LinearLayout(this).apply {
            orientation = LinearLayout.VERTICAL
            setPadding(18, 8, 18, 8)
            background = strokedBg(border, "#F7F8FC", 10)
            layoutParams = LinearLayout.LayoutParams(LinearLayout.LayoutParams.MATCH_PARENT, LinearLayout.LayoutParams.WRAP_CONTENT).apply { setMargins(0, 0, 0, 10) }
        }
        searchField = EditText(this).apply {
            hint = Loc.t(this@PaymentsReportActivity, "Search by party, note, or method", "\u067E\u0627\u0631\u0679\u06CC\u060C \u0646\u0648\u0679 \u06CC\u0627 \u0630\u0631\u06CC\u0639\u06C1 \u0633\u06D2 \u062A\u0644\u0627\u0634 \u06A9\u0631\u06CC\u06BA")
            background = null
            textSize = 14f
            addTextChangedListener(object : android.text.TextWatcher {
                override fun beforeTextChanged(s: CharSequence?, start: Int, count: Int, after: Int) {}
                override fun onTextChanged(s: CharSequence?, start: Int, before: Int, count: Int) {}
                override fun afterTextChanged(s: android.text.Editable?) {
                    query = s?.toString().orEmpty()
                    renderRows()
                }
            })
        }
        searchBox.addView(searchField)
        body.addView(searchBox)

        val filterRow = LinearLayout(this).apply {
            orientation = LinearLayout.HORIZONTAL
            setPadding(0, 0, 0, 14)
        }
        fun filterChip(label: String, f: ReportFilter): TextView = TextView(this).apply {
            text = label
            textSize = 12f
            setTypeface(typeface, android.graphics.Typeface.BOLD)
            setPadding(24, 12, 24, 12)
            val lp = LinearLayout.LayoutParams(LinearLayout.LayoutParams.WRAP_CONTENT, LinearLayout.LayoutParams.WRAP_CONTENT)
            lp.marginEnd = 10
            layoutParams = lp
            setOnClickListener {
                filter = f
                updateFilterChipStyles()
                renderRows()
            }
        }
        chipFilterAll = filterChip(Loc.t(this, "All", "\u0633\u0628"), ReportFilter.ALL)
        chipFilterReceived = filterChip(Loc.t(this, "Received", "\u0648\u0635\u0648\u0644 \u06C1\u0648\u0626\u06CC"), ReportFilter.RECEIVED)
        chipFilterMade = filterChip(Loc.t(this, "Made", "\u0627\u062F\u0627 \u06C1\u0648\u0626\u06CC"), ReportFilter.MADE)
        listOf(chipFilterAll, chipFilterReceived, chipFilterMade).forEach { filterRow.addView(it) }
        body.addView(filterRow)
        updateFilterChipStyles()

        listContainer = LinearLayout(this).apply { orientation = LinearLayout.VERTICAL }
        body.addView(listContainer)
        body.addView(spacer(30))

        root.addView(body)
        setContentView(ScrollView(this).apply {
            setBackgroundColor(Color.parseColor(bg))
            addView(root)
        })

        loadReport()
    }

    private fun updatePeriodChipStyles() {
        fun style(chip: TextView, p: ReportPeriod) {
            val active = period == p
            chip.background = roundedBg(if (active) teal else "#EEF0F7", 20)
            chip.setTextColor(if (active) Color.WHITE else Color.parseColor(textMuted))
        }
        style(chipToday, ReportPeriod.TODAY)
        style(chipWeek, ReportPeriod.WEEK)
        style(chipMonth, ReportPeriod.MONTH)
        style(chipAll, ReportPeriod.ALL)
    }

    private fun updateFilterChipStyles() {
        fun style(chip: TextView, f: ReportFilter, color: String) {
            val active = filter == f
            chip.background = roundedBg(if (active) color else "#EEF0F7", 20)
            chip.setTextColor(if (active) Color.WHITE else Color.parseColor(textMuted))
        }
        style(chipFilterAll, ReportFilter.ALL, teal)
        style(chipFilterReceived, ReportFilter.RECEIVED, green)
        style(chipFilterMade, ReportFilter.MADE, red)
    }

    private fun periodBounds(): Pair<Long, Long>? {
        if (period == ReportPeriod.ALL) return null
        val cal = Calendar.getInstance()
        cal.set(Calendar.HOUR_OF_DAY, 0); cal.set(Calendar.MINUTE, 0)
        cal.set(Calendar.SECOND, 0); cal.set(Calendar.MILLISECOND, 0)
        when (period) {
            ReportPeriod.WEEK -> cal.set(Calendar.DAY_OF_WEEK, cal.firstDayOfWeek)
            ReportPeriod.MONTH -> cal.set(Calendar.DAY_OF_MONTH, 1)
            else -> {}
        }
        val start = cal.timeInMillis
        return Pair(start, System.currentTimeMillis())
    }

    private fun loadReport() {
        lifecycleScope.launch {
            val db = PosDatabase.get(this@PaymentsReportActivity)
            val customers = db.customerDao().allList().associateBy { it.id }
            val suppliers = db.supplierDao().allList().associateBy { it.id }
            val bounds = periodBounds()

            // FIX (Bug 1 — bill-payments leaking into this "standalone payments only"
            // report): mirrors PartyRepository.recalculateBalances()'s reasoning — a
            // payment whose `reference` matches a real sale invoice / purchase billNo
            // is the bill-embedded cash row RoomSaleRepository/RoomPurchaseRepository
            // insert alongside `sale.paid`/`purchase.paid`, not a standalone "Receive
            // Payment"/"Make Payment" entry. Collected across ALL parties (not scoped
            // to one, since this report is all-parties) so those get excluded here too.
            val saleInvoices = db.saleDao().allRaw().map { it.invoice }.toHashSet()
            val purchaseBillNos = db.purchaseDao().allRaw().map { it.billNo }.toHashSet()

            val rows = db.paymentDao().allRaw()
                .filter { p -> bounds == null || p.createdAt in bounds.first..bounds.second }
                .filter { p -> p.reference !in saleInvoices && p.reference !in purchaseBillNos }
                .mapNotNull { p ->
                    when (p.partyType) {
                        "customer" -> customers[p.partyId]?.let { ReportRow(p, it.name, it.id, true) }
                        "supplier" -> suppliers[p.partyId]?.let { ReportRow(p, it.name, it.id, false) }
                        else -> null
                    }
                }
                .sortedByDescending { it.payment.createdAt }

            allRows = rows
            renderRows()
        }
    }

    private fun renderRows() {
        val received = allRows.filter { it.isCustomer }.sumOf { it.payment.amount }
        val made = allRows.filter { !it.isCustomer }.sumOf { it.payment.amount }
        receivedValueText.text = "Rs %.2f".format(received)
        madeValueText.text = "Rs %.2f".format(made)
        val net = received - made
        netValueText.text = "Rs %.2f".format(kotlin.math.abs(net))
        netValueText.setTextColor(Color.parseColor(if (net >= 0) green else red))

        val q = query.trim().lowercase()
        val fmt = SimpleDateFormat("dd MMM yyyy, hh:mm a", Locale.getDefault())
        val filtered = allRows.filter { row ->
            val passesFilter = when (filter) {
                ReportFilter.ALL -> true
                ReportFilter.RECEIVED -> row.isCustomer
                ReportFilter.MADE -> !row.isCustomer
            }
            val text = "${row.partyName} ${row.payment.note} ${row.payment.method} ${row.payment.billReference}".lowercase()
            passesFilter && (q.isEmpty() || text.contains(q))
        }

        listContainer.removeAllViews()
        if (filtered.isEmpty()) {
            listContainer.addView(TextView(this).apply {
                text = if (allRows.isEmpty()) Loc.t(this@PaymentsReportActivity, "No payments in this period", "\u0627\u0633 \u0645\u062F\u062A \u0645\u06CC\u06BA \u06A9\u0648\u0626\u06CC \u0627\u062F\u0627\u0626\u06CC\u06AF\u06CC \u0646\u06C1\u06CC\u06BA")
                    else Loc.t(this@PaymentsReportActivity, "No matching payments", "\u06A9\u0648\u0626\u06CC \u0645\u0645\u0627\u062B\u0644 \u0627\u062F\u0627\u0626\u06AF\u06CC \u0646\u06C1\u06CC\u06BA")
                setTextColor(Color.parseColor(textMuted))
                textSize = 13f
                gravity = Gravity.CENTER
                setPadding(0, 40, 0, 40)
            })
            return
        }
        filtered.forEach { row -> listContainer.addView(paymentReportRow(row, fmt)) }
    }

    private fun paymentReportRow(row: ReportRow, fmt: SimpleDateFormat): LinearLayout {
        val accent = if (row.isCustomer) green else red
        return LinearLayout(this).apply {
            orientation = LinearLayout.HORIZONTAL
            gravity = Gravity.CENTER_VERTICAL
            setPadding(18, 14, 18, 14)
            background = GradientDrawable().apply {
                setColor(Color.parseColor(cardWhite))
                cornerRadius = 16f
                setStroke(1, Color.parseColor(border))
            }
            elevation = 2f
            layoutParams = LinearLayout.LayoutParams(LinearLayout.LayoutParams.MATCH_PARENT, LinearLayout.LayoutParams.WRAP_CONTENT).apply { setMargins(0, 0, 0, 10) }
            isClickable = true
            // Tap a row to jump into that party's full transaction history.
            setOnClickListener {
                row.partyId?.let { pid ->
                    startActivity(Intent(this@PaymentsReportActivity, PartyTransactionActivity::class.java).apply {
                        putExtra("partyId", pid)
                        putExtra("partyName", row.partyName)
                        putExtra("isCustomer", row.isCustomer)
                    })
                }
            }

            addView(iconBadge(if (row.isCustomer) R.drawable.ic_trending else R.drawable.ic_trending_down, accent, sizeDp = 38, iconSizeDp = 17))

            val infoCol = LinearLayout(this@PaymentsReportActivity).apply {
                orientation = LinearLayout.VERTICAL
                setPadding(16, 0, 12, 0)
                layoutParams = LinearLayout.LayoutParams(0, LinearLayout.LayoutParams.WRAP_CONTENT, 1f)
            }
            infoCol.addView(TextView(this@PaymentsReportActivity).apply {
                text = row.partyName
                textSize = 13.5f
                setTypeface(typeface, android.graphics.Typeface.BOLD)
                setTextColor(Color.parseColor(textDark))
            })
            val subtitle = fmt.format(Date(row.payment.createdAt)) + "  \u2022  " + row.payment.method.uppercase() +
                (if (row.payment.billReference.isNotEmpty()) "  \u2022  ${row.payment.billReference}" else "") +
                (if (row.payment.note.isNotEmpty()) "  \u2022  ${row.payment.note}" else "")
            infoCol.addView(TextView(this@PaymentsReportActivity).apply {
                text = subtitle
                textSize = 11f
                setTextColor(Color.parseColor(textMuted))
            })
            addView(infoCol)

            addView(TextView(this@PaymentsReportActivity).apply {
                text = "Rs %.2f".format(row.payment.amount)
                textSize = 14f
                setTypeface(typeface, android.graphics.Typeface.BOLD)
                setTextColor(Color.parseColor(accent))
            })
        }
    }
}

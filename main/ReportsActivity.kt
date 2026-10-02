package com.grocerypos.v11.ui

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
import androidx.core.content.ContextCompat
import androidx.lifecycle.lifecycleScope
import com.grocerypos.v11.PosDatabase
import com.grocerypos.v11.R
import com.grocerypos.v11.util.Loc
import kotlinx.coroutines.launch
import java.util.Calendar
import com.grocerypos.v11.ui.components.*

class ReportsActivity : AppCompatActivity() {

    // ================= FLAT PALETTE (aligned with ThemeManager's app-wide flat design tokens) =================
    // Pulled from ThemeManager so this screen respects dark mode, same as Stock Report,
    // History, Party Reports and Balance Sheet.
    private var bg = "#F4F6F8"
    private var cardBg = "#FFFFFF"
    private var primary = "#1450C7"       // flatBlueFg (profit blue)
    private var primaryDark = "#1450C7"
    private var purple = "#1450C7"         // flatBlueFg (merged with primary — one accent everywhere)
    private var amber = "#854F0B"         // flatAmberFg
    private var teal = "#085041"          // flatTealFg
    private var gold = "#854F0B"          // Zakat only — reuses amber (financial)
    private var red = "#D32F4A"           // matches MainActivity's danger/logout red
    private var textDark = "#0B2545"
    private var textGray = "#7C8798"
    private var border = "#E3E8EE"
    private var headerIconTint = "#E3ECFE" // flatBlueBg — header badge behind the reports icon

    private fun loadThemeColors() {
        val p = com.grocerypos.v11.util.ThemeManager.palette(this)
        bg = p.bg
        cardBg = p.cardWhite
        primary = p.flatBlueFg
        primaryDark = p.flatBlueFg
        purple = p.flatBlueFg
        amber = p.flatAmberFg
        teal = p.flatTealFg
        gold = p.flatAmberFg
        red = p.red
        textDark = p.textDark
        textGray = p.textMuted
        border = p.border
        headerIconTint = p.flatBlueBg
    }

    private lateinit var resultsBox: LinearLayout
    private var periodLabel: TextView? = null
    private val filterButtons = mutableListOf<TextView>()

    private var rangeStart: Long = 0
    private var rangeEnd: Long = 0

    override fun onCreate(b: Bundle?) {
        super.onCreate(b)

        // FIX (Phase 4 - Security): role check enforced here — MainActivity only hides
        // the "Reports" tile from cashiers, it doesn't stop them opening this Activity
        // another way.
        val myRole = getSharedPreferences("session", MODE_PRIVATE).getString("role", "cashier") ?: "cashier"
        if (myRole != "admin" && myRole != "manager") {
            Toast.makeText(this, "Sirf Admin/Manager is screen ko access kar sakte hain", Toast.LENGTH_LONG).show()
            finish()
            return
        }

        loadThemeColors()

        val root = LinearLayout(this).apply {
            orientation = LinearLayout.VERTICAL
            setPadding(24, 48, 24, 24)
            setBackgroundColor(Color.parseColor(bg))
        }

        root.addView(premiumHeader(R.drawable.ic_chart, Loc.t(this, "Reports", "رپورٹس"), Loc.t(this, "Sales, stock & financial overview", "سیل، اسٹاک اور مالیاتی جائزہ")))

        root.addView(sectionHeader(Loc.t(this, "Sale reports", "سیل رپورٹس")))
        // ---- CHANGE (Khatabook-style flat list — user request: "flat jesa party
        // ma ha"): each report link used to be a row inside one shared bordered
        // navCard, separated by navDivider() lines, with a pastel-circle icon
        // badge on the left. Swapped for PartyDashboardActivity's borderless-card
        // style: every entry is its own elevated white card (no icon badge, no
        // divider lines) — same shape/spacing/elevation as the Party Dashboard's
        // party rows. navRow()/navDivider() are unused now but left in place
        // below in case another screen still wants the old bordered-list look. ----
        root.addView(khataRow(
            title = Loc.t(this, "Sale History", "سیل کی تاریخ"),
            subtitle = Loc.t(this, "View all sale transactions", "تمام سیل لین دین دیکھیں"),
            accentHex = primary
        ) {
            val i = android.content.Intent(this@ReportsActivity, HistoryActivity::class.java)
            i.putExtra(HistoryActivity.EXTRA_MODE, HistoryActivity.MODE_SALES)
            startActivity(i)
        })

        root.addView(khataRow(
            title = Loc.t(this, "Purchase History", "خریداری کی تاریخ"),
            subtitle = Loc.t(this, "View all purchase transactions", "تمام خریداری لین دین دیکھیں"),
            accentHex = "#993C1D"
        ) {
            val i = android.content.Intent(this@ReportsActivity, HistoryActivity::class.java)
            i.putExtra(HistoryActivity.EXTRA_MODE, HistoryActivity.MODE_PURCHASES)
            startActivity(i)
        })

        root.addView(khataRow(
            title = Loc.t(this, "Party Reports", "پارٹی رپورٹس"),
            subtitle = Loc.t(this, "Customer & supplier balances", "کسٹمر اور سپلائر کا بیلنس"),
            accentHex = purple
        ) { startActivity(android.content.Intent(this@ReportsActivity, PartyReportsActivity::class.java)) })

        // NEW (Payments 10/10 — suggestion #3): all-parties Payments Received vs
        // Made, by Today/Week/Month/All Time — separate from Day Book (mixes
        // payments with sales/purchases/expenses) and Party Reports' Payment
        // History (scoped to one party at a time).
        root.addView(khataRow(
            title = Loc.t(this, "Payments Report", "ادائیگیوں کی رپورٹ"),
            subtitle = Loc.t(this, "Payments received vs made, by period", "ادائیگیاں وصول اور ادا، مدت کے مطابق"),
            accentHex = teal
        ) { startActivity(android.content.Intent(this@ReportsActivity, PaymentsReportActivity::class.java)) })

        // NEW (user request — Total Sale/Total Purchase month & year wise): lists
        // every month (or year) side by side instead of only showing one selected
        // period's total, so e.g. this month can be compared against last month.
        root.addView(khataRow(
            title = Loc.t(this, "Sale vs Purchase — Month/Year", "سیل بمقابلہ خریداری — مہینہ/سال"),
            subtitle = Loc.t(this, "Total sale & purchase, broken down by month or year", "کل سیل اور خریداری، مہینہ یا سال کے مطابق"),
            accentHex = primary
        ) { startActivity(android.content.Intent(this@ReportsActivity, MonthlySalesPurchaseActivity::class.java)) })

        root.addView(khataRow(
            title = Loc.t(this, "Stock Report", "اسٹاک رپورٹ"),
            subtitle = Loc.t(this, "Current inventory levels", "موجودہ انوینٹری کی سطح"),
            accentHex = amber
        ) { startActivity(android.content.Intent(this@ReportsActivity, StockReportActivity::class.java)) })

        // ADDED (Inventory Accounting upgrade — stock_movements table): per-product
        // ledger of every purchase/sale/reversal/edit, and a cost-only view of the
        // same ledger — both backed by StockMovementActivity (see that file).
        root.addView(khataRow(
            title = Loc.t(this, "Stock History", "اسٹاک کی تاریخ"),
            subtitle = Loc.t(this, "Every purchase, sale & adjustment per item", "ہر آئٹم کی خریداری، سیل اور ایڈجسٹمنٹ"),
            accentHex = primary
        ) {
            val i = android.content.Intent(this@ReportsActivity, StockMovementActivity::class.java)
            i.putExtra(StockMovementActivity.EXTRA_MODE, StockMovementActivity.MODE_STOCK)
            startActivity(i)
        })

        root.addView(khataRow(
            title = Loc.t(this, "Cost History", "لاگت کی تاریخ"),
            subtitle = Loc.t(this, "How a product's cost changed over time", "پروڈکٹ کی لاگت وقت کے ساتھ کیسے بدلی"),
            accentHex = teal
        ) {
            val i = android.content.Intent(this@ReportsActivity, StockMovementActivity::class.java)
            i.putExtra(StockMovementActivity.EXTRA_MODE, StockMovementActivity.MODE_COST)
            startActivity(i)
        })

        // NEW (Stock Audit report): finds every product whose `stock` disagrees
        // with the sum of its own stock_movements ledger — the automatic version
        // of the by-hand انڈے investigation, run across every product at once.
        root.addView(khataRow(
            title = Loc.t(this, "Stock Audit", "اسٹاک آڈٹ"),
            subtitle = Loc.t(this, "Find products where stock doesn't match its own history", "وہ پروڈکٹس جن کا اسٹاک اپنی تاریخ سے میچ نہیں کرتا"),
            accentHex = red
        ) { startActivity(android.content.Intent(this@ReportsActivity, StockAuditActivity::class.java)) })

        // NEW: Stock Adjustment (log damage/loss or a manual correction) plus the four
        // Inventory Insights tabs (Reorder Suggestions, Damage/Loss Report, Profit
        // Margin per Item, Fast/Slow Movers) and Due Date Reminders.
        root.addView(khataRow(
            title = Loc.t(this, "Stock Adjustment", "اسٹاک ایڈجسٹمنٹ"),
            subtitle = Loc.t(this, "Log damage, loss, or a correction", "نقصان یا درستگی درج کریں"),
            accentHex = red
        ) { startActivity(android.content.Intent(this@ReportsActivity, StockAdjustmentActivity::class.java)) })

        // NEW (10/10 Priority #9 — Stock Taking): full physical-count-vs-system
        // reconciliation, distinct from Stock Adjustment above (which is for a
        // single known item's damage/loss/correction, not a full recount).
        root.addView(khataRow(
            title = Loc.t(this, "Stock Taking", "اسٹاک گنتی"),
            subtitle = Loc.t(this, "Physical count vs system stock", "اصل گنتی بمقابلہ سسٹم اسٹاک"),
            accentHex = primary
        ) { startActivity(android.content.Intent(this@ReportsActivity, StockTakingActivity::class.java)) })

        root.addView(khataRow(
            title = Loc.t(this, "Reorder Suggestions", "دوبارہ آرڈر تجاویز"),
            subtitle = Loc.t(this, "Items at or below reorder level", "کم اسٹاک آئٹمز"),
            accentHex = amber
        ) {
            val i = android.content.Intent(this@ReportsActivity, InventoryInsightsActivity::class.java)
            i.putExtra(InventoryInsightsActivity.EXTRA_MODE, InventoryInsightsActivity.MODE_REORDER)
            startActivity(i)
        })

        root.addView(khataRow(
            title = Loc.t(this, "Damage / Loss Report", "نقصان کی رپورٹ"),
            subtitle = Loc.t(this, "Value of stock damaged or lost", "خراب یا ضائع اسٹاک کی مالیت"),
            accentHex = red
        ) {
            val i = android.content.Intent(this@ReportsActivity, InventoryInsightsActivity::class.java)
            i.putExtra(InventoryInsightsActivity.EXTRA_MODE, InventoryInsightsActivity.MODE_DAMAGE)
            startActivity(i)
        })

        root.addView(khataRow(
            title = Loc.t(this, "Profit Margin per Item", "فی آئٹم منافع"),
            subtitle = Loc.t(this, "Sale price vs cost, item by item", "سیل پرائس بمقابلہ لاگت"),
            accentHex = teal
        ) {
            val i = android.content.Intent(this@ReportsActivity, InventoryInsightsActivity::class.java)
            i.putExtra(InventoryInsightsActivity.EXTRA_MODE, InventoryInsightsActivity.MODE_PROFIT)
            startActivity(i)
        })

        root.addView(khataRow(
            title = Loc.t(this, "Fast / Slow Movers", "تیز / سست چلنے والے"),
            subtitle = Loc.t(this, "Which items sell, and which don't", "کون سے آئٹم بکتے ہیں"),
            accentHex = purple
        ) {
            val i = android.content.Intent(this@ReportsActivity, InventoryInsightsActivity::class.java)
            i.putExtra(InventoryInsightsActivity.EXTRA_MODE, InventoryInsightsActivity.MODE_MOVERS)
            startActivity(i)
        })

        root.addView(khataRow(
            title = Loc.t(this, "Due Date Reminders", "ادائیگی کی یاد دہانی"),
            subtitle = Loc.t(this, "Credit sales still owed, by due date", "ادھار سیلز جو واجب الادا ہیں"),
            accentHex = primary
        ) { startActivity(android.content.Intent(this@ReportsActivity, DueRemindersActivity::class.java)) })

        root.addView(khataRow(
            title = Loc.t(this, "Balance Sheet", "بیلنس شیٹ"),
            subtitle = Loc.t(this, "Assets, liabilities & capital", "اثاثے، واجبات اور سرمایہ"),
            accentHex = teal
        ) { startActivity(android.content.Intent(this@ReportsActivity, BalanceSheetActivity::class.java)) })

        // NEW: Zakat tracker — Ramadan-to-Ramadan year, auto-calculated from the same
        // asset figures Balance Sheet uses, with monthly-installment support.
        root.addView(khataRow(
            title = Loc.t(this, "Zakat", "زکوٰۃ"),
            subtitle = Loc.t(this, "Track & pay this year's Zakat", "اس سال کی زکوٰۃ ٹریک اور ادا کریں"),
            accentHex = gold
        ) { startActivity(android.content.Intent(this@ReportsActivity, ZakatActivity::class.java)) })

        root.addView(spacer(4))

        // ================= PERIOD FILTER PILLS (matches Items tab-row style) =================
        val filterRow = LinearLayout(this).apply {
            orientation = LinearLayout.HORIZONTAL
            background = strokedBg(border, cardBg, 14)
            setPadding(6, 6, 6, 6)
            layoutParams = LinearLayout.LayoutParams(LinearLayout.LayoutParams.MATCH_PARENT, LinearLayout.LayoutParams.WRAP_CONTENT)
                .apply { setMargins(0, 0, 0, 4) }
        }
        val today = filterPill(Loc.t(this, "Today", "آج")) { setRangeToday(); loadReport() }
        val week = filterPill(Loc.t(this, "This Week", "اس ہفتے")) { setRangeThisWeek(); loadReport() }
        val month = filterPill(Loc.t(this, "This Month", "اس مہینے")) { setRangeThisMonth(); loadReport() }
        val all = filterPill(Loc.t(this, "All Time", "تمام وقت")) { setRangeAllTime(); loadReport() }
        filterButtons.addAll(listOf(today, week, month, all))
        filterRow.addView(today)
        filterRow.addView(week)
        filterRow.addView(month)
        filterRow.addView(all)
        root.addView(filterRow)

        periodLabel = TextView(this).apply {
            textSize = 11.5f
            setTextColor(Color.parseColor(textGray))
            setTypeface(typeface, Typeface.BOLD)
            setPadding(6, 14, 0, 6)
        }
        root.addView(periodLabel)

        resultsBox = LinearLayout(this).apply { orientation = LinearLayout.VERTICAL }
        root.addView(resultsBox)

        val scroll = ScrollView(this).apply {
            setBackgroundColor(Color.parseColor(bg))
            addView(root)
        }
        setContentView(scroll)

        setRangeToday()
        loadReport()
    }

    // ---- Date range helpers ----
    private fun setRangeToday() {
        val cal = Calendar.getInstance()
        cal.set(Calendar.HOUR_OF_DAY, 0); cal.set(Calendar.MINUTE, 0)
        cal.set(Calendar.SECOND, 0); cal.set(Calendar.MILLISECOND, 0)
        rangeStart = cal.timeInMillis
        rangeEnd = rangeStart + 24 * 60 * 60 * 1000L
        periodLabel?.text = Loc.t(this, "SHOWING: TODAY", "دکھایا جا رہا ہے: آج")
        highlightFilter(0)
    }

    private fun setRangeThisWeek() {
        val cal = Calendar.getInstance()
        cal.set(Calendar.DAY_OF_WEEK, cal.firstDayOfWeek)
        cal.set(Calendar.HOUR_OF_DAY, 0); cal.set(Calendar.MINUTE, 0)
        cal.set(Calendar.SECOND, 0); cal.set(Calendar.MILLISECOND, 0)
        rangeStart = cal.timeInMillis
        rangeEnd = System.currentTimeMillis()
        periodLabel?.text = Loc.t(this, "SHOWING: THIS WEEK", "دکھایا جا رہا ہے: اس ہفتے")
        highlightFilter(1)
    }

    private fun setRangeThisMonth() {
        val cal = Calendar.getInstance()
        cal.set(Calendar.DAY_OF_MONTH, 1)
        cal.set(Calendar.HOUR_OF_DAY, 0); cal.set(Calendar.MINUTE, 0)
        cal.set(Calendar.SECOND, 0); cal.set(Calendar.MILLISECOND, 0)
        rangeStart = cal.timeInMillis
        rangeEnd = System.currentTimeMillis()
        periodLabel?.text = Loc.t(this, "SHOWING: THIS MONTH", "دکھایا جا رہا ہے: اس مہینے")
        highlightFilter(2)
    }

    private fun setRangeAllTime() {
        rangeStart = 0L
        rangeEnd = System.currentTimeMillis()
        periodLabel?.text = Loc.t(this, "SHOWING: ALL TIME", "دکھایا جا رہا ہے: تمام وقت")
        highlightFilter(3)
    }

    private fun highlightFilter(activeIndex: Int) {
        filterButtons.forEachIndexed { i, btn ->
            if (i == activeIndex) {
                btn.background = roundedBg(primary, 10)
                btn.setTextColor(Color.WHITE)
            } else {
                btn.setBackgroundColor(Color.TRANSPARENT)
                btn.setTextColor(Color.parseColor(textGray))
            }
        }
    }

    // ---- Load and display ----
    private fun loadReport() {
        resultsBox.removeAllViews()

        lifecycleScope.launch {
            val db = PosDatabase.get(this@ReportsActivity)

            val totalSales = db.saleDao().totalSalesBetween(rangeStart, rangeEnd)
            val totalProfit = db.saleDao().profitBetween(rangeStart, rangeEnd)
            val totalPurchases = db.purchaseDao().totalBetween(rangeStart, rangeEnd)
            val totalExpenses = db.expenseDao().totalBetween(rangeStart, rangeEnd)
            val saleCount = db.saleDao().countBetween(rangeStart, rangeEnd)
            val topProducts = db.saleDao().topProducts(rangeStart, rangeEnd)
            val dailySales = db.saleDao().dailySales(rangeStart, rangeEnd)

            // ---- Returns for this period ----
            val totalSaleReturns = db.returnDao().totalByTypeBetween("sale", rangeStart, rangeEnd)
            val totalPurchaseReturns = db.returnDao().totalByTypeBetween("purchase", rangeStart, rangeEnd)

            // ---- Profit & Loss inputs ----
            val cogs = db.saleDao().cogsBetween(rangeStart, rangeEnd)
            val grossProfit = totalSales - cogs
            val netProfit = grossProfit - totalExpenses

            resultsBox.removeAllViews()

            resultsBox.addView(summaryCard(R.drawable.ic_wallet, Loc.t(this@ReportsActivity, "Total Sales", "کل سیل"), "Rs %.2f".format(totalSales), primary, "#EEEDFE"))
            resultsBox.addView(summaryCard(R.drawable.ic_trending, Loc.t(this@ReportsActivity, "Total Profit", "کل منافع"), "Rs %.2f".format(totalProfit), teal, "#E1F5EE"))
            resultsBox.addView(summaryCard(R.drawable.ic_receipt, Loc.t(this@ReportsActivity, "Total Purchases", "کل خریداری"), "Rs %.2f".format(totalPurchases), amber, "#FAEEDA"))
            resultsBox.addView(summaryCard(R.drawable.ic_trending_down, Loc.t(this@ReportsActivity, "Total Expenses", "کل اخراجات"), "Rs %.2f".format(totalExpenses), red, "#FCEBEB"))
            resultsBox.addView(summaryCard(R.drawable.ic_undo, Loc.t(this@ReportsActivity, "Sale Returns", "سیل کی واپسی"), "Rs %.2f".format(totalSaleReturns), "#AD1457", "#FCE4EC"))
            resultsBox.addView(summaryCard(R.drawable.ic_undo, Loc.t(this@ReportsActivity, "Purchase Returns", "خریداری کی واپسی"), "Rs %.2f".format(totalPurchaseReturns), teal, "#E1F5EE"))
            resultsBox.addView(summaryCard(R.drawable.ic_number, Loc.t(this@ReportsActivity, "Number of Sales", "سیلز کی تعداد"), "$saleCount", purple, "#EEEDFE"))

            resultsBox.addView(spacer(10))

            resultsBox.addView(
                profitLossCard(
                    revenue = totalSales,
                    cogs = cogs,
                    grossProfit = grossProfit,
                    expenses = totalExpenses,
                    netProfit = netProfit
                )
            )

            resultsBox.addView(spacer(14))

            resultsBox.addView(listCard(Loc.t(this@ReportsActivity, "Top Products", "ٹاپ پروڈکٹس"), topProducts.isEmpty(), Loc.t(this@ReportsActivity, "No sales in this period", "اس مدت میں کوئی سیل نہیں ہوئی")) { box ->
                topProducts.forEach { tp -> box.addView(rowText(tp.product, "${tp.totalQty} " + Loc.t(this@ReportsActivity, "sold", "فروخت شدہ"))) }
            })

            resultsBox.addView(spacer(14))

            resultsBox.addView(listCard(Loc.t(this@ReportsActivity, "Daily Sales", "روزانہ سیل"), dailySales.isEmpty(), Loc.t(this@ReportsActivity, "No data", "کوئی ڈیٹا نہیں")) { box ->
                dailySales.forEach { d -> box.addView(rowText(d.day, "Rs %.2f".format(d.total))) }
            })

            resultsBox.addView(spacer(30))
        }
    }

    // ================= FLAT HEADER (matches MainActivity's flat surface) =================
    private fun premiumHeader(iconRes: Int, title: String, subtitle: String): LinearLayout {
        val header = LinearLayout(this).apply {
            orientation = LinearLayout.HORIZONTAL
            gravity = Gravity.CENTER_VERTICAL
            setPadding(20, 18, 20, 18)
            background = strokedBg(border, cardBg, 22)
            layoutParams = LinearLayout.LayoutParams(
                LinearLayout.LayoutParams.MATCH_PARENT, LinearLayout.LayoutParams.WRAP_CONTENT
            ).apply { setMargins(0, 0, 0, 20) }
        }
        header.addView(TextView(this).apply {
            text = "‹"
            textSize = 20f
            setTextColor(Color.parseColor(textDark))
            setTypeface(typeface, Typeface.BOLD)
            gravity = Gravity.CENTER
            background = ovalBg(border)
            val px = (36 * resources.displayMetrics.density).toInt()
            layoutParams = android.view.ViewGroup.LayoutParams(px, px)
            setOnClickListener { finish() }
        })
        header.addView(View(this).apply { layoutParams = LinearLayout.LayoutParams(14, 1) })
        header.addView(circleIcon(iconRes, headerIconTint, 42))
        header.addView(View(this).apply { layoutParams = LinearLayout.LayoutParams(16, 1) })
        val headerCol = LinearLayout(this).apply {
            orientation = LinearLayout.VERTICAL
            layoutParams = LinearLayout.LayoutParams(0, LinearLayout.LayoutParams.WRAP_CONTENT, 1f)
        }
        headerCol.addView(TextView(this).apply {
            text = title
            textSize = 19f
            setTextColor(Color.parseColor(textDark))
            setTypeface(typeface, Typeface.BOLD)
        })
        headerCol.addView(TextView(this).apply {
            text = subtitle
            textSize = 11f
            setTextColor(Color.parseColor(textGray))
            setPadding(0, 4, 0, 0)
        })
        header.addView(headerCol)
        return header
    }

    // ---- UI helpers ----
    private fun summaryCard(iconRes: Int, label: String, value: String, accentHex: String, tintHex: String): LinearLayout {
        return LinearLayout(this).apply {
            orientation = LinearLayout.HORIZONTAL
            gravity = Gravity.CENTER_VERTICAL
            setPadding(22, 20, 22, 20)
            background = strokedBg(border, cardBg, 18)
            layoutParams = LinearLayout.LayoutParams(
                LinearLayout.LayoutParams.MATCH_PARENT, LinearLayout.LayoutParams.WRAP_CONTENT
            ).apply { setMargins(0, 0, 0, 10) }
            applyElevation(this, 2f)

            addView(FrameLayout(this@ReportsActivity).apply {
                val size = (40 * resources.displayMetrics.density).toInt()
                layoutParams = LinearLayout.LayoutParams(size, size)
                background = GradientDrawable().apply {
                    shape = GradientDrawable.OVAL
                    setColor(Color.parseColor(tintHex))
                }
                addView(ImageView(this@ReportsActivity).apply {
                    setImageDrawable(tintedDrawable(iconRes, accentHex, 17))
                    scaleType = ImageView.ScaleType.CENTER
                    layoutParams = FrameLayout.LayoutParams(FrameLayout.LayoutParams.MATCH_PARENT, FrameLayout.LayoutParams.MATCH_PARENT)
                })
            })

            val textCol = LinearLayout(this@ReportsActivity).apply {
                orientation = LinearLayout.VERTICAL
                setPadding(18, 0, 0, 0)
            }
            textCol.addView(TextView(this@ReportsActivity).apply {
                text = label; setTextColor(Color.parseColor(textGray)); textSize = 12.5f
                setTypeface(typeface, Typeface.BOLD)
            })
            textCol.addView(TextView(this@ReportsActivity).apply {
                text = value; setTextColor(Color.parseColor(accentHex)); textSize = 18f
                setTypeface(typeface, Typeface.BOLD)
                setPadding(0, 4, 0, 0)
            })
            addView(textCol)
        }
    }

    /**
     * Profit & Loss statement card:
     *   Sales Revenue
     *   (-) Cost of Goods Sold
     *   = Gross Profit
     *   (-) Operating Expenses
     *   = Net Profit / Loss
     */
    private fun profitLossCard(
        revenue: Double,
        cogs: Double,
        grossProfit: Double,
        expenses: Double,
        netProfit: Double
    ): LinearLayout {
        val netColor = if (netProfit >= 0) teal else red
        return LinearLayout(this).apply {
            orientation = LinearLayout.VERTICAL
            setPadding(22, 20, 22, 20)
            background = strokedBg(border, cardBg, 18)
            applyElevation(this, 2f)

            val titleRow = LinearLayout(this@ReportsActivity).apply {
                orientation = LinearLayout.HORIZONTAL
                gravity = Gravity.CENTER_VERTICAL
                setPadding(0, 0, 0, 14)
            }
            titleRow.addView(ImageView(this@ReportsActivity).apply {
                setImageDrawable(tintedDrawable(R.drawable.ic_chart, textDark, 15))
                val px = (15 * resources.displayMetrics.density).toInt()
                layoutParams = LinearLayout.LayoutParams(px, px).apply {
                    marginEnd = (8 * resources.displayMetrics.density).toInt()
                }
            })
            titleRow.addView(TextView(this@ReportsActivity).apply {
                text = Loc.t(this@ReportsActivity, "Profit & Loss Statement", "منافع اور نقصان کا بیان")
                textSize = 15f
                setTextColor(Color.parseColor(textDark))
                setTypeface(typeface, Typeface.BOLD)
            })
            addView(titleRow)

            addView(plRow(Loc.t(this@ReportsActivity, "Sales Revenue", "سیل کی آمدنی"), revenue, textDark, bold = false))
            addView(plRow(Loc.t(this@ReportsActivity, "(-) Cost of Goods Sold", "(-) فروخت شدہ سامان کی لاگت"), cogs, red, bold = false, isDeduction = true))
            addView(plDivider())
            addView(plRow(Loc.t(this@ReportsActivity, "Gross Profit", "مجموعی منافع"), grossProfit, primary, bold = true))
            addView(spacer(4))
            addView(plRow(Loc.t(this@ReportsActivity, "(-) Operating Expenses", "(-) آپریٹنگ اخراجات"), expenses, red, bold = false, isDeduction = true))
            addView(plDivider())
            addView(plRow(if (netProfit >= 0) Loc.t(this@ReportsActivity, "Net Profit", "خالص منافع") else Loc.t(this@ReportsActivity, "Net Loss", "خالص نقصان"), netProfit, netColor, bold = true, big = true))
        }
    }

    private fun plRow(label: String, amount: Double, colorHex: String, bold: Boolean, isDeduction: Boolean = false, big: Boolean = false): LinearLayout {
        val displayAmount = "Rs %.2f".format(amount)
        return LinearLayout(this).apply {
            orientation = LinearLayout.HORIZONTAL
            setPadding(0, 6, 0, 6)
            addView(TextView(this@ReportsActivity).apply {
                text = label
                textSize = if (big) 15f else 13.5f
                setTextColor(if (bold) Color.parseColor(textDark) else Color.parseColor(textGray))
                if (bold) setTypeface(typeface, Typeface.BOLD)
                layoutParams = LinearLayout.LayoutParams(0, LinearLayout.LayoutParams.WRAP_CONTENT, 1f)
            })
            addView(TextView(this@ReportsActivity).apply {
                text = displayAmount
                textSize = if (big) 16f else 13.5f
                setTextColor(Color.parseColor(colorHex))
                setTypeface(typeface, if (bold) Typeface.BOLD else Typeface.NORMAL)
                gravity = Gravity.END
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

    private fun listCard(title: String, isEmpty: Boolean, emptyMsg: String, fill: (LinearLayout) -> Unit): LinearLayout {
        return LinearLayout(this).apply {
            orientation = LinearLayout.VERTICAL
            setPadding(22, 20, 22, 16)
            background = strokedBg(border, cardBg, 18)
            applyElevation(this, 2f)

            addView(TextView(this@ReportsActivity).apply {
                text = title; textSize = 15f
                setTextColor(Color.parseColor(textDark))
                setTypeface(typeface, Typeface.BOLD)
                setPadding(0, 0, 0, 8)
            })
            if (isEmpty) {
                addView(emptyText(emptyMsg))
            } else {
                fill(this)
            }
        }
    }

    private fun rowText(left: String, right: String): LinearLayout {
        return LinearLayout(this).apply {
            orientation = LinearLayout.HORIZONTAL
            setPadding(4, 10, 4, 10)
            addView(TextView(this@ReportsActivity).apply {
                text = left; textSize = 14f
                setTextColor(Color.parseColor(textDark))
                layoutParams = LinearLayout.LayoutParams(0, LinearLayout.LayoutParams.WRAP_CONTENT, 1f)
            })
            addView(TextView(this@ReportsActivity).apply {
                text = right; textSize = 14f; gravity = Gravity.END
                setTextColor(Color.parseColor(primary))
                setTypeface(typeface, Typeface.BOLD)
            })
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

    private fun sectionHeader(title: String): TextView {
        return TextView(this).apply {
            text = title
            textSize = 12.5f
            setTextColor(Color.parseColor(textGray))
            setTypeface(typeface, Typeface.BOLD)
            setPadding(4, 0, 0, 10)
        }
    }

    // ---- Nav row (Sale/Purchase History, Party Reports, Stock Report, Balance Sheet) ----
    private fun navRow(
        iconRes: Int,
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

            addView(FrameLayout(this@ReportsActivity).apply {
                val size = (42 * resources.displayMetrics.density).toInt()
                layoutParams = LinearLayout.LayoutParams(size, size)
                background = GradientDrawable().apply {
                    shape = GradientDrawable.OVAL
                    setColor(Color.parseColor(tintHex))
                }
                addView(ImageView(this@ReportsActivity).apply {
                    setImageDrawable(tintedDrawable(iconRes, accentHex, 18))
                    scaleType = ImageView.ScaleType.CENTER
                    layoutParams = FrameLayout.LayoutParams(FrameLayout.LayoutParams.MATCH_PARENT, FrameLayout.LayoutParams.MATCH_PARENT)
                })
            })

            val textCol = LinearLayout(this@ReportsActivity).apply {
                orientation = LinearLayout.VERTICAL
                setPadding(16, 0, 8, 0)
                layoutParams = LinearLayout.LayoutParams(0, LinearLayout.LayoutParams.WRAP_CONTENT, 1f)
            }
            textCol.addView(TextView(this@ReportsActivity).apply {
                text = title
                textSize = 14.5f
                setTextColor(Color.parseColor(textDark))
                setTypeface(typeface, Typeface.BOLD)
            })
            textCol.addView(TextView(this@ReportsActivity).apply {
                text = subtitle
                textSize = 11.5f
                setTextColor(Color.parseColor(textGray))
                setPadding(0, 3, 0, 0)
            })
            addView(textCol)

            addView(TextView(this@ReportsActivity).apply {
                text = "\u203A"
                textSize = 18f
                setTextColor(Color.parseColor(accentHex))
                setTypeface(typeface, Typeface.BOLD)
                setPadding(8, 0, 4, 0)
            })
        }
    }

    // ---- Khatabook-style row (matches PartyDashboardActivity's dashboardPartyRow
    // shape/spacing exactly): borderless white card, soft shadow instead of a
    // stroke, no icon badge — just title + subtitle on the left and a colored
    // chevron on the right. Each call site adds its own card directly to `root`
    // (no shared bordered navCard wrapper, no divider lines between rows). ----
    private fun khataRow(
        title: String,
        subtitle: String,
        accentHex: String,
        onClick: () -> Unit
    ): LinearLayout {
        return LinearLayout(this).apply {
            orientation = LinearLayout.HORIZONTAL
            gravity = Gravity.CENTER_VERTICAL
            setPadding(20, 18, 20, 18)
            background = elevatedCardBg()
            elevation = 1.5f
            layoutParams = LinearLayout.LayoutParams(
                LinearLayout.LayoutParams.MATCH_PARENT, LinearLayout.LayoutParams.WRAP_CONTENT
            ).apply { setMargins(0, 0, 0, 12) }
            isClickable = true
            isFocusable = true
            setOnClickListener { onClick() }

            val textCol = LinearLayout(this@ReportsActivity).apply {
                orientation = LinearLayout.VERTICAL
                layoutParams = LinearLayout.LayoutParams(0, LinearLayout.LayoutParams.WRAP_CONTENT, 1f)
            }
            textCol.addView(TextView(this@ReportsActivity).apply {
                text = title
                textSize = 15f
                setTypeface(typeface, Typeface.BOLD)
                setTextColor(Color.parseColor("#2E3242"))
            })
            textCol.addView(TextView(this@ReportsActivity).apply {
                text = subtitle
                textSize = 11.5f
                setTextColor(Color.parseColor(textGray))
                setPadding(0, 4, 0, 0)
            })
            addView(textCol)

            addView(TextView(this@ReportsActivity).apply {
                text = "\u203A"
                textSize = 20f
                setTextColor(Color.parseColor(accentHex))
                setTypeface(typeface, Typeface.BOLD)
                setPadding(8, 0, 0, 0)
            })
        }
    }

    // Same shape as PartyDashboardActivity/PartyActivity's elevatedCardBg(): no
    // stroke, floats on the off-white background on a soft shadow only.
    private fun elevatedCardBg() = GradientDrawable().apply {
        setColor(Color.parseColor(cardBg))
        cornerRadius = 20f
    }

    private fun navDivider(): View {
        return View(this).apply {
            setBackgroundColor(Color.parseColor(border))
            layoutParams = LinearLayout.LayoutParams(LinearLayout.LayoutParams.MATCH_PARENT, 1).apply {
                setMargins(20, 0, 20, 0)
            }
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

    // ================= SHARED UI HELPERS (matches Items/Categories) =================
    private fun tintedDrawable(iconRes: Int, tintHex: String, sizeDp: Int = 16): android.graphics.drawable.Drawable? {
        val d = ContextCompat.getDrawable(this, iconRes)?.mutate() ?: return null
        d.setTint(Color.parseColor(tintHex))
        val px = (sizeDp * resources.displayMetrics.density).toInt()
        d.setBounds(0, 0, px, px)
        return d
    }

    private fun circleIcon(iconRes: Int, colorHex: String, sizeDp: Int) = ImageView(this).apply {
        setImageDrawable(tintedDrawable(iconRes, textDark, (sizeDp * 0.5).toInt()))
        scaleType = ImageView.ScaleType.CENTER
        background = ovalBg(colorHex)
        val px = (sizeDp * resources.displayMetrics.density).toInt()
        layoutParams = android.view.ViewGroup.LayoutParams(px, px)
    }

    // ---- Flat design has no shadows/elevation — kept as a no-op so existing call sites
    // (navCard, summaryCard, etc.) don't need to be touched individually. ----
    private fun applyElevation(view: View, dp: Float) {
        // intentionally flat — no elevation
    }

    // spacer() now comes from the shared UiHelpers.kt (item #24 dedup) — was a
    // byte-identical private copy here before.
}

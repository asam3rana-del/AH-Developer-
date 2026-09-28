package com.grocerypos.v11.ui

import android.graphics.Color
import android.graphics.Typeface
import android.os.Build
import android.os.Bundle
import android.view.Gravity
import android.view.View
import android.view.ViewOutlineProvider
import android.widget.FrameLayout
import android.widget.LinearLayout
import android.widget.ScrollView
import android.widget.TextView
import android.widget.Toast
import androidx.appcompat.app.AppCompatActivity
import androidx.lifecycle.lifecycleScope
import com.grocerypos.v11.PosDatabase
import com.grocerypos.v11.R
import com.grocerypos.v11.data.PartyRepository
import com.grocerypos.v11.smallestUnitFactor
import com.grocerypos.v11.util.Loc
import kotlinx.coroutines.flow.first
import kotlinx.coroutines.launch
import com.grocerypos.v11.ui.components.*

/**
 * Balance Sheet: Assets = Liabilities + Capital, built entirely from data the
 * app already tracks — nothing new to enter.
 *
 *   ASSETS
 *     Cash in Hand        = all-time cash_transactions IN(cash) - OUT(cash)
 *     Bank Balance         = all-time cash_transactions IN(bank) - OUT(bank)
 *     Stock in Hand (cost) = SUM(product.stock * cost-per-SMALLEST-unit)     [see FIX note below]
 *     Accounts Receivable  = SUM(customer.balance) where balance > 0    [customer owes us]
 *     Advance Paid to Suppliers = SUM(-supplier.balance) where balance < 0
 *
 *   LIABILITIES
 *     Accounts Payable     = SUM(supplier.balance) where balance > 0    [we owe supplier]
 *     Advance from Customers = SUM(-customer.balance) where balance < 0
 *
 *   CAPITAL / EQUITY
 *     Net Profit (all-time) = Total Sales − COGS − Total Expenses       [same formula as ReportsActivity's P&L]
 *     Capital (calculated)  = Total Assets − Total Liabilities − Net Profit
 *       (the balancing figure — this app has no separate "owner's capital injected"
 *        entry point, so whatever isn't accounted for by accumulated profit is shown
 *        here as Capital, and Assets will always equal Liabilities + Capital by
 *        construction)
 *
 * FIX (stock value was showing absurdly large numbers): this screen used to call
 * productDao().stockValueTotal(), a raw SQL SUM(stock*cost). That's wrong because
 * `stock` is stored in the product's SMALLEST unit (e.g. pcs inside a carton) while
 * `cost` is the rate per PRIMARY unit (e.g. Rs per carton) — multiplying them
 * directly overstates value by the unit-conversion factor (sometimes hundreds of
 * times). Stock value is now computed here in Kotlin the same way StockReportActivity
 * already does it correctly: cost is divided by the product's smallestUnitFactor()
 * before multiplying by stock, so it's always a true "cost per smallest unit".
 */
class BalanceSheetActivity : AppCompatActivity() {

    // ================= PREMIUM PALETTE (shared with Items / Categories / Reports) =================
    // Pulled from ThemeManager so this screen respects dark mode. Header was a
    // primary→primaryDark gradient; now flat like the rest of the app.
    private var bg = "#F3F2FA"
    private var cardBg = "#FFFFFF"
    private var primary = "#1450C7"
    private var primaryDark = "#1450C7"
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
        teal = p.flatTealFg
        red = p.red
        textDark = p.textDark
        textGray = p.textMuted
        border = p.border
    }

    private lateinit var resultsBox: LinearLayout

    override fun onCreate(b: Bundle?) {
        super.onCreate(b)
        loadThemeColors()

        val myRole = getSharedPreferences("session", MODE_PRIVATE).getString("role", "cashier") ?: "cashier"
        if (myRole != "admin" && myRole != "manager") {
            Toast.makeText(this, "Sirf Admin/Manager is screen ko access kar sakte hain", Toast.LENGTH_LONG).show()
            finish()
            return
        }

        val root = LinearLayout(this).apply {
            orientation = LinearLayout.VERTICAL
            setPadding(24, 48, 24, 24)
            setBackgroundColor(Color.parseColor(bg))
        }

        root.addView(premiumHeader(R.drawable.ic_bank, Loc.t(this, "Balance Sheet", "بیلنس شیٹ"), Loc.t(this, "As of today • all-time figures", "آج تک • تمام وقت کے اعداد و شمار")))

        resultsBox = LinearLayout(this).apply { orientation = LinearLayout.VERTICAL }
        root.addView(resultsBox)

        val scroll = ScrollView(this).apply {
            setBackgroundColor(Color.parseColor(bg))
            addView(root)
        }
        setContentView(scroll)

        loadBalanceSheet()
    }

    private fun loadBalanceSheet() {
        resultsBox.removeAllViews()
        lifecycleScope.launch {
            val db = PosDatabase.get(this@BalanceSheetActivity)

            // ---- Assets ----
            val cashInHand = db.cashTransactionDao().totalAll("IN", "cash") - db.cashTransactionDao().totalAll("OUT", "cash")
            val bankBalance = db.cashTransactionDao().totalAll("IN", "bank") - db.cashTransactionDao().totalAll("OUT", "bank")

            // FIX: was db.productDao().stockValueTotal() (raw SQL stock*cost, wrong
            // unit basis — see class doc comment). Now computed per-product with the
            // same cost-per-smallest-unit conversion StockReportActivity uses.
            val allProducts = db.productDao().all().first()
            val stockValue = allProducts.sumOf { p ->
                val factor = p.smallestUnitFactor()
                val costPerSmallestUnit = if (factor > 0) p.cost / factor else p.cost
                p.stock * costPerSmallestUnit
            }

            val receivables = db.customerDao().receivablesTotal()
            val advancePaidToSuppliers = db.supplierDao().advancesPaidTotal()
            val totalAssets = cashInHand + bankBalance + stockValue + receivables + advancePaidToSuppliers

            // ---- Liabilities ----
            val payables = db.supplierDao().payablesTotal()
            val advanceFromCustomers = db.customerDao().advancesReceivedTotal()
            val totalLiabilities = payables + advanceFromCustomers

            // ---- Capital / Equity (same P&L formula as ReportsActivity, all-time) ----
            val now = System.currentTimeMillis()
            val totalSales = db.saleDao().totalSalesBetween(0L, now)
            val cogs = db.saleDao().cogsBetween(0L, now)
            val totalExpenses = db.expenseDao().total()
            val netProfit = (totalSales - cogs) - totalExpenses
            val capital = totalAssets - totalLiabilities - netProfit

            resultsBox.removeAllViews()

            resultsBox.addView(sectionHeader(Loc.t(this@BalanceSheetActivity, "ASSETS", "اثاثے")))
            resultsBox.addView(statementCard {
                addStatementRow(it, Loc.t(this@BalanceSheetActivity, "Cash in Hand", "نقد رقم"), cashInHand)
                addStatementRow(it, Loc.t(this@BalanceSheetActivity, "Bank Balance", "بینک بیلنس"), bankBalance)
                addStatementRow(it, Loc.t(this@BalanceSheetActivity, "Stock in Hand (at cost)", "اسٹاک (لاگت پر)"), stockValue)
                addStatementRow(it, Loc.t(this@BalanceSheetActivity, "Accounts Receivable", "قابل وصول رقم"), receivables)
                if (advancePaidToSuppliers > 0) addStatementRow(it, Loc.t(this@BalanceSheetActivity, "Advance Paid to Suppliers", "سپلائرز کو ایڈوانس"), advancePaidToSuppliers)
                addDivider(it)
                addStatementRow(it, Loc.t(this@BalanceSheetActivity, "Total Assets", "کل اثاثے"), totalAssets, bold = true, big = true)
            })

            resultsBox.addView(spacer(16))

            resultsBox.addView(sectionHeader(Loc.t(this@BalanceSheetActivity, "LIABILITIES", "واجبات")))
            resultsBox.addView(statementCard {
                addStatementRow(it, Loc.t(this@BalanceSheetActivity, "Accounts Payable", "قابل ادائیگی رقم"), payables)
                if (advanceFromCustomers > 0) addStatementRow(it, Loc.t(this@BalanceSheetActivity, "Advance from Customers", "کسٹمرز سے ایڈوانس"), advanceFromCustomers)
                addDivider(it)
                addStatementRow(it, Loc.t(this@BalanceSheetActivity, "Total Liabilities", "کل واجبات"), totalLiabilities, bold = true, big = true)
            })

            resultsBox.addView(spacer(16))

            resultsBox.addView(sectionHeader(Loc.t(this@BalanceSheetActivity, "CAPITAL / EQUITY", "سرمایہ")))
            resultsBox.addView(statementCard {
                addStatementRow(it, Loc.t(this@BalanceSheetActivity, "Net Profit (all-time)", "خالص منافع (تمام وقت)"), netProfit)
                addStatementRow(it, Loc.t(this@BalanceSheetActivity, "Capital (calculated)", "سرمایہ (حساب شدہ)"), capital)
                addDivider(it)
                addStatementRow(it, Loc.t(this@BalanceSheetActivity, "Total Liabilities + Capital", "کل واجبات + سرمایہ"), totalLiabilities + capital + netProfit, bold = true, big = true)
            })

            // ADDED (audit — the sheet could never show a mistake): Capital is a plug, so Assets always
            // equal Liabilities + Capital no matter what is wrong underneath. These checks compare
            // the figures against independent sources so real problems become visible.
            val warnings = mutableListOf<String>()
            val drift = PartyRepository(db, applicationContext).recalculateBalances(dryRun = true)
            if (drift.customersFixed > 0 || drift.suppliersFixed > 0) {
                warnings.add(Loc.t(
                    this@BalanceSheetActivity,
                    "${drift.customersFixed} customer(s) and ${drift.suppliersFixed} supplier(s) have a stored balance that does not match their bills/payments — run Fix Balances.",
                    "${drift.customersFixed} کسٹمر اور ${drift.suppliersFixed} سپلائر کا بیلنس ان کے بلوں/ادائیگیوں سے میل نہیں کھاتا — Fix Balances چلائیں۔"
                ))
            }
            if (cashInHand < -0.009 || bankBalance < -0.009) {
                warnings.add(Loc.t(
                    this@BalanceSheetActivity,
                    "Cash or Bank is negative — an opening balance was probably never entered (add it once as a Cash In entry) or an entry is wrong.",
                    "کیش یا بینک منفی ہے — غالباً ابتدائی رقم درج نہیں ہوئی (ایک بار کیش ان میں لکھیں) یا کوئی انٹری غلط ہے۔"
                ))
            }
            if (warnings.isNotEmpty()) {
                resultsBox.addView(spacer(10))
                resultsBox.addView(TextView(this@BalanceSheetActivity).apply {
                    text = "\u26A0 " + warnings.joinToString("\n\n\u26A0 ")
                    textSize = 12.5f
                    setTextColor(Color.parseColor(red))
                    setPadding(6, 4, 6, 8)
                })
            }

            resultsBox.addView(spacer(10))
            resultsBox.addView(TextView(this@BalanceSheetActivity).apply {
                text = Loc.t(
                    this@BalanceSheetActivity,
                    "Note: Capital is a calculated balancing figure (Total Assets \u2212 Total Liabilities \u2212 Net Profit), since owner's injected capital isn't entered separately in this app.",
                    "نوٹ: سرمایہ ایک حساب شدہ balancing figure ہے، کیونکہ مالک کا لگایا گیا سرمایہ اس ایپ میں الگ سے درج نہیں ہوتا۔"
                )
                textSize = 11.5f
                setTextColor(Color.parseColor(textGray))
                setPadding(6, 4, 6, 20)
            })
        }
    }

    // ================= PREMIUM HEADER (matches Items/Categories/Reports) =================

    // ---- UI helpers (mirrors Reports/StockReport card styling) ----

    private fun statementCard(fill: (LinearLayout) -> Unit): LinearLayout {
        return LinearLayout(this).apply {
            orientation = LinearLayout.VERTICAL
            setPadding(22, 18, 22, 16)
            background = strokedBg(border, cardBg, 18)
            applyElevation(this, 2f)
            fill(this)
        }
    }

    private fun addStatementRow(box: LinearLayout, label: String, amount: Double, bold: Boolean = false, big: Boolean = false) {
        val color = if (amount < 0) red else if (bold) primary else textDark
        box.addView(LinearLayout(this).apply {
            orientation = LinearLayout.HORIZONTAL
            setPadding(0, 6, 0, 6)
            addView(TextView(this@BalanceSheetActivity).apply {
                text = label
                textSize = if (big) 15f else 13.5f
                setTextColor(Color.parseColor(if (bold) textDark else textGray))
                if (bold) setTypeface(typeface, Typeface.BOLD)
                layoutParams = LinearLayout.LayoutParams(0, LinearLayout.LayoutParams.WRAP_CONTENT, 1f)
            })
            addView(TextView(this@BalanceSheetActivity).apply {
                text = "Rs %.2f".format(amount)
                textSize = if (big) 16f else 13.5f
                setTextColor(Color.parseColor(color))
                setTypeface(typeface, if (bold) Typeface.BOLD else Typeface.NORMAL)
                gravity = Gravity.END
            })
        })
    }

    private fun addDivider(box: LinearLayout) {
        box.addView(View(this).apply {
            setBackgroundColor(Color.parseColor(border))
            layoutParams = LinearLayout.LayoutParams(LinearLayout.LayoutParams.MATCH_PARENT, 2).apply {
                setMargins(0, 8, 0, 8)
            }
        })
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

    // ================= SHARED UI HELPERS (matches Items/Categories/Reports) =================
    // circleIcon() and spacer() now come from the shared PremiumHeader.kt/UiHelpers.kt
    // (item #24 dedup) — both were byte-identical private copies here before.
}

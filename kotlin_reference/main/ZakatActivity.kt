package com.grocerypos.v11.ui

import android.app.AlertDialog
import android.app.DatePickerDialog
import android.graphics.Color
import android.graphics.Typeface
import android.icu.util.IslamicCalendar
import android.icu.util.Calendar as IcuCalendar
import android.os.Build
import android.os.Bundle
import android.text.InputType
import android.view.Gravity
import android.view.View
import android.view.ViewOutlineProvider
import android.widget.AdapterView
import android.widget.ArrayAdapter
import android.widget.EditText
import android.widget.LinearLayout
import android.widget.ProgressBar
import android.widget.ScrollView
import android.widget.Spinner
import android.widget.TextView
import android.widget.Toast
import androidx.appcompat.app.AppCompatActivity
import androidx.lifecycle.lifecycleScope
import androidx.room.withTransaction
import com.grocerypos.v11.CashTransaction
import com.grocerypos.v11.Expense
import com.grocerypos.v11.PosDatabase
import com.grocerypos.v11.R
import com.grocerypos.v11.SyncQueueHelper
import com.grocerypos.v11.ZakatMonthPlan
import com.grocerypos.v11.ZakatPayment
import com.grocerypos.v11.ZakatYear
import com.grocerypos.v11.smallestUnitFactor
import com.grocerypos.v11.util.Loc
import com.grocerypos.v11.util.parseMoneyOrWarn
import kotlinx.coroutines.flow.first
import kotlinx.coroutines.launch
import java.text.SimpleDateFormat
import java.util.Calendar
import java.util.Date
import java.util.Locale
import com.grocerypos.v11.ui.components.*

/**
 * Zakat tracker — Ramadan-to-Ramadan year (per the user's request), auto-calculated
 * from data this app already tracks (same asset formula as BalanceSheetActivity),
 * with support for paying the year's Zakat all at once or in installments, and a
 * month-by-month editable payable/paid breakdown.
 *
 * ZAKATABLE ASSETS (standard/common view — see the in-app note; a mufti/scholar
 * should confirm anything business-specific):
 *   Cash in Hand + Bank Balance + Stock in Hand (at cost) + Accounts Receivable
 *   − Accounts Payable (short-term debts owed)
 *   × 2.5%
 *
 * A "Zakat year" starts on the most recent 1 Ramadan on/before today and runs to
 * the following 1 Ramadan. The asset snapshot + payable amount are calculated once
 * when the year is started (editable before saving) and stay fixed for that year;
 * payments are then recorded against it, all-at-once or split into parts, each with
 * its own date and an optional category (Cash, Gold, Silver, Business Stock, ...).
 *
 * UPDATED (currency + calendar + monthly plan): a year now also carries a chosen
 * currency label and a choice of Islamic-month or Gregorian-month names for the
 * monthly breakdown below. Each of the 12 months in the breakdown has its own
 * editable payable amount + description/note (ZakatMonthPlan, saved per month), and
 * shows how much of THAT month's slice has actually been paid — computed live from
 * payments dated inside that month's window, not a separate manual toggle.
 * This is local-only data for now — see the ZakatYear/ZakatPayment/ZakatMonthPlan
 * doc comments in Database.kt.
 */
class ZakatActivity : AppCompatActivity() {

    // ================= PREMIUM PALETTE (shared with Items/Categories/Reports) =================
    private var bg = "#F3F2FA"
    private var cardBg = "#FFFFFF"
    private var primary = "#4A3AFF"
    private var primaryDark = "#4A3AFF"
    private var teal = "#0F9B8E"
    private var gold = "#C9A24B"
    private var red = "#E5484D"
    private var textDark = "#1A1A2E"
    private var textGray = "#8A8A9E"
    private var border = "#E7E5F3"

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

    private fun loadThemeColors() {
        val p = com.grocerypos.v11.util.ThemeManager.palette(this)
        bg = p.bg
        cardBg = p.cardWhite
        primary = p.flatPurpleFg
        primaryDark = p.flatPurpleFg
        teal = p.flatTealFg
        gold = p.flatAmberFg
        red = p.red
        textDark = p.textDark
        textGray = p.textMuted
        border = p.border
    }

    private lateinit var resultsBox: LinearLayout
    private val fmt = SimpleDateFormat("dd MMM yyyy", Locale.getDefault())

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

        root.addView(premiumHeader(R.drawable.ic_zakat, Loc.t(this, "Zakat", "زکوٰۃ"), Loc.t(this, "Ramadan to Ramadan \u2022 auto-calculated", "رمضان تا رمضان \u2022 خودکار حساب")))

        resultsBox = LinearLayout(this).apply { orientation = LinearLayout.VERTICAL }
        root.addView(resultsBox)

        val scroll = ScrollView(this).apply {
            setBackgroundColor(Color.parseColor(bg))
            addView(root)
        }
        setContentView(scroll)

        loadScreen()
    }

    override fun onResume() {
        super.onResume()
        if (::resultsBox.isInitialized) loadScreen()
    }

    // ---------------- Hijri (Ramadan) date helpers ----------------

    private fun ramadanStart(hijriYear: Int): Long {
        val cal = IslamicCalendar()
        cal.clear()
        cal.set(hijriYear, 8 /* Ramadan = 9th month, 0-indexed */, 1)
        return cal.timeInMillis
    }

    private fun currentRamadanBracket(): Pair<Long, Long> {
        val nowCal = IslamicCalendar()
        val hijriYearNow = nowCal.get(IcuCalendar.YEAR)
        var start = ramadanStart(hijriYearNow)
        if (start > System.currentTimeMillis()) start = ramadanStart(hijriYearNow - 1)
        val end = ramadanStart(hijriYearFor(start) + 1)
        return start to end
    }

    private fun hijriYearFor(timeMillis: Long): Int {
        val c = IslamicCalendar()
        c.timeInMillis = timeMillis
        return c.get(IcuCalendar.YEAR)
    }

    // ---------------- Month-slice helpers (used by the monthly breakdown) ----------------

    // Splits [year.startDate, year.endDate) into 12 even slices (~29.5 days each, since
    // it's a lunar year) and returns the start/end millis of slice m (1-indexed).
    private fun monthStartMillis(year: ZakatYear, m: Int): Long {
        val span = year.endDate - year.startDate
        return year.startDate + (span * (m - 1) / 12)
    }
    private fun monthEndMillis(year: ZakatYear, m: Int): Long {
        val span = year.endDate - year.startDate
        return year.startDate + (span * m / 12)
    }

    private val islamicMonthNames: List<Pair<String, String>> by lazy {
        listOf(
            "Ramadan" to "رمضان", "Shawwal" to "شوال", "Dhul-Qa'dah" to "ذوالقعدہ",
            "Dhul-Hijjah" to "ذوالحجہ", "Muharram" to "محرم", "Safar" to "صفر",
            "Rabi' al-Awwal" to "ربیع الاول", "Rabi' al-Thani" to "ربیع الثانی",
            "Jumada al-Awwal" to "جمادی الاولیٰ", "Jumada al-Thani" to "جمادی الثانی",
            "Rajab" to "رجب", "Sha'ban" to "شعبان"
        )
    }

    // Label for month m of a given year, per that year's chosen calendarType — either
    // the Islamic month name (Ramadan..Sha'ban, since the year always starts at Ramadan)
    // or the actual Gregorian month/year that slice's start date falls in.
    private fun monthLabel(year: ZakatYear, m: Int): String {
        return if (year.calendarType == "gregorian") {
            val greg = SimpleDateFormat("MMM yyyy", Locale.getDefault())
            greg.format(Date(monthStartMillis(year, m)))
        } else {
            val pair = islamicMonthNames.getOrNull(m - 1)
            if (pair != null) Loc.t(this, pair.first, pair.second) else Loc.t(this, "Month $m", "ماہ $m")
        }
    }

    // ---------------- Load ----------------

    private fun loadScreen() {
        resultsBox.removeAllViews()
        lifecycleScope.launch {
            val db = PosDatabase.get(this@ZakatActivity)
            val latest = db.zakatDao().latestYear()
            val now = System.currentTimeMillis()

            resultsBox.removeAllViews()

            if (latest == null || now >= latest.endDate) {
                resultsBox.addView(startYearCard())
            } else {
                val paid = db.zakatDao().totalPaidForYear(latest.id)
                val payments = db.zakatDao().paymentsForYear(latest.id)
                resultsBox.addView(activeYearCard(latest, paid))
                resultsBox.addView(spacer(16))
                resultsBox.addView(monthlyBreakdownCard(latest))
                resultsBox.addView(spacer(16))
                resultsBox.addView(historyCard(payments, latest.currency))
                resultsBox.addView(spacer(16))
                resultsBox.addView(startYearCard(isRestart = true))
            }

            resultsBox.addView(spacer(10))
            resultsBox.addView(TextView(this@ZakatActivity).apply {
                text = Loc.t(
                    this@ZakatActivity,
                    "Note: this uses a standard estimate (cash + bank + stock at cost + receivables \u2212 payables) \u00D7 2.5%. Confirm anything business-specific with your own mufti/scholar, especially Nisab and stock valuation.",
                    "نوٹ: یہ ایک عام تخمینہ استعمال کرتا ہے (نقدی + بینک + اسٹاک لاگت پر + قابل وصول \u2212 قابل ادائیگی) \u00D7 2.5%\u06D4 کاروبار سے متعلق تفصیلات، خاص طور پر نصاب اور اسٹاک کی قیمت، اپنے مفتی/عالم سے تصدیق کر لیں۔"
                )
                textSize = 11.5f
                setTextColor(Color.parseColor(textGray))
                setPadding(6, 4, 6, 20)
            })
        }
    }

    // ---------------- Currency + calendar-type pickers (shared by start/edit dialogs) ----------------

    private val currencyOptions = listOf("Rs", "PKR", "$", "SAR", "AED", "\u00A3", "\u20AC", "Custom")

    // Returns the picker view plus a getter for whatever the user currently has chosen.
    private fun currencyPickerView(initial: String): Pair<LinearLayout, () -> String> {
        val col = LinearLayout(this).apply {
            orientation = LinearLayout.VERTICAL
            setPadding(0, 10, 0, 4)
        }
        col.addView(TextView(this).apply {
            text = Loc.t(this@ZakatActivity, "Currency", "کرنسی")
            textSize = 12f
            setTextColor(Color.parseColor(textGray))
            setPadding(0, 0, 0, 4)
        })
        val spinner = Spinner(this).apply {
            adapter = ArrayAdapter(this@ZakatActivity, android.R.layout.simple_spinner_dropdown_item, currencyOptions)
        }
        val customInput = EditText(this).apply {
            hint = Loc.t(this@ZakatActivity, "Custom currency symbol/code", "اپنی کرنسی لکھیں")
            visibility = View.GONE
        }
        val presetIndex = currencyOptions.indexOf(initial)
        if (presetIndex >= 0) {
            spinner.setSelection(presetIndex)
        } else {
            spinner.setSelection(currencyOptions.size - 1)
            customInput.setText(initial)
            customInput.visibility = View.VISIBLE
        }
        spinner.onItemSelectedListener = object : AdapterView.OnItemSelectedListener {
            override fun onItemSelected(parent: AdapterView<*>?, v: View?, position: Int, id: Long) {
                customInput.visibility = if (currencyOptions[position] == "Custom") View.VISIBLE else View.GONE
            }
            override fun onNothingSelected(parent: AdapterView<*>?) {}
        }
        col.addView(spinner)
        col.addView(customInput)
        val getter: () -> String = {
            val sel = currencyOptions.getOrElse(spinner.selectedItemPosition) { "Rs" }
            if (sel == "Custom") customInput.text.toString().trim().ifBlank { "Rs" } else sel
        }
        return col to getter
    }

    // Simple two-way pill toggle for Islamic vs Gregorian month names.
    private fun calendarTypeToggle(initial: String): Pair<LinearLayout, () -> String> {
        var selected = initial
        val wrap = LinearLayout(this).apply {
            orientation = LinearLayout.VERTICAL
            setPadding(0, 10, 0, 4)
        }
        wrap.addView(TextView(this).apply {
            text = Loc.t(this@ZakatActivity, "Monthly breakdown shows", "ماہانہ تفصیل میں دکھائیں")
            textSize = 12f
            setTextColor(Color.parseColor(textGray))
            setPadding(0, 0, 0, 4)
        })
        val row = LinearLayout(this).apply { orientation = LinearLayout.HORIZONTAL }
        lateinit var islamicBtn: TextView
        lateinit var gregBtn: TextView
        fun refresh() {
            islamicBtn.background = roundedBg(if (selected == "islamic") primary else border, 30)
            islamicBtn.setTextColor(if (selected == "islamic") Color.WHITE else Color.parseColor(textDark))
            gregBtn.background = roundedBg(if (selected == "gregorian") primary else border, 30)
            gregBtn.setTextColor(if (selected == "gregorian") Color.WHITE else Color.parseColor(textDark))
        }
        islamicBtn = TextView(this).apply {
            text = Loc.t(this@ZakatActivity, "Islamic Months", "اسلامی مہینے")
            gravity = Gravity.CENTER
            textSize = 12.5f
            setPadding(12, 14, 12, 14)
            layoutParams = LinearLayout.LayoutParams(0, LinearLayout.LayoutParams.WRAP_CONTENT, 1f)
            setOnClickListener { selected = "islamic"; refresh() }
        }
        gregBtn = TextView(this).apply {
            text = Loc.t(this@ZakatActivity, "Gregorian Months", "عیسوی مہینے")
            gravity = Gravity.CENTER
            textSize = 12.5f
            setPadding(12, 14, 12, 14)
            layoutParams = LinearLayout.LayoutParams(0, LinearLayout.LayoutParams.WRAP_CONTENT, 1f)
            setOnClickListener { selected = "gregorian"; refresh() }
        }
        row.addView(islamicBtn)
        row.addView(View(this).apply { layoutParams = LinearLayout.LayoutParams(10, 1) })
        row.addView(gregBtn)
        refresh()
        wrap.addView(row)
        return wrap to { selected }
    }

    // ---------------- Start / restart a Zakat year ----------------

    private fun startYearCard(isRestart: Boolean = false): LinearLayout {
        val card = LinearLayout(this).apply {
            orientation = LinearLayout.VERTICAL
            setPadding(22, 18, 22, 18)
            background = strokedBg(if (isRestart) border else gold, cardBg, 18)
            applyElevation(this, 2f)
        }
        val (start, end) = currentRamadanBracket()
        card.addView(TextView(this).apply {
            text = if (isRestart) Loc.t(this@ZakatActivity, "Start a new Zakat year", "نیا زکوٰۃ سال شروع کریں")
                else Loc.t(this@ZakatActivity, "No active Zakat year", "کوئی فعال زکوٰۃ سال نہیں")
            textSize = 15f
            setTypeface(typeface, Typeface.BOLD)
            setTextColor(Color.parseColor(textDark))
        })
        card.addView(TextView(this).apply {
            text = "${fmt.format(Date(start))} \u2014 ${fmt.format(Date(end))}"
            textSize = 12.5f
            setTextColor(Color.parseColor(textGray))
            setPadding(0, 4, 0, 14)
        })
        card.addView(pillButton(
            Loc.t(this@ZakatActivity, "Calculate & Start This Year", "حساب لگائیں اور سال شروع کریں"),
            primary
        ) { showStartYearDialog(start, end) })
        return card
    }

    private fun showStartYearDialog(start: Long, end: Long) {
        lifecycleScope.launch {
            val db = PosDatabase.get(this@ZakatActivity)

            val cashInHand = db.cashTransactionDao().totalAll("IN", "cash") - db.cashTransactionDao().totalAll("OUT", "cash")
            val bankBalance = db.cashTransactionDao().totalAll("IN", "bank") - db.cashTransactionDao().totalAll("OUT", "bank")
            val allProducts = db.productDao().all().first()
            val stockValue = allProducts.sumOf { p ->
                val factor = p.smallestUnitFactor()
                val costPerSmallestUnit = if (factor > 0) p.cost / factor else p.cost
                p.stock * costPerSmallestUnit
            }
            val receivables = db.customerDao().receivablesTotal()
            val payables = db.supplierDao().payablesTotal()
            val autoAssets = cashInHand + bankBalance + stockValue + receivables - payables
            val defaultCurrency = db.appSettingDao().get("currency")?.value?.trim()?.ifBlank { null } ?: "Rs"

            val padding = (24 * resources.displayMetrics.density).toInt()
            val col = LinearLayout(this@ZakatActivity).apply { orientation = LinearLayout.VERTICAL; setPadding(padding, padding, padding, padding) }
            col.addView(TextView(this@ZakatActivity).apply {
                text = Loc.t(this@ZakatActivity, "Auto-calculated from Cash + Bank + Stock + Receivables \u2212 Payables. Adjust if needed:", "نقدی + بینک + اسٹاک + قابل وصول \u2212 قابل ادائیگی سے خودکار حساب۔ ضرورت ہو تو تبدیل کریں:")
                textSize = 12f
                setTextColor(Color.parseColor(textGray))
                setPadding(0, 0, 0, 12)
            })
            val assetsInput = EditText(this@ZakatActivity).apply {
                hint = Loc.t(this@ZakatActivity, "Net Zakatable Assets", "خالص زکوٰۃ کے قابل اثاثے")
                inputType = InputType.TYPE_CLASS_NUMBER or InputType.TYPE_NUMBER_FLAG_DECIMAL
                setText(if (autoAssets > 0) "%.0f".format(autoAssets) else "0")
            }
            col.addView(assetsInput)

            val (currencyView, getCurrency) = currencyPickerView(defaultCurrency)
            col.addView(currencyView)
            val (calendarView, getCalendarType) = calendarTypeToggle("islamic")
            col.addView(calendarView)

            val scrollWrap = ScrollView(this@ZakatActivity).apply { addView(col) }

            AlertDialog.Builder(this@ZakatActivity)
                .setTitle(Loc.t(this@ZakatActivity, "Confirm Zakat Year", "زکوٰۃ سال کی تصدیق کریں"))
                .setView(scrollWrap)
                .setPositiveButton(Loc.t(this@ZakatActivity, "Start", "شروع کریں")) { _, _ ->
                    val assets = assetsInput.parseMoneyOrWarn(this@ZakatActivity, "Net Zakatable Assets", "خالص زکوٰۃ کے قابل اثاثے") ?: return@setPositiveButton
                    saveNewYear(start, end, assets, getCurrency(), getCalendarType())
                }
                .setNegativeButton(Loc.t(this@ZakatActivity, "Cancel", "منسوخ کریں"), null)
                .show()
        }
    }

    private fun saveNewYear(start: Long, end: Long, assets: Double, currency: String, calendarType: String) {
        lifecycleScope.launch {
            val db = PosDatabase.get(this@ZakatActivity)
            val payable = assets * 0.025
            val newYear = ZakatYear(startDate = start, endDate = end, assetsSnapshot = assets, totalPayable = payable, currency = currency, calendarType = calendarType)
            val id = db.zakatDao().insertYear(newYear)
            SyncQueueHelper.enqueueZakatYear(db, newYear.copy(id = id), this@ZakatActivity)
            SyncQueueHelper.trigger(this@ZakatActivity)
            Toast.makeText(this@ZakatActivity, Loc.t(this@ZakatActivity, "Zakat year started", "زکوٰۃ سال شروع ہو گیا"), Toast.LENGTH_SHORT).show()
            loadScreen()
        }
    }

    // ---------------- Edit a saved year's assets/payable/currency/calendar ----------------

    private fun showEditYearDialog(year: ZakatYear) {
        val padding = (24 * resources.displayMetrics.density).toInt()
        val col = LinearLayout(this).apply { orientation = LinearLayout.VERTICAL; setPadding(padding, padding, padding, padding) }
        col.addView(TextView(this).apply {
            text = Loc.t(this@ZakatActivity, "Correct the saved Net Zakatable Assets for this year:", "اس سال کے محفوظ شدہ خالص زکوٰۃ کے قابل اثاثے درست کریں:")
            textSize = 12f
            setTextColor(Color.parseColor(textGray))
            setPadding(0, 0, 0, 12)
        })
        val assetsInput = EditText(this).apply {
            hint = Loc.t(this@ZakatActivity, "Net Zakatable Assets", "خالص زکوٰۃ کے قابل اثاثے")
            inputType = InputType.TYPE_CLASS_NUMBER or InputType.TYPE_NUMBER_FLAG_DECIMAL
            setText("%.0f".format(year.assetsSnapshot))
        }
        col.addView(assetsInput)

        val (currencyView, getCurrency) = currencyPickerView(year.currency)
        col.addView(currencyView)
        val (calendarView, getCalendarType) = calendarTypeToggle(year.calendarType)
        col.addView(calendarView)

        val scrollWrap = ScrollView(this).apply { addView(col) }

        AlertDialog.Builder(this)
            .setTitle(Loc.t(this, "Edit Zakat Year", "زکوٰۃ سال میں ترمیم"))
            .setView(scrollWrap)
            .setPositiveButton(Loc.t(this, "Save", "محفوظ کریں")) { _, _ ->
                val assets = assetsInput.text.toString().toDoubleOrNull()
                if (assets == null || assets < 0.0) {
                    Toast.makeText(this, Loc.t(this, "Enter a valid amount", "صحیح رقم لکھیں"), Toast.LENGTH_SHORT).show()
                    return@setPositiveButton
                }
                updateYearAssets(year, assets, getCurrency(), getCalendarType())
            }
            .setNegativeButton(Loc.t(this, "Cancel", "منسوخ کریں"), null)
            .show()
    }

    private fun updateYearAssets(year: ZakatYear, assets: Double, currency: String, calendarType: String) {
        lifecycleScope.launch {
            val db = PosDatabase.get(this@ZakatActivity)
            val payable = assets * 0.025
            val updated = year.copy(assetsSnapshot = assets, totalPayable = payable, currency = currency, calendarType = calendarType)
            db.zakatDao().updateYear(updated)
            SyncQueueHelper.enqueueZakatYear(db, updated, this@ZakatActivity)
            Toast.makeText(this@ZakatActivity, Loc.t(this@ZakatActivity, "Zakat year updated", "زکوٰۃ سال تازہ ہو گیا"), Toast.LENGTH_SHORT).show()
            loadScreen()
        }
    }

    // ---------------- Active year summary + payment ----------------

    private fun activeYearCard(year: ZakatYear, paid: Double): LinearLayout {
        val remaining = (year.totalPayable - paid).coerceAtLeast(0.0)
        val pct = if (year.totalPayable > 0) ((paid / year.totalPayable) * 100).coerceIn(0.0, 100.0) else 0.0

        val card = LinearLayout(this).apply {
            orientation = LinearLayout.VERTICAL
            setPadding(22, 20, 22, 20)
            background = strokedBg(border, cardBg, 18)
            applyElevation(this, 2f)
        }
        card.addView(LinearLayout(this).apply {
            orientation = LinearLayout.HORIZONTAL
            gravity = Gravity.CENTER_VERTICAL
            addView(TextView(this@ZakatActivity).apply {
                text = "${fmt.format(Date(year.startDate))} \u2014 ${fmt.format(Date(year.endDate))}"
                textSize = 12f
                setTextColor(Color.parseColor(textGray))
                layoutParams = LinearLayout.LayoutParams(0, LinearLayout.LayoutParams.WRAP_CONTENT, 1f)
            })
            addView(TextView(this@ZakatActivity).apply {
                text = Loc.t(this@ZakatActivity, "Edit", "ترمیم")
                textSize = 12.5f
                setTypeface(typeface, Typeface.BOLD)
                setTextColor(Color.parseColor(primary))
                setLeadingIcon(R.drawable.ic_edit, primary, 13, 4)
                setPadding(16, 6, 6, 6)
                setOnClickListener { showEditYearDialog(year) }
            })
        })
        card.addView(bigAmountRow(Loc.t(this, "Total Zakat Payable", "کل زکوٰۃ ادا کرنی ہے"), year.totalPayable, primary, year.currency))
        card.addView(spacer(4))
        card.addView(bigAmountRow(Loc.t(this, "Paid So Far", "اب تک ادا شدہ"), paid, teal, year.currency))
        card.addView(bigAmountRow(Loc.t(this, "Remaining", "باقی رقم"), remaining, if (remaining > 0) red else teal, year.currency))

        card.addView(spacer(10))
        card.addView(ProgressBar(this, null, android.R.attr.progressBarStyleHorizontal).apply {
            max = 100
            progress = pct.toInt()
            layoutParams = LinearLayout.LayoutParams(LinearLayout.LayoutParams.MATCH_PARENT, 20)
        })
        card.addView(TextView(this).apply {
            text = "%.0f%% ".format(pct) + Loc.t(this@ZakatActivity, "paid", "ادا شدہ")
            textSize = 11f
            setTextColor(Color.parseColor(textGray))
            setPadding(0, 4, 0, 14)
        })

        if (remaining > 0.0) {
            val row = LinearLayout(this).apply { orientation = LinearLayout.HORIZONTAL }
            row.addView(pillButton(Loc.t(this@ZakatActivity, "Record Payment", "ادائیگی درج کریں"), primary) {
                showPaymentDialog(year, remaining)
            }.apply { layoutParams = LinearLayout.LayoutParams(0, LinearLayout.LayoutParams.WRAP_CONTENT, 1f) })
            row.addView(View(this).apply { layoutParams = LinearLayout.LayoutParams(10, 1) })
            row.addView(pillButton(Loc.t(this@ZakatActivity, "Pay Remaining in Full", "باقی مکمل ادا کریں"), teal) {
                savePayment(year, remaining, "cash", Loc.t(this@ZakatActivity, "Full remaining balance", "مکمل باقی رقم"), "", System.currentTimeMillis())
            }.apply { layoutParams = LinearLayout.LayoutParams(0, LinearLayout.LayoutParams.WRAP_CONTENT, 1f) })
            card.addView(row)
        } else {
            card.addView(TextView(this).apply {
                text = "\u2705 " + Loc.t(this@ZakatActivity, "Fully paid for this year", "اس سال کی مکمل ادائیگی ہو چکی ہے")
                textSize = 13f
                setTypeface(typeface, Typeface.BOLD)
                setTextColor(Color.parseColor(teal))
            })
        }
        return card
    }

    private fun bigAmountRow(label: String, amount: Double, colorHex: String, currency: String): LinearLayout {
        return LinearLayout(this).apply {
            orientation = LinearLayout.HORIZONTAL
            setPadding(0, 4, 0, 4)
            addView(TextView(this@ZakatActivity).apply {
                text = label
                textSize = 13.5f
                setTextColor(Color.parseColor(textGray))
                layoutParams = LinearLayout.LayoutParams(0, LinearLayout.LayoutParams.WRAP_CONTENT, 1f)
            })
            addView(TextView(this@ZakatActivity).apply {
                text = "$currency %.0f".format(amount)
                textSize = 15f
                setTypeface(typeface, Typeface.BOLD)
                setTextColor(Color.parseColor(colorHex))
            })
        }
    }

    // Optional category for a payment — purely informational (which zakatable asset it
    // relates to). First entry ("" -> "No category") means the field can be left blank.
    private fun categoryOptions(): List<Pair<String, String>> = listOf(
        "" to Loc.t(this, "No category", "کوئی کیٹیگری نہیں"),
        "cash" to Loc.t(this, "Cash / Bank", "نقدی / بینک"),
        "gold" to Loc.t(this, "Gold", "سونا"),
        "silver" to Loc.t(this, "Silver", "چاندی"),
        "business" to Loc.t(this, "Business Stock", "کاروباری مال"),
        "livestock" to Loc.t(this, "Livestock", "مویشی"),
        "crops" to Loc.t(this, "Crops / Produce", "فصل / پیداوار"),
        "other" to Loc.t(this, "Other", "دیگر")
    )

    private fun showPaymentDialog(year: ZakatYear, remaining: Double) {
        val padding = (24 * resources.displayMetrics.density).toInt()
        val col = LinearLayout(this).apply { orientation = LinearLayout.VERTICAL; setPadding(padding, padding, padding, padding) }

        val amountInput = EditText(this).apply {
            hint = Loc.t(this@ZakatActivity, "Amount (remaining: ${year.currency} %.0f)".format(remaining), "رقم (باقی: ${year.currency} %.0f)".format(remaining))
            inputType = InputType.TYPE_CLASS_NUMBER or InputType.TYPE_NUMBER_FLAG_DECIMAL
        }
        col.addView(amountInput)

        val methodSpinner = Spinner(this).apply {
            adapter = ArrayAdapter(this@ZakatActivity, android.R.layout.simple_spinner_dropdown_item, listOf("cash", "bank"))
        }
        col.addView(methodSpinner)

        col.addView(TextView(this).apply {
            text = Loc.t(this@ZakatActivity, "Category (optional)", "کیٹیگری (اختیاری)")
            textSize = 12f
            setTextColor(Color.parseColor(textGray))
            setPadding(0, 12, 0, 4)
        })
        val catOptions = categoryOptions()
        val categorySpinner = Spinner(this).apply {
            adapter = ArrayAdapter(this@ZakatActivity, android.R.layout.simple_spinner_dropdown_item, catOptions.map { it.second })
        }
        col.addView(categorySpinner)

        var pickedDate = System.currentTimeMillis()
        col.addView(TextView(this).apply {
            text = Loc.t(this@ZakatActivity, "Payment Date", "ادائیگی کی تاریخ")
            textSize = 12f
            setTextColor(Color.parseColor(textGray))
            setPadding(0, 12, 0, 4)
        })
        lateinit var dateText: TextView
        dateText = TextView(this).apply {
            text = fmt.format(Date(pickedDate))
            textSize = 14f
            setTypeface(typeface, Typeface.BOLD)
            setTextColor(Color.parseColor(textDark))
            background = strokedBg(border, cardBg, 10)
            setPadding(16, 16, 16, 16)
            setLeadingIcon(R.drawable.ic_calendar, primary, 15, 8)
            setOnClickListener {
                val cal = Calendar.getInstance().apply { timeInMillis = pickedDate }
                DatePickerDialog(this@ZakatActivity, { _, y, m, d ->
                    val picked = Calendar.getInstance().apply { set(y, m, d, 0, 0, 0); set(Calendar.MILLISECOND, 0) }.timeInMillis
                    pickedDate = picked
                    text = fmt.format(Date(picked))
                }, cal.get(Calendar.YEAR), cal.get(Calendar.MONTH), cal.get(Calendar.DAY_OF_MONTH)).apply {
                    datePicker.calendarViewShown = true; datePicker.spinnersShown = false
                    datePicker.maxDate = System.currentTimeMillis()
                }.show()
            }
        }
        col.addView(dateText)

        val noteInput = EditText(this).apply {
            hint = Loc.t(this@ZakatActivity, "Note (optional)", "نوٹ (اختیاری)")
            setPadding(0, 20, 0, 0)
        }
        col.addView(noteInput)

        val scrollWrap = ScrollView(this).apply { addView(col) }

        AlertDialog.Builder(this)
            .setTitle(Loc.t(this, "Record Zakat Payment", "زکوٰۃ ادائیگی درج کریں"))
            .setView(scrollWrap)
            .setPositiveButton(Loc.t(this, "Save", "محفوظ کریں")) { _, _ ->
                val amt = amountInput.text.toString().toDoubleOrNull()
                if (amt == null || amt <= 0.0) {
                    Toast.makeText(this, Loc.t(this, "Enter a valid amount", "صحیح رقم لکھیں"), Toast.LENGTH_SHORT).show()
                    return@setPositiveButton
                }
                val category = catOptions.getOrElse(categorySpinner.selectedItemPosition) { catOptions[0] }.first
                savePayment(year, amt, methodSpinner.selectedItem?.toString() ?: "cash", noteInput.text.toString().trim(), category, pickedDate)
            }
            .setNegativeButton(Loc.t(this, "Cancel", "منسوخ کریں"), null)
            .show()
    }

    private fun savePayment(year: ZakatYear, amount: Double, method: String, note: String, category: String, paymentDate: Long) {
        lifecycleScope.launch {
            val db = PosDatabase.get(this@ZakatActivity)

            // FIX (audit #5 — "Zakat payment bhi same atomicity issue"): ZakatPayment
            // insert, the mirrored Expense + CashTransaction inserts, and all three
            // sync-queue enqueues used to be 6+ separate un-grouped DB writes. A crash
            // partway through could save the Zakat payment without its expense/cash-out
            // (or the reverse), silently desyncing Cash in Hand, P&L, and the Zakat
            // year's paid total from each other. Wrapped in one db.withTransaction {},
            // same fix as ExpenseActivity.saveExpense()/CashActivity's Cash-Out flow.
            db.withTransaction {
                val newPayment = ZakatPayment(zakatYearId = year.id, amount = amount, method = method, note = note, category = category, paymentDate = paymentDate)
                val paymentId = db.zakatDao().insertPayment(newPayment)
                // Also logged as a normal expense (category "Zakat") so it shows up in the
                // existing Expense reports/P&L alongside everything else — same as every
                // other outgoing payment in this app.
                val desc = Loc.t(this@ZakatActivity, "Zakat payment", "زکوٰۃ کی ادائیگی") + " (${fmt.format(Date(year.startDate))} \u2014 ${fmt.format(Date(year.endDate))})" + if (note.isNotEmpty()) " | $note" else ""
                // FIX (audit): the expense used to ignore which drawer the Zakat was paid from
                // (always the default "cash") and no cash-book entry was made, so Cash in Hand /
                // Bank Balance / Cash Register never went down while profit did.
                val zakatMethod = method.lowercase()
                val zakatExpense = Expense(category = "Zakat", description = desc, amount = amount, method = zakatMethod, createdAt = paymentDate)
                val expenseId = db.expenseDao().insert(zakatExpense)
                val savedExpense = zakatExpense.copy(id = expenseId)
                // FIX (audit): raw enqueue() left serverId unstamped => duplicate expense after
                // the next pull. See ExpenseActivity.saveExpense().
                SyncQueueHelper.enqueueExpense(db, savedExpense)
                val zakatCashTx = CashTransaction(
                    type = "OUT", method = zakatMethod, amount = amount,
                    reason = "Expense: Zakat",
                    reference = SyncQueueHelper.expenseEntityId(savedExpense),
                    createdAt = paymentDate
                )
                val zakatCashTxId = db.cashTransactionDao().insert(zakatCashTx)
                SyncQueueHelper.enqueueCashTransaction(db, zakatCashTx.copy(id = zakatCashTxId))
                val stampedYear = SyncQueueHelper.enqueueZakatYear(db, year, this@ZakatActivity)
                SyncQueueHelper.enqueueZakatPayment(
                    db, newPayment.copy(id = paymentId),
                    stampedYear.serverId ?: SyncQueueHelper.zakatYearEntityId(stampedYear),
                    this@ZakatActivity
                )
            }

            SyncQueueHelper.trigger(this@ZakatActivity)
            Toast.makeText(this@ZakatActivity, Loc.t(this@ZakatActivity, "Payment saved", "ادائیگی محفوظ ہو گئی"), Toast.LENGTH_SHORT).show()
            loadScreen()
        }
    }

    // ---------------- Monthly breakdown (editable payable + note per month) ----------------

    // Shows all 12 months of the active Zakat year by name (Islamic or Gregorian, per
    // year.calendarType), each with its own editable payable amount + description/note
    // (ZakatMonthPlan — defaults to totalPayable/12 until the user saves one), and how
    // much of that month's slice has actually been paid (computed live from payments
    // whose paymentDate falls in that slice). Tap a month to edit its amount/note.
    private fun monthlyBreakdownCard(year: ZakatYear): LinearLayout {
        val card = LinearLayout(this).apply {
            orientation = LinearLayout.VERTICAL
            setPadding(22, 18, 22, 18)
            background = strokedBg(border, cardBg, 18)
            applyElevation(this, 2f)
        }
        card.addView(TextView(this).apply {
            text = Loc.t(this@ZakatActivity, "Monthly Breakdown", "ماہانہ تفصیل")
            textSize = 14f
            setTypeface(typeface, Typeface.BOLD)
            setTextColor(Color.parseColor(textDark))
        })
        card.addView(TextView(this).apply {
            text = Loc.t(this@ZakatActivity, "Tap a month to set its amount and add a note", "رقم مقرر کرنے اور نوٹ لکھنے کے لیے ماہ پر ٹیپ کریں")
            textSize = 12f
            setTextColor(Color.parseColor(textGray))
            setPadding(0, 4, 0, 14)
        })

        lifecycleScope.launch {
            val db = PosDatabase.get(this@ZakatActivity)
            val plans = db.zakatDao().monthPlansForYear(year.id).associateBy { it.monthIndex }
            val defaultMonthly = year.totalPayable / 12.0
            var totalPlannedPayable = 0.0
            var totalPlannedPaid = 0.0

            for (m in 1..12) {
                val plan = plans[m]
                val payableAmt = plan?.payableAmount ?: defaultMonthly
                val note = plan?.note ?: ""
                val startM = monthStartMillis(year, m)
                val endM = monthEndMillis(year, m)
                val paidM = db.zakatDao().paidInRange(year.id, startM, endM)
                totalPlannedPayable += payableAmt
                totalPlannedPaid += paidM
                val covered = paidM >= payableAmt - 0.5
                val remainingM = (payableAmt - paidM).coerceAtLeast(0.0)

                card.addView(LinearLayout(this@ZakatActivity).apply {
                    orientation = LinearLayout.VERTICAL
                    setPadding(0, 10, 0, 10)
                    background = strokedBg(border, cardBg, 12)
                    setPadding(16, 12, 16, 12)
                    setOnClickListener { showMonthPlanDialog(year, m, plan, defaultMonthly) }

                    addView(LinearLayout(this@ZakatActivity).apply {
                        orientation = LinearLayout.HORIZONTAL
                        gravity = Gravity.CENTER_VERTICAL
                        addView(TextView(this@ZakatActivity).apply {
                            text = monthLabel(year, m)
                            if (covered) setLeadingIcon(R.drawable.ic_check, teal, 13, 6)
                            else setLeadingIcon(R.drawable.ic_edit, textGray, 12, 6)
                            textSize = 13.5f
                            setTypeface(typeface, Typeface.BOLD)
                            setTextColor(Color.parseColor(textDark))
                            layoutParams = LinearLayout.LayoutParams(0, LinearLayout.LayoutParams.WRAP_CONTENT, 1f)
                        })
                        addView(TextView(this@ZakatActivity).apply {
                            text = "${year.currency} %.0f".format(payableAmt)
                            textSize = 13f
                            setTypeface(typeface, Typeface.BOLD)
                            setTextColor(Color.parseColor(primary))
                        })
                    })
                    addView(LinearLayout(this@ZakatActivity).apply {
                        orientation = LinearLayout.HORIZONTAL
                        setPadding(0, 4, 0, 0)
                        addView(TextView(this@ZakatActivity).apply {
                            text = Loc.t(this@ZakatActivity, "Paid: ", "ادا شدہ: ") + "${year.currency} %.0f".format(paidM)
                            textSize = 11.5f
                            setTextColor(Color.parseColor(teal))
                            layoutParams = LinearLayout.LayoutParams(0, LinearLayout.LayoutParams.WRAP_CONTENT, 1f)
                        })
                        addView(TextView(this@ZakatActivity).apply {
                            text = Loc.t(this@ZakatActivity, "Remaining: ", "باقی: ") + "${year.currency} %.0f".format(remainingM)
                            textSize = 11.5f
                            setTextColor(Color.parseColor(if (remainingM > 0) red else teal))
                        })
                    })
                    if (note.isNotEmpty()) {
                        addView(TextView(this@ZakatActivity).apply {
                            text = note
                            textSize = 11.5f
                            setTextColor(Color.parseColor(textGray))
                            setPadding(0, 6, 0, 0)
                        })
                    }
                })
            }

            // Year-end summary computed from the monthly plan itself, so the user can see
            // at a glance whether their month-by-month schedule adds up to the year's
            // total payable, and how much of THAT schedule has been paid so far.
            card.addView(spacer(6))
            card.addView(View(this@ZakatActivity).apply {
                setBackgroundColor(Color.parseColor(border))
                layoutParams = LinearLayout.LayoutParams(LinearLayout.LayoutParams.MATCH_PARENT, 1)
            })
            card.addView(spacer(10))
            card.addView(TextView(this@ZakatActivity).apply {
                text = Loc.t(this@ZakatActivity, "Year-End Totals (from monthly schedule)", "سالانہ مجموعہ (ماہانہ شیڈول سے)")
                textSize = 12.5f
                setTypeface(typeface, Typeface.BOLD)
                setTextColor(Color.parseColor(textDark))
                setPadding(0, 0, 0, 6)
            })
            card.addView(bigAmountRow(Loc.t(this@ZakatActivity, "Total Planned Payable", "کل مقررہ رقم"), totalPlannedPayable, primary, year.currency))
            card.addView(bigAmountRow(Loc.t(this@ZakatActivity, "Total Paid (this schedule)", "کل ادا شدہ"), totalPlannedPaid, teal, year.currency))
            card.addView(bigAmountRow(Loc.t(this@ZakatActivity, "Remaining (this schedule)", "باقی رقم"), (totalPlannedPayable - totalPlannedPaid).coerceAtLeast(0.0), red, year.currency))
        }
        return card
    }

    private fun showMonthPlanDialog(year: ZakatYear, m: Int, existing: ZakatMonthPlan?, suggested: Double) {
        val padding = (24 * resources.displayMetrics.density).toInt()
        val col = LinearLayout(this).apply { orientation = LinearLayout.VERTICAL; setPadding(padding, padding, padding, padding) }
        col.addView(TextView(this).apply {
            text = monthLabel(year, m)
            textSize = 14f
            setTypeface(typeface, Typeface.BOLD)
            setTextColor(Color.parseColor(textDark))
            setPadding(0, 0, 0, 10)
        })
        val amountInput = EditText(this).apply {
            hint = Loc.t(this@ZakatActivity, "Payable Amount for this month", "اس ماہ کی قابل ادا رقم")
            inputType = InputType.TYPE_CLASS_NUMBER or InputType.TYPE_NUMBER_FLAG_DECIMAL
            setText("%.0f".format(existing?.payableAmount ?: suggested))
        }
        col.addView(amountInput)
        val noteInput = EditText(this).apply {
            hint = Loc.t(this@ZakatActivity, "Description / Note (optional)", "تفصیل / نوٹ (اختیاری)")
            setText(existing?.note ?: "")
            setPadding(0, 16, 0, 0)
        }
        col.addView(noteInput)

        AlertDialog.Builder(this)
            .setTitle(Loc.t(this, "Edit Month", "ماہ میں ترمیم"))
            .setView(col)
            .setPositiveButton(Loc.t(this, "Save", "محفوظ کریں")) { _, _ ->
                val amt = amountInput.text.toString().toDoubleOrNull()
                if (amt == null || amt < 0.0) {
                    Toast.makeText(this, Loc.t(this, "Enter a valid amount", "صحیح رقم لکھیں"), Toast.LENGTH_SHORT).show()
                    return@setPositiveButton
                }
                saveMonthPlan(year, m, amt, noteInput.text.toString().trim(), existing)
            }
            .setNegativeButton(Loc.t(this, "Cancel", "منسوخ کریں"), null)
            .show()
    }

    private fun saveMonthPlan(year: ZakatYear, m: Int, amount: Double, note: String, existing: ZakatMonthPlan?) {
        lifecycleScope.launch {
            val db = PosDatabase.get(this@ZakatActivity)
            if (existing != null) {
                db.zakatDao().updateMonthPlan(existing.copy(payableAmount = amount, note = note, updatedAt = System.currentTimeMillis(), dirty = true))
            } else {
                db.zakatDao().insertMonthPlan(ZakatMonthPlan(zakatYearId = year.id, monthIndex = m, payableAmount = amount, note = note))
            }
            Toast.makeText(this@ZakatActivity, Loc.t(this@ZakatActivity, "Month updated", "ماہ تازہ ہو گیا"), Toast.LENGTH_SHORT).show()
            loadScreen()
        }
    }

    // ---------------- Payment history ----------------

    private fun historyCard(payments: List<ZakatPayment>, currency: String): LinearLayout {
        val card = LinearLayout(this).apply {
            orientation = LinearLayout.VERTICAL
            setPadding(22, 18, 22, 18)
            background = strokedBg(border, cardBg, 18)
            applyElevation(this, 2f)
        }
        card.addView(TextView(this).apply {
            text = Loc.t(this@ZakatActivity, "Payment History", "ادائیگی کی تاریخ")
            textSize = 14f
            setTypeface(typeface, Typeface.BOLD)
            setTextColor(Color.parseColor(textDark))
            setPadding(0, 0, 0, 10)
        })
        if (payments.isEmpty()) {
            card.addView(TextView(this).apply {
                text = Loc.t(this@ZakatActivity, "No payments recorded yet", "ابھی تک کوئی ادائیگی درج نہیں")
                textSize = 12.5f
                setTextColor(Color.parseColor(textGray))
            })
        } else {
            val catLabels = categoryOptions().toMap()
            payments.forEach { p ->
                card.addView(LinearLayout(this).apply {
                    orientation = LinearLayout.VERTICAL
                    setPadding(0, 8, 0, 8)
                    addView(LinearLayout(this@ZakatActivity).apply {
                        orientation = LinearLayout.HORIZONTAL
                        addView(TextView(this@ZakatActivity).apply {
                            text = fmt.format(Date(p.paymentDate))
                            textSize = 12f
                            setTextColor(Color.parseColor(textGray))
                            layoutParams = LinearLayout.LayoutParams(0, LinearLayout.LayoutParams.WRAP_CONTENT, 1f)
                        })
                        addView(TextView(this@ZakatActivity).apply {
                            text = "$currency %.0f".format(p.amount)
                            textSize = 13.5f
                            setTypeface(typeface, Typeface.BOLD)
                            setTextColor(Color.parseColor(teal))
                        })
                    })
                    val catLabel = catLabels[p.category]?.takeIf { p.category.isNotEmpty() }
                    val metaParts = listOfNotNull(
                        p.method.takeIf { it.isNotEmpty() }?.uppercase(),
                        catLabel,
                        p.note.takeIf { it.isNotEmpty() }
                    )
                    if (metaParts.isNotEmpty()) {
                        addView(TextView(this@ZakatActivity).apply {
                            text = metaParts.joinToString("  \u2022  ")
                            textSize = 11.5f
                            setTextColor(Color.parseColor(textGray))
                        })
                    }
                })
            }
        }
        return card
    }

    // ---------------- Small UI helpers ----------------

    private fun pillButton(label: String, colorHex: String, onClick: () -> Unit) = TextView(this).apply {
        text = label
        textSize = 13f
        gravity = Gravity.CENTER
        setTextColor(Color.WHITE)
        setTypeface(typeface, Typeface.BOLD)
        background = roundedBg(colorHex, 30)
        setPadding(20, 16, 20, 16)
        setOnClickListener { onClick() }
    }

    // ================= PREMIUM HEADER (matches Items/Categories/Reports) =================

    private fun circleIcon(label: String, colorHex: String, sizeDp: Int) = TextView(this).apply {
        text = label
        textSize = 18f
        gravity = Gravity.CENTER
        background = ovalBg(colorHex)
        val px = (sizeDp * resources.displayMetrics.density).toInt()
        layoutParams = android.view.ViewGroup.LayoutParams(px, px)
    }

    // spacer() now comes from the shared UiHelpers.kt (item #24 dedup) — was a
    // byte-identical private copy here before.
}

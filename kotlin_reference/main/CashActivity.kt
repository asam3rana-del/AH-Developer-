package com.grocerypos.v11.ui

import android.graphics.Color
import android.graphics.drawable.GradientDrawable
import android.os.Bundle
import android.view.Gravity
import android.view.View
import android.widget.*
import androidx.appcompat.app.AppCompatActivity
import androidx.lifecycle.lifecycleScope
import androidx.room.withTransaction
import com.grocerypos.v11.CashTransaction
import com.grocerypos.v11.Expense
import com.grocerypos.v11.PosDatabase
import com.grocerypos.v11.R
import com.grocerypos.v11.SyncQueueHelper
import com.grocerypos.v11.util.Loc
import kotlinx.coroutines.flow.collectLatest
import kotlinx.coroutines.launch
import java.text.SimpleDateFormat
import java.util.Calendar
import java.util.Date
import java.util.Locale
import com.grocerypos.v11.ui.components.*

class CashActivity : AppCompatActivity() {

    // ---- Pulled from ThemeManager so this screen respects dark mode and stays in sync
    // with the rest of the app. Cash In stays green/positive, Cash Out stays red/negative —
    // that logic is untouched, only the hex source changed. "In" is unified with the app's
    // shared positive/teal color (flatTealFg), matching Party/Reports. ----
    private var bg = "#F3F4F9"
    private var navy = "#0B2545"
    private var cardWhite = "#FFFFFF"
    private var textDark = "#1A1D2E"
    private var textMuted = "#8A8FA3"
    private var green = "#2E7D32"      // positive — flatTealFg
    private var red = "#C62828"
    private var teal = "#0F9B8E"
    private var border = "#E6E8F0"
    private var fieldFill = "#FFFFFF"

    private fun loadThemeColors() {
        val p = com.grocerypos.v11.util.ThemeManager.palette(this)
        bg = p.bg
        cardWhite = p.cardWhite
        textDark = p.textDark
        textMuted = p.textMuted
        navy = p.navy
        green = p.flatTealFg
        red = p.red
        teal = p.teal
        border = p.border
        fieldFill = p.fieldFill
    }

    private val NON_EXPENSE = "Non-expense (Withdrawal / Transfer)"

    private val expenseCategories = listOf(
        "Food Authority License Fees",
        "Utility Bills",
        "Wages",
        "Fuel Expense",
        "Pick up Maintenance",
        "Fines",
        "Rent",
        "Income Tax Fees",
        "Miscellaneous",
        // ADDED (audit): every Cash Out used to be forced under an expense category, so money that
        // is NOT a business expense (owner withdrawal, bank deposit/transfer) had no honest
        // choice. This one records a plain cash movement with no Expense.
        NON_EXPENSE
    )

    private lateinit var amount: EditText
    private lateinit var reason: EditText
    private lateinit var methodSpinner: Spinner
    private lateinit var categoryLabel: TextView
    private lateinit var categorySpinner: Spinner
    private lateinit var categoryBox: LinearLayout
    private lateinit var miscToggle: TextView
    private lateinit var miscDescBox: LinearLayout
    private lateinit var miscDesc: EditText
    private lateinit var inTotalText: TextView
    private lateinit var outTotalText: TextView
    private lateinit var listContainer: LinearLayout

    override fun onCreate(b: Bundle?) {
        super.onCreate(b)
        loadThemeColors()

        val outer = LinearLayout(this).apply {
            orientation = LinearLayout.VERTICAL
            setBackgroundColor(Color.parseColor(bg))
        }
        outer.addView(premiumHeader(
            iconRes = R.drawable.ic_wallet,
            title = Loc.t(this@CashActivity, "Cash In / Cash Out", "کیش ان / کیش آؤٹ"),
            subtitle = Loc.t(this@CashActivity, "Record cash movements", "کیش کی آمد و رفت درج کریں"),
            primaryHex = navy,
            primaryDarkHex = navy
        ))

        val root = LinearLayout(this).apply {
            orientation = LinearLayout.VERTICAL
            setPadding(28, 26, 28, 32)
        }

        // ---- Today's totals: premium white cards ----
        val totalsRow = LinearLayout(this).apply { orientation = LinearLayout.HORIZONTAL }

        val inCard = statCard(R.drawable.ic_trending, Loc.t(this, "Today Cash In", "آج کیش ان"), green, lightenHex(green))
        val outCard = statCard(R.drawable.ic_trending_down, Loc.t(this, "Today Cash Out", "آج کیش آؤٹ"), red, lightenHex(red))
        inTotalText = inCard.second
        outTotalText = outCard.second

        inCard.first.layoutParams = LinearLayout.LayoutParams(0, LinearLayout.LayoutParams.WRAP_CONTENT, 1f).apply { setMargins(0,0,9,0) }
        outCard.first.layoutParams = LinearLayout.LayoutParams(0, LinearLayout.LayoutParams.WRAP_CONTENT, 1f).apply { setMargins(9,0,0,0) }

        totalsRow.addView(inCard.first)
        totalsRow.addView(outCard.first)
        root.addView(totalsRow)
        root.addView(spacer(26))

        // ---- Entry form card ----
        val formCard = cardContainer()
        formCard.addView(sectionLabel(Loc.t(this, "New Entry", "نئی انٹری")))

        val amountBox = outlinedBox()
        amount = EditText(this).apply {
            hint = Loc.t(this@CashActivity, "Amount", "رقم")
            background = null
            inputType = android.text.InputType.TYPE_CLASS_NUMBER or android.text.InputType.TYPE_NUMBER_FLAG_DECIMAL
        }
        amountBox.addView(amount)
        formCard.addView(amountBox)

        val methodBox = outlinedBox()
        methodSpinner = Spinner(this).apply {
            adapter = ArrayAdapter(this@CashActivity, android.R.layout.simple_spinner_dropdown_item, listOf("cash", "bank"))
        }
        methodBox.addView(methodSpinner)
        formCard.addView(methodBox)

        // ---- Expense category (CASH OUT only — hidden entirely for CASH IN entries, since
        // expense categories like "Rent" / "Utility Bills" make no sense on money coming in). ----
        categoryLabel = sectionLabel(Loc.t(this, "Expense Category", "خرچہ کیٹیگری"))
        formCard.addView(categoryLabel)
        categoryBox = outlinedBox()
        categorySpinner = Spinner(this).apply {
            adapter = ArrayAdapter(this@CashActivity, android.R.layout.simple_spinner_dropdown_item, expenseCategories)
        }
        categoryBox.addView(categorySpinner)
        formCard.addView(categoryBox)

        // ---- Miscellaneous description: collapsed by default, expands on tap ----
        miscToggle = TextView(this).apply {
            text = Loc.t(this@CashActivity, "Add description", "تفصیل شامل کریں")
            setLeadingIcon(R.drawable.ic_text, teal, 13, 6)
            textSize = 12f
            setTextColor(Color.parseColor(teal))
            setTypeface(typeface, android.graphics.Typeface.BOLD)
            setPadding(4, 0, 0, 10)
            visibility = View.GONE
            setOnClickListener {
                miscDescBox.visibility = View.VISIBLE
                miscToggle.visibility = View.GONE
                miscDesc.requestFocus()
            }
        }
        formCard.addView(miscToggle)

        miscDescBox = outlinedBox().apply { visibility = View.GONE }
        miscDesc = EditText(this).apply {
            hint = Loc.t(this@CashActivity, "Describe this expense", "اس خرچے کی تفصیل لکھیں")
            background = null
            minLines = 2
            maxLines = 4
            gravity = Gravity.TOP or Gravity.START
        }
        miscDescBox.addView(miscDesc)
        formCard.addView(miscDescBox)

        categorySpinner.onItemSelectedListener = object : AdapterView.OnItemSelectedListener {
            override fun onItemSelected(parent: AdapterView<*>?, view: View?, position: Int, id: Long) {
                val isMisc = expenseCategories.getOrNull(position) == "Miscellaneous"
                if (isMisc) {
                    if (miscDesc.text.isNullOrBlank()) {
                        miscToggle.visibility = View.VISIBLE
                        miscDescBox.visibility = View.GONE
                    } else {
                        miscToggle.visibility = View.GONE
                        miscDescBox.visibility = View.VISIBLE
                    }
                } else {
                    miscToggle.visibility = View.GONE
                    miscDescBox.visibility = View.GONE
                }
            }
            override fun onNothingSelected(parent: AdapterView<*>?) = Unit
        }

        val reasonBox = outlinedBox()
        reason = EditText(this).apply { hint = Loc.t(this@CashActivity, "Reason / Note (optional)", "وجہ / نوٹ (اختیاری)"); background = null }
        reasonBox.addView(reason)
        formCard.addView(reasonBox)

        val btnRow = LinearLayout(this).apply { orientation = LinearLayout.HORIZONTAL }
        btnRow.addView(Button(this).apply {
            text = Loc.t(this@CashActivity, "CASH IN", "کیش ان")
            setTextColor(Color.WHITE)
            background = roundedBg(green, 16)
            setPadding(0, 22, 0, 22)
            layoutParams = LinearLayout.LayoutParams(0, LinearLayout.LayoutParams.WRAP_CONTENT, 1f).apply { setMargins(0,0,8,0) }
            setOnClickListener { saveEntry("IN") }
        })
        btnRow.addView(Button(this).apply {
            text = Loc.t(this@CashActivity, "CASH OUT", "کیش آؤٹ")
            setTextColor(Color.WHITE)
            background = roundedBg(red, 16)
            setPadding(0, 22, 0, 22)
            layoutParams = LinearLayout.LayoutParams(0, LinearLayout.LayoutParams.WRAP_CONTENT, 1f).apply { setMargins(8,0,0,0) }
            setOnClickListener { saveEntry("OUT") }
        })
        formCard.addView(btnRow)
        root.addView(formCard)
        root.addView(spacer(26))

        // ---- Recent transactions ----
        root.addView(sectionLabelPlain(Loc.t(this, "RECENT TRANSACTIONS", "حالیہ لین دین")))
        root.addView(spacer(10))
        listContainer = LinearLayout(this).apply { orientation = LinearLayout.VERTICAL }
        root.addView(listContainer)
        root.addView(spacer(30))

        outer.addView(ScrollView(this).apply {
            setBackgroundColor(Color.parseColor(bg))
            addView(root)
        })
        setContentView(outer)

        loadTodayTotals()
        loadTransactions()
    }

    // ---- UI helpers ----
    private fun cardContainer() = LinearLayout(this).apply {
        orientation = LinearLayout.VERTICAL
        setPadding(24, 22, 24, 22)
        background = roundedBg(cardWhite, 24)
        elevation = 4f
    }

    private fun outlinedBox() = LinearLayout(this).apply {
        orientation = LinearLayout.VERTICAL
        setPadding(20, 14, 20, 14)
        background = strokedBg(border, fieldFill, 14)
        layoutParams = LinearLayout.LayoutParams(
            LinearLayout.LayoutParams.MATCH_PARENT, LinearLayout.LayoutParams.WRAP_CONTENT
        ).apply { setMargins(0, 0, 0, 14) }
    }

    private fun sectionLabel(text: String) = TextView(this).apply {
        this.text = text
        textSize = 15f
        setTextColor(Color.parseColor(textDark))
        setTypeface(typeface, android.graphics.Typeface.BOLD)
        setPadding(2, 0, 0, 14)
    }

    private fun sectionLabelPlain(text: String) = TextView(this).apply {
        this.text = text
        textSize = 12.5f
        setTextColor(Color.parseColor(textMuted))
        setTypeface(typeface, android.graphics.Typeface.BOLD)
        setPadding(4, 0, 0, 0)
    }

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

    private fun statCard(iconRes: Int, label: String, accentHex: String, tintHex: String): Pair<LinearLayout, TextView> {
        val card = LinearLayout(this).apply {
            orientation = LinearLayout.VERTICAL
            setPadding(22, 20, 22, 20)
            background = roundedBg(cardWhite, 22)
            elevation = 4f
        }
        val topRow = LinearLayout(this).apply { orientation = LinearLayout.HORIZONTAL; gravity = Gravity.CENTER_VERTICAL }
        topRow.addView(iconBadge(iconRes, accentHex, bgHex = tintHex, sizeDp = 36, iconSizeDp = 18))
        topRow.addView(TextView(this).apply {
            text = "  $label"; setTextColor(Color.parseColor(textMuted)); textSize = 12f
            setTypeface(typeface, android.graphics.Typeface.BOLD)
        })
        card.addView(topRow)
        val valueText = TextView(this).apply {
            text = "Rs 0.00"
            setTextColor(Color.parseColor(accentHex))
            textSize = 19f
            setTypeface(typeface, android.graphics.Typeface.BOLD)
            setPadding(0, 10, 0, 0)
        }
        card.addView(valueText)
        return Pair(card, valueText)
    }

    // spacer() and lighten() now come from the shared UiHelpers.kt (item #24 dedup) —
    // both were byte-identical private copies here before.
    private fun lightenHex(hex: String): String = String.format("#%06X", 0xFFFFFF and lighten(hex, 0.88f))

    // ---- logic: category now only applies to CASH OUT entries. CASH IN entries never carry an
    // expense category in the reason text, and the category/misc fields are hidden for CASH IN
    // so users aren't shown irrelevant fields (Rent, Utility Bills, etc.) on money coming in. ----
    // FIX (audit — double-tap saved the entry twice): the amount field is only cleared AFTER the
    // suspending insert finishes, so a second tap in that window read the same amount and
    // inserted a duplicate cash entry (the same duplicate class as the Sale History issue).
    private var saving = false

    private fun saveEntry(type: String) {
        if (saving) return
        val amt = amount.text.toString().toDoubleOrNull()
        if (amt == null || amt <= 0.0) {
            Toast.makeText(this, Loc.t(this, "Enter a valid amount", "صحیح رقم لکھیں"), Toast.LENGTH_SHORT).show()
            return
        }
        val method = methodSpinner.selectedItem?.toString() ?: "cash"
        val category = categorySpinner.selectedItem?.toString() ?: ""
        val misc = miscDesc.text.toString().trim()
        val note = reason.text.toString().trim()

        val fullReason = buildString {
            // Category only makes sense for expenses (CASH OUT). Skip it entirely for CASH IN.
            if (type == "OUT" && category.isNotEmpty() && category != NON_EXPENSE) {
                append(category)
                if (category == "Miscellaneous" && misc.isNotEmpty()) {
                    if (isNotEmpty()) append(" - ")
                    append(misc)
                }
            }
            if (note.isNotEmpty()) {
                if (isNotEmpty()) append(" | ")
                append(note)
            }
        }

        saving = true
        lifecycleScope.launch {
            try {
                val db = PosDatabase.get(this@CashActivity)
                // FIX (audit — Cash Out with an expense category never became an Expense): the
                // category was only text inside the cash entry's reason, so Expenses screen,
                // Reports P&L and Balance Sheet profit ignored it (profit overstated) while the
                // same spend entered on the Expense screen was counted. A Cash Out under a real
                // category now creates the Expense + its linked cash entry exactly like
                // ExpenseActivity.saveExpense(), in one transaction.
                if (type == "OUT" && category.isNotEmpty() && category != NON_EXPENSE) {
                    val expenseDesc = buildString {
                        if (category == "Miscellaneous" && misc.isNotEmpty()) append(misc)
                        if (note.isNotEmpty()) {
                            if (isNotEmpty()) append(" | ")
                            append(note)
                        }
                    }
                    db.withTransaction {
                        val expense = Expense(category = category, description = expenseDesc, amount = amt, method = method)
                        val expenseId = db.expenseDao().insert(expense)
                        val savedExpense = expense.copy(id = expenseId)
                        SyncQueueHelper.enqueueExpense(db, savedExpense)
                        val cashTx = CashTransaction(
                            type = "OUT", method = method, amount = amt,
                            reason = "Expense: $category",
                            reference = SyncQueueHelper.expenseEntityId(savedExpense),
                            createdAt = savedExpense.createdAt
                        )
                        val cashTxId = db.cashTransactionDao().insert(cashTx)
                        SyncQueueHelper.enqueueCashTransaction(db, cashTx.copy(id = cashTxId))
                    }
                } else {
                    val tx = CashTransaction(type = type, method = method, amount = amt, reason = fullReason)
                    val newId = db.cashTransactionDao().insert(tx)
                    val savedTx = tx.copy(id = newId)
                    SyncQueueHelper.enqueueCashTransaction(db, savedTx)
                }
                SyncQueueHelper.trigger(this@CashActivity)
                Toast.makeText(this@CashActivity, Loc.t(this@CashActivity, "Saved", "محفوظ ہو گیا"), Toast.LENGTH_SHORT).show()
                amount.text.clear()
                reason.text.clear()
                miscDesc.text.clear()
                miscDescBox.visibility = View.GONE
                miscToggle.visibility = View.GONE
                categorySpinner.setSelection(0)
                loadTodayTotals()
            } finally {
                saving = false
            }
        }
    }

    private fun loadTodayTotals() {
        lifecycleScope.launch {
            val db = PosDatabase.get(this@CashActivity)
            val cal = Calendar.getInstance()
            cal.set(Calendar.HOUR_OF_DAY, 0); cal.set(Calendar.MINUTE, 0)
            cal.set(Calendar.SECOND, 0); cal.set(Calendar.MILLISECOND, 0)
            val start = cal.timeInMillis
            val end = start + 24 * 60 * 60 * 1000L

            val cashIn = db.cashTransactionDao().totalBetween("IN", "cash", start, end)
            val bankIn = db.cashTransactionDao().totalBetween("IN", "bank", start, end)
            val cashOut = db.cashTransactionDao().totalBetween("OUT", "cash", start, end)
            val bankOut = db.cashTransactionDao().totalBetween("OUT", "bank", start, end)

            inTotalText.text = "Rs %.2f".format(cashIn + bankIn)
            outTotalText.text = "Rs %.2f".format(cashOut + bankOut)
        }
    }

    private fun loadTransactions() {
        lifecycleScope.launch {
            PosDatabase.get(this@CashActivity).cashTransactionDao().all().collectLatest { list ->
                listContainer.removeAllViews()
                if (list.isEmpty()) {
                    listContainer.addView(TextView(this@CashActivity).apply {
                        text = Loc.t(this@CashActivity, "No entries yet", "کوئی انٹری نہیں ہے")
                        setTextColor(Color.parseColor(textMuted))
                        setPadding(8,8,8,8)
                    })
                }
                val fmt = SimpleDateFormat("dd MMM, hh:mm a", Locale.getDefault())
                for (t in list.take(50)) {
                    val color = Color.parseColor(if (t.type == "IN") green else red)
                    val sign = if (t.type == "IN") "+" else "-"
                    listContainer.addView(LinearLayout(this@CashActivity).apply {
                        orientation = LinearLayout.VERTICAL
                        setPadding(20, 16, 20, 16)
                        background = roundedBg(cardWhite, 16)
                        elevation = 2f
                        layoutParams = LinearLayout.LayoutParams(
                            LinearLayout.LayoutParams.MATCH_PARENT, LinearLayout.LayoutParams.WRAP_CONTENT
                        ).apply { setMargins(0, 0, 0, 10) }

                        val row = LinearLayout(this@CashActivity).apply { orientation = LinearLayout.HORIZONTAL; gravity = Gravity.CENTER_VERTICAL }
                        row.addView(iconBadge(
                            if (t.type == "IN") R.drawable.ic_trending else R.drawable.ic_trending_down,
                            if (t.type == "IN") green else red,
                            sizeDp = 32, iconSizeDp = 15
                        ))
                        row.addView(spacerH(12))
                        row.addView(TextView(this@CashActivity).apply {
                            text = t.method.uppercase() + if (t.reason.isNotEmpty()) " - ${t.reason}" else ""
                            textSize = 14f
                            setTextColor(Color.parseColor(textDark))
                            layoutParams = LinearLayout.LayoutParams(0, LinearLayout.LayoutParams.WRAP_CONTENT, 1f)
                        })
                        row.addView(TextView(this@CashActivity).apply {
                            text = "$sign Rs %.2f".format(t.amount)
                            setTextColor(color)
                            setTypeface(typeface, android.graphics.Typeface.BOLD)
                            textSize = 15f
                        })
                        addView(row)
                        addView(TextView(this@CashActivity).apply {
                            text = fmt.format(Date(t.createdAt))
                            setTextColor(Color.parseColor(textMuted))
                            textSize = 11.5f
                            setPadding(0, 6, 0, 0)
                        })
                    })
                }
            }
        }
    }
}

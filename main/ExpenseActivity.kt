package com.grocerypos.v11.ui

import android.graphics.Color
import android.graphics.drawable.GradientDrawable
import android.os.Bundle
import android.view.Gravity
import android.view.View
import android.widget.*
import androidx.appcompat.app.AlertDialog
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

class ExpenseActivity : AppCompatActivity() {

    // ---- Pulled from ThemeManager so this screen respects dark mode and stays in sync
    // with the rest of the app. Red/negative logic untouched, only the hex source changed. ----
    private var bg = "#F3F4F9"
    private var navy = "#0B2545"
    private var cardWhite = "#FFFFFF"
    private var textDark = "#1A1D2E"
    private var textMuted = "#8A8FA3"
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
        red = p.red
        teal = p.teal
        border = p.border
        fieldFill = p.fieldFill
    }

    private fun lightenHex(hex: String): String = String.format("#%06X", 0xFFFFFF and lighten(hex, 0.88f))

    private val expenseCategories = listOf(
        "Food Authority License Fees",
        "Utility Bills",
        "Wages",
        "Salaries",
        "Fuel Expense",
        "Pick up Maintenance",
        "Fines",
        "Rent",
        "Income Tax Fees",
        "Zakat",
        "Miscellaneous"
    )

    private lateinit var amount: EditText
    private lateinit var reason: EditText
    private lateinit var categorySpinner: Spinner
    // FIX (Bug 2 — Cash in Hand): which drawer this expense comes out of, same
    // "cash"/"bank" choice CashActivity already offers (see methodSpinner there).
    private lateinit var methodSpinner: Spinner
    private lateinit var miscToggle: TextView
    private lateinit var miscDescBox: LinearLayout
    private lateinit var miscDesc: EditText
    private lateinit var todayTotalText: TextView
    private lateinit var monthTotalText: TextView
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
            title = Loc.t(this@ExpenseActivity, "Expenses", "اخراجات"),
            subtitle = Loc.t(this@ExpenseActivity, "Track your business spending", "اپنے کاروباری اخراجات ٹریک کریں"),
            primaryHex = navy,
            primaryDarkHex = navy
        ))

        val root = LinearLayout(this).apply {
            orientation = LinearLayout.VERTICAL
            setPadding(28, 26, 28, 32)
        }

        // ---- Totals: premium white cards ----
        val totalsRow = LinearLayout(this).apply { orientation = LinearLayout.HORIZONTAL }

        val todayCard = statCard(R.drawable.ic_trending_down, Loc.t(this, "Today's Expense", "آج کا خرچہ"), red, lightenHex(red))
        val monthCard = statCard(R.drawable.ic_calendar, Loc.t(this, "This Month", "اس مہینے"), red, lightenHex(red))
        todayTotalText = todayCard.second
        monthTotalText = monthCard.second

        todayCard.first.layoutParams = LinearLayout.LayoutParams(0, LinearLayout.LayoutParams.WRAP_CONTENT, 1f).apply { setMargins(0,0,9,0) }
        monthCard.first.layoutParams = LinearLayout.LayoutParams(0, LinearLayout.LayoutParams.WRAP_CONTENT, 1f).apply { setMargins(9,0,0,0) }

        totalsRow.addView(todayCard.first)
        totalsRow.addView(monthCard.first)
        root.addView(totalsRow)
        root.addView(spacer(26))

        // ---- Entry form card ----
        val formCard = cardContainer()
        formCard.addView(sectionLabel(Loc.t(this, "New Expense", "نیا خرچہ")))

        val amountBox = outlinedBox()
        amount = EditText(this).apply {
            hint = Loc.t(this@ExpenseActivity, "Amount", "رقم")
            background = null
            inputType = android.text.InputType.TYPE_CLASS_NUMBER or android.text.InputType.TYPE_NUMBER_FLAG_DECIMAL
        }
        amountBox.addView(amount)
        formCard.addView(amountBox)

        formCard.addView(sectionLabel(Loc.t(this, "Expense Category", "خرچہ کیٹیگری")))
        val categoryBox = outlinedBox()
        categorySpinner = Spinner(this).apply {
            adapter = ArrayAdapter(this@ExpenseActivity, android.R.layout.simple_spinner_dropdown_item, expenseCategories)
        }
        categoryBox.addView(categorySpinner)
        formCard.addView(categoryBox)

        // ---- Paid from: cash / bank (FIX — Bug 2, so this expense can actually
        // reduce Cash in Hand / feed the Cash Register the way a purchase or a
        // manual payment already does) ----
        formCard.addView(sectionLabel(Loc.t(this, "Paid From", "کہاں سے ادا کیا")))
        val methodBox = outlinedBox()
        methodSpinner = Spinner(this).apply {
            adapter = ArrayAdapter(this@ExpenseActivity, android.R.layout.simple_spinner_dropdown_item, listOf("cash", "bank"))
        }
        methodBox.addView(methodSpinner)
        formCard.addView(methodBox)

        // ---- Miscellaneous description: collapsed by default, expands on tap ----
        miscToggle = TextView(this).apply {
            text = Loc.t(this@ExpenseActivity, "Add description", "تفصیل شامل کریں")
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
            hint = Loc.t(this@ExpenseActivity, "Describe this expense", "اس خرچے کی تفصیل لکھیں")
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
        reason = EditText(this).apply { hint = Loc.t(this@ExpenseActivity, "Note (optional)", "نوٹ (اختیاری)"); background = null }
        reasonBox.addView(reason)
        formCard.addView(reasonBox)

        formCard.addView(Button(this).apply {
            text = Loc.t(this@ExpenseActivity, "SAVE EXPENSE", "خرچہ محفوظ کریں")
            setTextColor(Color.WHITE)
            isAllCaps = false
            setTypeface(typeface, android.graphics.Typeface.BOLD)
            background = roundedBg(red, 16)
            setPadding(0, 24, 0, 24)
            setOnClickListener { saveExpense() }
        })
        root.addView(formCard)
        root.addView(spacer(26))

        // ---- Recent expenses ----
        root.addView(sectionLabelPlain(Loc.t(this, "RECENT EXPENSES", "حالیہ اخراجات")))
        root.addView(spacer(10))
        listContainer = LinearLayout(this).apply { orientation = LinearLayout.VERTICAL }
        root.addView(listContainer)
        root.addView(spacer(30))

        outer.addView(ScrollView(this).apply {
            setBackgroundColor(Color.parseColor(bg))
            addView(root)
        })
        setContentView(outer)

        loadTotals()
        loadExpenses()
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

    // tintedDrawable()/setLeadingIcon() now come from the shared ui/components/MenuRow.kt —
    // were byte-identical private copies here before (same dedup pattern as spacer() above).

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

    private fun lighten(hex: String, factor: Float): Int {
        val base = Color.parseColor(hex)
        val r = (Color.red(base) + (255 - Color.red(base)) * factor).toInt()
        val g = (Color.green(base) + (255 - Color.green(base)) * factor).toInt()
        val bl = (Color.blue(base) + (255 - Color.blue(base)) * factor).toInt()
        return Color.rgb(r.coerceIn(0,255), g.coerceIn(0,255), bl.coerceIn(0,255))
    }

    // spacer() now comes from the shared UiHelpers.kt (item #24 dedup) — was a
    // byte-identical private copy here before.

    // ---- logic ----
    private fun saveExpense() {
        val amt = amount.text.toString().toDoubleOrNull()
        if (amt == null || amt <= 0.0) {
            Toast.makeText(this, Loc.t(this, "Enter a valid amount", "صحیح رقم لکھیں"), Toast.LENGTH_SHORT).show()
            return
        }
        val category = categorySpinner.selectedItem?.toString() ?: ""
        val method = methodSpinner.selectedItem?.toString() ?: "cash"
        val misc = miscDesc.text.toString().trim()
        val note = reason.text.toString().trim()

        val fullDescription = buildString {
            if (category == "Miscellaneous" && misc.isNotEmpty()) {
                append(misc)
            }
            if (note.isNotEmpty()) {
                if (isNotEmpty()) append(" | ")
                append(note)
            }
        }

        lifecycleScope.launch {
            val db = PosDatabase.get(this@ExpenseActivity)

            // FIX (audit #4 — "Expense save/delete fully atomic nahi", matches
            // CashActivity's identical Cash-Out-as-Expense flow): expense insert,
            // its linked CashTransaction insert, and both sync-queue enqueues used
            // to run as 4 separate un-grouped DB writes. If the app crashed/got
            // killed partway through, the expense could be saved with its cash-out
            // missing (or vice-versa) — Cash in Hand and the expense list would
            // permanently disagree. Wrapped in one db.withTransaction {} so all four
            // either land together or, on a crash, none of them do.
            db.withTransaction {
                val expense = Expense(category = category, description = fullDescription, amount = amt, method = method)
                val newId = db.expenseDao().insert(expense)
                val savedExpense = expense.copy(id = newId)
                // FIX (audit — every new expense showed up TWICE after the next sync): this used
                // to call the raw enqueue(), which never stamps the local row's serverId. The
                // pull that follows a push returns this device's own document too, and with no
                // serverId on the local row findByServerId() found nothing, so the pull inserted
                // a second copy. enqueueExpense() stamps serverId first, so the pull just updates.
                SyncQueueHelper.enqueueExpense(db, savedExpense)

                // FIX (Bug 2 — Expenses never touch Cash Register / Cash Activity /
                // Balance Sheet's "Cash in Hand"): mirrors RoomPurchaseRepository.savePurchase()
                // and PartyTransactionActivity's manual-payment flow — every cash movement
                // needs a matching CashTransaction(type="OUT") or Balance Sheet's all-time
                // "IN(cash) - OUT(cash)" formula never sees this money leave the drawer.
                // `reference` ties it back to this expense so an edit/delete (below) can
                // find and remove the matching drawer entry too, instead of leaving a
                // stale OUT behind forever.
                val cashTx = CashTransaction(
                    type = "OUT", method = method, amount = amt,
                    reason = "Expense" + (if (category.isNotEmpty()) ": $category" else ""),
                    // FIX (audit): reference used the bare LOCAL id ("expense:7"). Two devices
                    // both have an expense #7, so deleting one device's expense also deleted the
                    // OTHER device's cash-out entry (same reference). Now device-unique.
                    reference = SyncQueueHelper.expenseEntityId(savedExpense), createdAt = savedExpense.createdAt
                )
                val cashTxId = db.cashTransactionDao().insert(cashTx)
                SyncQueueHelper.enqueueCashTransaction(db, cashTx.copy(id = cashTxId))
            }

            SyncQueueHelper.trigger(this@ExpenseActivity)
            Toast.makeText(this@ExpenseActivity, Loc.t(this@ExpenseActivity, "Saved", "محفوظ ہو گیا"), Toast.LENGTH_SHORT).show()
            amount.text.clear()
            reason.text.clear()
            miscDesc.text.clear()
            miscDescBox.visibility = View.GONE
            miscToggle.visibility = View.GONE
            categorySpinner.setSelection(0)
            methodSpinner.setSelection(0)
            loadTotals()
        }
    }

    private fun loadTotals() {
        lifecycleScope.launch {
            val db = PosDatabase.get(this@ExpenseActivity)
            val dayCal = Calendar.getInstance()
            dayCal.set(Calendar.HOUR_OF_DAY, 0); dayCal.set(Calendar.MINUTE, 0)
            dayCal.set(Calendar.SECOND, 0); dayCal.set(Calendar.MILLISECOND, 0)
            val dayStart = dayCal.timeInMillis
            val dayEnd = dayStart + 24 * 60 * 60 * 1000L

            val monthCal = Calendar.getInstance()
            monthCal.set(Calendar.DAY_OF_MONTH, 1)
            monthCal.set(Calendar.HOUR_OF_DAY, 0); monthCal.set(Calendar.MINUTE, 0)
            monthCal.set(Calendar.SECOND, 0); monthCal.set(Calendar.MILLISECOND, 0)
            val monthStart = monthCal.timeInMillis
            val monthEndCal = monthCal.clone() as Calendar
            monthEndCal.add(Calendar.MONTH, 1)
            val monthEnd = monthEndCal.timeInMillis

            todayTotalText.text = "Rs %.2f".format(db.expenseDao().totalBetween(dayStart, dayEnd))
            monthTotalText.text = "Rs %.2f".format(db.expenseDao().totalBetween(monthStart, monthEnd))
        }
    }

    private fun loadExpenses() {
        lifecycleScope.launch {
            PosDatabase.get(this@ExpenseActivity).expenseDao().all().collectLatest { list ->
                listContainer.removeAllViews()
                if (list.isEmpty()) {
                    listContainer.addView(TextView(this@ExpenseActivity).apply {
                        text = Loc.t(this@ExpenseActivity, "No expenses yet", "ابھی تک کوئی خرچہ نہیں")
                        setTextColor(Color.parseColor(textMuted))
                        setPadding(8,8,8,8)
                    })
                }
                val fmt = SimpleDateFormat("dd MMM, hh:mm a", Locale.getDefault())
                for (e in list.take(50)) {
                    listContainer.addView(LinearLayout(this@ExpenseActivity).apply {
                        orientation = LinearLayout.VERTICAL
                        setPadding(20, 16, 20, 16)
                        background = roundedBg(cardWhite, 16)
                        elevation = 2f
                        layoutParams = LinearLayout.LayoutParams(
                            LinearLayout.LayoutParams.MATCH_PARENT, LinearLayout.LayoutParams.WRAP_CONTENT
                        ).apply { setMargins(0, 0, 0, 10) }

                        val row = LinearLayout(this@ExpenseActivity).apply { orientation = LinearLayout.HORIZONTAL; gravity = Gravity.CENTER_VERTICAL }
                        row.addView(iconBadge(R.drawable.ic_receipt, red, sizeDp = 32, iconSizeDp = 15))
                        row.addView(spacerH(12))
                        row.addView(TextView(this@ExpenseActivity).apply {
                            text = e.category + if (e.description.isNotEmpty()) " - ${e.description}" else ""
                            textSize = 14f
                            setTextColor(Color.parseColor(textDark))
                            layoutParams = LinearLayout.LayoutParams(0, LinearLayout.LayoutParams.WRAP_CONTENT, 1f)
                        })
                        row.addView(TextView(this@ExpenseActivity).apply {
                            text = "- Rs %.2f".format(e.amount)
                            setTextColor(Color.parseColor(red))
                            setTypeface(typeface, android.graphics.Typeface.BOLD)
                            textSize = 15f
                        })
                        addView(row)

                        val bottomRow = LinearLayout(this@ExpenseActivity).apply {
                            orientation = LinearLayout.HORIZONTAL
                            gravity = Gravity.CENTER_VERTICAL
                        }
                        bottomRow.addView(TextView(this@ExpenseActivity).apply {
                            text = fmt.format(Date(e.createdAt))
                            setTextColor(Color.parseColor(textMuted))
                            textSize = 11.5f
                            layoutParams = LinearLayout.LayoutParams(0, LinearLayout.LayoutParams.WRAP_CONTENT, 1f)
                        })
                        bottomRow.addView(ImageView(this@ExpenseActivity).apply {
                            setImageDrawable(tintedDrawable(R.drawable.ic_delete, red, 13))
                            setPadding(16, 4, 4, 4)
                            setOnClickListener { confirmDeleteExpense(e) }
                        })
                        addView(bottomRow.apply { setPadding(0, 6, 0, 0) })
                    })
                }
            }
        }
    }

    private fun confirmDeleteExpense(e: Expense) {
        AlertDialog.Builder(this)
            .setTitle(Loc.t(this, "Delete Expense", "خرچہ حذف کریں"))
            .setMessage(Loc.t(this, "Remove this expense entry?", "کیا یہ خرچہ حذف کر دیں؟"))
            .setPositiveButton(Loc.t(this, "Delete", "حذف کریں")) { _, _ ->
                lifecycleScope.launch {
                    val db = PosDatabase.get(this@ExpenseActivity)
                    // FIX (audit #4, delete side): expense deletion, its sync-queue
                    // delete-enqueue, and the matching CashTransaction cleanup used to
                    // be 3-4 separate un-grouped DB writes — a crash mid-delete could
                    // remove the expense but leave its CashTransaction(type="OUT")
                    // behind (permanently understating Cash in Hand), or the reverse.
                    // Grouped into one db.withTransaction {} so they all happen or none do.
                    db.withTransaction {
                        db.expenseDao().delete(e)
                        // A delete must also reach Firestore; otherwise another device
                        // would keep showing the removed expense after the next sync.
                        SyncQueueHelper.enqueueDelete(
                            db,
                            "expense",
                            SyncQueueHelper.expenseEntityId(e),
                            this@ExpenseActivity
                        )
                        // FIX (Bug 2 — Cash in Hand): without this, deleting an expense
                        // left its CashTransaction(type="OUT") behind, permanently
                        // understating Cash in Hand by that amount forever after.
                        SyncQueueHelper.deleteCashTransactionsByReference(db, SyncQueueHelper.expenseEntityId(e))
                        // Legacy rows (saved before this fix) used "expense:<localId>". That old
                        // format is only safe to touch for an expense created on THIS device.
                        val madeHere = e.serverId == null || e.serverId.startsWith("expense:${com.grocerypos.v11.DeviceTag.current}-")
                        if (madeHere) SyncQueueHelper.deleteCashTransactionsByReference(db, "expense:${e.id}")
                    }
                    loadTotals()
                }
            }
            .setNegativeButton(Loc.t(this, "Cancel", "منسوخ"), null)
            .show()
    }
}

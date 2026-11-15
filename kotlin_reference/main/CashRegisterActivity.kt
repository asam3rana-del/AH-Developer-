package com.grocerypos.v11.ui
import com.grocerypos.v11.SyncQueueHelper

import android.graphics.Color
import android.graphics.Typeface
import android.os.Bundle
import android.view.Gravity
import android.view.View
import android.widget.*
import androidx.appcompat.app.AlertDialog
import androidx.appcompat.app.AppCompatActivity
import androidx.lifecycle.lifecycleScope
import com.grocerypos.v11.CashRegister
import com.grocerypos.v11.PosDatabase
import com.grocerypos.v11.R
import com.grocerypos.v11.util.Loc
import com.grocerypos.v11.util.parseMoneyOrWarn
import kotlinx.coroutines.flow.collectLatest
import kotlinx.coroutines.launch
import java.text.SimpleDateFormat
import java.util.Calendar
import java.util.Date
import java.util.Locale
import com.grocerypos.v11.ui.components.*

// NEW (Cash Register — made reachable): the CashRegister entity + CashRegisterDao
// already existed in Database.kt (date-keyed openingCash/closingCash/openingBank/
// closingBank/closed) but had ZERO screen, manifest entry, or nav-tile using it
// anywhere in the app — completely dead backend code, unreachable from any Activity.
// This screen wires it up as a real daily till open/close flow:
//   1) OPEN the day with an opening cash/bank balance (auto carried forward from
//      yesterday's closing figures, editable).
//   2) While open, watch today's Cash In/Out and Bank In/Out (read straight from the
//      same cash_transactions table CashActivity already writes to) accumulate against
//      an "Expected Closing" figure.
//   3) CLOSE the day against an actually-counted amount, so a shortage/excess is
//      caught immediately (with a confirm dialog showing the diff) instead of being
//      discovered days later.
// CHANGED (Cash Register sync): this used to be local-only, per-device — same as
// Zakat/Shell Ledger — since a physical till count is inherently tied to whichever
// device/drawer it was counted at. Now synced to Firebase like everything else (see
// SyncQueueHelper.enqueueCashRegister / cashRegisterEntityId's comment): one shared
// register per branch per day, date-keyed, so the till can be opened on one device
// and closed from another. Every db.cashRegisterDao().upsert(...) call below is
// immediately followed by SyncQueueHelper.enqueueCashRegister(db, reg, this) to
// queue + push that change.
class CashRegisterActivity : AppCompatActivity() {

    // ---- Pulled from ThemeManager so this screen respects dark mode, same pattern as CashActivity. ----
    private var bg = "#F3F4F9"
    private var navy = "#0B2545"
    private var cardWhite = "#FFFFFF"
    private var textDark = "#1A1D2E"
    private var textMuted = "#8A8FA3"
    private var green = "#2E7D32"
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

    private val dateKeyFmt = SimpleDateFormat("yyyy-MM-dd", Locale.getDefault())
    private val dateDisplayFmt = SimpleDateFormat("dd MMM yyyy", Locale.getDefault())
    private fun todayKey() = dateKeyFmt.format(Date())

    private lateinit var stateContainer: LinearLayout
    private lateinit var historyContainer: LinearLayout

    override fun onCreate(b: Bundle?) {
        super.onCreate(b)
        loadThemeColors()

        val outer = LinearLayout(this).apply {
            orientation = LinearLayout.VERTICAL
            setBackgroundColor(Color.parseColor(bg))
        }
        outer.addView(premiumHeader(
            iconRes = R.drawable.ic_wallet,
            title = Loc.t(this@CashRegisterActivity, "Cash Register", "کیش رجسٹر"),
            subtitle = Loc.t(this@CashRegisterActivity, "Daily till open & close", "روزانہ کیش رجسٹر کھولنا / بند کرنا"),
            primaryHex = navy,
            primaryDarkHex = navy
        ))

        val root = LinearLayout(this).apply {
            orientation = LinearLayout.VERTICAL
            setPadding(28, 26, 28, 32)
        }

        root.addView(TextView(this).apply {
            text = dateDisplayFmt.format(Date())
            textSize = 13f
            setTextColor(Color.parseColor(textMuted))
            setTypeface(typeface, Typeface.BOLD)
            setPadding(2, 0, 0, 16)
        })

        stateContainer = LinearLayout(this).apply { orientation = LinearLayout.VERTICAL }
        root.addView(stateContainer)
        root.addView(spacer(28))

        root.addView(sectionLabelPlain(Loc.t(this, "REGISTER HISTORY", "رجسٹر کی تاریخ")))
        root.addView(spacer(10))
        historyContainer = LinearLayout(this).apply { orientation = LinearLayout.VERTICAL }
        root.addView(historyContainer)
        root.addView(spacer(30))

        outer.addView(ScrollView(this).apply {
            setBackgroundColor(Color.parseColor(bg))
            addView(root)
        })
        setContentView(outer)

        refresh()
        loadHistory()
    }

    // ---- UI helpers ----
    private fun cardContainer() = LinearLayout(this).apply {
        orientation = LinearLayout.VERTICAL
        setPadding(24, 22, 24, 22)
        background = roundedBg(cardWhite, 24)
        elevation = 4f
        layoutParams = LinearLayout.LayoutParams(LinearLayout.LayoutParams.MATCH_PARENT, LinearLayout.LayoutParams.WRAP_CONTENT)
            .apply { setMargins(0, 0, 0, 16) }
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
        setTypeface(typeface, Typeface.BOLD)
        setPadding(2, 0, 0, 14)
    }

    private fun sectionLabelPlain(text: String) = TextView(this).apply {
        this.text = text
        textSize = 12.5f
        setTextColor(Color.parseColor(textMuted))
        setTypeface(typeface, Typeface.BOLD)
        setPadding(4, 0, 0, 0)
    }

    private fun statusBadge(text: String, colorHex: String) = TextView(this).apply {
        this.text = text
        setTextColor(Color.WHITE)
        textSize = 11f
        setTypeface(typeface, Typeface.BOLD)
        setPadding(16, 6, 16, 6)
        background = roundedBg(colorHex, 20)
    }

    private fun statRow(label: String, value: String, valueColorHex: String = textDark): LinearLayout =
        LinearLayout(this).apply {
            orientation = LinearLayout.HORIZONTAL
            gravity = Gravity.CENTER_VERTICAL
            setPadding(0, 6, 0, 6)
            addView(TextView(this@CashRegisterActivity).apply {
                text = label; textSize = 13f; setTextColor(Color.parseColor(textMuted))
                layoutParams = LinearLayout.LayoutParams(0, LinearLayout.LayoutParams.WRAP_CONTENT, 1f)
            })
            addView(TextView(this@CashRegisterActivity).apply {
                text = value; textSize = 13.5f; setTextColor(Color.parseColor(valueColorHex))
                setTypeface(typeface, Typeface.BOLD)
            })
        }

    private fun divider(): View = View(this).apply {
        setBackgroundColor(Color.parseColor(border))
        layoutParams = LinearLayout.LayoutParams(LinearLayout.LayoutParams.MATCH_PARENT, 1).apply { setMargins(0, 8, 0, 8) }
    }

    // ---- Data loading ----
    private fun startOfDay(date: Date): Long {
        val cal = Calendar.getInstance()
        cal.time = date
        cal.set(Calendar.HOUR_OF_DAY, 0); cal.set(Calendar.MINUTE, 0)
        cal.set(Calendar.SECOND, 0); cal.set(Calendar.MILLISECOND, 0)
        return cal.timeInMillis
    }

    private fun refresh() = lifecycleScope.launch {
        val db = PosDatabase.get(this@CashRegisterActivity)
        val reg = db.cashRegisterDao().find(todayKey())

        val start = startOfDay(Date())
        val end = start + 24 * 60 * 60 * 1000L
        val cashIn = db.cashTransactionDao().totalBetween("IN", "cash", start, end)
        val cashOut = db.cashTransactionDao().totalBetween("OUT", "cash", start, end)
        val bankIn = db.cashTransactionDao().totalBetween("IN", "bank", start, end)
        val bankOut = db.cashTransactionDao().totalBetween("OUT", "bank", start, end)

        stateContainer.removeAllViews()
        if (reg == null) {
            // FIX (audit): the opening balance only ever looked at literally "yesterday".
            // If the register wasn't opened/closed on the previous day (holiday, forgot,
            // shop closed) the new day silently started from Rs 0. Carry forward from the
            // most recent CLOSED register instead.
            val lastClosed = db.cashRegisterDao().lastClosedBefore(todayKey())
            renderNotOpened(lastClosed?.closingCash ?: 0.0, lastClosed?.closingBank ?: 0.0)
        } else if (!reg.closed) {
            renderOpen(reg, cashIn, cashOut, bankIn, bankOut)
        } else {
            renderClosed(reg, cashIn, cashOut, bankIn, bankOut)
        }
    }

    private fun loadHistory() = lifecycleScope.launch {
        val db = PosDatabase.get(this@CashRegisterActivity)
        db.cashRegisterDao().all().collectLatest { list ->
            historyContainer.removeAllViews()
            if (list.isEmpty()) {
                historyContainer.addView(TextView(this@CashRegisterActivity).apply {
                    text = Loc.t(this@CashRegisterActivity, "No register history yet", "ابھی کوئی رجسٹر ریکارڈ نہیں")
                    setTextColor(Color.parseColor(textMuted))
                    setPadding(8, 8, 8, 8)
                })
            }
            for (r in list.take(20)) {
                historyContainer.addView(buildHistoryRow(db, r))
            }
        }
    }

    private suspend fun buildHistoryRow(db: PosDatabase, r: CashRegister): LinearLayout {
        var diffText = Loc.t(this, "In Progress", "جاری ہے")
        var diffColor = textMuted
        if (r.closed) {
            val date = try { dateKeyFmt.parse(r.date) } catch (e: Exception) { null } ?: Date()
            val start = startOfDay(date)
            val end = start + 24 * 60 * 60 * 1000L
            val cashIn = db.cashTransactionDao().totalBetween("IN", "cash", start, end)
            val cashOut = db.cashTransactionDao().totalBetween("OUT", "cash", start, end)
            val bankIn = db.cashTransactionDao().totalBetween("IN", "bank", start, end)
            val bankOut = db.cashTransactionDao().totalBetween("OUT", "bank", start, end)
            val expectedCash = r.openingCash + cashIn - cashOut
            val expectedBank = r.openingBank + bankIn - bankOut
            val totalDiff = (r.closingCash - expectedCash) + (r.closingBank - expectedBank)
            diffText = when {
                Math.abs(totalDiff) < 0.01 -> Loc.t(this, "Matched", "درست")
                totalDiff > 0 -> "+Rs %.2f".format(totalDiff)
                else -> "-Rs %.2f".format(-totalDiff)
            }
            diffColor = if (Math.abs(totalDiff) < 0.01) teal else if (totalDiff < 0) red else green
        }

        return LinearLayout(this).apply {
            orientation = LinearLayout.VERTICAL
            setPadding(18, 14, 18, 14)
            background = roundedBg(cardWhite, 16)
            elevation = 2f
            layoutParams = LinearLayout.LayoutParams(LinearLayout.LayoutParams.MATCH_PARENT, LinearLayout.LayoutParams.WRAP_CONTENT)
                .apply { setMargins(0, 0, 0, 8) }

            val row1 = LinearLayout(this@CashRegisterActivity).apply { orientation = LinearLayout.HORIZONTAL; gravity = Gravity.CENTER_VERTICAL }
            row1.addView(TextView(this@CashRegisterActivity).apply {
                text = r.date; textSize = 13.5f; setTextColor(Color.parseColor(textDark))
                setTypeface(typeface, Typeface.BOLD)
                layoutParams = LinearLayout.LayoutParams(0, LinearLayout.LayoutParams.WRAP_CONTENT, 1f)
            })
            row1.addView(TextView(this@CashRegisterActivity).apply {
                text = diffText; textSize = 12.5f; setTextColor(Color.parseColor(diffColor))
                setTypeface(typeface, Typeface.BOLD)
            })
            addView(row1)
            addView(TextView(this@CashRegisterActivity).apply {
                text = Loc.t(this@CashRegisterActivity, "Open", "کھلا") + ": Rs %.2f / %.2f   ".format(r.openingCash, r.openingBank) +
                    Loc.t(this@CashRegisterActivity, "Close", "بند") + ": Rs %.2f / %.2f".format(r.closingCash, r.closingBank)
                textSize = 11.5f; setTextColor(Color.parseColor(textMuted)); setPadding(0, 4, 0, 0)
            })
        }
    }

    // ---- State renderers ----
    private fun renderNotOpened(prefillCash: Double, prefillBank: Double) {
        val card = cardContainer()

        val badgeRow = LinearLayout(this).apply { orientation = LinearLayout.HORIZONTAL; gravity = Gravity.CENTER_VERTICAL; setPadding(0, 0, 0, 16) }
        badgeRow.addView(statusBadge(Loc.t(this, "NOT OPENED", "نہیں کھلا"), textMuted))
        card.addView(badgeRow)

        card.addView(sectionLabel(Loc.t(this, "Opening Balance", "افتتاحی بیلنس")))

        val cashBox = outlinedBox()
        val cashInput = EditText(this).apply {
            hint = Loc.t(this@CashRegisterActivity, "Opening Cash", "ابتدائی کیش")
            background = null
            inputType = android.text.InputType.TYPE_CLASS_NUMBER or android.text.InputType.TYPE_NUMBER_FLAG_DECIMAL
            if (prefillCash != 0.0) setText("%.2f".format(prefillCash))
        }
        cashBox.addView(cashInput); card.addView(cashBox)

        val bankBox = outlinedBox()
        val bankInput = EditText(this).apply {
            hint = Loc.t(this@CashRegisterActivity, "Opening Bank", "ابتدائی بینک")
            background = null
            inputType = android.text.InputType.TYPE_CLASS_NUMBER or android.text.InputType.TYPE_NUMBER_FLAG_DECIMAL
            if (prefillBank != 0.0) setText("%.2f".format(prefillBank))
        }
        bankBox.addView(bankInput); card.addView(bankBox)

        if (prefillCash != 0.0 || prefillBank != 0.0) {
            card.addView(TextView(this).apply {
                text = Loc.t(this@CashRegisterActivity, "Carried forward from last closing", "پچھلی بندش سے منتقل شدہ")
                textSize = 11f; setTextColor(Color.parseColor(textMuted)); setPadding(2, 0, 0, 14)
            })
        }

        card.addView(Button(this).apply {
            text = Loc.t(this@CashRegisterActivity, "OPEN REGISTER", "رجسٹر کھولیں")
            setTextColor(Color.WHITE)
            background = roundedBg(green, 16)
            setPadding(0, 22, 0, 22)
            setOnClickListener {
                val oc = cashInput.parseMoneyOrWarn(this@CashRegisterActivity, "Opening Cash", "ابتدائی کیش") ?: return@setOnClickListener
                val ob = bankInput.parseMoneyOrWarn(this@CashRegisterActivity, "Opening Bank", "ابتدائی بینک") ?: return@setOnClickListener
                lifecycleScope.launch {
                    val db = PosDatabase.get(this@CashRegisterActivity)
                    // FIX (audit — race window): find()-then-upsert() used to be two separate
                    // steps with a gap between them where a second OPEN (double-tap, or another
                    // caller) could also pass the find()==null check and then REPLACE this one's
                    // row. insertIfAbsent() makes the check-and-insert a single atomic SQLite
                    // statement — it either inserts, or (if today's row already exists) does
                    // nothing and reports that via its return value, with no gap in between.
                    // This covers a single device (e.g. a double-tap). It does NOT cover two
                    // different devices each opening today's register while both still offline —
                    // each passes this same local check independently. FIX (audit — cross-device
                    // OPEN REGISTER race): that case is now closed server-side too, by queuing
                    // this as "create_if_absent" (SyncQueueHelper.enqueueCashRegisterCreate)
                    // instead of a plain upsert — see its comment and SyncApi.push()'s dedicated
                    // branch for how the second device's create is dropped instead of clobbering
                    // the first device's opening balance.
                    val newReg = CashRegister(date = todayKey(), openingCash = oc, openingBank = ob, closingCash = 0.0, closingBank = 0.0, closed = false)
                    val insertedRowId = db.cashRegisterDao().insertIfAbsent(newReg)
                    if (insertedRowId == -1L) {
                        Toast.makeText(this@CashRegisterActivity, Loc.t(this@CashRegisterActivity, "Today's register is already opened on another device", "آج کا رجسٹر کسی اور ڈیوائس پر پہلے ہی کھل چکا ہے"), Toast.LENGTH_LONG).show()
                        refresh()
                        return@launch
                    }
                    com.grocerypos.v11.SyncQueueHelper.enqueueCashRegisterCreate(db, newReg, this@CashRegisterActivity)
                    Toast.makeText(this@CashRegisterActivity, Loc.t(this@CashRegisterActivity, "Register opened", "رجسٹر کھل گیا"), Toast.LENGTH_SHORT).show()
                    refresh()
                }
            }
        })
        stateContainer.addView(card)
    }

    private fun renderOpen(reg: CashRegister, cashIn: Double, cashOut: Double, bankIn: Double, bankOut: Double) {
        val expectedCash = reg.openingCash + cashIn - cashOut
        val expectedBank = reg.openingBank + bankIn - bankOut

        val card = cardContainer()
        val badgeRow = LinearLayout(this).apply { orientation = LinearLayout.HORIZONTAL; gravity = Gravity.CENTER_VERTICAL; setPadding(0, 0, 0, 16) }
        badgeRow.addView(statusBadge(Loc.t(this, "OPEN", "کھلا ہوا"), green))
        card.addView(badgeRow)

        card.addView(statRow(Loc.t(this, "Opening Cash", "ابتدائی کیش"), "Rs %.2f".format(reg.openingCash)))
        card.addView(statRow(Loc.t(this, "Opening Bank", "ابتدائی بینک"), "Rs %.2f".format(reg.openingBank)))
        card.addView(divider())
        card.addView(statRow(Loc.t(this, "Cash In (today)", "آج کیش ان"), "+ Rs %.2f".format(cashIn), green))
        card.addView(statRow(Loc.t(this, "Cash Out (today)", "آج کیش آؤٹ"), "- Rs %.2f".format(cashOut), red))
        card.addView(statRow(Loc.t(this, "Bank In (today)", "آج بینک ان"), "+ Rs %.2f".format(bankIn), green))
        card.addView(statRow(Loc.t(this, "Bank Out (today)", "آج بینک آؤٹ"), "- Rs %.2f".format(bankOut), red))
        card.addView(divider())
        card.addView(statRow(Loc.t(this, "Expected Closing Cash", "متوقع اختتامی کیش"), "Rs %.2f".format(expectedCash), navy))
        card.addView(statRow(Loc.t(this, "Expected Closing Bank", "متوقع اختتامی بینک"), "Rs %.2f".format(expectedBank), navy))

        card.addView(TextView(this).apply {
            text = Loc.t(this@CashRegisterActivity, "Edit opening balance", "ابتدائی بیلنس میں ترمیم کریں")
            setLeadingIcon(R.drawable.ic_edit, teal, 13, 6)
            textSize = 12f; setTextColor(Color.parseColor(teal)); setTypeface(typeface, Typeface.BOLD)
            setPadding(4, 16, 0, 0)
            setOnClickListener { showEditOpeningDialog(reg) }
        })
        stateContainer.addView(card)

        // ---- Close register card ----
        val closeCard = cardContainer()
        closeCard.addView(sectionLabel(Loc.t(this, "Close Register", "رجسٹر بند کریں")))
        closeCard.addView(TextView(this).apply {
            text = Loc.t(this@CashRegisterActivity, "Enter actual counted amounts to close today's register", "بند کرنے کے لیے اصل گنی گئی رقم درج کریں")
            textSize = 12f; setTextColor(Color.parseColor(textMuted)); setPadding(2, 0, 0, 14)
        })

        val actualCashBox = outlinedBox()
        val actualCashInput = EditText(this).apply {
            hint = Loc.t(this@CashRegisterActivity, "Counted Cash", "گنا گیا کیش")
            background = null
            inputType = android.text.InputType.TYPE_CLASS_NUMBER or android.text.InputType.TYPE_NUMBER_FLAG_DECIMAL
            setText("%.2f".format(expectedCash))
        }
        actualCashBox.addView(actualCashInput); closeCard.addView(actualCashBox)

        val actualBankBox = outlinedBox()
        val actualBankInput = EditText(this).apply {
            hint = Loc.t(this@CashRegisterActivity, "Counted Bank", "گنا گیا بینک")
            background = null
            inputType = android.text.InputType.TYPE_CLASS_NUMBER or android.text.InputType.TYPE_NUMBER_FLAG_DECIMAL
            setText("%.2f".format(expectedBank))
        }
        actualBankBox.addView(actualBankInput); closeCard.addView(actualBankBox)

        closeCard.addView(Button(this).apply {
            text = Loc.t(this@CashRegisterActivity, "CLOSE REGISTER", "رجسٹر بند کریں")
            setTextColor(Color.WHITE)
            background = roundedBg(red, 16)
            setPadding(0, 22, 0, 22)
            setOnClickListener {
                val ac = actualCashInput.text.toString().toDoubleOrNull()
                val ab = actualBankInput.text.toString().toDoubleOrNull()
                if (ac == null || ab == null) {
                    Toast.makeText(this@CashRegisterActivity, Loc.t(this@CashRegisterActivity, "Enter valid amounts", "صحیح رقم درج کریں"), Toast.LENGTH_SHORT).show()
                    return@setOnClickListener
                }
                confirmClose(reg, ac, ab, expectedCash, expectedBank)
            }
        })
        stateContainer.addView(closeCard)
    }

    private fun renderClosed(reg: CashRegister, cashIn: Double, cashOut: Double, bankIn: Double, bankOut: Double) {
        val expectedCash = reg.openingCash + cashIn - cashOut
        val expectedBank = reg.openingBank + bankIn - bankOut
        val diffCash = reg.closingCash - expectedCash
        val diffBank = reg.closingBank - expectedBank

        val card = cardContainer()
        val badgeRow = LinearLayout(this).apply { orientation = LinearLayout.HORIZONTAL; gravity = Gravity.CENTER_VERTICAL; setPadding(0, 0, 0, 16) }
        badgeRow.addView(statusBadge(Loc.t(this, "CLOSED", "بند"), textMuted))
        card.addView(badgeRow)

        card.addView(statRow(Loc.t(this, "Opening Cash", "ابتدائی کیش"), "Rs %.2f".format(reg.openingCash)))
        card.addView(statRow(Loc.t(this, "Opening Bank", "ابتدائی بینک"), "Rs %.2f".format(reg.openingBank)))
        card.addView(divider())
        card.addView(statRow(Loc.t(this, "Expected Closing Cash", "متوقع اختتامی کیش"), "Rs %.2f".format(expectedCash)))
        card.addView(statRow(Loc.t(this, "Counted Closing Cash", "گنا گیا اختتامی کیش"), "Rs %.2f".format(reg.closingCash)))
        card.addView(statRow(
            Loc.t(this, "Cash Difference", "کیش فرق"),
            (if (diffCash >= 0) "+" else "") + "Rs %.2f".format(diffCash),
            if (Math.abs(diffCash) < 0.01) teal else if (diffCash < 0) red else green
        ))
        card.addView(divider())
        card.addView(statRow(Loc.t(this, "Expected Closing Bank", "متوقع اختتامی بینک"), "Rs %.2f".format(expectedBank)))
        card.addView(statRow(Loc.t(this, "Counted Closing Bank", "گنا گیا اختتامی بینک"), "Rs %.2f".format(reg.closingBank)))
        card.addView(statRow(
            Loc.t(this, "Bank Difference", "بینک فرق"),
            (if (diffBank >= 0) "+" else "") + "Rs %.2f".format(diffBank),
            if (Math.abs(diffBank) < 0.01) teal else if (diffBank < 0) red else green
        ))

        card.addView(Button(this).apply {
            text = Loc.t(this@CashRegisterActivity, "REOPEN REGISTER", "رجسٹر دوبارہ کھولیں")
            setTextColor(Color.parseColor(navy))
            background = strokedBg(navy, cardWhite, 16)
            setPadding(0, 20, 0, 20)
            layoutParams = LinearLayout.LayoutParams(LinearLayout.LayoutParams.MATCH_PARENT, LinearLayout.LayoutParams.WRAP_CONTENT).apply { topMargin = 18 }
            setOnClickListener {
                lifecycleScope.launch {
                    val db = PosDatabase.get(this@CashRegisterActivity)
                    val updated = reg.copy(closed = false)
                    db.cashRegisterDao().upsert(updated)
                    com.grocerypos.v11.SyncQueueHelper.enqueueCashRegister(db, updated, this@CashRegisterActivity)
                    refresh()
                }
            }
        })
        stateContainer.addView(card)
    }

    // ---- Dialogs ----
    private fun showEditOpeningDialog(reg: CashRegister) {
        val root = LinearLayout(this).apply { orientation = LinearLayout.VERTICAL; setPadding(36, 20, 36, 8) }
        val cashInput = EditText(this).apply {
            hint = Loc.t(this@CashRegisterActivity, "Opening Cash", "ابتدائی کیش")
            setText("%.2f".format(reg.openingCash))
            inputType = android.text.InputType.TYPE_CLASS_NUMBER or android.text.InputType.TYPE_NUMBER_FLAG_DECIMAL
            setPadding(20, 18, 20, 18)
            background = strokedBg(border, fieldFill, 14)
            layoutParams = LinearLayout.LayoutParams(LinearLayout.LayoutParams.MATCH_PARENT, LinearLayout.LayoutParams.WRAP_CONTENT).apply { setMargins(0, 0, 0, 12) }
        }
        root.addView(cashInput)
        val bankInput = EditText(this).apply {
            hint = Loc.t(this@CashRegisterActivity, "Opening Bank", "ابتدائی بینک")
            setText("%.2f".format(reg.openingBank))
            inputType = android.text.InputType.TYPE_CLASS_NUMBER or android.text.InputType.TYPE_NUMBER_FLAG_DECIMAL
            setPadding(20, 18, 20, 18)
            background = strokedBg(border, fieldFill, 14)
        }
        root.addView(bankInput)

        AlertDialog.Builder(this)
            .setTitle(Loc.t(this, "Edit Opening Balance", "ابتدائی بیلنس میں ترمیم"))
            .setView(root)
            .setNegativeButton(Loc.t(this, "Cancel", "منسوخ کریں"), null)
            .setPositiveButton(Loc.t(this, "Save", "محفوظ کریں")) { _, _ ->
                val oc = cashInput.text.toString().toDoubleOrNull() ?: reg.openingCash
                val ob = bankInput.text.toString().toDoubleOrNull() ?: reg.openingBank
                lifecycleScope.launch {
                    val db = PosDatabase.get(this@CashRegisterActivity)
                    val updated = reg.copy(openingCash = oc, openingBank = ob)
                    db.cashRegisterDao().upsert(updated)
                    com.grocerypos.v11.SyncQueueHelper.enqueueCashRegister(db, updated, this@CashRegisterActivity)
                    refresh()
                }
            }
            .show()
    }

    // FIX (audit — stale expected values): recomputes today's expected closing cash/bank
    // straight from cash_transactions right now, instead of trusting a figure that was
    // computed back when the screen last rendered. Actual saved closingCash/closingBank
    // (what the cashier physically counted) were never wrong — only the shortage/excess
    // shown in the confirm dialog could go stale if another cash transaction (Cash In/Out,
    // a sale, a payment) landed after render but before the close. Used both when building
    // the dialog and again right before the save, so neither the message the user reads nor
    // the number of any place that might rely on it is based on an old snapshot.
    private suspend fun freshExpected(reg: CashRegister): Pair<Double, Double> {
        val db = PosDatabase.get(this)
        val date = try { dateKeyFmt.parse(reg.date) } catch (e: Exception) { null } ?: Date()
        val start = startOfDay(date)
        val end = start + 24 * 60 * 60 * 1000L
        val cashIn = db.cashTransactionDao().totalBetween("IN", "cash", start, end)
        val cashOut = db.cashTransactionDao().totalBetween("OUT", "cash", start, end)
        val bankIn = db.cashTransactionDao().totalBetween("IN", "bank", start, end)
        val bankOut = db.cashTransactionDao().totalBetween("OUT", "bank", start, end)
        return (reg.openingCash + cashIn - cashOut) to (reg.openingBank + bankIn - bankOut)
    }

    private fun confirmClose(reg: CashRegister, actualCash: Double, actualBank: Double, expectedCash: Double, expectedBank: Double) {
        lifecycleScope.launch {
            val (freshCash, freshBank) = freshExpected(reg)
            val diffCash = actualCash - freshCash
            val diffBank = actualBank - freshBank
            fun diffLabel(d: Double) = when {
                Math.abs(d) < 0.01 -> Loc.t(this@CashRegisterActivity, "Exact match", "بالکل درست")
                d > 0 -> Loc.t(this@CashRegisterActivity, "Excess", "زائد") + " Rs %.2f".format(d)
                else -> Loc.t(this@CashRegisterActivity, "Shortage", "کمی") + " Rs %.2f".format(-d)
            }
            val msg = Loc.t(this@CashRegisterActivity, "Cash", "کیش") + ": " + diffLabel(diffCash) + "\n" + Loc.t(this@CashRegisterActivity, "Bank", "بینک") + ": " + diffLabel(diffBank)
            AlertDialog.Builder(this@CashRegisterActivity)
                .setTitle(Loc.t(this@CashRegisterActivity, "Confirm Close", "بند کرنے کی تصدیق کریں"))
                .setMessage(msg)
                .setNegativeButton(Loc.t(this@CashRegisterActivity, "Cancel", "منسوخ کریں"), null)
                .setPositiveButton(Loc.t(this@CashRegisterActivity, "Confirm", "تصدیق کریں")) { _, _ ->
                    lifecycleScope.launch {
                        val db = PosDatabase.get(this@CashRegisterActivity)
                        val updated = reg.copy(closingCash = actualCash, closingBank = actualBank, closed = true)
                        db.cashRegisterDao().upsert(updated)
                        com.grocerypos.v11.SyncQueueHelper.enqueueCashRegister(db, updated, this@CashRegisterActivity)
                        Toast.makeText(this@CashRegisterActivity, Loc.t(this@CashRegisterActivity, "Register closed", "رجسٹر بند ہو گیا"), Toast.LENGTH_SHORT).show()
                        refresh()
                    }
                }
                .show()
        }
    }
}

package com.grocerypos.v11.ui

import android.app.AlertDialog
import android.content.Intent
import android.graphics.Color
import android.graphics.drawable.GradientDrawable
import android.os.Bundle
import android.text.InputType
import android.view.Gravity
import android.view.View
import android.widget.ArrayAdapter
import android.widget.EditText
import android.widget.ImageView
import android.widget.LinearLayout
import android.widget.ScrollView
import android.widget.Spinner
import android.widget.TextView
import android.widget.Toast
import androidx.appcompat.app.AppCompatActivity
import androidx.lifecycle.lifecycleScope
import androidx.room.withTransaction
import com.grocerypos.v11.CashTransaction
import com.grocerypos.v11.Payment
import com.grocerypos.v11.PosDatabase
import com.grocerypos.v11.Product
import com.grocerypos.v11.PurchaseItem
import com.grocerypos.v11.SaleItem
import com.grocerypos.v11.SyncQueueHelper
import com.grocerypos.v11.smallestPerUnitOf
import com.grocerypos.v11.smallestQty
import com.grocerypos.v11.smallestUnitFactor
import com.grocerypos.v11.toSmallestUnits
import com.grocerypos.v11.R
import com.grocerypos.v11.ui.components.*
import com.grocerypos.v11.util.Loc
import kotlinx.coroutines.launch
import java.text.SimpleDateFormat
import java.util.Date
import java.util.Locale

/**
 * Opened from PartyDashboardActivity when the user taps a party in the Parties tab.
 * Shows ONLY that party's own transactions (sales if customer, purchases if supplier),
 * newest first. Tapping a row shows a "Billed Items" dialog for that specific sale/
 * purchase — the items on that bill, each editable (qty/rate) and deletable, without
 * opening the full SaleActivity/PurchaseActivity edit screen.
 *
 * Expected intent extras:
 *   partyId: Long, partyName: String, isCustomer: Boolean
 *
 * *** CHANGE *** — billed items dialog is no longer read-only. Each line item now has
 * Edit and Delete actions:
 *   - Edit: change qty/rate for that line. Adjusts product stock by the delta, updates
 *     the parent Sale/Purchase total, and adjusts the party's balance by the same delta
 *     (so credit owed reflects the corrected bill).
 *   - Delete: removes the line. Reverses its stock effect, subtracts its amount from the
 *     parent total and the party balance. If it was the last item on the bill, prompts
 *     to delete the whole sale/purchase too.
 * All of the above enqueue sync_queue entries (product/sale-or-purchase/party) the same
 * way the Edit Party Name flow already does, via SyncQueueHelper.
 *
 * Edit Party Name button uses customerDao()/supplierDao() (picked via isCustomer) — each
 * needs a suspend fun find(id: Long): Customer?/Supplier? and the existing suspend fun
 * update(...). find() was added to both DAOs in Database.kt alongside this change.
 *
 * Manifest registration required:
 *   <activity android:name=".ui.PartyTransactionActivity" android:exported="false" />
 */
/** FIX (#8 — dangerous editing pattern): thrown from inside a db.withTransaction block
 * below to abort it cleanly (Room rolls back every write made so far in that block)
 * when stock turns out to be insufficient mid-way through — caught just outside to
 * show the normal user-facing toast instead of the generic "unknown error" one. */
private class InsufficientStockException(message: String) : Exception(message)

// ---- IMPROVEMENT PACK (Party Transactions 10/10): filter mode for the merged
// bills+payments feed, and a cached row so switching filters/typing a search
// query re-renders instantly from memory instead of re-hitting Room. ----
private enum class TxFilter { ALL, BILLS, PAYMENTS }
private data class TxEntry(val createdAt: Long, val isPayment: Boolean, val searchText: String, val view: LinearLayout)

class PartyTransactionActivity : AppCompatActivity() {

    // ---- Reports-style flat design — pulled from ThemeManager so this screen stays in
    // sync with the rest of the app and respects dark mode. Party = flatPink everywhere
    // per ThemeManager's documented category convention. ----
    private var bg = "#F4F6F8"
    private var cardWhite = "#FFFFFF"
    private var cardBorder = "#E3E8EE"
    private var textDark = "#0B2545"
    private var labelGray = "#7C8798"
    private var green = "#085041"      // flatTealFg — unified with Reports' "positive" color
    private var orange = "#993C1D"     // flatCoralFg
    private var red = "#D32F4A"
    private var teal = "#085041"       // flatTealFg
    private var blue = "#993556"       // primary chrome — flatPinkFg

    private fun loadThemeColors() {
        val p = com.grocerypos.v11.util.ThemeManager.palette(this)
        bg = p.bg
        cardWhite = p.cardWhite
        cardBorder = p.border
        textDark = p.textDark
        labelGray = p.textMuted
        green = p.flatTealFg
        orange = p.flatCoralFg
        red = p.red
        teal = p.flatTealFg
        blue = p.flatPinkFg
    }

    private lateinit var listContainer: LinearLayout
    private lateinit var partyNameLabel: TextView
    private var partyId: Long = -1
    private var partyName: String = ""
    private var isCustomer: Boolean = true

    // ---- IMPROVEMENT PACK (Party Transactions 10/10): balance summary card +
    // filter chips (All/Bills/Payments) + search box above the feed. ----
    private lateinit var openingValueText: TextView
    private lateinit var closingValueText: TextView
    private lateinit var closingLabelText: TextView

    // NEW (Stuck Balance): a small extra card under the balance card, shown ONLY for a
    // customer who has a stuck amount. Everyone else never sees it (visibility = GONE).
    private lateinit var stuckCard: LinearLayout
    private lateinit var stuckDailyValue: TextView
    private lateinit var stuckAmountValue: TextView
    private lateinit var stuckTotalValue: TextView
    private var currentDaily = 0.0
    private var currentStuck = 0.0

    // ---- NEW (Customer Dashboard 10/10): consolidated stat tiles — Total Sales/
    // Purchases, Total Paid, Overdue, Credit Limit, Last Purchase — so a party's full
    // picture (dashboard screenshot: "Customer open karne par ek hi jagah hon") shows
    // on this same screen instead of being scattered across Reports/PartyDashboard.
    // Outstanding is already covered by closingValueText above; Statement + Payment
    // History are already this screen's transaction list + filter chips. ----
    private lateinit var statTotalValue: TextView
    private lateinit var statPaidValue: TextView
    private lateinit var statOverdueValue: TextView
    private lateinit var statCreditValue: TextView
    private lateinit var statLastValue: TextView
    private lateinit var shareStatementBtn: TextView
    private lateinit var chipAll: TextView
    private lateinit var chipBills: TextView
    private lateinit var chipPayments: TextView
    private lateinit var txSearchField: EditText
    private var allEntries: List<TxEntry> = emptyList()
    private var txFilter: TxFilter = TxFilter.ALL
    private var txQuery: String = ""

    // ---- FIX (duplicate-row race) ----
    // loadTransactions() used to be called from BOTH onCreate() and onResume(). On a
    // fresh launch, Android calls onResume() immediately after onCreate() — before the
    // first coroutine's suspend DB query has returned. Both loadTransactions() calls did
    // removeAllViews() on the still-empty container, then each of their coroutines later
    // resumed and independently added a row for the same purchase/sale, producing a
    // transient duplicate that "settled" back to one row once nothing else reloaded.
    // Fixed by (a) loading only once per visible entry — onResume() alone, since it
    // already fires right after onCreate() for a fresh launch — and (b) cancelling any
    // in-flight load before starting a new one so two loads can never both mutate the list.
    private var loadJob: kotlinx.coroutines.Job? = null

    // NEW (P1 security — item #2, PartyTransactionActivity Admin Lock): billed-item
    // edit/delete, qty/rate changes and balance-affecting payment edit/delete are
    // sensitive and admin-only. isAdmin() gates which icons/chips even render;
    // requireAdminOrAbort() is the action-level re-check (item #3) called again
    // right before the actual DB write, so a stale button reference or a future
    // call site can never bypass it.
    private fun isAdmin(): Boolean =
        getSharedPreferences("session", MODE_PRIVATE).getString("role", "cashier") == "admin"

    private fun requireAdminOrAbort(): Boolean {
        if (isAdmin()) return true
        Toast.makeText(this, Loc.t(this, "Sirf Admin ye action kar sakta hai", "صرف ایڈمن یہ عمل کر سکتا ہے"), Toast.LENGTH_LONG).show()
        return false
    }

    override fun onCreate(b: Bundle?) {
        super.onCreate(b)
        loadThemeColors()

        partyId = intent.getLongExtra("partyId", -1)
        partyName = intent.getStringExtra("partyName") ?: ""
        isCustomer = intent.getBooleanExtra("isCustomer", true)

        val root = LinearLayout(this).apply {
            orientation = LinearLayout.VERTICAL
            setPadding(24, 40, 24, 32)
            setBackgroundColor(Color.parseColor(bg))
        }

        val headerRow = LinearLayout(this).apply { orientation = LinearLayout.HORIZONTAL; gravity = Gravity.CENTER_VERTICAL }
        headerRow.addView(TextView(this).apply {
            text = "\u2190"
            textSize = 18f
            setTextColor(Color.parseColor(textDark))
            setPadding(0, 0, 16, 0)
            setOnClickListener { finish() }
        })
        partyNameLabel = TextView(this).apply {
            text = partyName
            textSize = 19f
            setTypeface(typeface, android.graphics.Typeface.BOLD)
            setTextColor(Color.parseColor(textDark))
            layoutParams = LinearLayout.LayoutParams(0, LinearLayout.LayoutParams.WRAP_CONTENT, 1f)
        }
        headerRow.addView(partyNameLabel)

        // ---- Edit party name button — opens a small dialog to rename this party. ----
        headerRow.addView(TextView(this).apply {
            text = Loc.t(this@PartyTransactionActivity, "Edit", "\u062A\u0631\u0645\u06CC\u0645")
            textSize = 12.5f
            setTextColor(Color.WHITE)
            setTypeface(typeface, android.graphics.Typeface.BOLD)
            setLeadingIcon(R.drawable.ic_edit, "#FFFFFF", 13, 6)
            background = GradientDrawable().apply {
                setColor(Color.parseColor(teal))
                cornerRadius = 30f
            }
            setPadding(22, 12, 22, 12)
            setOnClickListener { promptEditPartyName() }
        })
        // NEW: "Receive Payment" (customer) / "Make Payment" (supplier) — previously there
        // was no way at all to record money actually changing hands against the running
        // balance; the only entries possible were full sale/purchase bills. This opens a
        // small dialog (amount, cash/bank, optional note) that adjusts the balance directly.
        headerRow.addView(TextView(this).apply {
            text = "  " + (if (isCustomer) Loc.t(this@PartyTransactionActivity, "Receive Payment", "\u0627\u062F\u0627\u0626\u06CC\u06AF\u06CC \u0648\u0635\u0648\u0644 \u06A9\u0631\u06CC\u06BA")
                else Loc.t(this@PartyTransactionActivity, "Make Payment", "\u0627\u062F\u0627\u0626\u06CC\u06AF\u06CC \u06A9\u0631\u06CC\u06BA"))
            textSize = 12.5f
            setTextColor(Color.WHITE)
            setTypeface(typeface, android.graphics.Typeface.BOLD)
            setLeadingIcon(R.drawable.ic_wallet, "#FFFFFF", 13, 6)
            background = GradientDrawable().apply {
                setColor(Color.parseColor(if (isCustomer) green else orange))
                cornerRadius = 30f
            }
            setPadding(22, 12, 22, 12)
            val lp = LinearLayout.LayoutParams(LinearLayout.LayoutParams.WRAP_CONTENT, LinearLayout.LayoutParams.WRAP_CONTENT)
            lp.marginStart = 12
            layoutParams = lp
            setOnClickListener { showPaymentDialog() }
        })
        root.addView(headerRow)

        root.addView(TextView(this).apply {
            text = if (isCustomer) Loc.t(this@PartyTransactionActivity, "Customer transactions", "\u06A9\u0633\u0679\u0645\u0631 \u0644\u06CC\u0646 \u062F\u06CC\u0646")
            else Loc.t(this@PartyTransactionActivity, "Supplier transactions", "\u0633\u067E\u0644\u0627\u0626\u0631 \u0644\u06CC\u0646 \u062F\u06CC\u0646")
            textSize = 12.5f
            setTextColor(Color.parseColor(labelGray))
            setPadding(28, 4, 0, 20)
        })

        // ---- IMPROVEMENT PACK (Party Transactions 10/10): balance summary card.
        // This screen showed the full money trail but never the party's actual
        // current balance — the only place to see "You'll Get/Give" for this
        // exact party was to back out of this screen to the dashboard list.
        // Filled in from loadPartyBalance(), called by loadTransactions(). ----
        val balanceCard = LinearLayout(this).apply {
            orientation = LinearLayout.HORIZONTAL
            setPadding(20, 16, 20, 16)
            background = GradientDrawable().apply {
                setColor(Color.parseColor(cardWhite))
                cornerRadius = 16f
                setStroke(1, Color.parseColor(cardBorder))
            }
            elevation = 2f
            layoutParams = LinearLayout.LayoutParams(
                LinearLayout.LayoutParams.MATCH_PARENT, LinearLayout.LayoutParams.WRAP_CONTENT
            ).apply { setMargins(0, 0, 0, 16) }
        }
        val openingCol = LinearLayout(this).apply {
            orientation = LinearLayout.VERTICAL
            layoutParams = LinearLayout.LayoutParams(0, LinearLayout.LayoutParams.WRAP_CONTENT, 1f)
        }
        openingCol.addView(TextView(this).apply {
            text = Loc.t(this@PartyTransactionActivity, "Opening", "\u0627\u0628\u062A\u062F\u0627\u0626\u06CC")
            textSize = 11f
            setTextColor(Color.parseColor(labelGray))
        })
        openingValueText = TextView(this).apply {
            text = "Rs 0.00"
            textSize = 14f
            setTypeface(typeface, android.graphics.Typeface.BOLD)
            setTextColor(Color.parseColor(textDark))
            setPadding(0, 4, 0, 0)
        }
        openingCol.addView(openingValueText)
        balanceCard.addView(openingCol)

        val closingCol = LinearLayout(this).apply {
            orientation = LinearLayout.VERTICAL
            gravity = Gravity.END
        }
        closingLabelText = TextView(this).apply {
            text = Loc.t(this@PartyTransactionActivity, "You'll Get", "\u0622\u067E \u06A9\u0648 \u0645\u0644\u06CC\u06BA \u06AF\u06D2")
            textSize = 11f
            setTextColor(Color.parseColor(green))
        }
        closingCol.addView(closingLabelText)
        closingValueText = TextView(this).apply {
            text = "Rs 0.00"
            textSize = 15f
            setTypeface(typeface, android.graphics.Typeface.BOLD)
            setTextColor(Color.parseColor(green))
            setPadding(0, 4, 0, 0)
        }
        closingCol.addView(closingValueText)
        balanceCard.addView(closingCol)
        root.addView(balanceCard)

        // ---- NEW (Stuck Balance): Daily / Stuck / Total split. Hidden until a customer
        // with a non-zero stuck amount is loaded (see updateStuckCard). ----
        stuckCard = LinearLayout(this).apply {
            orientation = LinearLayout.VERTICAL
            setPadding(20, 14, 20, 14)
            background = GradientDrawable().apply {
                setColor(Color.parseColor(cardWhite))
                cornerRadius = 16f
                setStroke(1, Color.parseColor(cardBorder))
            }
            elevation = 2f
            layoutParams = LinearLayout.LayoutParams(
                LinearLayout.LayoutParams.MATCH_PARENT, LinearLayout.LayoutParams.WRAP_CONTENT
            ).apply { setMargins(0, 0, 0, 16) }
            visibility = View.GONE
        }
        fun stuckLine(label: String, bold: Boolean): TextView {
            val valueView = TextView(this).apply {
                text = "Rs 0.00"
                textSize = if (bold) 15f else 13.5f
                setTypeface(typeface, if (bold) android.graphics.Typeface.BOLD else android.graphics.Typeface.NORMAL)
                setTextColor(Color.parseColor(textDark))
            }
            stuckCard.addView(LinearLayout(this).apply {
                orientation = LinearLayout.HORIZONTAL
                gravity = Gravity.CENTER_VERTICAL
                setPadding(0, if (bold) 8 else 3, 0, if (bold) 0 else 3)
                addView(TextView(this@PartyTransactionActivity).apply {
                    text = label
                    textSize = if (bold) 13f else 12f
                    if (bold) setTypeface(typeface, android.graphics.Typeface.BOLD)
                    setTextColor(Color.parseColor(if (bold) textDark else labelGray))
                    layoutParams = LinearLayout.LayoutParams(0, LinearLayout.LayoutParams.WRAP_CONTENT, 1f)
                })
                addView(valueView)
            })
            return valueView
        }
        stuckDailyValue = stuckLine(Loc.t(this, "Daily Payable", "روزانہ واجب الادا"), false)
        stuckAmountValue = stuckLine(Loc.t(this, "Stuck (Purana)", "اسٹک (پرانا)"), false)
        // thin divider before the Total line
        stuckCard.addView(View(this).apply {
            setBackgroundColor(Color.parseColor(cardBorder))
            layoutParams = LinearLayout.LayoutParams(LinearLayout.LayoutParams.MATCH_PARENT, 1).apply { setMargins(0, 6, 0, 0) }
        })
        stuckTotalValue = stuckLine(Loc.t(this, "Total Payable", "کل واجب الادا"), true)
        root.addView(stuckCard)

        // ---- NEW (Customer Dashboard 10/10): 2x2 stat grid + Share Statement button.
        // Values are filled in by updateDashboardStats(), called from loadTransactions()
        // using the same sales/purchases/payments already fetched there — no extra
        // DB round trip just for this card. ----
        root.addView(buildDashboardStatsCard())
        root.addView(TextView(this).apply {
            shareStatementBtn = this
            text = "  " + Loc.t(this@PartyTransactionActivity, "Share Statement", "\u0633\u0679\u06CC\u0679\u0645\u0646\u0679 \u0634\u06CC\u0626\u0631 \u06A9\u0631\u06CC\u06BA")
            textSize = 13f
            gravity = Gravity.CENTER
            setTextColor(Color.WHITE)
            setTypeface(typeface, android.graphics.Typeface.BOLD)
            setLeadingIcon(R.drawable.ic_share, "#FFFFFF", 14, 6)
            background = GradientDrawable().apply {
                setColor(Color.parseColor(if (isCustomer) green else orange))
                cornerRadius = 12f
            }
            setPadding(0, 26, 0, 26)
            layoutParams = LinearLayout.LayoutParams(
                LinearLayout.LayoutParams.MATCH_PARENT, LinearLayout.LayoutParams.WRAP_CONTENT
            ).apply { setMargins(0, 0, 0, 16) }
            setOnClickListener { shareStatement() }
        })

        // ---- IMPROVEMENT PACK (Party Transactions 10/10): search box + filter
        // chips (All/Bills/Payments) — a party with months of history otherwise
        // has no way to jump to just their payments, or find one old bill. Both
        // just re-filter allEntries in memory, no DB hit. ----
        val txSearchBox = LinearLayout(this).apply {
            orientation = LinearLayout.VERTICAL
            setPadding(18, 8, 18, 8)
            background = GradientDrawable().apply {
                setColor(Color.parseColor("#F7F8FC"))
                cornerRadius = 10f
                setStroke(1, Color.parseColor(cardBorder))
            }
            layoutParams = LinearLayout.LayoutParams(
                LinearLayout.LayoutParams.MATCH_PARENT, LinearLayout.LayoutParams.WRAP_CONTENT
            ).apply { setMargins(0, 0, 0, 10) }
        }
        txSearchField = EditText(this).apply {
            hint = Loc.t(this@PartyTransactionActivity, "Search this history (date, note, amount)", "\u0627\u0633 \u062A\u0627\u0631\u06CC\u062E \u0645\u06CC\u06BA \u062A\u0644\u0627\u0634 \u06A9\u0631\u06CC\u06BA")
            background = null
            textSize = 14f
            addTextChangedListener(object : android.text.TextWatcher {
                override fun beforeTextChanged(s: CharSequence?, start: Int, count: Int, after: Int) {}
                override fun onTextChanged(s: CharSequence?, start: Int, before: Int, count: Int) {}
                override fun afterTextChanged(s: android.text.Editable?) {
                    txQuery = s?.toString().orEmpty()
                    renderEntries()
                }
            })
        }
        txSearchBox.addView(txSearchField)
        root.addView(txSearchBox)

        val filterChipRow = LinearLayout(this).apply {
            orientation = LinearLayout.HORIZONTAL
            setPadding(0, 0, 0, 14)
        }
        fun filterChip(label: String, mode: TxFilter): TextView = TextView(this).apply {
            text = label
            textSize = 12f
            setTypeface(typeface, android.graphics.Typeface.BOLD)
            setPadding(24, 12, 24, 12)
            val lp = LinearLayout.LayoutParams(LinearLayout.LayoutParams.WRAP_CONTENT, LinearLayout.LayoutParams.WRAP_CONTENT)
            lp.marginEnd = 10
            layoutParams = lp
            setOnClickListener {
                txFilter = mode
                updateFilterChipStyles()
                renderEntries()
            }
        }
        chipAll = filterChip(Loc.t(this@PartyTransactionActivity, "All", "\u0633\u0628"), TxFilter.ALL)
        chipBills = filterChip(Loc.t(this@PartyTransactionActivity, "Bills", "\u0628\u0644"), TxFilter.BILLS)
        chipPayments = filterChip(Loc.t(this@PartyTransactionActivity, "Payments", "\u0627\u062F\u0627\u0626\u06CC\u06AF\u06CC\u0627\u06BA"), TxFilter.PAYMENTS)
        filterChipRow.addView(chipAll)
        filterChipRow.addView(chipBills)
        filterChipRow.addView(chipPayments)
        root.addView(filterChipRow)
        updateFilterChipStyles()

        listContainer = LinearLayout(this).apply { orientation = LinearLayout.VERTICAL }
        root.addView(listContainer)

        setContentView(ScrollView(this).apply {
            setBackgroundColor(Color.parseColor(bg))
            addView(root)
        })

        // ---- FIX: no longer loading here — onResume() (called right after onCreate on
        // a fresh launch, and again whenever the screen returns to the foreground) is now
        // the single place that triggers a load. See loadJob comment above for why. ----

        // NEW: dashboard "+" quick menu's "Payment Received"/"Payment Made" launches this
        // screen with openPayment=true after the user already picked the party, so open the
        // payment dialog immediately instead of making them tap the header button again.
        // Showing an AlertDialog here doesn't trigger onPause/onResume of this activity, so
        // this only runs once per launch (never re-fires when the dialog itself is dismissed).
        if (intent.getBooleanExtra("openPayment", false)) {
            showPaymentDialog()
        }
    }

    override fun onResume() {
        super.onResume()
        loadTransactions()
    }

    // ---------------- Edit party name ----------------

    private fun promptEditPartyName() {
        val input = EditText(this).apply {
            setPadding(32, 24, 32, 24)
            setText(partyName)
            setSelection(text.length)
        }

        AlertDialog.Builder(this)
            .setTitle(Loc.t(this, "Edit Name", "\u0646\u0627\u0645 \u062A\u0631\u0645\u06CC\u0645 \u06A9\u0631\u06CC\u06BA"))
            .setView(input)
            .setPositiveButton(Loc.t(this, "Save", "\u0645\u062D\u0641\u0648\u0638 \u06A9\u0631\u06CC\u06BA")) { _, _ ->
                val newName = input.text.toString().trim()
                if (newName.isEmpty()) {
                    Toast.makeText(this, Loc.t(this, "Name cannot be empty", "\u0646\u0627\u0645 \u062E\u0627\u0644\u06CC \u0646\u06C1\u06CC\u06BA \u06C1\u0648 \u0633\u06A9\u062A\u0627"), Toast.LENGTH_SHORT).show()
                } else {
                    saveNewPartyName(newName)
                }
            }
            .setNegativeButton(Loc.t(this, "Cancel", "\u0645\u0646\u0633\u0648\u062E \u06A9\u0631\u06CC\u06BA"), null)
            .show()
    }

    private fun saveNewPartyName(newName: String) {
        lifecycleScope.launch {
            try {
                val db = PosDatabase.get(this@PartyTransactionActivity)
                var found = false

                if (isCustomer) {
                    db.customerDao().find(partyId)?.let { customer ->
                        found = true
                        val updated = customer.copy(name = newName)
                        db.customerDao().update(updated)
                        // FIX (sync): this rename path (via PartyTransactionActivity's Edit
                        // button) never enqueued a sync_queue entry, so a name changed here
                        // never reached Firestore even though the equivalent edit dialog in
                        // PartyActivity does enqueue correctly. Mirrors that same pattern.
                        SyncQueueHelper.enqueueCustomer(db, updated)
                        SyncQueueHelper.trigger(this@PartyTransactionActivity)
                    }
                } else {
                    db.supplierDao().find(partyId)?.let { supplier ->
                        found = true
                        val updated = supplier.copy(name = newName)
                        db.supplierDao().update(updated)
                        SyncQueueHelper.enqueueSupplier(db, updated)
                        SyncQueueHelper.trigger(this@PartyTransactionActivity)
                    }
                }

                if (found) {
                    partyName = newName
                    partyNameLabel.text = newName

                    Toast.makeText(
                        this@PartyTransactionActivity,
                        Loc.t(this@PartyTransactionActivity, "Name updated", "\u0646\u0627\u0645 \u0627\u067E \u0688\u06CC\u0679 \u06C1\u0648 \u06AF\u06CC\u0627"),
                        Toast.LENGTH_SHORT
                    ).show()
                } else {
                    Toast.makeText(
                        this@PartyTransactionActivity,
                        Loc.t(this@PartyTransactionActivity, "Party not found", "\u067E\u0627\u0631\u0679\u06CC \u0646\u06C1\u06CC\u06BA \u0645\u0644\u06CC"),
                        Toast.LENGTH_SHORT
                    ).show()
                }
            } catch (e: Exception) {
                Toast.makeText(
                    this@PartyTransactionActivity,
                    "Could not update name: ${e.message ?: "unknown error"}",
                    Toast.LENGTH_LONG
                ).show()
            }
        }
    }

    // ---------------- Receive Payment / Make Payment ----------------

    // NEW: small dialog to record money actually paid/received against this party's
    // balance, without needing a full sale or purchase bill.
    // ---- IMPROVEMENT PACK (Payments 10/10): now doubles as the Edit dialog — pass
    // an existing Payment to pre-fill every field and save via updatePayment()
    // instead of creating a new one. Also adds an optional "Link to a bill" picker
    // so a payment can be tied to one specific sale/purchase instead of only ever
    // adjusting the party's general balance. ----
    private fun showPaymentDialog(existing: Payment? = null) {
        lifecycleScope.launch {
            val billOptions = loadBillOptionsForParty()
            val padding = (24 * resources.displayMetrics.density).toInt()
            val col = LinearLayout(this@PartyTransactionActivity).apply { orientation = LinearLayout.VERTICAL; setPadding(padding, padding, padding, padding) }

            val amountInput = EditText(this@PartyTransactionActivity).apply {
                hint = Loc.t(this@PartyTransactionActivity, "Amount", "\u0631\u0642\u0645")
                inputType = InputType.TYPE_CLASS_NUMBER or InputType.TYPE_NUMBER_FLAG_DECIMAL
                if (existing != null) setText(if (existing.amount == existing.amount.toLong().toDouble()) existing.amount.toLong().toString() else existing.amount.toString())
            }
            col.addView(amountInput)
            col.addView(View(this@PartyTransactionActivity).apply {
                layoutParams = LinearLayout.LayoutParams(LinearLayout.LayoutParams.MATCH_PARENT, (10 * resources.displayMetrics.density).toInt())
            })

            // ---- Date picker, defaulted to today (or the existing payment's date
            // when editing). Capped at today since a payment can't happen in the
            // future. ----
            val dateCal = java.util.Calendar.getInstance().apply { if (existing != null) timeInMillis = existing.createdAt }
            val dateFmt = SimpleDateFormat("dd MMM yyyy", Locale.getDefault())
            val dateField = TextView(this@PartyTransactionActivity).apply {
                text = dateFmt.format(dateCal.time)
                setLeadingIcon(R.drawable.ic_calendar, textDark, 15, 8)
                textSize = 15f
                setTextColor(Color.parseColor(textDark))
                setPadding(0, 18, 0, 18)
                isClickable = true
                setOnClickListener {
                    android.app.DatePickerDialog(
                        this@PartyTransactionActivity,
                        { _, year, month, dayOfMonth ->
                            dateCal.set(year, month, dayOfMonth)
                            text = dateFmt.format(dateCal.time)
                            setLeadingIcon(R.drawable.ic_calendar, textDark, 15, 8)
                        },
                        dateCal.get(java.util.Calendar.YEAR),
                        dateCal.get(java.util.Calendar.MONTH),
                        dateCal.get(java.util.Calendar.DAY_OF_MONTH)
                    ).apply { datePicker.maxDate = System.currentTimeMillis(); datePicker.calendarViewShown = true; datePicker.spinnersShown = false }.show()
                }
            }
            col.addView(dateField)
            col.addView(View(this@PartyTransactionActivity).apply {
                setBackgroundColor(Color.parseColor(cardBorder))
                layoutParams = LinearLayout.LayoutParams(LinearLayout.LayoutParams.MATCH_PARENT, 1).apply { setMargins(0, 0, 0, 10) }
            })

            val methodSpinner = Spinner(this@PartyTransactionActivity).apply {
                adapter = ArrayAdapter(this@PartyTransactionActivity, android.R.layout.simple_spinner_dropdown_item, listOf("cash", "bank"))
                if (existing != null && existing.method.equals("bank", ignoreCase = true)) setSelection(1)
            }
            col.addView(methodSpinner)
            col.addView(View(this@PartyTransactionActivity).apply {
                layoutParams = LinearLayout.LayoutParams(LinearLayout.LayoutParams.MATCH_PARENT, (10 * resources.displayMetrics.density).toInt())
            })

            // ---- IMPROVEMENT PACK (Payments 10/10): optional "Link to a bill" picker.
            // Index 0 is always "General (not linked)" — the original, still-default
            // behavior of adjusting the party's overall balance only. ----
            val generalLabel = Loc.t(this@PartyTransactionActivity, "General (not linked to a bill)", "\u0639\u0627\u0645 (\u06A9\u0633\u06CC \u0628\u0644 \u0633\u06D2 \u0645\u0646\u0633\u0644\u06A9 \u0646\u06C1\u06CC\u06BA)")
            val billLabels = listOf(generalLabel) + billOptions.map { it.label }
            val billSpinner = Spinner(this@PartyTransactionActivity).apply {
                adapter = ArrayAdapter(this@PartyTransactionActivity, android.R.layout.simple_spinner_dropdown_item, billLabels)
                val preselect = existing?.billReference?.takeIf { it.isNotEmpty() }?.let { ref -> billOptions.indexOfFirst { it.ref == ref } }
                if (preselect != null && preselect >= 0) setSelection(preselect + 1)
            }
            col.addView(billSpinner)
            col.addView(View(this@PartyTransactionActivity).apply {
                layoutParams = LinearLayout.LayoutParams(LinearLayout.LayoutParams.MATCH_PARENT, (10 * resources.displayMetrics.density).toInt())
            })

            val noteInput = EditText(this@PartyTransactionActivity).apply {
                hint = Loc.t(this@PartyTransactionActivity, "Note (optional)", "\u0646\u0648\u0679 (\u0627\u062E\u062A\u06CC\u0627\u0631\u06CC)")
                if (existing != null) setText(existing.note)
            }
            col.addView(noteInput)

            AlertDialog.Builder(this@PartyTransactionActivity)
                .setTitle(
                    if (existing != null) Loc.t(this@PartyTransactionActivity, "Edit Payment", "\u0627\u062F\u0627\u0626\u06CC\u06AF\u06CC \u0645\u06CC\u06BA \u062A\u0631\u0645\u06CC\u0645")
                    else if (isCustomer) Loc.t(this@PartyTransactionActivity, "Receive Payment", "\u0627\u062F\u0627\u0626\u06CC\u06AF\u06CC \u0648\u0635\u0648\u0644 \u06A9\u0631\u06CC\u06BA")
                    else Loc.t(this@PartyTransactionActivity, "Make Payment", "\u0627\u062F\u0627\u0626\u06CC\u06AF\u06CC \u06A9\u0631\u06CC\u06BA")
                )
                .setView(col)
                .setPositiveButton(Loc.t(this@PartyTransactionActivity, "Save", "\u0645\u062D\u0641\u0648\u0638 \u06A9\u0631\u06CC\u06BA")) { _, _ ->
                    val amt = amountInput.text.toString().toDoubleOrNull()
                    if (amt == null || amt <= 0.0) {
                        Toast.makeText(this@PartyTransactionActivity, Loc.t(this@PartyTransactionActivity, "Enter a valid amount", "\u0635\u062D\u06CC\u062D \u0631\u0642\u0645 \u0644\u06A9\u06BE\u06CC\u06BA"), Toast.LENGTH_SHORT).show()
                        return@setPositiveButton
                    }
                    val method = methodSpinner.selectedItem?.toString() ?: "cash"
                    val note = noteInput.text.toString().trim()
                    val billRef = if (billSpinner.selectedItemPosition <= 0) "" else billOptions[billSpinner.selectedItemPosition - 1].ref
                    if (existing != null) {
                        updatePayment(existing, amt, method, note, dateCal.timeInMillis, billRef)
                    } else {
                        savePayment(amt, method, note, dateCal.timeInMillis, billRef)
                    }
                }
                .setNegativeButton(Loc.t(this@PartyTransactionActivity, "Cancel", "\u0645\u0646\u0633\u0648\u062E \u06A9\u0631\u06CC\u06BA"), null)
                .show()
        }
    }

    private class BillOption(val label: String, val ref: String)

    // ADDED (Purchase/Sale History "due" not clearing after payment): a payment
    // recorded here could already be linked to a specific bill via billReference
    // (see loadBillOptionsForParty()/the "Link to a bill" picker), but that link
    // was purely cosmetic — it only showed up on the receipt text. The bill's own
    // `paid` field (what Purchase History/Sale History actually read to decide
    // DUE vs PAID and to compute "Balance") was never touched, only the party's
    // aggregate balance was. So a shopkeeper could fully pay off a supplier here
    // and still see that exact bill sitting in Purchase History marked DUE
    // forever. This applies `delta` (positive when paying more, negative when
    // reversing/reducing a payment) to that bill's `paid`, clamped to
    // [0, total], and enqueues the updated bill so the other device's History
    // screen agrees too.
    private suspend fun applyBillPaidDelta(db: PosDatabase, billRef: String, delta: Double) {
        if (billRef.isBlank() || delta == 0.0) return
        if (isCustomer) {
            val sale = db.saleDao().findSale(billRef) ?: return
            val newPaid = (sale.paid + delta).coerceIn(0.0, sale.total)
            val updated = sale.copy(paid = newPaid, dirty = true)
            db.saleDao().updateSale(updated)
            SyncQueueHelper.enqueue(db, "sale", SyncQueueHelper.saleEntityId(updated), "update", SyncQueueHelper.saleJson(db, updated))
        } else {
            val purchase = db.purchaseDao().findPurchase(billRef) ?: return
            val newPaid = (purchase.paid + delta).coerceIn(0.0, purchase.total)
            val updated = purchase.copy(paid = newPaid, dirty = true)
            db.purchaseDao().updatePurchase(updated)
            SyncQueueHelper.enqueue(db, "purchase", SyncQueueHelper.purchaseEntityId(updated), "update", SyncQueueHelper.purchaseJson(db, updated))
        }
    }

    /** Recent (unreturned) bills for this party, newest first, for the payment
     * dialog's optional "Link to a bill" picker. */
    private suspend fun loadBillOptionsForParty(): List<BillOption> {
        val db = PosDatabase.get(this)
        return if (isCustomer) {
            db.saleDao().salesByCustomer(partyId)
                .filter { it.status != "returned" }
                .sortedByDescending { it.createdAt }
                .take(50)
                .map { BillOption("${it.invoice} \u2022 Rs %.2f".format(it.total), it.invoice) }
        } else {
            db.purchaseDao().purchasesBySupplier(partyId)
                .filter { it.status != "returned" }
                .sortedByDescending { it.createdAt }
                .take(50)
                .map { BillOption("${it.billNo} \u2022 Rs %.2f".format(it.total), it.billNo) }
        }
    }

    private fun savePayment(amount: Double, method: String, note: String, dateMillis: Long, billRef: String = "") {
        lifecycleScope.launch {
            val db = PosDatabase.get(this@PartyTransactionActivity)
            val partyType = if (isCustomer) "customer" else "supplier"
            val reference = "manual-$partyType-$partyId-${System.currentTimeMillis()}"
            val reasonText = (if (isCustomer) "Payment received from $partyName" else "Payment made to $partyName") +
                if (note.isNotEmpty()) " | $note" else ""

            // FIX (P7 code review): payment insert, balance adjustment, and the
            // matching cash transaction now run inside one db.withTransaction —
            // same atomicity guarantee as RoomSaleRepository.saveSale() /
            // RoomPurchaseRepository.savePurchase(). Previously these were three
            // separate sequential writes, so a crash/kill mid-save could record
            // the payment without adjusting the party's balance (or vice versa).
            db.withTransaction {
                // ---- IMPROVEMENT PACK (Payments 10/10): both the payment row and its
                // matching cash-ledger entry use the picked dateMillis (not "now"), so
                // a backdated payment shows on the right day in both this party's
                // history AND the Cash/Day Book screens — not just here.
                val payment = Payment(reference = reference, partyType = partyType, partyId = partyId, amount = amount, method = method, note = note, billReference = billRef, createdAt = dateMillis)
                val paymentId = db.paymentDao().insert(payment)
                SyncQueueHelper.enqueuePayment(db, payment.copy(id = paymentId))

                // A customer paying us reduces what they owe (balance goes down); us paying a
                // supplier reduces what we owe them — both are a negative adjustment.
                if (isCustomer) SyncQueueHelper.adjustCustomerBalance(db, partyId, -amount)
                else SyncQueueHelper.adjustSupplierBalance(db, partyId, -amount)

                val cashTx = CashTransaction(type = if (isCustomer) "IN" else "OUT", method = method.lowercase(), amount = amount, reason = reasonText, reference = reference, createdAt = dateMillis)
                val cashTxId = db.cashTransactionDao().insert(cashTx)
                SyncQueueHelper.enqueueCashTransaction(db, cashTx.copy(id = cashTxId))

                applyBillPaidDelta(db, billRef, amount)
            }
            SyncQueueHelper.trigger(this@PartyTransactionActivity)

            Toast.makeText(this@PartyTransactionActivity, Loc.t(this@PartyTransactionActivity, "Payment saved", "\u0627\u062F\u0627\u0626\u06CC\u06AF\u06CC \u0645\u062D\u0641\u0648\u0638 \u06C1\u0648 \u06AF\u0626\u06CC"), Toast.LENGTH_SHORT).show()
            loadTransactions()

            // ---- IMPROVEMENT PACK (Payments 10/10): offer to share a receipt right
            // after saving — this is the moment the amount/date/method are freshest
            // in mind, and it's when a customer/supplier is most likely waiting for
            // a confirmation message. ----
            offerToShareReceipt(amount, method, note, dateMillis, billRef)
        }
    }

    /** ---- IMPROVEMENT PACK (Payments 10/10): edits an existing payment in place —
     * updates the Payment row, adjusts the party's balance by only the *change* in
     * amount (not the full amount again), and updates the matching cash-ledger
     * entry (found by the shared `reference`) so Cash/Day Book stays in sync too. */
    private fun updatePayment(original: Payment, newAmount: Double, newMethod: String, newNote: String, newDateMillis: Long, newBillRef: String) {
        lifecycleScope.launch {
            if (!requireAdminOrAbort()) return@launch
            val db = PosDatabase.get(this@PartyTransactionActivity)
            val delta = newAmount - original.amount
            val reasonText = (if (isCustomer) "Payment received from $partyName" else "Payment made to $partyName") +
                if (newNote.isNotEmpty()) " | $newNote" else ""

            db.withTransaction {
                val updatedPayment = original.copy(amount = newAmount, method = newMethod, note = newNote, billReference = newBillRef, createdAt = newDateMillis, dirty = true)
                db.paymentDao().update(updatedPayment)
                SyncQueueHelper.enqueuePayment(db, updatedPayment)

                if (delta != 0.0) {
                    // Same sign convention as the original insert: a bigger payment
                    // reduces the balance further; a smaller one gives some back.
                    if (isCustomer) SyncQueueHelper.adjustCustomerBalance(db, partyId, -delta)
                    else SyncQueueHelper.adjustSupplierBalance(db, partyId, -delta)
                }

                db.cashTransactionDao().findByReference(original.reference)?.let { tx ->
                    val updatedTx = tx.copy(amount = newAmount, method = newMethod.lowercase(), reason = reasonText, createdAt = newDateMillis, dirty = true)
                    db.cashTransactionDao().update(updatedTx)
                    SyncQueueHelper.enqueueCashTransaction(db, updatedTx)
                }

                // Same reasoning as savePayment()'s applyBillPaidDelta call: keep
                // whichever bill(s) this payment touches in sync with the edited
                // amount/link. If the bill link itself changed, reverse the full
                // original amount off the old bill and apply the new amount to the
                // new one; otherwise just apply the amount's delta to the one bill.
                if (original.billReference == newBillRef) {
                    applyBillPaidDelta(db, newBillRef, delta)
                } else {
                    applyBillPaidDelta(db, original.billReference, -original.amount)
                    applyBillPaidDelta(db, newBillRef, newAmount)
                }
            }
            SyncQueueHelper.trigger(this@PartyTransactionActivity)
            Toast.makeText(this@PartyTransactionActivity, Loc.t(this@PartyTransactionActivity, "Payment updated", "\u0627\u062F\u0627\u0626\u06CC\u06AF\u06CC \u0627\u067E \u0688\u06CC\u0679 \u06C1\u0648 \u06AF\u0626\u06CC"), Toast.LENGTH_SHORT).show()
            loadTransactions()
        }
    }

    /** ---- IMPROVEMENT PACK (Payments 10/10): deletes a payment, reversing exactly
     * what it did — the balance adjustment and its matching cash-ledger entry —
     * instead of leaving the party's balance permanently off by that amount. */
    private fun confirmDeletePayment(payment: Payment) {
        AlertDialog.Builder(this)
            .setTitle(Loc.t(this, "Delete Payment", "\u0627\u062F\u0627\u0626\u06CC\u06AF\u06CC \u0688\u06CC\u0644\u06CC\u0679 \u06A9\u0631\u06CC\u06BA"))
            .setMessage(Loc.t(
                this,
                "Delete this Rs %.2f payment? The party's balance will be adjusted back.".format(payment.amount),
                "\u06A9\u06CC\u0627 \u06CC\u06C1 Rs %.2f \u06A9\u06CC \u0627\u062F\u0627\u0626\u06CC\u06AF\u06CC \u062D\u0630\u0641 \u06A9\u06CC \u062C\u0627\u0626\u06D2\u061F \u067E\u0627\u0631\u0679\u06CC \u06A9\u0627 \u0628\u06CC\u0644\u06CC\u0646\u0633 \u0648\u0627\u067E\u0633 \u0627\u06CC\u0688\u062C\u0633\u0679 \u06C1\u0648 \u062C\u0627\u0626\u06D2 \u06AF\u0627\u06D4".format(payment.amount)
            ))
            .setPositiveButton(Loc.t(this, "Delete", "\u062D\u0630\u0641 \u06A9\u0631\u06CC\u06BA")) { _, _ -> deletePayment(payment) }
            .setNegativeButton(Loc.t(this, "Cancel", "\u0645\u0646\u0633\u0648\u062E \u06A9\u0631\u06CC\u06BA"), null)
            .show()
    }

    private fun deletePayment(payment: Payment) {
        lifecycleScope.launch {
            if (!requireAdminOrAbort()) return@launch
            val db = PosDatabase.get(this@PartyTransactionActivity)
            db.withTransaction {
                // FIX (audit — "deleted payment comes back after sync"): this used to
                // delete EVERY row sharing the reference straight from Room but only queue a
                // sync-delete for ONE payment (and one cash entry), built from THIS device's
                // id. Any extra row (leftover duplicate) or any row that originated on the
                // other device therefore stayed alive on the server and was pulled back in.
                // These helpers read the rows first and queue a delete for each with its
                // real serverId.
                SyncQueueHelper.deletePaymentsByReference(db, payment.reference)
                SyncQueueHelper.deleteCashTransactionsByReference(db, payment.reference)

                // Reverse exactly what savePayment() applied: it adjusted by -amount,
                // so undoing it is +amount.
                if (isCustomer) SyncQueueHelper.adjustCustomerBalance(db, partyId, payment.amount)
                else SyncQueueHelper.adjustSupplierBalance(db, partyId, payment.amount)

                applyBillPaidDelta(db, payment.billReference, -payment.amount)
            }
            SyncQueueHelper.trigger(this@PartyTransactionActivity)
            Toast.makeText(this@PartyTransactionActivity, Loc.t(this@PartyTransactionActivity, "Payment deleted", "\u0627\u062F\u0627\u0626\u06CC\u06AF\u06CC \u062D\u0630\u0641 \u06C1\u0648 \u06AF\u0626\u06CC"), Toast.LENGTH_SHORT).show()
            loadTransactions()
        }
    }

    /** ---- IMPROVEMENT PACK (Payments 10/10): asks whether to share a receipt for
     * a just-saved payment, then builds a plain-text message and hands it to
     * Intent.ACTION_SEND (chooser includes WhatsApp/SMS/etc. — whatever the
     * device has) rather than sending directly through any one channel. */
    private fun offerToShareReceipt(amount: Double, method: String, note: String, dateMillis: Long, billRef: String) {
        AlertDialog.Builder(this)
            .setTitle(Loc.t(this, "Share receipt?", "\u0631\u0633\u06CC\u062F \u0634\u06CC\u0626\u0631 \u06A9\u0631\u06CC\u06BA\u061F"))
            .setMessage(Loc.t(this, "Send a payment confirmation to $partyName?", "$partyName \u06A9\u0648 \u0627\u062F\u0627\u0626\u06CC\u06AF\u06CC \u06A9\u06CC \u062A\u0635\u062F\u06CC\u0642 \u0628\u06BE\u06CC\u062C\u06CC\u06BA\u061F"))
            .setPositiveButton(Loc.t(this, "Share", "\u0634\u06CC\u0626\u0631 \u06A9\u0631\u06CC\u06BA")) { _, _ -> shareReceipt(amount, method, note, dateMillis, billRef) }
            .setNegativeButton(Loc.t(this, "Not now", "ابھی نہیں"), null)
            .show()
    }

    private fun shareReceipt(amount: Double, method: String, note: String, dateMillis: Long, billRef: String) {
        val dateText = SimpleDateFormat("dd MMM yyyy", Locale.getDefault()).format(Date(dateMillis))
        val verb = if (isCustomer) Loc.t(this, "Payment Received", "\u0627\u062F\u0627\u0626\u06CC\u06AF\u06CC \u0648\u0635\u0648\u0644 \u06C1\u0648\u0626\u06CC")
            else Loc.t(this, "Payment Made", "\u0627\u062F\u0627\u0626\u06CC\u06AF\u06CC \u06C1\u0648\u0626\u06CC")
        val lines = mutableListOf(
            "$verb",
            "${Loc.t(this, "Party", "\u067E\u0627\u0631\u0679\u06CC")}: $partyName",
            "${Loc.t(this, "Amount", "\u0631\u0642\u0645")}: Rs %.2f".format(amount),
            "${Loc.t(this, "Date", "\u062A\u0627\u0631\u06CC\u062E")}: $dateText",
            "${Loc.t(this, "Method", "\u0630\u0631\u06CC\u0639\u06C1")}: ${method.uppercase()}"
        )
        if (billRef.isNotEmpty()) lines.add("${Loc.t(this, "Against Bill", "\u0628\u0644 \u0646\u0645\u0628\u0631")}: $billRef")
        if (note.isNotEmpty()) lines.add("${Loc.t(this, "Note", "\u0646\u0648\u0679")}: $note")
        val text = lines.joinToString("\n")
        startActivity(Intent.createChooser(Intent(Intent.ACTION_SEND).apply {
            type = "text/plain"
            putExtra(Intent.EXTRA_TEXT, text)
        }, Loc.t(this, "Share receipt", "\u0631\u0633\u06CC\u062F \u0634\u06CC\u0626\u0631 \u06A9\u0631\u06CC\u06BA")))
    }

    private fun loadTransactions() {
        // Cancel any load already in flight so its (possibly late-arriving) results can
        // never race with this one and duplicate rows — see loadJob comment above.
        loadJob?.cancel()
        loadJob = lifecycleScope.launch {
            val db = PosDatabase.get(this@PartyTransactionActivity)
            val fmt = SimpleDateFormat("dd MMM yyyy, hh:mm a", Locale.getDefault())

            // ---- IMPROVEMENT PACK (Party Transactions 10/10): balance summary,
            // fetched alongside the transaction feed since both come from this
            // same load pass (onResume / after a payment or bill edit). ----
            // PERMANENT FIX (balance drift — "paid supplier still shows You'll Get"):
            // `running` used to be read straight from the stored customer.balance/
            // supplier.balance field, which is only ever nudged +/- by every sale,
            // purchase, payment, edit and delete (see SyncQueueHelper.adjustCustomer/
            // SupplierBalance) — any one adjustment that ever fired without a perfectly
            // matching real transaction (an orphaned/duplicate payment row, an
            // interrupted sync, an old build's bug) left that stored number permanently
            // wrong with nothing to ever correct it. `running` is now computed fresh,
            // below, straight from this party's actual non-returned bills and
            // standalone payments — the exact same definition PartyRepository.
            // recalculateBalances()'s "Fix Balances" uses — so there is no stored
            // number left to drift; it's recalculated from the real ledger on every
            // load of this screen.
            val opening: Double
            val stuck: Double
            var creditLimit = 0.0
            if (isCustomer) {
                val customer = db.customerDao().find(partyId)
                opening = customer?.openingBalance ?: 0.0
                stuck = customer?.stuckBalance ?: 0.0
                creditLimit = customer?.creditLimit ?: 0.0
            } else {
                val supplier = db.supplierDao().find(partyId)
                opening = supplier?.openingBalance ?: 0.0
                stuck = 0.0
            }

            // NEW: standalone payments recorded via the Receive Payment/Make Payment button
            // — merged chronologically with the sale/purchase bills below so the full money
            // trail for this party shows in one list instead of only ever showing bills.
            // FIX (audit — supplier list showed a phantom "Payment Made" row for every purchase,
            // with live Edit/Delete buttons): savePurchase() writes a "Purchase payment" row
            // (reference == the purchase's billNo) for whatever was paid at bill time. That
            // money is already the purchase's own `paid`, so listing it again double-counted
            // "Total Paid" and let the user Edit/Delete it here — which moved the party balance
            // WITHOUT touching the purchase's `paid` (permanent drift). Only genuine standalone
            // payments (manual Receive/Make Payment) belong in this list.
            val ownBillIds: Set<String> = if (isCustomer) db.saleDao().salesByCustomer(partyId).map { it.invoice }.toHashSet()
                else db.purchaseDao().purchasesBySupplier(partyId).map { it.billNo }.toHashSet()
            val payments = db.paymentDao().listByParty(if (isCustomer) "customer" else "supplier", partyId)
                .filter { it.reference !in ownBillIds }

            val entries = mutableListOf<TxEntry>()

            // ---- NEW (Customer Dashboard 10/10): running totals for the stat grid,
            // built from the exact same bill lists below (single DB round trip). ----
            var totalAmount = 0.0
            var totalPaidOnBills = 0.0
            var overdueAmount = 0.0
            // PERMANENT FIX (balance drift): outstanding summed ONLY from non-returned
            // bills — a returned bill has nothing left owing, same rule recalculateBalances()
            // uses. This plus paymentsSum below (computed further down) is `running`.
            var outstandingActive = 0.0
            var lastActivityAt: Long? = null
            val now = System.currentTimeMillis()

            if (isCustomer) {
                db.saleDao().salesByCustomer(partyId).forEach { s ->
                    totalAmount += s.total
                    totalPaidOnBills += s.paid
                    if (s.status != "returned") outstandingActive += (s.total - s.paid)
                    if (s.status != "returned" && s.dueDate > 0L && s.dueDate < now && (s.total - s.paid) > 0.009) {
                        overdueAmount += (s.total - s.paid)
                    }
                    if (lastActivityAt == null || s.createdAt > lastActivityAt!!) lastActivityAt = s.createdAt

                    val dateText = fmt.format(Date(s.createdAt))
                    val typeLabel = Loc.t(this@PartyTransactionActivity, "Sale", "\u0633\u06CC\u0644")
                    entries.add(TxEntry(
                        createdAt = s.createdAt,
                        isPayment = false,
                        searchText = "$dateText $typeLabel ${s.total}".lowercase(),
                        view = row(
                            amount = s.total,
                            dateText = dateText,
                            typeLabel = typeLabel,
                            status = s.status,
                            accent = green,
                            iconRes = R.drawable.ic_cart
                        ) {
                            // ---- CHANGE: opens billed items dialog with edit/delete
                            // instead of the full SaleActivity edit screen. ----
                            showBilledItemsDialog(isSale = true, invoice = s.invoice, billNo = "")
                        }
                    ))
                }
            } else {
                db.purchaseDao().purchasesBySupplier(partyId).forEach { p ->
                    totalAmount += p.total
                    totalPaidOnBills += p.paid
                    if (p.status != "returned") outstandingActive += (p.total - p.paid)
                    // NEW: Purchase.dueDate now exists (MIGRATION_42_43) — same overdue
                    // rule as the customer/Sale branch above.
                    if (p.status != "returned" && p.dueDate > 0L && p.dueDate < now && (p.total - p.paid) > 0.009) {
                        overdueAmount += (p.total - p.paid)
                    }
                    if (lastActivityAt == null || p.createdAt > lastActivityAt!!) lastActivityAt = p.createdAt

                    val dateText = fmt.format(Date(p.createdAt))
                    val typeLabel = Loc.t(this@PartyTransactionActivity, "Purchase", "\u062E\u0631\u06CC\u062F\u0627\u0631\u06CC")
                    entries.add(TxEntry(
                        createdAt = p.createdAt,
                        isPayment = false,
                        searchText = "$dateText $typeLabel ${p.total}".lowercase(),
                        view = row(
                            amount = p.total,
                            dateText = dateText,
                            typeLabel = typeLabel,
                            status = p.status,
                            accent = orange,
                            iconRes = R.drawable.ic_receipt
                        ) {
                            // ---- CHANGE: opens billed items dialog with edit/delete
                            // instead of the full PurchaseActivity edit screen. ----
                            showBilledItemsDialog(isSale = false, invoice = "", billNo = p.billNo)
                        }
                    ))
                }
            }
            // FIX (audit): a payment linked to a bill is already folded into that bill's `paid`
            // (applyBillPaidDelta) — counting it again here inflated "Total Paid".
            val paymentsSum = payments.filter { it.billReference.isBlank() }.sumOf { it.amount }
            updateDashboardStats(totalAmount, totalPaidOnBills, paymentsSum, overdueAmount, creditLimit, lastActivityAt)

            // PERMANENT FIX (balance drift — see the big comment near the top of this
            // function): `running` = outstanding on this party's own active bills minus
            // standalone payments made against them, computed fresh every load instead
            // of read from the stored (and driftable) customer.balance/supplier.balance.
            val running = outstandingActive - paymentsSum
            // NEW (Stuck Balance): the headline "You'll Get" figure is the TOTAL (daily +
            // stuck); the split card below explains it. stuck == 0.0 => identical to before.
            updateBalanceCard(opening, opening + running + stuck)
            updateStuckCard(opening + running, stuck)

            payments.forEach { pay ->
                val dateText = fmt.format(Date(pay.createdAt))
                val label = (if (isCustomer) Loc.t(this@PartyTransactionActivity, "Payment Received", "\u0627\u062F\u0627\u0626\u06CC\u06AF\u06CC \u0648\u0635\u0648\u0644 \u06C1\u0648\u0626\u06CC")
                    else Loc.t(this@PartyTransactionActivity, "Payment Made", "\u0627\u062F\u0627\u0626\u06CC\u06AF\u06CC \u06C1\u0648\u0626\u06CC")) +
                    "  \u2022  " + pay.method.uppercase() + (if (pay.note.isNotEmpty()) "  \u2022  ${pay.note}" else "") +
                    (if (pay.billReference.isNotEmpty()) "  \u2022  " + Loc.t(this@PartyTransactionActivity, "Against", "\u0628\u0631\u0627\u06D2 \u0631\u0627\u0633\u062A") + " ${pay.billReference}" else "")
                entries.add(TxEntry(
                    createdAt = pay.createdAt,
                    isPayment = true,
                    searchText = "$dateText $label ${pay.amount} ${pay.method} ${pay.note} ${pay.billReference}".lowercase(),
                    // ---- IMPROVEMENT PACK (Payments 10/10): payments now get their own
                    // row with Edit/Delete/Share actions, instead of the plain tap-only
                    // `row()` used for bills — a wrong amount/date/method could never be
                    // corrected before, only deleted-and-redone by hand outside the app. ----
                    view = paymentRow(pay, dateText, label)
                ))
            }

            allEntries = entries.sortedByDescending { it.createdAt }
            renderEntries()
        }
    }

    /** Re-filters [allEntries] by [txFilter] + [txQuery] and redraws — no DB hit,
     * safe to call on every keystroke or chip tap. */
    private fun renderEntries() {
        listContainer.removeAllViews()
        val q = txQuery.trim().lowercase()
        val filtered = allEntries.filter { entry ->
            val passesFilter = when (txFilter) {
                TxFilter.ALL -> true
                TxFilter.BILLS -> !entry.isPayment
                TxFilter.PAYMENTS -> entry.isPayment
            }
            passesFilter && (q.isEmpty() || entry.searchText.contains(q))
        }
        if (filtered.isEmpty()) {
            val msg = if (allEntries.isEmpty())
                Loc.t(this, "No transactions yet", "\u0627\u0628\u06BE\u06CC \u062A\u06A9 \u06A9\u0648\u0626\u06CC \u0644\u06CC\u0646 \u062F\u06CC\u0646 \u0646\u06C1\u06CC\u06BA \u06C1\u06D2")
            else
                Loc.t(this, "No matching transactions", "\u06A9\u0648\u0626\u06CC \u0645\u0645\u0627\u062B\u0644 \u0644\u06CC\u0646 \u062F\u06CC\u0646 \u0646\u06C1\u06CC\u06BA")
            listContainer.addView(placeholderCard(msg))
        } else {
            filtered.forEach { listContainer.addView(it.view) }
        }
    }

    private fun updateFilterChipStyles() {
        val accent = if (isCustomer) green else orange
        fun style(chip: TextView, mode: TxFilter) {
            val active = txFilter == mode
            chip.background = GradientDrawable().apply {
                setColor(Color.parseColor(if (active) accent else "#EEF0F7"))
                cornerRadius = 24f
            }
            chip.setTextColor(if (active) Color.WHITE else Color.parseColor("#6B7280"))
        }
        style(chipAll, TxFilter.ALL)
        style(chipBills, TxFilter.BILLS)
        style(chipPayments, TxFilter.PAYMENTS)
    }

    /** NEW (Stuck Balance): fills + shows/hides the Daily / Stuck / Total card. */
    private fun updateStuckCard(daily: Double, stuck: Double) {
        currentDaily = daily
        currentStuck = stuck
        if (stuck == 0.0) {
            stuckCard.visibility = View.GONE
            return
        }
        stuckDailyValue.text = "Rs %.2f".format(daily)
        stuckAmountValue.text = "Rs %.2f".format(stuck)
        stuckTotalValue.text = "Rs %.2f".format(daily + stuck)
        stuckCard.visibility = View.VISIBLE
    }

    /** Updates the opening/closing balance card. Closing direction mirrors the
     * same type-aware give/get rule used everywhere else in the Party screens:
     * customer closing > 0 = they owe us (green, You'll Get); supplier
     * closing > 0 = we owe them (red, You'll Give). */
    private fun updateBalanceCard(opening: Double, closing: Double) {
        openingValueText.text = "Rs %.2f".format(opening)
        val give = if (isCustomer) closing < 0 else closing > 0
        val color = if (give) red else green
        closingValueText.text = "Rs %.2f".format(kotlin.math.abs(closing))
        closingValueText.setTextColor(Color.parseColor(color))
        closingLabelText.text = if (give) Loc.t(this, "You'll Give", "\u0622\u067E \u06A9\u0648 \u062F\u06CC\u0646\u06D2 \u06C1\u06CC\u06BA")
            else Loc.t(this, "You'll Get", "\u0622\u067E \u06A9\u0648 \u0645\u0644\u06CC\u06BA \u06AF\u06D2")
        closingLabelText.setTextColor(Color.parseColor(color))
    }

    // ==================== NEW (Customer Dashboard 10/10) ====================

    /** Builds the 2-column stat grid card: Total Sales/Purchases, Total Paid,
     * Overdue, Credit Limit, and a full-width Last Purchase/Sale row. Values start
     * blank/zero and are filled by [updateDashboardStats] on every load. */
    private fun buildDashboardStatsCard(): LinearLayout {
        val accent = if (isCustomer) green else orange
        val card = LinearLayout(this).apply {
            orientation = LinearLayout.VERTICAL
            setPadding(20, 18, 20, 14)
            background = GradientDrawable().apply {
                setColor(Color.parseColor(cardWhite))
                cornerRadius = 16f
                setStroke(1, Color.parseColor(cardBorder))
            }
            elevation = 2f
            layoutParams = LinearLayout.LayoutParams(
                LinearLayout.LayoutParams.MATCH_PARENT, LinearLayout.LayoutParams.WRAP_CONTENT
            ).apply { setMargins(0, 0, 0, 16) }
        }

        fun tile(labelText: String, valueColor: String): Pair<LinearLayout, TextView> {
            val col = LinearLayout(this).apply {
                orientation = LinearLayout.VERTICAL
                layoutParams = LinearLayout.LayoutParams(0, LinearLayout.LayoutParams.WRAP_CONTENT, 1f)
            }
            col.addView(TextView(this).apply {
                text = labelText
                textSize = 11f
                setTextColor(Color.parseColor(labelGray))
            })
            val value = TextView(this).apply {
                text = "Rs 0.00"
                textSize = 14.5f
                setTypeface(typeface, android.graphics.Typeface.BOLD)
                setTextColor(Color.parseColor(valueColor))
                setPadding(0, 4, 0, 0)
            }
            col.addView(value)
            return col to value
        }

        fun rowOf(vararg tiles: LinearLayout): LinearLayout = LinearLayout(this).apply {
            orientation = LinearLayout.HORIZONTAL
            layoutParams = LinearLayout.LayoutParams(
                LinearLayout.LayoutParams.MATCH_PARENT, LinearLayout.LayoutParams.WRAP_CONTENT
            ).apply { setMargins(0, 0, 0, 14) }
            tiles.forEach { addView(it) }
        }

        val (totalCol, totalVal) = tile(
            if (isCustomer) Loc.t(this, "Total Sales", "\u06A9\u0644 \u0641\u0631\u0648\u062E\u062A")
            else Loc.t(this, "Total Purchases", "\u06A9\u0644 \u062E\u0631\u06CC\u062F\u0627\u0631\u06CC"),
            textDark
        )
        statTotalValue = totalVal

        val (paidCol, paidVal) = tile(Loc.t(this, "Total Paid", "\u06A9\u0644 \u0627\u062F\u0627\u0626\u06CC\u06AF\u06CC"), green)
        statPaidValue = paidVal
        card.addView(rowOf(totalCol, paidCol))

        val (overdueCol, overdueVal) = tile(Loc.t(this, "Overdue", "\u0645\u06CC\u0639\u0627\u062F \u06AF\u0632\u0631 \u06AF\u0626\u06CC"), red)
        statOverdueValue = overdueVal

        val (creditCol, creditVal) = tile(
            if (isCustomer) Loc.t(this, "Credit Limit", "\u06A9\u0631\u06CC\u0688\u0679 \u0644\u0645\u0679") else Loc.t(this, "—", "\u2014"),
            textDark
        )
        statCreditValue = creditVal
        card.addView(rowOf(overdueCol, creditCol))
        // Supplier parties have no credit limit field in the data model — hide that tile.
        if (!isCustomer) creditCol.visibility = View.GONE

        val (lastCol, lastVal) = tile(
            if (isCustomer) Loc.t(this, "Last Purchase", "\u0622\u062E\u0631\u06CC \u062E\u0631\u06CC\u062F\u0627\u0631\u06CC")
            else Loc.t(this, "Last Purchase (by you)", "\u0622\u062E\u0631\u06CC \u062E\u0631\u06CC\u062F\u0627\u0631\u06CC"),
            accent
        )
        statLastValue = lastVal
        lastVal.textSize = 13f
        card.addView(rowOf(lastCol))

        return card
    }

    /** Fills the stat grid from data [loadTransactions] already pulled from Room —
     * no separate DB hit. `bills` is every sale/purchase for this party (any status),
     * `payments` is every standalone payment, `creditLimit` is 0.0 for suppliers. */
    private fun updateDashboardStats(
        totalAmount: Double,
        totalPaidOnBills: Double,
        paymentsSum: Double,
        overdueAmount: Double,
        creditLimit: Double,
        lastActivityAt: Long?
    ) {
        statTotalValue.text = "Rs %.2f".format(totalAmount)
        statPaidValue.text = "Rs %.2f".format(totalPaidOnBills + paymentsSum)
        statOverdueValue.text = "Rs %.2f".format(overdueAmount)
        statCreditValue.text = if (isCustomer) {
            if (creditLimit > 0.0) "Rs %.2f".format(creditLimit)
            else Loc.t(this, "No Limit", "\u06A9\u0648\u0626\u06CC \u062D\u062F \u0646\u06C1\u06CC\u06BA")
        } else "-"
        val fmt = SimpleDateFormat("dd MMM yyyy", Locale.getDefault())
        statLastValue.text = if (lastActivityAt != null && lastActivityAt > 0L) fmt.format(Date(lastActivityAt))
            else Loc.t(this, "No activity yet", "\u0627\u0628\u06BE\u06CC \u062A\u06A9 \u06A9\u0648\u0626\u06CC \u0633\u0631\u06AF\u0631\u0645\u06CC \u0646\u06C1\u06CC\u06BA")
    }

    /** Builds a plain-text statement (header info + every bill/payment, oldest first)
     * and hands it to the system share sheet — same Intent.ACTION_SEND pattern already
     * used by shareReceipt()/shareSummary() elsewhere in the Party screens. */
    private fun shareStatement() {
        val fmt = SimpleDateFormat("dd MMM yyyy, hh:mm a", Locale.getDefault())
        val sb = StringBuilder()
        sb.append(partyName).append("\n")
        sb.append(if (isCustomer) Loc.t(this, "Customer Statement", "\u06A9\u0633\u0679\u0645\u0631 \u0633\u0679\u06CC\u0679\u0645\u0646\u0679")
            else Loc.t(this, "Supplier Statement", "\u0633\u067E\u0644\u0627\u0626\u0631 \u0633\u0679\u06CC\u0679\u0645\u0646\u0679")).append("\n")
        sb.append(Loc.t(this, "Outstanding", "\u0628\u0642\u0627\u06CC\u0627")).append(": ").append(closingValueText.text).append("\n")
        // NEW (Stuck Balance): make the Outstanding figure explainable on the shared statement.
        if (currentStuck != 0.0) {
            sb.append(Loc.t(this, "Daily Payable", "روزانہ واجب الادا")).append(": Rs %.2f".format(currentDaily)).append("\n")
            sb.append(Loc.t(this, "Stuck (Purana)", "اسٹک (پرانا)")).append(": Rs %.2f".format(currentStuck)).append("\n")
        }
        sb.append("----------------------------\n")
        allEntries.sortedBy { it.createdAt }.forEach { e ->
            sb.append(fmt.format(Date(e.createdAt))).append("  \u2014  ").append(e.searchText).append("\n")
        }
        val intent = Intent(Intent.ACTION_SEND).apply {
            type = "text/plain"
            putExtra(Intent.EXTRA_SUBJECT, "$partyName - Statement")
            putExtra(Intent.EXTRA_TEXT, sb.toString())
        }
        startActivity(Intent.createChooser(intent, null))
    }

    // ---------------- Billed Items (editable / deletable) ----------------
    // Shows the line items on ONE sale (by invoice) or purchase (by billNo). Each row can
    // be edited (qty/rate) or deleted, without opening the full Sale/PurchaseActivity edit
    // screen. Reloads itself after every change so totals/rows stay in sync, and reloads
    // the parent transaction list underneath once the dialog is dismissed.
    private fun showBilledItemsDialog(isSale: Boolean, invoice: String, billNo: String) {
        val reference = if (isSale) invoice else billNo
        var dialog: AlertDialog? = null

        fun rebuildAndShow() {
            lifecycleScope.launch {
                val db = PosDatabase.get(this@PartyTransactionActivity)
                val accent = if (isSale) green else orange

                // Bill may have been deleted entirely (last item removed) — bail out.
                val stillExists = if (isSale) db.saleDao().findSale(reference) != null
                else db.purchaseDao().findPurchase(reference) != null
                if (!stillExists) {
                    dialog?.dismiss()
                    loadTransactions()
                    return@launch
                }

                val sale = if (isSale) db.saleDao().findSale(reference) else null
                val purchase = if (!isSale) db.purchaseDao().findPurchase(reference) else null
                val total = sale?.total ?: purchase?.total ?: 0.0
                val status = sale?.status ?: purchase?.status ?: "active"
                val createdAt = sale?.createdAt ?: purchase?.createdAt ?: System.currentTimeMillis()
                val fmt = SimpleDateFormat("dd MMM yyyy, hh:mm a", Locale.getDefault())
                val dateText = fmt.format(Date(createdAt))

                val outer = LinearLayout(this@PartyTransactionActivity).apply { orientation = LinearLayout.VERTICAL }

                outer.addView(TextView(this@PartyTransactionActivity).apply {
                    text = if (isSale) Loc.t(this@PartyTransactionActivity, "Billed Items \u2014 Sale", "\u0628\u0644 \u0634\u062F\u06C1 \u0622\u0626\u0679\u0645\u0632 \u2014 \u0633\u06CC\u0644")
                    else Loc.t(this@PartyTransactionActivity, "Billed Items \u2014 Purchase", "\u0628\u0644 \u0634\u062F\u06C1 \u0622\u0626\u0679\u0645\u0632 \u2014 \u062E\u0631\u06CC\u062F\u0627\u0631\u06CC")
                    textSize = 16f
                    setTypeface(typeface, android.graphics.Typeface.BOLD)
                    setTextColor(Color.parseColor(textDark))
                    setPadding(24, 24, 24, 4)
                })
                outer.addView(TextView(this@PartyTransactionActivity).apply {
                    text = dateText + if (status == "returned") "  \u2022  " + Loc.t(this@PartyTransactionActivity, "Returned", "\u0648\u0627\u067E\u0633") else ""
                    textSize = 12f
                    setTextColor(Color.parseColor(if (status == "returned") red else labelGray))
                    setPadding(24, 0, 24, 12)
                })

                val body = LinearLayout(this@PartyTransactionActivity).apply {
                    orientation = LinearLayout.VERTICAL
                    setPadding(24, 0, 24, 12)
                }
                val scroll = ScrollView(this@PartyTransactionActivity).apply {
                    layoutParams = LinearLayout.LayoutParams(
                        LinearLayout.LayoutParams.MATCH_PARENT,
                        (400 * resources.displayMetrics.density).toInt()
                    )
                    addView(body)
                }
                outer.addView(scroll)

                var itemCount = 0

                if (isSale) {
                    val items = db.saleDao().itemsForInvoice(reference)
                    itemCount = items.size
                    if (items.isEmpty()) {
                        body.addView(emptyText(Loc.t(this@PartyTransactionActivity, "No items found", "\u06A9\u0648\u0626\u06CC \u0622\u0626\u0679\u0645 \u0646\u06C1\u06CC\u06BA \u0645\u0644\u0627")))
                    } else {
                        items.forEach { item ->
                            body.addView(billedItemRow(
                                productName = item.product,
                                qtyText = formatQty(item.qty),
                                amount = item.amount,
                                accent = accent,
                                onEdit = if (isAdmin()) ({ promptEditSaleItem(item, sale!!) { rebuildAndShow() } }) else null,
                                onDelete = if (isAdmin()) ({ confirmDeleteSaleItem(item, sale!!) { rebuildAndShow() } }) else null
                            ))
                        }
                    }
                } else {
                    val items = db.purchaseDao().itemsForBill(reference)
                    itemCount = items.size
                    if (items.isEmpty()) {
                        body.addView(emptyText(Loc.t(this@PartyTransactionActivity, "No items found", "\u06A9\u0648\u0626\u06CC \u0622\u0626\u0679\u0645 \u0646\u06C1\u06CC\u06BA \u0645\u0644\u0627")))
                    } else {
                        items.forEach { item ->
                            // FIX (item name "gayab" after sync): prefer the name
                            // snapshotted on this row; only fall back to the live
                            // product lookup for pre-migration rows.
                            val productName = item.itemName.ifBlank { db.productDao().find(item.barcode)?.name ?: item.barcode }
                            body.addView(billedItemRow(
                                productName = productName,
                                qtyText = formatQty(item.qty),
                                amount = item.amount,
                                accent = accent,
                                onEdit = if (isAdmin()) ({ promptEditPurchaseItem(item, purchase!!) { rebuildAndShow() } }) else null,
                                onDelete = if (isAdmin()) ({ confirmDeletePurchaseItem(item, purchase!!) { rebuildAndShow() } }) else null
                            ))
                        }
                    }
                }

                if (itemCount > 0) {
                    body.addView(View(this@PartyTransactionActivity).apply {
                        setBackgroundColor(Color.parseColor(cardBorder))
                        layoutParams = LinearLayout.LayoutParams(LinearLayout.LayoutParams.MATCH_PARENT, 2).apply {
                            setMargins(0, 8, 0, 8)
                        }
                    })
                    body.addView(LinearLayout(this@PartyTransactionActivity).apply {
                        orientation = LinearLayout.HORIZONTAL
                        setPadding(4, 6, 4, 6)
                        addView(TextView(this@PartyTransactionActivity).apply {
                            text = Loc.t(this@PartyTransactionActivity, "Total", "\u06A9\u0644")
                            textSize = 14f
                            setTypeface(typeface, android.graphics.Typeface.BOLD)
                            setTextColor(Color.parseColor(textDark))
                            layoutParams = LinearLayout.LayoutParams(0, LinearLayout.LayoutParams.WRAP_CONTENT, 1f)
                        })
                        addView(TextView(this@PartyTransactionActivity).apply {
                            text = "Rs %.2f".format(total)
                            textSize = 14f
                            gravity = Gravity.END
                            setTypeface(typeface, android.graphics.Typeface.BOLD)
                            setTextColor(Color.parseColor(accent))
                        })
                    })
                }

                dialog?.dismiss()
                dialog = AlertDialog.Builder(this@PartyTransactionActivity)
                    .setView(outer)
                    .setPositiveButton(Loc.t(this@PartyTransactionActivity, "Close", "\u0628\u0646\u062F \u06A9\u0631\u06CC\u06BA")) { _, _ ->
                        loadTransactions()
                    }
                    .setOnCancelListener { loadTransactions() }
                    .show()
            }
        }

        rebuildAndShow()
    }

    // ---------------- Sale item edit / delete ----------------

    private fun promptEditSaleItem(item: SaleItem, sale: com.grocerypos.v11.Sale, onDone: () -> Unit) {
        val (qtyInput, rateInput, container) = qtyRateEditDialogView(item.qty, item.unitPrice)
        AlertDialog.Builder(this)
            .setTitle(item.product)
            .setView(container)
            .setPositiveButton(Loc.t(this, "Save", "\u0645\u062D\u0641\u0648\u0638 \u06A9\u0631\u06CC\u06BA")) { _, _ ->
                val newQty = qtyInput.text.toString().toDoubleOrNull()
                val newRate = rateInput.text.toString().toDoubleOrNull()
                if (newQty == null || newQty <= 0 || newRate == null || newRate < 0) {
                    Toast.makeText(this, Loc.t(this, "Enter a valid qty and rate", "\u062F\u0631\u0633\u062A \u0645\u0642\u062F\u0627\u0631 \u0627\u0648\u0631 \u0631\u06CC\u0679 \u062F\u0631\u062C \u06A9\u0631\u06CC\u06BA"), Toast.LENGTH_SHORT).show()
                    return@setPositiveButton
                }
                applySaleItemEdit(item, sale, newQty, newRate, onDone)
            }
            .setNegativeButton(Loc.t(this, "Cancel", "\u0645\u0646\u0633\u0648\u062E \u06A9\u0631\u06CC\u06BA"), null)
            .show()
    }

    private fun applySaleItemEdit(item: SaleItem, sale: com.grocerypos.v11.Sale, newQty: Double, newRate: Double, onDone: () -> Unit) {
        lifecycleScope.launch {
            if (!requireAdminOrAbort()) return@launch
            val db = PosDatabase.get(this@PartyTransactionActivity)
            try {
                // FIX (#8 — dangerous editing pattern): the item row change, the parent
                // Sale total/paid change, the stock change, the customer-balance change
                // and the linked cash-transaction change are now all one Room
                // transaction. Previously these were separate sequential writes — if the
                // app crashed/got killed partway through (e.g. right after stock updated
                // but before the sale row was), the database was left inconsistent with
                // no way to recover. A failure now rolls back everything above, exactly
                // as SaleRepository.saveSale()/deleteSale() already do for the full-bill
                // edit/delete screens.
                db.withTransaction {
                    val product = db.productDao().find(item.barcode)
                    val oldQty = item.qty

                    // FIX (historical unit conversion bug): the OLD portion must be
                    // reversed using the factor that was actually in effect when this
                    // line was sold (item.conversionFactor via smallestQty()), not the
                    // product's CURRENT unit config — otherwise editing a product's unit
                    // ladder after the fact would silently reverse the wrong quantity.
                    // The NEW portion legitimately uses the CURRENT config, since it's a
                    // fresh decision being made right now. Net delta is what's actually
                    // applied to stock; the two are computed separately instead of a
                    // simple qty delta so a factor change between old and new can't
                    // silently corrupt the result either way.
                    // FIX (rate-only edit changed stock): the old and new smallest-unit
                    // quantities come from two different unit configs (frozen vs current),
                    // so even an edit that only changed the RATE could yield a non-zero
                    // "delta" (whenever the product's unit ladder was edited after this
                    // sale) and silently add/remove stock. If the qty itself is unchanged
                    // there is nothing to reconcile — leave stock and the frozen factor alone.
                    val qtyChanged = kotlin.math.abs(newQty - oldQty) > 1e-9
                    val oldSmallest = item.smallestQty(product)
                    val newSmallest = product?.toSmallestUnits(newQty, item.unit.ifBlank { product.unit }) ?: newQty
                    val netSmallestDelta = if (qtyChanged) newSmallest - oldSmallest else 0.0

                    // Stock: a sale decreases stock, so selling MORE (net positive) must
                    // decrease stock further; selling LESS gives stock back.
                    if (product != null && netSmallestDelta != 0.0) {
                        if (netSmallestDelta > 0) {
                            val rows = SyncQueueHelper.decreaseProductStock(db, item.barcode, netSmallestDelta, "SALE_EDIT", sale.invoice)
                            if (rows == 0) {
                                throw InsufficientStockException(Loc.t(this@PartyTransactionActivity, "Not enough stock", "\u0627\u0633\u0679\u0627\u06A9 \u06A9\u0645 \u06C1\u06D2"))
                            }
                        } else {
                            SyncQueueHelper.increaseProductStock(db, item.barcode, -netSmallestDelta, "SALE_EDIT", sale.invoice)
                        }
                    }

                    val perUnitCost = if (oldQty != 0.0) item.cost / oldQty else 0.0
                    val newAmount = newQty * newRate
                    val newCost = perUnitCost * newQty
                    val updatedItem = item.copy(
                        qty = newQty, unitPrice = newRate, amount = newAmount, cost = newCost,
                        // Re-stamp with the CURRENT factor — this line now reflects "now", same
                        // reasoning as newSmallest above.
                        conversionFactor = if (qtyChanged) (product?.smallestPerUnitOf(item.unit) ?: item.conversionFactor)
                            else item.conversionFactor
                    )
                    db.saleDao().updateItemRow(updatedItem)

                    val deltaAmount = newAmount - item.amount
                    val newTotal = sale.total + deltaAmount

                    // FIX (#9 — cash transaction consistency): if the bill's paid amount
                    // no longer fits under its new (possibly lower) total, cap it there
                    // and shrink the linked cash transaction by the same amount — instead
                    // of leaving "Paid" and Cash IN permanently stuck at the old total.
                    val newPaid = reconcilePaidAndCashRecords(db, sale.invoice, sale.paid, newTotal, isPurchase = false)

                    val updatedSale = sale.copy(
                        subtotal = sale.subtotal + deltaAmount,
                        total = newTotal,
                        paid = newPaid
                    )
                    db.saleDao().updateSale(updatedSale)

                    sale.customerId?.let { custId ->
                        // FIX (audit): the balance is total - paid. When `paid` had to be capped
                        // (bill got cheaper than what was already paid) the outstanding did NOT
                        // fall by the full deltaAmount — the shrunk `paid` must be added back or
                        // the customer ends up with a phantom credit on top of the cash refund.
                        SyncQueueHelper.adjustCustomerBalance(db, custId, deltaAmount + (sale.paid - newPaid))
                        db.customerDao().find(custId)?.let { c -> SyncQueueHelper.enqueueCustomer(db, c) }
                    }
                    if (product != null) {
                        db.productDao().find(item.barcode)?.let { p -> SyncQueueHelper.enqueueProduct(db, p) }
                    }
                    SyncQueueHelper.enqueueSale(db, updatedSale)
                }
                SyncQueueHelper.trigger(this@PartyTransactionActivity)

                onDone()
            } catch (e: InsufficientStockException) {
                Toast.makeText(this@PartyTransactionActivity, e.message, Toast.LENGTH_SHORT).show()
            } catch (e: Exception) {
                Toast.makeText(this@PartyTransactionActivity, "Could not update item: ${e.message ?: "unknown error"}", Toast.LENGTH_LONG).show()
            }
        }
    }

    private fun confirmDeleteSaleItem(item: SaleItem, sale: com.grocerypos.v11.Sale, onDone: () -> Unit) {
        AlertDialog.Builder(this)
            .setTitle(Loc.t(this, "Delete Item", "\u0622\u0626\u0679\u0645 \u0688\u06CC\u0644\u06CC\u0679 \u06A9\u0631\u06CC\u06BA"))
            .setMessage(item.product)
            .setPositiveButton(Loc.t(this, "Delete", "\u0688\u06CC\u0644\u06CC\u0679 \u06A9\u0631\u06CC\u06BA")) { _, _ -> applyDeleteSaleItem(item, sale, onDone) }
            .setNegativeButton(Loc.t(this, "Cancel", "\u0645\u0646\u0633\u0648\u062E \u06A9\u0631\u06CC\u06BA"), null)
            .show()
    }

    private fun applyDeleteSaleItem(item: SaleItem, sale: com.grocerypos.v11.Sale, onDone: () -> Unit) {
        lifecycleScope.launch {
            if (!requireAdminOrAbort()) return@launch
            val db = PosDatabase.get(this@PartyTransactionActivity)
            try {
                var deletedWholeSale = false
                // FIX (#8 — dangerous editing pattern): stock restore, item delete,
                // parent Sale update/delete, customer-balance change and the linked
                // cash-transaction change all now run as one Room transaction — see
                // applySaleItemEdit() above for why.
                db.withTransaction {
                    val product = db.productDao().find(item.barcode)

                    // Deleting a sold item gives the stock back — using the factor that
                    // was in effect when it was actually sold (see applySaleItemEdit above).
                    if (product != null) {
                        val deltaSmallest = item.smallestQty(product)
                        SyncQueueHelper.increaseProductStock(db, item.barcode, deltaSmallest, "SALE_ITEM_DELETE", sale.invoice)
                        db.productDao().find(item.barcode)?.let { p -> SyncQueueHelper.enqueueProduct(db, p) }
                    }

                    db.saleDao().deleteItemById(item.id)

                    val remaining = db.saleDao().itemCountForInvoice(sale.invoice)
                    if (remaining == 0) {
                        deletedWholeSale = true
                        db.saleDao().deleteSale(sale.invoice)
                        sale.customerId?.let { custId ->
                            // FIX (audit): only the OUTSTANDING part of the bill was ever on the
                            // customer's balance (total - paid). Subtracting the last item's full
                            // amount also removed the paid part => phantom credit.
                            // FIX (overpaid-bill → party balance gap): was `outstanding > 0.009`,
                            // so deleting the last item of an overpaid sale (outstanding negative —
                            // credited as an advance) never reversed that advance.
                            val outstanding = sale.total - sale.paid
                            if (kotlin.math.abs(outstanding) > 0.009) SyncQueueHelper.adjustCustomerBalance(db, custId, -outstanding)
                            db.customerDao().find(custId)?.let { c -> SyncQueueHelper.enqueueCustomer(db, c) }
                        }
                        // FIX (#9 — cash transaction consistency): the whole sale is
                        // gone now, so its linked cash transaction must go with it —
                        // previously only db.saleDao().deleteSale() ran here, leaving a
                        // stale Cash IN entry behind forever (mirrors what
                        // SaleRepository.deleteSale() already does for the full-bill
                        // delete screen).
                        // FIX (deleted-payment-survives-sync bug — see RoomPurchaseRepository.
                        // deletePurchase()'s matching comment): raw deleteByReference() never
                        // enqueued the removal, so it never reached other devices/Firestore.
                        SyncQueueHelper.deleteCashTransactionsByReference(db, sale.invoice)
                        SyncQueueHelper.voidLinkedPayments(db, sale.invoice, null, "")
                        SyncQueueHelper.enqueueDelete(db, "sale", SyncQueueHelper.saleEntityId(sale))
                    } else {
                        val newTotal = sale.total - item.amount
                        val newPaid = reconcilePaidAndCashRecords(db, sale.invoice, sale.paid, newTotal, isPurchase = false)
                        val updatedSale = sale.copy(
                            subtotal = sale.subtotal - item.amount,
                            total = newTotal,
                            paid = newPaid
                        )
                        db.saleDao().updateSale(updatedSale)
                        sale.customerId?.let { custId ->
                            // FIX (audit): outstanding change = -item.amount + (paid that got capped).
                            SyncQueueHelper.adjustCustomerBalance(db, custId, -item.amount + (sale.paid - newPaid))
                            db.customerDao().find(custId)?.let { c -> SyncQueueHelper.enqueueCustomer(db, c) }
                        }
                        SyncQueueHelper.enqueueSale(db, updatedSale)
                    }
                }
                SyncQueueHelper.trigger(this@PartyTransactionActivity)

                if (deletedWholeSale) {
                    Toast.makeText(this@PartyTransactionActivity, Loc.t(this@PartyTransactionActivity, "Sale deleted", "\u0633\u06CC\u0644 \u0688\u06CC\u0644\u06CC\u0679 \u06C1\u0648 \u06AF\u0626\u06CC"), Toast.LENGTH_SHORT).show()
                }

                onDone()
            } catch (e: Exception) {
                Toast.makeText(this@PartyTransactionActivity, "Could not delete item: ${e.message ?: "unknown error"}", Toast.LENGTH_LONG).show()
            }
        }
    }

    // ---------------- Purchase item edit / delete ----------------

    private fun promptEditPurchaseItem(item: PurchaseItem, purchase: com.grocerypos.v11.Purchase, onDone: () -> Unit) {
        val (qtyInput, rateInput, container) = qtyRateEditDialogView(item.qty, item.unitCost)
        lifecycleScope.launch {
            val db = PosDatabase.get(this@PartyTransactionActivity)
            // FIX (item name "gayab" after sync): prefer the name snapshotted on this
            // row; only fall back to the live product lookup for pre-migration rows.
            val name = item.itemName.ifBlank { db.productDao().find(item.barcode)?.name ?: item.barcode }
            AlertDialog.Builder(this@PartyTransactionActivity)
                .setTitle(name)
                .setView(container)
                .setPositiveButton(Loc.t(this@PartyTransactionActivity, "Save", "\u0645\u062D\u0641\u0648\u0638 \u06A9\u0631\u06CC\u06BA")) { _, _ ->
                    val newQty = qtyInput.text.toString().toDoubleOrNull()
                    val newRate = rateInput.text.toString().toDoubleOrNull()
                    if (newQty == null || newQty <= 0 || newRate == null || newRate < 0) {
                        Toast.makeText(this@PartyTransactionActivity, Loc.t(this@PartyTransactionActivity, "Enter a valid qty and rate", "\u062F\u0631\u0633\u062A \u0645\u0642\u062F\u0627\u0631 \u0627\u0648\u0631 \u0631\u06CC\u0679 \u062F\u0631\u062C \u06A9\u0631\u06CC\u06BA"), Toast.LENGTH_SHORT).show()
                        return@setPositiveButton
                    }
                    applyPurchaseItemEdit(item, purchase, newQty, newRate, onDone)
                }
                .setNegativeButton(Loc.t(this@PartyTransactionActivity, "Cancel", "\u0645\u0646\u0633\u0648\u062E \u06A9\u0631\u06CC\u06BA"), null)
                .show()
        }
    }

    private fun applyPurchaseItemEdit(item: PurchaseItem, purchase: com.grocerypos.v11.Purchase, newQty: Double, newRate: Double, onDone: () -> Unit) {
        lifecycleScope.launch {
            if (!requireAdminOrAbort()) return@launch
            val db = PosDatabase.get(this@PartyTransactionActivity)
            try {
                // FIX (#8 — dangerous editing pattern): the item row change, the parent
                // Purchase total/paid change, the stock+cost change, the supplier-balance
                // change and the linked payment/cash-transaction change all now run as
                // one Room transaction — see applySaleItemEdit() above for why.
                db.withTransaction {
                    val product = db.productDao().find(item.barcode)
                    val oldQty = item.qty

                    // FIX (historical unit conversion bug): same reasoning as
                    // applySaleItemEdit() above — reverse the OLD portion using the
                    // factor frozen at purchase time, apply the NEW portion using the
                    // CURRENT product config, and only touch stock with the net delta.
                    // FIX (rate-only edit changed stock): see applySaleItemEdit() — with the
                    // qty unchanged, the "new" quantity IS the old one, so stock cannot move
                    // (frozen vs current unit config used to fake a delta after a ladder
                    // change). The cost below is still recomputed for the new rate.
                    val qtyChanged = kotlin.math.abs(newQty - oldQty) > 1e-9
                    val oldSmallest = item.smallestQty(product)
                    val newSmallest = if (!qtyChanged) oldSmallest
                        else product?.toSmallestUnits(newQty, item.unit.ifBlank { product.unit }) ?: newQty
                    val netSmallestDelta = newSmallest - oldSmallest
                    val newAmount = newQty * newRate

                    // FIX (#7 — purchase costing): this path used to only touch stock and
                    // never product.cost at all, so editing a purchase item's qty/rate here
                    // silently left the product's weighted-average cost stale — worse than
                    // PurchaseRepository's own reversal method (used by the full
                    // PurchaseActivity edit screen), which at least recomputes it. Now
                    // mirrors that same reversal-then-reapply approach: first remove this
                    // line's OLD contribution from the current average (reversePurchaseLineCost,
                    // using the factor/amount frozen at purchase time), then blend in the
                    // NEW line's contribution as a fresh weighted-average purchase
                    // (addPurchaseLineCost) — same math PurchaseRepository.savePurchase()
                    // uses for a brand-new line, applied here to just the one edited line
                    // instead of the whole bill.
                    if (product != null) {
                        // FIX (#7 — purchase costing safety): same guard as
                        // PurchaseRepository.reverseStockAndCostForItems() — if this
                        // line's own purchased quantity has already been drawn down
                        // below what's currently in stock (by a sale or another
                        // transaction since), reversing its cost contribution here
                        // would produce a wrong/zero cost instead of a real error.
                        // Refuse the edit rather than silently corrupting it.
                        if (oldSmallest > product.stock) {
                            throw InsufficientStockException(
                                Loc.t(this@PartyTransactionActivity,
                                    "Cannot edit: this item's stock has already been used elsewhere. Use a stock adjustment instead.",
                                    "\u0627\u06CC\u0688\u0679 \u0646\u06C1\u06CC\u06BA \u06C1\u0648 \u0633\u06A9\u062A\u0627: \u0627\u0633 \u0622\u0626\u0679\u0645 \u06A9\u0627 \u0627\u0633\u0679\u0627\u06A9 \u067E\u06C1\u0644\u06D2 \u06C1\u06CC \u06A9\u06C1\u06CC\u06BA \u0627\u0648\u0631 \u0627\u0633\u062A\u0639\u0645\u0627\u0644 \u06C1\u0648 \u0686\u06A9\u0627 \u06C1\u06D2\u06D4 \u0628\u062C\u0627\u0626\u06D2 \u0627\u0633 \u06A9\u06D2 \u0633\u0679\u0627\u06A9 \u0627\u06CC\u0688\u062C\u0633\u0679 \u0645\u0646\u0679 \u0627\u0633\u062A\u0639\u0645\u0627\u0644 \u06A9\u0631\u06CC\u06BA\u06D4")
                            )
                        }
                        val costAfterReversal = reversePurchaseLineCost(product, item, oldSmallest)
                        val stockAfterReversal = product.stock - oldSmallest
                        val productAfterReversal = product.copy(stock = stockAfterReversal, cost = costAfterReversal)
                        val finalCost = if (newSmallest > 0) {
                            addPurchaseLineCost(productAfterReversal, newSmallest, newAmount)
                        } else {
                            costAfterReversal
                        }

                        // Stock: a purchase increases stock, so buying MORE (net positive)
                        // adds more stock; buying less must remove stock (fails if already
                        // sold/used).
                        if (netSmallestDelta > 0) {
                            SyncQueueHelper.increaseProductStock(db, item.barcode, netSmallestDelta, "PURCHASE_EDIT", purchase.billNo, finalCost)
                        } else if (netSmallestDelta < 0) {
                            val rows = SyncQueueHelper.decreaseProductStock(db, item.barcode, -netSmallestDelta, "PURCHASE_EDIT", purchase.billNo, finalCost)
                            if (rows == 0) {
                                throw InsufficientStockException(Loc.t(this@PartyTransactionActivity, "Not enough stock to reduce", "\u06A9\u0645 \u06A9\u0631\u0646\u06D2 \u06A9\u06D2 \u0644\u06CC\u06D2 \u0627\u0633\u0679\u0627\u06A9 \u06A9\u0645 \u06C1\u06D2"))
                            }
                        }
                        SyncQueueHelper.updateProductCost(db, item.barcode, finalCost)
                    }

                    val updatedItem = item.copy(
                        qty = newQty, unitCost = newRate, amount = newAmount,
                        conversionFactor = if (qtyChanged) (product?.smallestPerUnitOf(item.unit) ?: item.conversionFactor)
                            else item.conversionFactor
                    )
                    db.purchaseDao().updateItemRow(updatedItem)

                    val deltaAmount = newAmount - item.amount
                    val newTotal = purchase.total + deltaAmount

                    // FIX (#9 — cash transaction consistency): cap "paid" at the new
                    // total and shrink the linked payment + cash transaction by the same
                    // amount if it no longer fits — see applySaleItemEdit() above.
                    val newPaid = reconcilePaidAndCashRecords(db, purchase.billNo, purchase.paid, newTotal, isPurchase = true)

                    val updatedPurchase = purchase.copy(
                        subtotal = purchase.subtotal + deltaAmount,
                        total = newTotal,
                        paid = newPaid
                    )
                    db.purchaseDao().updatePurchase(updatedPurchase)

                    purchase.supplierId?.let { supId ->
                        // FIX (audit): see applySaleItemEdit() — add back the capped `paid`.
                        SyncQueueHelper.adjustSupplierBalance(db, supId, deltaAmount + (purchase.paid - newPaid))
                        db.supplierDao().find(supId)?.let { s -> SyncQueueHelper.enqueueSupplier(db, s) }
                    }
                    if (product != null) {
                        db.productDao().find(item.barcode)?.let { p -> SyncQueueHelper.enqueueProduct(db, p) }
                    }
                    SyncQueueHelper.enqueuePurchase(db, updatedPurchase)
                }
                SyncQueueHelper.trigger(this@PartyTransactionActivity)

                onDone()
            } catch (e: InsufficientStockException) {
                Toast.makeText(this@PartyTransactionActivity, e.message, Toast.LENGTH_SHORT).show()
            } catch (e: Exception) {
                Toast.makeText(this@PartyTransactionActivity, "Could not update item: ${e.message ?: "unknown error"}", Toast.LENGTH_LONG).show()
            }
        }
    }

    private fun confirmDeletePurchaseItem(item: PurchaseItem, purchase: com.grocerypos.v11.Purchase, onDone: () -> Unit) {
        lifecycleScope.launch {
            val db = PosDatabase.get(this@PartyTransactionActivity)
            // FIX (item name "gayab" after sync): prefer the name snapshotted on this
            // row; only fall back to the live product lookup for pre-migration rows.
            val name = item.itemName.ifBlank { db.productDao().find(item.barcode)?.name ?: item.barcode }
            AlertDialog.Builder(this@PartyTransactionActivity)
                .setTitle(Loc.t(this@PartyTransactionActivity, "Delete Item", "\u0622\u0626\u0679\u0645 \u0688\u06CC\u0644\u06CC\u0679 \u06A9\u0631\u06CC\u06BA"))
                .setMessage(name)
                .setPositiveButton(Loc.t(this@PartyTransactionActivity, "Delete", "\u0688\u06CC\u0644\u06CC\u0679 \u06A9\u0631\u06CC\u06BA")) { _, _ -> applyDeletePurchaseItem(item, purchase, onDone) }
                .setNegativeButton(Loc.t(this@PartyTransactionActivity, "Cancel", "\u0645\u0646\u0633\u0648\u062E \u06A9\u0631\u06CC\u06BA"), null)
                .show()
        }
    }

    private fun applyDeletePurchaseItem(item: PurchaseItem, purchase: com.grocerypos.v11.Purchase, onDone: () -> Unit) {
        lifecycleScope.launch {
            if (!requireAdminOrAbort()) return@launch
            val db = PosDatabase.get(this@PartyTransactionActivity)
            try {
                var deletedWholePurchase = false
                // FIX (#8 — dangerous editing pattern): stock+cost reversal, item
                // delete, parent Purchase update/delete, supplier-balance change and
                // the linked payment/cash-transaction change all now run as one Room
                // transaction — see applySaleItemEdit() above for why.
                db.withTransaction {
                    val product = db.productDao().find(item.barcode)

                    // Deleting a purchased item removes the stock it had added — using
                    // the factor that was in effect when it was actually purchased (see
                    // applyPurchaseItemEdit above) — fails if that stock has already been
                    // sold/used elsewhere.
                    if (product != null) {
                        val deltaSmallest = item.smallestQty(product)
                        // FIX (#7 — purchase costing): deleting a purchase line here used
                        // to only touch stock and never recompute product.cost at all —
                        // now removes this line's contribution from the weighted-average
                        // cost too, same as reversePurchaseLineCost()/PurchaseRepository's
                        // full-bill delete. Computed BEFORE the stock decrease below so the
                        // stock_movements row logged by decreaseProductStock() can carry
                        // this same already-known cost instead of a stale pre-reversal one.
                        val newCost = reversePurchaseLineCost(product, item, deltaSmallest)
                        val rows = SyncQueueHelper.decreaseProductStock(db, item.barcode, deltaSmallest, "PURCHASE_ITEM_DELETE", purchase.billNo, newCost)
                        if (rows == 0) {
                            throw InsufficientStockException(Loc.t(this@PartyTransactionActivity, "Cannot delete: stock already used", "ڈیلیٹ نہیں ہو سکتا: اسٹاک پہلے ہی استعمال ہو چکا"))
                        }
                        SyncQueueHelper.updateProductCost(db, item.barcode, newCost)
                        db.productDao().find(item.barcode)?.let { p -> SyncQueueHelper.enqueueProduct(db, p) }
                    }

                    db.purchaseDao().deleteItemById(item.id)

                    val remaining = db.purchaseDao().itemCountForBill(purchase.billNo)
                    if (remaining == 0) {
                        deletedWholePurchase = true
                        db.purchaseDao().deletePurchase(purchase.billNo)
                        purchase.supplierId?.let { supId ->
                            // FIX (audit): only total - paid was ever on the supplier's balance.
                            // FIX (overpaid-bill → party balance gap): was `outstanding > 0.009`,
                            // so deleting the last item of an overpaid purchase (outstanding
                            // negative — credited as an advance) never reversed that advance.
                            val outstanding = purchase.total - purchase.paid
                            if (kotlin.math.abs(outstanding) > 0.009) SyncQueueHelper.adjustSupplierBalance(db, supId, -outstanding)
                            db.supplierDao().find(supId)?.let { s -> SyncQueueHelper.enqueueSupplier(db, s) }
                        }
                        // FIX (#9 — cash transaction consistency): the whole purchase is
                        // gone now, so its linked payment and cash transaction must go
                        // with it — previously only db.purchaseDao().deletePurchase() ran
                        // here, leaving stale Payment/Cash OUT entries behind forever.
                        // FIX (deleted-payment-survives-sync bug): raw deleteByReference()
                        // calls delete the rows locally but never enqueue a matching sync
                        // delete (see RoomPurchaseRepository.deletePurchase()'s matching
                        // comment) — the very bug this comment claimed was already handled
                        // there, but wasn't. Using the safe helpers actually closes it.
                        SyncQueueHelper.deletePaymentsByReference(db, purchase.billNo)
                        SyncQueueHelper.deleteCashTransactionsByReference(db, purchase.billNo)
                        SyncQueueHelper.voidLinkedPayments(db, purchase.billNo, null, "")
                        SyncQueueHelper.enqueueDelete(db, "purchase", SyncQueueHelper.purchaseEntityId(purchase))
                    } else {
                        val newTotal = purchase.total - item.amount
                        val newPaid = reconcilePaidAndCashRecords(db, purchase.billNo, purchase.paid, newTotal, isPurchase = true)
                        val updatedPurchase = purchase.copy(
                            subtotal = purchase.subtotal - item.amount,
                            total = newTotal,
                            paid = newPaid
                        )
                        db.purchaseDao().updatePurchase(updatedPurchase)
                        purchase.supplierId?.let { supId ->
                            // FIX (audit): outstanding change = -item.amount + (paid that got capped).
                            SyncQueueHelper.adjustSupplierBalance(db, supId, -item.amount + (purchase.paid - newPaid))
                            db.supplierDao().find(supId)?.let { s -> SyncQueueHelper.enqueueSupplier(db, s) }
                        }
                        SyncQueueHelper.enqueuePurchase(db, updatedPurchase)
                    }
                }
                SyncQueueHelper.trigger(this@PartyTransactionActivity)

                if (deletedWholePurchase) {
                    Toast.makeText(this@PartyTransactionActivity, Loc.t(this@PartyTransactionActivity, "Purchase deleted", "خریداری ڈیلیٹ ہو گئی"), Toast.LENGTH_SHORT).show()
                }

                onDone()
            } catch (e: InsufficientStockException) {
                Toast.makeText(this@PartyTransactionActivity, e.message, Toast.LENGTH_LONG).show()
            } catch (e: Exception) {
                Toast.makeText(this@PartyTransactionActivity, "Could not delete item: ${e.message ?: "unknown error"}", Toast.LENGTH_LONG).show()
            }
        }
    }

    // ---------------- Cost / cash-record helpers (FIX #7, #9) ----------------

    /** FIX (#9 — cash transaction consistency): a billed-item edit/delete changes the
     * parent bill's total. If the bill's existing `paid` amount no longer fits under
     * the new total (paid > new total — e.g. a fully-paid bill that just got smaller),
     * cap paid at the new total and shrink the ONE cash transaction (and, for a
     * purchase, the ONE payment record) tied to this bill's reference by the same
     * amount — instead of leaving Cash Report / Day Book / payment totals silently
     * stuck at the old, now-wrong figure. Growing a bill's total never auto-increases
     * `paid` — that would fabricate a payment nobody actually made — so this only ever
     * moves `paid` down, never up. Returns the (possibly capped) paid amount to store
     * back on the parent Sale/Purchase. */
    private suspend fun reconcilePaidAndCashRecords(
        db: PosDatabase,
        reference: String,
        oldPaid: Double,
        newTotal: Double,
        isPurchase: Boolean
    ): Double {
        val newPaid = oldPaid.coerceIn(0.0, newTotal.coerceAtLeast(0.0))
        val paidDelta = newPaid - oldPaid
        if (paidDelta == 0.0) return newPaid

        // FIX (audit — inconsistent with returns): this used to SHRINK the original cash row in
        // place, silently rewriting the original day's cash book (and any already-closed Cash
        // Register day now showed a phantom shortage). The excess the bill no longer owes is
        // money handed back today, so record it as a dated reversal exactly like a return does
        // (SyncQueueHelper.reverseCashByReference); the original day stays untouched.

        suspend fun reducePaymentRecords(amountToRemove: Double) {
            if (amountToRemove <= 0.0) return
            var remaining = amountToRemove
            val rows = db.paymentDao().allByReference(reference)
                .sortedByDescending { it.createdAt }
            for (pay in rows) {
                if (remaining <= 0.0) break
                val reduction = minOf(remaining, pay.amount.coerceAtLeast(0.0))
                if (reduction <= 0.0) continue
                val updatedPay = pay.copy(
                    amount = (pay.amount - reduction).coerceAtLeast(0.0),
                    updatedAt = System.currentTimeMillis(),
                    dirty = true
                )
                db.paymentDao().update(updatedPay)
                SyncQueueHelper.enqueuePayment(db, updatedPay)
                remaining -= reduction
            }
        }

        if (paidDelta < 0.0) {
            val reduction = -paidDelta
            SyncQueueHelper.reverseCashByReference(
                db, reference, reduction,
                if (isPurchase) "IN" else "OUT",
                if (isPurchase) "Purchase Adjustment" else "Sale Adjustment"
            )
            if (isPurchase) reducePaymentRecords(reduction)
        }
        return newPaid
    }

    /** FIX (#7 — purchase costing): removes ONE purchase line's contribution from
     * [product]'s current weighted-average cost — the same math
     * PurchaseRepository.reverseStockAndCostForItems() uses for a full-bill delete,
     * applied here to a single line so PartyTransactionActivity's item-level
     * edit/delete stays consistent with it instead of silently leaving cost stale
     * (which is what this screen used to do before this fix). [smallestQtyToRemove]
     * must already be expressed in the SAME smallest-unit terms as [item]'s frozen
     * conversionFactor (see PurchaseItem.smallestQty()), not the product's current
     * unit config. */
    private fun reversePurchaseLineCost(product: Product, item: PurchaseItem, smallestQtyToRemove: Double): Double {
        if (smallestQtyToRemove <= 0) return product.cost
        val factor = product.smallestUnitFactor()
        val currentCostPerSmallest = if (factor > 0) product.cost / factor else product.cost
        val currentStock = product.stock
        val newStock = currentStock - smallestQtyToRemove
        val totalValueBefore = currentStock * currentCostPerSmallest
        val totalValueAfterRemoval = (totalValueBefore - item.amount).coerceAtLeast(0.0)
        val newCostPerSmallest = if (newStock > 0) totalValueAfterRemoval / newStock else 0.0
        return newCostPerSmallest * factor
    }

    /** FIX (#7 — purchase costing): blends ONE new/edited purchase line into
     * [product]'s weighted-average cost — the same math
     * PurchaseRepository.savePurchase() uses when adding a brand-new line, applied
     * here to a single edited line. [product] must reflect the stock/cost state
     * immediately BEFORE this line is added (i.e. after any prior reversal via
     * [reversePurchaseLineCost] for an edit). */
    private fun addPurchaseLineCost(product: Product, addedSmallestQty: Double, lineAmount: Double): Double {
        if (addedSmallestQty <= 0) return product.cost
        val factor = product.smallestUnitFactor()
        val oldStockSmallest = product.stock
        val oldCostPerSmallest = if (factor > 0) product.cost / factor else product.cost
        val purchaseRatePerSmallest = lineAmount / addedSmallestQty
        val newCostPerSmallest = if (oldStockSmallest <= 0) purchaseRatePerSmallest
            else ((oldStockSmallest * oldCostPerSmallest) + (addedSmallestQty * purchaseRatePerSmallest)) / (oldStockSmallest + addedSmallestQty)
        return newCostPerSmallest * factor
    }

    // ---------------- Shared small UI builders ----------------

    /** Small qty + rate edit form used by both the sale-item and purchase-item edit dialogs. */
    private fun qtyRateEditDialogView(qty: Double, rate: Double): Triple<EditText, EditText, LinearLayout> {
        val qtyInput = EditText(this).apply {
            inputType = InputType.TYPE_CLASS_NUMBER or InputType.TYPE_NUMBER_FLAG_DECIMAL
            hint = Loc.t(this@PartyTransactionActivity, "Quantity", "\u0645\u0642\u062F\u0627\u0631")
            setText(formatQty(qty))
        }
        val rateInput = EditText(this).apply {
            inputType = InputType.TYPE_CLASS_NUMBER or InputType.TYPE_NUMBER_FLAG_DECIMAL
            hint = Loc.t(this@PartyTransactionActivity, "Rate", "\u0631\u06CC\u0679")
            setText(formatQty(rate))
        }
        val container = LinearLayout(this).apply {
            orientation = LinearLayout.VERTICAL
            setPadding(48, 16, 48, 0)
            addView(qtyInput)
            addView(View(this@PartyTransactionActivity).apply {
                layoutParams = LinearLayout.LayoutParams(LinearLayout.LayoutParams.MATCH_PARENT, 20)
            })
            addView(rateInput)
        }
        return Triple(qtyInput, rateInput, container)
    }

    private fun billedItemRow(
        productName: String,
        qtyText: String,
        amount: Double,
        accent: String,
        onEdit: (() -> Unit)?,
        onDelete: (() -> Unit)?
    ): LinearLayout {
        return LinearLayout(this).apply {
            orientation = LinearLayout.HORIZONTAL
            gravity = Gravity.CENTER_VERTICAL
            setPadding(4, 8, 4, 8)
            addView(LinearLayout(this@PartyTransactionActivity).apply {
                orientation = LinearLayout.VERTICAL
                layoutParams = LinearLayout.LayoutParams(0, LinearLayout.LayoutParams.WRAP_CONTENT, 1f)
                addView(TextView(this@PartyTransactionActivity).apply {
                    text = productName
                    textSize = 13.5f
                    setTextColor(Color.parseColor(textDark))
                    setTypeface(typeface, android.graphics.Typeface.BOLD)
                })
                addView(TextView(this@PartyTransactionActivity).apply {
                    text = Loc.t(this@PartyTransactionActivity, "Qty", "\u0645\u0642\u062F\u0627\u0631") + ": $qtyText"
                    textSize = 11.5f
                    setTextColor(Color.parseColor(labelGray))
                })
            })
            addView(TextView(this@PartyTransactionActivity).apply {
                text = "Rs %.2f".format(amount)
                textSize = 13.5f
                gravity = Gravity.END
                setTypeface(typeface, android.graphics.Typeface.BOLD)
                setTextColor(Color.parseColor(accent))
                setPadding(0, 0, 20, 0)
            })
            // NEW (P1 security): edit/delete icons are Admin-only — non-admin sees
            // just the plain row with no action affordance at all.
            if (onEdit != null) {
                addView(ImageView(this@PartyTransactionActivity).apply {
                    setImageDrawable(tintedDrawable(R.drawable.ic_edit, textDark, 15))
                    setPadding(14, 0, 14, 0)
                    setOnClickListener { onEdit() }
                })
            }
            if (onDelete != null) {
                addView(ImageView(this@PartyTransactionActivity).apply {
                    setImageDrawable(tintedDrawable(R.drawable.ic_delete, red, 15))
                    setPadding(6, 0, 0, 0)
                    setOnClickListener { onDelete() }
                })
            }
        }
    }

    // ---- REMOVED (code maintainability — DRY): formatQty() shared via
    // com.grocerypos.v11.ui.components (see UiHelpers.kt) — imported above.

    private fun row(amount: Double, dateText: String, typeLabel: String, status: String, accent: String, iconRes: Int, onClick: () -> Unit): LinearLayout {
        return LinearLayout(this).apply {
            orientation = LinearLayout.HORIZONTAL
            gravity = Gravity.CENTER_VERTICAL
            setPadding(18, 14, 18, 14)
            background = GradientDrawable().apply {
                setColor(Color.parseColor(cardWhite))
                cornerRadius = 16f
                setStroke(1, Color.parseColor(cardBorder))
            }
            elevation = 2f
            layoutParams = LinearLayout.LayoutParams(
                LinearLayout.LayoutParams.MATCH_PARENT, LinearLayout.LayoutParams.WRAP_CONTENT
            ).apply { setMargins(0, 0, 0, 10) }
            isClickable = true
            setOnClickListener { onClick() }

            addView(iconBadge(iconRes, accent, sizeDp = 38, iconSizeDp = 17))

            val infoCol = LinearLayout(this@PartyTransactionActivity).apply {
                orientation = LinearLayout.VERTICAL
                setPadding(16, 0, 12, 0)
                layoutParams = LinearLayout.LayoutParams(0, LinearLayout.LayoutParams.WRAP_CONTENT, 1f)
            }
            infoCol.addView(TextView(this@PartyTransactionActivity).apply {
                text = dateText
                textSize = 13.5f
                setTypeface(typeface, android.graphics.Typeface.BOLD)
                setTextColor(Color.parseColor(textDark))
            })
            infoCol.addView(TextView(this@PartyTransactionActivity).apply {
                text = typeLabel + if (status == "returned") "  \u2022  " + Loc.t(this@PartyTransactionActivity, "Returned", "\u0648\u0627\u067E\u0633") else ""
                textSize = 11f
                setTextColor(Color.parseColor(if (status == "returned") red else labelGray))
            })
            addView(infoCol)

            addView(TextView(this@PartyTransactionActivity).apply {
                text = "Rs %.2f".format(amount)
                textSize = 14f
                setTypeface(typeface, android.graphics.Typeface.BOLD)
                setTextColor(Color.parseColor(accent))
            })
        }
    }

    /** ---- IMPROVEMENT PACK (Payments 10/10): dedicated row for payment entries,
     * with Edit/Delete/Share actions — unlike bill rows (still handled by row()
     * above), a payment previously had no way to be corrected or reshared once
     * saved. Visual shape (icon circle + info column + amount) matches row() so
     * the merged feed still reads as one consistent list. */
    private fun paymentRow(payment: Payment, dateText: String, typeLabel: String): LinearLayout {
        return LinearLayout(this).apply {
            orientation = LinearLayout.VERTICAL
            setPadding(18, 14, 18, 10)
            background = GradientDrawable().apply {
                setColor(Color.parseColor(cardWhite))
                cornerRadius = 16f
                setStroke(1, Color.parseColor(cardBorder))
            }
            elevation = 2f
            layoutParams = LinearLayout.LayoutParams(
                LinearLayout.LayoutParams.MATCH_PARENT, LinearLayout.LayoutParams.WRAP_CONTENT
            ).apply { setMargins(0, 0, 0, 10) }

            val topRow = LinearLayout(this@PartyTransactionActivity).apply {
                orientation = LinearLayout.HORIZONTAL
                gravity = Gravity.CENTER_VERTICAL
            }
            topRow.addView(iconBadge(R.drawable.ic_wallet, teal, sizeDp = 38, iconSizeDp = 17))
            val infoCol = LinearLayout(this@PartyTransactionActivity).apply {
                orientation = LinearLayout.VERTICAL
                setPadding(16, 0, 12, 0)
                layoutParams = LinearLayout.LayoutParams(0, LinearLayout.LayoutParams.WRAP_CONTENT, 1f)
            }
            infoCol.addView(TextView(this@PartyTransactionActivity).apply {
                text = dateText
                textSize = 13.5f
                setTypeface(typeface, android.graphics.Typeface.BOLD)
                setTextColor(Color.parseColor(textDark))
            })
            infoCol.addView(TextView(this@PartyTransactionActivity).apply {
                text = typeLabel
                textSize = 11f
                setTextColor(Color.parseColor(labelGray))
            })
            topRow.addView(infoCol)
            topRow.addView(TextView(this@PartyTransactionActivity).apply {
                text = "Rs %.2f".format(payment.amount)
                textSize = 14f
                setTypeface(typeface, android.graphics.Typeface.BOLD)
                setTextColor(Color.parseColor(teal))
            })
            addView(topRow)

            fun chip(iconRes: Int, label: String, colorHex: String, onTap: () -> Unit): LinearLayout =
                LinearLayout(this@PartyTransactionActivity).apply {
                    orientation = LinearLayout.HORIZONTAL
                    gravity = Gravity.CENTER
                    setPadding(20, 12, 20, 12)
                    background = GradientDrawable().apply {
                        setColor(Color.parseColor("#F7F8FC"))
                        cornerRadius = 20f
                    }
                    val lp = LinearLayout.LayoutParams(0, LinearLayout.LayoutParams.WRAP_CONTENT, 1f)
                    lp.marginEnd = 8
                    layoutParams = lp
                    isClickable = true
                    setOnClickListener { onTap() }
                    addView(ImageView(this@PartyTransactionActivity).apply {
                        setImageDrawable(tintedDrawable(iconRes, colorHex, 13))
                    })
                    addView(TextView(this@PartyTransactionActivity).apply {
                        text = "  $label"
                        textSize = 11.5f
                        setTypeface(typeface, android.graphics.Typeface.BOLD)
                        setTextColor(Color.parseColor(colorHex))
                    })
                }

            val actionRow = LinearLayout(this@PartyTransactionActivity).apply {
                orientation = LinearLayout.HORIZONTAL
                setPadding(0, 10, 0, 0)
            }
            // NEW (P1 security): editing/deleting an existing payment adjusts the
            // party's balance — Admin-only, matching Billed Items above. Share stays
            // available to everyone since it doesn't touch any data.
            if (isAdmin()) {
                actionRow.addView(chip(R.drawable.ic_edit, Loc.t(this@PartyTransactionActivity, "Edit", "\u062A\u0631\u0645\u06CC\u0645"), textDark) { showPaymentDialog(existing = payment) })
            }
            actionRow.addView(chip(R.drawable.ic_send, Loc.t(this@PartyTransactionActivity, "Share", "\u0634\u06CC\u0626\u0631"), teal) {
                shareReceipt(payment.amount, payment.method, payment.note, payment.createdAt, payment.billReference)
            })
            if (isAdmin()) {
                actionRow.addView(chip(R.drawable.ic_delete, Loc.t(this@PartyTransactionActivity, "Delete", "\u062D\u0630\u0641"), red) { confirmDeletePayment(payment) })
            }
            (actionRow.getChildAt(actionRow.childCount - 1) as LinearLayout).layoutParams = (actionRow.getChildAt(actionRow.childCount - 1).layoutParams as LinearLayout.LayoutParams).apply { marginEnd = 0 }
            addView(actionRow)
        }
    }


    private fun placeholderCard(text: String) = LinearLayout(this).apply {
        orientation = LinearLayout.VERTICAL
        gravity = Gravity.CENTER
        setPadding(20, 30, 20, 30)
        background = GradientDrawable().apply {
            setColor(Color.parseColor(cardWhite))
            cornerRadius = 16f
            setStroke(1, Color.parseColor(cardBorder))
        }
        addView(TextView(this@PartyTransactionActivity).apply {
            this.text = text
            setTextColor(Color.parseColor(labelGray))
            textSize = 13f
            gravity = Gravity.CENTER
        })
    }

    private fun emptyText(text: String): TextView {
        return TextView(this).apply {
            this.text = text
            setTextColor(Color.parseColor(labelGray))
            textSize = 13f
            setPadding(0, 6, 0, 6)
        }
    }
}

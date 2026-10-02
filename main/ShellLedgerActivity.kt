package com.grocerypos.v11.ui
import com.grocerypos.v11.SyncQueueHelper

import android.graphics.Color
import android.graphics.Typeface
import android.os.Bundle
import android.text.Editable
import android.text.TextWatcher
import android.view.Gravity
import android.view.View
import android.widget.*
import androidx.appcompat.app.AlertDialog
import androidx.appcompat.app.AppCompatActivity
import androidx.lifecycle.lifecycleScope
import com.grocerypos.v11.PosDatabase
import com.grocerypos.v11.R
import com.grocerypos.v11.ShellCustomer
import com.grocerypos.v11.ShellTransaction
import com.grocerypos.v11.ShopEmptyShellLog
import com.grocerypos.v11.util.Loc
import kotlinx.coroutines.launch
import java.text.SimpleDateFormat
import java.util.Date
import java.util.Locale
import com.grocerypos.v11.ui.components.*

// NEW (Bottle Shell Ledger — made reachable): Database.kt already had the full backend
// for this feature (ShellCustomer/ShellTransaction/ShopEmptyShellLog entities, ShellDao,
// and the migration that creates the 3 tables) but no screen, manifest entry, or
// nav-tile anywhere in the app ever used it — completely unreachable, dead backend code.
// This screen wires it up end to end:
//   - ISSUE / RETURN against a named customer (auto-clamped so shellsOwed never goes
//     negative; typing an existing customer's name reuses their row via findByName
//     instead of creating a duplicate).
//   - A RETURN automatically also logs into the shop's own empty-shell stock with
//     reason=CUSTOMER_RETURN, matching what the entity's own doc-comment describes.
//   - A separate "Shop Stock" action for the shop's own count (manual add/remove, or
//     sent-for-refill), independent of any customer.
// Local-only, same as Zakat — not pushed through SyncQueueHelper (per the entity's own
// doc-comment), so no sync wiring is needed here.
class ShellLedgerActivity : AppCompatActivity() {

    private var bg = "#F3F4F9"
    private var navy = "#0B2545"
    private var cardWhite = "#FFFFFF"
    private var textDark = "#1A1D2E"
    private var textMuted = "#8A8FA3"
    private var green = "#2E7D32"
    private var red = "#C62828"
    private var teal = "#0F9B8E"
    private var amber = "#854F0B"
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
        amber = p.amber
        border = p.border
        fieldFill = p.fieldFill
    }

    private lateinit var owedTotalText: TextView
    private lateinit var shopStockTotalText: TextView
    private lateinit var searchField: EditText
    private lateinit var listContainer: LinearLayout
    private var allCustomers: List<ShellCustomer> = emptyList()

    override fun onCreate(b: Bundle?) {
        super.onCreate(b)
        loadThemeColors()

        val outer = LinearLayout(this).apply {
            orientation = LinearLayout.VERTICAL
            setBackgroundColor(Color.parseColor(bg))
        }
        outer.addView(premiumHeader(
            iconRes = R.drawable.ic_repeat,
            title = Loc.t(this@ShellLedgerActivity, "Bottle Shell Ledger", "بوتل شیل لیجر"),
            subtitle = Loc.t(this@ShellLedgerActivity, "Filled bottles given & shells returned", "دی گئی بھری بوتلیں اور واپس شیل"),
            primaryHex = navy,
            primaryDarkHex = navy
        ))

        val root = LinearLayout(this).apply {
            orientation = LinearLayout.VERTICAL
            setPadding(28, 26, 28, 32)
        }

        // ---- Summary cards ----
        val totalsRow = LinearLayout(this).apply { orientation = LinearLayout.HORIZONTAL }
        val owedCard = statCard(R.drawable.ic_people, Loc.t(this, "Owed by Customers", "کسٹمرز پر واجب"), red, lightenHex(red))
        val stockCard = statCard(R.drawable.ic_box, Loc.t(this, "Shop Empty Stock", "دکان کا خالی اسٹاک"), teal, lightenHex(teal))
        owedTotalText = owedCard.second
        shopStockTotalText = stockCard.second
        owedCard.first.layoutParams = LinearLayout.LayoutParams(0, LinearLayout.LayoutParams.WRAP_CONTENT, 1f).apply { setMargins(0, 0, 9, 0) }
        stockCard.first.layoutParams = LinearLayout.LayoutParams(0, LinearLayout.LayoutParams.WRAP_CONTENT, 1f).apply { setMargins(9, 0, 0, 0) }
        totalsRow.addView(owedCard.first); totalsRow.addView(stockCard.first)
        root.addView(totalsRow)
        root.addView(spacer(20))

        // ---- Action buttons ----
        val actionRow = LinearLayout(this).apply { orientation = LinearLayout.HORIZONTAL }
        actionRow.addView(Button(this).apply {
            text = Loc.t(this@ShellLedgerActivity, "ISSUE / RETURN", "اجرا / واپسی")
            setTextColor(Color.WHITE)
            background = roundedBg(navy, 16)
            setPadding(0, 20, 0, 20)
            layoutParams = LinearLayout.LayoutParams(0, LinearLayout.LayoutParams.WRAP_CONTENT, 1f).apply { setMargins(0, 0, 8, 0) }
            setOnClickListener { showIssueReturnDialog(null) }
        })
        actionRow.addView(Button(this).apply {
            text = Loc.t(this@ShellLedgerActivity, "SHOP STOCK", "دکان اسٹاک")
            setTextColor(Color.WHITE)
            background = roundedBg(teal, 16)
            setPadding(0, 20, 0, 20)
            layoutParams = LinearLayout.LayoutParams(0, LinearLayout.LayoutParams.WRAP_CONTENT, 1f).apply { setMargins(8, 0, 0, 0) }
            setOnClickListener { showShopStockDialog() }
        })
        root.addView(actionRow)
        root.addView(spacer(24))

        // ---- Search + customer list ----
        root.addView(sectionLabelPlain(Loc.t(this, "CUSTOMERS", "کسٹمرز")))
        root.addView(spacer(10))
        val searchBox = LinearLayout(this).apply {
            orientation = LinearLayout.HORIZONTAL
            gravity = Gravity.CENTER_VERTICAL
            setPadding(18, 4, 18, 4)
            background = strokedBg(border, fieldFill, 14)
            layoutParams = LinearLayout.LayoutParams(LinearLayout.LayoutParams.MATCH_PARENT, LinearLayout.LayoutParams.WRAP_CONTENT).apply { setMargins(0, 0, 0, 14) }
        }
        searchBox.addView(ImageView(this).apply {
            setImageDrawable(tintedDrawable(R.drawable.ic_search, textMuted, 15))
            layoutParams = LinearLayout.LayoutParams(LinearLayout.LayoutParams.WRAP_CONTENT, LinearLayout.LayoutParams.WRAP_CONTENT).apply { marginEnd = (8 * resources.displayMetrics.density).toInt() }
        })
        searchField = EditText(this).apply {
            hint = Loc.t(this@ShellLedgerActivity, "Search customer name or phone…", "کسٹمر کا نام یا فون تلاش کریں…")
            background = null
            textSize = 14f
            layoutParams = LinearLayout.LayoutParams(0, LinearLayout.LayoutParams.WRAP_CONTENT, 1f)
        }
        searchBox.addView(searchField)
        root.addView(searchBox)

        listContainer = LinearLayout(this).apply { orientation = LinearLayout.VERTICAL }
        root.addView(listContainer)
        root.addView(spacer(16))

        root.addView(TextView(this).apply {
            text = Loc.t(this@ShellLedgerActivity, "Shop Stock History", "دکان اسٹاک کی تاریخ")
            setLeadingIcon(R.drawable.ic_history, teal, 13, 6)
            textSize = 12f; setTextColor(Color.parseColor(teal)); setTypeface(typeface, Typeface.BOLD)
            setPadding(4, 0, 0, 0)
            setOnClickListener { showShopStockHistoryDialog() }
        })
        root.addView(spacer(30))

        outer.addView(ScrollView(this).apply {
            setBackgroundColor(Color.parseColor(bg))
            addView(root)
        })
        setContentView(outer)

        searchField.addTextChangedListener(object : TextWatcher {
            override fun beforeTextChanged(s: CharSequence?, a: Int, b: Int, c: Int) {}
            override fun onTextChanged(s: CharSequence?, a: Int, b: Int, c: Int) {}
            override fun afterTextChanged(s: Editable?) = renderList(s?.toString().orEmpty())
        })

        refresh()
    }

    // ---- UI helpers ----
    private fun sectionLabelPlain(text: String) = TextView(this).apply {
        this.text = text
        textSize = 12.5f
        setTextColor(Color.parseColor(textMuted))
        setTypeface(typeface, Typeface.BOLD)
        setPadding(4, 0, 0, 0)
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
            text = "  $label"; setTextColor(Color.parseColor(textMuted)); textSize = 11.5f
            setTypeface(typeface, Typeface.BOLD)
        })
        card.addView(topRow)
        val valueText = TextView(this).apply {
            text = "0"
            setTextColor(Color.parseColor(accentHex))
            textSize = 20f
            setTypeface(typeface, Typeface.BOLD)
            setPadding(0, 10, 0, 0)
        }
        card.addView(valueText)
        return Pair(card, valueText)
    }

    private fun reasonLabel(reason: String): String = when (reason) {
        "MANUAL_ADD" -> Loc.t(this, "Manual Add", "دستی اضافہ")
        "MANUAL_REMOVE" -> Loc.t(this, "Manual Remove", "دستی کمی")
        "SENT_FOR_REFILL" -> Loc.t(this, "Sent for Refill", "ری فل کے لیے بھیجی")
        "CUSTOMER_RETURN" -> Loc.t(this, "Customer Return", "کسٹمر کی واپسی")
        else -> reason
    }

    // ---- Data loading ----
    private fun refresh() = lifecycleScope.launch {
        val db = PosDatabase.get(this@ShellLedgerActivity)
        owedTotalText.text = db.shellDao().totalOwedByCustomers().toString()
        shopStockTotalText.text = db.shellDao().shopStockTotal().toString()
        allCustomers = db.shellDao().allCustomers()
        renderList(searchField.text?.toString().orEmpty())
    }

    private fun renderList(query: String) {
        listContainer.removeAllViews()
        val q = query.trim().lowercase()
        val filtered = if (q.isEmpty()) allCustomers else allCustomers.filter {
            it.name.lowercase().contains(q) || it.phone.lowercase().contains(q)
        }
        if (filtered.isEmpty()) {
            listContainer.addView(TextView(this).apply {
                text = if (allCustomers.isEmpty())
                    Loc.t(this@ShellLedgerActivity, "No shell customers yet", "ابھی کوئی شیل کسٹمر نہیں")
                else
                    Loc.t(this@ShellLedgerActivity, "No matches", "کوئی نتیجہ نہیں")
                setTextColor(Color.parseColor(textMuted))
                textSize = 13f; gravity = Gravity.CENTER
                setPadding(0, 24, 0, 24)
            })
            return
        }
        for (c in filtered) listContainer.addView(customerRow(c))
    }

    private fun customerRow(c: ShellCustomer): LinearLayout {
        return LinearLayout(this).apply {
            orientation = LinearLayout.HORIZONTAL
            gravity = Gravity.CENTER_VERTICAL
            setPadding(18, 16, 18, 16)
            background = roundedBg(cardWhite, 16)
            elevation = 2f
            layoutParams = LinearLayout.LayoutParams(LinearLayout.LayoutParams.MATCH_PARENT, LinearLayout.LayoutParams.WRAP_CONTENT).apply { setMargins(0, 0, 0, 10) }
            isClickable = true; isFocusable = true
            setOnClickListener { showCustomerDetailDialog(c) }

            addView(iconBadge(R.drawable.ic_person, navy, sizeDp = 38, iconSizeDp = 17))
            addView(spacerH(12))
            val col = LinearLayout(this@ShellLedgerActivity).apply {
                orientation = LinearLayout.VERTICAL
                layoutParams = LinearLayout.LayoutParams(0, LinearLayout.LayoutParams.WRAP_CONTENT, 1f)
            }
            col.addView(TextView(this@ShellLedgerActivity).apply {
                text = c.name; textSize = 14f; setTypeface(typeface, Typeface.BOLD); setTextColor(Color.parseColor(textDark))
            })
            if (c.phone.isNotEmpty()) {
                col.addView(TextView(this@ShellLedgerActivity).apply {
                    text = c.phone; textSize = 11.5f; setTextColor(Color.parseColor(textMuted)); setPadding(0, 2, 0, 0)
                })
            }
            addView(col)
            addView(TextView(this@ShellLedgerActivity).apply {
                text = "${c.shellsOwed} " + Loc.t(this@ShellLedgerActivity, "owed", "واجب")
                textSize = 12.5f
                setTextColor(Color.WHITE)
                setTypeface(typeface, Typeface.BOLD)
                setPadding(16, 6, 16, 6)
                background = roundedBg(if (c.shellsOwed > 0) red else teal, 20)
            })
        }
    }

    // ---- Issue / Return dialog ----
    private fun showIssueReturnDialog(prefill: ShellCustomer?) {
        var isIssue = true

        val root = LinearLayout(this).apply { orientation = LinearLayout.VERTICAL; setPadding(36, 20, 36, 8) }

        val nameInput = EditText(this).apply {
            hint = Loc.t(this@ShellLedgerActivity, "Customer name", "کسٹمر کا نام")
            setText(prefill?.name ?: "")
            isEnabled = prefill == null
            setPadding(20, 18, 20, 18)
            background = strokedBg(border, fieldFill, 14)
            layoutParams = LinearLayout.LayoutParams(LinearLayout.LayoutParams.MATCH_PARENT, LinearLayout.LayoutParams.WRAP_CONTENT).apply { setMargins(0, 0, 0, 12) }
        }
        root.addView(nameInput)

        val phoneInput = EditText(this).apply {
            hint = Loc.t(this@ShellLedgerActivity, "Phone (optional)", "فون (اختیاری)")
            setText(prefill?.phone ?: "")
            inputType = android.text.InputType.TYPE_CLASS_PHONE
            setPadding(20, 18, 20, 18)
            background = strokedBg(border, fieldFill, 14)
            layoutParams = LinearLayout.LayoutParams(LinearLayout.LayoutParams.MATCH_PARENT, LinearLayout.LayoutParams.WRAP_CONTENT).apply { setMargins(0, 0, 0, 16) }
            visibility = if (prefill == null) View.VISIBLE else View.GONE
        }
        root.addView(phoneInput)

        val typeRow = LinearLayout(this).apply { orientation = LinearLayout.HORIZONTAL; layoutParams = LinearLayout.LayoutParams(LinearLayout.LayoutParams.MATCH_PARENT, LinearLayout.LayoutParams.WRAP_CONTENT).apply { setMargins(0, 0, 0, 16) } }
        val issueChip = TextView(this).apply {
            text = Loc.t(this@ShellLedgerActivity, "ISSUE (gave filled)", "اجرا (بھری دی)")
            textSize = 13f; setTypeface(typeface, Typeface.BOLD); setPadding(16, 16, 16, 16)
            layoutParams = LinearLayout.LayoutParams(0, LinearLayout.LayoutParams.WRAP_CONTENT, 1f).apply { marginEnd = 8 }
        }
        val returnChip = TextView(this).apply {
            text = Loc.t(this@ShellLedgerActivity, "RETURN (shell back)", "واپسی (شیل واپس)")
            textSize = 13f; setTypeface(typeface, Typeface.BOLD); setPadding(16, 16, 16, 16)
            layoutParams = LinearLayout.LayoutParams(0, LinearLayout.LayoutParams.WRAP_CONTENT, 1f).apply { marginStart = 8 }
        }
        typeRow.addView(issueChip); typeRow.addView(returnChip)
        root.addView(typeRow)

        fun styleChips() {
            issueChip.background = if (isIssue) roundedBg(red, 14) else strokedBg(border, cardWhite, 14)
            issueChip.setTextColor(if (isIssue) Color.WHITE else Color.parseColor(textMuted))
            returnChip.background = if (!isIssue) roundedBg(teal, 14) else strokedBg(border, cardWhite, 14)
            returnChip.setTextColor(if (!isIssue) Color.WHITE else Color.parseColor(textMuted))
        }
        issueChip.setOnClickListener { isIssue = true; styleChips() }
        returnChip.setOnClickListener { isIssue = false; styleChips() }
        styleChips()

        val qtyInput = EditText(this).apply {
            hint = Loc.t(this@ShellLedgerActivity, "Quantity (shells)", "تعداد (شیلز)")
            inputType = android.text.InputType.TYPE_CLASS_NUMBER
            setPadding(20, 18, 20, 18)
            background = strokedBg(border, fieldFill, 14)
            layoutParams = LinearLayout.LayoutParams(LinearLayout.LayoutParams.MATCH_PARENT, LinearLayout.LayoutParams.WRAP_CONTENT).apply { setMargins(0, 0, 0, 12) }
        }
        root.addView(qtyInput)

        val noteInput = EditText(this).apply {
            hint = Loc.t(this@ShellLedgerActivity, "Note (optional)", "نوٹ (اختیاری)")
            setPadding(20, 18, 20, 18)
            background = strokedBg(border, fieldFill, 14)
        }
        root.addView(noteInput)

        if (prefill != null) {
            root.addView(TextView(this).apply {
                text = "${prefill.name} " + Loc.t(this@ShellLedgerActivity, "currently owes", "فی الحال واجب") + " ${prefill.shellsOwed}"
                textSize = 11.5f; setTextColor(Color.parseColor(textMuted)); setPadding(2, 12, 0, 0)
            })
        }

        val scroll = ScrollView(this).apply { addView(root) }

        AlertDialog.Builder(this)
            .setTitle(Loc.t(this, "Issue / Return Shell", "شیل اجرا / واپسی"))
            .setView(scroll)
            .setNegativeButton(Loc.t(this, "Cancel", "منسوخ کریں"), null)
            .setPositiveButton(Loc.t(this, "Save", "محفوظ کریں"), null)
            .create()
            .also { dialog ->
                dialog.setOnShowListener {
                    dialog.getButton(AlertDialog.BUTTON_POSITIVE).setOnClickListener {
                        val name = nameInput.text.toString().trim()
                        val qty = qtyInput.text.toString().toIntOrNull()
                        if (name.isEmpty()) {
                            Toast.makeText(this, Loc.t(this, "Enter a customer name", "کسٹمر کا نام درج کریں"), Toast.LENGTH_SHORT).show()
                            return@setOnClickListener
                        }
                        if (qty == null || qty <= 0) {
                            Toast.makeText(this, Loc.t(this, "Enter a valid quantity", "درست تعداد درج کریں"), Toast.LENGTH_SHORT).show()
                            return@setOnClickListener
                        }
                        saveIssueReturn(prefill, name, phoneInput.text.toString().trim(), isIssue, qty, noteInput.text.toString().trim())
                        dialog.dismiss()
                    }
                }
            }
            .show()
    }

    private fun saveIssueReturn(prefill: ShellCustomer?, name: String, phone: String, isIssue: Boolean, qty: Int, note: String) = lifecycleScope.launch {
        val db = PosDatabase.get(this@ShellLedgerActivity)
        val dao = db.shellDao()
        val customer = prefill ?: dao.findByName(name)
        val customerId: Long
        if (customer == null) {
            val newOwed = if (isIssue) qty else 0
            val newCustomer = ShellCustomer(name = name, phone = phone, shellsOwed = newOwed)
            customerId = dao.insertCustomer(newCustomer)
            dao.getCustomer(customerId)?.let { SyncQueueHelper.enqueueShellCustomer(db, it) }
        } else {
            customerId = customer.id
            val newOwed = if (isIssue) customer.shellsOwed + qty else (customer.shellsOwed - qty).coerceAtLeast(0)
            val updated = customer.copy(shellsOwed = newOwed, updatedAt = System.currentTimeMillis(), dirty = true)
            dao.updateCustomer(updated)
            SyncQueueHelper.enqueueShellCustomer(db, updated)
        }
        val newTxnId = dao.insertTransaction(ShellTransaction(
            customerId = customerId,
            type = if (isIssue) "ISSUE" else "RETURN",
            qty = qty,
            note = note
        ))
        dao.historyForCustomer(customerId).find { it.id == newTxnId }?.let {
            SyncQueueHelper.enqueueShellTransaction(db, it)
        }
        if (!isIssue) {
            // Customer handed back an empty shell — it lands in the shop's own stock.
            val newLogId = dao.insertShopLog(ShopEmptyShellLog(delta = qty, reason = "CUSTOMER_RETURN", note = if (note.isNotEmpty()) "$name - $note" else name))
            dao.shopLogHistory().find { it.id == newLogId }?.let { SyncQueueHelper.enqueueShopEmptyShellLog(db, it) }
        }
        SyncQueueHelper.trigger(this@ShellLedgerActivity)
        Toast.makeText(this@ShellLedgerActivity, Loc.t(this@ShellLedgerActivity, "Saved", "محفوظ ہو گیا"), Toast.LENGTH_SHORT).show()
        refresh()
    }

    // ---- Shop stock dialog ----
    private fun showShopStockDialog() {
        var reasonCode = "MANUAL_ADD"

        val root = LinearLayout(this).apply { orientation = LinearLayout.VERTICAL; setPadding(36, 20, 36, 8) }

        val reasonRow = LinearLayout(this).apply { orientation = LinearLayout.HORIZONTAL; layoutParams = LinearLayout.LayoutParams(LinearLayout.LayoutParams.MATCH_PARENT, LinearLayout.LayoutParams.WRAP_CONTENT).apply { setMargins(0, 0, 0, 16) } }
        val addChip = TextView(this).apply {
            text = Loc.t(this@ShellLedgerActivity, "+ Add", "+ شامل")
            textSize = 12.5f; setTypeface(typeface, Typeface.BOLD); setPadding(12, 14, 12, 14)
            layoutParams = LinearLayout.LayoutParams(0, LinearLayout.LayoutParams.WRAP_CONTENT, 1f).apply { marginEnd = 6 }
        }
        val removeChip = TextView(this).apply {
            text = Loc.t(this@ShellLedgerActivity, "− Remove", "− نکالیں")
            textSize = 12.5f; setTypeface(typeface, Typeface.BOLD); setPadding(12, 14, 12, 14)
            layoutParams = LinearLayout.LayoutParams(0, LinearLayout.LayoutParams.WRAP_CONTENT, 1f).apply { marginStart = 3; marginEnd = 3 }
        }
        val refillChip = TextView(this).apply {
            text = Loc.t(this@ShellLedgerActivity, "Sent for Refill", "ری فل کے لیے بھیجی")
            textSize = 12.5f; setTypeface(typeface, Typeface.BOLD); setPadding(12, 14, 12, 14)
            layoutParams = LinearLayout.LayoutParams(0, LinearLayout.LayoutParams.WRAP_CONTENT, 1f).apply { marginStart = 6 }
        }
        reasonRow.addView(addChip); reasonRow.addView(removeChip); reasonRow.addView(refillChip)
        root.addView(reasonRow)

        fun styleChips() {
            addChip.background = if (reasonCode == "MANUAL_ADD") roundedBg(teal, 14) else strokedBg(border, cardWhite, 14)
            addChip.setTextColor(if (reasonCode == "MANUAL_ADD") Color.WHITE else Color.parseColor(textMuted))
            removeChip.background = if (reasonCode == "MANUAL_REMOVE") roundedBg(red, 14) else strokedBg(border, cardWhite, 14)
            removeChip.setTextColor(if (reasonCode == "MANUAL_REMOVE") Color.WHITE else Color.parseColor(textMuted))
            refillChip.background = if (reasonCode == "SENT_FOR_REFILL") roundedBg(amber, 14) else strokedBg(border, cardWhite, 14)
            refillChip.setTextColor(if (reasonCode == "SENT_FOR_REFILL") Color.WHITE else Color.parseColor(textMuted))
        }
        addChip.setOnClickListener { reasonCode = "MANUAL_ADD"; styleChips() }
        removeChip.setOnClickListener { reasonCode = "MANUAL_REMOVE"; styleChips() }
        refillChip.setOnClickListener { reasonCode = "SENT_FOR_REFILL"; styleChips() }
        styleChips()

        val qtyInput = EditText(this).apply {
            hint = Loc.t(this@ShellLedgerActivity, "Quantity (shells)", "تعداد (شیلز)")
            inputType = android.text.InputType.TYPE_CLASS_NUMBER
            setPadding(20, 18, 20, 18)
            background = strokedBg(border, fieldFill, 14)
            layoutParams = LinearLayout.LayoutParams(LinearLayout.LayoutParams.MATCH_PARENT, LinearLayout.LayoutParams.WRAP_CONTENT).apply { setMargins(0, 0, 0, 12) }
        }
        root.addView(qtyInput)

        val noteInput = EditText(this).apply {
            hint = Loc.t(this@ShellLedgerActivity, "Note (optional)", "نوٹ (اختیاری)")
            setPadding(20, 18, 20, 18)
            background = strokedBg(border, fieldFill, 14)
        }
        root.addView(noteInput)

        AlertDialog.Builder(this)
            .setTitle(Loc.t(this, "Shop Empty Shell Stock", "دکان کا خالی شیل اسٹاک"))
            .setView(root)
            .setNegativeButton(Loc.t(this, "Cancel", "منسوخ کریں"), null)
            .setPositiveButton(Loc.t(this, "Save", "محفوظ کریں"), null)
            .create()
            .also { dialog ->
                dialog.setOnShowListener {
                    dialog.getButton(AlertDialog.BUTTON_POSITIVE).setOnClickListener {
                        val qty = qtyInput.text.toString().toIntOrNull()
                        if (qty == null || qty <= 0) {
                            Toast.makeText(this, Loc.t(this, "Enter a valid quantity", "درست تعداد درج کریں"), Toast.LENGTH_SHORT).show()
                            return@setOnClickListener
                        }
                        saveShopStock(reasonCode, qty, noteInput.text.toString().trim())
                        dialog.dismiss()
                    }
                }
            }
            .show()
    }

    private fun saveShopStock(reasonCode: String, qty: Int, note: String) = lifecycleScope.launch {
        val db = PosDatabase.get(this@ShellLedgerActivity)
        val current = db.shellDao().shopStockTotal()
        val delta = if (reasonCode == "MANUAL_ADD") qty else -qty
        if (delta < 0 && current + delta < 0) {
            Toast.makeText(this@ShellLedgerActivity, Loc.t(this@ShellLedgerActivity, "Not enough shop stock to remove that much", "اتنی مقدار نکالنے کے لیے اسٹاک کافی نہیں"), Toast.LENGTH_LONG).show()
            return@launch
        }
        val newLogId = db.shellDao().insertShopLog(ShopEmptyShellLog(delta = delta, reason = reasonCode, note = note))
        db.shellDao().shopLogHistory().find { it.id == newLogId }?.let { SyncQueueHelper.enqueueShopEmptyShellLog(db, it) }
        SyncQueueHelper.trigger(this@ShellLedgerActivity)
        Toast.makeText(this@ShellLedgerActivity, Loc.t(this@ShellLedgerActivity, "Saved", "محفوظ ہو گیا"), Toast.LENGTH_SHORT).show()
        refresh()
    }

    // ---- History dialogs ----
    private fun showCustomerDetailDialog(c: ShellCustomer) = lifecycleScope.launch {
        val db = PosDatabase.get(this@ShellLedgerActivity)
        val history = db.shellDao().historyForCustomer(c.id)

        val root = LinearLayout(this@ShellLedgerActivity).apply { orientation = LinearLayout.VERTICAL; setPadding(36, 12, 36, 8) }
        root.addView(TextView(this@ShellLedgerActivity).apply {
            text = Loc.t(this@ShellLedgerActivity, "Currently owes: ", "فی الحال واجب: ") + "${c.shellsOwed}"
            textSize = 13.5f; setTypeface(typeface, Typeface.BOLD); setTextColor(Color.parseColor(if (c.shellsOwed > 0) red else teal))
            setPadding(0, 0, 0, 14)
        })
        if (history.isEmpty()) {
            root.addView(TextView(this@ShellLedgerActivity).apply {
                text = Loc.t(this@ShellLedgerActivity, "No transactions yet", "ابھی کوئی لین دین نہیں")
                setTextColor(Color.parseColor(textMuted)); textSize = 12.5f
            })
        } else {
            val fmt = SimpleDateFormat("dd MMM, hh:mm a", Locale.getDefault())
            for (t in history.take(30)) {
                root.addView(LinearLayout(this@ShellLedgerActivity).apply {
                    orientation = LinearLayout.HORIZONTAL
                    gravity = Gravity.CENTER_VERTICAL
                    setPadding(0, 8, 0, 8)
                    addView(TextView(this@ShellLedgerActivity).apply {
                        text = (if (t.type == "ISSUE") "+ " else "− ") + "${t.qty} " +
                            (if (t.type == "ISSUE") Loc.t(this@ShellLedgerActivity, "Issued", "اجرا") else Loc.t(this@ShellLedgerActivity, "Returned", "واپس")) +
                            (if (t.note.isNotEmpty()) " (${t.note})" else "")
                        textSize = 12.5f
                        setTextColor(Color.parseColor(if (t.type == "ISSUE") red else teal))
                        layoutParams = LinearLayout.LayoutParams(0, LinearLayout.LayoutParams.WRAP_CONTENT, 1f)
                    })
                    addView(TextView(this@ShellLedgerActivity).apply {
                        text = fmt.format(Date(t.createdAt))
                        textSize = 10.5f; setTextColor(Color.parseColor(textMuted))
                    })
                })
            }
        }
        val scroll = ScrollView(this@ShellLedgerActivity).apply { addView(root) }

        AlertDialog.Builder(this@ShellLedgerActivity)
            .setTitle(c.name)
            .setView(scroll)
            .setNegativeButton(Loc.t(this@ShellLedgerActivity, "Close", "بند کریں"), null)
            .setPositiveButton(Loc.t(this@ShellLedgerActivity, "Issue / Return", "اجرا / واپسی")) { _, _ ->
                showIssueReturnDialog(c)
            }
            .show()
    }

    private fun showShopStockHistoryDialog() = lifecycleScope.launch {
        val db = PosDatabase.get(this@ShellLedgerActivity)
        val history = db.shellDao().shopLogHistory()
        val root = LinearLayout(this@ShellLedgerActivity).apply { orientation = LinearLayout.VERTICAL; setPadding(36, 12, 36, 8) }
        if (history.isEmpty()) {
            root.addView(TextView(this@ShellLedgerActivity).apply {
                text = Loc.t(this@ShellLedgerActivity, "No shop stock entries yet", "ابھی کوئی دکان اسٹاک انٹری نہیں")
                setTextColor(Color.parseColor(textMuted)); textSize = 12.5f
            })
        } else {
            val fmt = SimpleDateFormat("dd MMM, hh:mm a", Locale.getDefault())
            for (l in history.take(50)) {
                root.addView(LinearLayout(this@ShellLedgerActivity).apply {
                    orientation = LinearLayout.HORIZONTAL
                    gravity = Gravity.CENTER_VERTICAL
                    setPadding(0, 8, 0, 8)
                    addView(TextView(this@ShellLedgerActivity).apply {
                        text = (if (l.delta >= 0) "+" else "") + "${l.delta}  " + reasonLabel(l.reason) +
                            (if (l.note.isNotEmpty()) " (${l.note})" else "")
                        textSize = 12.5f
                        setTextColor(Color.parseColor(if (l.delta >= 0) teal else red))
                        layoutParams = LinearLayout.LayoutParams(0, LinearLayout.LayoutParams.WRAP_CONTENT, 1f)
                    })
                    addView(TextView(this@ShellLedgerActivity).apply {
                        text = fmt.format(Date(l.createdAt))
                        textSize = 10.5f; setTextColor(Color.parseColor(textMuted))
                    })
                })
            }
        }
        val scroll = ScrollView(this@ShellLedgerActivity).apply { addView(root) }
        AlertDialog.Builder(this@ShellLedgerActivity)
            .setTitle(Loc.t(this@ShellLedgerActivity, "Shop Stock History", "دکان اسٹاک کی تاریخ"))
            .setView(scroll)
            .setPositiveButton(Loc.t(this@ShellLedgerActivity, "Close", "بند کریں"), null)
            .show()
    }
}

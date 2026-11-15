package com.grocerypos.v11.ui

/*
 * Party Dashboard — "+" Quick Add menu: the action sheet itself
 * (showPremiumMenuSheet, reused by other quick-menus in this screen family),
 * the Quick Add item list (showQuickAddDialog), and the customer/supplier
 * picker used by the two payment shortcuts (showPartyPickerForPayment).
 * Split out of PartyDashboardActivity.kt as part of the "Oversized Activity
 * files" cleanup (see IMPROVEMENT-PLAN.md), same approach as the Sale/Product
 * screens: extension functions on PartyDashboardActivity, no behavior change.
 */

import android.app.AlertDialog
import android.content.Intent
import android.graphics.Color
import android.graphics.Typeface
import android.text.Editable
import android.text.TextWatcher
import android.view.Gravity
import android.view.View
import android.widget.EditText
import android.widget.LinearLayout
import android.widget.ScrollView
import android.widget.TextView
import com.grocerypos.v11.*
import com.grocerypos.v11.ui.components.*
import com.grocerypos.v11.util.Loc

internal fun PartyDashboardActivity.showQuickAddDialog() {
    showPremiumMenuSheet(
        headerIconRes = R.drawable.ic_add,
        headerTitle = Loc.t(this, "Quick Add", "\u0641\u0648\u0631\u06CC \u0627\u0646\u062F\u0631\u0627\u062C"),
        headerSubtitle = Loc.t(this, "Choose an action", "\u0627\u06CC\u06A9 \u0639\u0645\u0644 \u0645\u0646\u062A\u062E\u0628 \u06A9\u0631\u06CC\u06BA"),
        items = listOf(
            QuickMenuItem(R.drawable.ic_receipt, red, tintBg(red),
                Loc.t(this, "Add Sale", "\u0633\u06CC\u0644 \u0634\u0627\u0645\u0644 \u06A9\u0631\u06CC\u06BA"),
                Loc.t(this, "Create a new sale invoice", "نیا سیل انوائس بنائیں")
            ) { startActivity(Intent(this, SaleActivity::class.java)) },
            QuickMenuItem(R.drawable.ic_cart, blue, tintBg(blue),
                Loc.t(this, "Add Purchase", "\u062E\u0631\u06CC\u062F\u0627\u0631\u06CC \u0634\u0627\u0645\u0644 \u06A9\u0631\u06CC\u06BA"),
                Loc.t(this, "Create a new purchase bill", "نیا خریداری بل بنائیں")
            ) { startActivity(Intent(this, PurchaseActivity::class.java)) },
            // Sale/Purchase Return need a specific invoice/bill picked first — route
            // to the matching history list, which already has a ↩ Return action on
            // each row (see SaleHistoryActivity.saleRow() / PurchaseHistoryActivity's
            // per-card actions row), instead of duplicating that picker+logic here.
            QuickMenuItem(R.drawable.ic_undo, orange, tintBg(orange),
                Loc.t(this, "Sale Return", "\u0633\u06CC\u0644 \u0648\u0627\u067E\u0633\u06CC"),
                Loc.t(this, "Return items from a past sale", "پچھلی سیل سے آئٹمز واپس کریں")
            ) { startActivity(Intent(this, SaleHistoryActivity::class.java)) },
            QuickMenuItem(R.drawable.ic_undo, teal, tintBg(teal),
                Loc.t(this, "Purchase Return", "\u062E\u0631\u06CC\u062F\u0627\u0631\u06CC \u0648\u0627\u067E\u0633\u06CC"),
                Loc.t(this, "Return items from a past purchase", "پچھلی خریداری سے آئٹمز واپس کریں")
            ) { startActivity(Intent(this, PurchaseHistoryActivity::class.java)) },
            QuickMenuItem(R.drawable.ic_person, purple, tintBg(purple),
                Loc.t(this, "New Party", "\u0646\u0626\u06CC \u067E\u0627\u0631\u0679\u06CC"),
                Loc.t(this, "Add a customer or supplier", "کسٹمر یا سپلائر شامل کریں")
            ) { startActivity(Intent(this, PartyActivity::class.java)) },
            QuickMenuItem(R.drawable.ic_wallet, green, tintBg(green),
                Loc.t(this, "Payment Received", "\u0627\u062F\u0627\u0626\u06CC\u06AF\u06CC \u0648\u0635\u0648\u0644 \u06C1\u0648\u0626\u06CC"),
                Loc.t(this, "Record money received", "موصول ہونے والی رقم درج کریں")
            ) { showPartyPickerForPayment(forCustomer = true) },
            QuickMenuItem(R.drawable.ic_bank, gold, tintBg(gold),
                Loc.t(this, "Payment Made", "\u0627\u062F\u0627\u0626\u06CC\u06AF\u06CC \u06C1\u0648\u0626\u06CC"),
                Loc.t(this, "Record money paid out", "ادا کی گئی رقم درج کریں")
            ) { showPartyPickerForPayment(forCustomer = false) }
        )
    )
}

// ================= Shared premium menu-sheet builder =================
// One card matching the icon-badge nav-row style used in ReportsActivity/
// HistoryActivity: colored circular icon badge, bold title, gray subtitle,
// chevron, divider between rows. Height is hard-capped so on a tall list the
// rows scroll internally instead of ever pushing content off-screen.
internal data class QuickMenuItem(
    val iconRes: Int,
    val accentHex: String,
    val tintHex: String,
    val title: String,
    val subtitle: String,
    val onClick: () -> Unit
)

// CHANGED (brought onto the central theme system — was a fixed pastel hex per
// item, which stayed the same "light mode" tint even in dark mode). Deriving the
// badge background from the item's own theme-driven accentHex keeps it correctly
// muted in both themes with zero extra palette fields.
private fun tintBg(accentHex: String): String = "#22" + accentHex.removePrefix("#")

internal fun PartyDashboardActivity.showPremiumMenuSheet(headerIconRes: Int, headerTitle: String, headerSubtitle: String, items: List<QuickMenuItem>) {
    val itemsContainer = LinearLayout(this).apply { orientation = LinearLayout.VERTICAL }

    val header = LinearLayout(this).apply {
        orientation = LinearLayout.HORIZONTAL
        gravity = Gravity.CENTER_VERTICAL
        setPadding(28, 26, 28, 18)
        addView(iconBadge(headerIconRes, navy, bgHex = tintBg(navy), sizeDp = 44, iconSizeDp = 20).apply {
            layoutParams = LinearLayout.LayoutParams((44 * resources.displayMetrics.density).toInt(), (44 * resources.displayMetrics.density).toInt())
                .apply { setMargins(0, 0, 24, 0) }
        })
        addView(LinearLayout(this@showPremiumMenuSheet).apply {
            orientation = LinearLayout.VERTICAL
            layoutParams = LinearLayout.LayoutParams(0, LinearLayout.LayoutParams.WRAP_CONTENT, 1f)
            addView(TextView(this@showPremiumMenuSheet).apply {
                text = headerTitle
                textSize = 17f
                setTypeface(typeface, Typeface.BOLD)
                setTextColor(Color.parseColor(textDark))
            })
            addView(TextView(this@showPremiumMenuSheet).apply {
                text = headerSubtitle
                textSize = 12.5f
                setTextColor(Color.parseColor(labelGray))
                setPadding(0, 2, 0, 0)
            })
        })
    }
    itemsContainer.addView(header)
    itemsContainer.addView(View(this).apply {
        setBackgroundColor(Color.parseColor(cardBorder))
        layoutParams = LinearLayout.LayoutParams(LinearLayout.LayoutParams.MATCH_PARENT, 2)
    })

    lateinit var dialog: AlertDialog

    items.forEachIndexed { index, item ->
        val row = LinearLayout(this).apply {
            orientation = LinearLayout.HORIZONTAL
            gravity = Gravity.CENTER_VERTICAL
            isClickable = true
            isFocusable = true
            setPadding(28, 20, 28, 20)
            val outValue = android.util.TypedValue()
            theme.resolveAttribute(android.R.attr.selectableItemBackground, outValue, true)
            setBackgroundResource(outValue.resourceId)
            setOnClickListener { dialog.dismiss(); item.onClick() }
        }
        row.addView(iconBadge(item.iconRes, item.accentHex, bgHex = item.tintHex, sizeDp = 40, iconSizeDp = 18).apply {
            layoutParams = LinearLayout.LayoutParams((40 * resources.displayMetrics.density).toInt(), (40 * resources.displayMetrics.density).toInt())
                .apply { setMargins(0, 0, 22, 0) }
        })
        row.addView(LinearLayout(this).apply {
            orientation = LinearLayout.VERTICAL
            layoutParams = LinearLayout.LayoutParams(0, LinearLayout.LayoutParams.WRAP_CONTENT, 1f)
            addView(TextView(this@showPremiumMenuSheet).apply {
                text = item.title
                textSize = 14.5f
                setTypeface(typeface, Typeface.BOLD)
                setTextColor(Color.parseColor(textDark))
            })
            addView(TextView(this@showPremiumMenuSheet).apply {
                text = item.subtitle
                textSize = 12f
                setTextColor(Color.parseColor(labelGray))
                setPadding(0, 2, 0, 0)
            })
        })
        row.addView(TextView(this).apply {
            text = "\u203A"
            textSize = 18f
            setTypeface(typeface, Typeface.BOLD)
            setTextColor(Color.parseColor(item.accentHex))
        })
        itemsContainer.addView(row)
        if (index != items.lastIndex) {
            itemsContainer.addView(View(this).apply {
                setBackgroundColor(Color.parseColor(cardBorder))
                layoutParams = LinearLayout.LayoutParams(LinearLayout.LayoutParams.MATCH_PARENT, 1)
                    .apply { setMargins((28 * resources.displayMetrics.density).toInt(), 0, 0, 0) }
            })
        }
    }

    val scroll = ScrollView(this).apply {
        layoutParams = LinearLayout.LayoutParams(LinearLayout.LayoutParams.MATCH_PARENT, LinearLayout.LayoutParams.WRAP_CONTENT)
        addView(itemsContainer)
    }

    val maxHeightPx = (resources.displayMetrics.heightPixels * 0.78).toInt()
    val root = object : LinearLayout(this) {
        override fun onMeasure(widthMeasureSpec: Int, heightMeasureSpec: Int) {
            val mode = View.MeasureSpec.getMode(heightMeasureSpec)
            val size = View.MeasureSpec.getSize(heightMeasureSpec)
            val cappedSize = if (mode == View.MeasureSpec.UNSPECIFIED) maxHeightPx else size.coerceAtMost(maxHeightPx)
            val newMode = if (mode == View.MeasureSpec.UNSPECIFIED) View.MeasureSpec.AT_MOST else mode
            super.onMeasure(widthMeasureSpec, View.MeasureSpec.makeMeasureSpec(cappedSize, newMode))
        }
    }.apply {
        orientation = LinearLayout.VERTICAL
        background = strokedBg(cardBorder, cardWhite, 22)
        clipToOutline = true
        addView(scroll)
    }
    applyElevation(root, 6f)

    dialog = AlertDialog.Builder(this)
        .setView(root)
        .create()
    dialog.window?.setBackgroundDrawableResource(android.R.color.transparent)
    dialog.show()
}

// ---------------- NEW: quick "Payment Received" / "Payment Made" from the "+" menu ----------------
// Previously the only way to record a standalone payment (money changing hands with no
// new sale/purchase bill) was to open a specific party's ledger first, then tap the
// "Receive Payment"/"Make Payment" button there. This adds a fast path straight from the
// dashboard's "+" menu: pick the customer (for money received) or supplier (for money paid)
// from a searchable list, then jump straight into PartyTransactionActivity with the
// payment dialog already open (via the "openPayment" extra), skipping the extra tap.
internal fun PartyDashboardActivity.showPartyPickerForPayment(forCustomer: Boolean) {
    val p = com.grocerypos.v11.util.ThemeManager.palette(this)
    val candidates = allItems.filter { it.isCustomer == forCustomer }.sortedBy { it.name.lowercase() }

    val root = LinearLayout(this).apply {
        orientation = LinearLayout.VERTICAL
        setPadding(32, 24, 32, 8)
    }
    val searchBox = EditText(this).apply {
        hint = Loc.t(this@showPartyPickerForPayment,
            if (forCustomer) "Search customer" else "Search supplier",
            if (forCustomer) "\u06A9\u0633\u0679\u0645\u0631 \u062A\u0644\u0627\u0634 \u06A9\u0631\u06CC\u06BA" else "\u0633\u067E\u0644\u0627\u0626\u0631 \u062A\u0644\u0627\u0634 \u06A9\u0631\u06CC\u06BA")
        setPadding(20, 18, 20, 18)
        background = roundedBackground(p.fieldFill, 18)
    }
    root.addView(searchBox)

    val listContainer = LinearLayout(this).apply { orientation = LinearLayout.VERTICAL }
    val scroll = ScrollView(this).apply {
        addView(listContainer)
        layoutParams = LinearLayout.LayoutParams(
            LinearLayout.LayoutParams.MATCH_PARENT,
            (320 * resources.displayMetrics.density).toInt()
        )
    }
    root.addView(scroll)

    val dialog = AlertDialog.Builder(this)
        .setTitle(Loc.t(this,
            if (forCustomer) "Payment Received" else "Payment Made",
            if (forCustomer) "\u0627\u062F\u0627\u0626\u06CC\u06AF\u06CC \u0648\u0635\u0648\u0644 \u06C1\u0648\u0626\u06CC" else "\u0627\u062F\u0627\u0626\u06CC\u06AF\u06CC \u06C1\u0648\u0626\u06CC"))
        .setView(root)
        .setNegativeButton(Loc.t(this, "Cancel", "\u0645\u0646\u0633\u0648\u062E \u06A9\u0631\u06CC\u06BA"), null)
        .create()

    fun renderList(query: String) {
        listContainer.removeAllViews()
        val filtered = if (query.isBlank()) candidates
            else candidates.filter { it.name.contains(query, ignoreCase = true) || it.phone.contains(query) }
        if (filtered.isEmpty()) {
            listContainer.addView(TextView(this).apply {
                text = Loc.t(this@showPartyPickerForPayment,
                    if (forCustomer) "No customers found" else "No suppliers found",
                    if (forCustomer) "\u06A9\u0648\u0626\u06CC \u06A9\u0633\u0679\u0645\u0631 \u0646\u06C1\u06CC\u06BA \u0645\u0644\u0627" else "\u06A9\u0648\u0626\u06CC \u0633\u067E\u0644\u0627\u0626\u0631 \u0646\u06C1\u06CC\u06BA \u0645\u0644\u0627")
                textSize = 13.5f
                setTextColor(Color.parseColor(labelGray))
                gravity = Gravity.CENTER
                setPadding(20, 40, 20, 40)
            })
            return
        }
        for (item in filtered) {
            listContainer.addView(TextView(this).apply {
                text = item.name + if (item.phone.isNotBlank()) "  \u00B7  ${item.phone}" else ""
                textSize = 14.5f
                setTextColor(Color.parseColor(textDark))
                setPadding(20, 26, 20, 26)
                isClickable = true
                isFocusable = true
                setOnClickListener {
                    dialog.dismiss()
                    startActivity(Intent(this@showPartyPickerForPayment, PartyTransactionActivity::class.java).apply {
                        putExtra("partyId", item.id)
                        putExtra("partyName", item.name)
                        putExtra("isCustomer", item.isCustomer)
                        putExtra("openPayment", true)
                    })
                }
            })
        }
    }

    searchBox.addTextChangedListener(object : TextWatcher {
        override fun beforeTextChanged(s: CharSequence?, start: Int, count: Int, after: Int) {}
        override fun onTextChanged(s: CharSequence?, start: Int, before: Int, count: Int) {}
        override fun afterTextChanged(s: Editable?) { renderList(s?.toString() ?: "") }
    })

    renderList("")
    dialog.show()
}

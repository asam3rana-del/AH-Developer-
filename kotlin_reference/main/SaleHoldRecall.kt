package com.grocerypos.v11.ui

/*
 * Sale screen — Hold / Recall subsystem: parking the current in-progress
 * bill (holdBill/encodeHold) and bringing one back (decodeHold/
 * openRecallDialog). Split out of SaleActivity.kt as part of the "Oversized
 * Activity files" cleanup (see IMPROVEMENT-PLAN.md). Declared as extension
 * functions on SaleActivity; no behavior change.
 */

import android.graphics.Color
import android.view.Gravity
import android.view.View
import android.widget.Button
import android.widget.LinearLayout
import android.widget.TextView
import android.widget.Toast
import androidx.appcompat.app.AlertDialog
import androidx.lifecycle.lifecycleScope
import com.grocerypos.v11.*
import com.grocerypos.v11.domain.SaleLine
import com.grocerypos.v11.ui.components.*
import kotlinx.coroutines.launch
import java.text.SimpleDateFormat
import java.util.Date
import java.util.Locale

internal fun SaleActivity.holdBill() {
    if (lines.isEmpty()) {
        Toast.makeText(this, "Add items pehle, phir hold karen", Toast.LENGTH_SHORT).show()
        return
    }
    viewModel.holdBill(encodeHold())
}

internal fun SaleActivity.encodeHold(): String {
    val header = listOf(
        customerName.text.toString(),
        saleTypeSpinner.selectedItem?.toString() ?: "Retail",
        if (isCashSale) "CASH" else "CREDIT",
        discountInput.text.toString()
    ).joinToString("\u0001")

    val itemsPart = lines.joinToString("\u0002") {
        listOf(
            it.barcode, it.itemName, it.qty, it.unit, it.unitPrice, it.cost, it.amount,
            it.mainUnit, it.secondaryUnit, it.secondaryUnitQty, it.tertiaryUnit, it.tertiaryUnitQty
        ).joinToString("\u0003")
    }
    return header + "\u0004" + itemsPart
}

internal fun SaleActivity.decodeHold(payload: String) {
    val parts = payload.split("\u0004")
    if (parts.isEmpty()) return
    val header = parts[0].split("\u0001")
    if (header.size >= 4) {
        customerName.setText(header[0])
        val saleTypeIndex = if (header[1] == "Wholesale") 1 else 0
        saleTypeSpinner.setSelection(saleTypeIndex)
        discountInput.setText(header[3])
    }

    lines.clear()
    if (parts.size > 1 && parts[1].isNotEmpty()) {
        parts[1].split("\u0002").forEach { row ->
            val f = row.split("\u0003")
            if (f.size >= 10) {
                lines.add(
                    SaleLine(
                        barcode = f[0],
                        itemName = f[1],
                        qty = f[2].toDoubleOrNull() ?: 0.0,
                        unit = f[3],
                        unitPrice = f[4].toDoubleOrNull() ?: 0.0,
                        cost = f[5].toDoubleOrNull() ?: 0.0,
                        amount = f[6].toDoubleOrNull() ?: 0.0,
                        mainUnit = f[7],
                        secondaryUnit = f[8],
                        secondaryUnitQty = f[9].toDoubleOrNull() ?: 0.0,
                        tertiaryUnit = f.getOrNull(10) ?: "",
                        tertiaryUnitQty = f.getOrNull(11)?.toDoubleOrNull() ?: 0.0
                    )
                )
            }
        }
    }
    renderItemsList()
    updateTotals()
    if (editInvoice == null) saveDraft()
}

internal fun SaleActivity.openRecallDialog() {
    lifecycleScope.launch {
        val held = viewModel.heldBills()

        val content = LinearLayout(this@openRecallDialog).apply {
            orientation = LinearLayout.VERTICAL
            setBackgroundColor(Color.parseColor(cardBg))
        }
        val dialogHeader = LinearLayout(this@openRecallDialog).apply {
            setPadding(28, 26, 28, 26)
            background = roundedBg(navy, 0)
        }
        dialogHeader.addView(TextView(this@openRecallDialog).apply {
            text = "Held Bills"
            textSize = 18f
            setTextColor(Color.WHITE)
            setTypeface(typeface, android.graphics.Typeface.BOLD)
        })
        content.addView(dialogHeader)

        val list = LinearLayout(this@openRecallDialog).apply {
            orientation = LinearLayout.VERTICAL
            setPadding(24, 18, 24, 16)
        }

        if (held.isEmpty()) {
            list.addView(TextView(this@openRecallDialog).apply {
                text = "Koi held bill nahi hai"
                setTextColor(Color.parseColor(textGray))
                setPadding(8, 20, 8, 20)
            })
        }

        val dialog = AlertDialog.Builder(this@openRecallDialog).setView(content).create()
        val fmt = SimpleDateFormat("dd MMM, hh:mm a", Locale.getDefault())

        for (h in held) {
            val itemCount = h.payload.split("\u0004").getOrNull(1)?.split("\u0002")?.filter { it.isNotEmpty() }?.size ?: 0
            val row = LinearLayout(this@openRecallDialog).apply {
                orientation = LinearLayout.HORIZONTAL
                gravity = Gravity.CENTER_VERTICAL
                setPadding(18, 16, 18, 16)
                background = strokedBg(border, fieldFill, 14)
                layoutParams = LinearLayout.LayoutParams(
                    LinearLayout.LayoutParams.MATCH_PARENT, LinearLayout.LayoutParams.WRAP_CONTENT
                ).apply { setMargins(0, 0, 0, 10) }
            }
            row.addView(circleIcon("\u23F8", amber, 30))
            row.addView(View(this@openRecallDialog).apply { layoutParams = LinearLayout.LayoutParams(12, 1) })
            val info = LinearLayout(this@openRecallDialog).apply {
                orientation = LinearLayout.VERTICAL
                layoutParams = LinearLayout.LayoutParams(0, LinearLayout.LayoutParams.WRAP_CONTENT, 1f)
            }
            info.addView(TextView(this@openRecallDialog).apply {
                text = "$itemCount items"; textSize = 15f
                setTextColor(Color.parseColor(textDark))
                setTypeface(typeface, android.graphics.Typeface.BOLD)
            })
            info.addView(TextView(this@openRecallDialog).apply {
                text = fmt.format(Date(h.createdAt))
                textSize = 12f
                setTextColor(Color.parseColor(textGray))
            })
            row.addView(info)
            row.addView(TextView(this@openRecallDialog).apply {
                text = "RECALL"
                textSize = 12f
                setTextColor(Color.WHITE)
                setTypeface(typeface, android.graphics.Typeface.BOLD)
                background = roundedBg(teal, 20)
                setPadding(22, 10, 22, 10)
                setOnClickListener {
                    decodeHold(h.payload)
                    viewModel.deleteHeldBill(h)
                    dialog.dismiss()
                }
            })
            row.addView(View(this@openRecallDialog).apply { layoutParams = LinearLayout.LayoutParams(10, 1) })
            row.addView(TextView(this@openRecallDialog).apply {
                text = "\u2715"
                textSize = 14f
                setTextColor(Color.WHITE)
                background = ovalBg(red)
                gravity = Gravity.CENTER
                val px = (26 * resources.displayMetrics.density).toInt()
                layoutParams = android.view.ViewGroup.LayoutParams(px, px)
                setOnClickListener {
                    viewModel.deleteHeldBill(h)
                    Toast.makeText(this@openRecallDialog, "Held bill hata di", Toast.LENGTH_SHORT).show()
                    dialog.dismiss()
                }
            })
            list.addView(row)
        }
        content.addView(list)

        content.addView(Button(this@openRecallDialog).apply {
            text = "Close"
            isAllCaps = false
            setTextColor(Color.parseColor(textGray))
            setBackgroundColor(Color.TRANSPARENT)
            setOnClickListener { dialog.dismiss() }
        })

        dialog.show()
    }
}

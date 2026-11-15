package com.grocerypos.v11.ui
import com.grocerypos.v11.SyncQueueHelper

import android.app.AlertDialog
import android.content.ClipData
import android.content.Intent
import android.graphics.Bitmap
import android.graphics.Canvas
import android.graphics.Color
import android.graphics.Typeface
import android.graphics.drawable.GradientDrawable
import android.net.Uri
import android.os.Build
import android.os.Bundle
import android.text.InputType
import android.view.Gravity
import android.view.View
import android.view.ViewOutlineProvider
import android.widget.*
import androidx.appcompat.app.AppCompatActivity
import androidx.core.content.FileProvider
import androidx.lifecycle.lifecycleScope
import com.grocerypos.v11.Customer
import com.grocerypos.v11.PosDatabase
import com.grocerypos.v11.R
import com.grocerypos.v11.data.PartyRepository
import com.grocerypos.v11.util.PrinterHelper
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import kotlinx.coroutines.Dispatchers
import java.io.File
import java.io.FileOutputStream
import java.text.SimpleDateFormat
import java.util.Date
import java.util.Locale
import com.grocerypos.v11.ui.components.*

class BillPreviewActivity : ThemedActivity() {

    companion object {
        const val EXTRA_TYPE = "type"
        const val EXTRA_REFERENCE = "reference"
        const val EXTRA_PARTY_NAME = "party_name"
        const val EXTRA_PARTY_LABEL = "party_label"
        const val EXTRA_PARTY_ID = "party_id"
        const val EXTRA_DATE_MILLIS = "date_millis"
        const val EXTRA_SUBTOTAL = "subtotal"
        const val EXTRA_DISCOUNT = "discount"
        const val EXTRA_TOTAL = "total"
        const val EXTRA_PAID = "paid"
        const val EXTRA_PAYMENT_METHOD = "payment_method"
        const val EXTRA_ITEMS_ENCODED = "items_encoded"
    }

    // NOTE: cardBg/textDark/textGray/border/primary stay fixed — they're the printed
    // receipt paper's own colors (must always look like white paper with dark ink,
    // same as what actually prints/shares via WhatsApp, regardless of app theme).
    // Only the screen's own background (around the paper) follows dark mode.
    private var bg = "#F3F2FA"
    private val cardBg = "#FFFFFF"
    private val primary = "#4A3AFF"
    private val primaryDark = "#3527D6"
    private val green = "#1FA971"
    private val greenDark = "#158A5A"
    private val blue = "#2F6FED"
    private val whatsapp = "#25D366"
    private val whatsappDark = "#1DA851"
    private val textDark = "#1A1A2E"
    private val textGray = "#8A8A9E"
    private val border = "#E7E5F3"

    private fun loadThemeColors() {
        bg = com.grocerypos.v11.util.ThemeManager.palette(this).bg
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

    private data class PreviewLine(val name: String, val qty: String, val unit: String, val rate: Double, val amount: Double)

    // Whole-rupee, comma-grouped amount formatting for the "Gate Pass" print
    // layout (e.g. 266030.0 -> "266,030"), matching the reference wholesaler
    // slip's amount columns, which show no decimal/paisa places.
    // PERMANENT FIX (balance drift — same bug as PurchaseActivity's "Party balance"
    // line): the stored `customer.balance`/`supplier.balance` fields are only ever
    // nudged by SyncQueueHelper's adjust*Balance calls and can drift from the real
    // bills, so a receipt printed/shown here could disagree with the Dashboard for the
    // same party. Compute it fresh from the ledger instead — see PartyRepository.
    private suspend fun liveNetBalance(db: com.grocerypos.v11.PosDatabase, isSale: Boolean, partyId: Long): Double {
        val repo = PartyRepository(db, applicationContext)
        return if (isSale) {
            val c = db.customerDao().find(partyId) ?: return 0.0
            c.openingBalance + repo.liveCustomerBalance(partyId) + c.stuckBalance
        } else {
            val s = db.supplierDao().find(partyId) ?: return 0.0
            s.openingBalance + repo.liveSupplierBalance(partyId)
        }
    }

    private fun formatAmt(v: Double): String =
        java.text.DecimalFormat("#,##0").format(Math.round(v))

    private var shopName = "IBTISAAM Kiryana Store"
    private var shopPhone = ""
    private var shopAddress = ""
    private var receiptFooter = ""

    // ---- state needed for WhatsApp share ----
    private var partyId: Long? = null
    private var referenceNo = ""
    private var totalAmount = 0.0
    private lateinit var receiptCardRef: LinearLayout

    // FIX ("sale ki receipt ma customer ka [total] balance show nahi howa" — this
    // on-screen card (also what gets captured and sent over WhatsApp) only ever
    // showed THIS bill's own Balance Due, never the party's running total — so an
    // opening balance, or dues from earlier bills, was invisible on every new
    // sale's receipt even though it's always included in "You'll Get" on the
    // party's own screen. printReceipt() below already computes this correctly
    // for the physical/thermal print path (Prev Balance / Net Balance); these
    // hold the same inputs so the on-screen card can show the same two rows.
    private var billPaidAmount = 0.0
    private var billType = "sale"

    override fun onCreate(b: Bundle?) {
        super.onCreate(b)
        loadThemeColors()

        val type = intent.getStringExtra(EXTRA_TYPE) ?: "sale"
        val reference = intent.getStringExtra(EXTRA_REFERENCE) ?: ""
        val partyName = intent.getStringExtra(EXTRA_PARTY_NAME) ?: ""
        val partyLabel = intent.getStringExtra(EXTRA_PARTY_LABEL) ?: "Customer"
        val incomingPartyId = intent.getLongExtra(EXTRA_PARTY_ID, -1L)
        partyId = if (incomingPartyId > 0) incomingPartyId else null
        val dateMillis = intent.getLongExtra(EXTRA_DATE_MILLIS, System.currentTimeMillis())
        val subtotal = intent.getDoubleExtra(EXTRA_SUBTOTAL, 0.0)
        val discount = intent.getDoubleExtra(EXTRA_DISCOUNT, 0.0)
        val total = intent.getDoubleExtra(EXTRA_TOTAL, 0.0)
        val paid = intent.getDoubleExtra(EXTRA_PAID, 0.0)
        val paymentMethod = intent.getStringExtra(EXTRA_PAYMENT_METHOD) ?: ""
        val itemsEncoded = intent.getStringExtra(EXTRA_ITEMS_ENCODED) ?: ""

        referenceNo = reference
        totalAmount = total
        billPaidAmount = paid
        billType = type

        val lines = decodeItems(itemsEncoded)
        val isSale = type == "sale"
        val accent = if (isSale) green else "#EF6C00"
        val accentDark = if (isSale) greenDark else "#C4560A"

        val root = LinearLayout(this).apply {
            orientation = LinearLayout.VERTICAL
            setPadding(24, 56, 24, 24)
            setBackgroundColor(Color.parseColor(bg))
        }

        val header = LinearLayout(this).apply {
            orientation = LinearLayout.VERTICAL
            gravity = Gravity.CENTER
            setPadding(26, 26, 26, 26)
            background = GradientDrawable(
                GradientDrawable.Orientation.TL_BR,
                intArrayOf(Color.parseColor(accent), Color.parseColor(accentDark))
            ).apply { cornerRadius = 22f }
            layoutParams = LinearLayout.LayoutParams(
                LinearLayout.LayoutParams.MATCH_PARENT, LinearLayout.LayoutParams.WRAP_CONTENT
            ).apply { setMargins(0, 0, 0, 18) }
            applyElevation(this, 10f)
        }
        header.addView(ImageView(this).apply {
            setImageDrawable(tintedDrawable(R.drawable.ic_check, "#FFFFFF", 32))
            layoutParams = LinearLayout.LayoutParams(LinearLayout.LayoutParams.WRAP_CONTENT, LinearLayout.LayoutParams.WRAP_CONTENT).apply { gravity = Gravity.CENTER }
        })
        header.addView(TextView(this).apply {
            text = if (isSale) "Sale Saved" else "Purchase Saved"
            textSize = 18f
            gravity = Gravity.CENTER
            setTextColor(Color.WHITE)
            setTypeface(typeface, Typeface.BOLD)
            setPadding(0, 8, 0, 0)
        })
        header.addView(TextView(this).apply {
            text = reference
            textSize = 12.5f
            gravity = Gravity.CENTER
            setTextColor(Color.parseColor("#E4F5EC"))
            setPadding(0, 4, 0, 0)
        })
        root.addView(header)

        val receiptCard = LinearLayout(this).apply {
            orientation = LinearLayout.VERTICAL
            setPadding(26, 24, 26, 20)
            background = strokedBg(border, cardBg, 18)
            layoutParams = LinearLayout.LayoutParams(
                LinearLayout.LayoutParams.MATCH_PARENT, LinearLayout.LayoutParams.WRAP_CONTENT
            )
            applyElevation(this, 3f)
        }
        receiptCardRef = receiptCard

        receiptCard.addView(TextView(this).apply {
            text = shopName
            textSize = 17f
            gravity = Gravity.CENTER
            setTextColor(Color.parseColor(textDark))
            setTypeface(typeface, Typeface.BOLD)
            layoutParams = LinearLayout.LayoutParams(LinearLayout.LayoutParams.MATCH_PARENT, LinearLayout.LayoutParams.WRAP_CONTENT)
        }.also { shopNameLine = it })

        receiptCard.addView(TextView(this).apply {
            textSize = 11.5f
            gravity = Gravity.CENTER
            setTextColor(Color.parseColor(textGray))
            setPadding(0, 4, 0, 0)
        }.also { shopSubLine = it })

        receiptCard.addView(dashedDivider())

        val fmt = SimpleDateFormat("dd MMM yyyy, hh:mm a", Locale.getDefault())
        // CHANGE (Gate Pass style header): reordered to Customer / Bill No / Cashier /
        // Date / Payment, matching the wholesaler slip's field order and labels
        // ("Bill No" instead of "Ref", added "Cashier" — the logged-in staff name).
        if (partyName.isNotBlank()) receiptCard.addView(kv(partyLabel, partyName))
        receiptCard.addView(kv("Bill No", reference))
        val cashierName = getSharedPreferences("session", MODE_PRIVATE).getString("username", null)
        if (!cashierName.isNullOrBlank()) receiptCard.addView(kv("Cashier", cashierName))
        receiptCard.addView(kv("Date", fmt.format(Date(dateMillis))))
        if (paymentMethod.isNotBlank()) receiptCard.addView(kv("Payment Method", paymentMethod.replaceFirstChar { it.uppercase() }))

        receiptCard.addView(dashedDivider())

        receiptCard.addView(LinearLayout(this).apply {
            orientation = LinearLayout.HORIZONTAL
            addView(TextView(this@BillPreviewActivity).apply {
                text = "ITEM"; textSize = 11f
                setTextColor(Color.parseColor(textGray))
                setTypeface(typeface, Typeface.BOLD)
                layoutParams = LinearLayout.LayoutParams(0, LinearLayout.LayoutParams.WRAP_CONTENT, 2f)
            })
            addView(TextView(this@BillPreviewActivity).apply {
                text = "AMOUNT"; textSize = 11f; gravity = Gravity.CENTER
                setTextColor(Color.parseColor(textGray))
                setTypeface(typeface, Typeface.BOLD)
                layoutParams = LinearLayout.LayoutParams(0, LinearLayout.LayoutParams.WRAP_CONTENT, 1f)
            })
            addView(TextView(this@BillPreviewActivity).apply {
                text = "QTY"; textSize = 11f; gravity = Gravity.CENTER
                setTextColor(Color.parseColor(textGray))
                setTypeface(typeface, Typeface.BOLD)
                layoutParams = LinearLayout.LayoutParams(0, LinearLayout.LayoutParams.WRAP_CONTENT, 1f)
            })
            addView(TextView(this@BillPreviewActivity).apply {
                text = "RATE"; textSize = 11f; gravity = Gravity.END
                setTextColor(Color.parseColor(textGray))
                setTypeface(typeface, Typeface.BOLD)
                layoutParams = LinearLayout.LayoutParams(0, LinearLayout.LayoutParams.WRAP_CONTENT, 1f)
            })
        })
        receiptCard.addView(spacer(6))

        for (line in lines) {
            receiptCard.addView(LinearLayout(this).apply {
                orientation = LinearLayout.HORIZONTAL
                setPadding(0, 6, 0, 6)
                // Item name sits directly under the ITEM header. TEXT_ALIGNMENT_VIEW_START
                // keeps Urdu names on the left edge too (default alignment flips RTL text
                // to the right side of the cell, away from the ITEM header).
                addView(TextView(this@BillPreviewActivity).apply {
                    text = line.name; textSize = 13.5f
                    setTextColor(Color.parseColor(textDark))
                    setTypeface(typeface, Typeface.BOLD)
                    gravity = Gravity.START
                    textAlignment = View.TEXT_ALIGNMENT_VIEW_START
                    layoutParams = LinearLayout.LayoutParams(0, LinearLayout.LayoutParams.WRAP_CONTENT, 2f)
                })
                addView(TextView(this@BillPreviewActivity).apply {
                    text = "%.2f".format(line.amount); textSize = 13.5f; gravity = Gravity.CENTER
                    setTextColor(Color.parseColor(textDark))
                    setTypeface(typeface, Typeface.BOLD)
                    layoutParams = LinearLayout.LayoutParams(0, LinearLayout.LayoutParams.WRAP_CONTENT, 1f)
                })
                addView(TextView(this@BillPreviewActivity).apply {
                    text = "${line.qty} ${line.unit}"; textSize = 13f; gravity = Gravity.CENTER
                    setTextColor(Color.parseColor(textDark))
                    layoutParams = LinearLayout.LayoutParams(0, LinearLayout.LayoutParams.WRAP_CONTENT, 1f)
                })
                addView(TextView(this@BillPreviewActivity).apply {
                    text = "%.2f".format(line.rate); textSize = 13f; gravity = Gravity.END
                    setTextColor(Color.parseColor(textDark))
                    layoutParams = LinearLayout.LayoutParams(0, LinearLayout.LayoutParams.WRAP_CONTENT, 1f)
                })
            })
        }

        receiptCard.addView(dashedDivider())
        receiptCard.addView(kv("Subtotal", "Rs %.2f".format(subtotal)))
        if (discount > 0) receiptCard.addView(kv("Discount", "- Rs %.2f".format(discount)))
        receiptCard.addView(kv("Total", "Rs %.2f".format(total), bold = true))
        receiptCard.addView(kv("Paid", "Rs %.2f".format(paid)))
        val balance = total - paid
        if (balance > 0.009) receiptCard.addView(kv("Balance Due", "Rs %.2f".format(balance), valueColor = "#C62828"))

        footerLine = TextView(this).apply {
            textSize = 11.5f
            gravity = Gravity.CENTER
            setTextColor(Color.parseColor(textGray))
            setPadding(0, 14, 0, 0)
        }
        receiptCard.addView(footerLine)

        root.addView(receiptCard)
        root.addView(spacer(16))

        // ---- WhatsApp share button (full width, above Print/Done) ----
        root.addView(Button(this).apply {
            text = "WhatsApp par bhejein"
            setLeadingIcon(R.drawable.ic_send, "#FFFFFF", 18, 8)
            setTextColor(Color.WHITE)
            textSize = 14.5f
            isAllCaps = false
            setTypeface(typeface, Typeface.BOLD)
            background = GradientDrawable(
                GradientDrawable.Orientation.LEFT_RIGHT,
                intArrayOf(Color.parseColor(whatsapp), Color.parseColor(whatsappDark))
            ).apply { cornerRadius = 16f }
            setPadding(0, 26, 0, 26)
            applyElevation(this, 4f)
            setOnClickListener { handleWhatsAppShare() }
        })
        root.addView(spacer(12))

        // ---- "Add Another Bill" — lets the user jump straight back into a fresh
        // Purchase/Sale screen instead of finishing all the way to the Dashboard,
        // so entering several bills back-to-back doesn't need a Dashboard round-trip. ----
        if (type == "purchase" || type == "sale") {
            root.addView(Button(this).apply {
                text = if (type == "purchase") "+ NAYA PURCHASE BILL" else "+ NAYI SALE BILL"
                setLeadingIcon(R.drawable.ic_check, "#FFFFFF", 18, 8)
                setTextColor(Color.WHITE)
                textSize = 14.5f
                isAllCaps = false
                setTypeface(typeface, Typeface.BOLD)
                background = GradientDrawable().apply {
                    setColor(Color.parseColor(greenDark))
                    cornerRadius = 16f
                }
                setPadding(0, 26, 0, 26)
                applyElevation(this, 4f)
                setOnClickListener {
                    val next = if (type == "purchase") com.grocerypos.v11.ui.PurchaseActivity::class.java else com.grocerypos.v11.ui.SaleActivity::class.java
                    startActivity(Intent(this@BillPreviewActivity, next))
                    finish()
                }
            })
            root.addView(spacer(12))
        }

        val btnRow = LinearLayout(this).apply { orientation = LinearLayout.HORIZONTAL }
        btnRow.addView(Button(this).apply {
            text = "PRINT"
            setLeadingIcon(R.drawable.ic_printer, "#FFFFFF", 17, 6)
            setTextColor(Color.WHITE)
            textSize = 14.5f
            isAllCaps = false
            setTypeface(typeface, Typeface.BOLD)
            background = GradientDrawable(
                GradientDrawable.Orientation.LEFT_RIGHT,
                intArrayOf(Color.parseColor(blue), Color.parseColor("#1E4FBE"))
            ).apply { cornerRadius = 16f }
            setPadding(0, 26, 0, 26)
            layoutParams = LinearLayout.LayoutParams(0, LinearLayout.LayoutParams.WRAP_CONTENT, 1f).apply { setMargins(0, 0, 8, 0) }
            applyElevation(this, 4f)
            setOnClickListener { printReceipt(type, reference, partyName, partyLabel, dateMillis, lines, subtotal, discount, total, paid, paymentMethod) }
        })
        btnRow.addView(Button(this).apply {
            text = "DONE"
            setLeadingIcon(R.drawable.ic_check, "#FFFFFF", 17, 6)
            setTextColor(Color.WHITE)
            textSize = 14.5f
            isAllCaps = false
            setTypeface(typeface, Typeface.BOLD)
            background = GradientDrawable(
                GradientDrawable.Orientation.LEFT_RIGHT,
                intArrayOf(Color.parseColor(primary), Color.parseColor(primaryDark))
            ).apply { cornerRadius = 16f }
            setPadding(0, 26, 0, 26)
            layoutParams = LinearLayout.LayoutParams(0, LinearLayout.LayoutParams.WRAP_CONTENT, 1f).apply { setMargins(8, 0, 0, 0) }
            applyElevation(this, 4f)
            setOnClickListener { finish() }
        })
        root.addView(btnRow)
        root.addView(spacer(30))

        setContentView(ScrollView(this).apply {
            setBackgroundColor(Color.parseColor(bg))
            addView(root)
        })

        loadShopInfo()
    }

    private lateinit var shopNameLine: TextView
    private lateinit var shopSubLine: TextView
    private lateinit var footerLine: TextView

    private fun loadShopInfo() {
        lifecycleScope.launch {
            val db = PosDatabase.get(this@BillPreviewActivity)
            shopName = db.appSettingDao().get("shop_name")?.value?.ifBlank { shopName } ?: shopName
            shopPhone = db.appSettingDao().get("shop_phone")?.value ?: ""
            shopAddress = db.appSettingDao().get("shop_address")?.value ?: ""
            receiptFooter = db.appSettingDao().get("receipt_footer")?.value ?: ""

            shopNameLine.text = shopName
            val subParts = listOfNotNull(
                shopAddress.takeIf { it.isNotBlank() },
                shopPhone.takeIf { it.isNotBlank() }?.let { "📞 $it" }
            )
            shopSubLine.text = subParts.joinToString("  •  ")
            footerLine.text = receiptFooter.ifBlank { "Shukriya! Dobara tashreef layein." }

            // FIX (see billPaidAmount/billType note above): same Prev Balance / Net
            // Balance rows the printed receipt already shows, now added to the
            // on-screen card too — so it also shows in the WhatsApp bitmap, which is
            // captured straight from this card.
            val pid = partyId
            if (pid != null) {
                val netBalance = liveNetBalance(db, billType == "sale", pid)
                val prevBalance = netBalance - (totalAmount - billPaidAmount)
                val insertAt = receiptCardRef.indexOfChild(footerLine)
                receiptCardRef.addView(kv("Prev Balance", "Rs %.2f".format(prevBalance)), insertAt)
                receiptCardRef.addView(
                    kv("Net Balance", "Rs %.2f".format(netBalance), bold = true, valueColor = if (netBalance > 0.009) "#C62828" else textDark),
                    insertAt + 1
                )
            }
        }
    }

    // ================= WhatsApp share =================

    private fun handleWhatsAppShare() {
        val pid = partyId
        if (pid == null) {
            // Walk-in / no linked customer — just ask for a number, nothing to save to.
            promptForPhoneAndShare(saveToCustomerId = null)
            return
        }
        lifecycleScope.launch {
            val db = PosDatabase.get(this@BillPreviewActivity)
            val customer = db.customerDao().find(pid)
            val phone = customer?.phone?.trim() ?: ""
            if (phone.isNotBlank()) {
                shareBitmapToWhatsApp(phone)
            } else {
                promptForPhoneAndShare(saveToCustomerId = pid)
            }
        }
    }

    private fun promptForPhoneAndShare(saveToCustomerId: Long?) {
        val container = LinearLayout(this).apply {
            orientation = LinearLayout.VERTICAL
            setPadding(48, 32, 48, 8)
        }
        val phoneInput = EditText(this).apply {
            hint = "Customer ka number (e.g. 03001234567)"
            inputType = InputType.TYPE_CLASS_PHONE
        }
        container.addView(phoneInput)

        var saveCheckbox: CheckBox? = null
        if (saveToCustomerId != null) {
            container.addView(spacer(10))
            saveCheckbox = CheckBox(this).apply {
                text = "Number save karein future ke liye"
                isChecked = true
            }
            container.addView(saveCheckbox)
        }

        AlertDialog.Builder(this)
            .setTitle("WhatsApp Number")
            .setView(container)
            .setPositiveButton("Bhejein") { d, _ ->
                val phone = phoneInput.text.toString().trim()
                if (phone.length < 7) {
                    Toast.makeText(this, "Sahi number likhein", Toast.LENGTH_SHORT).show()
                    return@setPositiveButton
                }
                if (saveToCustomerId != null && saveCheckbox?.isChecked == true) {
                    lifecycleScope.launch {
                        val db = PosDatabase.get(this@BillPreviewActivity)
                        val customer = db.customerDao().find(saveToCustomerId)
                        if (customer != null) {
                            val updated = customer.copy(phone = phone)
                            db.customerDao().update(updated)
                            SyncQueueHelper.enqueueCustomer(db, updated, this@BillPreviewActivity)
                        }
                        shareBitmapToWhatsApp(phone)
                    }
                } else {
                    shareBitmapToWhatsApp(phone)
                }
                d.dismiss()
            }
            .setNegativeButton("Cancel", null)
            .show()
    }

    // FIX (WhatsApp direct-chat): the old "jid" extra on ACTION_SEND was an
    // undocumented trick that newer WhatsApp builds ignore — it just falls back to
    // WhatsApp's normal contact/share picker, so the user still has to pick the
    // number by hand every time even though one was already entered/saved. There is
    // no officially supported way to attach an image AND jump straight to a chosen
    // number in one shot (Meta blocks that for abuse/privacy reasons), so this is a
    // two-step flow instead: (1) save the receipt to the gallery and (2) open the
    // chat for that exact number directly via wa.me (this part is official and
    // reliable) with the caption pre-filled. The user only has to tap the 📎 attach
    // button once and pick the (already-saved, easy to find) receipt image — no more
    // picking a contact.
    private fun shareBitmapToWhatsApp(rawPhone: String) {
        val bitmap = viewToBitmap(receiptCardRef)
        val digits = cleanPhoneToDigits(rawPhone)
        val caption = "Invoice: $referenceNo\nTotal: Rs %.2f\nShukriya!".format(totalAmount)

        val savedToGallery = try {
            saveBitmapToGallery(bitmap)
            true
        } catch (e: Exception) {
            false
        }

        val waIntent = Intent(Intent.ACTION_VIEW).apply {
            data = Uri.parse("https://wa.me/$digits?text=${Uri.encode(caption)}")
            setPackage("com.whatsapp")
        }

        try {
            startActivity(waIntent)
            val msg = if (savedToGallery)
                "Chat khul gaya. Neeche 📎 se Gallery mein receipt image select kar lein."
            else
                "Chat khul gaya, lekin image save nahi ho saki — dobara try karein."
            Toast.makeText(this, msg, Toast.LENGTH_LONG).show()
        } catch (e: Exception) {
            // WhatsApp not installed (or wa.me couldn't be opened) — fall back to the
            // generic share sheet so the bill can still be sent some other way.
            try {
                val uri = bitmapToShareUri(bitmap)
                val clip = ClipData.newUri(contentResolver, "receipt", uri)
                val fallback = Intent(Intent.ACTION_SEND).apply {
                    type = "image/png"
                    putExtra(Intent.EXTRA_STREAM, uri)
                    putExtra(Intent.EXTRA_TEXT, caption)
                    clipData = clip
                    addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
                }
                startActivity(Intent.createChooser(fallback, "Bill share karein"))
            } catch (e2: Exception) {
                Toast.makeText(this, "Share nahi ho saka. WhatsApp installed hai?", Toast.LENGTH_LONG).show()
            }
        }
    }

    /** Cleans an entered number into bare digits with a country code, e.g. "923001234567".
     *  Assumes Pakistan (92) if no country code was entered — adjust the default
     *  country code below if this shop is in a different country. */
    private fun cleanPhoneToDigits(raw: String): String {
        var digits = raw.replace(Regex("[^0-9]"), "")
        if (digits.startsWith("0")) digits = "92" + digits.substring(1)
        else if (!digits.startsWith("92") && digits.length <= 10) digits = "92$digits"
        return digits
    }

    /** Saves the receipt bitmap into the device's Pictures/IBTISAAM gallery folder so
     *  it's easy to find from WhatsApp's own attach picker (📎 → Gallery). */
    private fun saveBitmapToGallery(bitmap: Bitmap): Uri {
        val filename = "Receipt_${referenceNo}_${System.currentTimeMillis()}.png"
        val resolver = contentResolver
        val values = android.content.ContentValues().apply {
            put(android.provider.MediaStore.Images.Media.DISPLAY_NAME, filename)
            put(android.provider.MediaStore.Images.Media.MIME_TYPE, "image/png")
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
                put(android.provider.MediaStore.Images.Media.RELATIVE_PATH, "Pictures/IBTISAAM")
            }
        }
        val uri = resolver.insert(android.provider.MediaStore.Images.Media.EXTERNAL_CONTENT_URI, values)
            ?: throw IllegalStateException("MediaStore insert failed")
        resolver.openOutputStream(uri)?.use { out ->
            bitmap.compress(Bitmap.CompressFormat.PNG, 100, out)
        } ?: throw IllegalStateException("Could not open output stream")
        return uri
    }

    private fun viewToBitmap(view: View): Bitmap {
        val bitmap = Bitmap.createBitmap(
            view.width.coerceAtLeast(1),
            view.height.coerceAtLeast(1),
            Bitmap.Config.ARGB_8888
        )
        val canvas = Canvas(bitmap)
        canvas.drawColor(Color.WHITE)
        view.draw(canvas)
        return bitmap
    }

    private fun bitmapToShareUri(bitmap: Bitmap): Uri {
        val dir = File(cacheDir, "receipts").apply { mkdirs() }
        val file = File(dir, "bill_${System.currentTimeMillis()}.png")
        FileOutputStream(file).use { out -> bitmap.compress(Bitmap.CompressFormat.PNG, 100, out) }
        return FileProvider.getUriForFile(this, "$packageName.fileprovider", file)
    }

    // ================= Thermal print =================

    // FIX ("Print b aesa hi aye b" — the physical print must match the on-screen
    // Bill Preview card SECTION-FOR-SECTION, not the older "Gate Pass" wholesaler-
    // slip layout that used to print here): rebuilt to walk the exact same fields
    // in the exact same order as the on-screen card above (shopName / shopSubLine
    // → Customer/Bill No/Cashier/Date/Payment Method → ITEM|AMOUNT|QTY|RATE table
    // → Subtotal/Discount/Total/Paid/Balance Due → Prev Balance/Net Balance →
    // footer), using the new PrinterHelper.ReceiptLine.PreviewItemRow for the item
    // rows so each one lines up ITEM(bold)/AMOUNT(bold)/QTY/RATE with the same
    // 2:1:1:1 column split the on-screen card uses. No more separate "Gate Pass"
    // formatting (Gross Amount/Payable/Amount Paid/Barcode column) — that whole
    // section is gone so print and screen never drift apart again.
    private fun printReceipt(
        type: String, reference: String, partyName: String, partyLabel: String,
        dateMillis: Long, lines: List<PreviewLine>, subtotal: Double, discount: Double,
        total: Double, paid: Double, paymentMethod: String
    ) {
        lifecycleScope.launch {
            val db = PosDatabase.get(this@BillPreviewActivity)
            val mac = db.appSettingDao().get("printer_mac")?.value
            if (mac.isNullOrEmpty()) {
                Toast.makeText(this@BillPreviewActivity, "Pehle Settings mein printer select karein", Toast.LENGTH_LONG).show()
                return@launch
            }
            val printerType = when (db.appSettingDao().get("printer_type")?.value?.lowercase()) {
                "usb" -> PrinterHelper.PrinterType.USB
                else -> PrinterHelper.PrinterType.BLUETOOTH
            }

            // Per-device print-head width (Settings > Printer > PRINT WIDTH); safe 384 default.
            val dotsWidth = PrinterHelper.normalizeDotsWidth(
                db.appSettingDao().get("printer_dots")?.value?.toIntOrNull()
            )

            // Same date format the on-screen card uses (fmt in onCreate above).
            val fmt = SimpleDateFormat("dd MMM yyyy, hh:mm a", Locale.getDefault())

            // FIX ("bill lamba ho tu split kaise ho ga, total kaise ho ga" — a long
            // multi-item bill needs to tear off as multiple slips instead of one
            // giant unbroken roll): the receipt is now built as three SEPARATE lists
            // — header, item rows, footer/totals — instead of one flat list, so
            // PrinterHelper.printReceiptLinesPaged can repeat the header on every
            // slip, paginate only the item rows, and print Subtotal/Total/Paid/
            // Balance ONLY on the final slip (a running partial total on earlier
            // slips would be misleading). Short bills print exactly as before —
            // pagination only kicks in past DEFAULT_MAX_ITEMS_PER_PAGE rows.
            val headerLines = mutableListOf<PrinterHelper.ReceiptLine>()
            val itemLines = mutableListOf<PrinterHelper.ReceiptLine>()
            val footerLines = mutableListOf<PrinterHelper.ReceiptLine>()

            // ---- Shop header: name (bold) + "address • 📞 phone" sub-line, same
            // as shopNameLine/shopSubLine on screen. ----
            headerLines.add(PrinterHelper.ReceiptLine.Center(shopName, bold = true, tight = true))
            val subParts = listOfNotNull(
                shopAddress.takeIf { it.isNotBlank() },
                shopPhone.takeIf { it.isNotBlank() }?.let { "📞 $it" }
            )
            if (subParts.isNotEmpty()) {
                headerLines.add(PrinterHelper.ReceiptLine.Center(subParts.joinToString("  •  "), tight = true))
            }
            headerLines.add(PrinterHelper.ReceiptLine.Divider)

            // ---- Customer / Bill No / Cashier / Date / Payment Method — same
            // order and labels as the on-screen kv() rows. ----
            if (partyName.isNotBlank()) headerLines.add(PrinterHelper.ReceiptLine.TwoCol(partyLabel, partyName, tight = true))
            headerLines.add(PrinterHelper.ReceiptLine.TwoCol("Bill No", reference, tight = true))
            val cashierName = getSharedPreferences("session", MODE_PRIVATE).getString("username", null)
            if (!cashierName.isNullOrBlank()) headerLines.add(PrinterHelper.ReceiptLine.TwoCol("Cashier", cashierName, tight = true))
            headerLines.add(PrinterHelper.ReceiptLine.TwoCol("Date", fmt.format(Date(dateMillis)), tight = true))
            if (paymentMethod.isNotBlank()) {
                headerLines.add(
                    PrinterHelper.ReceiptLine.TwoCol("Payment Method", paymentMethod.replaceFirstChar { it.uppercase() }, tight = true)
                )
            }
            headerLines.add(PrinterHelper.ReceiptLine.Divider)

            // ---- Item table: ITEM / AMOUNT / QTY / RATE — same header labels,
            // order and column weights as the on-screen table. itemLines[0] is the
            // table header row itself; printReceiptLinesPaged repeats it on every
            // slip and paginates only the rows after it. ----
            // Wider QTY column ("0.5 Quarter") + slightly narrower ITEM, for the larger table font.
            // Logical order: name / amount / qty / rate.
            val previewWeights = listOf(1.7f, 1f, 1.3f, 1f)
            // Mirrored (Urdu-bill style): visually AMOUNT | RATE | QTY | ITEM.
            itemLines.add(
                PrinterHelper.ReceiptLine.PreviewItemRow(
                    name = "ITEM", amount = "AMOUNT", qty = "QTY", rate = "RATE",
                    weights = previewWeights, mirrored = true
                )
            )
            for (line in lines) {
                itemLines.add(
                    PrinterHelper.ReceiptLine.PreviewItemRow(
                        name = line.name,
                        amount = "%.2f".format(line.amount),
                        qty = "${line.qty} ${line.unit}",
                        rate = "%.2f".format(line.rate),
                        weights = previewWeights,
                        mirrored = true
                    )
                )
            }
            footerLines.add(PrinterHelper.ReceiptLine.Divider)

            // ---- Totals: Subtotal / Discount / Total / Paid / Balance Due — same
            // as the on-screen card. Printed only on the LAST slip. ----
            footerLines.add(PrinterHelper.ReceiptLine.TwoCol("Subtotal", "Rs %.2f".format(subtotal), tight = true))
            if (discount > 0) footerLines.add(PrinterHelper.ReceiptLine.TwoCol("Discount", "- Rs %.2f".format(discount), tight = true))
            footerLines.add(PrinterHelper.ReceiptLine.TwoCol("Total", "Rs %.2f".format(total), bold = true, tight = true))
            footerLines.add(PrinterHelper.ReceiptLine.TwoCol("Paid", "Rs %.2f".format(paid), tight = true))
            val balanceDue = total - paid
            if (balanceDue > 0.009) {
                footerLines.add(PrinterHelper.ReceiptLine.TwoCol("Balance Due", "Rs %.2f".format(balanceDue), tight = true))
            }

            // Prev/Net balance come from the party's running ledger balance (already
            // updated to post-transaction by the time this prints), same as the
            // on-screen card's loadShopInfo() insert. Walk-in/cash sales with no
            // linked party have no ledger, so both are omitted for them.
            val pid = partyId
            if (pid != null) {
                val netBalance = liveNetBalance(db, type == "sale", pid)
                val prevBalance = netBalance - (total - paid)
                footerLines.add(PrinterHelper.ReceiptLine.TwoCol("Prev Balance", "Rs %.2f".format(prevBalance), tight = true))
                footerLines.add(PrinterHelper.ReceiptLine.TwoCol("Net Balance", "Rs %.2f".format(netBalance), bold = true, tight = true))
            } else if (balanceDue > 0.009) {
                // Walk-in / no linked party: there is no ledger, so the previous balance is
                // Rs 0 and the net balance is just this bill's own due amount.
                footerLines.add(PrinterHelper.ReceiptLine.TwoCol("Prev Balance", "Rs %.2f".format(0.0), tight = true))
                footerLines.add(PrinterHelper.ReceiptLine.TwoCol("Net Balance", "Rs %.2f".format(balanceDue), bold = true, tight = true))
            }
            footerLines.add(PrinterHelper.ReceiptLine.Divider)
            footerLines.add(PrinterHelper.ReceiptLine.Center(receiptFooter.ifBlank { "Shukriya! Dobara tashreef layein." }))

            // FIX ("print button kaam nahi kar raha, bari late... print bej dia
            // lekin print nahi aata"): the Bluetooth connect/write/Thread.sleep
            // pacing loop in PrinterHelper was running on the Main/UI thread (this
            // whole lifecycleScope.launch block defaults to Dispatchers.Main), which
            // was tolerable at the old faster chunk timing but became long enough
            // with the slower/safer anti-garble timing to stall the UI thread badly
            // enough that the transmission silently failed partway through even
            // though printReceiptLines still returned true. Moved to Dispatchers.IO
            // so the print job runs off the UI thread.
            // FIX ("split ka koi faida nahi howa, page lamba hi print howa, bs
            // header wagera extra add howe ha"): this printer's cutter is manual
            // (hath se phaarna parta hai), not motorized, so the GS V cut command
            // printReceiptLinesPaged sends between slips is silently ignored —
            // there is no physical break in the roll. The paged call still adds a
            // repeated header, repeated table header, and "Page X of Y / Continued"
            // lines for every slip, so on this printer it only made the single
            // continuous strip longer with no actual splitting benefit. Reverted to
            // one flat print: header + items + footer, no pagination.
            val ok = withContext(Dispatchers.IO) {
                PrinterHelper.printReceiptLines(
                    this@BillPreviewActivity,
                    printerType,
                    mac,
                    headerLines + itemLines + footerLines,
                    dotsWidth = dotsWidth
                )
            }
            Toast.makeText(
                this@BillPreviewActivity,
                if (ok) "Print bhej diya" else "Print fail ho gaya. Printer check karein.",
                Toast.LENGTH_LONG
            ).show()
        }
    }

    private fun decodeItems(encoded: String): List<PreviewLine> {
        if (encoded.isBlank()) return emptyList()
        return encoded.split("\u0002").mapNotNull { row ->
            val f = row.split("\u0003")
            if (f.size >= 5) {
                PreviewLine(
                    name = f[0],
                    qty = f[1],
                    unit = f[2],
                    rate = f[3].toDoubleOrNull() ?: 0.0,
                    amount = f[4].toDoubleOrNull() ?: 0.0
                )
            } else null
        }
    }

    private fun kv(label: String, value: String, bold: Boolean = false, valueColor: String? = null) = LinearLayout(this).apply {
        orientation = LinearLayout.HORIZONTAL
        setPadding(0, 5, 0, 5)
        addView(TextView(this@BillPreviewActivity).apply {
            text = label; textSize = if (bold) 14.5f else 13f
            setTextColor(Color.parseColor(if (bold) textDark else textGray))
            if (bold) setTypeface(typeface, Typeface.BOLD)
            layoutParams = LinearLayout.LayoutParams(0, LinearLayout.LayoutParams.WRAP_CONTENT, 1f)
        })
        addView(TextView(this@BillPreviewActivity).apply {
            text = value; textSize = if (bold) 14.5f else 13f
            setTextColor(Color.parseColor(valueColor ?: textDark))
            setTypeface(typeface, if (bold) Typeface.BOLD else Typeface.NORMAL)
            gravity = Gravity.END
        })
    }

    private fun dashedDivider() = View(this).apply {
        setBackgroundColor(Color.parseColor(border))
        layoutParams = LinearLayout.LayoutParams(LinearLayout.LayoutParams.MATCH_PARENT, 2).apply {
            setMargins(0, 12, 0, 12)
        }
    }

    // spacer() now comes from the shared UiHelpers.kt (item #24 dedup) — was a
    // byte-identical private copy here before.
}

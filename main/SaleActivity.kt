package com.grocerypos.v11.ui

import android.app.DatePickerDialog
import android.content.Context
import android.content.Intent
import com.grocerypos.v11.R
import com.grocerypos.v11.util.keepContentAboveKeyboard
import com.grocerypos.v11.util.parseMoneyOrWarn
import android.graphics.Color
import android.graphics.drawable.GradientDrawable
import android.os.Build
import android.os.Bundle
import android.text.Editable
import android.text.InputType
import android.text.TextWatcher
import android.view.Gravity
import android.view.KeyEvent
import android.view.View
import android.view.ViewGroup
import android.view.ViewOutlineProvider
import android.view.WindowManager
import android.view.inputmethod.EditorInfo
import android.view.inputmethod.InputMethodManager
import android.widget.*
import androidx.activity.viewModels
import androidx.appcompat.widget.PopupMenu
import androidx.appcompat.app.AlertDialog
import androidx.appcompat.app.AppCompatActivity
import androidx.lifecycle.lifecycleScope
import com.grocerypos.v11.*
import com.grocerypos.v11.domain.SaleLine
import com.grocerypos.v11.pricing.DiscountCalculator
import kotlinx.coroutines.flow.collectLatest
import kotlinx.coroutines.launch
import org.json.JSONArray
import org.json.JSONObject
import java.text.SimpleDateFormat
import java.util.Calendar
import java.util.Date
import java.util.Locale
import com.grocerypos.v11.ui.components.*

class SaleActivity : AppCompatActivity() {

    internal val viewModel: SaleViewModel by viewModels { SaleViewModelFactory(applicationContext) }

    companion object {
        const val EXTRA_INVOICE = "invoice"
        // ---- ADDED (dashboard "Quick Sale" card): when this extra is true, the
        // Quick Sale dialog opens immediately on launch — lets MainActivity's
        // dashboard jump straight into it instead of the full New Sale screen. ----
        const val EXTRA_OPEN_QUICK_SALE = "open_quick_sale"
        private const val PREFS_NAME = "sale_draft_prefs"
        private const val KEY_DRAFT = "draft_json"

        // ---- CHANGED (category-based unit auto-select): category name compared
        // case-insensitively against Product.category for 2-tier products. ----
        internal const val BEVERAGE_CATEGORY = "Beverages"
    }

    // ---------- Palette (Reports-style flat design — pulled from ThemeManager so this
    // screen also respects dark mode and stays in sync with the rest of the app).
    // CHANGED (user asked: main brand color across Sale/Purchase/Items/Settings/
    // Reports should match the "Today's profit" blue on the dashboard): header/
    // Save Sale/totals now use flatBlueFg. `teal`/`green` stay teal — that's the
    // app's separate "positive amount" (paid/due) semantic, not the brand accent.
    // `red` stays available separately for genuine errors/warnings. ----------
    internal var bg = "#F4F6F8"
    internal var cardBg = "#FFFFFF"
    internal var fieldFill = "#FAFBFD"
    internal var navy = "#1450C7"       // header/brand accent — profit blue, matches Purchase/Items/Settings/Reports
    internal var navyLight = "#1450C7"  // flat design, no gradient — same as navy
    internal var teal = "#0A8A4E"       // flatTealFg — secondary accent / positive amounts
    internal var green = "#0A8A4E"      // flatTealFg — unified with Reports' "positive" color
    internal var greenDark = "#0A8A4E"  // flat design, no gradient — same as green
    internal var red = "#D32F4A"
    internal var redDark = "#A81F39"
    internal var amber = "#854F0B"      // flatAmberFg
    internal var amberBg = "#FAEEDA"    // flatAmberBg
    internal var textDark = "#0B2545"
    internal var textGray = "#7C8798"
    internal var border = "#E3E8EE"

    private fun loadThemeColors() {
        val p = com.grocerypos.v11.util.ThemeManager.palette(this)
        bg = p.bg
        cardBg = p.cardWhite
        fieldFill = p.fieldFill
        navy = p.flatBlueFg
        navyLight = p.flatBlueFg
        teal = p.flatTealFg
        green = p.flatTealFg
        greenDark = p.flatTealFg
        red = p.red
        amber = p.flatAmberFg
        amberBg = p.flatAmberBg
        textDark = p.textDark
        textGray = p.textMuted
        border = p.border
    }

    internal lateinit var dateValueText: TextView
    private lateinit var firmNameText: TextView
    private lateinit var customerBox: LinearLayout
    internal lateinit var customerName: AutoCompleteTextView
    internal lateinit var saleTypeSpinner: Spinner
    private lateinit var itemEntrySection: LinearLayout
    internal lateinit var itemName: AutoCompleteTextView
    internal lateinit var qty: EditText
    internal lateinit var unitSpinner: Spinner
    internal lateinit var unitToggleRow: LinearLayout
    internal lateinit var unitPrice: EditText
    // NEW (Buy-by-amount — "customer mangta hai Rs 100 ki cheez"): lets the
    // shopkeeper type a Rupee amount instead of a weight/qty and have the app
    // work out the quantity, instead of doing amount÷rate by hand for every
    // sugar/rice/loose-item sale. See addItem()/updateItemLineTotal() in
    // SaleCart.kt.
    internal lateinit var amountModeToggle: TextView
    internal var qtyIsAmountMode = false
    // NEW ("10/10 Sale screen" — loss protection, mirrors PurchaseActivity's
    // updateMarginWarning()): warns live if the rate being typed is at or below
    // this item's cost, instead of that only being discoverable later in reports.
    internal lateinit var marginWarningText: TextView
    // NEW: shows when this item's price was auto-filled from a customer's own
    // rate history (e.g. "Ahmed Store ka pichla rate: Rs 80 laga diya gaya")
    // instead of the standard retail/wholesale price.
    internal lateinit var customerRateHint: TextView
    internal lateinit var conversionInfo: TextView
    internal lateinit var itemLineTotalText: TextView
    // ---- ADDED (Billed Items inline edit — brings Sale up to Purchase's existing
    // pattern): ✎ on a billed line refills the entry fields instead of only
    // allowing delete-and-retype. ----
    internal lateinit var addItemButton: Button
    internal lateinit var cancelEditButton: TextView
    internal var editingLineIndex: Int? = null
    internal lateinit var itemsContainer: LinearLayout
    private lateinit var billedItemsHeader: LinearLayout
    internal lateinit var billedItemsTrigger: TextView
    private lateinit var billedItemsChevron: TextView
    internal var billedItemsDialog: AlertDialog? = null
    internal lateinit var subtotalText: TextView
    internal lateinit var discountInput: EditText
    internal lateinit var totalText: TextView
    internal lateinit var paymentSection: LinearLayout
    internal lateinit var paidInput: EditText
    internal lateinit var paidWarningText: TextView
    internal lateinit var paymentMethodSpinner: Spinner
    // NEW (Split Payment / multiple payment methods): "Split Payment" link under
    // the single-method spinner, and the summary line ("Split: Cash Rs300 + Bank
    // Rs200 ✕") that replaces the spinner once a split is applied.
    internal lateinit var splitPaymentLink: TextView
    internal lateinit var splitPaymentSummary: TextView
    // Source of truth for a split-tender sale — each entry is (method, amount).
    // Empty means "single method", using paymentMethodSpinner + paidInput exactly
    // as before this feature existed.
    internal var splitPayments: MutableList<Pair<String, Double>> = mutableListOf()
    internal lateinit var dueAmountText: TextView
    private lateinit var saveButton: Button
    private lateinit var deleteButton: Button
    private lateinit var overflowButton: TextView
    internal lateinit var scrollView: ScrollView

    internal var customers = listOf<Customer>()
    internal var products = listOf<Product>()
    internal val lines = mutableListOf<SaleLine>()
    internal var selectedProduct: Product? = null
    internal var isCashSale = true
    internal var saleDateMillis = System.currentTimeMillis()

    // ---- ADDED (tablet / commercial "desktop view"): on wide screens (tablets,
    // and phones in landscape past ~700dp) the cart/billing section becomes a
    // separate right-hand pane that stays visible at all times, instead of
    // being reached only through the "Billed Items" popup dialog — closer to
    // how a computer-based POS screen is laid out. Phones keep the original
    // single-column, dialog-based flow untouched. ----
    internal var isTabletWide = false

    internal var editInvoice: String? = null
    private var originalSale: Sale? = null
    private var originalItems: List<SaleItem> = emptyList()
    // NEW (double-tap / accidental double-entry guard, mirrors PurchaseActivity):
    // isSaving blocks a second saveSale() while the first save is still in flight
    // (fast double-tap on Save), and checkDuplicateAndProceed() below catches the
    // slower case — the same bill genuinely saved twice a few minutes apart.
    private var isSaving = false

    // NEW (10/10 Priority #7 — Credit Limit + Due Management): stashes the exact
    // Quick Sale inputs so SaleEvent.QuickSaleCreditLimitExceeded's confirm
    // dialog (handleSaleEvent, below) can re-submit them with
    // overrideCreditLimit=true — the Quick Sale dialog itself is already
    // dismissed by the time that event arrives, so this can't just re-read its
    // fields.
    internal data class PendingQuickSale(val product: Product, val qty: Double, val price: Double, val unit: String, val customerName: String)
    internal var pendingQuickSale: PendingQuickSale? = null

    internal var lastMainPrice: Double = 0.0
    // FIX (sale-type keyboard-scroll bug): hasFocus() was unreliable right after a
    // touch-driven Spinner selection on some OEM keyboards (e.g. Samsung), so the
    // scroll-to-top / focus-Item-Name step below would silently skip. This flag is
    // set true the instant the spinner is actually touched, so the scroll/focus no
    // longer depends on focus state — it fires on every real user selection, but not
    // on the automatic first-item callback Android fires when the adapter is set.
    private var saleTypeUserInteracted = false
    internal var suppressPriceWatcher = false
    private var suppressPaidWatcher = false

    private var suppressDraftSave = false
    private var draftRestored = false

    override fun onCreate(b: Bundle?) {
        super.onCreate(b)
        editInvoice = intent.getStringExtra(EXTRA_INVOICE)

        // FIX (#11 — SaleActivity direct edit protection): New Sale stays open to
        // cashier (reasonable — that's their normal job), but Edit/Delete Sale is
        // admin-only per the app's role rules. Without this check, a cashier could
        // reach this same screen with EXTRA_INVOICE set (e.g. via Sale History) and
        // edit/delete an existing bill despite MainActivity only exposing that
        // action to admin — MainActivity hiding a button doesn't stop the Activity
        // itself being opened another way. Same pattern as ProductActivity/
        // PurchaseActivity/UserManagementActivity's role checks.
        if (editInvoice != null) {
            val myRole = getSharedPreferences("session", MODE_PRIVATE).getString("role", "cashier") ?: "cashier"
            if (myRole != "admin") {
                Toast.makeText(this, "Sirf Admin sale edit/delete kar sakte hain", Toast.LENGTH_LONG).show()
                finish()
                return
            }
        }

        window.setSoftInputMode(WindowManager.LayoutParams.SOFT_INPUT_ADJUST_RESIZE)
        loadThemeColors()

        // ---- ADDED (tablet / desktop-style layout): 700dp roughly matches a
        // 9"+ tablet in either orientation, while keeping ordinary phones
        // (even large ones, even rotated) on the original single-column flow.
        // Tune this number in one place if a specific tablet needs a different
        // breakpoint. ----
        isTabletWide = resources.configuration.screenWidthDp >= 700

        val root = LinearLayout(this).apply {
            orientation = LinearLayout.VERTICAL
            setPadding(24, 0, 24, 80)
            setBackgroundColor(Color.parseColor(bg))
        }

        // ---------- Header (Reports-style flat header — flatPurple, no gradient) ----------
        val header = LinearLayout(this).apply {
            orientation = LinearLayout.HORIZONTAL
            gravity = Gravity.CENTER_VERTICAL
            setPadding(26, 30, 22, 26)
            background = gradientBg(navy, navy, cornerBottom = 26)
            layoutParams = LinearLayout.LayoutParams(LinearLayout.LayoutParams.MATCH_PARENT, LinearLayout.LayoutParams.WRAP_CONTENT).apply { setMargins(-24, 0, -24, 16) }
            applyElevation(this, 8f)
        }
        val headerCol = LinearLayout(this).apply {
            orientation = LinearLayout.VERTICAL
            layoutParams = LinearLayout.LayoutParams(0, LinearLayout.LayoutParams.WRAP_CONTENT, 1f)
        }
        headerCol.addView(TextView(this).apply {
            text = if (editInvoice != null) com.grocerypos.v11.util.Loc.t(this@SaleActivity, "Edit Sale", "سیل میں ترمیم") else com.grocerypos.v11.util.Loc.t(this@SaleActivity, "New Sale", "نئی سیل")
            textSize = 20f
            setTextColor(Color.WHITE)
            setTypeface(typeface, android.graphics.Typeface.BOLD)
            letterSpacing = 0.01f
        })
        headerCol.addView(TextView(this).apply {
            text = "RETAIL · WHOLESALE BILLING"
            textSize = 10.5f
            setTextColor(Color.parseColor("#9FB4CC"))
            setTypeface(typeface, android.graphics.Typeface.BOLD)
            letterSpacing = 0.08f
            setPadding(0, 5, 0, 0)
        })
        header.addView(headerCol)
        header.addView(pillChip("Quick Sale", textSizeSp = 13.5f, hPad = 24, vPad = 14) { quickSaleDialog() })
        header.addView(spacer(8).apply { layoutParams = LinearLayout.LayoutParams((6 * resources.displayMetrics.density).toInt(), 1) })
        header.addView(pillChip("History", textSizeSp = 13.5f, hPad = 24, vPad = 14) { startActivity(Intent(this@SaleActivity, SaleHistoryActivity::class.java)) })
        header.addView(spacer(8).apply { layoutParams = LinearLayout.LayoutParams((6 * resources.displayMetrics.density).toInt(), 1) })
        overflowButton = TextView(this).apply {
            text = "\u22EE"
            textSize = 19f
            setTextColor(Color.WHITE)
            gravity = Gravity.CENTER
            background = ovalBg("#22FFFFFF")
            val px = (34 * resources.displayMetrics.density).toInt(); layoutParams = android.view.ViewGroup.LayoutParams(px, px)
            setOnClickListener { showOverflowMenu(it) }
        }
        header.addView(overflowButton)
        root.addView(header)

        // Secondary action row (Hold / Recall) — split full-width, left half Hold, right half Recall
        val actionRow = LinearLayout(this).apply {
            orientation = LinearLayout.HORIZONTAL
            layoutParams = LinearLayout.LayoutParams(LinearLayout.LayoutParams.MATCH_PARENT, LinearLayout.LayoutParams.WRAP_CONTENT).apply { setMargins(0, 0, 0, 14) }
        }
        val holdHalf = TextView(this).apply {
            text = "\u23F8  " + com.grocerypos.v11.util.Loc.t(this@SaleActivity, "Hold", "روکیں")
            textSize = 14f
            gravity = Gravity.CENTER
            setTextColor(Color.parseColor(navy))
            setTypeface(typeface, android.graphics.Typeface.BOLD)
            background = strokedBg(border, cardBg, 14)
            setPadding(0, 22, 0, 22)
            layoutParams = LinearLayout.LayoutParams(0, LinearLayout.LayoutParams.WRAP_CONTENT, 1f).apply { setMargins(0, 0, 6, 0) }
            applyElevation(this, 1.5f)
            setOnClickListener { holdBill() }
        }
        val recallHalf = TextView(this).apply {
            text = "\u21BA  " + com.grocerypos.v11.util.Loc.t(this@SaleActivity, "Recall", "واپس لائیں")
            textSize = 14f
            gravity = Gravity.CENTER
            setTextColor(Color.parseColor(navy))
            setTypeface(typeface, android.graphics.Typeface.BOLD)
            background = strokedBg(border, cardBg, 14)
            setPadding(0, 22, 0, 22)
            layoutParams = LinearLayout.LayoutParams(0, LinearLayout.LayoutParams.WRAP_CONTENT, 1f).apply { setMargins(6, 0, 0, 0) }
            applyElevation(this, 1.5f)
            setOnClickListener { openRecallDialog() }
        }
        actionRow.addView(holdHalf)
        actionRow.addView(recallHalf)
        root.addView(actionRow)

        // ---------- Date chip ----------
        val topRow = LinearLayout(this).apply {
            orientation = LinearLayout.HORIZONTAL
            gravity = Gravity.CENTER_VERTICAL
            layoutParams = LinearLayout.LayoutParams(LinearLayout.LayoutParams.WRAP_CONTENT, LinearLayout.LayoutParams.WRAP_CONTENT).apply { setMargins(0, 0, 0, 14) }
        }
        val dateChip = LinearLayout(this).apply {
            orientation = LinearLayout.HORIZONTAL
            gravity = Gravity.CENTER_VERTICAL
            setPadding(22, 12, 22, 12)
            background = strokedBg(border, cardBg, 30)
            applyElevation(this, 1.5f)
            setOnClickListener { openDatePicker() }
        }
        dateChip.addView(ImageView(this).apply {
            setImageDrawable(tintedDrawable(R.drawable.ic_calendar, textDark, 14))
            layoutParams = LinearLayout.LayoutParams(LinearLayout.LayoutParams.WRAP_CONTENT, LinearLayout.LayoutParams.WRAP_CONTENT).apply { marginEnd = (6 * resources.displayMetrics.density).toInt() }
        })
        dateValueText = TextView(this).apply {
            text = formatDate(saleDateMillis)
            textSize = 13f
            setTextColor(Color.parseColor(textDark))
            setTypeface(typeface, android.graphics.Typeface.BOLD)
        }
        dateChip.addView(dateValueText)
        dateChip.addView(TextView(this).apply { text = "  \u203A"; textSize = 13f; setTextColor(Color.parseColor(teal)); setTypeface(typeface, android.graphics.Typeface.BOLD) })
        topRow.addView(dateChip)
        root.addView(topRow)

        // ---------- Firm card ----------
        val firmBox = premiumCard().apply { setPadding(20, 10, 20, 10) }
        val firmRow = LinearLayout(this).apply { orientation = LinearLayout.HORIZONTAL; gravity = Gravity.CENTER_VERTICAL }
        val firmCol = LinearLayout(this).apply {
            orientation = LinearLayout.VERTICAL
            gravity = Gravity.CENTER_HORIZONTAL
            layoutParams = LinearLayout.LayoutParams(0, LinearLayout.LayoutParams.WRAP_CONTENT, 1f)
        }
        firmCol.addView(TextView(this).apply {
            text = com.grocerypos.v11.util.Loc.t(this@SaleActivity, "Firm Name", "فرم کا نام").uppercase()
            textSize = 9.5f; setTextColor(Color.parseColor(textGray)); setTypeface(typeface, android.graphics.Typeface.BOLD); letterSpacing = 0.05f
            gravity = Gravity.CENTER
        })
        firmNameText = TextView(this).apply {
            text = "IBTISAAM Kiryana Store"; textSize = 13.5f; setTextColor(Color.parseColor(textDark)); setTypeface(typeface, android.graphics.Typeface.BOLD); setPadding(0, 2, 0, 0)
            gravity = Gravity.CENTER
        }
        firmCol.addView(firmNameText)
        firmRow.addView(firmCol)
        firmBox.addView(firmRow)
        root.addView(firmBox)

        // ---------- Customer card ----------
        customerBox = premiumCard()
        customerBox.addView(labelRow(com.grocerypos.v11.util.Loc.t(this, "Customer", "کسٹمر")))
        val custRow = LinearLayout(this).apply { orientation = LinearLayout.HORIZONTAL; gravity = Gravity.CENTER_VERTICAL }
        customerName = AutoCompleteTextView(this).apply {
            hint = com.grocerypos.v11.util.Loc.t(this@SaleActivity, "Customer Name (Walk-in)", "کسٹمر کا نام (واک ان)")
            setHintTextColor(Color.parseColor(textGray))
            setTextColor(Color.parseColor(textDark))
            background = null
            textSize = 15.5f
            threshold = 1
            imeOptions = EditorInfo.IME_ACTION_NEXT
            layoutParams = LinearLayout.LayoutParams(0, LinearLayout.LayoutParams.WRAP_CONTENT, 1f)
        }
        custRow.addView(customerName)
        custRow.addView(circleIcon("+", teal, 32) { promptAddCustomer() })
        customerBox.addView(custRow)
        root.addView(customerBox)
        root.addView(spacer(4))

        // ---------- Sale type ----------
        val saleTypeBox = innerField()
        saleTypeBox.addView(labelRow(com.grocerypos.v11.util.Loc.t(this, "Sale Type", "سیل کی قسم")))
        saleTypeSpinner = Spinner(this).apply {
            adapter = ArrayAdapter(this@SaleActivity, android.R.layout.simple_spinner_dropdown_item, listOf("Retail", "Wholesale"))
            isFocusableInTouchMode = true
        }
        saleTypeBox.addView(saleTypeSpinner)
        root.addView(saleTypeBox)
        root.addView(spacer(14))

        // ---------- Item entry card ----------
        itemEntrySection = LinearLayout(this).apply {
            orientation = LinearLayout.VERTICAL
            setPadding(24, 22, 24, 22)
            background = strokedBg(border, cardBg, 20)
            layoutParams = LinearLayout.LayoutParams(LinearLayout.LayoutParams.MATCH_PARENT, LinearLayout.LayoutParams.WRAP_CONTENT).apply { setMargins(0, 0, 0, 12) }
            applyElevation(this, 3f)
        }
        val addItemHeaderRow = LinearLayout(this).apply { orientation = LinearLayout.HORIZONTAL; gravity = Gravity.CENTER_VERTICAL; setPadding(0, 0, 0, 16) }
        addItemHeaderRow.addView(TextView(this).apply {
            text = "\u2795  " + com.grocerypos.v11.util.Loc.t(this@SaleActivity, "Add Item", "آئٹم شامل کریں")
            textSize = 15f
            setTextColor(Color.parseColor(teal))
            setTypeface(typeface, android.graphics.Typeface.BOLD)
            layoutParams = LinearLayout.LayoutParams(0, LinearLayout.LayoutParams.WRAP_CONTENT, 1f)
        })
        itemEntrySection.addView(addItemHeaderRow)

        val itemBox = innerField()
        itemBox.addView(labelRow(com.grocerypos.v11.util.Loc.t(this, "Item Name", "آئٹم کا نام")).apply { setLeadingIcon(R.drawable.ic_box, textGray, 11, 5) })
        itemName = AutoCompleteTextView(this).apply {
            hint = com.grocerypos.v11.util.Loc.t(this@SaleActivity, "Type to search…", "تلاش کے لیے لکھیں…")
            setHintTextColor(Color.parseColor(textGray))
            setTextColor(Color.parseColor(textDark))
            background = null
            textSize = 15.5f
            threshold = 1
            imeOptions = EditorInfo.IME_ACTION_NEXT
        }
        itemBox.addView(itemName)
        itemEntrySection.addView(itemBox)

        unitToggleRow = LinearLayout(this).apply { orientation = LinearLayout.HORIZONTAL; visibility = View.GONE }
        itemEntrySection.addView(unitToggleRow)
        itemEntrySection.addView(spacer(10))

        val qtyUnitRow = LinearLayout(this).apply { orientation = LinearLayout.HORIZONTAL }
        val qtyBox = innerField().apply { layoutParams = LinearLayout.LayoutParams(0, LinearLayout.LayoutParams.WRAP_CONTENT, 1f).apply { setMargins(0, 0, 6, 0) } }
        val qtyLabelRow = LinearLayout(this).apply { orientation = LinearLayout.HORIZONTAL; gravity = Gravity.CENTER_VERTICAL }
        qtyLabelRow.addView(labelRow(com.grocerypos.v11.util.Loc.t(this, "Quantity", "مقدار")).apply {
            layoutParams = LinearLayout.LayoutParams(0, LinearLayout.LayoutParams.WRAP_CONTENT, 1f)
        })
        // NEW (Buy-by-amount): small pill next to the Quantity label — tap to
        // switch this box between "Quantity" (weight/pcs, as before) and
        // "Amount (Rs)" (type what the customer wants to spend; qty is worked
        // out from the rate). Kept next to the label rather than a whole
        // separate field so the box the shopkeeper is already looking at just
        // changes meaning, instead of adding a new row to scan.
        amountModeToggle = TextView(this).apply {
            text = "Rs"
            textSize = 10.5f
            setTypeface(typeface, android.graphics.Typeface.BOLD)
            setPadding(16, 6, 16, 6)
            setTextColor(Color.parseColor(textGray))
            background = strokedBg(border, cardBg, 20)
            setOnClickListener { toggleQtyAmountMode() }
        }
        qtyLabelRow.addView(amountModeToggle)
        qtyBox.addView(qtyLabelRow)
        qty = EditText(this).apply {
            hint = "0"
            setHintTextColor(Color.parseColor(textGray))
            setTextColor(Color.parseColor(textDark))
            background = null
            textSize = 15.5f
            inputType = InputType.TYPE_CLASS_NUMBER or InputType.TYPE_NUMBER_FLAG_DECIMAL
            imeOptions = EditorInfo.IME_ACTION_NEXT
        }
        qtyBox.addView(qty)
        val unitBox = innerField().apply { layoutParams = LinearLayout.LayoutParams(0, LinearLayout.LayoutParams.WRAP_CONTENT, 1f).apply { setMargins(6, 0, 0, 0) } }
        unitBox.addView(labelRow(com.grocerypos.v11.util.Loc.t(this, "Unit", "یونٹ")))
        unitSpinner = Spinner(this).apply {
            adapter = ArrayAdapter(this@SaleActivity, android.R.layout.simple_spinner_dropdown_item, listOf("pcs"))
        }
        unitBox.addView(unitSpinner)
        qtyUnitRow.addView(qtyBox)
        qtyUnitRow.addView(unitBox)
        itemEntrySection.addView(qtyUnitRow)
        itemEntrySection.addView(spacer(10))

        val rateBox = innerField()
        rateBox.addView(labelRow(com.grocerypos.v11.util.Loc.t(this, "Rate", "ریٹ")).apply { setLeadingIcon(R.drawable.ic_wallet, textGray, 11, 5) })
        unitPrice = EditText(this).apply {
            hint = com.grocerypos.v11.util.Loc.t(this@SaleActivity, "Auto-filled, editable", "خودکار، قابل ترمیم")
            setHintTextColor(Color.parseColor(textGray))
            setTextColor(Color.parseColor(textDark))
            background = null
            textSize = 15.5f
            inputType = InputType.TYPE_CLASS_NUMBER or InputType.TYPE_NUMBER_FLAG_DECIMAL
            imeOptions = EditorInfo.IME_ACTION_DONE
            setOnEditorActionListener { _, actionId, event ->
                if (actionId == EditorInfo.IME_ACTION_DONE ||
                    (event != null && event.keyCode == KeyEvent.KEYCODE_ENTER && event.action == KeyEvent.ACTION_DOWN)
                ) {
                    val imm = getSystemService(Context.INPUT_METHOD_SERVICE) as? InputMethodManager
                    imm?.hideSoftInputFromWindow(windowToken, 0)
                    addItem()
                    true
                } else {
                    false
                }
            }
        }
        rateBox.addView(unitPrice)
        itemEntrySection.addView(rateBox)

        customerRateHint = TextView(this).apply {
            text = ""; textSize = 12f; setTypeface(typeface, android.graphics.Typeface.BOLD)
            setPadding(16, 10, 16, 10); visibility = View.GONE
            background = strokedBg("#FBE3C7", "#FFF7EC", 10)
        }
        itemEntrySection.addView(customerRateHint)
        itemEntrySection.addView(spacer(6))

        marginWarningText = TextView(this).apply {
            text = ""; textSize = 12f; setTypeface(typeface, android.graphics.Typeface.BOLD)
            setPadding(16, 10, 16, 10); visibility = View.GONE
        }
        itemEntrySection.addView(marginWarningText)
        itemEntrySection.addView(spacer(6))

        conversionInfo = TextView(this).apply {
            text = ""; textSize = 12f; setTextColor(Color.parseColor(teal)); setTypeface(typeface, android.graphics.Typeface.BOLD)
            setPadding(16, 10, 16, 10); visibility = View.GONE
            background = strokedBg("#CDEEEC", "#EFFBFA", 10)
        }
        itemEntrySection.addView(conversionInfo)
        itemEntrySection.addView(spacer(6))

        itemLineTotalText = TextView(this).apply { text = "Total Amount: Rs 0"; textSize = 14.5f; setTypeface(typeface, android.graphics.Typeface.BOLD); setTextColor(Color.parseColor(navy)); setPadding(6, 8, 0, 10) }
        itemEntrySection.addView(itemLineTotalText)

        addItemButton = Button(this).apply {
            text = com.grocerypos.v11.util.Loc.t(this@SaleActivity, "ADD ITEM", "آئٹم شامل کریں")
            setTextColor(Color.WHITE)
            textSize = 14.5f
            isAllCaps = false
            setTypeface(typeface, android.graphics.Typeface.BOLD)
            background = gradientBg(teal, teal, cornerBottom = 14, cornerTop = 14)
            setPadding(0, 26, 0, 26)
            applyElevation(this, 3f)
            setOnClickListener { addItem() }
        }
        itemEntrySection.addView(addItemButton)
        cancelEditButton = TextView(this).apply {
            text = com.grocerypos.v11.util.Loc.t(this@SaleActivity, "Cancel Edit", "ترمیم منسوخ کریں")
            textSize = 13f
            gravity = Gravity.CENTER
            setTextColor(Color.parseColor(red))
            setTypeface(typeface, android.graphics.Typeface.BOLD)
            setPadding(0, 16, 0, 0)
            visibility = View.GONE
            setOnClickListener {
                endLineEdit()
                itemName.text.clear(); qty.text.clear(); unitPrice.text.clear()
                selectedProduct = null; lastMainPrice = 0.0
                conversionInfo.visibility = View.GONE; unitToggleRow.visibility = View.GONE
                marginWarningText.visibility = View.GONE
                itemLineTotalText.text = "Total Amount: Rs 0"
                val imm = getSystemService(Context.INPUT_METHOD_SERVICE) as? InputMethodManager
                imm?.hideSoftInputFromWindow(currentFocus?.windowToken, 0)
            }
        }
        itemEntrySection.addView(cancelEditButton)
        root.addView(itemEntrySection)

        // ---- ADDED (tablet / desktop-style layout): from here on, everything
        // that used to go straight into `root` (billed items, subtotal,
        // discount, total, payment, due, save/delete) is added to `cartColumn`
        // instead. On phones `cartColumn` IS `root`, so nothing changes. On a
        // tablet-wide screen it's a separate LinearLayout that becomes the
        // right-hand "cart" pane, built further down. ----
        val cartColumn: LinearLayout = if (isTabletWide) {
            LinearLayout(this).apply {
                orientation = LinearLayout.VERTICAL
                setPadding(0, 0, 0, 40)
            }
        } else {
            root
        }

        // ---------- Billed items header ----------
        billedItemsHeader = LinearLayout(this).apply {
            orientation = LinearLayout.HORIZONTAL
            gravity = Gravity.CENTER_VERTICAL
            setPadding(22, 16, 22, 16)
            background = gradientBg(navy, navy, cornerBottom = 14, cornerTop = 14)
            layoutParams = LinearLayout.LayoutParams(LinearLayout.LayoutParams.MATCH_PARENT, LinearLayout.LayoutParams.WRAP_CONTENT).apply { setMargins(0, 4, 0, 0) }
            applyElevation(this, 2f)
            setOnClickListener { openBilledItemsDialog() }
        }
        billedItemsTrigger = TextView(this).apply {
            text = com.grocerypos.v11.util.Loc.t(this@SaleActivity, "Billed Items (0)", "بل کردہ آئٹمز (0)")
            setLeadingIcon(R.drawable.ic_receipt, "#FFFFFF", 15, 8)
            textSize = 13.5f
            setTypeface(typeface, android.graphics.Typeface.BOLD)
            setTextColor(Color.WHITE)
            layoutParams = LinearLayout.LayoutParams(0, LinearLayout.LayoutParams.WRAP_CONTENT, 1f)
        }
        billedItemsHeader.addView(billedItemsTrigger)
        billedItemsChevron = TextView(this).apply { text = "\u203A"; textSize = 18f; setTextColor(Color.WHITE); setTypeface(typeface, android.graphics.Typeface.BOLD) }
        billedItemsHeader.addView(billedItemsChevron)
        // ---- CHANGED (tablet / desktop-style layout — keyboard-hides-total fix):
        // on phone this still goes straight into cartColumn (===root), unchanged.
        // On tablet it is NOT added to cartColumn — see the final two-pane
        // assembly below, where the header + cart list become their own
        // independently-scrolling middle section, separate from the
        // Total/Payment/Due/Save block. That way a long item list (or the
        // keyboard eating vertical space) can only ever squeeze the cart-list
        // area — it can no longer push Total Amount / Paid Amount / Save off
        // the bottom of the screen the way it did before this fix. ----
        if (!isTabletWide) {
            cartColumn.addView(billedItemsHeader)
            cartColumn.addView(spacer(14))
        }

        itemsContainer = LinearLayout(this).apply { orientation = LinearLayout.VERTICAL; setPadding(0, 8, 0, 0) }

        if (isTabletWide) {
            billedItemsHeader.setOnClickListener(null)
            billedItemsHeader.isClickable = false
            billedItemsChevron.visibility = View.GONE
        }

        // ---------- Subtotal + discount card ----------
        val billingCard = premiumCard()
        val subtotalRow = LinearLayout(this).apply { orientation = LinearLayout.HORIZONTAL; gravity = Gravity.CENTER_VERTICAL }
        subtotalRow.addView(TextView(this).apply {
            text = com.grocerypos.v11.util.Loc.t(this@SaleActivity, "Subtotal", "سب ٹوٹل").uppercase(); textSize = 11f
            setTextColor(Color.parseColor(textGray)); setTypeface(typeface, android.graphics.Typeface.BOLD); letterSpacing = 0.05f
            layoutParams = LinearLayout.LayoutParams(0, LinearLayout.LayoutParams.WRAP_CONTENT, 1f)
        })
        subtotalText = TextView(this).apply { text = "Rs 0.00"; textSize = 14f; setTextColor(Color.parseColor(textDark)); setTypeface(typeface, android.graphics.Typeface.BOLD) }
        subtotalRow.addView(subtotalText)
        billingCard.addView(subtotalRow)
        billingCard.addView(spacer(12))
        billingCard.addView(labelRow(com.grocerypos.v11.util.Loc.t(this, "Discount", "رعایت")))
        discountInput = EditText(this).apply {
            hint = "0.00"
            setHintTextColor(Color.parseColor(textGray))
            setTextColor(Color.parseColor(textDark))
            background = null
            textSize = 15f
            inputType = InputType.TYPE_CLASS_NUMBER or InputType.TYPE_NUMBER_FLAG_DECIMAL
        }
        discountInput.addTextChangedListener(simpleWatcher { updateTotals() })
        billingCard.addView(discountInput)
        cartColumn.addView(billingCard)

        // ---------- Grand total card ----------
        val totalCard = premiumCard().apply { orientation = LinearLayout.HORIZONTAL; gravity = Gravity.CENTER_VERTICAL; setPadding(24, 20, 24, 20); background = strokedBg(border, fieldFill, 18) }
        totalCard.addView(TextView(this).apply {
            text = com.grocerypos.v11.util.Loc.t(this@SaleActivity, "Total Amount", "کل رقم").uppercase()
            textSize = 12f
            setTextColor(Color.parseColor(textGray))
            setTypeface(typeface, android.graphics.Typeface.BOLD)
            letterSpacing = 0.05f
            layoutParams = LinearLayout.LayoutParams(0, LinearLayout.LayoutParams.WRAP_CONTENT, 1f)
        })
        totalText = TextView(this).apply { text = "Rs 0.00"; textSize = 21f; setTextColor(Color.parseColor(navy)); setTypeface(typeface, android.graphics.Typeface.BOLD) }
        totalCard.addView(totalText)
        cartColumn.addView(totalCard)

        // ---------- Payment section ----------
        paymentSection = premiumCard().apply { orientation = LinearLayout.VERTICAL; setPadding(22, 14, 22, 14) }
        val paidRow = LinearLayout(this).apply { orientation = LinearLayout.HORIZONTAL; gravity = Gravity.CENTER_VERTICAL }
        paidRow.addView(TextView(this).apply {
            text = com.grocerypos.v11.util.Loc.t(this@SaleActivity, "Paid Amount", "ادا شدہ رقم").uppercase()
            textSize = 12f
            setTextColor(Color.parseColor(textGray))
            setTypeface(typeface, android.graphics.Typeface.BOLD)
            letterSpacing = 0.05f
            layoutParams = LinearLayout.LayoutParams(0, LinearLayout.LayoutParams.WRAP_CONTENT, 1f)
        })
        paidRow.addView(TextView(this).apply { text = "Rs "; textSize = 17f; setTextColor(Color.parseColor(green)); setTypeface(typeface, android.graphics.Typeface.BOLD) })
        // ---- CHANGED (keyboard-driven save): paidInput now finishes with IME_ACTION_DONE
        // and a listener that hides the keyboard and calls saveSale() directly — so once
        // the user is on Paid Amount, Enter/Done on the keyboard saves the sale without
        // touching the screen. ----
        paidInput = EditText(this).apply {
            hint = "0.00"
            setHintTextColor(Color.parseColor(textGray))
            setTextColor(Color.parseColor(green))
            background = null
            textSize = 20f
            gravity = Gravity.END
            setTypeface(typeface, android.graphics.Typeface.BOLD)
            minWidth = (120 * resources.displayMetrics.density).toInt()
            inputType = InputType.TYPE_CLASS_NUMBER or InputType.TYPE_NUMBER_FLAG_DECIMAL
            imeOptions = EditorInfo.IME_ACTION_DONE
            setOnEditorActionListener { _, actionId, event ->
                if (actionId == EditorInfo.IME_ACTION_DONE ||
                    (event != null && event.keyCode == KeyEvent.KEYCODE_ENTER && event.action == KeyEvent.ACTION_DOWN)
                ) {
                    val imm = getSystemService(Context.INPUT_METHOD_SERVICE) as? InputMethodManager
                    imm?.hideSoftInputFromWindow(windowToken, 0)
                    saveSale()
                    true
                } else {
                    false
                }
            }
        }
        paidInput.addTextChangedListener(simpleWatcher {
            if (!suppressPaidWatcher) {
                refreshDue()
                if (editInvoice == null) saveDraft()
            }
        })
        paidRow.addView(paidInput)
        paymentSection.addView(paidRow)
        paymentSection.addView(spacer(6))
        paymentSection.addView(labelRow(com.grocerypos.v11.util.Loc.t(this, "Payment Method", "ادائیگی کا طریقہ")))
        paymentMethodSpinner = Spinner(this).apply {
            adapter = ArrayAdapter(this@SaleActivity, android.R.layout.simple_spinner_dropdown_item, listOf("Cash", "Bank"))
        }
        paymentSection.addView(paymentMethodSpinner)
        // NEW (Split Payment / multiple payment methods): tapping this opens a
        // dialog to pay one bill with more than one method (e.g. Rs 300 Cash +
        // Rs 200 Bank). Once applied, this link is hidden and splitPaymentSummary
        // below shows the breakdown instead — the single spinner above still sits
        // there but is ignored while a split is active (SaveSaleUseCase derives
        // the saved payment method from splitPayments, not the spinner, in that
        // case).
        splitPaymentLink = TextView(this).apply {
            text = com.grocerypos.v11.util.Loc.t(this@SaleActivity, "+ Split Payment (multiple methods)", "+ ادائیگی تقسیم کریں (ایک سے زیادہ طریقے)")
            textSize = 12.5f
            setTextColor(Color.parseColor(navy))
            setTypeface(typeface, android.graphics.Typeface.BOLD)
            setPadding(0, 10, 0, 0)
            setOnClickListener { openSplitPaymentDialog() }
        }
        paymentSection.addView(splitPaymentLink)
        splitPaymentSummary = TextView(this).apply {
            textSize = 12.5f
            setTextColor(Color.parseColor(textDark))
            setPadding(0, 10, 0, 0)
            visibility = View.GONE
        }
        paymentSection.addView(splitPaymentSummary)
        paidWarningText = TextView(this).apply {
            text = "Paid khali hai - Ye Udhaar me jayega"
            setLeadingIcon(R.drawable.ic_warning, red, 12, 5)
            textSize = 11f
            setTextColor(Color.parseColor(red))
            setTypeface(typeface, android.graphics.Typeface.BOLD)
            setPadding(0, 8, 0, 0)
            visibility = View.GONE
        }
        paymentSection.addView(paidWarningText)
        cartColumn.addView(paymentSection)

        // ---------- Due card ----------
        val dueCard = premiumCard().apply { orientation = LinearLayout.HORIZONTAL; gravity = Gravity.CENTER_VERTICAL; setPadding(22, 18, 22, 18); background = strokedBg(border, fieldFill, 18) }
        dueCard.addView(TextView(this).apply {
            text = com.grocerypos.v11.util.Loc.t(this@SaleActivity, "Due Amount", "باقی رقم").uppercase()
            textSize = 12f
            setTextColor(Color.parseColor(textGray))
            setTypeface(typeface, android.graphics.Typeface.BOLD)
            letterSpacing = 0.05f
            layoutParams = LinearLayout.LayoutParams(0, LinearLayout.LayoutParams.WRAP_CONTENT, 1f)
        })
        dueAmountText = TextView(this).apply { text = "Rs 0.00"; textSize = 18f; setTextColor(Color.parseColor(green)); setTypeface(typeface, android.graphics.Typeface.BOLD) }
        dueCard.addView(dueAmountText)
        cartColumn.addView(dueCard)
        cartColumn.addView(spacer(24))

        // ---------- Save / delete ----------
        saveButton = Button(this).apply {
            text = if (editInvoice != null) com.grocerypos.v11.util.Loc.t(this@SaleActivity, "UPDATE SALE", "سیل اپ ڈیٹ کریں") else com.grocerypos.v11.util.Loc.t(this@SaleActivity, "SAVE SALE", "سیل محفوظ کریں")
            setTextColor(Color.WHITE)
            textSize = 15.5f
            isAllCaps = false
            setTypeface(typeface, android.graphics.Typeface.BOLD)
            background = gradientBg(navy, navy, cornerBottom = 16, cornerTop = 16)
            setPadding(0, 30, 0, 30)
            applyElevation(this, 5f)
            setOnClickListener { saveSale() }
        }
        deleteButton = Button(this).apply {
            text = com.grocerypos.v11.util.Loc.t(this@SaleActivity, "DELETE", "حذف کریں")
            setTextColor(Color.WHITE)
            textSize = 15f
            isAllCaps = false
            setTypeface(typeface, android.graphics.Typeface.BOLD)
            background = roundedBg(red, 16)
            setPadding(0, 30, 0, 30)
            applyElevation(this, 3f)
            visibility = if (editInvoice != null) View.VISIBLE else View.GONE
            setOnClickListener { confirmDeleteSale() }
        }
        val saveDeleteRow = LinearLayout(this).apply { orientation = LinearLayout.HORIZONTAL }
        saveDeleteRow.addView(saveButton, LinearLayout.LayoutParams(0, LinearLayout.LayoutParams.WRAP_CONTENT, 1f).apply { setMargins(0, 0, 8, 0) })
        saveDeleteRow.addView(deleteButton, LinearLayout.LayoutParams(0, LinearLayout.LayoutParams.WRAP_CONTENT, 0.8f).apply { setMargins(8, 0, 0, 0) })
        cartColumn.addView(saveDeleteRow)
        cartColumn.addView(spacer(30))

        if (isTabletWide) {
            // ---- ADDED (tablet / desktop-style layout): two side-by-side panes,
            // like a computer POS screen — left = item entry (scrolls), right =
            // cart/bill/payment. `scrollView` keeps pointing at the LEFT pane,
            // since every existing scrollView.smoothScrollTo(...) call in
            // SaleActivity.kt/SaleCart.kt is about the item-entry side of the
            // screen (jumping back to Item Name / Sale Type after an action) —
            // that behavior is unchanged, it just now scrolls the left pane only.
            //
            // ---- FIX (keyboard-hides-total): the right pane is built as THREE
            // stacked pieces, not one long ScrollView — billedItemsHeader (fixed),
            // a scrollable middle strip holding just the cart list (this is the
            // ONLY part that grows with more items / shrinks for the keyboard),
            // and cartColumn (Total/Payment/Due/Save) pinned at the bottom. A
            // LinearLayout gives non-weighted children (the header and the
            // pinned bottom block) their full requested height FIRST, and only
            // gives the weighted middle strip whatever space is left over — so
            // no matter how many items are billed, or how much the keyboard
            // shrinks the window, Total/Paid/Save always get their space and
            // stay visible; only the cart list itself scrolls/shrinks. The
            // bottom block also has its own small ScrollView as a safety net,
            // in case even it doesn't fully fit in extreme cases. ----
            val cartListScroll = ScrollView(this).apply {
                addView(itemsContainer)
                layoutParams = LinearLayout.LayoutParams(LinearLayout.LayoutParams.MATCH_PARENT, 0, 1f)
            }
            val pinnedBottom = ScrollView(this).apply {
                addView(cartColumn)
            }
            val rightPane = LinearLayout(this).apply {
                orientation = LinearLayout.VERTICAL
                setBackgroundColor(Color.parseColor(bg))
                setPadding(16, 0, 0, 0)
                addView(billedItemsHeader)
                addView(spacer(10))
                addView(cartListScroll)
                addView(spacer(10))
                addView(pinnedBottom)
                layoutParams = LinearLayout.LayoutParams(0, LinearLayout.LayoutParams.MATCH_PARENT, 1f)
            }
            val leftScroll = ScrollView(this).apply {
                setBackgroundColor(Color.parseColor(bg))
                setPadding(0, 0, 16, 0)
                addView(root)
                layoutParams = LinearLayout.LayoutParams(0, LinearLayout.LayoutParams.MATCH_PARENT, 1.3f)
            }
            val divider = View(this).apply {
                setBackgroundColor(Color.parseColor(border))
                layoutParams = LinearLayout.LayoutParams((1 * resources.displayMetrics.density).toInt(), LinearLayout.LayoutParams.MATCH_PARENT)
            }
            val twoPane = LinearLayout(this).apply {
                orientation = LinearLayout.HORIZONTAL
                setBackgroundColor(Color.parseColor(bg))
                setPadding(24, 0, 24, 0)
                addView(leftScroll)
                addView(divider)
                addView(rightPane)
            }
            scrollView = leftScroll
            setContentView(twoPane)
            keepContentAboveKeyboard(twoPane)
        } else {
            scrollView = ScrollView(this).apply {
                setBackgroundColor(Color.parseColor(bg))
                addView(root)
            }
            setContentView(scrollView)
            keepContentAboveKeyboard(scrollView)
        }

        observeViewModel()
        loadFirmName()
        updateTotals()
        editInvoice?.let { loadForEdit(it) }

        customerName.setOnClickListener { if (customers.isNotEmpty()) customerName.showDropDown() }
        customerName.setOnFocusChangeListener { _, hasFocus -> if (hasFocus && customers.isNotEmpty()) customerName.showDropDown() }
        customerName.setOnItemClickListener { _, _, position, _ ->
            val name = customerName.adapter.getItem(position).toString()
            customerName.setText(name)
            customerName.setSelection(customerName.text.length)
            goToSaleTypeFromCustomer()
            // If an item row is already active (customer picked AFTER the
            // item), re-check for that customer's usual rate on this item too.
            suggestCustomerRate()
        }
        customerName.setOnEditorActionListener { _, actionId, event ->
            if (actionId == EditorInfo.IME_ACTION_NEXT ||
                (event != null && event.keyCode == KeyEvent.KEYCODE_ENTER && event.action == KeyEvent.ACTION_DOWN)
            ) {
                goToSaleTypeFromCustomer()
                true
            } else false
        }

        itemName.setOnItemClickListener { _, _, position, _ ->
            val name = itemName.adapter.getItem(position).toString()
            onItemPicked(name)
        }
        itemName.addTextChangedListener(simpleWatcher {
            val match = products.find { it.name.equals(itemName.text.toString().trim(), ignoreCase = true) }
            if (match == null) {
                selectedProduct = null
                unitSpinner.adapter = ArrayAdapter(this, android.R.layout.simple_spinner_dropdown_item, listOf("pcs"))
                conversionInfo.visibility = View.GONE
                unitToggleRow.visibility = View.GONE
            }
        })
        itemName.setOnEditorActionListener { _, actionId, event ->
            if (actionId == EditorInfo.IME_ACTION_NEXT ||
                (event != null && event.keyCode == KeyEvent.KEYCODE_ENTER && event.action == KeyEvent.ACTION_DOWN)
            ) {
                val typed = itemName.text.toString().trim()
                val match = products.find { it.name.equals(typed, ignoreCase = true) }
                if (match != null && selectedProduct?.barcode != match.barcode) {
                    onItemPicked(match.name)
                } else {
                    qty.requestFocus()
                    qty.selectAll()
                }
                true
            } else false
        }
        qty.addTextChangedListener(simpleWatcher { updateItemLineTotal() })
        unitPrice.addTextChangedListener(simpleWatcher {
            if (!suppressPriceWatcher) {
                val entered = unitPrice.text.toString().toDoubleOrNull() ?: 0.0
                lastMainPrice = toMainUnitPrice(entered)
            }
            updateItemLineTotal()
            updateMarginWarning()
        })
        unitSpinner.onItemSelectedListener = object : AdapterView.OnItemSelectedListener {
            override fun onItemSelected(p: AdapterView<*>?, v: View?, pos: Int, id: Long) { refillAutoPrice() }
            override fun onNothingSelected(p: AdapterView<*>?) {}
        }
        // ---- CHANGED (auto-scroll on Sale Type select): once a sale type is picked, the
        // ScrollView jumps back to the very top (so Item Name is visible right under the
        // header, matching the reference screenshot) before focus moves into Item Name.
        // FIX: previously gated on saleTypeSpinner.hasFocus(), which was unreliable right
        // after a touch-driven selection on some OEM keyboards — now gated on
        // saleTypeUserInteracted instead (set true by the touch listener below), so this
        // reliably fires on every real user selection. ----
        saleTypeSpinner.onItemSelectedListener = object : AdapterView.OnItemSelectedListener {
            override fun onItemSelected(p: AdapterView<*>?, v: View?, pos: Int, id: Long) {
                lastMainPrice = 0.0
                refillAutoPrice()
                if (saleTypeUserInteracted) {
                    repriceLinesForSaleType()
                    // FIX (position bug): scrolling to absolute 0 landed at the very top
                    // of the screen (Header/Quick Sale/Date/Firm/Customer cards), which
                    // pushed the Add Item section back down under the keyboard. Scrolling
                    // to saleTypeBox's own top position instead matches the reference
                    // screenshot — Sale Type box at the top, Add Item right below it.
                    scrollView.post { scrollView.smoothScrollTo(0, saleTypeBox.top) }
                    itemName.requestFocus()
                    itemName.post {
                        val imm = getSystemService(Context.INPUT_METHOD_SERVICE) as? InputMethodManager
                        imm?.showSoftInput(itemName, InputMethodManager.SHOW_IMPLICIT)
                    }
                }
            }
            override fun onNothingSelected(p: AdapterView<*>?) {}
        }
        saleTypeSpinner.setOnTouchListener { _, _ ->
            saleTypeUserInteracted = true
            false // let the touch continue so the dropdown still opens normally
        }

        if (editInvoice == null) {
            restoreDraftIfAny()
        }

        // ---- ADDED (dashboard "Quick Sale" card) ----
        if (intent.getBooleanExtra(EXTRA_OPEN_QUICK_SALE, false)) {
            quickSaleDialog()
        }
    }

    // ---- Keyboard flow: after customer is picked/confirmed, jump straight into
    // Sale Type so the rest (item -> qty -> rate -> Add Item) can be done without
    // touching the screen. ----
    // FIX (auto-scroll not firing after Customer -> Sale Type): saleTypeSpinner's
    // own OnTouchListener (which sets saleTypeUserInteracted = true) only fires on a
    // direct touch of the closed spinner. When this flow opens the dropdown
    // programmatically via performClick(), the user's subsequent tap lands on the
    // popup list item instead, never touching the spinner view itself — so the flag
    // stayed false and the auto-scroll-to-top in saleTypeSpinner's onItemSelected
    // never ran. The tap here still represents a real user choice, so set the flag
    // directly instead of relying on the touch listener for this path.
    private fun goToSaleTypeFromCustomer() {
        val imm = getSystemService(Context.INPUT_METHOD_SERVICE) as? InputMethodManager
        imm?.hideSoftInputFromWindow(customerName.windowToken, 0)
        saleTypeUserInteracted = true
        saleTypeSpinner.requestFocus()
        saleTypeSpinner.performClick()
    }

    override fun onResume() {
        super.onResume()
        loadFirmName()
    }

    override fun onPause() {
        super.onPause()
        if (editInvoice == null && !suppressDraftSave) {
            saveDraft()
        }
    }

    @Suppress("OVERRIDE_DEPRECATION", "DEPRECATION")
    override fun onBackPressed() {
        if (editInvoice == null && !suppressDraftSave) {
            saveDraft()
        }
        super.onBackPressed()
    }

    private fun draftPrefs() = getSharedPreferences(PREFS_NAME, Context.MODE_PRIVATE)

    // ---- isInitialized checks on a lateinit var only compile when written
    // lexically inside the declaring class/file, so SaleCart.kt (which now owns
    // updateBilledItemsTrigger()/refreshDue()) can't write `::billedItemsTrigger
    // .isInitialized` directly. These two tiny accessors stay here for that
    // reason and are called from there instead. ----
    internal fun isBilledItemsTriggerReady() = ::billedItemsTrigger.isInitialized
    internal fun isPaidWarningTextReady() = ::paidWarningText.isInitialized

    internal fun saveDraft() {
        val hasContent = lines.isNotEmpty() ||
            customerName.text.toString().isNotBlank() ||
            itemName.text.toString().isNotBlank() ||
            qty.text.toString().isNotBlank() ||
            unitPrice.text.toString().isNotBlank()
        if (!hasContent) {
            clearDraft()
            return
        }

        val linesArray = JSONArray()
        lines.forEach { line ->
            linesArray.put(JSONObject().apply {
                put("barcode", line.barcode)
                put("itemName", line.itemName)
                put("qty", line.qty)
                put("unit", line.unit)
                put("unitPrice", line.unitPrice)
                put("cost", line.cost)
                put("amount", line.amount)
                put("mainUnit", line.mainUnit)
                put("secondaryUnit", line.secondaryUnit)
                put("secondaryUnitQty", line.secondaryUnitQty)
                put("tertiaryUnit", line.tertiaryUnit)
                put("tertiaryUnitQty", line.tertiaryUnitQty)
            })
        }

        val draft = JSONObject().apply {
            put("customer", customerName.text.toString())
            put("saleType", saleTypeSpinner.selectedItem?.toString() ?: "Retail")
            put("isCashSale", isCashSale)
            put("discount", discountInput.text.toString())
            put("paid", paidInput.text.toString())
            put("dateMillis", saleDateMillis)
            put("pendingItemName", itemName.text.toString())
            put("pendingQty", qty.text.toString())
            put("pendingPrice", unitPrice.text.toString())
            put("lines", linesArray)
        }

        draftPrefs().edit().putString(KEY_DRAFT, draft.toString()).apply()
    }

    internal fun clearDraft() {
        draftPrefs().edit().remove(KEY_DRAFT).apply()
    }

    private fun restoreDraftIfAny() {
        val raw = draftPrefs().getString(KEY_DRAFT, null) ?: return
        val draft = try { JSONObject(raw) } catch (e: Exception) { null } ?: return
        if (draftRestored) return
        draftRestored = true
        suppressDraftSave = true

        try {
            val customer = draft.optString("customer", "")
            if (customer.isNotBlank()) customerName.setText(customer)

            val saleType = draft.optString("saleType", "Retail")
            saleTypeSpinner.setSelection(if (saleType == "Wholesale") 1 else 0)

            val discount = draft.optString("discount", "")
            if (discount.isNotBlank()) discountInput.setText(discount)
            val paid = draft.optString("paid", "")
            if (paid.isNotBlank()) paidInput.setText(paid)

            // FIX (invoice date/time bug): a draft can sit unsaved for days (app
            // closed mid-sale, etc.). Restoring its old `dateMillis` here meant a
            // brand-new sale silently got stamped with a days-old date/time that
            // nobody noticed until printing. `saleDateMillis` already defaults to
            // System.currentTimeMillis() (see its declaration above), so we simply
            // leave it as "now" when restoring a draft — items/customer/etc. are
            // still restored, only the stale date is not. The date picker still
            // lets the user pick a different date manually if they really need to.

            val linesArray = draft.optJSONArray("lines")
            if (linesArray != null) {
                for (i in 0 until linesArray.length()) {
                    val o = linesArray.getJSONObject(i)
                    lines.add(
                        SaleLine(
                            barcode = o.optString("barcode"),
                            itemName = o.optString("itemName"),
                            qty = o.optDouble("qty", 0.0),
                            unit = o.optString("unit"),
                            unitPrice = o.optDouble("unitPrice", 0.0),
                            cost = o.optDouble("cost", 0.0),
                            amount = o.optDouble("amount", 0.0),
                            mainUnit = o.optString("mainUnit"),
                            secondaryUnit = o.optString("secondaryUnit"),
                            secondaryUnitQty = o.optDouble("secondaryUnitQty", 0.0),
                            tertiaryUnit = o.optString("tertiaryUnit"),
                            tertiaryUnitQty = o.optDouble("tertiaryUnitQty", 0.0)
                        )
                    )
                }
                renderItemsList()
                updateTotals()
            }

            val pendingItemName = draft.optString("pendingItemName", "")
            if (pendingItemName.isNotBlank()) {
                itemName.setText(pendingItemName)
                val match = products.find { it.name.equals(pendingItemName, ignoreCase = true) }
                if (match != null) onItemPicked(match.name)
            }
            val pendingQty = draft.optString("pendingQty", "")
            if (pendingQty.isNotBlank()) qty.setText(pendingQty)
            val pendingPrice = draft.optString("pendingPrice", "")
            if (pendingPrice.isNotBlank()) unitPrice.setText(pendingPrice)
            updateItemLineTotal()

            if (lines.isNotEmpty() || pendingItemName.isNotBlank()) {
                Toast.makeText(
                    this,
                    com.grocerypos.v11.util.Loc.t(this, "Restored your unsaved sale draft", "آپ کا غیر محفوظ شدہ سیل ڈرافٹ بحال کر دیا گیا"),
                    Toast.LENGTH_LONG
                ).show()
            }
        } finally {
            suppressDraftSave = false
        }
    }

    private fun loadFirmName() {
        lifecycleScope.launch {
            val savedName = viewModel.firmName()
            firmNameText.text = if (!savedName.isNullOrBlank()) savedName else "IBTISAAM Kiryana Store"
        }
    }

    private fun loadForEdit(invoice: String) {
        lifecycleScope.launch {
            val edit = viewModel.loadForEdit(invoice) ?: return@launch
            originalSale = edit.sale
            originalItems = edit.items

            saleDateMillis = edit.sale.createdAt
            dateValueText.text = formatDate(saleDateMillis)

            customerName.setText(edit.customerName)

            saleTypeSpinner.setSelection(if (edit.sale.saleType == "wholesale") 1 else 0)
            discountInput.setText(if (edit.sale.discount > 0) "%.2f".format(edit.sale.discount) else "")
            suppressPaidWatcher = true
            paidInput.setText(if (edit.sale.paid > 0) "%.2f".format(edit.sale.paid) else "0.00")
            suppressPaidWatcher = false
            val methodIndex = if (edit.sale.paymentMethod.equals("bank", ignoreCase = true)) 1 else 0
            paymentMethodSpinner.setSelection(methodIndex)
            // NEW (Split Payment): if this bill was originally saved with 2+
            // payment methods, re-open it in split mode so editing/re-saving it
            // doesn't silently collapse it back to a single method.
            if (edit.payments.size >= 2) {
                applySplitPayments(edit.payments)
            } else {
                clearSplitPayments()
            }

            lines.clear()
            lines.addAll(edit.lines)
            renderItemsList()
            recomputeAmounts()
            refreshDue()
            deleteButton.visibility = View.VISIBLE
        }
    }

    // ================= UI helpers (Purchase-style vocabulary) =================
    private fun premiumCard() = LinearLayout(this).apply {
        orientation = LinearLayout.VERTICAL
        setPadding(22, 18, 22, 18)
        background = strokedBg(border, cardBg, 18)
        layoutParams = LinearLayout.LayoutParams(LinearLayout.LayoutParams.MATCH_PARENT, LinearLayout.LayoutParams.WRAP_CONTENT).apply { setMargins(0, 0, 0, 14) }
        applyElevation(this, 3f)
    }

    private fun innerField() = LinearLayout(this).apply {
        orientation = LinearLayout.VERTICAL
        setPadding(18, 13, 18, 13)
        background = strokedBg(border, fieldFill, 14)
        layoutParams = LinearLayout.LayoutParams(LinearLayout.LayoutParams.MATCH_PARENT, LinearLayout.LayoutParams.WRAP_CONTENT).apply { setMargins(0, 0, 0, 12) }
    }

    private fun labelRow(label: String) = TextView(this).apply {
        text = label.uppercase(); textSize = 10.5f; setTextColor(Color.parseColor(textGray)); setTypeface(typeface, android.graphics.Typeface.BOLD); setPadding(0, 0, 0, 6); letterSpacing = 0.05f
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

    private fun pillChip(label: String, textSizeSp: Float = 12.5f, hPad: Int = 22, vPad: Int = 12, onClick: () -> Unit) = TextView(this).apply {
        this.text = label; textSize = textSizeSp; setTextColor(Color.parseColor(navy)); setTypeface(typeface, android.graphics.Typeface.BOLD); background = roundedBg(cardBg, 30); setPadding(hPad, vPad, hPad, vPad); setOnClickListener { onClick() }
    }

    internal fun circleIcon(label: String, colorHex: String, sizeDp: Int, onClick: (() -> Unit)? = null) = TextView(this).apply {
        this.text = label; textSize = 15f; setTextColor(Color.WHITE); gravity = Gravity.CENTER; background = ovalBg(colorHex); val px = (sizeDp * resources.displayMetrics.density).toInt(); layoutParams = android.view.ViewGroup.LayoutParams(px, px); if (onClick != null) setOnClickListener { onClick() }
    }



    internal fun dp(v: Int) = (v * resources.displayMetrics.density).toInt()

    internal fun simpleWatcher(onChange: () -> Unit) = object : TextWatcher {
        override fun beforeTextChanged(s: CharSequence?, a: Int, b: Int, c: Int) {}
        override fun onTextChanged(s: CharSequence?, a: Int, b: Int, c: Int) {}
        override fun afterTextChanged(s: Editable?) = onChange()
    }

    internal fun formatDate(millis: Long) = SimpleDateFormat("dd/MM/yyyy", Locale.getDefault()).format(Date(millis))

    private fun openDatePicker() {
        val cal = Calendar.getInstance().apply { timeInMillis = saleDateMillis }
        DatePickerDialog(this, { _, y, m, d ->
            cal.set(y, m, d)
            saleDateMillis = cal.timeInMillis
            dateValueText.text = formatDate(saleDateMillis)
        }, cal.get(Calendar.YEAR), cal.get(Calendar.MONTH), cal.get(Calendar.DAY_OF_MONTH)).apply {
            // FIX (consistent date picker style across the app): some OEM skins
            // default android.app.DatePickerDialog to the old scrolling-spinner
            // layout regardless of the app's Material theme. Forcing calendar
            // mode here guarantees the same grid-calendar picker everywhere.
            datePicker.calendarViewShown = true; datePicker.spinnersShown = false
        }.show()
    }

    // ---- CHANGED: overflow "Share" now resolves the selected customer (if any) so
    // openBillPreview() can pass a partyId through to BillPreviewActivity's WhatsApp
    // share flow — previously only the typed name was passed. ----
    private fun showOverflowMenu(anchor: View) {
        val popup = PopupMenu(this, anchor)
        popup.menu.add(com.grocerypos.v11.util.Loc.t(this, "Print", "پرنٹ"))
        popup.menu.add(com.grocerypos.v11.util.Loc.t(this, "Share", "شیئر کریں"))
        popup.setOnMenuItemClickListener {
            val invoice = editInvoice
            if (invoice == null) {
                Toast.makeText(this, "Save the sale first", Toast.LENGTH_SHORT).show()
            } else {
                val subtotal = lines.sumOf { it.amount }
                val enteredDiscount = discountInput.text.toString().toDoubleOrNull() ?: 0.0
                val enteredPaid = paidInput.text.toString().toDoubleOrNull() ?: 0.0
                val totals = DiscountCalculator.compute(subtotal, enteredDiscount, enteredPaid)
                val method = paymentMethodSpinner.selectedItem?.toString() ?: "Cash"
                val enteredName = customerName.text.toString().trim()
                val matchedCustomer = customers.find { it.name.equals(enteredName, ignoreCase = true) }
                openBillPreview(
                    invoice, forSaving = false,
                    party = enteredName, partyId = matchedCustomer?.id,
                    subtotal = subtotal, discount = totals.discount, total = totals.total,
                    paid = totals.paid, paymentMethod = method
                )
            }
            true
        }
        popup.show()
    }

    /** Continuous customer/product lists (for the two autocomplete fields) come
     * from [SaleViewModel.uiState]; one-shot save/delete/hold outcomes come from
     * [SaleViewModel.events]. The Activity never queries Room directly for
     * either. */
    private fun observeViewModel() {
        lifecycleScope.launch {
            viewModel.uiState.collectLatest { state ->
                customers = state.customers
                customerName.setAdapter(ArrayAdapter(this@SaleActivity, android.R.layout.simple_dropdown_item_1line, state.customers.map { it.name }))
                products = state.products
                // FIX (English search not working here): was a plain name-only
                // ArrayAdapter, so Android's default dropdown filter only ever
                // matched the Urdu `name` — typing the English searchTag alias
                // (Urdu keyboard off) found nothing, even though it worked on
                // every other search screen. ProductNameAdapter filters through
                // Product.matchesQuery() (name + searchTag) like they do.
                itemName.setAdapter(ProductNameAdapter(this@SaleActivity) { products })
            }
        }
        lifecycleScope.launch {
            viewModel.events.collectLatest { event -> handleSaleEvent(event) }
        }
    }

    private fun handleSaleEvent(event: SaleEvent) {
        // NEW: every branch except the ones that lead to another dialog/step re-arms
        // the Save button — these are all "the save did not happen" outcomes coming
        // back from SaveSaleUseCase, mirroring PurchaseActivity's handleViewModelEvent.
        when (event) {
            is SaleEvent.EmptyItems, is SaleEvent.CustomerRequiredForDue, is SaleEvent.StockIssue,
            is SaleEvent.DuplicateInvoice, is SaleEvent.InvalidLine,
            // NEW (10/10 Priority #7): a credit-limit block is also "the save did
            // not happen (yet)" — re-arm the button so the confirm dialog's
            // Cancel path (or just dismissing it) doesn't leave Save stuck disabled.
            is SaleEvent.CreditLimitExceeded -> {
                isSaving = false
                saveButton.isEnabled = true
            }
            else -> {}
        }
        when (event) {
            is SaleEvent.EmptyItems ->
                Toast.makeText(this, "Kam az kam ek item add karen", Toast.LENGTH_SHORT).show()
            is SaleEvent.CustomerRequiredForDue ->
                Toast.makeText(this, "Due amount ke liye Customer zaroori hai", Toast.LENGTH_SHORT).show()
            is SaleEvent.StockIssue ->
                Toast.makeText(this, event.message, Toast.LENGTH_LONG).show()
            is SaleEvent.DuplicateInvoice ->
                Toast.makeText(this, event.message, Toast.LENGTH_LONG).show()
            is SaleEvent.InvalidLine ->
                Toast.makeText(this, event.message, Toast.LENGTH_LONG).show()
            is SaleEvent.SaveSuccess -> {
                isSaving = false
                saveButton.isEnabled = true
                val result = event.result
                result.stockWarnings.forEach { warning ->
                    Toast.makeText(this, warning, Toast.LENGTH_LONG).show()
                }
                suppressDraftSave = true
                clearDraft()
                editInvoice = result.invoice
                Toast.makeText(
                    this,
                    if (result.isUpdate) "Sale updated" else "Sale saved",
                    Toast.LENGTH_SHORT
                ).show()
                openBillPreview(
                    invoice = result.invoice,
                    forSaving = true,
                    party = result.customer?.name ?: result.customerNameEntered,
                    partyId = result.customer?.id,
                    subtotal = result.subtotal,
                    discount = result.discount,
                    total = result.total,
                    paid = result.paid,
                    paymentMethod = result.paymentMethod
                )
            }
            is SaleEvent.QuickSaleSuccess -> {
                vibrateShort()
                Toast.makeText(
                    this,
                    if (event.isCredit) "Credit sale saved: ${event.invoice}" else "Cash sale saved: ${event.invoice}",
                    Toast.LENGTH_SHORT
                ).show()
            }
            is SaleEvent.QuickSaleStockIssue ->
                Toast.makeText(this, event.message, Toast.LENGTH_LONG).show()
            is SaleEvent.QuickSaleInvalidQty ->
                Toast.makeText(this, event.message, Toast.LENGTH_LONG).show()
            is SaleEvent.QuickSaleDuplicateInvoice ->
                Toast.makeText(this, event.message, Toast.LENGTH_LONG).show()
            is SaleEvent.SaleDeleted -> {
                Toast.makeText(this, "Sale deleted", Toast.LENGTH_SHORT).show()
                finish()
            }
            is SaleEvent.BillHeld -> {
                Toast.makeText(this, "Bill hold ho gayi", Toast.LENGTH_SHORT).show()
                clearAll()
            }
            is SaleEvent.CustomerAdded -> {
                Toast.makeText(this, "Customer added", Toast.LENGTH_SHORT).show()
                customerName.setText(event.name)
            }
            // NEW (10/10 Priority #7 — Credit Limit + Due Management): block with a
            // confirm, don't hard-reject — a shopkeeper often has good reasons to
            // let a trusted customer go over their usual limit occasionally.
            // "Save Anyway" re-reads the screen's current fields (unchanged since
            // the failed attempt a moment ago) and calls proceedSaveSale directly
            // with overrideCreditLimit=true — skipping saveSale()'s duplicate-bill
            // check again, since that already ran (or didn't need to) to get here.
            is SaleEvent.CreditLimitExceeded -> {
                AlertDialog.Builder(this)
                    .setTitle(com.grocerypos.v11.util.Loc.t(this, "Credit Limit Exceeded", "کریڈٹ لیمٹ سے تجاوز"))
                    .setMessage(
                        "${event.customerName} ki credit limit Rs.${formatQty(event.creditLimit)} hai. " +
                        "Ye bill save karne ke baad balance Rs.${formatQty(event.projectedBalance)} ho jayega.\n\n" +
                        "Phir bhi save karen?"
                    )
                    .setPositiveButton(com.grocerypos.v11.util.Loc.t(this, "Save Anyway", "پھر بھی محفوظ کریں")) { _, _ ->
                        val discountVal = discountInput.parseMoneyOrWarn(this, "Discount", "ڈسکاؤنٹ") ?: return@setPositiveButton
                        val paidVal = paidInput.parseMoneyOrWarn(this, "Paid Amount", "ادا شدہ رقم") ?: return@setPositiveButton
                        proceedSaveSale(
                            enteredCustomer = customerName.text.toString().trim(),
                            saleTypeLabel = saleTypeSpinner.selectedItem?.toString() ?: "Retail",
                            enteredDiscount = discountVal,
                            enteredPaid = paidVal,
                            paymentMethodLabel = paymentMethodSpinner.selectedItem?.toString() ?: "Cash",
                            overrideCreditLimit = true
                        )
                    }
                    .setNegativeButton(com.grocerypos.v11.util.Loc.t(this, "Cancel", "منسوخ"), null)
                    .show()
            }
            is SaleEvent.QuickSaleCreditLimitExceeded -> {
                val pending = pendingQuickSale
                AlertDialog.Builder(this)
                    .setTitle(com.grocerypos.v11.util.Loc.t(this, "Credit Limit Exceeded", "کریڈٹ لیمٹ سے تجاوز"))
                    .setMessage(
                        "${event.customerName} ki credit limit Rs.${formatQty(event.creditLimit)} hai. " +
                        "Ye sale save karne ke baad balance Rs.${formatQty(event.projectedBalance)} ho jayega.\n\n" +
                        "Phir bhi save karen?"
                    )
                    .setPositiveButton(com.grocerypos.v11.util.Loc.t(this, "Save Anyway", "پھر بھی محفوظ کریں")) { _, _ ->
                        if (pending != null) {
                            viewModel.saveQuickSale(pending.product, pending.qty, pending.price, pending.unit, pending.customerName, overrideCreditLimit = true)
                        }
                    }
                    .setNegativeButton(com.grocerypos.v11.util.Loc.t(this, "Cancel", "منسوخ"), null)
                    .show()
            }
        }
    }

    // ---- CHANGED (Roman Urdu request: "jab new party add karte hain to sirf party
    // name aata hai sale/purchase ke waqt, jab ke uska Sara form khulna chahiye") —
    // this used to be a single name-only EditText. Now it mirrors PartyActivity's
    // own "Add Customer" form (Name*, Phone, Credit Limit, Opening Balance) so a
    // customer quick-added mid-sale doesn't come out missing the details you'd
    // normally fill in from the Customers & Suppliers screen. ----
    private fun promptAddCustomer() {
        fun microLabel(text: String) = TextView(this).apply {
            this.text = text; textSize = 11.5f
            setTextColor(Color.parseColor(textGray))
            setTypeface(typeface, android.graphics.Typeface.BOLD)
            setPadding(0, 0, 0, 8); letterSpacing = 0.04f
        }
        fun field(hint: String, inputType: Int? = null) = EditText(this).apply {
            this.hint = hint
            setTextColor(Color.parseColor(textDark))
            background = strokedBg(border, fieldFill, 14)
            setPadding(18, 16, 18, 16)
            textSize = 15f
            if (inputType != null) this.inputType = inputType
        }

        val body = LinearLayout(this).apply { orientation = LinearLayout.VERTICAL; setPadding(28, 24, 28, 8) }
        body.addView(microLabel("NAME *"))
        val nameField = field("Customer name")
        body.addView(nameField); body.addView(spacer(16))

        body.addView(microLabel("PHONE (OPTIONAL)"))
        val phoneField = field("Phone", InputType.TYPE_CLASS_PHONE)
        body.addView(phoneField); body.addView(spacer(16))

        body.addView(microLabel("CREDIT LIMIT (OPTIONAL)"))
        val creditLimitField = field("Credit limit", InputType.TYPE_CLASS_NUMBER or InputType.TYPE_NUMBER_FLAG_DECIMAL)
        body.addView(creditLimitField); body.addView(spacer(16))

        body.addView(microLabel("OPENING BALANCE (RS, IF ANY PREVIOUS DUE)"))
        val openingField = field("Opening balance", InputType.TYPE_CLASS_NUMBER or InputType.TYPE_NUMBER_FLAG_DECIMAL)
        body.addView(openingField)

        val scroll = ScrollView(this).apply { addView(body) }

        AlertDialog.Builder(this)
            .setTitle("New Customer")
            .setView(scroll)
            .setPositiveButton("Add") { _, _ ->
                val name = nameField.text.toString().trim()
                if (name.isEmpty()) {
                    Toast.makeText(this, "Name is required", Toast.LENGTH_SHORT).show()
                    return@setPositiveButton
                }
                val phone = phoneField.text.toString().trim()
                val creditLimit = creditLimitField.parseMoneyOrWarn(this, "Credit Limit", "کریڈٹ حد") ?: return@setPositiveButton
                val openingBalance = openingField.parseMoneyOrWarn(this, "Opening Balance", "افتتاحی بیلنس") ?: return@setPositiveButton
                viewModel.addCustomer(name, phone, creditLimit, openingBalance)
            }
            .setNegativeButton("Cancel", null)
            .show()
    }

    // ---- FIX (unit auto-selection): single source of truth for which unit tier
    // should be pre-selected when an item is picked, used both here (normal Add
    // Item flow) and in the Quick Sale dialog below — so both stay in sync.
    //
    //   1-tier (no secondary unit at all)         -> index 0 (the only unit)
    //   2-tier (secondary exists, no tertiary):
    //       - Beverages category                  -> index 0 (1st/primary unit)
    //       - every other category                 -> index 1 (2nd/secondary unit)
    //   3-tier (secondary AND tertiary both exist) -> index 1 (secondary/2nd unit)
    //
    // ---- CHANGED (category-based unit auto-select): previously every 2-tier product
    // (no tertiary) defaulted to index 0 regardless of category. Now Beverages keep
    // defaulting to the 1st unit, while every other 2-tier category defaults to the
    // 2nd unit instead — matching how those items are actually sold day to day. ----

    // ================= QUICK SALE =================


    private fun vibrateShort() {
        try {
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
                val vm = getSystemService(android.os.VibratorManager::class.java)
                vm?.defaultVibrator?.vibrate(
                    android.os.VibrationEffect.createOneShot(35, android.os.VibrationEffect.DEFAULT_AMPLITUDE)
                )
            } else {
                @Suppress("DEPRECATION")
                val v = getSystemService(Context.VIBRATOR_SERVICE) as? android.os.Vibrator
                if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                    v?.vibrate(android.os.VibrationEffect.createOneShot(35, android.os.VibrationEffect.DEFAULT_AMPLITUDE))
                } else {
                    @Suppress("DEPRECATION")
                    v?.vibrate(35)
                }
            }
        } catch (e: Exception) {
            // no vibrator permission/hardware — ignore silently
        }
    }

    // ================= Save =================
    // ---- discount/total/paid/due come from the same DiscountCalculator used
    // everywhere else in this screen (recomputeAmounts/refreshDue), so the live
    // preview and the saved bill always agree. ----
    private fun saveSale() {
        if (isSaving) return
        if (lines.isEmpty()) { Toast.makeText(this, "Kam az kam ek item add karen", Toast.LENGTH_SHORT).show(); return }

        val enteredCustomer = customerName.text.toString().trim()
        val enteredDiscount = discountInput.parseMoneyOrWarn(this, "Discount", "ڈسکاؤنٹ") ?: return
        val enteredPaid = paidInput.parseMoneyOrWarn(this, "Paid Amount", "ادا شدہ رقم") ?: return
        val saleTypeLabel = saleTypeSpinner.selectedItem?.toString() ?: "Retail"
        val paymentMethodLabel = paymentMethodSpinner.selectedItem?.toString() ?: "Cash"

        // NEW: same-customer + same-total heuristic as PurchaseActivity's
        // checkDuplicateAndProceed — computed with the same DiscountCalculator the
        // save path itself uses, so the total here matches what will actually land
        // in the sales table. Runs before the real save; skips the sale currently
        // being edited so re-saving an edit of itself never trips a false alarm.
        val subtotal = lines.sumOf { it.amount }
        val totals = DiscountCalculator.compute(subtotal, enteredDiscount, enteredPaid)
        checkDuplicateAndProceedSale(enteredCustomer, totals.total) {
            proceedSaveSale(enteredCustomer, saleTypeLabel, enteredDiscount, enteredPaid, paymentMethodLabel)
        }
    }

    // FIX (Double Bill Alert — match by sale DATE, not "last 24 hours"): mirrors the
    // identical fix in PurchaseActivity.checkDuplicateAndProceed(). This used to
    // compare `r.createdAt` (real-world instant the earlier sale was saved) against
    // `now` (real-world instant THIS save was tapped) in a rolling 24-hour window —
    // so re-entering an old/backdated sale days later never triggered it even for
    // the exact same customer, amount, AND sale date. Now compares each candidate's
    // `createdAt` (which doubles as the sale's own recorded date — see
    // proceedSaveSale's `createdAt = saleDateMillis`) against this sale's
    // `saleDateMillis` by calendar day, with no time-window cutoff.
    private fun checkDuplicateAndProceedSale(customer: String, grandTotal: Double, onProceed: () -> Unit) {
        val custForMatch = customer.ifBlank { "Walk-in" }
        lifecycleScope.launch {
            val db = PosDatabase.get(this@SaleActivity)
            val recent = db.saleDao().allSales()
            val dayFmt = SimpleDateFormat("yyyyMMdd", Locale.getDefault())
            val targetDay = dayFmt.format(Date(saleDateMillis))
            val duplicate = recent.firstOrNull { r ->
                r.invoice != editInvoice &&
                r.status != "returned" &&
                r.customerName.equals(custForMatch, ignoreCase = true) &&
                r.total == grandTotal &&
                dayFmt.format(Date(r.createdAt)) == targetDay
            }
            if (duplicate == null) { onProceed(); return@launch }
            val fmt = SimpleDateFormat("dd MMM yyyy, hh:mm a", Locale.getDefault())
            android.app.AlertDialog.Builder(this@SaleActivity)
                .setTitle(com.grocerypos.v11.util.Loc.t(this@SaleActivity, "Possible Duplicate Bill", "ممکنہ ڈپلیکیٹ بل"))
                .setMessage(
                    com.grocerypos.v11.util.Loc.t(
                        this@SaleActivity,
                        "A sale for $custForMatch of Rs %.0f was already saved on ${fmt.format(Date(duplicate.createdAt))} (Invoice #${duplicate.invoice}).\n\nSave this one anyway?".format(grandTotal),
                        "$custForMatch کے لیے Rs %.0f کی سیل پہلے ہی ${fmt.format(Date(duplicate.createdAt))} کو محفوظ ہو چکی ہے (انوائس نمبر ${duplicate.invoice})۔\n\nکیا پھر بھی محفوظ کریں؟".format(grandTotal)
                    )
                )
                .setPositiveButton(com.grocerypos.v11.util.Loc.t(this@SaleActivity, "Save Anyway", "پھر بھی محفوظ کریں")) { _, _ -> onProceed() }
                .setNegativeButton(com.grocerypos.v11.util.Loc.t(this@SaleActivity, "Cancel", "منسوخ کریں"), null)
                .show()
        }
    }

    private fun proceedSaveSale(
        enteredCustomer: String,
        saleTypeLabel: String,
        enteredDiscount: Double,
        enteredPaid: Double,
        paymentMethodLabel: String,
        // NEW (10/10 Priority #7 — Credit Limit + Due Management): true only when
        // re-called from handleSaleEvent's CreditLimitExceeded confirm dialog
        // below — a normal saveSale()->checkDuplicateAndProceedSale() path always
        // passes the default false.
        overrideCreditLimit: Boolean = false
    ) {
        isSaving = true
        saveButton.isEnabled = false
        // FIX (Phase 1 - Data Safety): the whole save (stock reversal on edit, stock
        // check, stock deduction, sale+items insert, customer balance update, cash
        // transaction insert) runs inside a single Room transaction in
        // SaleRepository.saveSale — see that function for details. Validation (empty
        // items, due needs a customer, discount/total/paid clamping) happens first in
        // SaveSaleUseCase; this screen only reacts to the resulting SaleEvent.
        viewModel.saveSale(
            editInvoice = editInvoice,
            enteredCustomerName = enteredCustomer,
            saleTypeLabel = saleTypeLabel,
            lines = lines.toList(),
            discountInput = enteredDiscount,
            paidInput = enteredPaid,
            paymentMethodLabel = paymentMethodLabel,
            saleDateMillis = saleDateMillis,
            original = originalSale,
            originalItems = originalItems,
            overrideCreditLimit = overrideCreditLimit,
            payments = splitPayments.toList()
        )
    }

    // ---- Purchase-style single reusable bill-preview launcher, used both for the
    // normal post-save navigation and for the overflow menu's reprint/share flow.
    // CHANGED: now also accepts partyId so BillPreviewActivity can look up (or later
    // save) the customer's phone number for the WhatsApp share button. ----
    private fun openBillPreview(invoice: String, forSaving: Boolean, party: String, partyId: Long?, subtotal: Double, discount: Double, total: Double, paid: Double, paymentMethod: String) {
        val itemsEncoded = lines.joinToString("\u0002") {
            listOf(it.itemName, formatQty(it.qty), it.unit, it.unitPrice, it.amount).joinToString("\u0003")
        }
        val previewIntent = Intent(this, BillPreviewActivity::class.java).apply {
            putExtra(BillPreviewActivity.EXTRA_TYPE, "sale")
            putExtra(BillPreviewActivity.EXTRA_REFERENCE, invoice)
            putExtra(BillPreviewActivity.EXTRA_PARTY_NAME, party)
            putExtra(BillPreviewActivity.EXTRA_PARTY_LABEL, "Customer")
            if (partyId != null) putExtra(BillPreviewActivity.EXTRA_PARTY_ID, partyId)
            putExtra(BillPreviewActivity.EXTRA_DATE_MILLIS, saleDateMillis)
            putExtra(BillPreviewActivity.EXTRA_SUBTOTAL, subtotal)
            putExtra(BillPreviewActivity.EXTRA_DISCOUNT, discount)
            putExtra(BillPreviewActivity.EXTRA_TOTAL, total)
            putExtra(BillPreviewActivity.EXTRA_PAID, paid)
            putExtra(BillPreviewActivity.EXTRA_PAYMENT_METHOD, paymentMethod)
            putExtra(BillPreviewActivity.EXTRA_ITEMS_ENCODED, itemsEncoded)
        }
        startActivity(previewIntent)
        if (forSaving) finish()
    }

    private fun confirmDeleteSale() {
        val invoice = editInvoice ?: return
        AlertDialog.Builder(this)
            .setTitle(com.grocerypos.v11.util.Loc.t(this, "Delete Sale", "سیل حذف کریں"))
            .setMessage(com.grocerypos.v11.util.Loc.t(this, "This will remove the bill and reverse its stock and customer balance effect. Continue?", "یہ بل حذف کر دے گا اور اس کا اسٹاک اور کسٹمر بیلنس پر اثر واپس کر دے گا۔ جاری رکھیں؟"))
            .setPositiveButton(com.grocerypos.v11.util.Loc.t(this, "Delete", "حذف کریں")) { _, _ -> deleteSale(invoice) }
            .setNegativeButton(com.grocerypos.v11.util.Loc.t(this, "Cancel", "منسوخ"), null)
            .show()
    }

    private fun deleteSale(invoice: String) {
        // FIX (Phase 1 - Data Safety): stock reversal + balance reversal + row
        // deletes are one atomic transaction — see SaleRepository.deleteSale.
        viewModel.deleteSale(invoice, originalSale, originalItems)
    }

    internal fun formatQty(v: Double): String =
        if (v == v.toLong().toDouble()) v.toLong().toString() else v.toString()

    // ================= Split Payment (multiple payment methods) =================
    // NEW: lets one bill be paid across more than one method — e.g. Rs 300 Cash +
    // Rs 200 Bank on a Rs 500 bill — instead of the single Cash/Bank spinner
    // forcing the whole Paid Amount onto one method. Kept deliberately simple:
    // Cash/Bank rows only (matches paymentMethodSpinner's own options), no limit
    // on row count. `splitPayments` (declared above with paymentMethodSpinner) is
    // the source of truth once applied — saveSale()/proceedSaveSale() forward it
    // straight through, and SaveSaleUseCase computes the real paid/due and the
    // combined "Cash + Bank" method label from it, ignoring paidInput/the spinner
    // for as long as a split is active.
    private fun openSplitPaymentDialog() {
        val density = resources.displayMetrics.density
        fun dp(v: Int) = (v * density).toInt()

        val container = LinearLayout(this).apply {
            orientation = LinearLayout.VERTICAL
            setPadding(dp(24), dp(16), dp(24), dp(8))
        }
        val totalDue = recomputeAmounts()
        val infoText = TextView(this).apply {
            text = com.grocerypos.v11.util.Loc.t(
                this@SaleActivity,
                "Bill Total: Rs %.2f".format(totalDue),
                "بل کل: Rs %.2f".format(totalDue)
            )
            textSize = 13f
            setTextColor(Color.parseColor("#666666"))
            setPadding(0, 0, 0, dp(10))
        }
        container.addView(infoText)

        val rowsContainer = LinearLayout(this).apply { orientation = LinearLayout.VERTICAL }
        container.addView(rowsContainer)

        val methods = listOf("Cash", "Bank")
        fun addRow(method: String, amount: Double) {
            val row = LinearLayout(this).apply {
                orientation = LinearLayout.HORIZONTAL
                gravity = Gravity.CENTER_VERTICAL
                setPadding(0, dp(6), 0, dp(6))
            }
            val methodSpinner = Spinner(this).apply {
                adapter = ArrayAdapter(this@SaleActivity, android.R.layout.simple_spinner_dropdown_item, methods)
                setSelection(methods.indexOf(method).coerceAtLeast(0))
                layoutParams = LinearLayout.LayoutParams(0, LinearLayout.LayoutParams.WRAP_CONTENT, 1f)
            }
            val amountField = EditText(this).apply {
                hint = "0.00"
                if (amount > 0.0) setText(if (amount == amount.toLong().toDouble()) amount.toLong().toString() else amount.toString())
                inputType = InputType.TYPE_CLASS_NUMBER or InputType.TYPE_NUMBER_FLAG_DECIMAL
                gravity = Gravity.END
                minWidth = dp(90)
                layoutParams = LinearLayout.LayoutParams(0, LinearLayout.LayoutParams.WRAP_CONTENT, 1f).apply { setMargins(dp(8), 0, dp(8), 0) }
            }
            val removeBtn = TextView(this).apply {
                text = "\u2715"
                setTextColor(Color.parseColor(red))
                setTypeface(typeface, android.graphics.Typeface.BOLD)
                setPadding(dp(8), dp(4), dp(8), dp(4))
                setOnClickListener { rowsContainer.removeView(row) }
            }
            row.addView(methodSpinner)
            row.addView(amountField)
            row.addView(removeBtn)
            rowsContainer.addView(row)
        }

        if (splitPayments.isNotEmpty()) {
            splitPayments.forEach { (m, a) -> addRow(m, a) }
        } else {
            // Helpful default: two blank rows, Cash and Bank, nudging the cashier
            // toward actually splitting rather than just re-typing one method.
            addRow("Cash", 0.0)
            addRow("Bank", 0.0)
        }

        val addRowLink = TextView(this).apply {
            text = com.grocerypos.v11.util.Loc.t(this@SaleActivity, "+ Add another method", "+ ایک اور طریقہ شامل کریں")
            setTextColor(Color.parseColor(navy))
            setTypeface(typeface, android.graphics.Typeface.BOLD)
            textSize = 13f
            setPadding(0, dp(8), 0, dp(8))
            setOnClickListener { addRow("Cash", 0.0) }
        }
        container.addView(addRowLink)

        val scrollWrapper = ScrollView(this).apply { addView(container) }

        AlertDialog.Builder(this)
            .setTitle(com.grocerypos.v11.util.Loc.t(this, "Split Payment", "ادائیگی تقسیم کریں"))
            .setView(scrollWrapper)
            .setPositiveButton(com.grocerypos.v11.util.Loc.t(this, "Apply", "لاگو کریں"), null)
            .setNegativeButton(com.grocerypos.v11.util.Loc.t(this, "Cancel", "منسوخ کریں"), null)
            .also { builder ->
                if (splitPayments.isNotEmpty()) {
                    // Third button to fully undo the split and go back to the
                    // single-method spinner — only shown once a split already exists.
                    builder.setNeutralButton(com.grocerypos.v11.util.Loc.t(this, "Remove Split", "تقسیم ہٹائیں"), null)
                }
            }
            .create()
            .also { dialog ->
                dialog.setOnShowListener {
                    dialog.getButton(AlertDialog.BUTTON_POSITIVE).setOnClickListener {
                        val entries = (0 until rowsContainer.childCount).mapNotNull { i ->
                            val row = rowsContainer.getChildAt(i) as LinearLayout
                            val method = (row.getChildAt(0) as Spinner).selectedItem?.toString() ?: "Cash"
                            val amtField = row.getChildAt(1) as EditText
                            val amt = amtField.parseMoneyOrWarn(this, "Payment Amount", "ادائیگی کی رقم") ?: return@setOnClickListener
                            if (amt > 0.009) method to amt else null
                        }
                        if (entries.isEmpty()) {
                            Toast.makeText(this, com.grocerypos.v11.util.Loc.t(this, "Kam az kam ek payment amount daalen", "کم از کم ایک ادائیگی کی رقم درج کریں"), Toast.LENGTH_SHORT).show()
                            return@setOnClickListener
                        }
                        applySplitPayments(entries)
                        dialog.dismiss()
                    }
                    dialog.getButton(AlertDialog.BUTTON_NEUTRAL)?.setOnClickListener {
                        clearSplitPayments()
                        dialog.dismiss()
                    }
                }
                dialog.show()
            }
    }

    private fun applySplitPayments(entries: List<Pair<String, Double>>) {
        splitPayments = entries.toMutableList()
        val sum = entries.sumOf { it.second }
        paidInput.setText(if (sum == sum.toLong().toDouble()) sum.toLong().toString() else sum.toString())
        // paidInput's own watcher already runs refreshDue()/saveDraft() off the
        // setText() above — no need to duplicate that here.
        paidInput.isEnabled = false
        paymentMethodSpinner.isEnabled = false
        updateSplitPaymentSummaryText()
    }

    internal fun clearSplitPayments() {
        splitPayments = mutableListOf()
        paidInput.isEnabled = true
        paymentMethodSpinner.isEnabled = true
        updateSplitPaymentSummaryText()
    }

    internal fun updateSplitPaymentSummaryText() {
        if (splitPayments.isEmpty()) {
            splitPaymentSummary.visibility = View.GONE
            splitPaymentLink.visibility = View.VISIBLE
            splitPaymentLink.text = com.grocerypos.v11.util.Loc.t(this, "+ Split Payment (multiple methods)", "+ ادائیگی تقسیم کریں (ایک سے زیادہ طریقے)")
            return
        }
        val breakdown = splitPayments.joinToString("  +  ") { (m, a) -> "$m Rs %.0f".format(a) }
        splitPaymentSummary.text = com.grocerypos.v11.util.Loc.t(
            this,
            "Split: $breakdown   \u2715",
            "تقسیم: $breakdown   \u2715"
        )
        splitPaymentSummary.visibility = View.VISIBLE
        splitPaymentSummary.setOnClickListener {
            AlertDialog.Builder(this)
                .setTitle(com.grocerypos.v11.util.Loc.t(this, "Remove Split Payment?", "تقسیم شدہ ادائیگی ہٹائیں؟"))
                .setPositiveButton(com.grocerypos.v11.util.Loc.t(this, "Remove", "ہٹائیں")) { _, _ -> clearSplitPayments() }
                .setNegativeButton(com.grocerypos.v11.util.Loc.t(this, "Edit", "ترمیم کریں")) { _, _ -> openSplitPaymentDialog() }
                .show()
        }
        splitPaymentLink.visibility = View.VISIBLE
        splitPaymentLink.text = com.grocerypos.v11.util.Loc.t(this, "\u270E Edit split payment", "\u270E تقسیم میں ترمیم کریں")
    }
}

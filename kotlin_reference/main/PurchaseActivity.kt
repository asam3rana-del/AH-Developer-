package com.grocerypos.v11.ui
import com.grocerypos.v11.SyncQueueHelper

import com.grocerypos.v11.R
import com.grocerypos.v11.util.keepContentAboveKeyboard
import com.grocerypos.v11.util.parseMoneyOrWarn

import android.app.DatePickerDialog
import android.content.Context
import android.content.Intent
import android.graphics.Color
import android.graphics.Rect
import android.graphics.drawable.GradientDrawable
import android.os.Build
import android.os.Bundle
import android.text.Editable
import android.text.InputType
import android.text.TextWatcher
import android.view.Gravity
import android.view.View
import android.view.ViewGroup
import android.view.ViewOutlineProvider
import android.view.WindowManager
import android.view.inputmethod.EditorInfo
import android.widget.*
import androidx.activity.result.contract.ActivityResultContracts
import androidx.activity.viewModels
import androidx.appcompat.widget.PopupMenu
import androidx.lifecycle.lifecycleScope
import com.grocerypos.v11.*
import com.grocerypos.v11.data.PartyRepository
import com.grocerypos.v11.data.PurchaseEditData
import com.grocerypos.v11.data.PurchaseLine
import com.grocerypos.v11.domain.ScannedLine
import com.grocerypos.v11.util.ThemeManager
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.flow.collectLatest
import kotlinx.coroutines.flow.first
import kotlinx.coroutines.launch
import android.util.Log
import org.json.JSONArray
import org.json.JSONObject
import java.text.SimpleDateFormat
import java.util.Calendar
import java.util.Date
import java.util.Locale
import com.grocerypos.v11.ui.components.*

class PurchaseActivity : ThemedActivity() {

    private val viewModel: PurchaseViewModel by viewModels { PurchaseViewModelFactory(applicationContext) }

    companion object {
        const val EXTRA_BILL_NO = "billNo"
        private const val PREFS_NAME = "purchase_draft_prefs"
        private const val KEY_DRAFT = "draft_json"
        private const val TAG = "PurchaseActivity"
    }

    // ---------- Premium palette ----------
    private var bg = "#F5F7FA"
    private var cardWhite = "#FFFFFF"
    private var textDark = "#111827"
    private var textMuted = "#8892A0"
    private var border = "#E7EAF0"
    private var red = "#E5484D"
    private var fieldFill = "#FAFBFD"

    // CHANGED (user asked: Sale and Purchase's main brand color should match the
    // "Today's profit" blue on the dashboard, applied app-wide as the one central
    // accent): header/Save Purchase/totals now use flatBlueFg. `teal`/`successGreen`
    // stay teal — that's the app's separate "positive amount" (paid/due) semantic,
    // not the brand accent, so it's left alone.
    private var navy = "#1450C7"       // header/brand accent — profit blue, matches Sale/Items/Settings/Reports
    private var navyLight = "#1450C7" // flat design, no gradient — same as navy
    private var teal = "#0A8A4E"       // flatTealFg — positive amount accent (unchanged)
    private var gold = "#854F0B"       // flatAmberFg — "best price" badge
    private var amberBadge = "#FAEEDA" // flatAmberBg
    private var successGreen = "#0A8A4E" // flatTealFg — unified with Reports' "positive" color

    private fun loadThemePrefs() {
        val p = ThemeManager.palette(this)
        bg = p.bg
        cardWhite = p.cardWhite
        textDark = p.textDark
        textMuted = p.textMuted
        border = p.border
        red = p.red
        fieldFill = p.fieldFill
        navy = p.flatBlueFg
        navyLight = p.flatBlueFg
        teal = p.flatTealFg
        gold = p.flatAmberFg
        amberBadge = p.flatAmberBg
        successGreen = p.flatTealFg
    }

    private lateinit var dateValueText: TextView
    private lateinit var firmNameText: TextView
    private lateinit var supplierBalanceText: TextView
    private lateinit var partyBox: LinearLayout
    private lateinit var partyName: AutoCompleteTextView
    // NEW ("10/10 Purchase screen" item #2): the SUPPLIER's own invoice/bill number
    // (optional) — separate from our own auto-generated billNo, used for an exact
    // duplicate-bill check.
    private lateinit var supplierInvoiceNoInput: EditText
    private lateinit var itemEntrySection: LinearLayout
    private lateinit var addItemsTrigger: TextView
    private lateinit var itemName: AutoCompleteTextView
    private lateinit var qty: EditText
    private lateinit var unitSpinner: Spinner
    private lateinit var unitToggleRow: LinearLayout
    private lateinit var rate: EditText
    private lateinit var totalLotPrice: EditText
    // NEW ("10/10 Purchase screen" item #7): retail (salePrice) / wholesale rate,
    // editable right here, so a purchase can also update what an item sells for.
    private lateinit var retailRateInput: EditText
    private lateinit var wholesaleRateInput: EditText
    // NEW ("10/10 Purchase screen" item #15): live warning if this purchase rate
    // would eat into or invert the item's current sale margin.
    private lateinit var marginWarningText: TextView
    private lateinit var conversionInfo: TextView
    private lateinit var totalAmountText: TextView
    private lateinit var addItemButton: Button
    // NEW: shown only while editing an existing billed line, lets the user back out
    // without saving the change (row keeps its old values).
    private lateinit var cancelEditButton: TextView
    // NEW: handle to the "Billed Items" popup so editLine() can close it before the
    // entry fields (which live outside the dialog) are scrolled into view.
    private var billedItemsDialog: android.app.AlertDialog? = null
    private lateinit var billedItemsHeader: LinearLayout
    private lateinit var billedItemsSummaryText: TextView
    private lateinit var billedItemsChevron: TextView
    private lateinit var itemsContainer: LinearLayout
    private lateinit var grandTotalText: TextView
    private lateinit var paymentSection: LinearLayout
    private lateinit var paidInput: EditText
    private lateinit var dueAmountText: TextView
    // NEW (Split Payment / multiple payment methods): mirrors SaleActivity's
    // paymentMethodSpinner + splitPaymentLink/splitPaymentSummary — lets one
    // purchase bill be paid across Cash + Bank instead of forcing it all onto
    // one method (previously Purchase always hardcoded paymentMethod = "Cash").
    private lateinit var paymentMethodSpinner: Spinner
    private lateinit var splitPaymentLink: TextView
    private lateinit var splitPaymentSummary: TextView
    // Source of truth for a split-tender purchase — each entry is (method, amount).
    // Empty means "single method", using paymentMethodSpinner + paidInput exactly
    // as before this feature.
    internal var splitPayments: MutableList<Pair<String, Double>> = mutableListOf()
    private lateinit var paidWarningText: TextView
    private lateinit var saveButton: Button
    private lateinit var deleteButton: Button
    private lateinit var overflowButton: TextView
    private lateinit var scrollArea: ScrollView

    private var suppliers = listOf<Supplier>()
    // PERMANENT FIX (balance drift — this screen showing a different figure than the
    // Dashboard for the same supplier): party balances everywhere else already come
    // from PartyRepository's live ledger computation, never the stored, driftable
    // `.balance` field — see PartyRepository.liveSupplierBalance(). This screen's own
    // "Party balance" line needs the same source of truth, or it can show a stale
    // number the Dashboard/Party screens don't agree with.
    private val partyRepo by lazy { PartyRepository(PosDatabase.get(this), applicationContext) }
    // Guards against a slow lookup for an old party name landing after the user has
    // already moved on to typing/selecting a different party.
    private var balanceLookupToken = 0
    private var products = listOf<Product>()
    private var allUnits = listOf("pcs", "kg", "box", "dozen", "carton", "ctn", "outer", "dabbi")
    private val lines = mutableListOf<PurchaseLine>()
    // NEW: when a billed item's ✎ (edit) icon is tapped, its index is stashed here so
    // addItem() updates that line in place instead of appending a new one — previously
    // fixing a mistake meant deleting the line and re-typing it from scratch.
    private var editingLineIndex: Int? = null
    private var purchaseDateMillis = System.currentTimeMillis()
    private var selectedProduct: Product? = null

    private var lastMainQty: Double = 0.0
    private var suppressQtyWatcher = false
    private var lastMainRate: Double = 0.0
    private var lastPurchaseMainRate: Double = 0.0
    private var suppressRateWatcher = false
    private var suppressTotalLotWatcher = false
    // NEW ("10/10 Purchase screen" item #7): retail/wholesale rate state, mirroring
    // lastMainRate above — main-unit-basis values the retail/wholesale fields
    // currently represent, plus the product's rates as they stood BEFORE this
    // purchase screen touched them (used by the item #15 margin warning, which
    // must compare against the CURRENT stored sale price, not a value the user is
    // mid-edit on).
    private var lastMainRetailRate: Double = 0.0
    private var lastMainWholesaleRate: Double = 0.0
    private var suppressRetailRateWatcher = false
    private var suppressWholesaleRateWatcher = false
    private var currentProductSalePriceMain: Double = 0.0
    private var currentProductWholesalePriceMain: Double = 0.0
    private var editBillNo: String? = null
    private var originalPurchase: Purchase? = null
    private var originalItems: List<PurchaseItem> = emptyList()
    private var suppressDraftSave = false
    private var draftRestored = false

    private var isSaving = false

    // ---- ADDED (tablet / commercial "desktop view"): same two-pane treatment
    // as SaleActivity — on wide screens the cart/billing section becomes a
    // separate right-hand pane that stays visible, instead of only being
    // reachable through the "Billed Items" popup dialog. Phones keep the
    // original single-column, dialog-based flow untouched. ----
    private var isTabletWide = false

    private var scrollTargetView: View? = null
    private var scrollAlignTop: Boolean = true

    private val billScanLauncher = registerForActivityResult(ActivityResultContracts.StartActivityForResult()) { result ->
        if (result.resultCode == RESULT_OK) {
            val json = result.data?.getStringExtra(BillScanActivity.RESULT_ITEMS_JSON)
            if (!json.isNullOrBlank()) handleScannedItems(json)
        }
    }

    private fun safeLaunch(label: String, block: suspend () -> Unit) {
        lifecycleScope.launch {
            try {
                block()
            } catch (e: CancellationException) {
                throw e
            } catch (e: Exception) {
                Log.e(TAG, "safeLaunch[$label] failed", e)
                Toast.makeText(this@PurchaseActivity, "Error in $label: ${e.message ?: e.javaClass.simpleName}", Toast.LENGTH_LONG).show()
            }
        }
    }

    override fun onCreate(b: Bundle?) {
        super.onCreate(b)
        // FIX (Phase 4 - Security): role check enforced here — MainActivity only shows
        // the Purchase quick-action to admin, it doesn't stop a cashier/manager opening
        // this Activity another way.
        // UPDATED: Purchase editing restricted to admin only (manager access removed per
        // owner's request — every kind of editing in the app should be admin-only now).
        val myRole = getSharedPreferences("session", MODE_PRIVATE).getString("role", "cashier") ?: "cashier"
        if (myRole != "admin") {
            Toast.makeText(this, "Sirf Admin is screen ko access kar sakte hain", Toast.LENGTH_LONG).show()
            finish()
            return
        }
        window.setSoftInputMode(WindowManager.LayoutParams.SOFT_INPUT_ADJUST_RESIZE)
        com.grocerypos.v11.util.CrashHandler.install(this)
        com.grocerypos.v11.util.CrashHandler.getLastCrash(this)?.let { crashText -> showCrashDialog(crashText) }
        try {
            loadThemePrefs()
            editBillNo = intent.getStringExtra(EXTRA_BILL_NO)
            buildUi()
        } catch (e: Exception) {
            Log.e(TAG, "onCreate: fatal error building Purchase screen", e)
            Toast.makeText(this, "Purchase screen error: ${e.message ?: e.javaClass.simpleName}", Toast.LENGTH_LONG).show()
            finish()
        }
    }

    private fun showCrashDialog(crashText: String) {
        android.app.AlertDialog.Builder(this)
            .setTitle("Pichli baar app crash hui thi")
            .setMessage(if (crashText.length > 3000) crashText.take(3000) + "\n\n…(truncated, use Share for full text)" else crashText)
            .setPositiveButton("Share") { _, _ ->
                startActivity(Intent.createChooser(com.grocerypos.v11.util.CrashHandler.shareIntent(crashText), "Share crash log"))
                com.grocerypos.v11.util.CrashHandler.clearLastCrash(this)
            }
            .setNeutralButton("Copy") { _, _ ->
                val clipboard = getSystemService(Context.CLIPBOARD_SERVICE) as android.content.ClipboardManager
                clipboard.setPrimaryClip(android.content.ClipData.newPlainText("crash", crashText))
                Toast.makeText(this, "Copied", Toast.LENGTH_SHORT).show()
            }
            .setNegativeButton("Dismiss") { _, _ -> com.grocerypos.v11.util.CrashHandler.clearLastCrash(this) }
            .setCancelable(false)
            .show()
    }

    private fun buildUi() {
        // ---- ADDED (tablet / desktop-style layout): same 700dp breakpoint as
        // SaleActivity, tune in one place if a specific tablet needs a
        // different value. ----
        isTabletWide = resources.configuration.screenWidthDp >= 700

        val root = LinearLayout(this).apply {
            orientation = LinearLayout.VERTICAL
            setPadding(24, 0, 24, 80)
            setBackgroundColor(Color.parseColor(bg))
        }

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
            text = if (editBillNo != null) com.grocerypos.v11.util.Loc.t(this@PurchaseActivity, "Edit Purchase", "خریداری میں ترمیم") else com.grocerypos.v11.util.Loc.t(this@PurchaseActivity, "Purchase", "خریداری")
            textSize = 20f
            setTextColor(Color.WHITE)
            setTypeface(typeface, android.graphics.Typeface.BOLD)
            letterSpacing = 0.01f
        })
        headerCol.addView(TextView(this).apply {
            text = "STOCK IN · SUPPLIER BILLING"
            textSize = 10.5f
            setTextColor(Color.parseColor("#A7B4CC"))
            setTypeface(typeface, android.graphics.Typeface.BOLD)
            letterSpacing = 0.08f
            setPadding(0, 5, 0, 0)
        })
        header.addView(headerCol)
        header.addView(pillChip("History") {
            startActivity(Intent(this@PurchaseActivity, PurchaseHistoryActivity::class.java))
        })
        header.addView(spacer(8).apply { layoutParams = LinearLayout.LayoutParams((8 * resources.displayMetrics.density).toInt(), 1) })
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

        val topRow = LinearLayout(this).apply {
            orientation = LinearLayout.HORIZONTAL
            gravity = Gravity.CENTER_VERTICAL
            layoutParams = LinearLayout.LayoutParams(LinearLayout.LayoutParams.WRAP_CONTENT, LinearLayout.LayoutParams.WRAP_CONTENT).apply { setMargins(0, 0, 0, 14) }
        }
        val dateChip = LinearLayout(this).apply {
            orientation = LinearLayout.HORIZONTAL
            gravity = Gravity.CENTER_VERTICAL
            setPadding(22, 12, 22, 12)
            background = strokedBg(border, cardWhite, 30)
            applyElevation(this, 1.5f)
            setOnClickListener { openDatePicker() }
        }
        dateChip.addView(TextView(this).apply { text = "\uD83D\uDCC5  "; textSize = 13f })
        dateValueText = TextView(this).apply {
            text = formatDate(purchaseDateMillis)
            textSize = 13f
            setTextColor(Color.parseColor(textDark))
            setTypeface(typeface, android.graphics.Typeface.BOLD)
        }
        dateChip.addView(dateValueText)
        dateChip.addView(TextView(this).apply { text = "  \u203A"; textSize = 13f; setTextColor(Color.parseColor(teal)); setTypeface(typeface, android.graphics.Typeface.BOLD) })
        topRow.addView(dateChip)
        root.addView(topRow)

        val firmBox = premiumCard().apply { setPadding(22, 16, 22, 16) }
        val firmRow = LinearLayout(this).apply { orientation = LinearLayout.HORIZONTAL; gravity = Gravity.CENTER_VERTICAL }
        val firmCol = LinearLayout(this).apply { orientation = LinearLayout.VERTICAL; layoutParams = LinearLayout.LayoutParams(0, LinearLayout.LayoutParams.WRAP_CONTENT, 1f) }
        firmCol.addView(TextView(this).apply { text = com.grocerypos.v11.util.Loc.t(this@PurchaseActivity, "Firm Name", "فرم کا نام").uppercase(); textSize = 9.5f; setTextColor(Color.parseColor(textMuted)); setTypeface(typeface, android.graphics.Typeface.BOLD); letterSpacing = 0.05f })
        firmNameText = TextView(this).apply { text = "IBTISAAM Kiryana Store"; textSize = 13.5f; setTextColor(Color.parseColor(textDark)); setTypeface(typeface, android.graphics.Typeface.BOLD); setPadding(0, 2, 0, 0) }
        firmCol.addView(firmNameText)
        firmRow.addView(firmCol)
        val balCol = LinearLayout(this).apply { orientation = LinearLayout.VERTICAL; gravity = Gravity.END }
        balCol.addView(TextView(this).apply { text = com.grocerypos.v11.util.Loc.t(this@PurchaseActivity, "Party Balance", "پارٹی بیلنس").uppercase(); textSize = 9.5f; setTextColor(Color.parseColor(textMuted)); setTypeface(typeface, android.graphics.Typeface.BOLD); letterSpacing = 0.05f })
        supplierBalanceText = TextView(this).apply { text = "Rs 0.00"; textSize = 14f; setTypeface(typeface, android.graphics.Typeface.BOLD); setTextColor(Color.parseColor(textMuted)); setPadding(0, 2, 0, 0) }
        balCol.addView(supplierBalanceText)
        firmRow.addView(balCol)
        firmBox.addView(firmRow)
        root.addView(firmBox)

        partyBox = premiumCard()
        partyBox.addView(labelRow(com.grocerypos.v11.util.Loc.t(this, "Party / Supplier", "پارٹی / سپلائر")))
        val partyRow = LinearLayout(this).apply { orientation = LinearLayout.HORIZONTAL; gravity = Gravity.CENTER_VERTICAL }
        partyName = AutoCompleteTextView(this).apply {
            hint = com.grocerypos.v11.util.Loc.t(this@PurchaseActivity, "Party Name (Supplier) *", "پارٹی کا نام (سپلائر) *")
            setHintTextColor(Color.parseColor(textMuted))
            setTextColor(Color.parseColor(textDark))
            background = null
            textSize = 15.5f
            threshold = 1
            imeOptions = EditorInfo.IME_ACTION_NEXT
            layoutParams = LinearLayout.LayoutParams(0, LinearLayout.LayoutParams.WRAP_CONTENT, 1f)
        }
        partyRow.addView(partyName)
        partyRow.addView(circleIcon("+", teal, 32) { promptAddSupplier() })
        partyBox.addView(partyRow)
        // NEW ("10/10 Purchase screen" item #2): supplier's own invoice/bill number.
        partyBox.addView(spacer(10))
        partyBox.addView(labelRow(com.grocerypos.v11.util.Loc.t(this, "Supplier Invoice/Bill No. (optional)", "سپلائر انوائس/بل نمبر (اختیاری)")))
        supplierInvoiceNoInput = EditText(this).apply {
            hint = com.grocerypos.v11.util.Loc.t(this@PurchaseActivity, "e.g. printed on their bill", "مثلاً ان کے بل پر چھپا نمبر")
            setHintTextColor(Color.parseColor(textMuted))
            setTextColor(Color.parseColor(textDark))
            background = strokedBg(border, fieldFill, 12)
            setPadding(16, 12, 16, 12)
            textSize = 14f
            imeOptions = EditorInfo.IME_ACTION_NEXT
        }
        partyBox.addView(supplierInvoiceNoInput)
        root.addView(partyBox)
        root.addView(spacer(18))

        itemEntrySection = LinearLayout(this).apply {
            orientation = LinearLayout.VERTICAL
            setPadding(24, 22, 24, 22)
            background = strokedBg(border, cardWhite, 20)
            layoutParams = LinearLayout.LayoutParams(LinearLayout.LayoutParams.MATCH_PARENT, LinearLayout.LayoutParams.WRAP_CONTENT).apply { setMargins(0, 0, 0, 12) }
            applyElevation(this, 3f)
        }

        val addItemHeaderRow = LinearLayout(this).apply { orientation = LinearLayout.HORIZONTAL; gravity = Gravity.CENTER_VERTICAL; setPadding(0, 0, 0, 16) }
        addItemsTrigger = TextView(this).apply {
            text = "\u2795  " + com.grocerypos.v11.util.Loc.t(this@PurchaseActivity, "Add Item", "آئٹم شامل کریں")
            textSize = 15f
            setTextColor(Color.parseColor(teal))
            setTypeface(typeface, android.graphics.Typeface.BOLD)
            layoutParams = LinearLayout.LayoutParams(0, LinearLayout.LayoutParams.WRAP_CONTENT, 1f)
        }
        addItemHeaderRow.addView(addItemsTrigger)
        itemEntrySection.addView(addItemHeaderRow)

        val itemBox = innerField()
        itemBox.addView(labelRow(com.grocerypos.v11.util.Loc.t(this, "Item Name", "آئٹم کا نام")))
        val itemNameRow = LinearLayout(this).apply { orientation = LinearLayout.HORIZONTAL; gravity = Gravity.CENTER_VERTICAL }
        itemName = AutoCompleteTextView(this).apply {
            hint = com.grocerypos.v11.util.Loc.t(this@PurchaseActivity, "Type to search…", "تلاش کے لیے لکھیں…")
            setHintTextColor(Color.parseColor(textMuted))
            setTextColor(Color.parseColor(textDark))
            background = null
            textSize = 15.5f
            threshold = 1
            imeOptions = EditorInfo.IME_ACTION_NEXT
            layoutParams = LinearLayout.LayoutParams(0, LinearLayout.LayoutParams.WRAP_CONTENT, 1f)
        }
        itemNameRow.addView(itemName)
        // NEW: 📊 opens a quick supplier-comparison popup for the currently selected
        // item, right here while purchasing — so the user can see who's cheapest
        // before typing in a rate, instead of switching to the Item Search screen.
        itemNameRow.addView(circleIcon("\uD83D\uDCCA", navy, 30) { showSupplierComparison() })
        itemNameRow.addView(circleIcon("+", teal, 30) { openAddProductDialog(itemName.text.toString().trim()) })
        itemBox.addView(itemNameRow)
        itemEntrySection.addView(itemBox)

        unitToggleRow = LinearLayout(this).apply { orientation = LinearLayout.HORIZONTAL; visibility = View.GONE }
        itemEntrySection.addView(unitToggleRow)
        itemEntrySection.addView(spacer(10))

        val qtyUnitRow = LinearLayout(this).apply { orientation = LinearLayout.HORIZONTAL }
        val qtyBox = innerField().apply { layoutParams = LinearLayout.LayoutParams(0, LinearLayout.LayoutParams.WRAP_CONTENT, 1f).apply { setMargins(0, 0, 6, 0) } }
        qtyBox.addView(labelRow(com.grocerypos.v11.util.Loc.t(this, "Quantity", "مقدار")))
        qty = EditText(this).apply {
            hint = "0"
            setHintTextColor(Color.parseColor(textMuted))
            setTextColor(Color.parseColor(textDark))
            background = null
            textSize = 15.5f
            inputType = InputType.TYPE_CLASS_NUMBER or InputType.TYPE_NUMBER_FLAG_DECIMAL
            imeOptions = EditorInfo.IME_ACTION_NEXT
        }
        qtyBox.addView(qty)
        val unitBox = innerField().apply { layoutParams = LinearLayout.LayoutParams(0, LinearLayout.LayoutParams.WRAP_CONTENT, 1f).apply { setMargins(6, 0, 0, 0) } }
        unitBox.addView(labelRow(com.grocerypos.v11.util.Loc.t(this, "Unit", "یونٹ")))
        unitSpinner = Spinner(this)
        unitBox.addView(unitSpinner)
        qtyUnitRow.addView(qtyBox)
        qtyUnitRow.addView(unitBox)
        itemEntrySection.addView(qtyUnitRow)
        itemEntrySection.addView(spacer(10))

        val rateRow = LinearLayout(this).apply { orientation = LinearLayout.HORIZONTAL }
        val rateBox = innerField().apply { layoutParams = LinearLayout.LayoutParams(0, LinearLayout.LayoutParams.WRAP_CONTENT, 1f).apply { setMargins(0, 0, 6, 0) } }
        rateBox.addView(labelRow(com.grocerypos.v11.util.Loc.t(this, "Rate (Per Unit)", "ریٹ")))
        rate = EditText(this).apply {
            hint = "Price / Unit"
            setHintTextColor(Color.parseColor(textMuted))
            setTextColor(Color.parseColor(textDark))
            background = null
            textSize = 15.5f
            inputType = InputType.TYPE_CLASS_NUMBER or InputType.TYPE_NUMBER_FLAG_DECIMAL
            imeOptions = EditorInfo.IME_ACTION_NEXT
        }
        rateBox.addView(rate)

        val totalLotBox = innerField().apply { layoutParams = LinearLayout.LayoutParams(0, LinearLayout.LayoutParams.WRAP_CONTENT, 1f).apply { setMargins(6, 0, 0, 0) } }
        totalLotBox.addView(labelRow("Total Lot Price"))
        totalLotPrice = EditText(this).apply {
            hint = "e.g. 5000 for 2 Ctn"
            setHintTextColor(Color.parseColor(textMuted))
            setTextColor(Color.parseColor(textDark))
            background = null
            textSize = 15.5f
            inputType = InputType.TYPE_CLASS_NUMBER or InputType.TYPE_NUMBER_FLAG_DECIMAL
            // FIX (tab order): used to be IME_ACTION_DONE with its listener calling
            // addItem() straight away, so hitting Next/Done here skipped Retail/
            // Wholesale Rate entirely. Now NEXT like every other field in this row,
            // handing off to Retail Rate — see the matching editor-action listener
            // below and retailRateInput/wholesaleRateInput's, which restores the
            // original Lot Price → Retail → Wholesale → Done chain.
            imeOptions = EditorInfo.IME_ACTION_NEXT
        }
        totalLotBox.addView(totalLotPrice)
        rateRow.addView(rateBox)
        rateRow.addView(totalLotBox)
        itemEntrySection.addView(rateRow)

        // NEW ("10/10 Purchase screen" item #7): Retail/Wholesale rate, editable here —
        // pre-filled from the picked product's current salePrice/wholesalePrice
        // (see applyPickedProduct()/refillAutoRate()) and only written back to the
        // product on save if the user changes it away from 0 (see PurchaseLine).
        val priceRow = LinearLayout(this).apply { orientation = LinearLayout.HORIZONTAL }
        val retailBox = innerField().apply { layoutParams = LinearLayout.LayoutParams(0, LinearLayout.LayoutParams.WRAP_CONTENT, 1f).apply { setMargins(0, 0, 6, 0) } }
        retailBox.addView(labelRow(com.grocerypos.v11.util.Loc.t(this, "Retail Rate", "ریٹیل ریٹ")))
        retailRateInput = EditText(this).apply {
            hint = "Sale Price"
            setHintTextColor(Color.parseColor(textMuted))
            setTextColor(Color.parseColor(textDark))
            background = null
            textSize = 15.5f
            inputType = InputType.TYPE_CLASS_NUMBER or InputType.TYPE_NUMBER_FLAG_DECIMAL
            imeOptions = EditorInfo.IME_ACTION_NEXT
        }
        retailBox.addView(retailRateInput)
        val wholesaleBox = innerField().apply { layoutParams = LinearLayout.LayoutParams(0, LinearLayout.LayoutParams.WRAP_CONTENT, 1f).apply { setMargins(6, 0, 0, 0) } }
        wholesaleBox.addView(labelRow(com.grocerypos.v11.util.Loc.t(this, "Wholesale Rate", "ہول سیل ریٹ")))
        wholesaleRateInput = EditText(this).apply {
            hint = "Wholesale Price"
            setHintTextColor(Color.parseColor(textMuted))
            setTextColor(Color.parseColor(textDark))
            background = null
            textSize = 15.5f
            inputType = InputType.TYPE_CLASS_NUMBER or InputType.TYPE_NUMBER_FLAG_DECIMAL
            imeOptions = EditorInfo.IME_ACTION_DONE
        }
        wholesaleBox.addView(wholesaleRateInput)
        priceRow.addView(retailBox)
        priceRow.addView(wholesaleBox)
        itemEntrySection.addView(priceRow)

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

        totalAmountText = TextView(this).apply { text = "Total Amount: Rs 0.00"; textSize = 14.5f; setTypeface(typeface, android.graphics.Typeface.BOLD); setTextColor(Color.parseColor(navy)); setPadding(6, 8, 0, 10) }
        itemEntrySection.addView(totalAmountText)

        addItemButton = Button(this).apply {
            text = com.grocerypos.v11.util.Loc.t(this@PurchaseActivity, "ADD ITEM", "آئٹم شامل کریں")
            setTextColor(Color.WHITE)
            textSize = 14.5f
            isAllCaps = false
            setTypeface(typeface, android.graphics.Typeface.BOLD)
            background = gradientBg(teal, teal, cornerBottom = 14, cornerTop = 14)
            setPadding(0, 26, 0, 26)
            applyElevation(this, 3f)
        }
        itemEntrySection.addView(addItemButton)
        cancelEditButton = TextView(this).apply {
            text = com.grocerypos.v11.util.Loc.t(this@PurchaseActivity, "Cancel Edit", "ترمیم منسوخ کریں")
            textSize = 13f
            gravity = Gravity.CENTER
            setTextColor(Color.parseColor(red))
            setTypeface(typeface, android.graphics.Typeface.BOLD)
            setPadding(0, 16, 0, 0)
            visibility = View.GONE
            setOnClickListener {
                endLineEdit()
                itemName.setText(""); qty.setText(""); rate.setText(""); totalLotPrice.setText("")
                retailRateInput.setText(""); wholesaleRateInput.setText("")
                selectedProduct = null; lastMainQty = 0.0; lastMainRate = 0.0
                lastMainRetailRate = 0.0; lastMainWholesaleRate = 0.0
                currentProductSalePriceMain = 0.0; currentProductWholesalePriceMain = 0.0
                marginWarningText.visibility = View.GONE
                conversionInfo.visibility = View.GONE; unitToggleRow.visibility = View.GONE
                totalAmountText.text = "Total Amount: Rs 0"
                hideKeyboard()
            }
        }
        itemEntrySection.addView(cancelEditButton)
        root.addView(itemEntrySection)

        // ---- ADDED (tablet / desktop-style layout): from here on, everything
        // that used to go straight into `root` (billed items, total, payment,
        // due, save/delete) is added to `cartColumn` instead. On phones
        // `cartColumn` IS `root`, so nothing changes. On a tablet-wide screen
        // it's a separate LinearLayout that becomes the right-hand "cart"
        // pane, built further down. ----
        val cartColumn: LinearLayout = if (isTabletWide) {
            LinearLayout(this).apply {
                orientation = LinearLayout.VERTICAL
                setPadding(0, 0, 0, 40)
            }
        } else {
            root
        }

        billedItemsHeader = LinearLayout(this).apply {
            orientation = LinearLayout.HORIZONTAL
            gravity = Gravity.CENTER_VERTICAL
            setPadding(22, 16, 22, 16)
            background = gradientBg(navy, navy, cornerBottom = 14, cornerTop = 14)
            layoutParams = LinearLayout.LayoutParams(LinearLayout.LayoutParams.MATCH_PARENT, LinearLayout.LayoutParams.WRAP_CONTENT).apply { setMargins(0, 4, 0, 0) }
            visibility = View.GONE
            applyElevation(this, 2f)
            setOnClickListener { showBilledItemsDialog() }
        }
        billedItemsSummaryText = TextView(this).apply {
            text = "\uD83D\uDCCB  " + com.grocerypos.v11.util.Loc.t(this@PurchaseActivity, "Billed Items", "بل شدہ آئٹمز")
            textSize = 13.5f
            setTypeface(typeface, android.graphics.Typeface.BOLD)
            setTextColor(Color.WHITE)
            layoutParams = LinearLayout.LayoutParams(0, LinearLayout.LayoutParams.WRAP_CONTENT, 1f)
        }
        billedItemsHeader.addView(billedItemsSummaryText)
        billedItemsChevron = TextView(this).apply { text = "\u203A"; textSize = 18f; setTextColor(Color.WHITE); setTypeface(typeface, android.graphics.Typeface.BOLD) }
        billedItemsHeader.addView(billedItemsChevron)
        // ---- CHANGED (tablet / desktop-style layout — keyboard-hides-total fix):
        // on phone this still goes straight into cartColumn (===root), unchanged.
        // On tablet it's NOT added to cartColumn — see the final two-pane assembly
        // below, where the header + cart list become their own independently-
        // scrolling middle section, separate from the Total/Payment/Due/Save
        // block. That way a long item list (or the keyboard eating vertical
        // space) can only squeeze the cart-list area, never push Total/Paid/Save
        // off-screen. ----
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

        val totalCard = premiumCard().apply { orientation = LinearLayout.HORIZONTAL; gravity = Gravity.CENTER_VERTICAL; setPadding(24, 20, 24, 20); background = strokedBg(border, fieldFill, 18) }
        totalCard.addView(TextView(this).apply {
            text = com.grocerypos.v11.util.Loc.t(this@PurchaseActivity, "Total Amount", "کل رقم").uppercase()
            textSize = 12f
            setTextColor(Color.parseColor(textMuted))
            setTypeface(typeface, android.graphics.Typeface.BOLD)
            letterSpacing = 0.05f
            layoutParams = LinearLayout.LayoutParams(0, LinearLayout.LayoutParams.WRAP_CONTENT, 1f)
        })
        grandTotalText = TextView(this).apply { text = "Rs 0"; textSize = 21f; setTextColor(Color.parseColor(navy)); setTypeface(typeface, android.graphics.Typeface.BOLD) }
        totalCard.addView(grandTotalText)
        cartColumn.addView(totalCard)

        paymentSection = premiumCard().apply { orientation = LinearLayout.VERTICAL; setPadding(24, 20, 24, 20) }
        val paidRow = LinearLayout(this).apply { orientation = LinearLayout.HORIZONTAL; gravity = Gravity.CENTER_VERTICAL }
        paidRow.addView(TextView(this).apply {
            text = com.grocerypos.v11.util.Loc.t(this@PurchaseActivity, "Paid Amount", "ادا شدہ رقم").uppercase()
            textSize = 12f
            setTextColor(Color.parseColor(textMuted))
            setTypeface(typeface, android.graphics.Typeface.BOLD)
            letterSpacing = 0.05f
            layoutParams = LinearLayout.LayoutParams(0, LinearLayout.LayoutParams.WRAP_CONTENT, 1f)
        })
        paidRow.addView(TextView(this).apply { text = "Rs "; textSize = 17f; setTextColor(Color.parseColor(successGreen)); setTypeface(typeface, android.graphics.Typeface.BOLD) })
        paidInput = EditText(this).apply {
            hint = "0"
            setHintTextColor(Color.parseColor(textMuted))
            setTextColor(Color.parseColor(successGreen))
            background = null
            textSize = 20f
            gravity = Gravity.END
            setTypeface(typeface, android.graphics.Typeface.BOLD)
            minWidth = (120 * resources.displayMetrics.density).toInt()
            inputType = InputType.TYPE_CLASS_NUMBER
            imeOptions = EditorInfo.IME_ACTION_DONE
        }
        paidRow.addView(paidInput)
        paymentSection.addView(paidRow)
        paymentSection.addView(spacer(6))
        paymentSection.addView(labelRow(com.grocerypos.v11.util.Loc.t(this, "Payment Method", "ادائیگی کا طریقہ")))
        paymentMethodSpinner = Spinner(this).apply {
            adapter = ArrayAdapter(this@PurchaseActivity, android.R.layout.simple_spinner_dropdown_item, listOf("Cash", "Bank"))
        }
        paymentSection.addView(paymentMethodSpinner)
        // NEW (Split Payment / multiple payment methods): tapping this opens a
        // dialog to pay one bill with more than one method (e.g. Rs 300 Cash +
        // Rs 200 Bank). Once applied, this link is hidden and splitPaymentSummary
        // below shows the breakdown instead — the single spinner above still sits
        // there but is ignored while a split is active (savePurchase derives the
        // saved payment method from splitPayments, not the spinner, in that case).
        splitPaymentLink = TextView(this).apply {
            text = com.grocerypos.v11.util.Loc.t(this@PurchaseActivity, "+ Split Payment (multiple methods)", "+ ادائیگی تقسیم کریں (ایک سے زیادہ طریقے)")
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
            textSize = 11f
            setTextColor(Color.parseColor(red))
            setTypeface(typeface, android.graphics.Typeface.BOLD)
            setPadding(0, 8, 0, 0)
            visibility = View.GONE
            setLeadingIcon(R.drawable.ic_warning, red, 12, 5)
        }
        paymentSection.addView(paidWarningText)
        cartColumn.addView(paymentSection)

        val dueCard = premiumCard().apply { orientation = LinearLayout.HORIZONTAL; gravity = Gravity.CENTER_VERTICAL; setPadding(22, 18, 22, 18); background = strokedBg(border, fieldFill, 18) }
        dueCard.addView(TextView(this).apply {
            text = com.grocerypos.v11.util.Loc.t(this@PurchaseActivity, "Due Amount", "باقی رقم").uppercase()
            textSize = 12f
            setTextColor(Color.parseColor(textMuted))
            setTypeface(typeface, android.graphics.Typeface.BOLD)
            letterSpacing = 0.05f
            layoutParams = LinearLayout.LayoutParams(0, LinearLayout.LayoutParams.WRAP_CONTENT, 1f)
        })
        dueAmountText = TextView(this).apply { text = "Rs 0"; textSize = 18f; setTextColor(Color.parseColor(navy)); setTypeface(typeface, android.graphics.Typeface.BOLD) }
        dueCard.addView(dueAmountText)
        cartColumn.addView(dueCard)
        // ---- CHANGED (tablet / desktop-style layout): the large 220dp spacer
        // below exists to leave scroll room above the phone's soft keyboard.
        // On the tablet's right-hand cart pane that would just be a big dead
        // gap before the Save button, so it's shrunk there. ----
        cartColumn.addView(spacer(if (isTabletWide) 24 else 220))

        saveButton = Button(this).apply {
            text = if (editBillNo != null) com.grocerypos.v11.util.Loc.t(this@PurchaseActivity, "UPDATE PURCHASE", "خریداری اپ ڈیٹ کریں") else com.grocerypos.v11.util.Loc.t(this@PurchaseActivity, "SAVE PURCHASE", "خریداری محفوظ کریں")
            setTextColor(Color.WHITE)
            textSize = 15.5f
            isAllCaps = false
            setTypeface(typeface, android.graphics.Typeface.BOLD)
            background = gradientBg(navy, navy, cornerBottom = 16, cornerTop = 16)
            setPadding(0, 30, 0, 30)
            applyElevation(this, 5f)
        }
        deleteButton = Button(this).apply {
            text = com.grocerypos.v11.util.Loc.t(this@PurchaseActivity, "DELETE", "حذف کریں")
            setTextColor(Color.WHITE)
            textSize = 15f
            isAllCaps = false
            setTypeface(typeface, android.graphics.Typeface.BOLD)
            background = roundedBg(red, 16)
            setPadding(0, 30, 0, 30)
            applyElevation(this, 3f)
            visibility = if (editBillNo != null) View.VISIBLE else View.GONE
        }
        val saveDeleteRow = LinearLayout(this).apply { orientation = LinearLayout.HORIZONTAL }
        saveDeleteRow.addView(saveButton, LinearLayout.LayoutParams(0, LinearLayout.LayoutParams.WRAP_CONTENT, 1f).apply { setMargins(0, 0, 8, 0) })
        saveDeleteRow.addView(deleteButton, LinearLayout.LayoutParams(0, LinearLayout.LayoutParams.WRAP_CONTENT, 0.8f).apply { setMargins(8, 0, 0, 0) })
        cartColumn.addView(saveDeleteRow)
        cartColumn.addView(spacer(30))

        if (isTabletWide) {
            // ---- ADDED (tablet / desktop-style layout): two side-by-side panes,
            // like a computer POS screen — left = supplier/item entry (scrolls),
            // right = cart/bill/payment. `scrollArea` keeps pointing at the LEFT
            // pane — every existing scrollArea call above is about the item-entry
            // side of the screen, and the handful of payment-related scroll calls
            // elsewhere are skipped on tablet (search isTabletWide in this file).
            //
            // ---- FIX (keyboard-hides-total): same fix as SaleActivity — the
            // right pane is built as THREE stacked pieces, not one long
            // ScrollView. billedItemsHeader (fixed) + a scrollable middle strip
            // holding just the cart list is the ONLY part that grows with more
            // items or shrinks for the keyboard; cartColumn (Total/Payment/Due/
            // Save) is pinned at the bottom with its own small ScrollView as a
            // safety net. A LinearLayout gives non-weighted children their full
            // requested height first, so Total/Paid/Save always stay visible
            // regardless of how long the cart list gets or how much room the
            // keyboard eats — only the cart list itself scrolls/shrinks. ----
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
            scrollArea = leftScroll
            setContentView(twoPane)
            keepContentAboveKeyboard(twoPane)
        } else {
            scrollArea = ScrollView(this).apply {
                layoutParams = LinearLayout.LayoutParams(LinearLayout.LayoutParams.MATCH_PARENT, LinearLayout.LayoutParams.MATCH_PARENT)
                setBackgroundColor(Color.parseColor(bg))
                addView(root)
            }
            setContentView(scrollArea)
            keepContentAboveKeyboard(scrollArea)
        }

        observeViewModel()
        editBillNo?.let { loadForEdit(it) }

        partyName.setOnEditorActionListener { _, actionId, _ ->
            if (actionId == EditorInfo.IME_ACTION_NEXT) { itemName.requestFocus(); safeShowDropDown(itemName); true } else false
        }

        itemName.setOnItemClickListener { _, _, position, _ ->
            onItemPicked(itemName.adapter.getItem(position).toString())
            qty.requestFocus()
        }
        itemName.onFocusChangeListener = View.OnFocusChangeListener { _, hasFocus ->
            if (hasFocus) {
                safeShowDropDown(itemName)
                scrollTargetView = itemEntrySection
                scrollAlignTop = true
                scrollArea.post { scrollToShowView(itemEntrySection, true) }
            }
        }
        itemName.setOnEditorActionListener { _, actionId, _ ->
            if (actionId == EditorInfo.IME_ACTION_NEXT) { qty.requestFocus(); true } else false
        }
        itemName.addTextChangedListener(simpleWatcher {
            if (itemName.hasFocus() && itemName.text.length >= 1) safeShowDropDown(itemName)
            val match = products.find { it.name.equals(itemName.text.toString().trim(), ignoreCase = true) }
            if (match == null) {
                selectedProduct = null
                unitSpinner.adapter = ArrayAdapter(this, android.R.layout.simple_spinner_dropdown_item, allUnits)
                conversionInfo.visibility = View.GONE
                unitToggleRow.visibility = View.GONE
            }
        })

        qty.setOnEditorActionListener { _, actionId, _ ->
            if (actionId == EditorInfo.IME_ACTION_NEXT) { rate.requestFocus(); true } else false
        }
        qty.onFocusChangeListener = View.OnFocusChangeListener { _, hasFocus ->
            if (hasFocus) {
                scrollTargetView = itemEntrySection
                scrollAlignTop = true
                scrollArea.post { scrollToShowView(itemEntrySection, true) }
            }
        }
        rate.setOnEditorActionListener { _, actionId, _ ->
            if (actionId == EditorInfo.IME_ACTION_NEXT) { totalLotPrice.requestFocus(); true } else false
        }
        rate.onFocusChangeListener = View.OnFocusChangeListener { _, hasFocus ->
            if (hasFocus) {
                rate.post { rate.selectAll() }
                scrollTargetView = itemEntrySection
                scrollAlignTop = true
                scrollArea.post { scrollToShowView(itemEntrySection, true) }
            }
        }
        totalLotPrice.setOnEditorActionListener { _, actionId, _ ->
            if (actionId == EditorInfo.IME_ACTION_NEXT) { retailRateInput.requestFocus(); true } else false
        }
        totalLotPrice.onFocusChangeListener = View.OnFocusChangeListener { _, hasFocus ->
            if (hasFocus) {
                scrollTargetView = itemEntrySection
                scrollAlignTop = true
                scrollArea.post { scrollToShowView(itemEntrySection, true) }
            }
        }
        // FIX (tab order): restores Lot Price → Retail Rate → Wholesale Rate →
        // Done (addItem), same as before totalLotPrice's DONE action started
        // short-circuiting straight to addItem().
        retailRateInput.setOnEditorActionListener { _, actionId, _ ->
            if (actionId == EditorInfo.IME_ACTION_NEXT) { wholesaleRateInput.requestFocus(); true } else false
        }
        wholesaleRateInput.setOnEditorActionListener { _, actionId, _ ->
            if (actionId == EditorInfo.IME_ACTION_DONE) { addItem(); true } else false
        }

        addItemButton.setOnClickListener { addItem() }
        saveButton.setOnClickListener { savePurchase() }
        deleteButton.setOnClickListener { confirmDeletePurchase() }

        unitSpinner.onItemSelectedListener = object : AdapterView.OnItemSelectedListener {
            override fun onItemSelected(p: AdapterView<*>?, v: View?, pos: Int, id: Long) { refillAutoRate(); updateLineTotal() }
            override fun onNothingSelected(p: AdapterView<*>?) {}
        }

        partyName.onFocusChangeListener = View.OnFocusChangeListener { _, hasFocus ->
            if (hasFocus) {
                safeShowDropDown(partyName)
                scrollTargetView = partyBox
                scrollAlignTop = true
                scrollArea.post { scrollToShowView(partyBox, true) }
            }
        }
        partyName.setOnItemClickListener { _, _, position, _ -> updateSupplierBalanceDisplay(partyName.adapter.getItem(position).toString()) }
        partyName.addTextChangedListener(simpleWatcher {
            updateSupplierBalanceDisplay(partyName.text.toString().trim())
            if (partyName.hasFocus() && partyName.text.length >= 1) safeShowDropDown(partyName)
        })

        qty.addTextChangedListener(simpleWatcher {
            if (!suppressQtyWatcher) { lastMainQty = toMainUnitQty(qty.text.toString().toDoubleOrNull() ?: 0.0) }
            updateLineTotal()
        })
        rate.addTextChangedListener(simpleWatcher {
            if (suppressRateWatcher) return@simpleWatcher
            lastMainRate = toMainUnitRate(rate.text.toString().toDoubleOrNull() ?: 0.0)
            val q = qty.text.toString().toDoubleOrNull() ?: 0.0
            val r = rate.text.toString().toDoubleOrNull() ?: 0.0
            if (q > 0 && r > 0) {
                suppressTotalLotWatcher = true
                totalLotPrice.setText("%.2f".format(q * r).trimEnd('0').trimEnd('.'))
                suppressTotalLotWatcher = false
            }
            updateLineTotal()
            updateMarginWarning()
        })
        retailRateInput.addTextChangedListener(simpleWatcher {
            if (suppressRetailRateWatcher) return@simpleWatcher
            lastMainRetailRate = toMainUnitRate(retailRateInput.text.toString().toDoubleOrNull() ?: 0.0)
        })
        wholesaleRateInput.addTextChangedListener(simpleWatcher {
            if (suppressWholesaleRateWatcher) return@simpleWatcher
            lastMainWholesaleRate = toMainUnitRate(wholesaleRateInput.text.toString().toDoubleOrNull() ?: 0.0)
        })
        totalLotPrice.addTextChangedListener(simpleWatcher {
            if (suppressTotalLotWatcher) return@simpleWatcher
            val totalLot = totalLotPrice.text.toString().toDoubleOrNull() ?: 0.0
            val q = qty.text.toString().toDoubleOrNull() ?: 0.0
            if (q > 0 && totalLot > 0) {
                val newRate = totalLot / q
                suppressRateWatcher = true
                rate.setText("%.2f".format(newRate).trimEnd('0').trimEnd('.'))
                suppressRateWatcher = false
                lastMainRate = toMainUnitRate(newRate)
                updateLineTotal()
                updateMarginWarning()
            }
        })
        paidInput.addTextChangedListener(simpleWatcher { updateGrandTotal() })

        paidInput.onFocusChangeListener = View.OnFocusChangeListener { _, hasFocus ->
            if (hasFocus && !isTabletWide) {
                scrollTargetView = paymentSection
                scrollAlignTop = false
                scrollArea.post { scrollToShowView(paymentSection, false) }
            }
        }
        scrollArea.viewTreeObserver.addOnGlobalLayoutListener {
            scrollTargetView?.let { scrollToShowView(it, scrollAlignTop) }
        }

        if (editBillNo == null) restoreDraftIfAny()
    }

    private fun scrollToShowView(target: View, alignTop: Boolean) {
        if (!::scrollArea.isInitialized) return
        val visibleFrame = Rect()
        scrollArea.getWindowVisibleDisplayFrame(visibleFrame)
        val location = IntArray(2)
        target.getLocationOnScreen(location)
        val top = location[1]
        val bottom = top + target.height
        val extraPadding = (24 * resources.displayMetrics.density).toInt()
        if (alignTop) {
            scrollArea.scrollBy(0, top - visibleFrame.top - extraPadding)
        } else {
            when {
                bottom > visibleFrame.bottom -> scrollArea.scrollBy(0, (bottom - visibleFrame.bottom) + extraPadding)
                top < visibleFrame.top -> scrollArea.scrollBy(0, top - visibleFrame.top - extraPadding)
            }
        }
    }

    override fun onPause() {
        super.onPause()
        if (editBillNo == null && !suppressDraftSave) saveDraft()
    }

    private fun draftPrefs() = getSharedPreferences(PREFS_NAME, Context.MODE_PRIVATE)
    private fun saveDraft() {
        try {
            val hasContent = lines.isNotEmpty() || partyName.text.toString().isNotBlank() || itemName.text.toString().isNotBlank() || qty.text.toString().isNotBlank() || rate.text.toString().isNotBlank()
            if (!hasContent) { clearDraft(); return }
            val linesArray = JSONArray()
            lines.forEach { line ->
                linesArray.put(JSONObject().apply {
                    put("itemName", line.itemName); put("barcode", line.barcode ?: ""); put("qty", line.qty); put("unit", line.unit); put("rate", line.rate); put("amount", line.amount)
                    put("mainUnit", line.mainUnit); put("secondaryUnit", line.secondaryUnit); put("secondaryUnitQty", line.secondaryUnitQty)
                    put("tertiaryUnit", line.tertiaryUnit); put("tertiaryUnitQty", line.tertiaryUnitQty)
                    put("retailRate", line.retailRate); put("wholesaleRate", line.wholesaleRate)
                })
            }
            val draft = JSONObject().apply {
                put("party", partyName.text.toString()); put("paid", paidInput.text.toString()); put("dateMillis", purchaseDateMillis)
                put("supplierInvoiceNo", supplierInvoiceNoInput.text.toString())
                put("pendingItemName", itemName.text.toString()); put("pendingQty", qty.text.toString()); put("pendingRate", rate.text.toString()); put("lines", linesArray)
            }
            draftPrefs().edit().putString(KEY_DRAFT, draft.toString()).apply()
        } catch (e: Exception) {
            Log.e(TAG, "saveDraft failed", e)
        }
    }
    private fun clearDraft() { draftPrefs().edit().remove(KEY_DRAFT).apply() }
    private fun restoreDraftIfAny() {
        try {
            val raw = draftPrefs().getString(KEY_DRAFT, null) ?: return
            val draft = try { JSONObject(raw) } catch (e: Exception) { null } ?: return
            if (draftRestored) return
            draftRestored = true
            suppressDraftSave = true
            try {
                val party = draft.optString("party", ""); if (party.isNotBlank()) { partyName.setText(party); updateSupplierBalanceDisplay(party) }
                val paid = draft.optString("paid", ""); if (paid.isNotBlank()) paidInput.setText(paid)
                val savedDate = draft.optLong("dateMillis", 0L); if (savedDate > 0L) { purchaseDateMillis = savedDate; dateValueText.text = formatDate(purchaseDateMillis) }
                val savedInvoiceNo = draft.optString("supplierInvoiceNo", ""); if (savedInvoiceNo.isNotBlank()) supplierInvoiceNoInput.setText(savedInvoiceNo)
                val linesArray = draft.optJSONArray("lines")
                if (linesArray != null) {
                    for (i in 0 until linesArray.length()) {
                        try {
                            val o = linesArray.getJSONObject(i)
                            lines.add(PurchaseLine(o.optString("itemName"), o.optString("barcode").ifBlank { null }, o.optDouble("qty", 0.0), o.optString("unit"), o.optDouble("rate", 0.0), o.optDouble("amount", 0.0), o.optString("mainUnit"), o.optString("secondaryUnit"), o.optDouble("secondaryUnitQty", 0.0), o.optString("tertiaryUnit"), o.optDouble("tertiaryUnitQty", 0.0), o.optDouble("retailRate", 0.0), o.optDouble("wholesaleRate", 0.0)))
                        } catch (e: Exception) { Log.e(TAG, "restoreDraftIfAny: skipping bad line $i", e) }
                    }
                    renderItemsList(); updateGrandTotal()
                }
                val pendingItemName = draft.optString("pendingItemName", ""); if (pendingItemName.isNotBlank()) { itemName.setText(pendingItemName); val match = products.find { it.name.equals(pendingItemName, ignoreCase = true) }; if (match != null) applyPickedProduct(match) }
                val pendingQty = draft.optString("pendingQty", ""); if (pendingQty.isNotBlank()) qty.setText(pendingQty)
                val pendingRate = draft.optString("pendingRate", ""); if (pendingRate.isNotBlank()) rate.setText(pendingRate)
                updateLineTotal()
            } finally { suppressDraftSave = false }
        } catch (e: Exception) {
            Log.e(TAG, "restoreDraftIfAny failed - clearing corrupt draft", e)
            try { clearDraft() } catch (ignored: Exception) {}
            suppressDraftSave = false
        }
    }

    /** Single collector for everything PurchaseViewModel loads from the
     * database (suppliers, products, units, firm name) plus one-shot save/
     * delete/error events — replaces the old loadSuppliers()/loadUnits()/
     * loadProducts()/loadFirmName() functions, which each queried Room
     * directly. */
    private fun observeViewModel() {
        lifecycleScope.launch {
            viewModel.uiState.collectLatest { state ->
                suppliers = state.suppliers
                partyName.setAdapter(ArrayAdapter(this@PurchaseActivity, android.R.layout.simple_dropdown_item_1line, state.suppliers.map { it.name }))
                updateSupplierBalanceDisplay(partyName.text.toString().trim())

                products = state.products
                // FIX (English search not working here): was a plain name-only
                // ArrayAdapter, so Android's default dropdown filter only ever
                // matched the Urdu `name` — typing the English searchTag alias
                // (Urdu keyboard off) found nothing, even though it worked on
                // every other search screen. ProductNameAdapter filters through
                // Product.matchesQuery() (name + searchTag) like they do.
                itemName.setAdapter(ProductNameAdapter(this@PurchaseActivity) { products })

                allUnits = state.units
                if (selectedProduct == null) { unitSpinner.adapter = ArrayAdapter(this@PurchaseActivity, android.R.layout.simple_spinner_dropdown_item, allUnits) }

                if (!state.firmName.isNullOrBlank()) firmNameText.text = state.firmName
            }
        }
        lifecycleScope.launch {
            viewModel.events.collectLatest { event -> handleViewModelEvent(event) }
        }
    }

    private fun handleViewModelEvent(event: PurchaseEvent) {
        when (event) {
            is PurchaseEvent.Saved -> {
                isSaving = false
                saveButton.isEnabled = true
                suppressDraftSave = true; clearDraft(); editBillNo = event.billNo
                Toast.makeText(this, if (event.isUpdate) "Purchase updated" else "Purchase saved", Toast.LENGTH_SHORT).show()
                openBillPreview(event.billNo, forSaving = true, party = event.party, grandTotal = event.grandTotal, discount = event.discount, amountPaid = event.amountPaid, paymentMethod = event.paymentMethod)
            }
            is PurchaseEvent.Deleted -> {
                Toast.makeText(this, "Purchase deleted", Toast.LENGTH_SHORT).show(); finish()
            }
            is PurchaseEvent.Error -> {
                isSaving = false
                saveButton.isEnabled = true
                Toast.makeText(this, event.message, Toast.LENGTH_LONG).show()
            }
        }
    }

    private fun updateSupplierBalanceDisplay(name: String) {
        val supplier = suppliers.find { it.name.equals(name, ignoreCase = true) }
        if (supplier == null) { supplierBalanceText.text = "Rs 0.00"; supplierBalanceText.setTextColor(Color.parseColor(textMuted)); return }
        // PERMANENT FIX (balance drift): read the live ledger balance (bills + payments,
        // recomputed fresh) instead of the stored `supplier.balance` field, which only
        // ever moves via SyncQueueHelper.adjustSupplierBalance nudges and can drift away
        // from the real bills — exactly what let this screen show a different number
        // than the Dashboard for the same supplier. See PartyRepository's big comment.
        val token = ++balanceLookupToken
        supplierBalanceText.text = "…"
        supplierBalanceText.setTextColor(Color.parseColor(textMuted))
        lifecycleScope.launch {
            val live = supplier.openingBalance + partyRepo.liveSupplierBalance(supplier.id)
            if (token != balanceLookupToken) return@launch // a newer lookup superseded this one
            supplierBalanceText.text = "Rs %.2f".format(live)
            supplierBalanceText.setTextColor(Color.parseColor(if (live > 0) red else successGreen))
        }
    }

    private fun premiumCard() = LinearLayout(this).apply {
        orientation = LinearLayout.VERTICAL
        setPadding(22, 18, 22, 18)
        background = strokedBg(border, cardWhite, 18)
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
        text = label.uppercase(); textSize = 10.5f; setTextColor(Color.parseColor(textMuted)); setTypeface(typeface, android.graphics.Typeface.BOLD); setPadding(0, 0, 0, 6); letterSpacing = 0.05f
    }
    private fun pillChip(label: String, onClick: () -> Unit) = TextView(this).apply {
        this.text = label; textSize = 12.5f; setTextColor(Color.parseColor(navy)); setTypeface(typeface, android.graphics.Typeface.BOLD); background = roundedBg(cardWhite, 30); setPadding(24, 13, 24, 13); setOnClickListener { onClick() }
    }
    private fun circleIcon(label: String, colorHex: String, sizeDp: Int, onClick: (() -> Unit)? = null) = TextView(this).apply {
        this.text = label; textSize = 16f; setTextColor(Color.WHITE); gravity = Gravity.CENTER; background = ovalBg(colorHex); val px = (sizeDp * resources.displayMetrics.density).toInt(); layoutParams = android.view.ViewGroup.LayoutParams(px, px); if (onClick != null) setOnClickListener { onClick() }
    }

    private fun showBilledItemsDialog() {
        if (lines.isEmpty()) return
        (itemsContainer.parent as? ViewGroup)?.removeView(itemsContainer)
        val wrapper = ScrollView(this).apply {
            setPadding(20, 10, 20, 4)
            addView(itemsContainer)
        }
        billedItemsDialog = android.app.AlertDialog.Builder(this)
            .setTitle(com.grocerypos.v11.util.Loc.t(this, "Billed Items", "بل شدہ آئٹمز"))
            .setView(wrapper)
            .setPositiveButton(com.grocerypos.v11.util.Loc.t(this, "Close", "بند کریں"), null)
            .setOnDismissListener {
                billedItemsDialog = null
                // NEW: skip the "jump back to Paid" behaviour if the dialog is closing
                // because the user tapped ✎ to edit a line — editLine() already moved
                // focus to the item-entry fields.
                if (editingLineIndex != null) return@setOnDismissListener
                paidInput.requestFocus()
                paidInput.post {
                    paidInput.selectAll()
                    val imm = getSystemService(Context.INPUT_METHOD_SERVICE) as? android.view.inputmethod.InputMethodManager
                    imm?.showSoftInput(paidInput, android.view.inputmethod.InputMethodManager.SHOW_IMPLICIT)
                    if (!isTabletWide) {
                        scrollTargetView = paymentSection
                        scrollAlignTop = false
                        scrollArea.post { scrollToShowView(paymentSection, false) }
                    }
                }
            }
            .show()
    }

    private fun showOverflowMenu(anchor: View) {
        val popup = PopupMenu(this, anchor)
        popup.menu.add(com.grocerypos.v11.util.Loc.t(this, "Print", "پرنٹ"))
        popup.menu.add(com.grocerypos.v11.util.Loc.t(this, "Share", "شیئر کریں"))
        // NEW ("10/10 Purchase screen" item #12): Hold/Recall, mirroring Sale's
        // SaleHoldRecall.kt but as private methods on this Activity (Purchase's
        // fields are `private`, not `internal` like Sale's, so an extension-function
        // file the way SaleHoldRecall.kt is done isn't an option without a wider
        // visibility change across the class).
        val holdItem = popup.menu.add(com.grocerypos.v11.util.Loc.t(this, "Hold Bill", "بل ہولڈ کریں"))
        val recallItem = popup.menu.add(com.grocerypos.v11.util.Loc.t(this, "Recall Bill", "بل واپس لائیں"))
        popup.setOnMenuItemClickListener { item ->
            when (item) {
                holdItem -> holdBill()
                recallItem -> openRecallDialog()
                else -> {
                    val billNo = editBillNo
                    if (billNo == null) { Toast.makeText(this, "Save the purchase first", Toast.LENGTH_SHORT).show() } else { openBillPreview(billNo, forSaving = false) }
                }
            }
            true
        }
        popup.show()
    }
    // NEW ("10/10 Purchase screen" item #12): an incomplete purchase (e.g. supplier's
    // bill has more items than there's time to enter right now) can be parked and
    // picked back up later, instead of having to be finished or abandoned in one go.
    // Reuses the same held_bills table as Sale's Hold/Recall — see HeldDao's
    // allSaleHolds()/allPurchaseHolds() for how the two stay separate.
    private fun encodeHold(): String {
        val header = listOf(
            partyName.text.toString(),
            supplierInvoiceNoInput.text.toString(),
            paidInput.text.toString(),
            purchaseDateMillis.toString()
        ).joinToString("\u0001")
        val itemsPart = lines.joinToString("\u0002") { l ->
            listOf(
                l.barcode ?: "", l.itemName, l.qty, l.unit, l.rate, l.amount,
                l.mainUnit, l.secondaryUnit, l.secondaryUnitQty, l.tertiaryUnit, l.tertiaryUnitQty,
                l.retailRate, l.wholesaleRate
            ).joinToString("\u0003")
        }
        return header + "\u0004" + itemsPart
    }
    private fun decodeHold(payload: String) {
        val parts = payload.split("\u0004")
        if (parts.isEmpty()) return
        val header = parts[0].split("\u0001")
        if (header.size >= 3) {
            partyName.setText(header[0])
            updateSupplierBalanceDisplay(header[0])
            supplierInvoiceNoInput.setText(header[1])
            paidInput.setText(header[2])
            header.getOrNull(3)?.toLongOrNull()?.let { purchaseDateMillis = it; dateValueText.text = formatDate(purchaseDateMillis) }
        }
        lines.clear()
        if (parts.size > 1 && parts[1].isNotEmpty()) {
            parts[1].split("\u0002").forEach { row ->
                val f = row.split("\u0003")
                if (f.size >= 11) {
                    lines.add(PurchaseLine(
                        itemName = f[1], barcode = f[0].ifBlank { null }, qty = f[2].toDoubleOrNull() ?: 0.0,
                        unit = f[3], rate = f[4].toDoubleOrNull() ?: 0.0, amount = f[5].toDoubleOrNull() ?: 0.0,
                        mainUnit = f[6], secondaryUnit = f[7], secondaryUnitQty = f[8].toDoubleOrNull() ?: 0.0,
                        tertiaryUnit = f.getOrNull(9) ?: "", tertiaryUnitQty = f.getOrNull(10)?.toDoubleOrNull() ?: 0.0,
                        retailRate = f.getOrNull(11)?.toDoubleOrNull() ?: 0.0, wholesaleRate = f.getOrNull(12)?.toDoubleOrNull() ?: 0.0
                    ))
                }
            }
        }
        endLineEdit(); renderItemsList(); updateGrandTotal()
        if (editBillNo == null) saveDraft()
    }
    private fun holdBill() {
        if (lines.isEmpty()) { Toast.makeText(this, "Add items pehle, phir hold karen", Toast.LENGTH_SHORT).show(); return }
        val holdId = "PHOLD" + System.currentTimeMillis()
        val payload = encodeHold()
        safeLaunch("holdPurchaseBill") {
            PosDatabase.get(this@PurchaseActivity).heldDao().hold(HeldBill(holdId = holdId, payload = payload))
            Toast.makeText(this@PurchaseActivity, "Purchase hold ho gayi", Toast.LENGTH_SHORT).show()
            partyName.setText(""); supplierInvoiceNoInput.setText(""); paidInput.setText("")
            endLineEdit(); lines.clear(); renderItemsList(); updateGrandTotal()
        }
    }
    private fun openRecallDialog() {
        safeLaunch("loadPurchaseHolds") {
            val held = PosDatabase.get(this@PurchaseActivity).heldDao().allPurchaseHolds().first()
            if (held.isEmpty()) { Toast.makeText(this@PurchaseActivity, "Koi held purchase nahi hai", Toast.LENGTH_SHORT).show(); return@safeLaunch }
            val labels = held.map { h ->
                val header = h.payload.split("\u0004").getOrNull(0)?.split("\u0001")
                val partyLabel = header?.getOrNull(0)?.takeIf { it.isNotBlank() } ?: "Unknown Supplier"
                val itemCount = h.payload.split("\u0004").getOrNull(1)?.let { if (it.isEmpty()) 0 else it.split("\u0002").size } ?: 0
                "$partyLabel — $itemCount item(s)"
            }.toTypedArray()
            android.app.AlertDialog.Builder(this@PurchaseActivity)
                .setTitle(com.grocerypos.v11.util.Loc.t(this@PurchaseActivity, "Recall Held Purchase", "ہولڈ کی گئی خریداری واپس لائیں"))
                .setItems(labels) { _, which ->
                    val chosen = held[which]
                    decodeHold(chosen.payload)
                    safeLaunch("deletePurchaseHold") { PosDatabase.get(this@PurchaseActivity).heldDao().delete(chosen) }
                }
                .setNegativeButton("Cancel", null)
                .show()
        }
    }
    // gradientBg() and spacer() now come from the shared UiHelpers.kt (item #24 dedup) —
    // both were byte-identical private copies here before.
    private fun tintedDrawable(iconRes: Int, tintHex: String, sizeDp: Int = 16): android.graphics.drawable.Drawable? {
        val d = androidx.core.content.ContextCompat.getDrawable(this, iconRes)?.mutate() ?: return null
        d.setTint(Color.parseColor(tintHex))
        val px = (sizeDp * resources.displayMetrics.density).toInt()
        d.setBounds(0, 0, px, px)
        return d
    }

    private fun TextView.setLeadingIcon(iconRes: Int, tintHex: String, sizeDp: Int = 13, paddingDp: Int = 6) {
        setCompoundDrawablesRelative(tintedDrawable(iconRes, tintHex, sizeDp), null, null, null)
        compoundDrawablePadding = (paddingDp * resources.displayMetrics.density).toInt()
    }

    private fun simpleWatcher(onChange: () -> Unit) = object : TextWatcher {
        override fun beforeTextChanged(s: CharSequence?, a: Int, b: Int, c: Int) {}
        override fun onTextChanged(s: CharSequence?, a: Int, b: Int, c: Int) {}
        override fun afterTextChanged(s: Editable?) = onChange()
    }
    private fun safeShowDropDown(view: AutoCompleteTextView) {
        if (!view.isAttachedToWindow) return
        try {
            view.showDropDown()
        } catch (e: Exception) {
            Log.e(TAG, "safeShowDropDown failed for ${view.hint}", e)
        }
    }

    private fun formatDate(millis: Long) = SimpleDateFormat("dd/MM/yyyy", Locale.getDefault()).format(Date(millis))
    private fun formatQty(v: Double): String = if (v == v.toLong().toDouble()) v.toLong().toString() else v.toString()
    private fun openDatePicker() {
        val cal = Calendar.getInstance().apply { timeInMillis = purchaseDateMillis }
        // FIX (consistent date picker style across the app): force calendar mode
        // so this always matches the grid-calendar picker used everywhere else,
        // instead of falling back to an OEM's scrolling-spinner layout.
        DatePickerDialog(this, { _, y, m, d -> cal.set(y, m, d); purchaseDateMillis = cal.timeInMillis; dateValueText.text = formatDate(purchaseDateMillis) }, cal.get(Calendar.YEAR), cal.get(Calendar.MONTH), cal.get(Calendar.DAY_OF_MONTH)).apply { datePicker.calendarViewShown = true; datePicker.spinnersShown = false }.show()
    }
    private fun hideKeyboard() {
        currentFocus?.let { focused -> val imm = getSystemService(Context.INPUT_METHOD_SERVICE) as? android.view.inputmethod.InputMethodManager; imm?.hideSoftInputFromWindow(focused.windowToken, 0); focused.clearFocus() }
    }
    private fun loadForEdit(bill: String) = safeLaunch("loadForEdit") {
        val data: PurchaseEditData = viewModel.loadForEdit(bill) ?: return@safeLaunch
        originalPurchase = data.purchase; originalItems = data.items
        purchaseDateMillis = data.purchase.createdAt; dateValueText.text = formatDate(purchaseDateMillis)
        partyName.setText(data.supplierName); updateSupplierBalanceDisplay(data.supplierName)
        supplierInvoiceNoInput.setText(data.purchase.supplierInvoiceNo)
        paidInput.setText(if (data.purchase.paid > 0) Math.round(data.purchase.paid).toString() else "")
        endLineEdit(); lines.clear(); lines.addAll(data.lines)
        renderItemsList(); updateGrandTotal(); deleteButton.visibility = View.VISIBLE
        // NEW (Split Payment): if this bill was originally saved with 2+ payment
        // methods, re-open it in split mode so editing/re-saving it preserves the
        // breakdown instead of collapsing it into one method — mirrors
        // SaleActivity.loadForEdit's equivalent applySplitPayments(edit.payments) call.
        if (data.payments.size >= 2) {
            applySplitPayments(data.payments)
        } else {
            clearSplitPayments()
        }
    }
    private fun onItemPicked(pickedName: String) {
        val product = products.find { it.name.equals(pickedName, ignoreCase = true) } ?: return
        applyPickedProduct(product)
    }
    private fun applyPickedProduct(product: Product) {
        selectedProduct = product
        val unitOptions = mutableListOf(product.unit)
        if (product.secondaryUnit.isNotBlank() && product.secondaryUnit != product.unit) {
            unitOptions.add(product.secondaryUnit)
            if (product.tertiaryUnit.isNotBlank() && product.tertiaryUnit != product.unit && product.tertiaryUnit != product.secondaryUnit && product.tertiaryUnitQty > 0) { unitOptions.add(product.tertiaryUnit) }
        }
        unitSpinner.adapter = ArrayAdapter(this, android.R.layout.simple_spinner_dropdown_item, unitOptions)
        buildUnitChips(unitOptions, product.unit)
        conversionInfo.text = buildString {
            if (unitOptions.contains(product.secondaryUnit) && product.secondaryUnitQty > 0) { append("1 ${product.unit} = ${product.secondaryUnitQty} ${product.secondaryUnit}") }
            if (unitOptions.contains(product.tertiaryUnit) && product.tertiaryUnitQty > 0) { if (isNotEmpty()) append("   •   "); append("1 ${product.secondaryUnit} = ${product.tertiaryUnitQty} ${product.tertiaryUnit}") }
        }
        conversionInfo.visibility = if (conversionInfo.text.isNotEmpty()) View.VISIBLE else View.GONE
        lastMainQty = 0.0; lastMainRate = 0.0; lastPurchaseMainRate = 0.0
        // NEW ("10/10 Purchase screen" item #7/#15): remember the product's rates
        // as they stand right now (before this purchase touches them) — the retail/
        // wholesale fields prefill from these, and the margin warning always compares
        // against these, not whatever the user is mid-typing.
        currentProductSalePriceMain = product.salePrice
        currentProductWholesalePriceMain = product.wholesalePrice
        lastMainRetailRate = 0.0; lastMainWholesaleRate = 0.0
        refillAutoRate(); updateLineTotal(); updateMarginWarning()
        qty.setText(""); totalLotPrice.setText(""); qty.requestFocus()

        // NEW: look up the actual last purchase rate for this product (not the running
        // weighted-average cost) and refill the Rate field with it once found — unless
        // the user has already started typing their own rate by the time it arrives.
        val barcode = product.barcode
        safeLaunch("findLastPurchaseRate") {
            val result = viewModel.lastPurchaseRate(barcode, editBillNo)
            if (selectedProduct?.barcode != barcode) return@safeLaunch // user picked something else meanwhile
            if (result != null) {
                val (histRate, histUnit) = result
                lastPurchaseMainRate = rateToMainUnit(product, histRate, histUnit)
                if (rate.text.toString().isBlank()) {
                    refillAutoRate()
                }
            }
        }
    }

    // ---- FIX: delegated to Database.kt's toPrimaryUnitRate()/fromPrimaryUnitRate() —
    // the same central unitLadder() that backs toSmallestUnits()/fromSmallestUnits() —
    // instead of the old PricingTierMath.kt, which kept a second, independent unit-tier
    // system for rate math. Two independent copies of this math meant a fix to one
    // (e.g. for a secondary-only or tertiary product) could silently miss the other —
    // now Sale, Purchase, Return, and Edit all route through the same conversion
    // engine, so a fix here fixes every screen at once. ----
    // NEW: converts a rate recorded in some historical unit to the product's main-unit
    // basis, using the product's CURRENT conversion factors.
    private fun rateToMainUnit(product: Product, rate: Double, fromUnit: String): Double =
        product.toPrimaryUnitRate(rate, fromUnit)
    // NOTE: a QUANTITY converts the opposite way a RATE does — entering 24 "dozen"
    // becomes 2 "carton" (divide by the tier factor), while a rate per "dozen"
    // becomes a bigger rate per "carton" (multiply). So this reuses fromPrimaryUnitRate's
    // divide-by-factor arithmetic even though it's converting a quantity, not a price.
    private fun toMainUnitQty(entered: Double): Double {
        val product = selectedProduct ?: return entered
        val chosenUnit = unitSpinner.selectedItem?.toString() ?: product.unit
        return product.fromPrimaryUnitRate(entered, chosenUnit)
    }
    private fun fromMainUnitRate(mainRate: Double, chosenUnit: String): Double {
        val product = selectedProduct ?: return mainRate
        return product.fromPrimaryUnitRate(mainRate, chosenUnit)
    }
    private fun toMainUnitRate(entered: Double): Double {
        val product = selectedProduct ?: return entered
        val chosenUnit = unitSpinner.selectedItem?.toString() ?: product.unit
        return product.toPrimaryUnitRate(entered, chosenUnit)
    }
    private fun refillAutoRate() {
        val product = selectedProduct ?: return
        val chosenUnit = unitSpinner.selectedItem?.toString() ?: product.unit
        val base = when {
            lastMainRate > 0 -> lastMainRate                 // user already typed a rate for this pick — keep it
            lastPurchaseMainRate > 0 -> lastPurchaseMainRate  // NEW: prefer the real last purchase rate
            else -> product.cost                              // fallback: weighted-average cost
        }
        val r = fromMainUnitRate(base, chosenUnit)
        suppressRateWatcher = true
        rate.setText(if (r > 0) "%.2f".format(r) else "")
        suppressRateWatcher = false
        if (r > 0) rate.post { rate.selectAll() }
        // NEW ("10/10 Purchase screen" item #7): retail/wholesale fields follow the
        // same "keep whatever the user already typed, else fall back" pattern as
        // Rate above, falling back to the product's CURRENT salePrice/wholesalePrice
        // instead of cost.
        val retailBase = if (lastMainRetailRate > 0) lastMainRetailRate else currentProductSalePriceMain
        val wholesaleBase = if (lastMainWholesaleRate > 0) lastMainWholesaleRate else currentProductWholesalePriceMain
        suppressRetailRateWatcher = true
        retailRateInput.setText(if (retailBase > 0) "%.2f".format(fromMainUnitRate(retailBase, chosenUnit)) else "")
        suppressRetailRateWatcher = false
        suppressWholesaleRateWatcher = true
        wholesaleRateInput.setText(if (wholesaleBase > 0) "%.2f".format(fromMainUnitRate(wholesaleBase, chosenUnit)) else "")
        suppressWholesaleRateWatcher = false
        updateMarginWarning()
    }
    // NEW ("10/10 Purchase screen" item #15): warns — right where the rate is being
    // typed — when today's purchase rate would eat into or invert the item's CURRENT
    // sale margin, instead of that only being discoverable later on the Sale screen.
    private fun updateMarginWarning() {
        val sale = currentProductSalePriceMain
        if (selectedProduct == null || sale <= 0.0 || lastMainRate <= 0.0) {
            marginWarningText.visibility = View.GONE
            return
        }
        val margin = sale - lastMainRate
        val marginPct = (margin / sale) * 100.0
        marginWarningText.visibility = View.VISIBLE
        when {
            margin <= 0 -> {
                marginWarningText.setTextColor(Color.parseColor(red))
                marginWarningText.text = com.grocerypos.v11.util.Loc.t(this,
                    "⚠ Loss! Purchase rate ≥ current Sale Rate (Rs %.2f)".format(sale),
                    "⚠ نقصان! خریداری ریٹ موجودہ سیل ریٹ (روپے %.2f) کے برابر یا زیادہ ہے".format(sale))
            }
            marginPct < 10.0 -> {
                marginWarningText.setTextColor(Color.parseColor(gold))
                marginWarningText.text = com.grocerypos.v11.util.Loc.t(this,
                    "⚠ Low margin: Rs %.2f (%.1f%%) vs Sale Rate Rs %.2f".format(margin, marginPct, sale),
                    "⚠ کم منافع: روپے %.2f (%.1f%%) بمقابلہ سیل ریٹ روپے %.2f".format(margin, marginPct, sale))
            }
            else -> {
                marginWarningText.setTextColor(Color.parseColor(teal))
                marginWarningText.text = com.grocerypos.v11.util.Loc.t(this,
                    "Margin: Rs %.2f (%.1f%%) vs Sale Rate Rs %.2f".format(margin, marginPct, sale),
                    "منافع: روپے %.2f (%.1f%%) بمقابلہ سیل ریٹ روپے %.2f".format(margin, marginPct, sale))
            }
        }
    }
    private fun buildUnitChips(options: List<String>, selected: String) {
        unitToggleRow.removeAllViews()
        if (options.size < 2) { unitToggleRow.visibility = View.GONE; return }
        unitToggleRow.visibility = View.VISIBLE
        options.forEachIndexed { index, unitLabel ->
            val isSelected = unitLabel == selected
            val chip = TextView(this).apply {
                text = unitLabel; textSize = 13f; setTypeface(typeface, android.graphics.Typeface.BOLD); setPadding(28, 13, 28, 13)
                setTextColor(if (isSelected) Color.WHITE else Color.parseColor(teal))
                background = if (isSelected) roundedBg(teal, 30) else strokedBg(teal, cardWhite, 30)
                layoutParams = LinearLayout.LayoutParams(LinearLayout.LayoutParams.WRAP_CONTENT, LinearLayout.LayoutParams.WRAP_CONTENT).apply { setMargins(if (index == 0) 0 else 8, 0, 0, 0) }
                setOnClickListener { unitSpinner.setSelection(options.indexOf(unitLabel)); buildUnitChips(options, unitLabel); refillAutoRate(); updateLineTotal() }
            }
            unitToggleRow.addView(chip)
        }
    }
    private fun updateLineTotal() {
        val q = qty.text.toString().toDoubleOrNull() ?: 0.0
        val r = rate.text.toString().toDoubleOrNull() ?: 0.0
        totalAmountText.text = "Total Amount: Rs %.0f".format(Math.round(q * r).toDouble())
    }
    private fun addItem() {
        val enteredName = itemName.text.toString().trim()
        val q = qty.text.toString().toDoubleOrNull()
        val r = rate.text.toString().toDoubleOrNull()
        val unit = (unitSpinner.selectedItem as? String) ?: "pcs"
        if (enteredName.isEmpty()) { itemName.error = "Required"; return }
        if (q == null || q <= 0) { qty.error = "Enter quantity"; return }
        if (r == null || r < 0) { rate.error = "Enter rate"; return }
        val product = selectedProduct ?: products.find { it.name.equals(enteredName, ignoreCase = true) }
        if (product == null) { openAddProductDialog(enteredName); return }
        // FIX (fraction control): reject a purchase-line qty that doesn't resolve to a
        // whole smallest-unit for non-fractional items (Piece/Dabbi/Bottle etc.) right
        // here, same as SaleActivity.addItem() — previously this was only caught deep
        // inside proceedSave() at save time (via a thrown exception), so a bad line could
        // sit in the bill through several other item entries before the user found out.
        if (!product.isValidSmallestQty(product.toSmallestUnits(q, unit))) {
            Toast.makeText(this, "Qty ($q $unit) whole ${product.smallestUnitName()} mein convert nahi hoti", Toast.LENGTH_SHORT).show()
            return
        }
        val line = PurchaseLine(product.name, product.barcode, q, unit, r, Math.round(q * r).toDouble(), product.unit, product.secondaryUnit, product.secondaryUnitQty, product.tertiaryUnit, product.tertiaryUnitQty, lastMainRetailRate, lastMainWholesaleRate)
        // NEW: editing an existing billed item updates it in place instead of appending
        val editIndex = editingLineIndex
        if (editIndex != null && editIndex in lines.indices) {
            lines[editIndex] = line
        } else {
            lines.add(line)
        }
        endLineEdit()
        renderItemsList(); updateGrandTotal()
        itemName.setText(""); qty.setText(""); rate.setText(""); totalLotPrice.setText("")
        retailRateInput.setText(""); wholesaleRateInput.setText("")
        selectedProduct = null; lastMainQty = 0.0; lastMainRate = 0.0
        lastMainRetailRate = 0.0; lastMainWholesaleRate = 0.0
        currentProductSalePriceMain = 0.0; currentProductWholesalePriceMain = 0.0
        marginWarningText.visibility = View.GONE
        conversionInfo.visibility = View.GONE; unitToggleRow.visibility = View.GONE
        totalAmountText.text = "Total Amount: Rs 0"
        itemName.requestFocus()
        if (editBillNo == null) saveDraft()
        if (lines.isNotEmpty() && paidInput.text.toString().isBlank()) {
            paidWarningText.visibility = View.VISIBLE
            paymentSection.background = strokedBg("#FF9800", "#FFF8E1", 18)
            paymentSection.postDelayed({ paymentSection.background = strokedBg(border, cardWhite, 18) }, 2000)
        }
    }
    // NEW: populate the entry fields from an already-billed line so the user can correct
    // a mistake (wrong qty/rate/unit) without deleting the line and retyping it.
    private fun editLine(index: Int) {
        if (index !in lines.indices) return
        val line = lines[index]
        editingLineIndex = index
        val product = products.find { it.name.equals(line.itemName, ignoreCase = true) }
        if (product != null) { applyPickedProduct(product) }
        // NEW ("10/10 Purchase screen" item #7): restore this line's own retail/
        // wholesale rate (if it had set one) instead of the product's current
        // rate that applyPickedProduct() just prefilled.
        if (line.retailRate > 0.0) { lastMainRetailRate = line.retailRate }
        if (line.wholesaleRate > 0.0) { lastMainWholesaleRate = line.wholesaleRate }
        if (line.retailRate > 0.0 || line.wholesaleRate > 0.0) { refillAutoRate() }
        itemName.setText(line.itemName)
        qty.setText(formatQty(line.qty))
        // FIX (edited rate silently corrupted — e.g. Rs 2405/Outer turning into
        // Rs 48.10 after hitting UPDATE ITEM): rate.setText() below fires the rate
        // TextWatcher, which recomputes lastMainRate by reading unitSpinner's
        // CURRENTLY selected unit — still whatever applyPickedProduct() defaulted
        // it to (e.g. "Ctn"), not this line's own unit ("Outer"), since the spinner
        // isn't switched to line.unit until a few lines below. That mismatched
        // lastMainRate then gets converted AGAIN when the spinner selection change
        // below fires refillAutoRate(), compounding a wrong unit-conversion (÷50
        // here) into the visible rate. Precomputing lastMainRate directly from
        // line.rate/line.unit — before either the unit switch or the rate text is
        // set — makes both of those follow-on triggers land back on the same
        // correct number instead of drifting from it.
        if (product != null) { lastMainRate = product.toPrimaryUnitRate(line.rate, line.unit) }
        suppressRateWatcher = true
        rate.setText(if (line.rate == line.rate.toLong().toDouble()) line.rate.toLong().toString() else line.rate.toString())
        suppressRateWatcher = false
        totalLotPrice.setText("")
        val unitOptions = (unitSpinner.adapter as? ArrayAdapter<*>)?.let { adapter -> (0 until adapter.count).map { adapter.getItem(it).toString() } } ?: listOf(line.unit)
        val unitIndex = unitOptions.indexOf(line.unit)
        if (unitIndex >= 0) { unitSpinner.setSelection(unitIndex); buildUnitChips(unitOptions, line.unit) }
        updateLineTotal()
        addItemButton.text = com.grocerypos.v11.util.Loc.t(this, "UPDATE ITEM", "آئٹم اپ ڈیٹ کریں")
        cancelEditButton.visibility = View.VISIBLE
        scrollTargetView = itemEntrySection
        scrollAlignTop = true
        scrollArea.post { scrollToShowView(itemEntrySection, true) }
        qty.requestFocus(); qty.selectAll()
    }
    private fun endLineEdit() {
        editingLineIndex = null
        addItemButton.text = com.grocerypos.v11.util.Loc.t(this, "ADD ITEM", "آئٹم شامل کریں")
        cancelEditButton.visibility = View.GONE
    }
    // NEW: 📊 popup on the item-entry row — pulls this item's past purchases,
    // groups them by supplier (last rate + running average), and shows who's
    // currently cheapest, so the user can decide before typing today's rate.
    private fun showSupplierComparison() {
        val typed = itemName.text.toString().trim()
        val product = selectedProduct ?: products.find { it.name.equals(typed, ignoreCase = true) }
        if (product == null) {
            Toast.makeText(this, com.grocerypos.v11.util.Loc.t(this, "Select an item first", "پہلے آئٹم منتخب کریں"), Toast.LENGTH_SHORT).show()
            return
        }
        lifecycleScope.launch {
            val db = PosDatabase.get(this@PurchaseActivity)
            val records = db.purchaseDao().purchaseRecordsForItem(product.barcode)
            val body = ScrollView(this@PurchaseActivity).apply {
                val col = LinearLayout(this@PurchaseActivity).apply { orientation = LinearLayout.VERTICAL; setPadding(32, 16, 32, 16) }
                if (records.isEmpty()) {
                    col.addView(TextView(this@PurchaseActivity).apply {
                        text = com.grocerypos.v11.util.Loc.t(this@PurchaseActivity, "No supplier data yet for this item", "اس آئٹم کے لیے ابھی کوئی سپلائر ڈیٹا نہیں")
                        setTextColor(Color.parseColor(textMuted)); textSize = 13.5f
                    })
                } else {
                    val bySupplier = records.groupBy { it.supplierName }
                    val summaries = bySupplier.map { (supplier, rows) ->
                        Triple(supplier, rows.first().unitCost, Pair(rows.sumOf { it.unitCost } / rows.size, rows.size))
                    }.sortedBy { it.second }
                    val cheapest = summaries.minOf { it.second }
                    summaries.forEach { (supplier, lastRate, avgAndCount) ->
                        val isBest = lastRate == cheapest
                        col.addView(LinearLayout(this@PurchaseActivity).apply {
                            orientation = LinearLayout.VERTICAL
                            setPadding(24, 16, 24, 16)
                            background = strokedBg(if (isBest) navy else border, if (isBest) "#EAF2FF" else cardWhite, 12)
                            layoutParams = LinearLayout.LayoutParams(LinearLayout.LayoutParams.MATCH_PARENT, LinearLayout.LayoutParams.WRAP_CONTENT).apply { setMargins(0, 0, 0, 10) }
                            val top = LinearLayout(this@PurchaseActivity).apply { orientation = LinearLayout.HORIZONTAL; gravity = Gravity.CENTER_VERTICAL }
                            top.addView(TextView(this@PurchaseActivity).apply {
                                text = supplier; textSize = 14f; setTypeface(typeface, android.graphics.Typeface.BOLD); setTextColor(Color.parseColor(textDark))
                                layoutParams = LinearLayout.LayoutParams(0, LinearLayout.LayoutParams.WRAP_CONTENT, 1f)
                            })
                            if (isBest) top.addView(TextView(this@PurchaseActivity).apply {
                                text = com.grocerypos.v11.util.Loc.t(this@PurchaseActivity, "BEST", "بہترین")
                                textSize = 9.5f; setTextColor(Color.WHITE); setTypeface(typeface, android.graphics.Typeface.BOLD)
                                background = roundedBg(navy, 20); setPadding(14, 4, 14, 4)
                            })
                            top.addView(View(this@PurchaseActivity).apply { layoutParams = LinearLayout.LayoutParams(10, 1) })
                            top.addView(TextView(this@PurchaseActivity).apply {
                                text = "Rs %.2f".format(lastRate); textSize = 14.5f; setTypeface(typeface, android.graphics.Typeface.BOLD)
                                setTextColor(Color.parseColor(if (isBest) navy else textDark))
                            })
                            addView(top)
                            addView(TextView(this@PurchaseActivity).apply {
                                text = "Avg Rs %.2f  •  %d purchase%s".format(avgAndCount.first, avgAndCount.second, if (avgAndCount.second == 1) "" else "s")
                                textSize = 11.5f; setTextColor(Color.parseColor(textMuted)); setPadding(0, 4, 0, 0)
                            })
                        })
                    }
                }
                addView(col)
            }
            android.app.AlertDialog.Builder(this@PurchaseActivity)
                .setTitle("${product.name} \u2014 " + com.grocerypos.v11.util.Loc.t(this@PurchaseActivity, "Suppliers", "سپلائرز"))
                .setView(body)
                .setPositiveButton(com.grocerypos.v11.util.Loc.t(this@PurchaseActivity, "Close", "بند کریں"), null)
                .show()
        }
    }
    private fun normalizeUnitName(u: String) = u.trim().lowercase()
    private fun standardUnitQty(fromUnit: String, toUnit: String): Double? {
        val f = normalizeUnitName(fromUnit); val t = normalizeUnitName(toUnit)
        val gramNames = setOf("gram", "grams", "g", "gm"); val pieceNames = setOf("pcs", "pc", "piece", "pieces"); val mlNames = setOf("ml", "milliliter", "millilitre"); val kgNames = setOf("kg", "kgs", "kilogram", "kilograms"); val litreNames = setOf("litre", "liter", "l", "ltr"); val paoNames = setOf("pao", "pav")
        return when {
            f == "dozen" && t in pieceNames -> 12.0
            f == "gross" && t == "dozen" -> 12.0
            f == "gross" && t in pieceNames -> 144.0
            f in kgNames && t in gramNames -> 1000.0
            f in litreNames && t in mlNames -> 1000.0
            f == "quintal" && t in kgNames -> 100.0
            f == "ton" && t in kgNames -> 1000.0
            f in kgNames && t in paoNames -> 4.0
            f in paoNames && t in gramNames -> 250.0
            f == "pao" && t == "gram" -> 250.0
            else -> null
        }
    }
    private fun trimNum(v: Double): String = if (v == v.toLong().toDouble()) v.toLong().toString() else v.toString()
    private fun promptAddUnitInline(onAdded: (String) -> Unit) {
        hideKeyboard(); val input = EditText(this).apply { setPadding(32, 24, 32, 24) }
        android.app.AlertDialog.Builder(this).setTitle(com.grocerypos.v11.util.Loc.t(this, "New Unit", "نیا یونٹ")).setView(input).setPositiveButton(com.grocerypos.v11.util.Loc.t(this, "Add", "شامل کریں")) { _, _ ->
            val v = input.text.toString().trim()
            if (v.isNotEmpty()) safeLaunch("addUnit") { viewModel.addUnit(v); Toast.makeText(this@PurchaseActivity, com.grocerypos.v11.util.Loc.t(this@PurchaseActivity, "Unit added", "یونٹ شامل ہو گیا"), Toast.LENGTH_SHORT).show(); onAdded(v) }
        }.setNegativeButton(com.grocerypos.v11.util.Loc.t(this, "Cancel", "منسوخ کریں"), null).show()
    }

    // NEW: "Add New Category" inline from the Purchase screen's "Add New Product"
    // dialog — same master-table insert as ProductActivity's "Add New Category",
    // just triggered here so the shop owner doesn't have to leave Purchase to
    // create a category first before adding a new product mid-purchase.
    private fun promptAddCategoryInline(onAdded: (String) -> Unit) {
        hideKeyboard(); val input = EditText(this).apply { setPadding(32, 24, 32, 24) }
        android.app.AlertDialog.Builder(this).setTitle(com.grocerypos.v11.util.Loc.t(this, "New Category", "نئی کیٹیگری")).setView(input).setPositiveButton(com.grocerypos.v11.util.Loc.t(this, "Add", "شامل کریں")) { _, _ ->
            val v = input.text.toString().trim()
            if (v.isNotEmpty()) safeLaunch("addCategory") { viewModel.addCategory(v); Toast.makeText(this@PurchaseActivity, com.grocerypos.v11.util.Loc.t(this@PurchaseActivity, "Category added", "کیٹیگری شامل ہو گئی"), Toast.LENGTH_SHORT).show(); onAdded(v) }
        }.setNegativeButton(com.grocerypos.v11.util.Loc.t(this, "Cancel", "منسوخ کریں"), null).show()
    }
    private fun handleScannedItems(json: String) {
        val arr = try { JSONArray(json) } catch (e: Exception) { Log.e(TAG, "handleScannedItems: bad json", e); return }
        val scanned = mutableListOf<ScannedLine>()
        for (i in 0 until arr.length()) {
            val o = try { arr.getJSONObject(i) } catch (e: Exception) { Log.e(TAG, "handleScannedItems: skipping bad item $i", e); continue }
            val scannedName = o.optString("name").trim(); val scannedQty = o.optDouble("qty", 0.0); val scannedRate = o.optDouble("rate", 0.0)
            if (scannedName.isEmpty() || scannedQty <= 0) continue
            scanned.add(ScannedLine(scannedName, scannedQty, scannedRate))
        }
        safeLaunch("handleScannedItems") {
            val newLines = viewModel.processScannedItems(scanned)
            if (newLines.isNotEmpty()) { lines.addAll(newLines); renderItemsList(); updateGrandTotal(); if (editBillNo == null) saveDraft() }
            Toast.makeText(this@PurchaseActivity, "${newLines.size} items added from scan", Toast.LENGTH_LONG).show()
        }
    }

    private fun renderItemsList() {
        itemsContainer.removeAllViews()
        billedItemsHeader.visibility = if (lines.isEmpty()) View.GONE else View.VISIBLE
        val totalSoFar = lines.sumOf { it.amount }
        billedItemsSummaryText.text = "\uD83D\uDCCB  " + com.grocerypos.v11.util.Loc.t(this@PurchaseActivity, "Billed Items", "بل شدہ آئٹمز") +
            "  (${lines.size})  ·  Rs %.0f".format(totalSoFar)
        lines.forEachIndexed { index, line ->
            val row = premiumCard(); val topRow = LinearLayout(this).apply { orientation = LinearLayout.HORIZONTAL; gravity = Gravity.CENTER_VERTICAL }
            val badge = TextView(this).apply { text = "#${index + 1}"; textSize = 11.5f; setTypeface(typeface, android.graphics.Typeface.BOLD); setTextColor(Color.parseColor(gold)); background = strokedBg("#E7DCB8", amberBadge, 8); setPadding(14, 5, 14, 5) }
            topRow.addView(badge)
            topRow.addView(TextView(this).apply { text = "  ${line.itemName}"; textSize = 14.5f; setTypeface(typeface, android.graphics.Typeface.BOLD); setTextColor(Color.parseColor(textDark)); layoutParams = LinearLayout.LayoutParams(0, LinearLayout.LayoutParams.WRAP_CONTENT, 1f) })
            topRow.addView(TextView(this).apply { text = "Rs %.0f".format(line.amount); textSize = 14.5f; setTypeface(typeface, android.graphics.Typeface.BOLD); setTextColor(Color.parseColor(navy)) })
            // NEW: ✎ edit — loads this line back into the entry fields for correction
            // instead of forcing a delete + re-add of the whole line.
            topRow.addView(TextView(this).apply { text = "  \u270E"; textSize = 14f; setTextColor(Color.parseColor(teal)); setTypeface(typeface, android.graphics.Typeface.BOLD); setOnClickListener { billedItemsDialog?.dismiss(); editLine(index) } })
            topRow.addView(TextView(this).apply { text = "  \u2715"; textSize = 14f; setTextColor(Color.parseColor(red)); setTypeface(typeface, android.graphics.Typeface.BOLD); setOnClickListener {
                val editing = editingLineIndex
                when {
                    editing == index -> endLineEdit()
                    editing != null && editing > index -> editingLineIndex = editing - 1
                }
                lines.removeAt(index); renderItemsList(); updateGrandTotal(); if (editBillNo == null) saveDraft()
            } })
            row.addView(topRow)
            row.addView(TextView(this).apply { text = "${formatQty(line.qty)} ${line.unit} x ${line.rate} = Rs %.0f".format(line.amount); textSize = 12.5f; setTextColor(Color.parseColor(textMuted)); setPadding(0, 6, 0, 0) })
            itemsContainer.addView(row)
        }
    }
    private fun updateGrandTotal() {
        val total = Math.round(lines.sumOf { it.amount }).toDouble(); grandTotalText.text = "Rs %.0f".format(total)
        val paid = Math.round(paidInput.text.toString().toDoubleOrNull() ?: 0.0).toDouble()
        val due = (total - paid).coerceAtLeast(0.0)
        dueAmountText.text = "Rs %.0f".format(due)
        dueAmountText.setTextColor(Color.parseColor(if (due > 0) red else successGreen))
        if (paid == 0.0 && total > 0) { paidWarningText.visibility = View.VISIBLE; paidWarningText.text = "Paid khali hai - Ye Rs %.0f Udhaar jayega".format(due) }
        else { paidWarningText.visibility = View.GONE }
    }
    // ---- CHANGED (Roman Urdu request: "jab new party add karte hain to sirf party
    // name aata hai sale/purchase ke waqt, jab ke uska Sara form khulna chahiye") —
    // this used to be a single name-only EditText. Now it mirrors PartyActivity's
    // "Add Supplier" form (Name*, Phone, Opening Balance — no Credit Limit field,
    // same as PartyActivity hides that field for suppliers) instead of quick-adding
    // a supplier that's missing everything but its name. ----
    private fun promptAddSupplier() {
        fun microLabel(text: String) = TextView(this).apply {
            this.text = text; textSize = 11.5f
            setTextColor(Color.parseColor(textMuted))
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
        val nameField = field("Supplier name")
        body.addView(nameField); body.addView(spacer(16))

        body.addView(microLabel("PHONE (OPTIONAL)"))
        val phoneField = field("Phone", InputType.TYPE_CLASS_PHONE)
        body.addView(phoneField); body.addView(spacer(16))

        body.addView(microLabel("OPENING BALANCE (RS, IF ANY PREVIOUS DUE)"))
        val openingField = field("Opening balance", InputType.TYPE_CLASS_NUMBER or InputType.TYPE_NUMBER_FLAG_DECIMAL)
        body.addView(openingField)

        val scroll = ScrollView(this).apply { addView(body) }

        android.app.AlertDialog.Builder(this).setTitle("Add Supplier").setView(scroll).setPositiveButton("Add") { _, _ ->
            val name = nameField.text.toString().trim()
            if (name.isBlank()) {
                Toast.makeText(this, "Name is required", Toast.LENGTH_SHORT).show()
                return@setPositiveButton
            }
            val phone = phoneField.text.toString().trim()
            val openingBalance = openingField.parseMoneyOrWarn(this, "Opening Balance", "افتتاحی بیلنس") ?: return@setPositiveButton
            safeLaunch("addSupplier") { viewModel.addSupplier(name, phone, openingBalance); partyName.setText(name) }
        }.setNegativeButton("Cancel", null).show()
    }
    private fun openAddProductDialog(prefillName: String) {
        val content = LinearLayout(this).apply { orientation = LinearLayout.VERTICAL; setBackgroundColor(Color.parseColor(cardWhite)) }
        val dialogHeader = LinearLayout(this).apply { orientation = LinearLayout.HORIZONTAL; gravity = Gravity.CENTER_VERTICAL; setPadding(28, 26, 28, 26); background = gradientBg(navy, navy) }
        dialogHeader.addView(TextView(this).apply { text = "\u2795  Add New Product"; textSize = 18f; setTextColor(Color.WHITE); setTypeface(typeface, android.graphics.Typeface.BOLD) })
        content.addView(dialogHeader)
        val scrollableBody = ScrollView(this); val body = LinearLayout(this).apply { orientation = LinearLayout.VERTICAL; setPadding(28, 26, 28, 8) }; scrollableBody.addView(body)
        fun microLabel(text: String) = TextView(this).apply { this.text = text; textSize = 11.5f; setTextColor(Color.parseColor(textMuted)); setTypeface(typeface, android.graphics.Typeface.BOLD); setPadding(0, 0, 0, 8); letterSpacing = 0.04f }
        body.addView(microLabel("PRODUCT NAME"))
        val nameField = EditText(this).apply { setText(prefillName); setTextColor(Color.parseColor(textDark)); background = strokedBg(border, fieldFill, 14); setPadding(18, 16, 18, 16); textSize = 15f }
        body.addView(nameField); body.addView(spacer(10))
        // NEW: English search-tag field, same as ProductActivity's Add/Edit Product screen.
        // Lets a product added mid-purchase get its English/Roman search alias right away,
        // without having to leave Purchase and edit it later from the Products screen.
        val searchTagBox = LinearLayout(this).apply {
            orientation = LinearLayout.HORIZONTAL
            gravity = Gravity.CENTER_VERTICAL
            setPadding(18, 8, 8, 8)
            background = strokedBg(border, fieldFill, 14)
        }
        val searchTagField = EditText(this).apply {
            hint = com.grocerypos.v11.util.Loc.t(
                this@PurchaseActivity,
                "Search Tag in English (optional)",
                "تلاش کے لیے انگریزی لفظ (اختیاری)"
            )
            setHintTextColor(Color.parseColor(textMuted))
            setTextColor(Color.parseColor(textDark))
            background = null
            textSize = 14f
            maxLines = 1
            // Same trick as ProductActivity: forces the Latin/QWERTY keyboard on this
            // field even if the Product Name field above just left it in Urdu mode.
            inputType = InputType.TYPE_CLASS_TEXT or InputType.TYPE_TEXT_VARIATION_VISIBLE_PASSWORD
            imeOptions = EditorInfo.IME_ACTION_NEXT
            layoutParams = LinearLayout.LayoutParams(-1, -2)
        }
        searchTagBox.addView(searchTagField)
        body.addView(searchTagBox); body.addView(spacer(18))
        body.addView(microLabel("CATEGORY"))
        val categoryRow = LinearLayout(this).apply { orientation = LinearLayout.HORIZONTAL; gravity = Gravity.CENTER_VERTICAL }
        val categorySpinnerBox = LinearLayout(this).apply { background = strokedBg(border, fieldFill, 14); setPadding(14, 2, 14, 2); layoutParams = LinearLayout.LayoutParams(0, LinearLayout.LayoutParams.WRAP_CONTENT, 1f) }
        val categorySpinnerDialog = Spinner(this).apply { layoutParams = LinearLayout.LayoutParams(LinearLayout.LayoutParams.MATCH_PARENT, LinearLayout.LayoutParams.WRAP_CONTENT) }
        categorySpinnerBox.addView(categorySpinnerDialog); categoryRow.addView(categorySpinnerBox); categoryRow.addView(spacer(8).apply { layoutParams = LinearLayout.LayoutParams((10 * resources.displayMetrics.density).toInt(), 1) })
        var allCategories = listOf<String>()
        categoryRow.addView(circleIcon("+", teal, 34) {
            promptAddCategoryInline { newCat ->
                allCategories = (allCategories + newCat).distinct()
                categorySpinnerDialog.adapter = ArrayAdapter(this@PurchaseActivity, android.R.layout.simple_spinner_dropdown_item, allCategories)
                categorySpinnerDialog.setSelection(allCategories.indexOf(newCat))
            }
        })
        body.addView(categoryRow); body.addView(spacer(20))
        safeLaunch("loadCategoriesForDialog") { val cats = viewModel.categories(); allCategories = cats; categorySpinnerDialog.adapter = ArrayAdapter(this@PurchaseActivity, android.R.layout.simple_spinner_dropdown_item, cats) }
        body.addView(microLabel("PRIMARY UNIT"))
        val primaryRow = LinearLayout(this).apply { orientation = LinearLayout.HORIZONTAL; gravity = Gravity.CENTER_VERTICAL }
        val primarySpinnerBox = LinearLayout(this).apply { background = strokedBg(border, fieldFill, 14); setPadding(14, 2, 14, 2); layoutParams = LinearLayout.LayoutParams(0, LinearLayout.LayoutParams.WRAP_CONTENT, 1f) }
        val primarySpinner = Spinner(this).apply { layoutParams = LinearLayout.LayoutParams(LinearLayout.LayoutParams.MATCH_PARENT, LinearLayout.LayoutParams.WRAP_CONTENT) }
        primarySpinnerBox.addView(primarySpinner); primaryRow.addView(primarySpinnerBox); primaryRow.addView(spacer(8).apply { layoutParams = LinearLayout.LayoutParams((10 * resources.displayMetrics.density).toInt(), 1) })
        primaryRow.addView(circleIcon("+", teal, 34) { promptAddUnitInline { newUnit -> allUnits = (allUnits + newUnit).distinct(); primarySpinner.adapter = ArrayAdapter(this@PurchaseActivity, android.R.layout.simple_spinner_dropdown_item, allUnits); primarySpinner.setSelection(allUnits.indexOf(newUnit)) } })
        body.addView(primaryRow); body.addView(spacer(20))
        body.addView(microLabel("SECONDARY UNIT"))
        val secondaryRow = LinearLayout(this).apply { orientation = LinearLayout.HORIZONTAL; gravity = Gravity.CENTER_VERTICAL }
        val secondarySpinnerBox = LinearLayout(this).apply { background = strokedBg(border, fieldFill, 14); setPadding(14, 2, 14, 2); layoutParams = LinearLayout.LayoutParams(0, LinearLayout.LayoutParams.WRAP_CONTENT, 1f) }
        val secondarySpinner = Spinner(this).apply { layoutParams = LinearLayout.LayoutParams(LinearLayout.LayoutParams.MATCH_PARENT, LinearLayout.LayoutParams.WRAP_CONTENT) }
        secondarySpinnerBox.addView(secondarySpinner); secondaryRow.addView(secondarySpinnerBox); secondaryRow.addView(spacer(8).apply { layoutParams = LinearLayout.LayoutParams((10 * resources.displayMetrics.density).toInt(), 1) })
        secondaryRow.addView(circleIcon("+", teal, 34) { promptAddUnitInline { newUnit -> allUnits = (allUnits + newUnit).distinct(); val opts = listOf("None") + allUnits; secondarySpinner.adapter = ArrayAdapter(this@PurchaseActivity, android.R.layout.simple_spinner_dropdown_item, opts); secondarySpinner.setSelection(opts.indexOf(newUnit)) } })
        body.addView(secondaryRow); body.addView(spacer(16))
        val secQtyBox = LinearLayout(this).apply { orientation = LinearLayout.HORIZONTAL; gravity = Gravity.CENTER_VERTICAL; background = strokedBg(border, fieldFill, 14); setPadding(16, 4, 16, 4) }
        val secQtyField = EditText(this).apply { hint = "1 Primary = how many Secondary?"; setHintTextColor(Color.parseColor(textMuted)); setTextColor(Color.parseColor(textDark)); background = null; inputType = InputType.TYPE_CLASS_NUMBER or InputType.TYPE_NUMBER_FLAG_DECIMAL }
        secQtyField.setOnFocusChangeListener { _, hasFocus -> if (hasFocus) secQtyField.post { secQtyField.selectAll() } }
        secQtyBox.addView(secQtyField); body.addView(secQtyBox); body.addView(spacer(20))
        body.addView(microLabel("TERTIARY UNIT"))
        val tertiaryRow = LinearLayout(this).apply { orientation = LinearLayout.HORIZONTAL; gravity = Gravity.CENTER_VERTICAL }
        val tertiarySpinnerBox = LinearLayout(this).apply { background = strokedBg(border, fieldFill, 14); setPadding(14, 2, 14, 2); layoutParams = LinearLayout.LayoutParams(0, LinearLayout.LayoutParams.WRAP_CONTENT, 1f) }
        val tertiarySpinner = Spinner(this).apply { layoutParams = LinearLayout.LayoutParams(LinearLayout.LayoutParams.MATCH_PARENT, LinearLayout.LayoutParams.WRAP_CONTENT) }
        tertiarySpinnerBox.addView(tertiarySpinner); tertiaryRow.addView(tertiarySpinnerBox); tertiaryRow.addView(spacer(8).apply { layoutParams = LinearLayout.LayoutParams((10 * resources.displayMetrics.density).toInt(), 1) })
        tertiaryRow.addView(circleIcon("+", teal, 34) { promptAddUnitInline { newUnit -> allUnits = (allUnits + newUnit).distinct(); val opts = listOf("None") + allUnits; tertiarySpinner.adapter = ArrayAdapter(this@PurchaseActivity, android.R.layout.simple_spinner_dropdown_item, opts); tertiarySpinner.setSelection(opts.indexOf(newUnit)) } })
        body.addView(tertiaryRow); body.addView(spacer(16))
        val terQtyBox = LinearLayout(this).apply { orientation = LinearLayout.HORIZONTAL; gravity = Gravity.CENTER_VERTICAL; background = strokedBg(border, fieldFill, 14); setPadding(16, 4, 16, 4) }
        val terQtyField = EditText(this).apply { hint = "1 Secondary = how many Tertiary?"; setHintTextColor(Color.parseColor(textMuted)); setTextColor(Color.parseColor(textDark)); background = null; inputType = InputType.TYPE_CLASS_NUMBER or InputType.TYPE_NUMBER_FLAG_DECIMAL }
        terQtyField.setOnFocusChangeListener { _, hasFocus -> if (hasFocus) terQtyField.post { terQtyField.selectAll() } }
        terQtyBox.addView(terQtyField); body.addView(terQtyBox); body.addView(spacer(20))
        // NEW: "Default Unit for Sale Screen" chip picker, same purple-badge control as
        // ProductActivity's Units dialog (ProductUnitDialog.kt). Lets a product created
        // mid-purchase get its Sale-screen default unit pinned right away, instead of
        // always falling back to Auto until someone opens it from the Products screen.
        val purple = "#8B5CF6"
        body.addView(microLabel("DEFAULT UNIT FOR SALE SCREEN"))
        body.addView(TextView(this).apply {
            text = com.grocerypos.v11.util.Loc.t(
                this@PurchaseActivity,
                "Auto picks it for you. Choose one yourself if you'd rather it always show a specific unit.",
                "آٹو خود بخود منتخب کرتا ہے۔ اگر ہمیشہ کوئی خاص یونٹ دکھانا ہو تو خود منتخب کریں"
            )
            textSize = 11.5f
            setTextColor(Color.parseColor(textMuted))
            setPadding(0, 0, 0, 10)
        })
        val defaultUnitChipRow = LinearLayout(this).apply { orientation = LinearLayout.HORIZONTAL }
        body.addView(defaultUnitChipRow); body.addView(spacer(20))
        var chosenDefaultUnitIndex = -1
        fun refreshDefaultUnitChips() {
            val tierNames = mutableListOf(primarySpinner.selectedItem?.toString() ?: "")
            val s = secondarySpinner.selectedItem?.toString() ?: "None"
            val t = tertiarySpinner.selectedItem?.toString() ?: "None"
            if (s != "None") tierNames.add(s)
            if (s != "None" && t != "None") tierNames.add(t)
            if (chosenDefaultUnitIndex !in 0 until tierNames.size) chosenDefaultUnitIndex = -1
            defaultUnitChipRow.removeAllViews()
            val options = listOf(-1 to com.grocerypos.v11.util.Loc.t(this@PurchaseActivity, "Auto", "آٹو")) +
                tierNames.mapIndexed { index, unitLabel -> index to unitLabel }
            options.forEachIndexed { i, (indexValue, label) ->
                val isSelected = indexValue == chosenDefaultUnitIndex
                defaultUnitChipRow.addView(TextView(this@PurchaseActivity).apply {
                    text = label
                    textSize = 12.5f
                    setTypeface(typeface, android.graphics.Typeface.BOLD)
                    setPadding(20, 12, 20, 12)
                    setTextColor(if (isSelected) Color.WHITE else Color.parseColor(purple))
                    background = if (isSelected) gradientBg(purple, purple, cornerTop = 30, cornerBottom = 30)
                        else strokedBg(purple, cardWhite, 30)
                    layoutParams = LinearLayout.LayoutParams(-2, -2).apply { setMargins(if (i == 0) 0 else 8, 0, 0, 0) }
                    setOnClickListener { chosenDefaultUnitIndex = indexValue; refreshDefaultUnitChips() }
                })
            }
        }
        // NEW ("10/10 Purchase screen" item #7): a brand-new product created mid-purchase
        // used to get salePrice=wholesalePrice=0.0 with no prompt at all — now defaults
        // to the purchase rate being entered (a sane starting point) but stays editable.
        val purchaseRateNow = rate.text.toString().toDoubleOrNull() ?: 0.0
        body.addView(microLabel("RETAIL RATE (SALE PRICE)"))
        val retailField = EditText(this).apply { setText(if (purchaseRateNow > 0) trimNum(purchaseRateNow) else ""); setTextColor(Color.parseColor(textDark)); background = strokedBg(border, fieldFill, 14); setPadding(18, 16, 18, 16); textSize = 15f; inputType = InputType.TYPE_CLASS_NUMBER or InputType.TYPE_NUMBER_FLAG_DECIMAL }
        body.addView(retailField); body.addView(spacer(18))
        body.addView(microLabel("WHOLESALE RATE"))
        val wholesaleField = EditText(this).apply { setText(if (purchaseRateNow > 0) trimNum(purchaseRateNow) else ""); setTextColor(Color.parseColor(textDark)); background = strokedBg(border, fieldFill, 14); setPadding(18, 16, 18, 16); textSize = 15f; inputType = InputType.TYPE_CLASS_NUMBER or InputType.TYPE_NUMBER_FLAG_DECIMAL }
        body.addView(wholesaleField)
        content.addView(scrollableBody, LinearLayout.LayoutParams(LinearLayout.LayoutParams.MATCH_PARENT, 0, 1f))
        primarySpinner.adapter = ArrayAdapter(this, android.R.layout.simple_spinner_dropdown_item, allUnits)
        val secondaryOptions = listOf("None") + allUnits; secondarySpinner.adapter = ArrayAdapter(this, android.R.layout.simple_spinner_dropdown_item, secondaryOptions)
        val tertiaryOptions = listOf("None") + allUnits; tertiarySpinner.adapter = ArrayAdapter(this, android.R.layout.simple_spinner_dropdown_item, tertiaryOptions)
        fun autoFillSecondaryQty() {
            val p = primarySpinner.selectedItem?.toString() ?: return; val s = secondarySpinner.selectedItem?.toString() ?: return; if (s == "None") return
            val std = standardUnitQty(p, s) ?: return
            secQtyField.setText(trimNum(std))
            secQtyField.post { secQtyField.selectAll() }
        }
        fun autoFillTertiaryQty() {
            val s = secondarySpinner.selectedItem?.toString() ?: return; val t = tertiarySpinner.selectedItem?.toString() ?: return; if (s == "None" || t == "None") return
            val std = standardUnitQty(s, t) ?: return
            terQtyField.setText(trimNum(std))
            terQtyField.post { terQtyField.selectAll() }
        }
        primarySpinner.onItemSelectedListener = object : AdapterView.OnItemSelectedListener { override fun onItemSelected(p: AdapterView<*>?, v: View?, pos: Int, id: Long) { autoFillSecondaryQty(); refreshDefaultUnitChips() } override fun onNothingSelected(p: AdapterView<*>?) {} }
        secondarySpinner.onItemSelectedListener = object : AdapterView.OnItemSelectedListener { override fun onItemSelected(p: AdapterView<*>?, v: View?, pos: Int, id: Long) { autoFillSecondaryQty(); autoFillTertiaryQty(); refreshDefaultUnitChips() } override fun onNothingSelected(p: AdapterView<*>?) {} }
        tertiarySpinner.onItemSelectedListener = object : AdapterView.OnItemSelectedListener { override fun onItemSelected(p: AdapterView<*>?, v: View?, pos: Int, id: Long) { autoFillTertiaryQty(); refreshDefaultUnitChips() } override fun onNothingSelected(p: AdapterView<*>?) {} }
        refreshDefaultUnitChips()
        val footer = LinearLayout(this).apply { orientation = LinearLayout.HORIZONTAL; setPadding(28, 18, 28, 26) }; content.addView(footer)
        val dialog = android.app.AlertDialog.Builder(this).setView(content).create()
        footer.addView(TextView(this).apply { text = "Cancel"; gravity = Gravity.CENTER; textSize = 14f; setTextColor(Color.parseColor(textMuted)); setTypeface(typeface, android.graphics.Typeface.BOLD); background = strokedBg(border, fieldFill, 14); setPadding(0, 22, 0, 22); layoutParams = LinearLayout.LayoutParams(0, LinearLayout.LayoutParams.WRAP_CONTENT, 1f).apply { setMargins(0, 0, 8, 0) }; setOnClickListener { dialog.dismiss() } })
        footer.addView(TextView(this).apply {
            text = "Save"; gravity = Gravity.CENTER; textSize = 14f; setTextColor(Color.WHITE); setTypeface(typeface, android.graphics.Typeface.BOLD); background = gradientBg(teal, teal, cornerBottom = 14, cornerTop = 14); setPadding(0, 22, 0, 22); layoutParams = LinearLayout.LayoutParams(0, LinearLayout.LayoutParams.WRAP_CONTENT, 1f).apply { setMargins(8, 0, 0, 0) }
            setOnClickListener {
                val pname = nameField.text.toString().trim(); if (pname.isEmpty()) { nameField.error = "Required"; return@setOnClickListener }
                val primaryUnit = primarySpinner.selectedItem?.toString() ?: "pcs"; var secondaryUnit = secondarySpinner.selectedItem?.toString() ?: "None"; val secondaryQty = secQtyField.text.toString().toDoubleOrNull() ?: 0.0; var tertiaryUnit = tertiarySpinner.selectedItem?.toString() ?: "None"; var tertiaryQty = terQtyField.text.toString().toDoubleOrNull() ?: 0.0
                if (secondaryUnit != "None" && secondaryUnit == primaryUnit) { Toast.makeText(this@PurchaseActivity, "Secondary must be different", Toast.LENGTH_SHORT).show(); return@setOnClickListener }
                if (secondaryUnit != "None" && secondaryQty <= 0) { secQtyField.error = "Enter qty"; return@setOnClickListener }
                if (tertiaryUnit != "None" && secondaryUnit == "None") { Toast.makeText(this@PurchaseActivity, "Select Secondary first", Toast.LENGTH_SHORT).show(); return@setOnClickListener }
                if (secondaryUnit == "None") { tertiaryUnit = "None"; tertiaryQty = 0.0 }
                val costVal = rate.parseMoneyOrWarn(this@PurchaseActivity, "Cost Price", "لاگت قیمت") ?: return@setOnClickListener
                val saleVal = retailField.parseMoneyOrWarn(this@PurchaseActivity, "Retail Rate", "خوردہ ریٹ") ?: return@setOnClickListener
                val wholesaleVal = wholesaleField.parseMoneyOrWarn(this@PurchaseActivity, "Wholesale Rate", "ہول سیل ریٹ") ?: return@setOnClickListener
                val newProduct = Product(barcode = "P" + System.currentTimeMillis(), name = pname, category = categorySpinnerDialog.selectedItem?.toString() ?: "General", cost = costVal, salePrice = saleVal, wholesalePrice = wholesaleVal, stock = 0.0, openingStock = 0.0, unit = primaryUnit, secondaryUnit = if (secondaryUnit == "None") "" else secondaryUnit, secondaryUnitQty = secondaryQty, tertiaryUnit = if (tertiaryUnit == "None") "" else tertiaryUnit, tertiaryUnitQty = tertiaryQty, searchTag = searchTagField.text.toString().trim(), defaultUnitIndex = chosenDefaultUnitIndex)
                safeLaunch("saveNewProduct") { viewModel.addProduct(newProduct); Toast.makeText(this@PurchaseActivity, "Product added", Toast.LENGTH_SHORT).show(); itemName.setText(newProduct.name); applyPickedProduct(newProduct); dialog.dismiss() }
            }
        })
        dialog.show()
    }
    private fun confirmDeletePurchase() {
        val billNo = editBillNo ?: return
        android.app.AlertDialog.Builder(this).setTitle("Delete Purchase").setMessage("This will remove the bill and reverse its stock and supplier balance effect. Continue?").setPositiveButton("Delete") { _, _ -> viewModel.delete(billNo, originalPurchase, originalItems) }.setNegativeButton("Cancel", null).show()
    }

    private fun savePurchase() {
        if (isSaving) return

        hideKeyboard()
        val party = partyName.text.toString().trim()
        if (party.isEmpty()) { partyName.error = "Required"; return }
        if (lines.isEmpty()) { Toast.makeText(this, "Add at least one item", Toast.LENGTH_SHORT).show(); return }
        val subtotal = lines.sumOf { it.amount }
        val grandTotal = Math.round(subtotal).toDouble().coerceAtLeast(0.0)
        // FIX (silent-0.0 audit): a non-empty, unparseable Paid Amount used to fall
        // through the isPaidEmpty check below (isPaidEmpty only trips on a truly
        // empty box or a value that parses to exactly 0.0 — an unparseable string
        // is neither), then got silently re-parsed to 0.0 further down in
        // proceedSave(). So a typo here used to skip the "save as credit?" warning
        // entirely, then save with amountPaid=0 with no warning of any kind. Now
        // parsed once, up front, and threaded through every call in this chain
        // instead of each one re-reading paidInput.text.toString() itself.
        val amountPaid = paidInput.parseMoneyOrWarn(this, "Paid Amount", "ادا شدہ رقم") ?: return
        val isPaidEmpty = amountPaid == 0.0
        if (isPaidEmpty && grandTotal > 0) {
            android.app.AlertDialog.Builder(this)
                .setTitle("Confirm Credit Purchase")
                .setMessage("You have not entered Paid Amount.\nTotal: Rs %.0f\n\nThis bill will be saved as CREDIT (Udhaar).\nSupplier balance will increase.\n\nAre you sure?".format(grandTotal))
                .setPositiveButton("Yes, Save as Credit") { _, _ -> checkInvoiceDuplicateThenProceed(party, grandTotal, amountPaid) }
                .setNegativeButton("Enter Payment") { dialog, _ -> dialog.dismiss(); if (isTabletWide) paidInput.requestFocus() else scrollArea.post { scrollArea.smoothScrollTo(0, paymentSection.top); paidInput.requestFocus() } }
                .show()
            return
        }
        checkInvoiceDuplicateThenProceed(party, grandTotal, amountPaid)
    }
    // NEW ("10/10 Purchase screen" item #2): an EXACT duplicate check on the
    // supplier's own invoice number, run before the existing same-party+same-amount
    // heuristic below. Only fires when an invoice number was actually entered —
    // otherwise falls straight through to checkDuplicateAndProceed().
    private fun checkInvoiceDuplicateThenProceed(party: String, grandTotal: Double, amountPaid: Double) {
        val invoiceNo = supplierInvoiceNoInput.text.toString().trim()
        if (invoiceNo.isEmpty()) { checkDuplicateAndProceed(party, grandTotal, amountPaid); return }
        lifecycleScope.launch {
            val db = PosDatabase.get(this@PurchaseActivity)
            val duplicate = db.purchaseDao().findDuplicateBySupplierInvoice(party, invoiceNo, editBillNo ?: "")
            if (duplicate == null) { checkDuplicateAndProceed(party, grandTotal, amountPaid); return@launch }
            android.app.AlertDialog.Builder(this@PurchaseActivity)
                .setTitle(com.grocerypos.v11.util.Loc.t(this@PurchaseActivity, "Duplicate Invoice Number", "ڈپلیکیٹ انوائس نمبر"))
                .setMessage(
                    com.grocerypos.v11.util.Loc.t(
                        this@PurchaseActivity,
                        "Invoice #$invoiceNo from $party is already recorded as Bill #${duplicate.billNo}.\n\nSave this one anyway?",
                        "$party کا انوائس نمبر #$invoiceNo پہلے ہی بل نمبر #${duplicate.billNo} کے طور پر محفوظ ہے۔\n\nکیا پھر بھی محفوظ کریں؟"
                    )
                )
                .setPositiveButton(com.grocerypos.v11.util.Loc.t(this@PurchaseActivity, "Save Anyway", "پھر بھی محفوظ کریں")) { _, _ -> checkDuplicateAndProceed(party, grandTotal, amountPaid) }
                .setNegativeButton(com.grocerypos.v11.util.Loc.t(this@PurchaseActivity, "Cancel", "منسوخ کریں"), null)
                .show()
        }
    }
    // FIX (Double Bill Alert — match by bill DATE, not "last 24 hours"): this used
    // to compare `r.createdAt` (the real-world instant the earlier bill was saved)
    // against `now` (the real-world instant THIS save button was tapped), inside a
    // rolling 24-hour window. That only ever caught a duplicate entered back-to-back
    // in real time — re-entering an old/backdated bill days later (a very common
    // Kiryana workflow: catching up a week's paper bills in one sitting) never
    // triggered it, even for the exact same supplier, amount, AND bill date, since
    // real elapsed time between the two saves was well past 24 hours. The alert is
    // meant to catch "same bill entered twice", which is a same-party + same-amount
    // + same BILL DATE question — nothing to do with when either save actually
    // happened — so this now compares each candidate's `createdAt` (which doubles
    // as the purchase's own recorded date) against this bill's `purchaseDateMillis`
    // by calendar day, with no time-window cutoff at all.
    private fun checkDuplicateAndProceed(party: String, grandTotal: Double, amountPaid: Double) {
        lifecycleScope.launch {
            val db = PosDatabase.get(this@PurchaseActivity)
            val recent = db.purchaseDao().allPurchases()
            val dayFmt = SimpleDateFormat("yyyyMMdd", Locale.getDefault())
            val targetDay = dayFmt.format(Date(purchaseDateMillis))
            val duplicate = recent.firstOrNull { r ->
                r.billNo != editBillNo &&
                r.status != "returned" &&
                r.supplierName.equals(party, ignoreCase = true) &&
                r.total == grandTotal &&
                dayFmt.format(Date(r.createdAt)) == targetDay
            }
            if (duplicate == null) {
                proceedSave(party, grandTotal, amountPaid)
                return@launch
            }
            val fmt = SimpleDateFormat("dd MMM yyyy, hh:mm a", Locale.getDefault())
            android.app.AlertDialog.Builder(this@PurchaseActivity)
                .setTitle(com.grocerypos.v11.util.Loc.t(this@PurchaseActivity, "Possible Duplicate Bill", "ممکنہ ڈپلیکیٹ بل"))
                .setMessage(
                    com.grocerypos.v11.util.Loc.t(
                        this@PurchaseActivity,
                        "A purchase from $party for Rs %.0f was already saved on ${fmt.format(Date(duplicate.createdAt))} (Bill #${duplicate.billNo}).\n\nSave this one anyway?".format(grandTotal),
                        "$party کی طرف سے Rs %.0f کی خریداری پہلے ہی ${fmt.format(Date(duplicate.createdAt))} کو محفوظ ہو چکی ہے (بل نمبر ${duplicate.billNo})۔\n\nکیا پھر بھی محفوظ کریں؟".format(grandTotal)
                    )
                )
                .setPositiveButton(com.grocerypos.v11.util.Loc.t(this@PurchaseActivity, "Save Anyway", "پھر بھی محفوظ کریں")) { _, _ -> proceedSave(party, grandTotal, amountPaid) }
                .setNegativeButton(com.grocerypos.v11.util.Loc.t(this@PurchaseActivity, "Cancel", "منسوخ کریں"), null)
                .show()
        }
    }

    private fun proceedSave(party: String, grandTotal: Double, amountPaid: Double) {
        isSaving = true
        saveButton.isEnabled = false
        val discount = 0.0
        val amountPaidClamped = amountPaid.coerceIn(0.0, grandTotal)
        // NEW (Split Payment): while a split is active, the combined method label
        // (e.g. "Cash + Bank") is derived from splitPayments instead of the single
        // spinner — mirrors SaleActivity's proceedSaveSale().
        val paymentMethod = if (splitPayments.isNotEmpty())
            splitPayments.map { it.first }.distinct().joinToString(" + ")
        else paymentMethodSpinner.selectedItem?.toString() ?: "Cash"
        // Persisting (supplier insert, reversal of the original purchase on edit,
        // purchase+items insert, stock/cost update per line, supplier balance update,
        // payment + cash transaction insert, all as one Room transaction) now lives in
        // PurchaseRepository.savePurchase — the result comes back as a Saved/Error
        // PurchaseEvent, handled in handleViewModelEvent().
        viewModel.save(
            editBillNo = editBillNo,
            party = party,
            grandTotal = grandTotal,
            amountPaid = amountPaidClamped,
            discount = discount,
            paymentMethod = paymentMethod,
            purchaseDateMillis = purchaseDateMillis,
            lines = lines.toList(),
            original = originalPurchase,
            originalItems = originalItems,
            supplierInvoiceNo = supplierInvoiceNoInput.text.toString().trim(),
            payments = splitPayments.toList()
        )
    }

    private fun openBillPreview(billNo: String, forSaving: Boolean, party: String = partyName.text.toString().trim(), grandTotal: Double = Math.round(lines.sumOf { it.amount }).toDouble(), discount: Double = 0.0, amountPaid: Double = Math.round(paidInput.text.toString().toDoubleOrNull() ?: 0.0).toDouble(), paymentMethod: String = "Cash") {
        val itemsEncoded = lines.joinToString("\u0002") { listOf(it.itemName, formatQty(it.qty), it.unit, it.rate, it.amount).joinToString("\u0003") }
        val previewIntent = Intent(this, BillPreviewActivity::class.java).apply {
            putExtra(BillPreviewActivity.EXTRA_TYPE, "purchase")
            putExtra(BillPreviewActivity.EXTRA_REFERENCE, billNo)
            putExtra(BillPreviewActivity.EXTRA_PARTY_NAME, party)
            putExtra(BillPreviewActivity.EXTRA_PARTY_LABEL, "Supplier")
            putExtra(BillPreviewActivity.EXTRA_DATE_MILLIS, purchaseDateMillis)
            putExtra(BillPreviewActivity.EXTRA_SUBTOTAL, grandTotal + discount)
            putExtra(BillPreviewActivity.EXTRA_DISCOUNT, discount)
            putExtra(BillPreviewActivity.EXTRA_TOTAL, grandTotal)
            putExtra(BillPreviewActivity.EXTRA_PAID, amountPaid)
            putExtra(BillPreviewActivity.EXTRA_PAYMENT_METHOD, paymentMethod)
            putExtra(BillPreviewActivity.EXTRA_ITEMS_ENCODED, itemsEncoded)
        }
        startActivity(previewIntent); if (forSaving) finish()
    }

    // ================= Split Payment (multiple payment methods) =================
    // NEW: lets one purchase bill be paid across more than one method — e.g.
    // Rs 300 Cash + Rs 200 Bank on a Rs 500 bill — instead of the single Cash/Bank
    // spinner forcing the whole Paid Amount onto one method. Mirrors
    // SaleActivity's openSplitPaymentDialog()/applySplitPayments()/
    // clearSplitPayments()/updateSplitPaymentSummaryText() exactly. `splitPayments`
    // (declared above with paymentMethodSpinner) is the source of truth once
    // applied — proceedSave() forwards it straight through, and
    // RoomPurchaseRepository.savePurchase computes the real per-method
    // cash-drawer entries and the combined "Cash + Bank" method label from it,
    // ignoring paidInput/the spinner for as long as a split is active.
    private fun openSplitPaymentDialog() {
        val density = resources.displayMetrics.density
        fun dp(v: Int) = (v * density).toInt()

        val container = LinearLayout(this).apply {
            orientation = LinearLayout.VERTICAL
            setPadding(dp(24), dp(16), dp(24), dp(8))
        }
        val totalDue = Math.round(lines.sumOf { it.amount }).toDouble()
        val infoText = TextView(this).apply {
            text = com.grocerypos.v11.util.Loc.t(
                this@PurchaseActivity,
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
                adapter = ArrayAdapter(this@PurchaseActivity, android.R.layout.simple_spinner_dropdown_item, methods)
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
            // Helpful default: two blank rows, Cash and Bank, nudging the user
            // toward actually splitting rather than just re-typing one method.
            addRow("Cash", 0.0)
            addRow("Bank", 0.0)
        }

        val addRowLink = TextView(this).apply {
            text = com.grocerypos.v11.util.Loc.t(this@PurchaseActivity, "+ Add another method", "+ ایک اور طریقہ شامل کریں")
            setTextColor(Color.parseColor(navy))
            setTypeface(typeface, android.graphics.Typeface.BOLD)
            textSize = 13f
            setPadding(0, dp(8), 0, dp(8))
            setOnClickListener { addRow("Cash", 0.0) }
        }
        container.addView(addRowLink)

        val scrollWrapper = ScrollView(this).apply { addView(container) }

        android.app.AlertDialog.Builder(this)
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
                    dialog.getButton(android.app.AlertDialog.BUTTON_POSITIVE).setOnClickListener {
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
                    dialog.getButton(android.app.AlertDialog.BUTTON_NEUTRAL)?.setOnClickListener {
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
        // paidInput's own watcher already runs updateGrandTotal()/refreshDue()-style
        // logic off the setText() above — no need to duplicate that here.
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
            android.app.AlertDialog.Builder(this)
                .setTitle(com.grocerypos.v11.util.Loc.t(this, "Remove Split Payment?", "تقسیم شدہ ادائیگی ہٹائیں؟"))
                .setPositiveButton(com.grocerypos.v11.util.Loc.t(this, "Remove", "ہٹائیں")) { _, _ -> clearSplitPayments() }
                .setNegativeButton(com.grocerypos.v11.util.Loc.t(this, "Edit", "ترمیم کریں")) { _, _ -> openSplitPaymentDialog() }
                .show()
        }
        splitPaymentLink.visibility = View.VISIBLE
        splitPaymentLink.text = com.grocerypos.v11.util.Loc.t(this, "\u270E Edit split payment", "\u270E تقسیم میں ترمیم کریں")
    }
}

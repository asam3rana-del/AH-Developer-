package com.grocerypos.v11.ui

import android.app.AlertDialog
import android.content.Intent
import android.graphics.Color
import android.graphics.Typeface
import android.graphics.drawable.GradientDrawable
import android.os.Build
import android.os.Bundle
import android.text.Editable
import android.text.InputType
import android.text.TextWatcher
import android.view.Gravity
import android.view.View
import android.view.ViewOutlineProvider
import android.widget.*
import androidx.appcompat.app.AppCompatActivity
import androidx.core.view.ViewCompat
import androidx.core.view.WindowInsetsCompat
import androidx.lifecycle.lifecycleScope
import com.grocerypos.v11.Customer
import com.grocerypos.v11.data.PartyRepository
import com.grocerypos.v11.PosDatabase
import com.grocerypos.v11.Product
import com.grocerypos.v11.R
import com.grocerypos.v11.SyncQueueHelper
import com.grocerypos.v11.Supplier
import com.grocerypos.v11.formatStockBreakdown
import com.grocerypos.v11.matchesQuery
import com.grocerypos.v11.util.Loc
import kotlinx.coroutines.flow.collectLatest
import kotlinx.coroutines.flow.combine
import kotlinx.coroutines.flow.first
import kotlinx.coroutines.launch
import java.text.SimpleDateFormat
import java.util.Date
import java.util.Locale
import com.grocerypos.v11.ui.components.*

/**
 * Home-screen style dashboard: "You'll Get / You'll Give" summary cards + Parties /
 * Transactions / Items tabs + searchable list + bottom Add Purchase / Add Sale bar.
 *
 * ---- CHANGES IN THIS VERSION (per Roman Urdu requirements) ----
 * 1. Parties tab: tapping a party now opens PartyTransactionActivity — a NEW screen
 *    showing only that party's own sales/purchases, instead of the generic PartyActivity.
 * 2. Transactions tab: the search/add row now shows ONLY a search box (no "New Party"
 *    button, no filter icon) and filters by party name across cached transactions.
 * 3. Transactions tab: rows are clickable and open the underlying Sale/Purchase.
 *    *** ASSUMPTION *** — SaleActivity is opened with extra "invoice" (String) and
 *    PurchaseActivity with extra "billNo" (String) to load that record in edit mode,
 *    matching the pattern already described for PurchaseActivity's edit/delete flow.
 *    If those activities expect different extra keys, tell me and I'll fix the two
 *    lines marked ADJUST-EXTRA-KEY below.
 * 4. Items tab: search/add row now shows a search box + "+ Add Item" button (opens
 *    ProductActivity) instead of "+ New Party". Search filters by product name.
 * 5. Items tab: each product row shows its full profile — category, unit, purchase
 *    (cost) rate, retail (sale) rate, wholesale rate — plus lifetime sold/purchased
 *    qty & amount already there before. Tapping a row shows the full detail dialog.
 *
 * ---- FIX IN THIS VERSION ----
 * 6. You'll Get / You'll Give totals (both the top summary cards and each party row's
 *    label) were using the exact same sign rule for customers and suppliers, which
 *    wrongly mixed receivables and payables together. Fixed so that:
 *      - Customer closing > 0  => customer owes the shop (receivable)  -> You'll Get
 *      - Customer closing < 0  => shop owes the customer                -> You'll Give
 *      - Supplier closing > 0  => shop owes the supplier (payable)      -> You'll Give
 *      - Supplier closing < 0  => supplier owes the shop (e.g. credit)  -> You'll Get
 *    See updateSummaryTotals() and dashboardPartyRow() below.
 * 7. Items tab stock display: Product.stock is the SMALLEST-unit count, not a primary-unit
 *    count, so "${stock} ${unit}" (raw smallest count + primary unit label) was misleading.
 *    Now uses Product.formatStockBreakdown() (same helper Product/Purchase/Sale screens use)
 *    so the Items tab always agrees with the rest of the app.
 *
 * ---- BUILD FIX ----
 * 8. renderItemsList(): sold?.totalQty / pur?.totalQty come back as Double (SQL SUM
 *    aggregate), but ItemAgg.soldQty/purQty are declared Int. `sold?.totalQty ?: 0`
 *    mixed a Double with an Int literal, which the Kotlin compiler couldn't resolve to
 *    a single type (":app:compileDebugKotlin" failure — "Argument type mismatch: actual
 *    type is 'it(kotlin.Number & kotlin.Comparable<CapturedType(*)>)', but 'kotlin.Int'
 *    was expected"). Fixed by defaulting to 0.0 and rounding to Int explicitly.
 *
 * ---- NEW IN THIS VERSION ----
 * 9. Items tab detail dialog now has an "EDIT" button next to "Close". It opens a
 *    small dialog with Purchase / Retail Sale / Wholesale rate fields pre-filled,
 *    editable, and saved straight to the DB via productDao().upsert() — see
 *    showEditRatesDialog() below. ItemAgg now carries the full Product `entity` so
 *    this update doesn't need a second DB lookup by name. Confirmed against
 *    ProductActivity.kt, which uses the same db.productDao().upsert(product) call.
 *
 * Manifest: PartyTransactionActivity must be added:
 *   <activity android:name=".ui.PartyTransactionActivity" android:exported="false" />
 */
class PartyDashboardActivity : AppCompatActivity() {

    // ---- Reports-style flat design — pulled from ThemeManager so this screen stays
    // in sync with the rest of the app and respects dark mode. Party = flatPink
    // everywhere per ThemeManager's documented category convention; the extra accent
    // hues below (purple/teal/gold) come straight from the same shared flat palette
    // so each quick-menu row keeps its own distinct icon-badge color. ----
    private var bg = "#F4F6F8"
    internal var navy = "#0B2545"       // app-wide accent (header + main-menu chrome)
    internal var blue = "#185FA5"        // primary accent (Add Purchase/New Party/Add Item) — flatBlueFg
    internal var orange = "#993C1D"     // flatCoralFg
    internal var green = "#085041"      // flatTealFg — unified with Reports' "positive" color
    internal var red = "#D32F4A"
    internal var cardWhite = "#FFFFFF"
    internal var cardBorder = "#E3E8EE"
    internal var labelGray = "#7C8798"
    internal var purple = "#534AB7"     // flatPurpleFg
    internal var teal = "#085041"       // flatTealFg
    internal var gold = "#854F0B"       // flatAmberFg
    internal var textDark = "#0B2545"

    private fun loadThemeColors() {
        val p = com.grocerypos.v11.util.ThemeManager.palette(this)
        bg = p.bg
        cardWhite = p.cardWhite
        cardBorder = p.border
        labelGray = p.textMuted
        textDark = p.textDark
        navy = p.navy
        blue = p.flatBlueFg
        orange = p.flatCoralFg
        green = p.flatTealFg
        red = p.red
        purple = p.flatPurpleFg
        teal = p.flatTealFg
        gold = p.flatAmberFg
    }

    private lateinit var youllGetValue: TextView
    private lateinit var youllGiveValue: TextView
    private lateinit var tabRow: LinearLayout
    private lateinit var searchRowContainer: LinearLayout
    private lateinit var listContainer: LinearLayout

    private var activeTab = Tab.PARTIES
    private var filterMode = FilterMode.ALL
    internal var allItems: List<PartyItem> = emptyList()
    private var role: String = "cashier"

    // ADDED (Khatabook-style party list — screenshot reference): date format for
    // each party row's last-activity date, e.g. "05 Aug 2026".
    private val partyRowDateFmt = SimpleDateFormat("dd MMM yyyy", Locale.getDefault())

    // ---- Transactions tab cache + search query (so typing doesn't re-hit the DB) ----
    private var txCache: List<TxRow> = emptyList()
    private var txQuery: String = ""
    // NEW (search transactions by item name too, not just party name): reference
    // (invoice/billNo) -> lowercase item names on that bill, built once alongside
    // txCache in renderTransactionsList(), used by renderTxRows()'s filter below.
    private var txItemNamesByRef: Map<String, List<String>> = emptyMap()

    // ---- Items tab cache + search query ----
    private var itemCache: List<ItemAgg> = emptyList()
    private var itemQuery: String = ""

    private enum class Tab { PARTIES, TRANSACTIONS, ITEMS }
    // ---- ADDED (Payable/Receivable split): RECEIVABLE = "You'll Get" only (money
    // owed TO the shop), PAYABLE = "You'll Give" only (money the shop owes OUT).
    // These are independent of CUSTOMERS/SUPPLIERS because a customer can have a
    // negative balance (shop owes them, e.g. an overpayment/advance) and a supplier
    // can have a negative balance too (supplier owes the shop) — so "who to pay" and
    // "who to receive from" is a different cut than "customer vs supplier". ----
    private enum class FilterMode { ALL, CUSTOMERS, SUPPLIERS, RECEIVABLE, PAYABLE }

    /** Unified wrapper so customers + suppliers can share one list/adapter-ish rendering. */
    internal data class PartyItem(
        val id: Long,
        val name: String,
        val phone: String,
        val closing: Double,
        val isCustomer: Boolean,
        // ---- IMPROVEMENT PACK (Payments 10/10 — link due reminders to Payments):
        // null = no active due-date reminder on any of this customer's unpaid sales;
        // otherwise the most urgent one, so the party list can badge it. Always null
        // for suppliers — dueSales() only tracks money owed TO the shop. ----
        val dueStatus: DueStatus? = null,
        // ADDED (Khatabook-style party list — screenshot reference): most recent
        // sale/purchase/payment timestamp for this party, across all three tables.
        // null means the party has no transactions yet (freshly added party).
        val lastActivityAt: Long? = null,
        // NEW (Stuck Balance): the stuck part of `closing` for a customer (0.0 for suppliers
        // and almost every customer). `closing` is already the TOTAL payable (daily + stuck);
        // the row uses this only to show the Daily / Stuck split under the name.
        val stuck: Double = 0.0
    )

    // OVERDUE: dueDate has passed. DUE_TODAY: dueDate is today. Anything further out
    // isn't badged — the list would just get noisy — but still shows on Due Date
    // Reminders (Reports > Due Date Reminders) same as always.
    internal enum class DueStatus { OVERDUE, DUE_TODAY }

    private data class TxRow(
        val reference: String,   // invoice (sale) or billNo (purchase)
        val partyName: String,
        val amount: Double,
        val createdAt: Long,
        val isSale: Boolean,
        val status: String
    )

    private data class ItemAgg(
        val product: String,
        val category: String,
        val unit: String,
        val cost: Double,
        val salePrice: Double,
        val wholesalePrice: Double,
        val stock: Double,
        val stockDisplay: String,
        val soldQty: Int,
        val soldAmt: Double,
        val purQty: Int,
        val purAmt: Double,
        // Kept so the edit-rate dialog can update the exact row via productDao()
        // without a second lookup — everything ItemAgg needs is already derived
        // from this same Product.
        val entity: Product
    )

    override fun onCreate(b: Bundle?) {
        super.onCreate(b)
        loadThemeColors()

        val session = getSharedPreferences("session", MODE_PRIVATE)
        if (session.getString("username", null) == null) {
            startActivity(Intent(this@PartyDashboardActivity, LoginActivity::class.java))
            finish()
            return
        }
        role = session.getString("role", "cashier") ?: "cashier"

        val outer = LinearLayout(this).apply {
            orientation = LinearLayout.VERTICAL
            setBackgroundColor(Color.parseColor(bg))
        }

        outer.addView(buildHeader())

        val root = LinearLayout(this).apply {
            orientation = LinearLayout.VERTICAL
            setPadding(24, 20, 24, 0)
        }

        root.addView(buildSummaryCards())
        root.addView(spacer(18))
        root.addView(buildTabs())
        root.addView(spacer(16))

        searchRowContainer = LinearLayout(this).apply {
            orientation = LinearLayout.HORIZONTAL
            gravity = Gravity.CENTER_VERTICAL
        }
        root.addView(searchRowContainer)
        root.addView(spacer(14))

        listContainer = LinearLayout(this).apply { orientation = LinearLayout.VERTICAL }
        root.addView(listContainer)
        root.addView(spacer(90)) // keep list clear of the floating bottom bar

        val scrollArea = ScrollView(this).apply {
            layoutParams = FrameLayout.LayoutParams(
                FrameLayout.LayoutParams.MATCH_PARENT, FrameLayout.LayoutParams.MATCH_PARENT
            )
            addView(root)
        }

        val stack = FrameLayout(this).apply {
            addView(scrollArea)
            addView(buildBottomBar())
            layoutParams = LinearLayout.LayoutParams(LinearLayout.LayoutParams.MATCH_PARENT, 0, 1f)
        }
        outer.addView(stack)

        setContentView(outer)

        renderSearchRow()
        loadParties()

        // ---- IMPROVEMENT PACK (Payments 10/10): home screen's "Payments" quick
        // action lands here with quickPayment=true — show the Received/Made
        // chooser immediately instead of making the user find "+" -> Payment
        // Received/Made themselves. ----
        if (intent.getBooleanExtra("quickPayment", false)) {
            showPaymentTypeChooser()
        }
    }

    override fun onResume() {
        super.onResume()
        loadParties()
        // Transactions/Items caches are refreshed lazily when their tab is opened
        // (renderActiveTabBody -> render*List with forceReload), so a sale/purchase
        // added elsewhere shows up next time the user visits those tabs.
        if (activeTab == Tab.TRANSACTIONS) renderTransactionsList(forceReload = true)
        if (activeTab == Tab.ITEMS) renderItemsList(forceReload = true)
    }

    // ---- IMPROVEMENT PACK (Payments 10/10): tiny Received/Made chooser shown when
    // this screen is opened via the home screen's "Payments" quick action, then
    // hands off to the existing searchable party picker (PartyQuickAddMenu.kt). ----
    private fun showPaymentTypeChooser() {
        showPremiumMenuSheet(
            headerIconRes = R.drawable.ic_wallet,
            headerTitle = Loc.t(this, "Record Payment", "\u0627\u062F\u0627\u0626\u06CC\u06AF\u06CC \u062F\u0631\u062C \u06A9\u0631\u06CC\u06BA"),
            headerSubtitle = Loc.t(this, "Received or paid out?", "\u0648\u0635\u0648\u0644 \u06C1\u0648\u0626\u06CC \u06CC\u0627 \u0627\u062F\u0627 \u06A9\u06CC \u06AF\u0626\u06CC\u061F"),
            items = listOf(
                QuickMenuItem(R.drawable.ic_wallet, green, "#EAF7EC",
                    Loc.t(this, "Payment Received", "\u0627\u062F\u0627\u0626\u06CC\u06AF\u06CC \u0648\u0635\u0648\u0644 \u06C1\u0648\u0626\u06CC"),
                    Loc.t(this, "From a customer", "\u06A9\u0633\u0679\u0645\u0631 \u0633\u06D2")
                ) { showPartyPickerForPayment(forCustomer = true) },
                QuickMenuItem(R.drawable.ic_bank, gold, "#FBF3E3",
                    Loc.t(this, "Payment Made", "\u0627\u062F\u0627\u0626\u06CC\u06AF\u06CC \u06C1\u0648\u0626\u06CC"),
                    Loc.t(this, "To a supplier", "\u0633\u067E\u0644\u0627\u0626\u0631 \u06A9\u0648")
                ) { showPartyPickerForPayment(forCustomer = false) }
            )
        )
    }

    // ================= HEADER (flat, Reports-style — no gradient) =================
    private fun buildHeader(): LinearLayout {
        return LinearLayout(this).apply {
            orientation = LinearLayout.HORIZONTAL
            gravity = Gravity.CENTER_VERTICAL
            setPadding(28, 46, 24, 32)
            background = GradientDrawable(
                GradientDrawable.Orientation.TL_BR,
                intArrayOf(Color.parseColor(navy), Color.parseColor(navy))
            )

            addView(ImageView(this@PartyDashboardActivity).apply {
                setImageDrawable(tintedDrawable(R.drawable.ic_menu, "#FFFFFF", 20))
                setPadding(4, 0, 20, 0)
                setOnClickListener { showMainMenu() }
            })

            addView(TextView(this@PartyDashboardActivity).apply {
                text = Loc.t(this@PartyDashboardActivity, "Dashboard", "\u0688\u06CC\u0634 \u0628\u0648\u0631\u0688")
                textSize = 19f
                setTextColor(Color.WHITE)
                setTypeface(typeface, android.graphics.Typeface.BOLD)
                layoutParams = LinearLayout.LayoutParams(0, LinearLayout.LayoutParams.WRAP_CONTENT, 1f)
            })

            addView(ImageView(this@PartyDashboardActivity).apply {
                setImageDrawable(tintedDrawable(R.drawable.ic_notifications, "#FFFFFF", 20))
                setPadding(0, 0, 24, 0)
                setOnClickListener {
                    Toast.makeText(this@PartyDashboardActivity, Loc.t(this@PartyDashboardActivity, "No new notifications", "\u06A9\u0648\u0626\u06CC \u0646\u0626\u06CC \u0627\u0637\u0644\u0627\u0639 \u0646\u06C1\u06CC\u06BA"), Toast.LENGTH_SHORT).show()
                }
            })

            addView(ImageView(this@PartyDashboardActivity).apply {
                setImageDrawable(tintedDrawable(R.drawable.ic_send, "#FF5252", 20))
                setOnClickListener { shareSummary() }
            })
        }
    }

    // ================= MAIN MENU =================
    // CHANGE (luxury premium UI pass): replaced the plain AlertDialog.setItems() text
    // list with the same icon-badge nav-row card style used across Reports/History/
    // Stock screens — colored circular icon, bold title + gray subtitle, chevron.
    private fun showMainMenu() {
        showPremiumMenuSheet(
            headerIconRes = R.drawable.ic_menu,
            headerTitle = Loc.t(this, "Menu", "\u0645\u06CC\u0646\u0648"),
            headerSubtitle = Loc.t(this, "Jump to any section", "\u06A9\u0633\u06CC \u0628\u06BE\u06CC \u0633\u06CC\u06A9\u0634\u0646 \u067E\u0631 \u062C\u0627\u0626\u06CC\u06BA"),
            items = listOf(
                QuickMenuItem(R.drawable.ic_box, blue, "#EAF0FF",
                    Loc.t(this, "Products", "\u067E\u0631\u0648\u0688\u06A9\u0679\u0633"),
                    Loc.t(this, "Manage your inventory items", "اپنے انوینٹری آئٹمز کا انتظام کریں")
                ) { startActivity(Intent(this, ProductActivity::class.java)) },
                QuickMenuItem(R.drawable.ic_trending, purple, "#F1EEFF",
                    Loc.t(this, "Reports", "\u0631\u067E\u0648\u0631\u0679\u0633"),
                    Loc.t(this, "Sales, stock & financial overview", "سیل، اسٹاک اور مالیاتی جائزہ")
                ) { startActivity(Intent(this, ReportsActivity::class.java)) },
                QuickMenuItem(R.drawable.ic_wallet, green, "#EAF7EC",
                    Loc.t(this, "Cash In/Out", "\u06A9\u06CC\u0634 \u0627\u0646/\u0622\u0624\u0679"),
                    Loc.t(this, "Record cash movements", "کیش کی آمد و رفت درج کریں")
                ) { startActivity(Intent(this, CashActivity::class.java)) },
                QuickMenuItem(R.drawable.ic_search, teal, "#E6F7F5",
                    Loc.t(this, "Item Rate Search", "\u0622\u0626\u0679\u0645 \u0631\u06CC\u0679 \u0633\u0631\u0686"),
                    Loc.t(this, "Look up any item's price", "کسی بھی آئٹم کی قیمت دیکھیں")
                ) { startActivity(Intent(this, ItemSearchActivity::class.java)) },
                QuickMenuItem(R.drawable.ic_settings, orange, "#FFF3E7",
                    Loc.t(this, "Settings", "\u0633\u06CC\u0679\u0646\u06AF\u0632"),
                    Loc.t(this, "App preferences & account", "ایپ کی ترتیبات اور اکاؤنٹ")
                ) { startActivity(Intent(this, SettingsActivity::class.java)) },
                QuickMenuItem(R.drawable.ic_logout, red, "#FDEDED",
                    Loc.t(this, "Logout", "\u0644\u0627\u06AF \u0622\u0624\u0679"),
                    Loc.t(this, "Sign out of this session", "اس سیشن سے سائن آؤٹ کریں")
                ) { doLogout() }
            )
        )
    }

    private fun doLogout() {
        getSharedPreferences("session", MODE_PRIVATE).edit().clear().apply()
        val intent = Intent(this, LoginActivity::class.java).apply {
            flags = Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_CLEAR_TASK
        }
        startActivity(intent)
        finish()
    }

    private fun shareSummary() {
        val text = Loc.t(
            this,
            "You'll Get: Rs %.2f\nYou'll Give: Rs %.2f".format(
                parseAmount(youllGetValue.text), parseAmount(youllGiveValue.text)
            ),
            "\u0622\u067E \u06A9\u0648 \u0645\u0644\u06CC\u06BA \u06AF\u06D2: \u0631\u0648\u067E\u06D2 %.2f\n\u0622\u067E \u06A9\u0648 \u062F\u06CC\u0646\u06D2 \u06C1\u06CC\u06BA: \u0631\u0648\u067E\u06D2 %.2f".format(
                parseAmount(youllGetValue.text), parseAmount(youllGiveValue.text)
            )
        )
        startActivity(Intent.createChooser(Intent(Intent.ACTION_SEND).apply {
            type = "text/plain"
            putExtra(Intent.EXTRA_TEXT, text)
        }, Loc.t(this, "Share summary", "\u062E\u0644\u0627\u0635\u06C1 \u0634\u06CC\u0626\u0631 \u06A9\u0631\u06CC\u06BA")))
    }

    private fun parseAmount(t: CharSequence): Double =
        t.toString().replace(Regex("[^0-9.]"), "").toDoubleOrNull() ?: 0.0

    // ================= SUMMARY CARDS =================
    // ---- ADDED (Payable/Receivable split): kept as class fields so tapping one card
    // can restyle both (active card gets a tinted background + border; the other
    // reverts to plain) without having to rebuild the whole row. ----
    private lateinit var getCardView: LinearLayout
    private lateinit var giveCardView: LinearLayout

    private fun buildSummaryCards(): LinearLayout {
        val row = LinearLayout(this).apply { orientation = LinearLayout.HORIZONTAL }

        val getCard = summaryCard("\u2193", Loc.t(this, "You'll Get", "\u0622\u067E \u06A9\u0648 \u0645\u0644\u06CC\u06BA \u06AF\u06D2"), green) {
            // ---- Tap "You'll Get" -> jump to Parties tab filtered to receivables
            // only (everyone who currently owes the shop money), regardless of
            // whether they're filed as a customer or a supplier. ----
            filterMode = if (filterMode == FilterMode.RECEIVABLE) FilterMode.ALL else FilterMode.RECEIVABLE
            activeTab = Tab.PARTIES
            renderTabs(); renderSearchRow(); renderActiveTabBody()
            updateSummaryCardStyles()
        }
        val giveCard = summaryCard("\u2191", Loc.t(this, "You'll Give", "\u0622\u067E \u06A9\u0648 \u062F\u06CC\u0646\u06D2 \u06C1\u06CC\u06BA"), red) {
            // ---- Tap "You'll Give" -> jump to Parties tab filtered to payables only
            // (everyone the shop currently owes money to). ----
            filterMode = if (filterMode == FilterMode.PAYABLE) FilterMode.ALL else FilterMode.PAYABLE
            activeTab = Tab.PARTIES
            renderTabs(); renderSearchRow(); renderActiveTabBody()
            updateSummaryCardStyles()
        }
        youllGetValue = getCard.second
        youllGiveValue = giveCard.second
        getCardView = getCard.first
        giveCardView = giveCard.first

        getCard.first.layoutParams = LinearLayout.LayoutParams(0, LinearLayout.LayoutParams.WRAP_CONTENT, 1f).apply { setMargins(0, 0, 8, 0) }
        giveCard.first.layoutParams = LinearLayout.LayoutParams(0, LinearLayout.LayoutParams.WRAP_CONTENT, 1f).apply { setMargins(8, 0, 0, 0) }

        row.addView(getCard.first)
        row.addView(giveCard.first)
        return row
    }

    /** Highlights whichever summary card matches the active filter (tinted
     * background + colored border) so it's obvious the list below is filtered,
     * and reverts both to the plain card style when filterMode is ALL/CUSTOMERS/
     * SUPPLIERS (i.e. not driven by a summary-card tap). */
    private fun updateSummaryCardStyles() {
        if (!::getCardView.isInitialized) return
        getCardView.background = if (filterMode == FilterMode.RECEIVABLE) tintedCardBg(green) else elevatedCardBg()
        giveCardView.background = if (filterMode == FilterMode.PAYABLE) tintedCardBg(red) else elevatedCardBg()
    }

    private fun tintedCardBg(accentHex: String) = GradientDrawable().apply {
        setColor(Color.parseColor(lightenForTint(accentHex)))
        cornerRadius = 18f
        setStroke((1.5f * resources.displayMetrics.density).toInt(), Color.parseColor(accentHex))
    }

    private fun lightenForTint(colorHex: String): String {
        val c = Color.parseColor(colorHex)
        val hsv = FloatArray(3)
        Color.colorToHSV(c, hsv)
        hsv[1] *= 0.15f
        hsv[2] = 1f
        return String.format("#%06X", 0xFFFFFF and Color.HSVToColor(hsv))
    }

    // ---- CHANGE (modern minimal UI pass): airier padding (18->22 vertical), the
    // arrow glyph now sits in a small tinted circular dot instead of loose bold text
    // (a common "minimal fintech card" motif), and a slightly lower elevation (3f -> 2f)
    // since the border removal already does most of the work of making the card read
    // as a distinct surface — a lighter shadow keeps the whole screen feeling calm
    // rather than "boxy".
    private fun summaryCard(arrow: String, label: String, accentHex: String, onTap: (() -> Unit)? = null): Pair<LinearLayout, TextView> {
        val card = LinearLayout(this).apply {
            orientation = LinearLayout.VERTICAL
            setPadding(22, 20, 22, 20)
            background = elevatedCardBg()
            elevation = 2f
            if (onTap != null) {
                isClickable = true
                isFocusable = true
                setOnClickListener { onTap() }
            }
        }
        val topRow = LinearLayout(this).apply { orientation = LinearLayout.HORIZONTAL; gravity = Gravity.CENTER_VERTICAL }
        topRow.addView(TextView(this).apply {
            text = arrow
            setTextColor(Color.WHITE)
            textSize = 12f
            gravity = Gravity.CENTER
            setTypeface(typeface, android.graphics.Typeface.BOLD)
            background = pillBg(accentHex, radius = 20f)
            width = (26 * resources.displayMetrics.density).toInt()
            height = (26 * resources.displayMetrics.density).toInt()
        })
        topRow.addView(TextView(this).apply {
            text = "  $label"
            setTextColor(Color.parseColor(labelGray))
            textSize = 12.5f
        })
        card.addView(topRow)
        val value = TextView(this).apply {
            text = "Rs 0"
            textSize = 20f
            setTypeface(typeface, android.graphics.Typeface.BOLD)
            setTextColor(Color.parseColor("#2E3242"))
            setPadding(0, 10, 0, 0)
        }
        card.addView(value)
        return Pair(card, value)
    }

    // ================= TABS =================
    // ---- Reference-screenshot tab style: each tab is its own bordered white pill
    // (not a single gray segmented track). Active tab gets a red border + bold red
    // text; inactive tabs get a light-gray border + gray text. Matches Parties/
    // Transactions/Items exactly as shown in the reference UI. ----
    private fun buildTabs(): LinearLayout {
        tabRow = LinearLayout(this).apply {
            orientation = LinearLayout.HORIZONTAL
        }
        renderTabs()
        return tabRow
    }

    private fun renderTabs() {
        tabRow.removeAllViews()
        val entries = listOf(
            Triple(Tab.PARTIES, Loc.t(this, "Parties", "\u067E\u0627\u0631\u0679\u06CC\u0632"), true),
            Triple(Tab.TRANSACTIONS, Loc.t(this, "Transactions", "\u0644\u06CC\u0646 \u062F\u06CC\u0646"), true),
            Triple(Tab.ITEMS, Loc.t(this, "Items", "\u0622\u0626\u0679\u0645\u0632"), true)
        )
        entries.forEachIndexed { idx, (tab, label, _) ->
            val isActive = tab == activeTab
            tabRow.addView(TextView(this).apply {
                text = label
                textSize = 13f
                gravity = Gravity.CENTER
                setPadding(0, 16, 0, 16)
                setTypeface(typeface, if (isActive) android.graphics.Typeface.BOLD else android.graphics.Typeface.NORMAL)
                setTextColor(Color.parseColor(if (isActive) red else labelGray))
                background = strokedBg(if (isActive) red else cardBorder, cardWhite, 20)
                layoutParams = LinearLayout.LayoutParams(0, LinearLayout.LayoutParams.WRAP_CONTENT, 1f).apply {
                    if (idx > 0) marginStart = (8 * resources.displayMetrics.density).toInt()
                }
                setOnClickListener {
                    activeTab = tab
                    renderTabs()
                    renderSearchRow()
                    renderActiveTabBody()
                }
            })
        }
    }

    // ================= SEARCH / ADD ROW (rebuilt per tab) =================
    private fun renderSearchRow() {
        searchRowContainer.removeAllViews()
        when (activeTab) {
            Tab.PARTIES -> searchRowContainer.addView(buildPartySearchRow())
            Tab.TRANSACTIONS -> searchRowContainer.addView(buildSearchOnlyRow(
                hint = Loc.t(this, "Search transaction (party or item name)", "\u067E\u0627\u0631\u0679\u06CC \u06CC\u0627 \u0622\u0626\u0679\u0645 \u06A9\u0627 \u0646\u0627\u0645 \u0633\u06D2 \u062A\u0644\u0627\u0634 \u06A9\u0631\u06CC\u06BA"),
                onQueryChanged = { txQuery = it; renderTxRows() }
            ))
            Tab.ITEMS -> searchRowContainer.addView(buildItemSearchRow())
        }
    }

    /** Search box + filter icon + "New Party" button — Parties tab only. */
    private fun buildPartySearchRow(): LinearLayout {
        val row = LinearLayout(this).apply { orientation = LinearLayout.HORIZONTAL; gravity = Gravity.CENTER_VERTICAL }

        // ---- CHANGE (modern minimal UI pass): filled, borderless field (light-gray
        // fill instead of white+stroke) — see buildSearchOnlyRow() below for the
        // shared rationale.
        val searchBox = LinearLayout(this).apply {
            orientation = LinearLayout.HORIZONTAL
            gravity = Gravity.CENTER_VERTICAL
            setPadding(18, 10, 18, 10)
            background = pillBg("#F0F1F5", radius = 18f)
            layoutParams = LinearLayout.LayoutParams(0, LinearLayout.LayoutParams.WRAP_CONTENT, 1f)
        }
        searchBox.addView(ImageView(this).apply { setImageDrawable(tintedDrawable(R.drawable.ic_search, labelGray, 15)); setPadding(0, 0, 10, 0) })
        searchBox.addView(EditText(this).apply {
            hint = Loc.t(this@PartyDashboardActivity, "Search party", "\u067E\u0627\u0631\u0679\u06CC \u062A\u0644\u0627\u0634 \u06A9\u0631\u06CC\u06BA")
            background = null
            textSize = 13.5f
            setHintTextColor(Color.parseColor(labelGray))
            addTextChangedListener(object : TextWatcher {
                override fun beforeTextChanged(s: CharSequence?, a: Int, b: Int, c: Int) {}
                override fun onTextChanged(s: CharSequence?, a: Int, b: Int, c: Int) { renderPartyList(s?.toString().orEmpty()) }
                override fun afterTextChanged(s: Editable?) {}
            })
        })
        row.addView(searchBox)
        row.addView(spacerHoriz(10))

        row.addView(ImageView(this).apply {
            setImageDrawable(tintedDrawable(R.drawable.ic_filter, labelGray, 17))
            scaleType = ImageView.ScaleType.CENTER
            // CHANGE: borderless filled circle instead of white+stroke oval.
            background = pillBg("#F0F1F5", radius = 20f)
            layoutParams = LinearLayout.LayoutParams((40 * resources.displayMetrics.density).toInt(), (40 * resources.displayMetrics.density).toInt())
            setOnClickListener { showFilterDialog() }
        })
        row.addView(spacerHoriz(10))

        row.addView(TextView(this).apply {
            text = "+ " + Loc.t(this@PartyDashboardActivity, "New Party", "\u0646\u0626\u06CC \u067E\u0627\u0631\u0679\u06CC")
            textSize = 13f
            setTextColor(Color.WHITE)
            setTypeface(typeface, android.graphics.Typeface.BOLD)
            setPadding(20, 14, 20, 14)
            // CHANGE: solid accent fill instead of a pale tint — a single confident
            // accent-colored action button reads more "modern app" than a light-tint
            // button, and matches the bottom Add Purchase/Add Sale buttons' treatment.
            background = pillBg(blue, radius = 20f)
            setOnClickListener { startActivity(Intent(this@PartyDashboardActivity, PartyActivity::class.java)) }
        })

        return row
    }

    /** Search box only — used for the Transactions tab (no add button, no filter). */
    // ---- CHANGE (modern minimal UI pass): filled light-gray pill instead of a white
    // card with a visible border. A flat filled search field (no stroke) is the more
    // contemporary pattern — the border was doing the same "separate this from the
    // background" job the fill now does on its own, just with a harder edge.
    private fun buildSearchOnlyRow(hint: String, onQueryChanged: (String) -> Unit): LinearLayout {
        val row = LinearLayout(this).apply { orientation = LinearLayout.HORIZONTAL; gravity = Gravity.CENTER_VERTICAL }
        val searchBox = LinearLayout(this).apply {
            orientation = LinearLayout.HORIZONTAL
            gravity = Gravity.CENTER_VERTICAL
            setPadding(18, 10, 18, 10)
            background = pillBg("#F0F1F5", radius = 18f)
            layoutParams = LinearLayout.LayoutParams(LinearLayout.LayoutParams.MATCH_PARENT, LinearLayout.LayoutParams.WRAP_CONTENT)
        }
        searchBox.addView(ImageView(this).apply { setImageDrawable(tintedDrawable(R.drawable.ic_search, labelGray, 15)); setPadding(0, 0, 10, 0) })
        searchBox.addView(EditText(this).apply {
            this.hint = hint
            background = null
            textSize = 13.5f
            setHintTextColor(Color.parseColor(labelGray))
            layoutParams = LinearLayout.LayoutParams(0, LinearLayout.LayoutParams.WRAP_CONTENT, 1f)
            addTextChangedListener(object : TextWatcher {
                override fun beforeTextChanged(s: CharSequence?, a: Int, b: Int, c: Int) {}
                override fun onTextChanged(s: CharSequence?, a: Int, b: Int, c: Int) { onQueryChanged(s?.toString().orEmpty()) }
                override fun afterTextChanged(s: Editable?) {}
            })
        })
        row.addView(searchBox)
        return row
    }

    /** Search box + "Add Item" button — Items tab only. */
    private fun buildItemSearchRow(): LinearLayout {
        val row = LinearLayout(this).apply { orientation = LinearLayout.HORIZONTAL; gravity = Gravity.CENTER_VERTICAL }

        // ---- CHANGE (modern minimal UI pass): same filled borderless field + solid
        // accent button treatment as the Parties/Transactions search rows above.
        val searchBox = LinearLayout(this).apply {
            orientation = LinearLayout.HORIZONTAL
            gravity = Gravity.CENTER_VERTICAL
            setPadding(18, 10, 18, 10)
            background = pillBg("#F0F1F5", radius = 18f)
            layoutParams = LinearLayout.LayoutParams(0, LinearLayout.LayoutParams.WRAP_CONTENT, 1f)
        }
        searchBox.addView(ImageView(this).apply { setImageDrawable(tintedDrawable(R.drawable.ic_search, labelGray, 15)); setPadding(0, 0, 10, 0) })
        searchBox.addView(EditText(this).apply {
            hint = Loc.t(this@PartyDashboardActivity, "Search item", "\u0622\u0626\u0679\u0645 \u062A\u0644\u0627\u0634 \u06A9\u0631\u06CC\u06BA")
            background = null
            textSize = 13.5f
            setHintTextColor(Color.parseColor(labelGray))
            addTextChangedListener(object : TextWatcher {
                override fun beforeTextChanged(s: CharSequence?, a: Int, b: Int, c: Int) {}
                override fun onTextChanged(s: CharSequence?, a: Int, b: Int, c: Int) { itemQuery = s?.toString().orEmpty(); renderItemRows() }
                override fun afterTextChanged(s: Editable?) {}
            })
        })
        row.addView(searchBox)
        row.addView(spacerHoriz(10))

        row.addView(TextView(this).apply {
            text = "+ " + Loc.t(this@PartyDashboardActivity, "Add Item", "\u0622\u0626\u0679\u0645 \u0634\u0627\u0645\u0644 \u06A9\u0631\u06CC\u06BA")
            textSize = 13f
            setTextColor(Color.WHITE)
            setTypeface(typeface, android.graphics.Typeface.BOLD)
            setPadding(20, 14, 20, 14)
            background = pillBg(blue, radius = 20f)
            setOnClickListener { startActivity(Intent(this@PartyDashboardActivity, ProductActivity::class.java)) }
        })

        return row
    }

    private fun spacerHoriz(widthDp: Int) = View(this).apply {
        layoutParams = LinearLayout.LayoutParams((widthDp * resources.displayMetrics.density).toInt(), 1)
    }

    private fun showFilterDialog() {
        // ---- ADDED (Payable/Receivable split): the same two cuts available from
        // tapping the summary cards are also reachable from the filter icon, so
        // there's always one place to both apply AND clear any party-list filter. ----
        val options = arrayOf(
            Loc.t(this, "All Parties", "\u062A\u0645\u0627\u0645 \u067E\u0627\u0631\u0679\u06CC\u0632"),
            Loc.t(this, "Customers Only", "\u0635\u0631\u0641 \u06A9\u0633\u0679\u0645\u0631\u0632"),
            Loc.t(this, "Suppliers Only", "\u0635\u0631\u0641 \u0633\u067E\u0644\u0627\u0626\u0631\u0632"),
            Loc.t(this, "Receivable Only (You'll Get)", "\u0635\u0631\u0641 \u0648\u0635\u0648\u0644\u06CC \u0628\u0627\u0642\u06CC (\u0622\u067E \u06A9\u0648 \u0645\u0644\u06CC\u06BA \u06AF\u06D2)"),
            Loc.t(this, "Payable Only (You'll Give)", "\u0635\u0631\u0641 \u0627\u062F\u0627\u0626\u06CC\u06AF\u06CC \u0628\u0627\u0642\u06CC (\u0622\u067E \u06A9\u0648 \u062F\u06CC\u0646\u06D2 \u06C1\u06CC\u06BA)")
        )
        val current = when (filterMode) {
            FilterMode.ALL -> 0; FilterMode.CUSTOMERS -> 1; FilterMode.SUPPLIERS -> 2
            FilterMode.RECEIVABLE -> 3; FilterMode.PAYABLE -> 4
        }
        AlertDialog.Builder(this)
            .setTitle(Loc.t(this, "Filter", "\u0641\u0644\u0679\u0631"))
            .setSingleChoiceItems(options, current) { d, which ->
                filterMode = when (which) {
                    1 -> FilterMode.CUSTOMERS; 2 -> FilterMode.SUPPLIERS
                    3 -> FilterMode.RECEIVABLE; 4 -> FilterMode.PAYABLE
                    else -> FilterMode.ALL
                }
                renderPartyList()
                updateSummaryCardStyles()
                d.dismiss()
            }
            .show()
    }

    // ================= BOTTOM ACTION BAR =================
    private fun buildBottomBar(): LinearLayout {
        val bar = LinearLayout(this).apply {
            orientation = LinearLayout.HORIZONTAL
            gravity = Gravity.CENTER_VERTICAL
            setPadding(24, 16, 24, 16)
            background = GradientDrawable().apply {
                setColor(Color.parseColor(cardWhite))
                cornerRadii = floatArrayOf(28f, 28f, 28f, 28f, 0f, 0f, 0f, 0f)
            }
            elevation = 10f
            layoutParams = FrameLayout.LayoutParams(
                FrameLayout.LayoutParams.MATCH_PARENT, FrameLayout.LayoutParams.WRAP_CONTENT, Gravity.BOTTOM
            )
        }

        ViewCompat.setOnApplyWindowInsetsListener(bar) { view, insets ->
            val navBarInset = insets.getInsets(WindowInsetsCompat.Type.systemBars()).bottom
            view.setPadding(view.paddingLeft, 16, view.paddingRight, 16 + navBarInset)
            insets
        }

        bar.addView(TextView(this).apply {
            text = Loc.t(this@PartyDashboardActivity, "Add Purchase", "\u062E\u0631\u06CC\u062F\u0627\u0631\u06CC \u0634\u0627\u0645\u0644 \u06A9\u0631\u06CC\u06BA")
            setTextColor(Color.WHITE)
            textSize = 13.5f
            setTypeface(typeface, android.graphics.Typeface.BOLD)
            gravity = Gravity.CENTER
            setPadding(0, 22, 0, 22)
            background = roundedBackground(blue, 26)
            layoutParams = LinearLayout.LayoutParams(0, LinearLayout.LayoutParams.WRAP_CONTENT, 1f).apply { setMargins(0, 0, 10, 0) }
            setOnClickListener { startActivity(Intent(this@PartyDashboardActivity, PurchaseActivity::class.java)) }
        })

        bar.addView(ImageView(this).apply {
            setImageDrawable(tintedDrawable(R.drawable.ic_add, "#FFFFFF", 22))
            scaleType = ImageView.ScaleType.CENTER
            background = ovalBg(blue)
            layoutParams = LinearLayout.LayoutParams((52 * resources.displayMetrics.density).toInt(), (52 * resources.displayMetrics.density).toInt())
            setOnClickListener { showQuickAddDialog() }
        })

        bar.addView(TextView(this).apply {
            text = Loc.t(this@PartyDashboardActivity, "Add Sale", "\u0633\u06CC\u0644 \u0634\u0627\u0645\u0644 \u06A9\u0631\u06CC\u06BA")
            setTextColor(Color.WHITE)
            textSize = 13.5f
            setTypeface(typeface, android.graphics.Typeface.BOLD)
            gravity = Gravity.CENTER
            setPadding(0, 22, 0, 22)
            background = roundedBackground(red, 26)
            layoutParams = LinearLayout.LayoutParams(0, LinearLayout.LayoutParams.WRAP_CONTENT, 1f).apply { setMargins(10, 0, 0, 0) }
            setOnClickListener { startActivity(Intent(this@PartyDashboardActivity, SaleActivity::class.java)) }
        })

        return bar
    }

    // CHANGE (luxury premium UI pass): replaced the plain AlertDialog.setItems() text
    // list with the same icon-badge nav-row card style used across Reports/History/
    // Stock screens — colored circular icon, bold title + gray subtitle, chevron.
    // ================= DATA LOAD (Parties tab / summary cards) =================
    private fun loadParties() {
        lifecycleScope.launch {
            val db = PosDatabase.get(this@PartyDashboardActivity)
            combine(db.customerDao().all(), db.supplierDao().all()) { customers, suppliers ->
                Pair(customers, suppliers)
            }.collectLatest { (customers, suppliers) ->
                // ---- IMPROVEMENT PACK (Payments 10/10 — link due reminders to Payments):
                // one dueSales() call, reduced to the single most urgent (overdue, else
                // due-today) reminder per customer, so the Parties tab can badge exactly
                // who to chase for a payment without opening Due Date Reminders first. ----
                val cal = java.util.Calendar.getInstance().apply {
                    set(java.util.Calendar.HOUR_OF_DAY, 0); set(java.util.Calendar.MINUTE, 0)
                    set(java.util.Calendar.SECOND, 0); set(java.util.Calendar.MILLISECOND, 0)
                }
                val today = cal.timeInMillis
                val tomorrow = today + 24 * 60 * 60 * 1000L
                val dueByCustomer = db.saleDao().dueSales()
                    .filter { it.dueDate in 1 until tomorrow && it.customerId != null }
                    .groupBy { it.customerId!! }
                    .mapValues { (_, sales) -> if (sales.any { it.dueDate < today }) DueStatus.OVERDUE else DueStatus.DUE_TODAY }

                // ---- ADDED (Khatabook-style party list — screenshot reference):
                // most recent activity date per party, merged across sales/purchases
                // and standalone payments so a party whose last touch was a payment
                // (not a new sale/purchase) still shows the correct date. Kept as two
                // separate maps (customer vs supplier) since the two tables have
                // independent id spaces — a customerId and supplierId can collide. ----
                val customerLastAt = mutableMapOf<Long, Long>()
                db.saleDao().lastActivityByCustomer().forEach { customerLastAt[it.partyId] = maxOf(customerLastAt[it.partyId] ?: 0L, it.lastAt) }
                db.paymentDao().lastActivityByPartyType("customer").forEach { customerLastAt[it.partyId] = maxOf(customerLastAt[it.partyId] ?: 0L, it.lastAt) }

                val supplierLastAt = mutableMapOf<Long, Long>()
                db.purchaseDao().lastActivityBySupplier().forEach { supplierLastAt[it.partyId] = maxOf(supplierLastAt[it.partyId] ?: 0L, it.lastAt) }
                db.paymentDao().lastActivityByPartyType("supplier").forEach { supplierLastAt[it.partyId] = maxOf(supplierLastAt[it.partyId] ?: 0L, it.lastAt) }

                // PERMANENT FIX (balance drift — "paid supplier still shows You'll Get"):
                // closing is computed from PartyRepository's live ledger balance (fresh
                // from actual bills + standalone payments), not the stored, driftable
                // customer.balance/supplier.balance field `.totalPayable()`/`s.balance`
                // used to read. See PartyRepository.liveCustomerBalances() comment.
                val partyRepo = PartyRepository(db, applicationContext)
                val liveCustomerBal = partyRepo.liveCustomerBalances()
                val liveSupplierBal = partyRepo.liveSupplierBalances()

                val items = mutableListOf<PartyItem>()
                for (c in customers) {
                    val closing = c.openingBalance + (liveCustomerBal[c.id] ?: 0.0) + c.stuckBalance
                    items.add(PartyItem(id = c.id, name = c.name, phone = c.phone, closing = closing, isCustomer = true, dueStatus = dueByCustomer[c.id], lastActivityAt = customerLastAt[c.id], stuck = c.stuckBalance))
                }
                for (s in suppliers) {
                    val closing = s.openingBalance + (liveSupplierBal[s.id] ?: 0.0)
                    items.add(PartyItem(id = s.id, name = s.name, phone = s.phone, closing = closing, isCustomer = false, lastActivityAt = supplierLastAt[s.id]))
                }
                // CHANGE (Khatabook-style party list — screenshot reference): sort by
                // most recent activity first (matches the reference screenshot's order
                // — newest transaction date at top), falling back to name for parties
                // with no transactions yet so they still appear in a stable order.
                allItems = items.sortedWith(
                    compareByDescending<PartyItem> { it.lastActivityAt ?: -1L }
                        .thenBy { it.name.lowercase() }
                )
                updateSummaryTotals()
                if (activeTab == Tab.PARTIES) renderPartyList()
            }
        }
    }

    /**
     * ---- FIX ----
     * Customer and supplier closing balances mean opposite things and must NOT share the
     * same sign rule:
     *   - Customer closing > 0  => customer owes the shop (receivable)  -> You'll Get
     *   - Customer closing < 0  => shop owes the customer                -> You'll Give
     *   - Supplier closing > 0  => shop owes the supplier (payable)      -> You'll Give
     *   - Supplier closing < 0  => supplier owes the shop (e.g. credit)  -> You'll Get
     */
    private fun updateSummaryTotals() {
        val youllGet = allItems.sumOf {
            if (it.isCustomer) maxOf(it.closing, 0.0) else maxOf(-it.closing, 0.0)
        }
        val youllGive = allItems.sumOf {
            if (it.isCustomer) maxOf(-it.closing, 0.0) else maxOf(it.closing, 0.0)
        }
        youllGetValue.text = "Rs %.2f".format(youllGet)
        youllGiveValue.text = "Rs %.2f".format(youllGive)
    }

    private fun renderActiveTabBody() {
        listContainer.removeAllViews()
        when (activeTab) {
            Tab.PARTIES -> renderPartyList()
            Tab.TRANSACTIONS -> renderTransactionsList(forceReload = true)
            Tab.ITEMS -> renderItemsList(forceReload = true)
        }
    }

    // ================= PARTIES TAB =================
    private fun renderPartyList(query: String = "") {
        if (activeTab != Tab.PARTIES) return
        listContainer.removeAllViews()

        val q = query.trim().lowercase()
        val filtered = allItems
            .filter { item ->
                when (filterMode) {
                    FilterMode.ALL -> true
                    FilterMode.CUSTOMERS -> item.isCustomer
                    FilterMode.SUPPLIERS -> !item.isCustomer
                    // ---- ADDED (Payable/Receivable split): same give/get sign rule as
                    // updateSummaryTotals()/dashboardPartyRow() above, applied per-party
                    // instead of summed, and a settled (Rs 0) party never counts as
                    // either. RECEIVABLE = "You'll Get" list, PAYABLE = "You'll Give" list.
                    FilterMode.RECEIVABLE -> kotlin.math.abs(item.closing) >= 0.005 &&
                        (if (item.isCustomer) item.closing > 0 else item.closing < 0)
                    FilterMode.PAYABLE -> kotlin.math.abs(item.closing) >= 0.005 &&
                        (if (item.isCustomer) item.closing < 0 else item.closing > 0)
                }
            }
            .filter { it.name.lowercase().contains(q) }

        if (filtered.isEmpty()) {
            val emptyMsg = when (filterMode) {
                FilterMode.RECEIVABLE -> Loc.t(this, "No one owes you right now", "ابھی کوئی آپ کا مقروض نہیں")
                FilterMode.PAYABLE -> Loc.t(this, "You don't owe anyone right now", "ابھی آپ کسی کے مقروض نہیں")
                else -> Loc.t(this, "No parties found", "\u06A9\u0648\u0626\u06CC \u067E\u0627\u0631\u0679\u06CC \u0646\u06C1\u06CC\u06BA \u0645\u0644\u06CC")
            }
            listContainer.addView(placeholderCard(emptyMsg))
            return
        }

        for (item in filtered) {
            listContainer.addView(dashboardPartyRow(item))
        }
    }

    private fun dashboardPartyRow(item: PartyItem): LinearLayout {
        // ---- FIX: type-aware give/get, see updateSummaryTotals() comment above ----
        // ---- CHANGE (Khatabook-style party list — screenshot reference): a settled
        // party (closing == 0, e.g. "Cash purchase", "Rozgar technologies" in the
        // screenshot) shows a plain black "Rs 0" with no You'll Get/Give caption,
        // instead of being colored green/red like an actual balance. ----
        val isZero = kotlin.math.abs(item.closing) < 0.005
        val give = if (item.isCustomer) item.closing < 0 else item.closing > 0
        val amountColor = if (isZero) textDark else if (give) red else green
        val label = if (isZero) "" else if (give) Loc.t(this, "You'll Give", "\u0622\u067E \u06A9\u0648 \u062F\u06CC\u0646\u06D2 \u06C1\u06CC\u06BA") else Loc.t(this, "You'll Get", "\u0622\u067E \u06A9\u0648 \u0645\u0644\u06CC\u06BA \u06AF\u06D2")

        // ---- CHANGE (modern minimal UI pass): a touch more breathing room per row
        // (padding 16->18, gap between cards 10->12) now that the border is gone —
        // borderless cards need slightly more space between them so the eye can still
        // tell where one ends and the next begins, using whitespace instead of a line.
        return LinearLayout(this).apply {
            orientation = LinearLayout.HORIZONTAL
            gravity = Gravity.CENTER_VERTICAL
            setPadding(20, 18, 20, 18)
            background = elevatedCardBg()
            elevation = 1.5f
            layoutParams = LinearLayout.LayoutParams(
                LinearLayout.LayoutParams.MATCH_PARENT, LinearLayout.LayoutParams.WRAP_CONTENT
            ).apply { setMargins(0, 0, 0, 12) }
            isClickable = true
            // ---- CHANGE: opens PartyTransactionActivity filtered to this party,
            // instead of the generic PartyActivity. ----
            setOnClickListener {
                startActivity(Intent(this@PartyDashboardActivity, PartyTransactionActivity::class.java).apply {
                    putExtra("partyId", item.id)
                    putExtra("partyName", item.name)
                    putExtra("isCustomer", item.isCustomer)
                })
            }

            val infoCol = LinearLayout(this@PartyDashboardActivity).apply {
                orientation = LinearLayout.VERTICAL
                layoutParams = LinearLayout.LayoutParams(0, LinearLayout.LayoutParams.WRAP_CONTENT, 1f)
            }
            infoCol.addView(TextView(this@PartyDashboardActivity).apply {
                text = item.name
                textSize = 15f
                setTextColor(Color.parseColor("#2E3242"))
                setTypeface(typeface, android.graphics.Typeface.BOLD)
            })
            // ---- CHANGE (Khatabook-style party list — screenshot reference): show
            // the party's last transaction date (e.g. "05 Aug 2026") instead of a
            // static "Customer"/"Supplier" label, matching the reference design.
            // Falls back to Customer/Supplier for a brand-new party with no
            // transactions yet (lastActivityAt == null), since there's no date to show.
            infoCol.addView(TextView(this@PartyDashboardActivity).apply {
                text = item.lastActivityAt?.let { partyRowDateFmt.format(Date(it)) }
                    ?: if (item.isCustomer) Loc.t(this@PartyDashboardActivity, "Customer", "\u06A9\u0633\u0679\u0645\u0631") else Loc.t(this@PartyDashboardActivity, "Supplier", "\u0633\u067E\u0644\u0627\u0626\u0631")
                textSize = 11.5f
                setTextColor(Color.parseColor(labelGray))
                setPadding(0, 4, 0, 0)
            })
            // NEW (Stuck Balance): only for a customer who has a stuck amount — the big figure on
            // the right is the TOTAL, this line explains it as Daily + Stuck.
            if (item.stuck != 0.0) {
                infoCol.addView(TextView(this@PartyDashboardActivity).apply {
                    text = Loc.t(this@PartyDashboardActivity, "Daily", "روزانہ") + " Rs %.0f".format(item.closing - item.stuck) +
                        "  •  " + Loc.t(this@PartyDashboardActivity, "Stuck", "اسٹک") + " Rs %.0f".format(item.stuck)
                    textSize = 11f
                    setTextColor(Color.parseColor(labelGray))
                    setPadding(0, 2, 0, 0)
                })
            }
            // ---- IMPROVEMENT PACK (Payments 10/10 — link due reminders to Payments):
            // small badge when this customer has an active reminder due today or
            // overdue, so the person doing collections can see who to call for a
            // payment right from this list, without opening Due Date Reminders. ----
            item.dueStatus?.let { status ->
                val badgeColor = if (status == DueStatus.OVERDUE) red else gold
                val badgeText = if (status == DueStatus.OVERDUE)
                    Loc.t(this@PartyDashboardActivity, "Overdue", "\u0645\u06CC\u0639\u0627\u062F \u06AF\u0632\u0631 \u06AF\u0626\u06CC")
                else
                    Loc.t(this@PartyDashboardActivity, "Due Today", "\u0622\u062C \u0648\u0627\u062C\u0628 \u0627\u0644\u0627\u062F\u0627")
                infoCol.addView(TextView(this@PartyDashboardActivity).apply {
                    text = badgeText
                    textSize = 10.5f
                    setTypeface(typeface, android.graphics.Typeface.BOLD)
                    setTextColor(Color.WHITE)
                    setPadding(16, 6, 16, 6)
                    background = roundedBackground(badgeColor, 20)
                    setLeadingIcon(R.drawable.ic_alarm, "#FFFFFF", 12, 5)
                    layoutParams = LinearLayout.LayoutParams(LinearLayout.LayoutParams.WRAP_CONTENT, LinearLayout.LayoutParams.WRAP_CONTENT).apply { topMargin = 6 }
                })
            }
            addView(infoCol)

            val amountCol = LinearLayout(this@PartyDashboardActivity).apply {
                orientation = LinearLayout.VERTICAL
                gravity = Gravity.END
            }
            amountCol.addView(TextView(this@PartyDashboardActivity).apply {
                // CHANGE: a settled balance shows the plain "Rs 0" the screenshot
                // uses, instead of "Rs 0.00".
                text = if (isZero) "Rs 0" else "Rs %.2f".format(kotlin.math.abs(item.closing))
                textSize = 14.5f
                setTypeface(typeface, android.graphics.Typeface.BOLD)
                setTextColor(Color.parseColor(amountColor))
            })
            // CHANGE: no You'll Get/Give caption under a settled Rs 0 balance.
            if (label.isNotEmpty()) {
                amountCol.addView(TextView(this@PartyDashboardActivity).apply {
                    text = label
                    textSize = 11f
                    setTextColor(Color.parseColor(amountColor))
                    setPadding(0, 2, 0, 0)
                })
            }
            addView(amountCol)
        }
    }

    // ================= TRANSACTIONS TAB =================
    // Merges recent sales + purchases into one date-sorted feed. forceReload=true
    // re-hits the DB (used when the tab is opened); typing in the search box only
    // re-filters the cached list (renderTxRows), no DB hit.
    private fun renderTransactionsList(forceReload: Boolean) {
        if (!forceReload) { renderTxRows(); return }
        listContainer.removeAllViews()
        lifecycleScope.launch {
            val db = PosDatabase.get(this@PartyDashboardActivity)
            val sales = db.saleDao().allSales()
            val purchases = db.purchaseDao().allPurchases()

            val merged = mutableListOf<TxRow>()
            sales.forEach { merged.add(TxRow(it.invoice, it.customerName, it.total, it.createdAt, true, it.status)) }
            purchases.forEach { merged.add(TxRow(it.billNo, it.supplierName, it.total, it.createdAt, false, it.status)) }
            // FIX ("August ki purchases nahi mil rahin"): was capped to the newest 100
            // sales+purchases combined across the whole shop — once more than 100
            // transactions happened after an older bill, that bill silently dropped off
            // this list with no way to reach it (search only filters txCache, it doesn't
            // re-query). No cap now; the search box narrows a long list down.
            txCache = merged.sortedByDescending { it.createdAt }

            // NEW: item names per reference, for the search-by-item-name filter below.
            val itemNames = db.saleDao().allItemNamesForSales() + db.purchaseDao().allItemNamesForPurchases()
            txItemNamesByRef = itemNames.groupBy({ it.reference }, { it.product.lowercase() })

            if (activeTab != Tab.TRANSACTIONS) return@launch
            renderTxRows()
        }
    }

    private fun renderTxRows() {
        if (activeTab != Tab.TRANSACTIONS) return
        listContainer.removeAllViews()
        val q = txQuery.trim().lowercase()
        // FIX (English search alias): match the same convention as
        // Product.matchesQuery() — split into words, require every word to
        // appear somewhere across party name + item names (name+searchTag)
        // combined, so English tag words match alongside the Urdu name.
        val terms = q.split(Regex("\\s+")).filter { it.isNotBlank() }
        val filtered = txCache.filter { row ->
            if (terms.isEmpty()) return@filter true
            val haystack = (row.partyName + " " + txItemNamesByRef[row.reference].orEmpty().joinToString(" ")).lowercase()
            terms.all { haystack.contains(it) }
        }

        if (filtered.isEmpty()) {
            listContainer.addView(placeholderCard(Loc.t(this, "No transactions yet", "\u0627\u0628\u06BE\u06CC \u062A\u06A9 \u06A9\u0648\u0626\u06CC \u0644\u06CC\u0646 \u062F\u06CC\u0646 \u0646\u06C1\u06CC\u06BA \u06C1\u06D2")))
            return
        }

        val fmt = SimpleDateFormat("dd MMM, hh:mm a", Locale.getDefault())
        for (row in filtered) {
            listContainer.addView(transactionRow(row, fmt.format(Date(row.createdAt))))
        }
    }

    private fun transactionRow(row: TxRow, dateText: String): LinearLayout {
        val accent = if (row.isSale) green else orange
        val typeLabel = if (row.isSale) Loc.t(this, "Sale", "\u0633\u06CC\u0644") else Loc.t(this, "Purchase", "\u062E\u0631\u06CC\u062F\u0627\u0631\u06CC")

        return LinearLayout(this).apply {
            orientation = LinearLayout.HORIZONTAL
            gravity = Gravity.CENTER_VERTICAL
            setPadding(20, 18, 20, 18)
            background = elevatedCardBg()
            elevation = 1.5f
            layoutParams = LinearLayout.LayoutParams(
                LinearLayout.LayoutParams.MATCH_PARENT, LinearLayout.LayoutParams.WRAP_CONTENT
            ).apply { setMargins(0, 0, 0, 12) }
            isClickable = true
            // ---- CHANGE: tapping a transaction opens it. ADJUST-EXTRA-KEY if
            // SaleActivity/PurchaseActivity expect a different extra name. ----
            setOnClickListener {
                val intent = if (row.isSale) {
                    Intent(this@PartyDashboardActivity, SaleActivity::class.java).apply {
                        putExtra("invoice", row.reference) // ADJUST-EXTRA-KEY
                    }
                } else {
                    Intent(this@PartyDashboardActivity, PurchaseActivity::class.java).apply {
                        putExtra("billNo", row.reference) // ADJUST-EXTRA-KEY
                    }
                }
                startActivity(intent)
            }

            // ---- CHANGE (sada/plain like Parties tab — user asked to match
            // dashboardPartyRow's plain-text look): dropped the leading
            // ic_cart/ic_receipt icon badge that used to sit here. ----

            val infoCol = LinearLayout(this@PartyDashboardActivity).apply {
                orientation = LinearLayout.VERTICAL
                setPadding(0, 0, 12, 0)
                layoutParams = LinearLayout.LayoutParams(0, LinearLayout.LayoutParams.WRAP_CONTENT, 1f)
            }
            infoCol.addView(TextView(this@PartyDashboardActivity).apply {
                text = row.partyName
                textSize = 14.5f
                setTypeface(typeface, android.graphics.Typeface.BOLD)
                setTextColor(Color.parseColor("#2E3242"))
            })
            infoCol.addView(TextView(this@PartyDashboardActivity).apply {
                text = typeLabel
                textSize = 10f
                setTypeface(typeface, android.graphics.Typeface.BOLD)
                setTextColor(Color.parseColor(accent))
                background = pillBg(lightenHex(accent, 0.85f), 20f)
                setPadding(16, 4, 16, 4)
                val lp = LinearLayout.LayoutParams(LinearLayout.LayoutParams.WRAP_CONTENT, LinearLayout.LayoutParams.WRAP_CONTENT)
                lp.topMargin = 6
                layoutParams = lp
            })
            infoCol.addView(TextView(this@PartyDashboardActivity).apply {
                text = dateText + if (row.status == "returned") "  \u2022  " + Loc.t(this@PartyDashboardActivity, "Returned", "\u0648\u0627\u067E\u0633") else ""
                textSize = 11f
                setTextColor(Color.parseColor(if (row.status == "returned") red else labelGray))
                setPadding(0, 4, 0, 0)
            })
            addView(infoCol)

            addView(TextView(this@PartyDashboardActivity).apply {
                text = "Rs %.2f".format(row.amount)
                textSize = 14f
                setTypeface(typeface, android.graphics.Typeface.BOLD)
                setTextColor(Color.parseColor(accent))
            })
        }
    }

    // ================= ITEMS TAB =================
    // Combines each product's own profile (category/unit/rates) with its all-time
    // sold vs purchased totals, so the row shows the item's complete picture.
    private fun renderItemsList(forceReload: Boolean) {
        if (!forceReload) { renderItemRows(); return }
        listContainer.removeAllViews()
        lifecycleScope.launch {
            val db = PosDatabase.get(this@PartyDashboardActivity)
            val products = db.productDao().all().first()
            val soldTotals = db.saleDao().allTimeItemTotals()
            val purchasedTotals = db.purchaseDao().allTimeItemTotals()

            val soldMap = soldTotals.associateBy { it.product }
            val purMap = purchasedTotals.associateBy { it.product }

            itemCache = products.map { p ->
                val sold = soldMap[p.name]
                val pur = purMap[p.name]
                ItemAgg(
                    product = p.name,
                    category = p.category,
                    unit = p.unit,
                    cost = p.cost,
                    salePrice = p.salePrice,
                    wholesalePrice = p.wholesalePrice,
                    stock = p.stock,
                    // Product.stock is a SMALLEST-unit count, not a primary-unit count, so it
                    // must never be paired with `p.unit` directly — formatStockBreakdown() is
                    // the same helper Product/Purchase/Sale screens use for this.
                    stockDisplay = p.formatStockBreakdown(),
                    // ---- FIX: totalQty is a Double (SQL SUM aggregate); ItemAgg.soldQty/
                    // purQty are Int. `?: 0` mixed an Int literal with a Double, which the
                    // compiler couldn't resolve to a single type — this was the
                    // ":app:compileDebugKotlin" failure. Default to 0.0 and round to Int.
                    soldQty = (sold?.totalQty ?: 0.0).toInt(),
                    soldAmt = sold?.totalAmount ?: 0.0,
                    purQty = (pur?.totalQty ?: 0.0).toInt(),
                    purAmt = pur?.totalAmount ?: 0.0,
                    entity = p
                )
            }.sortedBy { it.product.lowercase() }

            if (activeTab != Tab.ITEMS) return@launch
            renderItemRows()
        }
    }

    private fun renderItemRows() {
        if (activeTab != Tab.ITEMS) return
        listContainer.removeAllViews()
        val q = itemQuery.trim()
        // FIX (English search alias not matching here): every other item-search
        // screen goes through Product.matchesQuery() (name + searchTag); this one
        // was checking the raw Urdu `product` name only. Route through the same
        // entity (full Product row, already cached in ItemAgg) instead.
        val filtered = itemCache.filter { it.entity.matchesQuery(q) }

        if (filtered.isEmpty()) {
            listContainer.addView(placeholderCard(Loc.t(this, "No items found", "\u06A9\u0648\u0626\u06CC \u0622\u0626\u0679\u0645 \u0646\u06C1\u06CC\u06BA \u0645\u0644\u0627")))
            return
        }

        for (c in filtered) {
            listContainer.addView(itemRow(c))
        }
    }

    private fun itemRow(c: ItemAgg): LinearLayout {
        return LinearLayout(this).apply {
            orientation = LinearLayout.VERTICAL
            setPadding(20, 18, 20, 18)
            background = elevatedCardBg()
            elevation = 1.5f
            layoutParams = LinearLayout.LayoutParams(
                LinearLayout.LayoutParams.MATCH_PARENT, LinearLayout.LayoutParams.WRAP_CONTENT
            ).apply { setMargins(0, 0, 0, 12) }
            isClickable = true
            setOnClickListener { showItemDetailDialog(c) }

            val headRow = LinearLayout(this@PartyDashboardActivity).apply { orientation = LinearLayout.HORIZONTAL; gravity = Gravity.CENTER_VERTICAL }
            // ---- CHANGE (sada/plain like Parties tab — icon removed here too):
            // dropped the leading ic_box icon badge, same as transactionRow above. ----
            val topRow = LinearLayout(this@PartyDashboardActivity).apply {
                orientation = LinearLayout.HORIZONTAL
                gravity = Gravity.CENTER_VERTICAL
                setPadding(0, 0, 0, 0)
                layoutParams = LinearLayout.LayoutParams(0, LinearLayout.LayoutParams.WRAP_CONTENT, 1f)
            }
            topRow.addView(TextView(this@PartyDashboardActivity).apply {
                text = c.product
                textSize = 14.5f
                setTypeface(typeface, android.graphics.Typeface.BOLD)
                setTextColor(Color.parseColor("#2E3242"))
                layoutParams = LinearLayout.LayoutParams(0, LinearLayout.LayoutParams.WRAP_CONTENT, 1f)
            })
            val rightCol = LinearLayout(this@PartyDashboardActivity).apply {
                orientation = LinearLayout.VERTICAL
                gravity = Gravity.END
            }
            if (c.category.isNotBlank()) {
                rightCol.addView(TextView(this@PartyDashboardActivity).apply {
                    text = c.category
                    textSize = 10f
                    setTypeface(typeface, android.graphics.Typeface.BOLD)
                    setTextColor(Color.parseColor(labelGray))
                    background = pillBg(lightenHex(labelGray, 0.85f), 20f)
                    setPadding(16, 4, 16, 4)
                })
            }
            rightCol.addView(TextView(this@PartyDashboardActivity).apply {
                text = "Stock: ${c.stockDisplay}"
                textSize = 11.5f
                setTextColor(Color.parseColor(labelGray))
                setPadding(0, 4, 0, 0)
            })
            topRow.addView(rightCol)
            headRow.addView(topRow)
            addView(headRow)

            addView(TextView(this@PartyDashboardActivity).apply {
                text = Loc.t(this@PartyDashboardActivity, "Category", "\u06A9\u06CC\u0679\u06AF\u0631\u06CC") + ": ${c.category.ifBlank { "-" }}  \u00B7  " +
                        Loc.t(this@PartyDashboardActivity, "Unit", "\u06CC\u0648\u0646\u0679") + ": ${c.unit}"
                textSize = 11.5f
                setTextColor(Color.parseColor(labelGray))
                setPadding(0, 4, 0, 0)
            })

            val ratesRow = LinearLayout(this@PartyDashboardActivity).apply { orientation = LinearLayout.HORIZONTAL; setPadding(0, 6, 0, 0) }
            ratesRow.addView(TextView(this@PartyDashboardActivity).apply {
                text = Loc.t(this@PartyDashboardActivity, "Purchase Rate", "\u062E\u0631\u06CC\u062F \u0631\u06CC\u0679") + ": Rs %.2f".format(c.cost)
                textSize = 11.5f
                setTextColor(Color.parseColor(orange))
                layoutParams = LinearLayout.LayoutParams(0, LinearLayout.LayoutParams.WRAP_CONTENT, 1f)
            })
            ratesRow.addView(TextView(this@PartyDashboardActivity).apply {
                text = Loc.t(this@PartyDashboardActivity, "Retail Rate", "\u0631\u06CC\u0679\u06CC\u0644 \u0631\u06CC\u0679") + ": Rs %.2f".format(c.salePrice)
                textSize = 11.5f
                setTextColor(Color.parseColor(blue))
                layoutParams = LinearLayout.LayoutParams(0, LinearLayout.LayoutParams.WRAP_CONTENT, 1f)
            })
            addView(ratesRow)

            addView(TextView(this@PartyDashboardActivity).apply {
                text = Loc.t(this@PartyDashboardActivity, "Wholesale Rate", "\u06C1\u0648\u0644 \u0633\u06CC\u0644 \u0631\u06CC\u0679") + ": Rs %.2f".format(c.wholesalePrice)
                textSize = 11.5f
                setTextColor(Color.parseColor("#7B61FF"))
                setPadding(0, 4, 0, 0)
            })

            val row = LinearLayout(this@PartyDashboardActivity).apply {
                orientation = LinearLayout.HORIZONTAL
                setPadding(0, 8, 0, 0)
            }
            row.addView(TextView(this@PartyDashboardActivity).apply {
                text = Loc.t(this@PartyDashboardActivity, "Sold", "\u0641\u0631\u0648\u062E\u062A") + ": ${c.soldQty} \u00B7 Rs %.2f".format(c.soldAmt)
                textSize = 12f
                setTextColor(Color.parseColor(green))
                layoutParams = LinearLayout.LayoutParams(0, LinearLayout.LayoutParams.WRAP_CONTENT, 1f)
            })
            row.addView(TextView(this@PartyDashboardActivity).apply {
                text = Loc.t(this@PartyDashboardActivity, "Purchased", "\u062E\u0631\u06CC\u062F\u0627") + ": ${c.purQty} \u00B7 Rs %.2f".format(c.purAmt)
                textSize = 12f
                setTextColor(Color.parseColor(orange))
            })
            addView(row)
        }
    }

    private fun showItemDetailDialog(c: ItemAgg) {
        val body = LinearLayout(this).apply {
            orientation = LinearLayout.VERTICAL
            setPadding(28, 20, 28, 10)
        }
        fun line(label: String, value: String, colorHex: String = "#2E3242") {
            body.addView(LinearLayout(this@PartyDashboardActivity).apply {
                orientation = LinearLayout.HORIZONTAL
                setPadding(0, 8, 0, 8)
                addView(TextView(this@PartyDashboardActivity).apply {
                    text = label; textSize = 13.5f
                    setTextColor(Color.parseColor(labelGray))
                    layoutParams = LinearLayout.LayoutParams(0, LinearLayout.LayoutParams.WRAP_CONTENT, 1f)
                })
                addView(TextView(this@PartyDashboardActivity).apply {
                    text = value; textSize = 13.5f; gravity = Gravity.END
                    setTypeface(typeface, android.graphics.Typeface.BOLD)
                    setTextColor(Color.parseColor(colorHex))
                })
            })
        }
        line(Loc.t(this, "Category", "\u06A9\u06CC\u0679\u06AF\u0631\u06CC"), c.category.ifBlank { "-" })
        line(Loc.t(this, "Unit", "\u06CC\u0648\u0646\u0679"), c.unit)
        line(Loc.t(this, "Current Stock", "\u0645\u0648\u062C\u0648\u062F\u06C1 \u0627\u0633\u0679\u0627\u06A9"), c.stockDisplay)
        line(Loc.t(this, "Purchase Rate", "\u062E\u0631\u06CC\u062F \u0631\u06CC\u0679"), "Rs %.2f".format(c.cost), orange)
        line(Loc.t(this, "Retail Sale Rate", "\u0631\u06CC\u0679\u06CC\u0644 \u0631\u06CC\u0679"), "Rs %.2f".format(c.salePrice), blue)
        line(Loc.t(this, "Wholesale Rate", "\u06C1\u0648\u0644 \u0633\u06CC\u0644 \u0631\u06CC\u0679"), "Rs %.2f".format(c.wholesalePrice), "#7B61FF")
        body.addView(View(this).apply {
            setBackgroundColor(Color.parseColor(cardBorder))
            layoutParams = LinearLayout.LayoutParams(LinearLayout.LayoutParams.MATCH_PARENT, 2).apply { setMargins(0, 8, 0, 8) }
        })
        line(Loc.t(this, "Total Sold (all-time)", "\u06A9\u0644 \u0641\u0631\u0648\u062E\u062A"), "${c.soldQty} \u00B7 Rs %.2f".format(c.soldAmt), green)
        line(Loc.t(this, "Total Purchased (all-time)", "\u06A9\u0644 \u062E\u0631\u06CC\u062F\u0627\u0631\u06CC"), "${c.purQty} \u00B7 Rs %.2f".format(c.purAmt), orange)

        // ---- NEW: EDIT button opens showEditRatesDialog() to update rates in-place. ----
        AlertDialog.Builder(this)
            .setTitle(c.product)
            .setView(body)
            .setPositiveButton(Loc.t(this, "Close", "\u0628\u0646\u062F \u06A9\u0631\u06CC\u06BA"), null)
            .setNeutralButton(Loc.t(this, "Edit", "\u0627\u06CC\u0688\u0679")) { _, _ -> showEditRatesDialog(c) }
            .show()
    }

    /**
     * Small dialog to quickly update Purchase / Retail Sale / Wholesale rates for one
     * product, without going through the full ProductActivity edit screen. Saves via
     * productDao().upsert() — confirmed against ProductActivity.kt's saveProduct(),
     * which uses the same db.productDao().upsert(product) call — then refreshes the
     * Items tab so the new values show immediately in both the row and the detail
     * dialog.
     */
    private fun showEditRatesDialog(c: ItemAgg) {
        val container = LinearLayout(this).apply {
            orientation = LinearLayout.VERTICAL
            setPadding(48, 20, 48, 8)
        }

        fun rateField(labelText: String, initial: Double): EditText {
            container.addView(TextView(this).apply {
                text = labelText
                textSize = 12.5f
                setTextColor(Color.parseColor(labelGray))
                setPadding(0, 14, 0, 4)
            })
            val field = EditText(this).apply {
                setText(if (initial == 0.0) "" else "%.2f".format(initial))
                hint = "0.00"
                inputType = InputType.TYPE_CLASS_NUMBER or InputType.TYPE_NUMBER_FLAG_DECIMAL
            }
            container.addView(field)
            return field
        }

        val purchaseField = rateField(Loc.t(this, "Purchase Rate", "\u062E\u0631\u06CC\u062F \u0631\u06CC\u0679"), c.cost)
        val retailField = rateField(Loc.t(this, "Retail Sale Rate", "\u0631\u06CC\u0679\u06CC\u0644 \u0631\u06CC\u0679"), c.salePrice)
        val wholesaleField = rateField(Loc.t(this, "Wholesale Rate", "\u06C1\u0648\u0644 \u0633\u06CC\u0644 \u0631\u06CC\u0679"), c.wholesalePrice)

        AlertDialog.Builder(this)
            .setTitle(Loc.t(this, "Edit Rates", "\u0631\u06CC\u0679 \u0627\u06CC\u0688\u0679 \u06A9\u0631\u06CC\u06BA") + " \u2014 ${c.product}")
            .setView(container)
            .setPositiveButton(Loc.t(this, "Save", "\u0645\u062D\u0641\u0648\u0638 \u06A9\u0631\u06CC\u06BA")) { d, _ ->
                val newCost = purchaseField.text.toString().trim().toDoubleOrNull()
                val newRetail = retailField.text.toString().trim().toDoubleOrNull()
                val newWholesale = wholesaleField.text.toString().trim().toDoubleOrNull()

                if (newCost == null || newRetail == null || newWholesale == null ||
                    newCost < 0 || newRetail < 0 || newWholesale < 0
                ) {
                    Toast.makeText(this, Loc.t(this, "Enter valid rates", "\u0635\u062D\u06CC\u062D \u0631\u06CC\u0679 \u0644\u06A9\u06BE\u06CC\u06BA"), Toast.LENGTH_SHORT).show()
                    return@setPositiveButton
                }

                lifecycleScope.launch {
                    val db = PosDatabase.get(this@PartyDashboardActivity)
                    // FIX: ProductActivity.kt confirms ProductDao uses upsert(product),
                    // not update() — corrected from the earlier ADJUST-DAO-METHOD guess.
                    val updatedProduct = c.entity.copy(
                        cost = newCost,
                        salePrice = newRetail,
                        wholesalePrice = newWholesale
                    )
                    db.productDao().upsert(updatedProduct)
                    // Keep rate changes made from Party Dashboard in the same sync path
                    // as ProductActivity, so other branch devices receive them too.
                    SyncQueueHelper.enqueueProduct(db, updatedProduct)
                    Toast.makeText(
                        this@PartyDashboardActivity,
                        Loc.t(this@PartyDashboardActivity, "Rates updated", "\u0631\u06CC\u0679 \u0627\u067E\u0688\u06CC\u0679 \u06C1\u0648 \u06AF\u0626\u06CC"),
                        Toast.LENGTH_SHORT
                    ).show()
                    renderItemsList(forceReload = true)
                }
                d.dismiss()
            }
            .setNegativeButton(Loc.t(this, "Cancel", "\u0645\u0646\u0633\u0648\u062E \u06A9\u0631\u06CC\u06BA"), null)
            .show()
    }

    private fun placeholderCard(text: String) = LinearLayout(this).apply {
        orientation = LinearLayout.VERTICAL
        gravity = Gravity.CENTER
        setPadding(20, 30, 20, 30)
        background = elevatedCardBg()
        addView(TextView(this@PartyDashboardActivity).apply {
            this.text = text
            setTextColor(Color.parseColor(labelGray))
            textSize = 13f
            gravity = Gravity.CENTER
        })
    }

    // ================= UI helpers =================
    // ---- CHANGE (modern minimal UI pass): dropped the 1px border stroke every card
    // used to have — a bordered-white-square look reads as "form UI", not modern. Cards
    // now float on the off-white background purely on a soft shadow (elevation), with
    // a bigger corner radius (16f -> 20f) for a softer, more contemporary shape. This
    // one shared helper feeds every card on this screen (summary cards, party rows,
    // transaction rows, item rows, placeholders) so the whole screen re-themes together.
    private fun elevatedCardBg() = GradientDrawable().apply {
        setColor(Color.parseColor(cardWhite))
        cornerRadius = 20f
    }

    // ---- ADDED (modern minimal UI pass): flat, borderless "chip" pill — used for the
    // segmented tab control's active pill and can be reused anywhere a filled pill
    // (no stroke) is wanted, as opposed to roundedBackground() which is also stroke-free
    // but named for full-bleed accent backgrounds rather than small pills.
    private fun pillBg(colorHex: String, radius: Float = 22f) = GradientDrawable().apply {
        setColor(Color.parseColor(colorHex))
        cornerRadius = radius
    }

    internal fun roundedBackground(colorHex: String, cornerRadius: Int) = GradientDrawable().apply {
        setColor(Color.parseColor(colorHex))
        this.cornerRadius = cornerRadius.toFloat()
    }

}

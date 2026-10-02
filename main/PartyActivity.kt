package com.grocerypos.v11.ui
import com.grocerypos.v11.SyncQueueHelper

import android.Manifest
import android.app.AlertDialog
import android.content.Intent
import android.content.pm.PackageManager
import android.graphics.Color
import android.graphics.drawable.GradientDrawable
import android.net.Uri
import android.os.Bundle
import android.provider.ContactsContract
import android.text.InputType
import android.view.Gravity
import android.view.View
import android.widget.*
import androidx.activity.result.ActivityResultLauncher
import androidx.activity.result.contract.ActivityResultContracts
import androidx.activity.viewModels
import androidx.appcompat.app.AppCompatActivity
import androidx.core.content.ContextCompat
import androidx.lifecycle.lifecycleScope
import com.grocerypos.v11.Customer
import com.grocerypos.v11.totalPayable
import com.grocerypos.v11.R
import com.grocerypos.v11.Supplier
import com.grocerypos.v11.data.DuplicatePaymentGroup
import com.grocerypos.v11.util.Loc
import com.grocerypos.v11.util.parseMoneyOrWarn
import kotlinx.coroutines.flow.collectLatest
import kotlinx.coroutines.launch
import java.text.SimpleDateFormat
import java.util.Date
import java.util.Locale
import com.grocerypos.v11.ui.components.*

/**
 * UI layer only — this Activity builds views and forwards user actions to
 * [PartyViewModel]. It never touches Room or SyncQueueHelper directly; that
 * lives in PartyRepository (data) and PartyUseCases (domain). See those two
 * files plus PartyViewModel for the rest of the UI -> ViewModel -> UseCase ->
 * Repository -> Room chain.
 */
class PartyActivity : AppCompatActivity() {

    private val viewModel: PartyViewModel by viewModels { PartyViewModelFactory(applicationContext) }

    // ---- Reports-style flat design — pulled from ThemeManager so this screen stays in
    // sync with the rest of the app and respects dark mode. Party = flatPink everywhere
    // per ThemeManager's documented category convention (matches MainActivity's
    // "Customers & Suppliers" tile). ----
    private var bg = "#F4F6F8"
    private var navy = "#0B2545"       // app-wide accent (header + primary chrome)
    private var blue = "#993556"       // customer accent — flatPinkFg (kept distinct for tab/icon tinting)
    private var orange = "#993C1D"     // supplier accent — flatCoralFg (kept distinct for tab/icon tinting)
    private var green = "#085041"      // flatTealFg — unified with Reports' "positive" color
    private var red = "#D32F4A"
    private var cardWhite = "#FFFFFF"
    private var cardBorder = "#E3E8EE"
    private var labelGray = "#7C8798"

    private fun loadThemeColors() {
        val p = com.grocerypos.v11.util.ThemeManager.palette(this)
        bg = p.bg
        cardWhite = p.cardWhite
        cardBorder = p.border
        labelGray = p.textMuted
        navy = p.navy
        blue = p.flatPinkFg
        orange = p.flatCoralFg
        green = p.flatTealFg
        red = p.red
    }

    private lateinit var tabRow: LinearLayout
    private lateinit var formCard: LinearLayout
    private lateinit var nameField: EditText
    private lateinit var phoneField: EditText
    private lateinit var creditLimitField: EditText
    private lateinit var creditLimitBox: LinearLayout
    // NEW (Stuck Balance): optional field on the Add form. Only shown for the Customers tab
    // AND only to Admin/Manager (everyone, cashier included, can SEE it in lists/history).
    private lateinit var stuckBalanceField: EditText
    private lateinit var stuckBalanceBox: LinearLayout

    // NEW (Stuck Balance): who may add/edit the stuck amount — Admin and Manager. Same
    // session pref + fail-safe default ("cashier") as the other role gates in this app,
    // so a missing/unknown role can never edit it.
    private val canEditStuck: Boolean
        get() {
            val role = getSharedPreferences("session", MODE_PRIVATE).getString("role", "cashier") ?: "cashier"
            return role == "admin" || role == "manager"
        }
    private lateinit var openingBalanceField: EditText
    private lateinit var listContainer: LinearLayout
    private lateinit var saveButton: Button
    private lateinit var sectionAccentText: TextView

    // ---- IMPROVEMENT PACK (Party 10/10): search box + "Dues only" chip above the
    // list. Both are pure UI-side filters — they never touch the ViewModel's
    // uiState, they just narrow what render() draws from the last state it got. ----
    private lateinit var searchField: EditText
    private lateinit var duesOnlyChip: TextView
    private lateinit var recalculateChip: TextView
    private lateinit var mergeDuplicatesChip: TextView
    private lateinit var cleanupPaymentsChip: TextView
    private lateinit var orphanedPaymentsChip: TextView
    private var searchQuery: String = ""
    private var duesOnly: Boolean = false
    private var lastState: PartyUiState? = null

    // ---- Contact picker launchers ----
    private lateinit var contactPickerLauncher: ActivityResultLauncher<Void?>
    private lateinit var contactPermissionLauncher: ActivityResultLauncher<String>

    // PERMANENT FIX (balance drift): the live balances (PartyUiState.customerBalances/
    // supplierBalances) only auto-refresh when a customer/supplier ROW itself changes —
    // not when a sale/purchase/payment does. Re-fetching them every time this screen
    // becomes visible again (e.g. coming back here after making a payment on the Party
    // Transaction screen) keeps what's shown from ever going stale.
    override fun onResume() {
        super.onResume()
        viewModel.refreshBalances()
    }

    override fun onCreate(b: Bundle?) {
        super.onCreate(b)
        loadThemeColors()

        contactPickerLauncher = registerForActivityResult(ActivityResultContracts.PickContact()) { uri ->
            uri?.let { fetchPhoneFromContact(it) }
        }
        contactPermissionLauncher = registerForActivityResult(ActivityResultContracts.RequestPermission()) { granted ->
            if (granted) {
                contactPickerLauncher.launch(null)
            } else {
                Toast.makeText(this, Loc.t(this, "Contacts permission denied", "رابطوں کی اجازت مسترد"), Toast.LENGTH_SHORT).show()
            }
        }

        // ---- TABLET/DENSITY FIX: header + root padding below used to be raw pixel values
        // (e.g. setPadding(28, 40, 24, 32)) instead of dp-scaled — fine on the density this was
        // designed at, but far too tight on a tablet's higher-density screen. That's why the
        // header sat cramped against the top and, more importantly, why the LAST party row's
        // Edit/Delete buttons ended up sitting right at the physical bottom edge of the screen —
        // inside the gesture-nav strip, which swallows the tap before it reaches the button
        // (looks like "last item's Edit doesn't work"). Fixed by scaling every padding value
        // below with density, and adding real breathing room at the bottom of the scroll
        // content so the last card can be scrolled clear of the gesture area. ----
        val d = resources.displayMetrics.density

        val outer = LinearLayout(this).apply {
            orientation = LinearLayout.VERTICAL
            setBackgroundColor(Color.parseColor(bg))
        }

        // ================= HEADER (shared premiumHeader — same as History/Reports/Settings) =================
        outer.addView(premiumHeader(
            iconRes = R.drawable.ic_people,
            title = Loc.t(this@PartyActivity, "Customers & Suppliers", "کسٹمرز اور سپلائرز"),
            subtitle = Loc.t(this@PartyActivity, "Manage parties & view ledgers", "پارٹیز کا انتظام اور کھاتے دیکھیں"),
            primaryHex = navy,
            primaryDarkHex = navy
        ))

        val root = LinearLayout(this).apply {
            orientation = LinearLayout.VERTICAL
            // Bottom padding raised from a raw 28px to a density-scaled 90dp so the last
            // list item always has room to scroll clear of the gesture-nav strip.
            setPadding((24 * d).toInt(), (20 * d).toInt(), (24 * d).toInt(), (90 * d).toInt())
        }

        // ================= TABS (pill style) =================
        tabRow = LinearLayout(this).apply { orientation = LinearLayout.HORIZONTAL }
        root.addView(tabRow)
        root.addView(spacer(16))

        // ================= ADD PARTY FORM CARD =================
        formCard = premiumCard().apply { setPadding(22, 20, 22, 20) }

        sectionAccentText = TextView(this).apply {
            text = Loc.t(this@PartyActivity, "Add Customer", "کسٹمر شامل کریں")
            textSize = 13f
            setTypeface(typeface, android.graphics.Typeface.BOLD)
            setTextColor(Color.parseColor(blue))
            setPadding(0, 0, 0, 12)
            setLeadingIcon(R.drawable.ic_person, blue, 14, 8)
        }
        formCard.addView(sectionAccentText)

        val nameBox = innerField()
        nameField = EditText(this).apply { hint = Loc.t(this@PartyActivity, "Name *", "نام *"); background = null; textSize = 15f }
        nameBox.addView(nameField)
        formCard.addView(nameBox)
        formCard.addView(spacer(10))

        // ---- Phone field row: EditText + contact-picker icon button ----
        val phoneBox = innerField().apply {
            orientation = LinearLayout.HORIZONTAL
            gravity = Gravity.CENTER_VERTICAL
        }
        phoneField = EditText(this).apply {
            hint = Loc.t(this@PartyActivity, "Phone (optional)", "فون (اختیاری)")
            background = null
            textSize = 15f
            inputType = InputType.TYPE_CLASS_PHONE
            layoutParams = LinearLayout.LayoutParams(0, LinearLayout.LayoutParams.WRAP_CONTENT, 1f)
        }
        phoneBox.addView(phoneField)
        phoneBox.addView(ImageView(this).apply {
            setImageDrawable(tintedDrawable(R.drawable.ic_person, blue, 20))
            setPadding(12, 0, 4, 0)
            setOnClickListener { openContactPicker() }
        })
        formCard.addView(phoneBox)
        formCard.addView(spacer(10))

        creditLimitBox = innerField()
        creditLimitField = EditText(this).apply {
            hint = Loc.t(this@PartyActivity, "Credit Limit (optional)", "کریڈٹ لیمٹ (اختیاری)")
            background = null
            textSize = 15f
            inputType = InputType.TYPE_CLASS_NUMBER or InputType.TYPE_NUMBER_FLAG_DECIMAL
        }
        creditLimitBox.addView(creditLimitField)
        formCard.addView(creditLimitBox)
        formCard.addView(spacer(10))

        val openingBox = innerField()
        openingBalanceField = EditText(this).apply {
            hint = Loc.t(this@PartyActivity, "Opening Balance (Rs, if any previous due)", "ابتدائی بیلنس (روپے، اگر کوئی پرانا واجب الادا ہو)")
            background = null
            textSize = 15f
            inputType = InputType.TYPE_CLASS_NUMBER or InputType.TYPE_NUMBER_FLAG_DECIMAL
        }
        openingBox.addView(openingBalanceField)
        formCard.addView(openingBox)

        // NEW (Stuck Balance): a second, separate opening amount for an old amount that
        // doesn't move with daily sales. Leave empty for normal customers.
        formCard.addView(spacer(10))
        stuckBalanceBox = innerField()
        stuckBalanceField = EditText(this).apply {
            hint = Loc.t(this@PartyActivity, "Stuck Balance (Rs, optional — old amount that doesn't move)", "اسٹک بیلنس (روپے، اختیاری — پرانا رکا ہوا رقم)")
            background = null
            textSize = 15f
            inputType = InputType.TYPE_CLASS_NUMBER or InputType.TYPE_NUMBER_FLAG_DECIMAL
        }
        stuckBalanceBox.addView(stuckBalanceField)
        formCard.addView(stuckBalanceBox)
        formCard.addView(spacer(14))

        saveButton = Button(this).apply {
            text = Loc.t(this@PartyActivity, "SAVE", "محفوظ کریں")
            setTextColor(Color.WHITE)
            textSize = 14f
            background = roundedBackground(blue, 14)
            setPadding(0, 20, 0, 20)
            setOnClickListener { saveParty() }
        }
        formCard.addView(saveButton)
        root.addView(formCard)
        root.addView(spacer(18))

        // ================= LIST HEADER =================
        val listHeaderRow = LinearLayout(this).apply {
            orientation = LinearLayout.HORIZONTAL
            gravity = Gravity.CENTER_VERTICAL
            setPadding(4, 0, 4, 10)
        }
        listHeaderRow.addView(TextView(this).apply {
            text = Loc.t(this@PartyActivity, "Party List", "پارٹی لسٹ")
            textSize = 14f
            setTypeface(typeface, android.graphics.Typeface.BOLD)
            setLeadingIcon(R.drawable.ic_list, navy, 15, 8)
            layoutParams = LinearLayout.LayoutParams(0, LinearLayout.LayoutParams.WRAP_CONTENT, 1f)
        })
        listHeaderRow.addView(TextView(this).apply {
            text = Loc.t(this@PartyActivity, "Tap for history · icons to edit/delete", "تاریخ کے لیے ٹیپ کریں · ترمیم/حذف کے آئیکنز")
            textSize = 11f
            setTextColor(Color.parseColor(labelGray))
        })
        root.addView(listHeaderRow)

        // ---- IMPROVEMENT PACK (Party 10/10): search box + "Dues only" filter chip.
        // Lets a shop with a long party list actually find someone instead of
        // scrolling, and instantly see who still owes / is owed money. ----
        // FIX (search box + action chips squeezed into one row): these used to share
        // a single HORIZONTAL row where the search box had weight=1 and five fixed-width
        // chips ("Dues only", "Fix Balances", "Merge Duplicates", "Cleanup Payments",
        // "Cleanup Orphaned") sat next to it. On a normal phone width that left almost no
        // room for the search box (it rendered as a near-invisible sliver) and squashed the
        // chips together with barely any gap between them. The search box now gets its own
        // full-width row, and the chips sit in a horizontally scrollable row below with
        // consistent spacing, so nothing is cramped and everything stays tappable.
        val searchRow = LinearLayout(this).apply {
            orientation = LinearLayout.HORIZONTAL
            gravity = Gravity.CENTER_VERTICAL
            setPadding(0, 0, 0, 10)
        }
        val searchBox = innerField().apply {
            layoutParams = LinearLayout.LayoutParams(LinearLayout.LayoutParams.MATCH_PARENT, LinearLayout.LayoutParams.WRAP_CONTENT)
        }
        searchField = EditText(this).apply {
            hint = Loc.t(this@PartyActivity, "Search by name or phone", "نام یا فون سے تلاش کریں")
            background = null
            textSize = 14f
            setLeadingIcon(R.drawable.ic_search, "#9AA0AE", 16, 8)
            compoundDrawablePadding = (8 * d).toInt()
            addTextChangedListener(object : android.text.TextWatcher {
                override fun beforeTextChanged(s: CharSequence?, start: Int, count: Int, after: Int) {}
                override fun onTextChanged(s: CharSequence?, start: Int, before: Int, count: Int) {}
                override fun afterTextChanged(s: android.text.Editable?) {
                    searchQuery = s?.toString().orEmpty()
                    lastState?.let { render(it) }
                }
            })
        }
        searchBox.addView(searchField)
        searchRow.addView(searchBox)
        root.addView(searchRow)

        val filterRow = LinearLayout(this).apply {
            orientation = LinearLayout.HORIZONTAL
            gravity = Gravity.CENTER_VERTICAL
        }
        val filterScroll = HorizontalScrollView(this).apply {
            isHorizontalScrollBarEnabled = false
            layoutParams = LinearLayout.LayoutParams(LinearLayout.LayoutParams.MATCH_PARENT, LinearLayout.LayoutParams.WRAP_CONTENT).apply {
                bottomMargin = (12 * d).toInt()
            }
            addView(filterRow)
        }
        duesOnlyChip = TextView(this).apply {
            text = Loc.t(this@PartyActivity, "Dues only", "صرف واجبات")
            textSize = 12f
            setTypeface(typeface, android.graphics.Typeface.BOLD)
            setPadding((16 * d).toInt(), (14 * d).toInt(), (16 * d).toInt(), (14 * d).toInt())
            background = roundedBackground("#EEF0F7", 24)
            setTextColor(Color.parseColor("#6B7280"))
            setLeadingIcon(R.drawable.ic_wallet, "#6B7280", 14, 6)
            setOnClickListener {
                duesOnly = !duesOnly
                lastState?.let { render(it) }
            }
        }
        filterRow.addView(duesOnlyChip)
        filterRow.addView(spacer(10).apply {
            layoutParams = LinearLayout.LayoutParams((10 * d).toInt(), LinearLayout.LayoutParams.WRAP_CONTENT)
        })
        // NEW (Recalculate Balances): a party's balance is a running total nudged by
        // every sale/purchase/payment, not something recomputed from the visible
        // history each time — so it can quietly drift out of sync with the party's
        // actual bills (see PartyRepository.recalculateBalances()). This lets the
        // shop owner fix that drift on demand instead of only Claude being able to.
        recalculateChip = TextView(this).apply {
            text = Loc.t(this@PartyActivity, "Fix Balances", "بیلنس ٹھیک کریں")
            textSize = 12f
            setTypeface(typeface, android.graphics.Typeface.BOLD)
            setPadding((16 * d).toInt(), (14 * d).toInt(), (16 * d).toInt(), (14 * d).toInt())
            background = roundedBackground("#EEF0F7", 24)
            setTextColor(Color.parseColor("#6B7280"))
            setLeadingIcon(R.drawable.ic_sync, "#6B7280", 14, 6)
            setOnClickListener { confirmRecalculateBalances() }
        }
        filterRow.addView(recalculateChip)
        filterRow.addView(spacer(10).apply {
            layoutParams = LinearLayout.LayoutParams((10 * d).toInt(), LinearLayout.LayoutParams.WRAP_CONTENT)
        })
        // NEW (Merge Duplicate Parties): same-name customers/suppliers created
        // independently on two devices before their first sync end up as two
        // separate rows with two separate histories — this merges them into one.
        // See PartyRepository.mergeDuplicateParties().
        mergeDuplicatesChip = TextView(this).apply {
            text = Loc.t(this@PartyActivity, "Merge Duplicates", "ڈپلیکیٹ ملائیں")
            textSize = 12f
            setTypeface(typeface, android.graphics.Typeface.BOLD)
            setPadding((16 * d).toInt(), (14 * d).toInt(), (16 * d).toInt(), (14 * d).toInt())
            background = roundedBackground("#EEF0F7", 24)
            setTextColor(Color.parseColor("#6B7280"))
            setLeadingIcon(R.drawable.ic_people, "#6B7280", 14, 6)
            setOnClickListener { confirmMergeDuplicates() }
        }
        filterRow.addView(mergeDuplicatesChip)
        filterRow.addView(spacer(10).apply {
            layoutParams = LinearLayout.LayoutParams((10 * d).toInt(), LinearLayout.LayoutParams.WRAP_CONTENT)
        })
        // NEW (Cleanup Duplicate Payments): the duplicate-payment-on-sync bug (fixed in
        // Database.kt/SyncQueueHelper.kt) left stray leftover payment rows behind on every
        // purchase/sale edit that happened before the fix — those rows are still sitting in
        // the database inflating balances even though no new ones can be created now. This
        // finds and removes exactly those old rows. See PartyRepository.findDuplicatePayments()
        // / cleanupDuplicatePayments().
        cleanupPaymentsChip = TextView(this).apply {
            text = Loc.t(this@PartyActivity, "Cleanup Payments", "ادائیگیاں صاف کریں")
            textSize = 12f
            setTypeface(typeface, android.graphics.Typeface.BOLD)
            setPadding((16 * d).toInt(), (14 * d).toInt(), (16 * d).toInt(), (14 * d).toInt())
            background = roundedBackground("#EEF0F7", 24)
            setTextColor(Color.parseColor("#6B7280"))
            setLeadingIcon(R.drawable.ic_wallet, "#6B7280", 14, 6)
            setOnClickListener { viewModel.findDuplicatePayments() }
        }
        filterRow.addView(cleanupPaymentsChip)
        filterRow.addView(spacer(10).apply {
            layoutParams = LinearLayout.LayoutParams((10 * d).toInt(), LinearLayout.LayoutParams.WRAP_CONTENT)
        })
        // NEW (Cleanup Orphaned Payments): a different leftover than Cleanup Payments
        // above — see PartyRepository.findOrphanedPayments() and this screen's
        // showOrphanedPaymentsPreview() for the full reasoning.
        orphanedPaymentsChip = TextView(this).apply {
            text = Loc.t(this@PartyActivity, "Cleanup Orphaned", "بے مالک صاف کریں")
            textSize = 12f
            setTypeface(typeface, android.graphics.Typeface.BOLD)
            setPadding((16 * d).toInt(), (14 * d).toInt(), (16 * d).toInt(), (14 * d).toInt())
            background = roundedBackground("#EEF0F7", 24)
            setTextColor(Color.parseColor("#6B7280"))
            setLeadingIcon(R.drawable.ic_wallet, "#6B7280", 14, 6)
            setOnClickListener { viewModel.findOrphanedPayments() }
        }
        filterRow.addView(orphanedPaymentsChip)
        root.addView(filterScroll)

        listContainer = LinearLayout(this).apply { orientation = LinearLayout.VERTICAL }
        root.addView(listContainer)

        val scrollArea = ScrollView(this).apply {
            layoutParams = LinearLayout.LayoutParams(LinearLayout.LayoutParams.MATCH_PARENT, 0, 1f)
            addView(root)
        }
        outer.addView(scrollArea)

        setContentView(outer)

        lifecycleScope.launch {
            viewModel.uiState.collectLatest { state -> render(state) }
        }
        lifecycleScope.launch {
            viewModel.events.collectLatest { event -> handleEvent(event) }
        }
    }

    /** Single render pass driven by [PartyUiState] — tabs, form styling, and the
     * party list all follow from this one source of truth instead of being
     * mutated ad hoc from separate click handlers. */
    private fun render(state: PartyUiState) {
        lastState = state
        buildTabs(state.showingCustomers)
        creditLimitBox.visibility = if (state.showingCustomers) View.VISIBLE else View.GONE
        stuckBalanceBox.visibility = if (state.showingCustomers && canEditStuck) View.VISIBLE else View.GONE
        sectionAccentText.text = if (state.showingCustomers)
            Loc.t(this, "Add Customer", "کسٹمر شامل کریں")
        else
            Loc.t(this, "Add Supplier", "سپلائر شامل کریں")
        val sectionAccentColor = if (state.showingCustomers) blue else orange
        sectionAccentText.setTextColor(Color.parseColor(sectionAccentColor))
        sectionAccentText.setLeadingIcon(
            if (state.showingCustomers) R.drawable.ic_person else R.drawable.ic_shopping_bag,
            sectionAccentColor, 14, 8
        )
        saveButton.background = roundedBackground(if (state.showingCustomers) blue else orange, 14)

        // ---- IMPROVEMENT PACK (Party 10/10): active-chip styling + the actual
        // search/dues filtering, applied to whichever list is currently showing. ----
        duesOnlyChip.background = roundedBackground(if (duesOnly) (if (state.showingCustomers) blue else orange) else "#EEF0F7", 24)
        duesOnlyChip.setTextColor(if (duesOnly) Color.WHITE else Color.parseColor("#6B7280"))

        val query = searchQuery.trim()
        fun matches(name: String, phone: String) =
            query.isEmpty() || name.contains(query, ignoreCase = true) || phone.contains(query, ignoreCase = true)

        listContainer.removeAllViews()
        // PERMANENT FIX (balance drift — "paid supplier still shows You'll Get"): every
        // closing figure below reads from state.customerBalances/supplierBalances —
        // PartyRepository's live, recomputed-from-the-ledger balances — instead of
        // c.balance/s.balance (the stored field that can drift). See
        // GetLiveBalancesUseCase / PartyRepository.liveCustomerBalances().
        if (state.showingCustomers) {
            val filtered = state.customers.filter {
                matches(it.name, it.phone) && (!duesOnly || (it.openingBalance + (state.customerBalances[it.id] ?: 0.0) + it.stuckBalance) != 0.0)
            }
            if (filtered.isEmpty()) {
                val msg = if (state.customers.isEmpty()) Loc.t(this, "No customers yet", "کوئی کسٹمر نہیں ہے")
                          else Loc.t(this, "No matching customers", "کوئی مماثل کسٹمر نہیں")
                listContainer.addView(emptyCard(msg))
            }
            for (c in filtered) {
                listContainer.addView(
                    partyRow(c.name, c.phone, c.openingBalance, state.customerBalances[c.id] ?: 0.0, blue, R.drawable.ic_person, isCustomer = true, stuck = c.stuckBalance,
                        onClick = { openCustomerHistory(c) },
                        onEdit = { editCustomerDialog(c) },
                        onDelete = { confirmDeleteCustomer(c) },
                        onCall = { dialPhone(c.phone) }
                    )
                )
            }
        } else {
            val filtered = state.suppliers.filter {
                matches(it.name, it.phone) && (!duesOnly || (it.openingBalance + (state.supplierBalances[it.id] ?: 0.0)) != 0.0)
            }
            if (filtered.isEmpty()) {
                val msg = if (state.suppliers.isEmpty()) Loc.t(this, "No suppliers yet", "کوئی سپلائر نہیں ہے")
                          else Loc.t(this, "No matching suppliers", "کوئی مماثل سپلائر نہیں")
                listContainer.addView(emptyCard(msg))
            }
            for (s in filtered) {
                listContainer.addView(
                    partyRow(s.name, s.phone, s.openingBalance, state.supplierBalances[s.id] ?: 0.0, orange, R.drawable.ic_shopping_bag, isCustomer = false,
                        onClick = { openSupplierHistory(s) },
                        onEdit = { editSupplierDialog(s) },
                        onDelete = { confirmDeleteSupplier(s) },
                        onCall = { dialPhone(s.phone) }
                    )
                )
            }
        }
    }

    private fun handleEvent(event: PartyEvent) {
        // NEW (Cleanup Duplicate Payments): these two don't fit the generic "run it, then
        // toast a one-line summary" pattern below — Found needs a preview dialog listing
        // what was found (with its own confirm/cancel) BEFORE anything is deleted, and
        // Cleaned reuses that same "Fixed X customer(s), Y supplier(s)" phrasing as
        // BalancesRecalculated so it still needs its own branch to add the removed-payments
        // count in front of it.
        if (event is PartyEvent.DuplicatePaymentsFound) {
            showDuplicatePaymentsPreview(event.groups)
            return
        }
        if (event is PartyEvent.DuplicatePaymentsCleaned) {
            val message = if (event.paymentsRemoved == 0) {
                Loc.t(this, "No duplicate payments found", "کوئی ڈپلیکیٹ ادائیگی نہیں ملی")
            } else {
                Loc.t(
                    this,
                    "Removed ${event.paymentsRemoved} duplicate payment(s). Fixed ${event.customersFixed} customer(s), ${event.suppliersFixed} supplier(s)",
                    "${event.paymentsRemoved} ڈپلیکیٹ ادائیگیاں حذف ہو گئیں۔ ${event.customersFixed} کسٹمرز اور ${event.suppliersFixed} سپلائرز کا بیلنس ٹھیک ہو گیا"
                )
            }
            Toast.makeText(this, message, Toast.LENGTH_LONG).show()
            return
        }
        // NEW (Cleanup Orphaned Payments): same two-step preview/confirm shape as
        // Cleanup Duplicate Payments above, for a different leftover — a bill-embedded
        // payment row whose purchase/sale was deleted (by an old build, before
        // deletePurchase()/deleteSale() cleaned up that row too) and never removed.
        if (event is PartyEvent.OrphanedPaymentsFound) {
            showOrphanedPaymentsPreview(event.payments)
            return
        }
        if (event is PartyEvent.OrphanedPaymentsCleaned) {
            val message = if (event.paymentsRemoved == 0) {
                Loc.t(this, "No orphaned payments found", "کوئی بے مالک ادائیگی نہیں ملی")
            } else {
                Loc.t(
                    this,
                    "Removed ${event.paymentsRemoved} orphaned payment(s). Fixed ${event.customersFixed} customer(s), ${event.suppliersFixed} supplier(s)",
                    "${event.paymentsRemoved} بے مالک ادائیگیاں حذف ہو گئیں۔ ${event.customersFixed} کسٹمرز اور ${event.suppliersFixed} سپلائرز کا بیلنس ٹھیک ہو گیا"
                )
            }
            Toast.makeText(this, message, Toast.LENGTH_LONG).show()
            return
        }
        val message = when (event) {
            PartyEvent.NameRequired -> Loc.t(this, "Name is required", "نام ضروری ہے")
            PartyEvent.Saved -> Loc.t(this, "Saved", "محفوظ ہو گیا")
            PartyEvent.Updated -> Loc.t(this, "Updated", "اپ ڈیٹ ہو گیا")
            PartyEvent.Deleted -> Loc.t(this, "Deleted", "حذف ہو گیا")
            // Both already handled (and returned from) above — these two branches only
            // exist so the `when` stays exhaustive over the sealed PartyEvent class;
            // they're unreachable in practice.
            is PartyEvent.DuplicatePaymentsFound -> return
            is PartyEvent.DuplicatePaymentsCleaned -> return
            is PartyEvent.OrphanedPaymentsFound -> return
            is PartyEvent.OrphanedPaymentsCleaned -> return
            is PartyEvent.BalancesRecalculated -> {
                val total = event.customersFixed + event.suppliersFixed
                if (total == 0) {
                    Loc.t(this, "All balances already correct", "تمام بیلنس پہلے ہی درست ہیں")
                } else {
                    Loc.t(
                        this,
                        "Fixed ${event.customersFixed} customer(s), ${event.suppliersFixed} supplier(s)",
                        "${event.customersFixed} کسٹمرز اور ${event.suppliersFixed} سپلائرز کا بیلنس ٹھیک ہو گیا"
                    )
                }
            }
            is PartyEvent.DuplicatesMerged -> {
                val total = event.customersMerged + event.suppliersMerged
                if (total == 0) {
                    Loc.t(this, "No duplicates found", "کوئی ڈپلیکیٹ نہیں ملا")
                } else {
                    Loc.t(
                        this,
                        "Merged ${event.customersMerged} customer(s), ${event.suppliersMerged} supplier(s)",
                        "${event.customersMerged} کسٹمرز اور ${event.suppliersMerged} سپلائرز ملا دیے گئے"
                    )
                }
            }
        }
        Toast.makeText(this, message, Toast.LENGTH_SHORT).show()
        if (event == PartyEvent.Saved) {
            nameField.text.clear()
            phoneField.text.clear()
            creditLimitField.text.clear()
            openingBalanceField.text.clear()
            stuckBalanceField.text.clear()
        }
    }

    // NEW (Recalculate Balances): confirmation before running — this touches every
    // customer/supplier's stored balance, so it should be a deliberate action, not
    // something a stray tap triggers.
    private fun confirmRecalculateBalances() {
        AlertDialog.Builder(this)
            .setTitle(Loc.t(this, "Recalculate Balances", "بیلنس دوبارہ شمار کریں"))
            .setMessage(
                Loc.t(
                    this,
                    "This checks every customer's and supplier's balance against their actual bills and payments, and fixes any that don't match. Continue?",
                    "یہ ہر کسٹمر اور سپلائر کا بیلنس ان کے اصل بلوں اور ادائیگیوں سے ملا کر چیک کرے گا، اور جو میل نہیں کھاتے انہیں ٹھیک کر دے گا۔ جاری رکھیں؟"
                )
            )
            .setPositiveButton(Loc.t(this, "Recalculate", "دوبارہ شمار کریں")) { _, _ -> viewModel.recalculateBalances() }
            .setNegativeButton(Loc.t(this, "Cancel", "منسوخ کریں"), null)
            .show()
    }

    // NEW (Merge Duplicate Parties): confirmation before running — this moves bills/
    // payments between rows and deletes rows, so it should be a deliberate action,
    // not something a stray tap triggers.
    private fun confirmMergeDuplicates() {
        AlertDialog.Builder(this)
            .setTitle(Loc.t(this, "Merge Duplicates", "ڈپلیکیٹ ملائیں"))
            .setMessage(
                Loc.t(
                    this,
                    "This finds customers/suppliers that share the exact same name, combines their purchase/sale history and balance into one record, and deletes the extra copy. This can't be undone. Continue?",
                    "یہ ایک جیسے نام والے کسٹمرز/سپلائرز کو ڈھونڈ کر ان کی خرید/فروخت کی تاریخ اور بیلنس ایک ریکارڈ میں ملا دے گا، اور اضافی کاپی حذف کر دے گا۔ یہ واپس نہیں ہو سکتا۔ جاری رکھیں؟"
                )
            )
            .setPositiveButton(Loc.t(this, "Merge", "ملائیں")) { _, _ -> viewModel.mergeDuplicateParties() }
            .setNegativeButton(Loc.t(this, "Cancel", "منسوخ کریں"), null)
            .show()
    }

    // NEW (Cleanup Duplicate Payments): shows exactly what "Cleanup Payments" found before
    // deleting anything — one line per party+bill listing how many stray rows and how much
    // money they add up to — so the shop owner can see it's the same old edited bills (like
    // Arfan Brothers' Rs 267,854 purchase) before confirming, not just trust a blind "Fix".
    private fun showDuplicatePaymentsPreview(groups: List<DuplicatePaymentGroup>) {
        if (groups.isEmpty()) {
            Toast.makeText(
                this,
                Loc.t(this, "No duplicate payments found", "کوئی ڈپلیکیٹ ادائیگی نہیں ملی"),
                Toast.LENGTH_SHORT
            ).show()
            return
        }
        val totalRows = groups.sumOf { it.remove.size }
        val totalAmount = groups.sumOf { g -> g.remove.sumOf { it.amount } }
        val lines = groups.joinToString("\n") { g ->
            val billLabel = g.reference.take(24)
            "• ${g.partyName} (${billLabel}) — ${g.remove.size} × Rs %.2f".format(g.remove.sumOf { it.amount } / g.remove.size)
        }
        AlertDialog.Builder(this)
            .setTitle(Loc.t(this, "Cleanup Payments", "ادائیگیاں صاف کریں"))
            .setMessage(
                Loc.t(
                    this,
                    "Found $totalRows leftover duplicate payment(s) totalling Rs %.2f:\n\n$lines\n\nEach of these is an old row a bill edit left behind before the sync fix — the one correct payment for each bill is kept, only the extra copies below are removed. Balances will be corrected afterward. This can't be undone. Continue?".format(totalAmount),
                    "بل ایڈٹ کے دوران sync fix سے پہلے رہ جانے والی $totalRows پرانی ڈپلیکیٹ ادائیگیاں ملیں، مجموعی رقم Rs %.2f:\n\n$lines\n\nہر بل کی ایک درست ادائیگی رکھی جائے گی، صرف اضافی کاپیاں حذف ہوں گی۔ اس کے بعد بیلنس ٹھیک کر دیا جائے گا۔ یہ واپس نہیں ہو سکتا۔ جاری رکھیں؟".format(totalAmount)
                )
            )
            .setPositiveButton(Loc.t(this, "Clean Up", "صاف کریں")) { _, _ -> viewModel.cleanupDuplicatePayments(groups) }
            .setNegativeButton(Loc.t(this, "Cancel", "منسوخ کریں"), null)
            .show()
    }

    // NEW (Cleanup Orphaned Payments): same preview-then-confirm shape as
    // showDuplicatePaymentsPreview above, for orphaned bill-embedded payment rows —
    // see PartyRepository.findOrphanedPayments() for what these are and why they
    // throw a party's balance the wrong direction.
    private fun showOrphanedPaymentsPreview(payments: List<com.grocerypos.v11.Payment>) {
        if (payments.isEmpty()) {
            Toast.makeText(
                this,
                Loc.t(this, "No orphaned payments found", "کوئی بے مالک ادائیگی نہیں ملی"),
                Toast.LENGTH_SHORT
            ).show()
            return
        }
        val customerNames = viewModel.uiState.value.customers.associate { it.id to it.name }
        val supplierNames = viewModel.uiState.value.suppliers.associate { it.id to it.name }
        val totalAmount = payments.sumOf { it.amount }
        val lines = payments.joinToString("\n") { p ->
            val name = (if (p.partyType == "customer") customerNames[p.partyId] else supplierNames[p.partyId]) ?: "#${p.partyId}"
            "• $name (${p.reference.take(24)}) — Rs %.2f".format(p.amount)
        }
        AlertDialog.Builder(this)
            .setTitle(Loc.t(this, "Cleanup Orphaned Payments", "بے مالک ادائیگیاں صاف کریں"))
            .setMessage(
                Loc.t(
                    this,
                    "Found ${payments.size} orphaned payment(s) totalling Rs %.2f:\n\n$lines\n\nEach of these is a bill-payment row whose purchase/sale bill was deleted by an old app version before it cleaned up this row too — it's being wrongly counted as real money, throwing that party's balance the wrong way. Balances will be corrected afterward. This can't be undone. Continue?".format(totalAmount),
                    "ان میں سے ہر ایک اس بل کی ادائیگی ہے جس کا purchase/sale پرانی ایپ ورژن سے حذف ہوا تھا مگر یہ ادائیگی حذف نہیں ہوئی — یہ غلطی سے اصل رقم شمار ہو رہی ہے اور پارٹی کا بیلنس غلط سمت دکھا رہی ہے۔ اس کے بعد بیلنس ٹھیک کر دیا جائے گا۔ یہ واپس نہیں ہو سکتا۔ جاری رکھیں؟"
                )
            )
            .setPositiveButton(Loc.t(this, "Clean Up", "صاف کریں")) { _, _ -> viewModel.cleanupOrphanedPayments(payments) }
            .setNegativeButton(Loc.t(this, "Cancel", "منسوخ کریں"), null)
            .show()
    }

    // ================= Contact picker =================
    private fun openContactPicker() {
        if (ContextCompat.checkSelfPermission(this, Manifest.permission.READ_CONTACTS)
            == PackageManager.PERMISSION_GRANTED
        ) {
            contactPickerLauncher.launch(null)
        } else {
            contactPermissionLauncher.launch(Manifest.permission.READ_CONTACTS)
        }
    }

    private fun fetchPhoneFromContact(contactUri: Uri) {
        val cursor = contentResolver.query(contactUri, null, null, null, null)
        cursor?.use {
            if (it.moveToFirst()) {
                val idIdx = it.getColumnIndex(ContactsContract.Contacts._ID)
                val hasPhoneIdx = it.getColumnIndex(ContactsContract.Contacts.HAS_PHONE_NUMBER)
                val nameIdx = it.getColumnIndex(ContactsContract.Contacts.DISPLAY_NAME)
                val contactId = if (idIdx >= 0) it.getString(idIdx) else null
                val contactName = if (nameIdx >= 0) it.getString(nameIdx) else null

                if (contactId != null && hasPhoneIdx >= 0 && it.getInt(hasPhoneIdx) > 0) {
                    val phoneCursor = contentResolver.query(
                        ContactsContract.CommonDataKinds.Phone.CONTENT_URI,
                        null,
                        "${ContactsContract.CommonDataKinds.Phone.CONTACT_ID} = ?",
                        arrayOf(contactId),
                        null
                    )
                    phoneCursor?.use { pc ->
                        if (pc.moveToFirst()) {
                            val numIdx = pc.getColumnIndex(ContactsContract.CommonDataKinds.Phone.NUMBER)
                            val number = if (numIdx >= 0) pc.getString(numIdx) else null
                            if (number != null) {
                                phoneField.setText(number.replace(Regex("[^0-9+]"), ""))
                            }
                            if (nameField.text.isNullOrBlank() && !contactName.isNullOrBlank()) {
                                nameField.setText(contactName)
                            }
                        }
                    }
                } else {
                    Toast.makeText(
                        this,
                        Loc.t(this, "No phone number for this contact", "اس رابطے کا کوئی نمبر نہیں"),
                        Toast.LENGTH_SHORT
                    ).show()
                }
            }
        }
    }

    // ---- IMPROVEMENT PACK (Party 10/10): one-tap dial from the party row. Uses
    // ACTION_DIAL (opens the dialer pre-filled) rather than ACTION_CALL, so it
    // needs no CALL_PHONE permission and the person still confirms before it
    // actually dials. ----
    private fun dialPhone(phone: String) {
        if (phone.isBlank()) return
        try {
            startActivity(Intent(Intent.ACTION_DIAL, Uri.parse("tel:$phone")))
        } catch (e: Exception) {
            Toast.makeText(this, Loc.t(this, "Couldn't open dialer", "ڈائلر نہیں کھل سکا"), Toast.LENGTH_SHORT).show()
        }
    }

    // ================= Tabs =================
    private fun buildTabs(showingCustomers: Boolean) {
        tabRow.removeAllViews()
        tabRow.addView(Button(this).apply {
            text = Loc.t(this@PartyActivity, "CUSTOMERS", "کسٹمرز")
            setTextColor(if (showingCustomers) Color.WHITE else Color.parseColor("#6B7280"))
            textSize = 12f
            background = roundedBackground(if (showingCustomers) blue else "#EEF0F7", 24)
            setLeadingIcon(R.drawable.ic_person, if (showingCustomers) "#FFFFFF" else "#6B7280", 14, 6)
            layoutParams = LinearLayout.LayoutParams(0, LinearLayout.LayoutParams.WRAP_CONTENT, 1f).apply { setMargins(0, 0, 8, 0) }
            setOnClickListener { viewModel.showCustomers() }
        })
        tabRow.addView(Button(this).apply {
            text = Loc.t(this@PartyActivity, "SUPPLIERS", "سپلائرز")
            setTextColor(if (!showingCustomers) Color.WHITE else Color.parseColor("#6B7280"))
            textSize = 12f
            background = roundedBackground(if (!showingCustomers) orange else "#EEF0F7", 24)
            setLeadingIcon(R.drawable.ic_shopping_bag, if (!showingCustomers) "#FFFFFF" else "#6B7280", 14, 6)
            layoutParams = LinearLayout.LayoutParams(0, LinearLayout.LayoutParams.WRAP_CONTENT, 1f).apply { setMargins(8, 0, 0, 0) }
            setOnClickListener { viewModel.showSuppliers() }
        })
    }

    private fun saveParty() {
        val name = nameField.text.toString()
        val phone = phoneField.text.toString()
        val limit = creditLimitField.parseMoneyOrWarn(this, "Credit Limit", "کریڈٹ حد") ?: return
        val opening = openingBalanceField.parseMoneyOrWarn(this, "Opening Balance", "افتتاحی بیلنس") ?: return
        // NEW (Stuck Balance): the box is hidden for cashiers / suppliers, but read it
        // defensively anyway — a hidden field is always empty so this is 0.0 there.
        val stuck = if (canEditStuck) stuckBalanceField.parseMoneyOrWarn(this, "Stuck Balance", "پھنسا ہوا بیلنس") ?: return else 0.0

        // ---- IMPROVEMENT PACK (Party 10/10): warn on an exact-name collision before
        // creating a second party with the same name — the #1 cause of a shop
        // splitting one customer's dues across two rows by accident. Doesn't block
        // it outright (two real people can share a name), just makes it a deliberate
        // choice instead of a silent typo. ----
        val trimmed = name.trim()
        val state = lastState
        val duplicate = if (trimmed.isNotEmpty() && state != null) {
            if (state.showingCustomers) state.customers.any { it.name.equals(trimmed, ignoreCase = true) }
            else state.suppliers.any { it.name.equals(trimmed, ignoreCase = true) }
        } else false

        if (duplicate) {
            AlertDialog.Builder(this)
                .setTitle(Loc.t(this, "Name already exists", "یہ نام پہلے سے موجود ہے"))
                .setMessage(Loc.t(
                    this,
                    "A party named \"$trimmed\" already exists. Add another one with the same name?",
                    "\"$trimmed\" نام کی ایک پارٹی پہلے سے موجود ہے۔ کیا اسی نام سے ایک اور شامل کی جائے؟"
                ))
                .setPositiveButton(Loc.t(this, "Add anyway", "پھر بھی شامل کریں")) { d, _ ->
                    viewModel.addParty(name, phone, limit, opening, stuck)
                    d.dismiss()
                }
                .setNegativeButton(Loc.t(this, "Cancel", "منسوخ کریں"), null)
                .show()
        } else {
            // ViewModel decides customer vs supplier from its own state and ignores
            // creditLimit on the supplier path, so this call doesn't need to branch.
            viewModel.addParty(name, phone, limit, opening, stuck)
        }
    }

    // ================= Premium party row card =================
    // ---- FIX ----
    // Closing-balance color must be type-aware, not a blanket "positive = red" rule:
    //   - Customer closing > 0  => customer owes the shop (receivable)  -> green (good, You'll Get)
    //   - Customer closing < 0  => shop owes the customer                -> red (You'll Give)
    //   - Supplier closing > 0  => shop owes the supplier (payable)      -> red (You'll Give)
    //   - Supplier closing < 0  => supplier owes the shop (e.g. credit)  -> green (You'll Get)
    // This mirrors the same fix applied to PartyDashboardActivity's You'll Get/You'll Give totals.
    private fun partyRow(
        name: String,
        phone: String,
        opening: Double,
        running: Double,
        accentHex: String,
        iconRes: Int,
        isCustomer: Boolean,
        onClick: () -> Unit,
        onEdit: () -> Unit,
        onDelete: () -> Unit,
        onCall: (() -> Unit)? = null,
        // NEW (Stuck Balance): 0.0 for suppliers and for almost every customer — then this
        // row looks exactly as before. Non-zero => the big figure becomes TOTAL payable and
        // the small line shows the Daily / Stuck split.
        stuck: Double = 0.0
    ): LinearLayout {
        val closing = opening + running + stuck
        val isGive = if (isCustomer) closing < 0 else closing > 0
        val outerRow = premiumCard().apply {
            orientation = LinearLayout.VERTICAL
            setPadding(18, 16, 18, 12)
        }

        val topRow = LinearLayout(this).apply {
            orientation = LinearLayout.HORIZONTAL
            gravity = Gravity.CENTER_VERTICAL
            setOnClickListener { onClick() }
        }

        topRow.addView(iconBadge(iconRes, accentHex, sizeDp = 42, iconSizeDp = 19))

        val infoCol = LinearLayout(this).apply {
            orientation = LinearLayout.VERTICAL
            setPadding(18, 0, 12, 0)
            layoutParams = LinearLayout.LayoutParams(0, LinearLayout.LayoutParams.WRAP_CONTENT, 1f)
        }
        infoCol.addView(TextView(this).apply {
            text = name
            textSize = 15f
            setTypeface(typeface, android.graphics.Typeface.BOLD)
            setTextColor(Color.parseColor("#2E3242"))
        })
        if (phone.isNotEmpty()) {
            infoCol.addView(TextView(this).apply {
                text = phone
                textSize = 12f
                setTextColor(Color.parseColor(labelGray))
            })
        }
        val balRow = LinearLayout(this).apply { orientation = LinearLayout.HORIZONTAL; setPadding(0, 6, 0, 0) }
        balRow.addView(TextView(this).apply {
            text = if (stuck != 0.0)
                Loc.t(this@PartyActivity, "Daily", "روزانہ") + ": Rs %.2f".format(opening + running) +
                    "  •  " + Loc.t(this@PartyActivity, "Stuck", "اسٹک") + ": Rs %.2f".format(stuck)
            else
                Loc.t(this@PartyActivity, "Opening", "ابتدائی") + ": Rs %.2f".format(opening)
            textSize = 11f
            setTextColor(Color.parseColor(labelGray))
            layoutParams = LinearLayout.LayoutParams(0, LinearLayout.LayoutParams.WRAP_CONTENT, 1f)
        })
        infoCol.addView(balRow)
        infoCol.addView(TextView(this).apply {
            text = Loc.t(this@PartyActivity, "Tap for full history  ›", "مکمل تاریخ کے لیے ٹیپ کریں  ›")
            textSize = 11f
            setTextColor(Color.parseColor(accentHex))
            setPadding(0, 4, 0, 0)
        })
        topRow.addView(infoCol)

        topRow.addView(TextView(this).apply {
            text = "Rs %.2f".format(closing)
            textSize = 14f
            setTypeface(typeface, android.graphics.Typeface.BOLD)
            setTextColor(Color.parseColor(if (isGive) red else green))
        })
        outerRow.addView(topRow)

        // ---- action row: edit / delete ----
        val actionDivider = View(this).apply {
            setBackgroundColor(Color.parseColor(cardBorder))
            layoutParams = LinearLayout.LayoutParams(LinearLayout.LayoutParams.MATCH_PARENT, 1).apply {
                setMargins(0, 12, 0, 8)
            }
        }
        outerRow.addView(actionDivider)

        val actionRow = LinearLayout(this).apply {
            orientation = LinearLayout.HORIZONTAL
            gravity = Gravity.END
        }
        // ---- IMPROVEMENT PACK (Party 10/10): one-tap call, only shown when a
        // phone number is actually on file. ----
        if (phone.isNotEmpty() && onCall != null) {
            actionRow.addView(actionChip(R.drawable.ic_phone, Loc.t(this@PartyActivity, "Call", "کال کریں"), green, isDelete = false) { onCall() })
            actionRow.addView(spacer(10).apply { layoutParams = LinearLayout.LayoutParams((10 * resources.displayMetrics.density).toInt(), LinearLayout.LayoutParams.WRAP_CONTENT) })
        }
        actionRow.addView(actionChip(R.drawable.ic_edit, Loc.t(this@PartyActivity, "Edit", "ترمیم"), accentHex, isDelete = false) { onEdit() })
        actionRow.addView(spacer(10).apply { layoutParams = LinearLayout.LayoutParams((10 * resources.displayMetrics.density).toInt(), LinearLayout.LayoutParams.WRAP_CONTENT) })
        actionRow.addView(actionChip(R.drawable.ic_delete, Loc.t(this@PartyActivity, "Delete", "حذف کریں"), red, isDelete = true) { onDelete() })
        outerRow.addView(actionRow)

        return outerRow
    }

    private fun actionChip(iconRes: Int, label: String, colorHex: String, isDelete: Boolean, onClick: () -> Unit): LinearLayout {
        return LinearLayout(this).apply {
            orientation = LinearLayout.HORIZONTAL
            gravity = Gravity.CENTER
            setPadding(16, 8, 16, 8)
            background = GradientDrawable().apply {
                setColor(Color.parseColor(if (isDelete) "#FDEDED" else "#EEF0FF"))
                cornerRadius = 20f
            }
            addView(ImageView(this@PartyActivity).apply {
                setImageDrawable(tintedDrawable(iconRes, colorHex, 14))
            })
            addView(TextView(this@PartyActivity).apply {
                text = "  $label"
                textSize = 12f
                setTextColor(Color.parseColor(colorHex))
                setTypeface(typeface, android.graphics.Typeface.BOLD)
            })
            setOnClickListener { onClick() }
        }
    }

    // ================= Edit dialogs =================
    private fun editCustomerDialog(c: Customer) {
        val container = LinearLayout(this).apply {
            orientation = LinearLayout.VERTICAL
            setPadding(32, 24, 32, 8)
        }
        val nameEdit = EditText(this).apply { setText(c.name); hint = Loc.t(this@PartyActivity, "Name", "نام") }
        val phoneEdit = EditText(this).apply { setText(c.phone); hint = Loc.t(this@PartyActivity, "Phone", "فون"); inputType = InputType.TYPE_CLASS_PHONE }
        val limitEdit = EditText(this).apply { setText(c.creditLimit.toString()); hint = Loc.t(this@PartyActivity, "Credit Limit", "کریڈٹ لیمٹ"); inputType = InputType.TYPE_CLASS_NUMBER or InputType.TYPE_NUMBER_FLAG_DECIMAL }
        val openingEdit = EditText(this).apply { setText(c.openingBalance.toString()); hint = Loc.t(this@PartyActivity, "Opening Balance", "ابتدائی بیلنس"); inputType = InputType.TYPE_CLASS_NUMBER or InputType.TYPE_NUMBER_FLAG_DECIMAL }
        // NEW (Stuck Balance): Admin/Manager only. Empty box = no stuck amount (or clears it).
        val stuckEdit: EditText? = if (canEditStuck) EditText(this).apply {
            setText(if (c.stuckBalance == 0.0) "" else c.stuckBalance.toString())
            hint = Loc.t(this@PartyActivity, "Stuck Balance (optional)", "اسٹک بیلنس (اختیاری)")
            inputType = InputType.TYPE_CLASS_NUMBER or InputType.TYPE_NUMBER_FLAG_DECIMAL
        } else null
        for (f in listOfNotNull(nameEdit, phoneEdit, limitEdit, openingEdit, stuckEdit)) {
            container.addView(f)
            container.addView(spacer(10))
        }

        AlertDialog.Builder(this)
            .setTitle(Loc.t(this, "Edit Customer", "کسٹمر میں ترمیم کریں"))
            .setView(container)
            .setPositiveButton(Loc.t(this, "Save", "محفوظ کریں")) { d, _ ->
                val newName = nameEdit.text.toString().trim()
                if (newName.isEmpty()) {
                    Toast.makeText(this, Loc.t(this, "Name is required", "نام ضروری ہے"), Toast.LENGTH_SHORT).show()
                    return@setPositiveButton
                }
                viewModel.editCustomer(
                    existing = c,
                    name = newName,
                    phone = phoneEdit.text.toString(),
                    creditLimit = limitEdit.text.toString().toDoubleOrNull() ?: c.creditLimit,
                    openingBalance = openingEdit.text.toString().toDoubleOrNull() ?: c.openingBalance,
                    // null (cashier: field not shown) keeps the stored stuck amount untouched.
                    stuckBalance = stuckEdit?.let {
                        it.parseMoneyOrWarn(this, "Stuck Balance", "پھنسا ہوا بیلنس") ?: return@setPositiveButton
                    }
                )
                d.dismiss()
            }
            .setNegativeButton(Loc.t(this, "Cancel", "منسوخ کریں"), null)
            .show()
    }

    private fun editSupplierDialog(s: Supplier) {
        val container = LinearLayout(this).apply {
            orientation = LinearLayout.VERTICAL
            setPadding(32, 24, 32, 8)
        }
        val nameEdit = EditText(this).apply { setText(s.name); hint = Loc.t(this@PartyActivity, "Name", "نام") }
        val phoneEdit = EditText(this).apply { setText(s.phone); hint = Loc.t(this@PartyActivity, "Phone", "فون"); inputType = InputType.TYPE_CLASS_PHONE }
        val openingEdit = EditText(this).apply { setText(s.openingBalance.toString()); hint = Loc.t(this@PartyActivity, "Opening Balance", "ابتدائی بیلنس"); inputType = InputType.TYPE_CLASS_NUMBER or InputType.TYPE_NUMBER_FLAG_DECIMAL }
        for (f in listOf(nameEdit, phoneEdit, openingEdit)) {
            container.addView(f)
            container.addView(spacer(10))
        }

        AlertDialog.Builder(this)
            .setTitle(Loc.t(this, "Edit Supplier", "سپلائر میں ترمیم کریں"))
            .setView(container)
            .setPositiveButton(Loc.t(this, "Save", "محفوظ کریں")) { d, _ ->
                val newName = nameEdit.text.toString().trim()
                if (newName.isEmpty()) {
                    Toast.makeText(this, Loc.t(this, "Name is required", "نام ضروری ہے"), Toast.LENGTH_SHORT).show()
                    return@setPositiveButton
                }
                viewModel.editSupplier(
                    existing = s,
                    name = newName,
                    phone = phoneEdit.text.toString(),
                    openingBalance = openingEdit.text.toString().toDoubleOrNull() ?: s.openingBalance
                )
                d.dismiss()
            }
            .setNegativeButton(Loc.t(this, "Cancel", "منسوخ کریں"), null)
            .show()
    }

    // ================= Delete confirmations =================
    // ---- IMPROVEMENT PACK (Party 10/10): if the party still has a non-zero
    // balance, say so — and which direction — right in the confirmation, instead
    // of a generic "cannot be undone." Deleting a party with dues doesn't touch
    // their past sales/purchases (still in history by name), but it permanently
    // drops the running-balance tracking for money still owed either way, so the
    // person should see that number before confirming, not discover it's gone. ----
    private fun confirmDeleteCustomer(c: Customer) {
        val closing = c.totalPayable()
        val message = if (closing != 0.0) {
            val direction = if (closing > 0)
                Loc.t(this, "you'll get from them", "آپ نے ان سے لینے ہیں")
            else
                Loc.t(this, "you'll give to them", "آپ نے انہیں دینے ہیں")
            Loc.t(
                this,
                "${c.name} still has an outstanding balance of Rs %.2f (%s). Deleting this customer will permanently lose track of this due. Delete anyway?".format(kotlin.math.abs(closing), direction),
                "${c.name} کا Rs %.2f (%s) کا واجب الادا بیلنس ہے۔ اس کسٹمر کو حذف کرنے سے یہ ریکارڈ ہمیشہ کے لیے ختم ہو جائے گا۔ پھر بھی حذف کریں؟".format(kotlin.math.abs(closing), direction)
            )
        } else {
            Loc.t(this, "Delete ${c.name}? This cannot be undone.", "${c.name} کو حذف کریں؟ اسے واپس نہیں لایا جا سکتا۔")
        }
        AlertDialog.Builder(this)
            .setTitle(Loc.t(this, "Delete Customer", "کسٹمر حذف کریں"))
            .setMessage(message)
            .setPositiveButton(Loc.t(this, "Delete", "حذف کریں")) { d, _ ->
                viewModel.removeCustomer(c)
                d.dismiss()
            }
            .setNegativeButton(Loc.t(this, "Cancel", "منسوخ کریں"), null)
            .show()
    }

    private fun confirmDeleteSupplier(s: Supplier) {
        val closing = s.openingBalance + s.balance
        val message = if (closing != 0.0) {
            val direction = if (closing > 0)
                Loc.t(this, "you'll give to them", "آپ نے انہیں دینے ہیں")
            else
                Loc.t(this, "you'll get from them", "آپ نے ان سے لینے ہیں")
            Loc.t(
                this,
                "${s.name} still has an outstanding balance of Rs %.2f (%s). Deleting this supplier will permanently lose track of this due. Delete anyway?".format(kotlin.math.abs(closing), direction),
                "${s.name} کا Rs %.2f (%s) کا واجب الادا بیلنس ہے۔ اس سپلائر کو حذف کرنے سے یہ ریکارڈ ہمیشہ کے لیے ختم ہو جائے گا۔ پھر بھی حذف کریں؟".format(kotlin.math.abs(closing), direction)
            )
        } else {
            Loc.t(this, "Delete ${s.name}? This cannot be undone.", "${s.name} کو حذف کریں؟ اسے واپس نہیں لایا جا سکتا۔")
        }
        AlertDialog.Builder(this)
            .setTitle(Loc.t(this, "Delete Supplier", "سپلائر حذف کریں"))
            .setMessage(message)
            .setPositiveButton(Loc.t(this, "Delete", "حذف کریں")) { d, _ ->
                viewModel.removeSupplier(s)
                d.dismiss()
            }
            .setNegativeButton(Loc.t(this, "Cancel", "منسوخ کریں"), null)
            .show()
    }

    // ================= Customer full history =================
    private fun openCustomerHistory(c: Customer) {
        lifecycleScope.launch {
            val sales = viewModel.customerHistory(c)
            // PERMANENT FIX (balance drift): live balance, not c.balance — see the
            // comment on render()'s list-building above.
            val liveRunning = viewModel.uiState.value.customerBalances[c.id] ?: 0.0
            val content = historyDialogContainer(c.name, blue, R.drawable.ic_person, c.openingBalance, liveRunning, c.stuckBalance)
            val body = content.getChildAt(1) as LinearLayout

            if (sales.isEmpty()) {
                body.addView(emptyCard(Loc.t(this@PartyActivity, "No sales yet", "ابھی تک کوئی سیل نہیں ہوئی")))
            } else {
                val fmt = SimpleDateFormat("dd MMM yyyy, hh:mm a", Locale.getDefault())
                // ---- Newest first, and no invoice/reference number shown — date is the identifier ----
                for (s in sales.sortedByDescending { it.createdAt }) {
                    body.addView(historyRow(fmt.format(Date(s.createdAt)), s.total, s.paid, blue))
                }
            }

            val dialog = AlertDialog.Builder(this@PartyActivity).setView(content).create()
            (content.getChildAt(2) as LinearLayout).addView(Button(this@PartyActivity).apply {
                text = Loc.t(this@PartyActivity, "Close", "بند کریں")
                setTextColor(Color.WHITE)
                background = roundedBackground(blue, 14)
                setOnClickListener { dialog.dismiss() }
            })
            dialog.show()
        }
    }

    // ================= Supplier full history =================
    private fun openSupplierHistory(s: Supplier) {
        lifecycleScope.launch {
            val purchases = viewModel.supplierHistory(s)
            // PERMANENT FIX (balance drift): live balance, not s.balance — see the
            // comment on render()'s list-building above.
            val liveRunning = viewModel.uiState.value.supplierBalances[s.id] ?: 0.0
            val content = historyDialogContainer(s.name, orange, R.drawable.ic_shopping_bag, s.openingBalance, liveRunning)
            val body = content.getChildAt(1) as LinearLayout

            if (purchases.isEmpty()) {
                body.addView(emptyCard(Loc.t(this@PartyActivity, "No purchases yet", "ابھی تک کوئی خریداری نہیں ہوئی")))
            } else {
                val fmt = SimpleDateFormat("dd MMM yyyy, hh:mm a", Locale.getDefault())
                // ---- Newest first, and no bill number shown — date is the identifier ----
                for (p in purchases.sortedByDescending { it.createdAt }) {
                    body.addView(historyRow(fmt.format(Date(p.createdAt)), p.total, p.paid, orange))
                }
            }

            val dialog = AlertDialog.Builder(this@PartyActivity).setView(content).create()
            (content.getChildAt(2) as LinearLayout).addView(Button(this@PartyActivity).apply {
                text = Loc.t(this@PartyActivity, "Close", "بند کریں")
                setTextColor(Color.WHITE)
                background = roundedBackground(orange, 14)
                setOnClickListener { dialog.dismiss() }
            })
            dialog.show()
        }
    }

    // ================= shared dialog helpers (premium gradient header dialog) =================
    private fun historyDialogContainer(name: String, colorHex: String, iconRes: Int, opening: Double, running: Double, stuck: Double = 0.0): LinearLayout {
        val outer = LinearLayout(this).apply {
            orientation = LinearLayout.VERTICAL
            background = GradientDrawable().apply {
                setColor(Color.parseColor(bg))
                cornerRadius = 20f
            }
        }

        val header = LinearLayout(this).apply {
            orientation = LinearLayout.HORIZONTAL
            gravity = Gravity.CENTER_VERTICAL
            setPadding(28, 24, 28, 24)
            background = GradientDrawable(
                GradientDrawable.Orientation.TL_BR,
                intArrayOf(Color.parseColor(colorHex), lighten(colorHex))
            ).apply {
                cornerRadii = floatArrayOf(20f, 20f, 20f, 20f, 0f, 0f, 0f, 0f)
            }
        }
        header.addView(iconBadge(iconRes, colorHex, bgHex = cardWhite, sizeDp = 40, iconSizeDp = 18))
        val headerTextCol = LinearLayout(this).apply {
            orientation = LinearLayout.VERTICAL
            setPadding(16, 0, 0, 0)
        }
        headerTextCol.addView(TextView(this).apply {
            text = name; textSize = 17f
            setTextColor(Color.WHITE)
            setTypeface(typeface, android.graphics.Typeface.BOLD)
        })
        val balRow = LinearLayout(this).apply { orientation = LinearLayout.HORIZONTAL; setPadding(0, 6, 0, 0) }
        // NEW (Stuck Balance): with a stuck amount the header reads Daily (left) and TOTAL
        // (right, bold) with the stuck figure on its own line; otherwise exactly as before.
        balRow.addView(TextView(this).apply {
            text = if (stuck != 0.0)
                Loc.t(this@PartyActivity, "Daily", "روزانہ") + ": Rs %.2f".format(opening + running)
            else
                Loc.t(this@PartyActivity, "Opening", "ابتدائی") + ": Rs %.2f".format(opening)
            setTextColor(Color.parseColor("#F2F3FF")); textSize = 11f
            layoutParams = LinearLayout.LayoutParams(0, LinearLayout.LayoutParams.WRAP_CONTENT, 1f)
        })
        balRow.addView(TextView(this).apply {
            text = if (stuck != 0.0)
                Loc.t(this@PartyActivity, "Total", "کل") + ": Rs %.2f".format(opening + running + stuck)
            else
                Loc.t(this@PartyActivity, "Closing", "اختتامی") + ": Rs %.2f".format(opening + running)
            setTextColor(Color.WHITE); textSize = 12f
            setTypeface(typeface, android.graphics.Typeface.BOLD)
        })
        headerTextCol.addView(balRow)
        if (stuck != 0.0) {
            headerTextCol.addView(TextView(this).apply {
                text = Loc.t(this@PartyActivity, "Stuck", "اسٹک") + ": Rs %.2f".format(stuck)
                setTextColor(Color.parseColor("#F2F3FF")); textSize = 11f
                setPadding(0, 2, 0, 0)
            })
        }
        header.addView(headerTextCol)
        outer.addView(header)

        val body = LinearLayout(this).apply {
            orientation = LinearLayout.VERTICAL
            setPadding(20, 16, 20, 8)
        }
        outer.addView(body)

        val footer = LinearLayout(this).apply {
            orientation = LinearLayout.HORIZONTAL
            setPadding(20, 8, 20, 20)
        }
        outer.addView(footer)
        return outer
    }

    // ---- No invoice/bill reference is passed in or shown anymore — just the date,
    // total, and amount paid. Date is bold since it's now the row's identifier. ----
    private fun historyRow(date: String, total: Double, paid: Double, colorHex: String): LinearLayout {
        return LinearLayout(this).apply {
            orientation = LinearLayout.VERTICAL
            setPadding(18, 14, 18, 14)
            background = elevatedCardBg()
            elevation = 2f
            layoutParams = LinearLayout.LayoutParams(
                LinearLayout.LayoutParams.MATCH_PARENT, LinearLayout.LayoutParams.WRAP_CONTENT
            ).apply { setMargins(0, 0, 0, 10) }

            val top = LinearLayout(this@PartyActivity).apply { orientation = LinearLayout.HORIZONTAL; gravity = Gravity.CENTER_VERTICAL }
            top.addView(TextView(this@PartyActivity).apply {
                text = date; textSize = 14f
                setTypeface(typeface, android.graphics.Typeface.BOLD)
                setTextColor(Color.parseColor("#2E3242"))
                layoutParams = LinearLayout.LayoutParams(0, LinearLayout.LayoutParams.WRAP_CONTENT, 1f)
            })
            top.addView(TextView(this@PartyActivity).apply {
                text = "Rs %.2f".format(total)
                setTextColor(Color.parseColor(colorHex))
                setTypeface(typeface, android.graphics.Typeface.BOLD)
                textSize = 14f
            })
            addView(top)
            addView(TextView(this@PartyActivity).apply {
                text = Loc.t(this@PartyActivity, "Paid", "ادا شدہ") + ": Rs %.2f".format(paid)
                textSize = 11f
                setTextColor(Color.parseColor(labelGray))
                setPadding(0, 4, 0, 0)
            })
        }
    }

    private fun emptyCard(text: String) = premiumCard().apply {
        gravity = Gravity.CENTER
        setPadding(20, 24, 20, 24)
        addView(TextView(this@PartyActivity).apply {
            this.text = text
            setTextColor(Color.parseColor(labelGray))
            textSize = 13f
        })
    }

    // ---- UI helpers ----

    /** Elevated white card, light premium look with soft border + shadow. */
    private fun premiumCard() = LinearLayout(this).apply {
        orientation = LinearLayout.VERTICAL
        setPadding(20, 16, 20, 16)
        background = elevatedCardBg()
        elevation = 3f
        layoutParams = LinearLayout.LayoutParams(
            LinearLayout.LayoutParams.MATCH_PARENT, LinearLayout.LayoutParams.WRAP_CONTENT
        ).apply { setMargins(0, 0, 0, 12) }
    }

    /** Lighter inner wrapper used for text fields inside a card. */
    private fun innerField() = LinearLayout(this).apply {
        orientation = LinearLayout.VERTICAL
        setPadding(18, 10, 18, 10)
        background = GradientDrawable().apply {
            setColor(Color.parseColor("#F7F8FC"))
            cornerRadius = 10f
            setStroke(1, Color.parseColor(cardBorder))
        }
        layoutParams = LinearLayout.LayoutParams(
            LinearLayout.LayoutParams.MATCH_PARENT, LinearLayout.LayoutParams.WRAP_CONTENT
        )
    }

    private fun elevatedCardBg() = GradientDrawable().apply {
        setColor(Color.parseColor(cardWhite))
        cornerRadius = 16f
        setStroke(1, Color.parseColor(cardBorder))
    }

    private fun roundedBackground(colorHex: String, cornerRadius: Int) = GradientDrawable().apply {
        setColor(Color.parseColor(colorHex))
        this.cornerRadius = cornerRadius.toFloat()
    }

    private fun lighten(colorHex: String): Int {
        val c = Color.parseColor(colorHex)
        val hsv = FloatArray(3)
        Color.colorToHSV(c, hsv)
        hsv[1] *= 0.7f
        hsv[2] = (hsv[2] * 1.15f).coerceAtMost(1f)
        return Color.HSVToColor(hsv)
    }

    private fun spacer(heightDp: Int) = View(this).apply {
        val px = (heightDp * resources.displayMetrics.density).toInt()
        layoutParams = LinearLayout.LayoutParams(LinearLayout.LayoutParams.MATCH_PARENT, px)
    }

    private fun divider(): View {
        return View(this).apply {
            setBackgroundColor(0xFFEEEEEE.toInt())
            layoutParams = LinearLayout.LayoutParams(LinearLayout.LayoutParams.MATCH_PARENT, 2)
        }
    }
}

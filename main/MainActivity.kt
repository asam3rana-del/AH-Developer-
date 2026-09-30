package com.grocerypos.v11

import android.app.AlertDialog
import android.content.Context
import android.content.Intent
import android.graphics.Color
import android.graphics.drawable.GradientDrawable
import android.os.Bundle
import android.text.Editable
import android.text.TextWatcher
import android.view.Gravity
import android.view.View
import android.widget.*
import androidx.biometric.BiometricManager
import androidx.biometric.BiometricPrompt
import androidx.core.content.ContextCompat
import androidx.lifecycle.lifecycleScope
import com.grocerypos.v11.sync.SyncWorker
import com.grocerypos.v11.data.PartyRepository
import com.grocerypos.v11.ui.LoginActivity
import com.grocerypos.v11.ui.SettingsActivity
import com.grocerypos.v11.ui.ProductActivity
import com.grocerypos.v11.ui.PurchaseActivity
import com.grocerypos.v11.ui.SaleActivity
import com.grocerypos.v11.ui.ReportsActivity
import com.grocerypos.v11.ui.CashActivity
import com.grocerypos.v11.ui.DayBookActivity
import com.grocerypos.v11.ui.BackupExportActivity
import com.grocerypos.v11.ui.PartyDashboardActivity
import com.grocerypos.v11.ui.ItemSearchActivity
import com.grocerypos.v11.ui.ItemsActivity
import com.grocerypos.v11.ui.StockReportActivity
import com.grocerypos.v11.ui.ThemedActivity
import com.grocerypos.v11.ui.components.iconBadge
import com.grocerypos.v11.util.Loc
import com.grocerypos.v11.util.ThemeManager
import kotlinx.coroutines.flow.collectLatest
import kotlinx.coroutines.flow.combine
import kotlinx.coroutines.flow.first
import kotlinx.coroutines.launch
import java.util.Calendar

class MainActivity : ThemedActivity() {

    private lateinit var todaySaleValue: TextView
    private var todayProfitValue: TextView? = null
    private var todaySaleAmount: Double = 0.0
    private var todayProfitAmount: Double = 0.0
    private var isSaleAmountHidden = false
    private var isProfitAmountHidden = false
    private var role: String = "cashier"
    private lateinit var shopNameHeader: TextView

    private lateinit var youllGetValue: TextView
    private lateinit var youllGiveValue: TextView
    private lateinit var syncPendingLabel: TextView

    private lateinit var searchResultsBox: LinearLayout
    private var allProductsCache: List<com.grocerypos.v11.Product>? = null

    // ---- Theme-dependent — swapped between light/dark by loadThemePrefs() below, sourced from
    // the app-wide ThemeManager so this screen stays in sync with every other screen. ----
    private var bgColor = "#F0F1F8"
    private var cardWhite = "#FFFFFF"
    private var textDark = "#151726"
    private var textMuted = "#8A8FA3"
    private var border = "#ECEEF6"

    // ---- Flat-minimal design tokens (app-wide redesign) — soft chip bg + matching icon/text
    // color per category, pulled from the shared ThemeManager palette. ----
    private var flatPurpleBg = "#EEEDFE"; private var flatPurpleFg = "#534AB7"
    private var flatCoralBg = "#FAECE7"; private var flatCoralFg = "#993C1D"
    private var flatBlueBg = "#E6F1FB"; private var flatBlueFg = "#185FA5"
    private var flatPinkBg = "#FBEAF0"; private var flatPinkFg = "#993556"
    private var flatTealBg = "#E1F5EE"; private var flatTealFg = "#085041"
    private var flatAmberBg = "#FAEEDA"; private var flatAmberFg = "#854F0B"

    // ---- Brand colors — get/give green & red are semantic (money owed to/by the shop) and
    // stay fixed regardless of theme; paired with a soft flat tint background for their cards. ----
    private val partyGreen = "#1B8A4A"
    private val partyGreenBg = "#EAF3DE"
    private val partyRed = "#D32F4A"
    private val partyRedBg = "#FCEBEB"
    private val headerStart = "#0D1B4C"
    private val headerMid = "#0D1B4C"
    private val headerEnd = "#14297A"
    private val goldAccent = "#FF8A00"

    // ---- Pulls this screen's theme-dependent colors from the app-wide ThemeManager (shared
    // across every activity — see ThemeManager.kt / ThemedActivity.kt). ----
    private fun loadThemePrefs() {
        val p = ThemeManager.palette(this)
        bgColor = p.bg
        cardWhite = p.cardWhite
        textDark = p.textDark
        textMuted = p.textMuted
        border = p.border
        flatPurpleBg = p.flatPurpleBg; flatPurpleFg = p.flatPurpleFg
        flatCoralBg = p.flatCoralBg; flatCoralFg = p.flatCoralFg
        flatBlueBg = p.flatBlueBg; flatBlueFg = p.flatBlueFg
        flatPinkBg = p.flatPinkBg; flatPinkFg = p.flatPinkFg
        flatTealBg = p.flatTealBg; flatTealFg = p.flatTealFg
        flatAmberBg = p.flatAmberBg; flatAmberFg = p.flatAmberFg
    }

    // ---- Flips the app-wide theme preference and recreates this activity. Any other open
    // activity that extends ThemedActivity picks up the change automatically on resume. ----
    private fun toggleTheme() {
        ThemeManager.toggleDarkMode(this)
        recreate()
    }

    override fun onCreate(b: Bundle?) {
        super.onCreate(b)

        val session = getSharedPreferences("session", MODE_PRIVATE)
        if (session.getString("username", null) == null) {
            startActivity(Intent(this@MainActivity, LoginActivity::class.java))
            finish()
            return
        }
        role = session.getString("role", "cashier") ?: "cashier"

        // NEW: starts background sync (push queued changes + pull server changes every
        // 15 minutes). Safe to call on every app start — ExistingPeriodicWorkPolicy.KEEP
        // inside SyncWorker.schedulePeriodic() means it won't duplicate or restart an
        // already-scheduled sync.
        SyncWorker.schedulePeriodic(this)

        com.grocerypos.v11.util.CrashHandler.install(this)
        com.grocerypos.v11.util.CrashHandler.getLastCrash(this)?.let { crashText -> showCrashDialog(crashText) }

        // ---- Must run before any view construction below, since header/body colors are read
        // from these vars while building the layout. ----
        loadThemePrefs()

        val root = LinearLayout(this).apply {
            orientation = LinearLayout.VERTICAL
            setBackgroundColor(Color.parseColor(bgColor))
        }

        // ================= HEADER — flat surface, no gradient (app-wide flat redesign) =================
        val header = LinearLayout(this).apply {
            orientation = LinearLayout.VERTICAL
            setPadding(26, 40, 26, 24)
            background = GradientDrawable().apply {
                setColor(Color.parseColor(cardWhite))
                cornerRadii = floatArrayOf(0f, 0f, 0f, 0f, 28f, 28f, 28f, 28f)
            }
            elevation = 0f
        }

        val topRow = LinearLayout(this).apply {
            orientation = LinearLayout.HORIZONTAL
            gravity = Gravity.CENTER_VERTICAL
        }

        topRow.addView(FrameLayout(this).apply {
            val size = (40 * resources.displayMetrics.density).toInt()
            layoutParams = LinearLayout.LayoutParams(size, size)
            val chipBg = GradientDrawable().apply {
                shape = GradientDrawable.OVAL
                setColor(Color.parseColor(flatPurpleBg))
            }
            isClickable = true
            background = android.graphics.drawable.RippleDrawable(
                android.content.res.ColorStateList.valueOf(Color.parseColor(flatPurpleFg)).withAlpha(40),
                chipBg, null
            )
            addView(ImageView(this@MainActivity).apply {
                setImageDrawable(tintedDrawable(R.drawable.ic_settings, flatPurpleFg, 17))
                scaleType = ImageView.ScaleType.CENTER
                layoutParams = FrameLayout.LayoutParams(FrameLayout.LayoutParams.MATCH_PARENT, FrameLayout.LayoutParams.MATCH_PARENT)
            })
            // Products & Reports live in Settings — reached via this gear icon, since they're
            // setup/review actions rather than daily transactional ones and don't appear as
            // dashboard cards below.
            setOnClickListener { startActivity(Intent(this@MainActivity, SettingsActivity::class.java)) }
        })

        topRow.addView(View(this).apply {
            layoutParams = LinearLayout.LayoutParams((10 * resources.displayMetrics.density).toInt(), 1)
        })

        // ---- Day/night toggle — shows the icon for the mode you'd switch TO. ----
        topRow.addView(premiumIconBadge(if (ThemeManager.isDarkMode(this)) R.drawable.ic_sun else R.drawable.ic_moon, flatAmberBg, flatAmberFg, 40, 17).apply {
            isClickable = true
            setOnClickListener { toggleTheme() }
        })

        topRow.addView(View(this).apply {
            layoutParams = LinearLayout.LayoutParams((10 * resources.displayMetrics.density).toInt(), 1)
        })

        // ---- QUICK SWITCH USER — one tap opens a list of active staff accounts
        // (Admin/Manager/Cashier); tapping a name verifies fingerprint first (falls
        // back to that user's password) and switches the session instantly, without
        // going through the full Login screen / OTP flow. ----
        topRow.addView(premiumIconBadge(R.drawable.ic_sync, flatTealBg, flatTealFg, 40, 16).apply {
            isClickable = true
            setOnClickListener { openQuickSwitchDialog() }
        })

        topRow.addView(View(this).apply { layoutParams = LinearLayout.LayoutParams(0, 1, 1f) })

        topRow.addView(LinearLayout(this).apply {
            orientation = LinearLayout.VERTICAL
            gravity = Gravity.CENTER_HORIZONTAL
            addView(premiumLogoBadge(40))
            addView(TextView(this@MainActivity).apply {
                text = role.replaceFirstChar { it.uppercase() } + " Panel"
                textSize = 9f
                setTextColor(Color.parseColor(textMuted))
                setTypeface(typeface, android.graphics.Typeface.BOLD)
                gravity = Gravity.CENTER
                setPadding(0, 5, 0, 0)
            })
        })

        header.addView(topRow)

        shopNameHeader = TextView(this).apply {
            text = "IBTISAAM Kiryana Store"
            textSize = 19.5f
            setTextColor(Color.parseColor(textDark))
            setTypeface(typeface, android.graphics.Typeface.BOLD)
            gravity = Gravity.CENTER
            setPadding(8, 16, 8, 0)
        }
        header.addView(shopNameHeader)

        header.addView(View(this).apply {
            layoutParams = LinearLayout.LayoutParams(LinearLayout.LayoutParams.MATCH_PARENT, (1.2 * resources.displayMetrics.density).toInt()).apply {
                topMargin = (16 * resources.displayMetrics.density).toInt()
            }
            setBackgroundColor(Color.parseColor(border))
        })

        root.addView(header)

        val body = LinearLayout(this).apply {
            orientation = LinearLayout.VERTICAL
            setPadding(28, 26, 28, 40)
        }

        // ================= ITEM RATE SEARCH — live, inline, no second screen =================
        body.addView(premiumSearchBar())
        searchResultsBox = LinearLayout(this).apply {
            orientation = LinearLayout.VERTICAL
            visibility = View.GONE
        }
        body.addView(searchResultsBox)
        body.addView(spacer(26))

        // ================= STAT CARDS =================
        val statsRow = LinearLayout(this).apply { orientation = LinearLayout.HORIZONTAL }

        val saleCardParts = premiumStatCard("Today's sale", flatTealBg, flatTealFg)
        val saleCardView = saleCardParts.first
        todaySaleValue = saleCardParts.second
        saleCardView.isClickable = true
        saleCardView.isFocusable = true
        saleCardView.setOnClickListener {
            isSaleAmountHidden = !isSaleAmountHidden
            updateSaleValueDisplay()
        }

        if (role == "admin") {
            val profitCardParts = premiumStatCard("Today's profit", flatBlueBg, flatBlueFg)
            val profitCardView = profitCardParts.first
            todayProfitValue = profitCardParts.second
            profitCardView.isClickable = true
            profitCardView.isFocusable = true
            profitCardView.setOnClickListener {
                isProfitAmountHidden = !isProfitAmountHidden
                updateProfitValueDisplay()
            }

            saleCardView.layoutParams = LinearLayout.LayoutParams(0, LinearLayout.LayoutParams.WRAP_CONTENT, 1f).apply { setMargins(0, 0, 9, 0) }
            profitCardView.layoutParams = LinearLayout.LayoutParams(0, LinearLayout.LayoutParams.WRAP_CONTENT, 1f).apply { setMargins(9, 0, 0, 0) }

            statsRow.addView(saleCardView)
            statsRow.addView(profitCardView)
        } else {
            saleCardView.layoutParams = LinearLayout.LayoutParams(LinearLayout.LayoutParams.MATCH_PARENT, LinearLayout.LayoutParams.WRAP_CONTENT)
            statsRow.addView(saleCardView)
        }

        body.addView(statsRow)
        body.addView(spacer(30))

        // ================= QUICK ACTIONS =================
        // Every dashboard action (Sale, Cash, Purchase, Day Book, Backup, Customers & Suppliers,
        // Logout) now renders as the same gradient quick-action card — one consistent style,
        // one tap each, instead of Sale/Cash/Purchase being "big cards" while Day Book etc.
        // were small icon tiles buried under a separate "MORE" section. Products and Reports
        // are intentionally not in this list — they're setup/review actions, reachable from
        // the ⚙️ Settings icon in the header instead.
        val quickActions = mutableListOf(
            QuickAction("Sale", "Start a new sale", R.drawable.ic_cart, flatPurpleBg, flatPurpleFg) {
                startActivity(Intent(this@MainActivity, SaleActivity::class.java))
            },
            // ---- ADDED (dashboard fit for tablet): jumps straight into the
            // existing Quick Sale dialog (SaleQuickSale.kt) instead of the full
            // New Sale screen — for fast single/couple-item counter sales.
            QuickAction("Quick Sale", "Fast single-item sale", R.drawable.ic_stopwatch, flatPurpleBg, flatPurpleFg) {
                startActivity(Intent(this@MainActivity, SaleActivity::class.java).putExtra(SaleActivity.EXTRA_OPEN_QUICK_SALE, true))
            }
        )
        // UPDATED: Purchase editing restricted to admin only (manager access removed —
        // every kind of editing in the app is now admin-only). Button hidden for manager
        // too, matching the enforcement inside PurchaseActivity itself.
        // NOTE: Purchase is added BEFORE Cash on purpose — user asked for Purchase to
        // sit in Cash's old grid position (i.e. right after Quick Sale), with Cash
        // shifting to where Purchase used to be.
        if (role == "admin") {
            quickActions.add(
                QuickAction("Purchase", "Record a purchase", R.drawable.ic_box, flatCoralBg, flatCoralFg) {
                    startActivity(Intent(this@MainActivity, PurchaseActivity::class.java))
                }
            )
        }
        quickActions.add(
            QuickAction("Cash", "Cash in / cash out", R.drawable.ic_wallet, flatAmberBg, flatAmberFg) {
                startActivity(Intent(this@MainActivity, CashActivity::class.java))
            }
        )
        // ---- IMPROVEMENT PACK (Payments 10/10): one tap straight from the home
        // screen into "Receive/Make Payment", instead of Customers & Suppliers ->
        // "+" -> Payment Received/Made -> pick party. Jumps into
        // PartyDashboardActivity with quickPayment=true, which immediately shows
        // the Received/Made chooser then the searchable party picker.
        quickActions.add(
            QuickAction("Payments", "Receive or make a payment", R.drawable.ic_bank, flatTealBg, flatTealFg) {
                startActivity(Intent(this@MainActivity, PartyDashboardActivity::class.java).putExtra("quickPayment", true))
            }
        )
        // NOTE: Customers & Suppliers moved to sit in Day book's old grid position
        // (right after Payments), per user request — with Day book shifting down
        // to where Customers & Suppliers used to be.
        quickActions.add(
            QuickAction("Customers &\nSuppliers", "Manage ledgers & dues", R.drawable.ic_people, flatPinkBg, flatPinkFg) {
                startActivity(Intent(this@MainActivity, PartyDashboardActivity::class.java))
            }
        )
        // ---- ADDED (dashboard fit for tablet): one tap into Stock Report with
        // the Low Stock filter already switched on, so restocking is a single
        // tap away from the dashboard instead of Settings > Stock Report > toggle.
        quickActions.add(
            QuickAction("Low Stock", "Items needing restock", R.drawable.ic_warning, partyRedBg, partyRed) {
                startActivity(Intent(this@MainActivity, StockReportActivity::class.java).putExtra(StockReportActivity.EXTRA_LOW_STOCK_ONLY, true))
            }
        )
        // NEW (user request 2026-09-17): Items was only reachable via Settings ->
        // Items before this, buried a level deep — added here so unit products
        // and categories (ItemsActivity's Products/Categories/Units tabs) are one
        // tap from the dashboard. No role gate, matching ItemsActivity itself
        // (Settings' own "Items" row has none either).
        quickActions.add(
            QuickAction("Items", "Products, categories & units", R.drawable.ic_list, flatBlueBg, flatBlueFg) {
                startActivity(Intent(this@MainActivity, ItemsActivity::class.java))
            }
        )
        // NEW: Backup & Reports — combined CSV + PDF export (full data or custom date range).
        // Restricted to admin/manager since it exports the entire business dataset, same
        // access level as Purchase above.
        if (role == "admin" || role == "manager") {
            quickActions.add(
                QuickAction("Backup", "Export data (CSV + PDF)", R.drawable.ic_save, flatBlueBg, flatBlueFg) {
                    startActivity(Intent(this@MainActivity, BackupExportActivity::class.java))
                }
            )
        }
        quickActions.add(
            QuickAction("Day book", "View daily ledger", R.drawable.ic_book, flatTealBg, flatTealFg) {
                startActivity(Intent(this@MainActivity, DayBookActivity::class.java))
            }
        )
        if (role == "manager" || role == "cashier") {
            quickActions.add(
                QuickAction("Logout", "Sign out of this session", R.drawable.ic_logout, partyRedBg, partyRed) { doLogout() }
            )
        }

        body.addView(sectionLabel("QUICK ACTIONS"))
        buildQuickActionRows(quickActions).forEach { row ->
            body.addView(row)
            body.addView(spacer(12))
        }
        body.addView(spacer(18))

        // ================= CUSTOMERS & SUPPLIERS — dues summary =================
        body.addView(buildCustomerSupplierSection())
        body.addView(spacer(20))

        root.addView(body)

        val scroll = ScrollView(this).apply {
            setBackgroundColor(Color.parseColor(bgColor))
            addView(root)
        }
        setContentView(scroll)

        loadDashboard()
        loadShopName()
        loadPartySummary()
        observeSyncPending()
    }

    override fun onResume() {
        super.onResume()
        loadDashboard()
        loadShopName()
        loadPartySummary()
        allProductsCache = null // refresh cache in case products changed elsewhere
    }

    private fun showCrashDialog(crashText: String) {
        AlertDialog.Builder(this)
            .setTitle(Loc.t(this, "App crashed last time", "پچھلی بار ایپ کریش ہوئی تھی"))
            .setMessage(if (crashText.length > 3000) crashText.take(3000) + "\n\n…(truncated, use Share for full text)" else crashText)
            .setPositiveButton(Loc.t(this, "Share", "شیئر کریں")) { _, _ ->
                startActivity(Intent.createChooser(com.grocerypos.v11.util.CrashHandler.shareIntent(crashText), "Share crash log"))
                com.grocerypos.v11.util.CrashHandler.clearLastCrash(this)
            }
            .setNeutralButton(Loc.t(this, "Copy", "کاپی کریں")) { _, _ ->
                val clipboard = getSystemService(Context.CLIPBOARD_SERVICE) as android.content.ClipboardManager
                clipboard.setPrimaryClip(android.content.ClipData.newPlainText("crash", crashText))
                Toast.makeText(this, Loc.t(this, "Copied", "کاپی ہو گیا"), Toast.LENGTH_SHORT).show()
            }
            .setNegativeButton(Loc.t(this, "Dismiss", "برخاست کریں")) { _, _ -> com.grocerypos.v11.util.CrashHandler.clearLastCrash(this) }
            .setCancelable(false)
            .show()
    }

    // ---- flat circular icon badge — soft tint background, no gradient/elevation — reused
    // everywhere for a consistent flat-minimal look across the dashboard. ----
    private fun tintedDrawable(iconRes: Int, tintHex: String, sizeDp: Int = 16): android.graphics.drawable.Drawable? {
        val d = ContextCompat.getDrawable(this, iconRes)?.mutate() ?: return null
        d.setTint(Color.parseColor(tintHex))
        val px = (sizeDp * resources.displayMetrics.density).toInt()
        d.setBounds(0, 0, px, px)
        return d
    }

    // ---- Now a thin wrapper around the shared iconBadge() (ui/components/MenuRow.kt) so this
    // screen's badges are pixel-identical to Settings' menu-row badges and every other screen
    // that has been migrated onto the shared component, instead of a private local copy of the
    // same oval-drawing code. bgHex/fgHex order flips vs iconBadge(iconRes, fgHex, bgHex, ...). ----
    private fun premiumIconBadge(iconRes: Int, bgHex: String, fgHex: String, sizeDp: Int, iconSizeDp: Int): ImageView =
        iconBadge(iconRes, fgHex, bgHex, sizeDp, iconSizeDp)

    // ---- flat circular logo badge — solid soft-purple fill, no gradient rings ----
    private fun premiumLogoBadge(sizeDp: Int): FrameLayout {
        val size = (sizeDp * resources.displayMetrics.density).toInt()
        return FrameLayout(this).apply {
            layoutParams = LinearLayout.LayoutParams(size, size)
            background = GradientDrawable().apply {
                shape = GradientDrawable.OVAL
                setColor(Color.parseColor(flatPurpleBg))
            }
            addView(TextView(this@MainActivity).apply {
                text = "IK"
                textSize = 13f
                setTextColor(Color.parseColor(flatPurpleFg))
                setTypeface(typeface, android.graphics.Typeface.BOLD)
                gravity = Gravity.CENTER
                layoutParams = FrameLayout.LayoutParams(FrameLayout.LayoutParams.MATCH_PARENT, FrameLayout.LayoutParams.MATCH_PARENT)
            })
        }
    }

    // ---- live search bar: typing filters products immediately and results render right below,
    // no second search screen involved. Tapping a result opens Item Rate Search prefilled with
    // that exact product, so it shows the result directly with no retyping needed. ----
    private fun premiumSearchBar(): LinearLayout {
        val row = LinearLayout(this)
        val input = EditText(this).apply {
            hint = "Search Item Rate…"
            textSize = 14.5f
            setTextColor(Color.parseColor(textDark))
            setHintTextColor(Color.parseColor(textMuted))
            setTypeface(typeface, android.graphics.Typeface.BOLD)
            background = null
            isSingleLine = true
            layoutParams = LinearLayout.LayoutParams(0, LinearLayout.LayoutParams.WRAP_CONTENT, 1f)
        }

        row.apply {
            orientation = LinearLayout.HORIZONTAL
            gravity = Gravity.CENTER_VERTICAL
            setPadding(20, 16, 20, 16)
            elevation = 8f
            background = roundedBackgroundBordered(cardWhite, 30)

            // FIX (crash — ClassCastException: ViewGroup$LayoutParams cannot be cast to
            // LinearLayout$LayoutParams): premiumIconBadge() (→ iconBadge() in MenuRow.kt)
            // sets a plain ViewGroup.LayoutParams on the icon view. The old code cast that
            // straight to LinearLayout.LayoutParams INSIDE the .apply{} block that builds
            // addView()'s argument — which runs BEFORE addView() itself, so at that point
            // the view still had its original ViewGroup.LayoutParams and the cast crashed
            // on every launch. addView() itself is what converts a child's incompatible
            // LayoutParams to the parent's type (LinearLayout.generateLayoutParams()), so
            // the icon must be added FIRST — only then does its layoutParams actually
            // become a real LinearLayout.LayoutParams that's safe to cast and set margins on.
            val searchIcon = premiumIconBadge(R.drawable.ic_search, flatTealBg, flatTealFg, 36, 16)
            addView(searchIcon)
            (searchIcon.layoutParams as LinearLayout.LayoutParams).setMargins(0, 0, 14, 0)
            addView(input)
        }

        input.addTextChangedListener(object : TextWatcher {
            override fun beforeTextChanged(s: CharSequence?, start: Int, count: Int, after: Int) {}
            override fun onTextChanged(s: CharSequence?, start: Int, before: Int, count: Int) {}
            override fun afterTextChanged(s: Editable?) {
                runItemSearch(s?.toString().orEmpty())
            }
        })

        return row
    }

    // Filters the product list as the user types and renders matches directly under the search
    // bar. Tapping a match now passes that product's id + name to ItemSearchActivity, which
    // opens straight into that item's rate history — no need to type the name again there.
    private fun runItemSearch(query: String) {
        val trimmed = query.trim()
        if (trimmed.isEmpty()) {
            searchResultsBox.removeAllViews()
            searchResultsBox.visibility = View.GONE
            return
        }
        lifecycleScope.launch {
            val products = allProductsCache ?: PosDatabase.get(this@MainActivity).productDao().all().first().also { allProductsCache = it }
            val matches = products.filter { it.matchesQuery(trimmed) }.take(6)

            searchResultsBox.removeAllViews()
            if (matches.isEmpty()) {
                searchResultsBox.addView(TextView(this@MainActivity).apply {
                    text = "No matching items"
                    textSize = 13f
                    setTextColor(Color.parseColor(textMuted))
                    setPadding(24, 18, 24, 18)
                })
            } else {
                matches.forEachIndexed { index, product ->
                    searchResultsBox.addView(LinearLayout(this@MainActivity).apply {
                        orientation = LinearLayout.HORIZONTAL
                        gravity = Gravity.CENTER_VERTICAL
                        setPadding(22, 16, 22, 16)
                        isClickable = true
                        background = android.graphics.drawable.RippleDrawable(
                            android.content.res.ColorStateList.valueOf(Color.parseColor(headerEnd)).withAlpha(25),
                            null, null
                        )
                        addView(TextView(this@MainActivity).apply {
                            text = product.name
                            textSize = 13.5f
                            setTextColor(Color.parseColor(textDark))
                            setTypeface(typeface, android.graphics.Typeface.BOLD)
                            layoutParams = LinearLayout.LayoutParams(0, LinearLayout.LayoutParams.WRAP_CONTENT, 1f)
                        })
                        addView(TextView(this@MainActivity).apply {
                            text = "Rs %.2f".format(product.salePrice)
                            textSize = 13.5f
                            setTextColor(Color.parseColor("#1257C4"))
                            setTypeface(typeface, android.graphics.Typeface.BOLD)
                        })
                        setOnClickListener {
                            val intent = Intent(this@MainActivity, ItemSearchActivity::class.java)
                            intent.putExtra("product_barcode", product.barcode)
                            intent.putExtra("product_name", product.name)
                            startActivity(intent)
                        }
                    })
                    if (index != matches.lastIndex) {
                        searchResultsBox.addView(View(this@MainActivity).apply {
                            layoutParams = LinearLayout.LayoutParams(LinearLayout.LayoutParams.MATCH_PARENT, 1).apply {
                                leftMargin = 22; rightMargin = 22
                            }
                            setBackgroundColor(Color.parseColor(border))
                        })
                    }
                }
            }
            searchResultsBox.background = roundedBackgroundBordered(cardWhite, 20)
            searchResultsBox.elevation = 6f
            val m = LinearLayout.LayoutParams(LinearLayout.LayoutParams.MATCH_PARENT, LinearLayout.LayoutParams.WRAP_CONTENT)
            m.topMargin = (8 * resources.displayMetrics.density).toInt()
            searchResultsBox.layoutParams = m
            searchResultsBox.visibility = View.VISIBLE
        }
    }

    private fun sectionLabel(text: String): TextView = TextView(this).apply {
        this.text = text
        textSize = 12.5f
        setTextColor(Color.parseColor(textMuted))
        setTypeface(typeface, android.graphics.Typeface.BOLD)
        letterSpacing = 0.06f
        setPadding(4, 0, 0, 14)
    }

    // ---- responsive column count: phones stay at the original 2-per-row, but a tablet
    // (or a phone in landscape) has enough width to show 3 or 4 cards per row instead of
    // wasting space with two oversized cards — recalculated fresh every onCreate(), so it
    // adapts automatically on rotation or when opened on a different device. ----
    private fun dashboardColumns(): Int {
        val widthDp = resources.configuration.screenWidthDp
        return when {
            widthDp >= 900 -> 4   // large tablet / landscape tablet
            widthDp >= 600 -> 3   // tablet portrait / small tablet
            else -> 2             // phone (unchanged from before)
        }
    }

    // ---- lays out quick-action cards N per row, N coming from dashboardColumns() above —
    // this is now the ONE layout pattern for every dashboard action, on any screen size. A
    // short last row is padded with invisible spacers (same weight) so its cards stay the
    // same size as the rows above instead of stretching to fill the leftover space. ----
    private fun buildQuickActionRows(actions: List<QuickAction>): List<LinearLayout> {
        val columns = dashboardColumns()
        return actions.chunked(columns).map { group ->
            LinearLayout(this).apply {
                orientation = LinearLayout.HORIZONTAL
                group.forEachIndexed { index, action ->
                    val leftMargin = if (index == 0) 0 else 9
                    val rightMargin = if (index == group.size - 1) 0 else 9
                    addView(quickActionCard(action).apply {
                        layoutParams = LinearLayout.LayoutParams(0, LinearLayout.LayoutParams.WRAP_CONTENT, 1f).apply {
                            setMargins(leftMargin, 0, rightMargin, 0)
                        }
                    })
                }
                if (group.size < columns) {
                    repeat(columns - group.size) {
                        addView(View(this@MainActivity).apply {
                            layoutParams = LinearLayout.LayoutParams(0, LinearLayout.LayoutParams.WRAP_CONTENT, 1f)
                        })
                    }
                }
            }
        }
    }

    private fun quickActionCard(action: QuickAction): LinearLayout {
        return LinearLayout(this).apply {
            orientation = LinearLayout.VERTICAL
            gravity = Gravity.START
            setPadding(18, 20, 18, 20)
            val base = roundedBackgroundBordered(cardWhite, 22)
            background = android.graphics.drawable.RippleDrawable(
                android.content.res.ColorStateList.valueOf(Color.parseColor(textMuted)).withAlpha(40),
                base, base
            )
            isClickable = true
            isFocusable = true

            addView(iconBadge(action.iconRes, action.fgHex, action.bgHex, 36, 16).apply {
                layoutParams = LinearLayout.LayoutParams(
                    (36 * resources.displayMetrics.density).toInt(),
                    (36 * resources.displayMetrics.density).toInt()
                ).apply { bottomMargin = 14 }
            })
            addView(TextView(this@MainActivity).apply {
                text = action.title
                textSize = 14.5f
                setTextColor(Color.parseColor(textDark))
                setTypeface(typeface, android.graphics.Typeface.BOLD)
            })
            addView(TextView(this@MainActivity).apply {
                text = action.subtitle
                textSize = 11f
                setTextColor(Color.parseColor(textMuted))
                setPadding(0, 3, 0, 0)
            })

            setOnClickListener { action.onClick() }
        }
    }

    // ---- dues summary only now (the "View All ›" navigation link + Customers & Suppliers
    // itself moved into the Quick Actions cards above, so this section is purely the two
    // You'll Get / You'll Give stat numbers). ----
    private fun buildCustomerSupplierSection(): LinearLayout {
        val section = LinearLayout(this).apply { orientation = LinearLayout.VERTICAL }

        section.addView(TextView(this).apply {
            text = "DUES SUMMARY"
            textSize = 12.5f
            setTextColor(Color.parseColor(textMuted))
            setTypeface(typeface, android.graphics.Typeface.BOLD)
            letterSpacing = 0.06f
            setPadding(4, 0, 0, 14)
        })

        val row = LinearLayout(this).apply { orientation = LinearLayout.HORIZONTAL }

        val getCardParts = premiumStatCard("You'll get", partyGreenBg, partyGreen)
        val giveCardParts = premiumStatCard("You'll give", partyRedBg, partyRed)
        youllGetValue = getCardParts.second
        youllGiveValue = giveCardParts.second

        val getCardView = getCardParts.first.apply {
            layoutParams = LinearLayout.LayoutParams(0, LinearLayout.LayoutParams.WRAP_CONTENT, 1f).apply { setMargins(0, 0, 9, 0) }
            isClickable = true
            setOnClickListener { startActivity(Intent(this@MainActivity, PartyDashboardActivity::class.java)) }
        }
        val giveCardView = giveCardParts.first.apply {
            layoutParams = LinearLayout.LayoutParams(0, LinearLayout.LayoutParams.WRAP_CONTENT, 1f).apply { setMargins(9, 0, 0, 0) }
            isClickable = true
            setOnClickListener { startActivity(Intent(this@MainActivity, PartyDashboardActivity::class.java)) }
        }

        row.addView(getCardView)
        row.addView(giveCardView)
        section.addView(row)

        // ADDED (leaking payable follow-up): "Already up to date" only means nothing
        // NEW arrived in this check — it says nothing about whether an earlier change
        // made on THIS device ever actually reached the cloud. A shop running two
        // devices has no other way to notice that gap until the two dues totals have
        // already drifted apart. This small line surfaces the local sync_queue's
        // unsynced-row count right on the dashboard, next to the numbers it could be
        // silently affecting, and taps straight into Settings > Sync History to fix it.
        syncPendingLabel = TextView(this).apply {
            textSize = 12f
            setTextColor(Color.parseColor(partyRed))
            setPadding(4, 10, 4, 0)
            visibility = android.view.View.GONE
            setOnClickListener { startActivity(Intent(this@MainActivity, SettingsActivity::class.java)) }
        }
        section.addView(syncPendingLabel)

        return section
    }

    private fun observeSyncPending() {
        lifecycleScope.launch {
            PosDatabase.get(this@MainActivity).syncQueueDao().pendingCountFlow().collectLatest { count ->
                if (count > 0) {
                    syncPendingLabel.text = Loc.t(
                        this@MainActivity,
                        "⚠ $count change(s) not yet synced to cloud — tap to check Sync History",
                        "⚠ $count تبدیلیاں ابھی کلاؤڈ پر نہیں پہنچیں — چیک کرنے کے لیے ٹیپ کریں"
                    )
                    syncPendingLabel.visibility = android.view.View.VISIBLE
                } else {
                    syncPendingLabel.visibility = android.view.View.GONE
                }
            }
        }
    }

    private fun loadPartySummary() {
        lifecycleScope.launch {
            val db = PosDatabase.get(this@MainActivity)
            combine(db.customerDao().all(), db.supplierDao().all()) { customers, suppliers ->
                Pair(customers, suppliers)
            }.collectLatest { (customers, suppliers) ->
                // PERMANENT FIX (balance drift — "paid supplier still shows You'll Get"):
                // closings computed from PartyRepository's live ledger balances, not the
                // stored, driftable .balance field / totalPayable(). See
                // PartyRepository.liveCustomerBalances() for why.
                val partyRepo = PartyRepository(db, applicationContext)
                val liveCustomerBal = partyRepo.liveCustomerBalances()
                val liveSupplierBal = partyRepo.liveSupplierBalances()
                val customerClosings = customers.map { it.openingBalance + (liveCustomerBal[it.id] ?: 0.0) + it.stuckBalance }
                val supplierClosings = suppliers.map { it.openingBalance + (liveSupplierBal[it.id] ?: 0.0) }

                val getFromCustomers = customerClosings.filter { it > 0 }.sumOf { it }
                val giveFromCustomers = customerClosings.filter { it < 0 }.sumOf { -it }

                val giveFromSuppliers = supplierClosings.filter { it > 0 }.sumOf { it }
                val getFromSuppliers = supplierClosings.filter { it < 0 }.sumOf { -it }

                val youllGet = getFromCustomers + getFromSuppliers
                val youllGive = giveFromCustomers + giveFromSuppliers

                youllGetValue.text = "Rs %.2f".format(youllGet)
                youllGiveValue.text = "Rs %.2f".format(youllGive)
            }
        }
    }

    private fun loadShopName() {
        lifecycleScope.launch {
            val savedName = PosDatabase.get(this@MainActivity).appSettingDao().get("shop_name")?.value
            if (!savedName.isNullOrBlank()) shopNameHeader.text = savedName
        }
    }

    private fun doLogout() {
        getSharedPreferences("session", MODE_PRIVATE).edit().clear().apply()
        val intent = Intent(this@MainActivity, LoginActivity::class.java).apply {
            flags = Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_CLEAR_TASK
        }
        startActivity(intent)
        finish()
    }

    // ================= QUICK SWITCH USER =================
    // List of every active staff account, tap-to-switch — a fast alternative to Logout +
    // full Login screen when the person handing the counter over is just changing who's
    // ringing up sales (Admin/Manager/Cashier). Each switch still requires proving it's
    // really that person: fingerprint is tried first, password is always the fallback.
    private fun openQuickSwitchDialog() {
        lifecycleScope.launch {
            val users = PosDatabase.get(this@MainActivity).userDao().all().first().filter { it.active }
            if (users.isEmpty()) return@launch

            val myUsername = getSharedPreferences("session", MODE_PRIVATE).getString("username", "")

            val list = LinearLayout(this@MainActivity).apply {
                orientation = LinearLayout.VERTICAL
                setPadding(12, 8, 12, 8)
            }
            val dialog = AlertDialog.Builder(this@MainActivity)
                .setTitle("Switch User")
                .setView(ScrollView(this@MainActivity).apply { addView(list) })
                .setNegativeButton("Cancel", null)
                .create()

            users.forEach { user ->
                list.addView(quickSwitchRow(user, user.username == myUsername) {
                    dialog.dismiss()
                    attemptQuickSwitch(user)
                })
                list.addView(spacer(8))
            }
            dialog.show()
        }
    }

    private fun quickSwitchRow(user: User, isCurrent: Boolean, onTap: () -> Unit): LinearLayout {
        val roleColor = when (user.role) {
            "admin" -> "#0D1B4C"
            "manager" -> "#2F6FED"
            else -> "#FF8A00"
        }
        return LinearLayout(this).apply {
            orientation = LinearLayout.HORIZONTAL
            gravity = Gravity.CENTER_VERTICAL
            setPadding(18, 16, 18, 16)
            background = roundedBackgroundBordered(cardWhite, 14)
            isClickable = !isCurrent
            if (!isCurrent) setOnClickListener { onTap() }
            alpha = if (isCurrent) 0.55f else 1f

            addView(TextView(this@MainActivity).apply {
                text = user.displayName.take(1).uppercase()
                textSize = 15f
                setTextColor(Color.WHITE)
                gravity = Gravity.CENTER
                setTypeface(typeface, android.graphics.Typeface.BOLD)
                background = GradientDrawable().apply {
                    shape = GradientDrawable.OVAL
                    setColor(Color.parseColor(roleColor))
                }
                val px = (38 * resources.displayMetrics.density).toInt()
                layoutParams = android.view.ViewGroup.LayoutParams(px, px)
            })
            addView(View(this@MainActivity).apply {
                layoutParams = LinearLayout.LayoutParams((14 * resources.displayMetrics.density).toInt(), 1)
            })
            addView(LinearLayout(this@MainActivity).apply {
                orientation = LinearLayout.VERTICAL
                layoutParams = LinearLayout.LayoutParams(0, LinearLayout.LayoutParams.WRAP_CONTENT, 1f)
                addView(TextView(this@MainActivity).apply {
                    text = if (isCurrent) "${user.displayName} (Current)" else user.displayName
                    textSize = 14f
                    setTextColor(Color.parseColor(textDark))
                    setTypeface(typeface, android.graphics.Typeface.BOLD)
                })
                addView(TextView(this@MainActivity).apply {
                    text = user.role.replaceFirstChar { it.uppercase() }
                    textSize = 11.5f
                    setTextColor(Color.parseColor(roleColor))
                    setPadding(0, 2, 0, 0)
                })
            })
            if (!isCurrent) {
                addView(TextView(this@MainActivity).apply {
                    text = "›"
                    textSize = 18f
                    setTextColor(Color.parseColor(textMuted))
                })
            }
        }
    }

    // Fingerprint first; falls back to that user's own password if fingerprint isn't set
    // up on this device, or if the person cancels/fails the prompt.
    private fun attemptQuickSwitch(user: User) {
        val biometricManager = BiometricManager.from(this)
        val canAuthenticate = biometricManager.canAuthenticate(BiometricManager.Authenticators.BIOMETRIC_STRONG)

        if (canAuthenticate != BiometricManager.BIOMETRIC_SUCCESS) {
            askPasswordForSwitch(user)
            return
        }

        val executor = ContextCompat.getMainExecutor(this)
        val biometricPrompt = BiometricPrompt(
            this, executor,
            object : BiometricPrompt.AuthenticationCallback() {
                override fun onAuthenticationSucceeded(result: BiometricPrompt.AuthenticationResult) {
                    super.onAuthenticationSucceeded(result)
                    completeQuickSwitch(user)
                }

                override fun onAuthenticationError(errorCode: Int, errString: CharSequence) {
                    super.onAuthenticationError(errorCode, errString)
                    // Cancelled / failed to open / "Use Password" tapped — password
                    // fallback picks up from here either way.
                    askPasswordForSwitch(user)
                }

                override fun onAuthenticationFailed() {
                    super.onAuthenticationFailed()
                    Toast.makeText(this@MainActivity, "Fingerprint match nahi hua, dobara try karein", Toast.LENGTH_SHORT).show()
                }
            }
        )

        val promptInfo = BiometricPrompt.PromptInfo.Builder()
            .setTitle("Fingerprint Verify Karein")
            .setSubtitle("${user.displayName} ke account par switch karne ke liye")
            .setNegativeButtonText("Password Use Karein")
            .setAllowedAuthenticators(BiometricManager.Authenticators.BIOMETRIC_STRONG)
            .build()

        biometricPrompt.authenticate(promptInfo)
    }

    private fun askPasswordForSwitch(user: User) {
        val passwordField = EditText(this).apply {
            hint = "${user.displayName} ka password"
            inputType = android.text.InputType.TYPE_CLASS_TEXT or android.text.InputType.TYPE_TEXT_VARIATION_PASSWORD
            setPadding(28, 22, 28, 22)
        }
        AlertDialog.Builder(this)
            .setTitle("Password Verify Karein")
            .setView(passwordField)
            .setPositiveButton("Switch") { _, _ ->
                val typed = passwordField.text.toString()
                lifecycleScope.launch {
                    // FIX: same backward-compat check as LoginActivity — PasswordHasher.verify()
                    // always returns false for a still-plain-text passwordHash (pre-hashing-update
                    // accounts, e.g. the seeded admin), so it can't be the only check here or a
                    // correct password would always be rejected as "Ghalat password".
                    val passwordOk = if (PasswordHasher.isHashed(user.passwordHash)) {
                        PasswordHasher.verify(typed, user.passwordHash)
                    } else {
                        user.passwordHash == typed
                    }
                    if (passwordOk) {
                        if (!PasswordHasher.isHashed(user.passwordHash)) {
                            val migrated = user.copy(passwordHash = PasswordHasher.hash(typed))
                            PosDatabase.get(this@MainActivity).userDao().upsert(migrated)
                            SyncQueueHelper.enqueueUser(PosDatabase.get(this@MainActivity), migrated, this@MainActivity)
                        }
                        completeQuickSwitch(user)
                    } else {
                        Toast.makeText(this@MainActivity, "Ghalat password", Toast.LENGTH_SHORT).show()
                    }
                }
            }
            .setNegativeButton("Cancel", null)
            .show()
    }

    private fun completeQuickSwitch(user: User) {
        getSharedPreferences("session", MODE_PRIVATE).edit()
            .putString("username", user.username)
            .putString("role", user.role)
            .apply()
        Toast.makeText(this, "${user.displayName} par switch ho gaya", Toast.LENGTH_SHORT).show()
        // Simplest correct refresh: re-run onCreate (same pattern used by toggleTheme()
        // above) so every role-gated button/card on this screen rebuilds against the
        // new session instead of drifting out of sync.
        recreate()
    }

    private data class QuickAction(val title: String, val subtitle: String, val iconRes: Int, val bgHex: String, val fgHex: String, val onClick: () -> Unit)

    private fun premiumStatCard(label: String, tintBgHex: String, tintFgHex: String): Pair<LinearLayout, TextView> {
        val card = LinearLayout(this).apply {
            orientation = LinearLayout.VERTICAL
            setPadding(24, 20, 24, 20)
            background = GradientDrawable().apply {
                setColor(Color.parseColor(tintBgHex))
                cornerRadius = 26f
            }
        }
        card.addView(TextView(this).apply {
            text = label
            setTextColor(Color.parseColor(tintFgHex))
            textSize = 12.5f
        })
        val valueText = TextView(this).apply {
            text = "Rs 0.00"
            setTextColor(Color.parseColor(tintFgHex))
            textSize = 22f
            setTypeface(typeface, android.graphics.Typeface.BOLD)
            setPadding(0, 6, 0, 0)
        }
        card.addView(valueText)
        return Pair(card, valueText)
    }

    // ---- Tap-to-hide/unhide for the dashboard stat cards. Tapping a card toggles the
    // amount between its real value and a masked placeholder, without re-querying the DB.
    private fun updateSaleValueDisplay() {
        todaySaleValue.text = if (isSaleAmountHidden) "Rs ••••••" else "Rs %.2f".format(todaySaleAmount)
    }

    private fun updateProfitValueDisplay() {
        todayProfitValue?.text = if (isProfitAmountHidden) "Rs ••••••" else "Rs %.2f".format(todayProfitAmount)
    }

    private fun spacer(heightPx: Int) = View(this).apply {
        layoutParams = LinearLayout.LayoutParams(LinearLayout.LayoutParams.MATCH_PARENT, heightPx)
    }

    // ---- FIX (Today's Profit bug): previously used SaleDao.profitBetween(), which sums
    // (sale_items.amount - sale_items.cost). sale_items.amount is the pre-discount line
    // total (qty * unitPrice) — it is NEVER reduced when a bill-level discount is applied
    // in SaleActivity (only sales.total is discount-adjusted). So any sale with a discount
    // made profitBetween() overstate profit by the discount amount, which is why "Today's
    // Profit" could show a suspiciously high number/margin compared to "Today's Sale".
    //
    // Now computed the same way ReportsActivity's "Gross Profit" already does it —
    // Total Sales (discount-adjusted, from totalSalesBetween()) minus COGS (from
    // cogsBetween(), which only sums sale_items.cost and is unaffected by discount) —
    // so the dashboard number always agrees with the Reports screen and reflects discounts.
    private fun loadDashboard() {
        lifecycleScope.launch {
            val db = PosDatabase.get(this@MainActivity)

            val cal = Calendar.getInstance()
            cal.set(Calendar.HOUR_OF_DAY, 0); cal.set(Calendar.MINUTE, 0)
            cal.set(Calendar.SECOND, 0); cal.set(Calendar.MILLISECOND, 0)
            val startOfDay = cal.timeInMillis
            val endOfDay = startOfDay + 24 * 60 * 60 * 1000L

            val todaySale = db.saleDao().totalSalesBetween(startOfDay, endOfDay)
            todaySaleAmount = todaySale
            updateSaleValueDisplay()

            if (role == "admin") {
                val cogs = db.saleDao().cogsBetween(startOfDay, endOfDay)
                val todayProfit = todaySale - cogs
                todayProfitAmount = todayProfit
                updateProfitValueDisplay()
            }
        }
    }

    // ---- Fixed: stroke width is now density-scaled (matches the rest of the app's dp-based
    // sizing) instead of a hardcoded 2px, so card borders look consistent across screen densities. ----
    private fun roundedBackgroundBordered(colorHex: String, cornerRadius: Int, strokeColorHex: String = border): GradientDrawable {
        return GradientDrawable().apply {
            setColor(Color.parseColor(colorHex))
            this.cornerRadius = cornerRadius.toFloat()
            setStroke((1.2 * resources.displayMetrics.density).toInt(), Color.parseColor(strokeColorHex))
        }
    }

    private fun lighten(hex: String, factor: Float): Int {
        val base = Color.parseColor(hex)
        val r = (Color.red(base) + (255 - Color.red(base)) * factor).toInt()
        val g = (Color.green(base) + (255 - Color.green(base)) * factor).toInt()
        val b = (Color.blue(base) + (255 - Color.blue(base)) * factor).toInt()
        return Color.rgb(r.coerceIn(0, 255), g.coerceIn(0, 255), b.coerceIn(0, 255))
    }

    private fun darken(hex: String, factor: Float): Int {
        val base = Color.parseColor(hex)
        val r = (Color.red(base) * (1 - factor)).toInt()
        val g = (Color.green(base) * (1 - factor)).toInt()
        val b = (Color.blue(base) * (1 - factor)).toInt()
        return Color.rgb(r.coerceIn(0, 255), g.coerceIn(0, 255), b.coerceIn(0, 255))
    }
}

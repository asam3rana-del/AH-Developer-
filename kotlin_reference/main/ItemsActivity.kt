package com.grocerypos.v11.ui

import android.content.Intent
import android.graphics.Color
import android.graphics.Typeface
import android.graphics.drawable.GradientDrawable
import android.text.Editable
import android.text.TextWatcher
import android.os.Bundle
import android.view.Gravity
import android.view.View
import android.view.ViewGroup
import android.widget.EditText
import android.widget.FrameLayout
import android.widget.ImageView
import android.widget.LinearLayout
import android.widget.HorizontalScrollView
import android.widget.TextView
import android.widget.Toast
import androidx.activity.result.ActivityResultLauncher
import androidx.activity.result.contract.ActivityResultContracts
import androidx.appcompat.app.AlertDialog
import androidx.appcompat.app.AppCompatActivity
import androidx.lifecycle.lifecycleScope
import androidx.recyclerview.widget.RecyclerView
import com.grocerypos.v11.Category
import com.grocerypos.v11.PosDatabase
import com.grocerypos.v11.Product
import com.grocerypos.v11.SyncQueueHelper
import com.grocerypos.v11.R
import com.grocerypos.v11.UnitType
import com.grocerypos.v11.formatStockBreakdown
import com.grocerypos.v11.matchesQuery
import kotlinx.coroutines.flow.collectLatest
import kotlinx.coroutines.launch
import com.grocerypos.v11.ui.components.*

/**
 * "Items" hub — three tabs: Products, Categories, Units.
 * Each tab has its own search box, list, and a floating "+ Add ..." button.
 *
 * Categories tab now supports drilling into a category (tap the row) to see
 * every product inside it, with per-product Edit / Change Category / Delete
 * actions, plus Edit (rename) and Delete on the category row itself.
 */
class ItemsActivity : ThemedActivity() {

    // ================= PREMIUM COLOR PALETTE (matches Settings / Product) =================
    // Pulled from ThemeManager so this screen respects dark mode.
    // CHANGED (user asked: main brand color across Sale/Purchase/Items/Settings/
    // Reports should match the "Today's profit" blue on the dashboard): Items'
    // primary accent now pulls flatBlueFg instead of flatPurpleFg.
    private var bg = "#F4F5F9"
    private var cardBg = "#FFFFFF"
    private var primary = "#1450C7"
    private var primaryDark = "#1450C7"
    private var red = "#E5484D"
    private var redDark = "#E5484D"
    private var purple = "#1450C7"
    private var amber = "#B85C00"
    private var teal = "#0F9B8E"
    private var textDark = "#14162B"
    private var textGray = "#7C8798"
    private var border = "#E7E9F2"

    private fun loadThemeColors() {
        val p = com.grocerypos.v11.util.ThemeManager.palette(this)
        bg = p.bg
        cardBg = p.cardWhite
        primary = p.flatBlueFg
        primaryDark = p.flatBlueFg
        red = p.red
        redDark = p.red
        purple = p.flatBlueFg
        amber = p.flatAmberFg
        teal = p.flatTealFg
        textDark = p.textDark
        textGray = p.textMuted
        border = p.border
    }

    private enum class Tab { PRODUCTS, CATEGORIES, UNITS }
    private var currentTab = Tab.PRODUCTS

    private var allProducts: List<Product> = emptyList()
    private var allCategories: List<Category> = emptyList()
    private var allUnits: List<UnitType> = emptyList()
    private var searchQuery = ""

    // ---- NEW: category drill-down state. When non-null, Categories tab shows
    // that category's products instead of the category list. "" (empty string)
    // means the special "Items Not in Any Category" bucket. ----
    private var openCategoryName: String? = null

    private lateinit var tabRow: LinearLayout
    private lateinit var productsTabBtn: TextView
    private lateinit var categoriesTabBtn: TextView
    private lateinit var unitsTabBtn: TextView
    private lateinit var searchField: EditText
    // ---- Item #2 (RecyclerView migration): was a LinearLayout that render*()
    // functions addView()'d rows into directly; now a RecyclerView backed by
    // the shared ViewListAdapter (see UiHelpers.kt), so only on-screen rows
    // across all three tabs get inflated instead of the whole list living as
    // permanent child views. ----
    private lateinit var listContainer: RecyclerView
    private lateinit var fab: TextView

    // ---- Debounce state for the search box (see the FIX comment where
    // searchField is built) ----
    private val searchDebounceHandler = android.os.Handler(android.os.Looper.getMainLooper())
    private val searchDebounceRunnable = Runnable { renderCurrentTab() }

    // ---- Rate List import: lets the user pick the CSV back up (after editing rates
    // in Excel/Sheets) via the system file picker, and applies the edited rates back
    // onto the matching products (matched by the hidden "Code" column). ----
    private lateinit var importRatesLauncher: ActivityResultLauncher<Array<String>>

    override fun onCreate(b: Bundle?) {
        super.onCreate(b)
        loadThemeColors()

        importRatesLauncher = registerForActivityResult(ActivityResultContracts.OpenDocument()) { uri ->
            uri?.let { importRateListCsv(it) }
        }

        val outer = FrameLayout(this).apply {
            setBackgroundColor(Color.parseColor(bg))
        }

        val root = LinearLayout(this).apply {
            orientation = LinearLayout.VERTICAL
            layoutParams = FrameLayout.LayoutParams(
                FrameLayout.LayoutParams.MATCH_PARENT, FrameLayout.LayoutParams.MATCH_PARENT
            )
            // FIX (list wouldn't scroll to the end — user report, Products/
            // Categories/Units tabs): this whole column (header + tabs + search +
            // the RecyclerView) used to be wrapped in an outer ScrollView, with
            // the RecyclerView itself measured WRAP_CONTENT and
            // isNestedScrollingEnabled = false so the ScrollView "owned" the
            // scrolling. In practice a RecyclerView still intercepts vertical
            // drags for itself first — it calls requestDisallowInterceptTouchEvent
            // on its parent as soon as a drag starts, even though nested
            // scrolling is off — which blocked the outer ScrollView from ever
            // receiving the rest of the gesture. Net effect: the screen only
            // scrolled a little (whatever the initial touch grabbed) and then
            // stuck, so the last rows were unreachable — exactly what was
            // reported. Fix: drop the outer ScrollView entirely. Header/tabs/
            // search stay fixed (non-scrolling) here in `root`; the
            // RecyclerView below is given its own remaining space
            // (height=0dp + weight=1) and scrolls itself natively — no
            // competing scroll containers, so it reaches every row.
            val d = resources.displayMetrics.density
            setPadding((24 * d).toInt(), (48 * d).toInt(), (24 * d).toInt(), 0)
        }

        // ================= HEADER (matches Items/Categories/Reports) =================
        val header = premiumHeader(R.drawable.ic_box, "Items", "Products, Categories & Units", primary, primaryDark)
        root.addView(header)

        // ================= HEADER ACTION BUTTONS (Rate List / Import / Translate) =================
        // ---- FIX (mobile layout bug): these 3 pills used to be added directly onto the
        // header's own horizontal row (back-chevron + icon + title/subtitle). On narrow phone
        // screens that row had too many children to fit; the title/subtitle column (width=0dp,
        // weight=1, meant to take the leftover space) got squeezed down to ~0 width, which made
        // its text wrap onto many lines instead of being clipped — and since the header's own
        // height always matches its tallest child, the whole header ballooned to that wrapped
        // text's height. With everything centered (gravity = CENTER_VERTICAL) inside that now-
        // huge header, the pills appeared to float in a sea of empty purple, and "Translate"
        // got pushed off the right edge of the screen. A tablet's wider screen never triggered
        // the squeeze, so it looked fine there. Fix: give these pills their own row, in a
        // HorizontalScrollView, completely separate from the title's flexible column — the
        // title can never be squeezed by them again, and if the pills themselves ever don't
        // fit, this row scrolls sideways instead of clipping or blowing up in height. ----
        val actionsBar = HorizontalScrollView(this).apply {
            isHorizontalScrollBarEnabled = false
            background = GradientDrawable(
                GradientDrawable.Orientation.TL_BR,
                intArrayOf(Color.parseColor(primary), Color.parseColor(primaryDark))
            ).apply { cornerRadius = 18f }
            layoutParams = LinearLayout.LayoutParams(
                LinearLayout.LayoutParams.MATCH_PARENT, LinearLayout.LayoutParams.WRAP_CONTENT
            ).apply { setMargins(0, 0, 0, 16) }
        }
        val actionsRow = LinearLayout(this).apply {
            orientation = LinearLayout.HORIZONTAL
            setPadding(
                (10 * resources.displayMetrics.density).toInt(),
                (8 * resources.displayMetrics.density).toInt(),
                (10 * resources.displayMetrics.density).toInt(),
                (8 * resources.displayMetrics.density).toInt()
            )
        }
        actionsBar.addView(actionsRow)

        // ---- "Rate List" pill button — CHANGED: used to export every product's
        // rates to a CSV for review in Excel/Sheets. Now launches
        // BulkMissingRatesActivity, same one-at-a-time stepper as Translate/Units,
        // showing only products still missing a Retail or Wholesale rate. ----
        actionsRow.addView(TextView(this).apply {
            text = "Rate List"
            textSize = 11f
            setTextColor(Color.WHITE)
            setTypeface(typeface, Typeface.BOLD)
            background = GradientDrawable().apply {
                setColor(Color.parseColor("#33FFFFFF"))
                cornerRadius = 30f
            }
            setPadding(18, 12, 18, 12)
            setCompoundDrawablesRelative(tintedDrawable(R.drawable.ic_document, "#FFFFFF", 13), null, null, null)
            compoundDrawablePadding = (6 * resources.displayMetrics.density).toInt()
            setOnClickListener {
                startActivity(Intent(this@ItemsActivity, BulkMissingRatesActivity::class.java))
            }
        })

        actionsRow.addView(View(this).apply {
            layoutParams = LinearLayout.LayoutParams((8 * resources.displayMetrics.density).toInt(), 1)
        })

        // ---- Import edited Rate List back — reads the CSV (after it was opened &
        // edited in Excel/Sheets) and applies the new rates/units onto the matching
        // products in this POS, so edits don't require re-entering each item by hand. ----
        actionsRow.addView(TextView(this).apply {
            text = "Import"
            textSize = 11f
            setTextColor(Color.WHITE)
            setTypeface(typeface, Typeface.BOLD)
            background = GradientDrawable().apply {
                setColor(Color.parseColor("#33FFFFFF"))
                cornerRadius = 30f
            }
            setPadding(18, 12, 18, 12)
            setCompoundDrawablesRelative(tintedDrawable(R.drawable.ic_undo, "#FFFFFF", 13), null, null, null)
            compoundDrawablePadding = (6 * resources.displayMetrics.density).toInt()
            setOnClickListener {
                importRatesLauncher.launch(arrayOf("text/*", "text/comma-separated-values", "application/*"))
            }
        })

        actionsRow.addView(View(this).apply {
            layoutParams = LinearLayout.LayoutParams((8 * resources.displayMetrics.density).toInt(), 1)
        })

        // ---- "Translate" pill button — launches BulkTranslateActivity so Urdu
        // category/unit values already saved can be renamed to English once each,
        // instead of editing every product individually. ----
        actionsRow.addView(TextView(this).apply {
            text = "Translate"
            textSize = 11f
            setTextColor(Color.WHITE)
            setTypeface(typeface, Typeface.BOLD)
            background = GradientDrawable().apply {
                setColor(Color.parseColor("#33FFFFFF"))
                cornerRadius = 30f
            }
            setPadding(18, 12, 18, 12)
            setCompoundDrawablesRelative(tintedDrawable(R.drawable.ic_globe, "#FFFFFF", 13), null, null, null)
            compoundDrawablePadding = (6 * resources.displayMetrics.density).toInt()
            setOnClickListener {
                startActivity(Intent(this@ItemsActivity, BulkTranslateActivity::class.java))
            }
        })

        actionsRow.addView(View(this).apply {
            layoutParams = LinearLayout.LayoutParams((8 * resources.displayMetrics.density).toInt(), 1)
        })

        // ---- "Units" pill button — launches BulkDefaultUnitActivity so the
        // Sale-screen default unit (see ProductUnitDialog's "Default Unit for
        // Sale Screen" row) can be reviewed/set for every already-added
        // multi-unit product one at a time, instead of opening each product. ----
        actionsRow.addView(TextView(this).apply {
            text = "Units"
            textSize = 11f
            setTextColor(Color.WHITE)
            setTypeface(typeface, Typeface.BOLD)
            background = GradientDrawable().apply {
                setColor(Color.parseColor("#33FFFFFF"))
                cornerRadius = 30f
            }
            setPadding(18, 12, 18, 12)
            setCompoundDrawablesRelative(tintedDrawable(R.drawable.ic_ruler, "#FFFFFF", 13), null, null, null)
            compoundDrawablePadding = (6 * resources.displayMetrics.density).toInt()
            setOnClickListener {
                startActivity(Intent(this@ItemsActivity, BulkDefaultUnitActivity::class.java))
            }
        })

        root.addView(actionsBar)

        // ================= TABS =================
        tabRow = LinearLayout(this).apply {
            orientation = LinearLayout.HORIZONTAL
            background = strokedBg(border, cardBg, 14)
            setPadding(6, 6, 6, 6)
            layoutParams = LinearLayout.LayoutParams(
                LinearLayout.LayoutParams.MATCH_PARENT, LinearLayout.LayoutParams.WRAP_CONTENT
            ).apply { setMargins(0, 0, 0, 16) }
        }
        productsTabBtn = tabButton("PRODUCTS") { switchTab(Tab.PRODUCTS) }
        categoriesTabBtn = tabButton("CATEGORIES") { switchTab(Tab.CATEGORIES) }
        unitsTabBtn = tabButton("UNITS") { switchTab(Tab.UNITS) }
        tabRow.addView(productsTabBtn)
        tabRow.addView(categoriesTabBtn)
        tabRow.addView(unitsTabBtn)
        root.addView(tabRow)

        // ================= SEARCH =================
        val searchBox = LinearLayout(this).apply {
            orientation = LinearLayout.HORIZONTAL
            gravity = Gravity.CENTER_VERTICAL
            background = strokedBg(border, "#FAFAFF", 14)
            setPadding(18, 4, 18, 4)
            layoutParams = LinearLayout.LayoutParams(
                LinearLayout.LayoutParams.MATCH_PARENT, LinearLayout.LayoutParams.WRAP_CONTENT
            ).apply { setMargins(0, 0, 0, 18) }
        }
        searchBox.addView(ImageView(this).apply {
            setImageDrawable(tintedDrawable(R.drawable.ic_search, textGray, 15))
            val px = (15 * resources.displayMetrics.density).toInt()
            layoutParams = LinearLayout.LayoutParams(px, px).apply { marginEnd = (8 * resources.displayMetrics.density).toInt() }
        })
        searchField = EditText(this).apply {
            hint = "Search..."
            setHintTextColor(Color.parseColor(textGray))
            setTextColor(Color.parseColor(textDark))
            background = null
            layoutParams = LinearLayout.LayoutParams(0, LinearLayout.LayoutParams.WRAP_CONTENT, 1f)
            // FIX (perf — app feels slow sometimes): renderCurrentTab() rebuilds a
            // full row View per item on the main thread. Firing that on every
            // single keystroke means fast typing on a big catalog queues up many
            // back-to-back full rebuilds and the UI visibly stutters while typing.
            // Debounce it: wait 200ms after the user stops typing before
            // re-rendering, and cancel any still-pending render from a previous
            // keystroke. Feels identical to typing normally, just without the lag.
            addTextChangedListener {
                searchQuery = it.trim()
                searchDebounceHandler.removeCallbacks(searchDebounceRunnable)
                searchDebounceHandler.postDelayed(searchDebounceRunnable, 200)
            }
        }
        searchBox.addView(searchField)
        root.addView(searchBox)

        listContainer = recyclerListView().apply {
            // Take all remaining vertical space below the fixed header/tabs/
            // search, and be the ONE thing on this screen that scrolls — see
            // the note on `root` above for why the previous outer-ScrollView
            // setup got stuck partway down the list.
            layoutParams = LinearLayout.LayoutParams(
                LinearLayout.LayoutParams.MATCH_PARENT, 0, 1f
            )
            isNestedScrollingEnabled = true
            clipToPadding = false
            val d = resources.displayMetrics.density
            // Bottom padding clears the floating "+ Add" button; clipToPadding
            // = false (above) means rows still scroll up into/past this
            // padding instead of being cut off by it.
            setPadding(0, 0, 0, (150 * d).toInt())
        }
        root.addView(listContainer)

        outer.addView(root)

        // ================= FLOATING ADD BUTTON =================
        fab = TextView(this).apply {
            textSize = 14.5f
            setTextColor(Color.WHITE)
            setTypeface(typeface, Typeface.BOLD)
            gravity = Gravity.CENTER
            setPadding(46, 26, 46, 26)
            background = GradientDrawable(
                GradientDrawable.Orientation.LEFT_RIGHT,
                intArrayOf(Color.parseColor(red), Color.parseColor(redDark))
            ).apply { cornerRadius = 100f }
            layoutParams = FrameLayout.LayoutParams(
                FrameLayout.LayoutParams.WRAP_CONTENT, FrameLayout.LayoutParams.WRAP_CONTENT
            ).apply {
                gravity = Gravity.BOTTOM or Gravity.CENTER_HORIZONTAL
                bottomMargin = (24 * resources.displayMetrics.density).toInt()
            }
            applyElevation(this, 8f)
            setOnClickListener { onFabClicked() }
        }
        outer.addView(fab)

        setContentView(outer)

        loadAll()
        switchTab(Tab.PRODUCTS)
    }

    override fun onBackPressed() {
        // ---- NEW: if a category is drilled into, Back closes the drill-down
        // first instead of leaving the screen. ----
        if (currentTab == Tab.CATEGORIES && openCategoryName != null) {
            closeCategoryDetail()
            return
        }
        super.onBackPressed()
    }

    override fun onDestroy() {
        searchDebounceHandler.removeCallbacks(searchDebounceRunnable)
        super.onDestroy()
    }

    // ================= TAB SWITCHING =================
    private fun switchTab(tab: Tab) {
        currentTab = tab
        openCategoryName = null
        searchQuery = ""
        // Cancel any pending debounced re-render from typing on the previous
        // tab — switchTab renders immediately below, so a stale callback
        // shouldn't fire a redundant render right after.
        searchDebounceHandler.removeCallbacks(searchDebounceRunnable)
        searchField.setText("")
        searchField.hint = when (tab) {
            Tab.PRODUCTS -> "Search Items by Name or Code"
            Tab.CATEGORIES -> "Search Category"
            Tab.UNITS -> "Search Unit"
        }
        fab.text = when (tab) {
            Tab.PRODUCTS -> "＋  Add Product"
            Tab.CATEGORIES -> "＋  Add Category"
            Tab.UNITS -> "＋  Add Unit"
        }
        fab.visibility = View.VISIBLE

        productsTabBtn.setBackgroundColor(Color.TRANSPARENT)
        categoriesTabBtn.setBackgroundColor(Color.TRANSPARENT)
        unitsTabBtn.setBackgroundColor(Color.TRANSPARENT)
        productsTabBtn.setTextColor(Color.parseColor(textGray))
        categoriesTabBtn.setTextColor(Color.parseColor(textGray))
        unitsTabBtn.setTextColor(Color.parseColor(textGray))

        val selected = when (tab) {
            Tab.PRODUCTS -> productsTabBtn
            Tab.CATEGORIES -> categoriesTabBtn
            Tab.UNITS -> unitsTabBtn
        }
        selected.background = roundedBg(primary, 10)
        selected.setTextColor(Color.WHITE)

        renderCurrentTab()
    }

    private fun closeCategoryDetail() {
        openCategoryName = null
        searchQuery = ""
        searchDebounceHandler.removeCallbacks(searchDebounceRunnable)
        searchField.setText("")
        searchField.hint = "Search Category"
        fab.text = "＋  Add Category"
        fab.visibility = View.VISIBLE
        renderCurrentTab()
    }

    private fun onFabClicked() {
        if (currentTab == Tab.CATEGORIES && openCategoryName != null) {
            // Inside a category's product list — FAB adds a new product
            // (category can be set on the product form itself).
            startActivity(Intent(this, ProductActivity::class.java))
            return
        }
        when (currentTab) {
            Tab.PRODUCTS -> startActivity(Intent(this, ProductActivity::class.java))
            Tab.CATEGORIES -> promptAddCategory()
            Tab.UNITS -> promptAddUnit()
        }
    }

    // ================= DATA LOADING =================
    private fun loadAll() {
        lifecycleScope.launch {
            PosDatabase.get(this@ItemsActivity).productDao().all().collectLatest {
                allProducts = it
                if (currentTab == Tab.PRODUCTS || currentTab == Tab.CATEGORIES) renderCurrentTab()
            }
        }
        lifecycleScope.launch {
            PosDatabase.get(this@ItemsActivity).categoryDao().all().collectLatest {
                allCategories = it
                if (currentTab == Tab.CATEGORIES) renderCurrentTab()
            }
        }
        lifecycleScope.launch {
            PosDatabase.get(this@ItemsActivity).unitDao().all().collectLatest {
                allUnits = it
                if (currentTab == Tab.UNITS) renderCurrentTab()
            }
        }
    }

    private fun renderCurrentTab() {
        when (currentTab) {
            Tab.PRODUCTS -> renderProducts()
            Tab.CATEGORIES -> {
                val open = openCategoryName
                if (open != null) renderCategoryDetail(open) else renderCategories()
            }
            Tab.UNITS -> renderUnits()
        }
    }

    // ================= PRODUCTS TAB =================
    private fun renderProducts() {
        val filtered = if (searchQuery.isEmpty()) allProducts
        else allProducts.filter {
            it.matchesQuery(searchQuery) || it.barcode.contains(searchQuery, ignoreCase = true)
        }
        val rows = mutableListOf<View>()
        if (filtered.isEmpty()) {
            rows.add(emptyState("Koi product nahi mila"))
            listContainer.submitRows(rows)
            return
        }
        for (p in filtered) {
            rows.add(LinearLayout(this).apply {
                orientation = LinearLayout.VERTICAL
                setPadding(20, 16, 20, 16)
                background = strokedBg(border, cardBg, 14)
                layoutParams = LinearLayout.LayoutParams(
                    LinearLayout.LayoutParams.MATCH_PARENT, LinearLayout.LayoutParams.WRAP_CONTENT
                ).apply { setMargins(0, 0, 0, 10) }

                addView(TextView(this@ItemsActivity).apply {
                    text = p.name
                    textSize = 14.5f
                    setTextColor(Color.parseColor(textDark))
                    setTypeface(typeface, Typeface.BOLD)
                })
                if (p.category.isNotBlank()) {
                    addView(TextView(this@ItemsActivity).apply {
                        text = p.category
                        textSize = 10.5f
                        setTextColor(Color.WHITE)
                        setTypeface(typeface, Typeface.BOLD)
                        background = roundedBg(purple, 16)
                        setPadding(16, 4, 16, 4)
                        layoutParams = LinearLayout.LayoutParams(
                            LinearLayout.LayoutParams.WRAP_CONTENT, LinearLayout.LayoutParams.WRAP_CONTENT
                        ).apply { setMargins(0, 8, 0, 0) }
                    })
                }
                val priceRow = LinearLayout(this@ItemsActivity).apply {
                    orientation = LinearLayout.HORIZONTAL
                    setPadding(0, 10, 0, 0)
                }
                priceRow.addView(priceCol("Sale Price", p.salePrice))
                priceRow.addView(priceCol("Purchase Price", p.cost))
                addView(priceRow)

                setOnClickListener {
                    startActivity(Intent(this@ItemsActivity, ProductActivity::class.java).apply {
                        putExtra(ProductActivity.EXTRA_EDIT_BARCODE, p.barcode)
                    })
                }
            })
        }
        listContainer.submitRows(rows)
    }

    private fun priceCol(label: String, value: Double) = LinearLayout(this).apply {
        orientation = LinearLayout.VERTICAL
        layoutParams = LinearLayout.LayoutParams(0, LinearLayout.LayoutParams.WRAP_CONTENT, 1f)
        addView(TextView(this@ItemsActivity).apply {
            text = label; textSize = 11f
            setTextColor(Color.parseColor(textGray))
        })
        addView(TextView(this@ItemsActivity).apply {
            text = "Rs %.2f".format(value)
            textSize = 13f
            setTextColor(Color.parseColor(textDark))
            setTypeface(typeface, Typeface.BOLD)
        })
    }

    // ================= CATEGORIES TAB (list) =================
    private fun renderCategories() {
        val counts = allProducts.groupingBy { it.category.ifBlank { "" } }.eachCount()
        val notCategorized = counts[""] ?: 0

        // name to (count, isSpecialUncategorizedBucket)
        val categoryRows = mutableListOf<Triple<String, Int, Boolean>>()
        categoryRows.add(Triple("Items Not in Any Category", notCategorized, true))
        for (c in allCategories) {
            categoryRows.add(Triple(c.name, counts[c.name] ?: 0, false))
        }

        val filtered = if (searchQuery.isEmpty()) categoryRows
        else categoryRows.filter { it.first.contains(searchQuery, ignoreCase = true) }

        val rows = mutableListOf<View>()
        if (filtered.isEmpty()) {
            rows.add(emptyState("Koi category nahi mili"))
            listContainer.submitRows(rows)
            return
        }

        for ((name, count, isUncategorized) in filtered) {
            rows.add(LinearLayout(this).apply {
                orientation = LinearLayout.HORIZONTAL
                gravity = Gravity.CENTER_VERTICAL
                setPadding(20, 18, 20, 18)
                background = strokedBg(border, cardBg, 14)
                layoutParams = LinearLayout.LayoutParams(
                    LinearLayout.LayoutParams.MATCH_PARENT, LinearLayout.LayoutParams.WRAP_CONTENT
                ).apply { setMargins(0, 0, 0, 10) }

                // ---- Tap anywhere on the row (except the edit/delete icons) to
                // drill into that category's products. ----
                setOnClickListener {
                    openCategoryName = if (isUncategorized) "" else name
                    searchQuery = ""
                    searchField.setText("")
                    searchField.hint = "Search Items in \"$name\""
                    fab.text = "＋  Add Product"
                    renderCurrentTab()
                }

                addView(TextView(this@ItemsActivity).apply {
                    text = name
                    textSize = 14f
                    setTextColor(Color.parseColor(textDark))
                    setTypeface(typeface, Typeface.BOLD)
                    layoutParams = LinearLayout.LayoutParams(0, LinearLayout.LayoutParams.WRAP_CONTENT, 1f)
                })
                addView(TextView(this@ItemsActivity).apply {
                    text = count.toString()
                    textSize = 13.5f
                    setTextColor(Color.WHITE)
                    setTypeface(typeface, Typeface.BOLD)
                    background = roundedBg(purple, 20)
                    setPadding(20, 6, 20, 6)
                })

                // ---- Real categories (not the "Items Not in Any Category"
                // bucket) get Edit (rename) and Delete icons. ----
                if (!isUncategorized) {
                    val category = allCategories.first { it.name == name }
                    addView(View(this@ItemsActivity).apply { layoutParams = LinearLayout.LayoutParams(14, 1) })
                    addView(ImageView(this@ItemsActivity).apply {
                        setImageDrawable(tintedDrawable(R.drawable.ic_edit, textGray, 16))
                        setPadding(14, 8, 14, 8)
                        setOnClickListener { promptEditCategory(category) }
                    })
                    addView(ImageView(this@ItemsActivity).apply {
                        setImageDrawable(tintedDrawable(R.drawable.ic_delete, textGray, 16))
                        setPadding(14, 8, 14, 8)
                        setOnClickListener { confirmDeleteCategory(category, count) }
                    })
                }
            })
        }
        listContainer.submitRows(rows)
    }

    private fun promptAddCategory() {
        val input = EditText(this).apply { setPadding(32, 24, 32, 24) }
        AlertDialog.Builder(this)
            .setTitle("New Category")
            .setView(input)
            .setPositiveButton("Add") { _, _ ->
                val v = input.text.toString().trim()
                if (v.isNotEmpty()) lifecycleScope.launch {
                    val db = PosDatabase.get(this@ItemsActivity)
                    val newCategory = Category(v)
                    db.categoryDao().insert(newCategory)
                    SyncQueueHelper.enqueueCategory(db, newCategory, this@ItemsActivity)
                }
            }
            .setNegativeButton("Cancel", null)
            .show()
    }

    // ---- NEW: rename a category. Renaming also updates every product
    // currently tagged with the old name, so nothing silently becomes
    // "uncategorized" just because the category was renamed. ----
    private fun promptEditCategory(category: Category) {
        val input = EditText(this).apply {
            setPadding(32, 24, 32, 24)
            setText(category.name)
            setSelection(text.length)
        }
        AlertDialog.Builder(this)
            .setTitle("Rename Category")
            .setView(input)
            .setPositiveButton("Save") { _, _ ->
                val newName = input.text.toString().trim()
                if (newName.isEmpty() || newName == category.name) return@setPositiveButton
                lifecycleScope.launch {
                    val db = PosDatabase.get(this@ItemsActivity)
                    // Category's primary key IS its name, so "renaming" means:
                    // add the new name, repoint every product that used the old
                    // name (existing helper — already used by BulkTranslateActivity),
                    // then remove the old category row.
                    // FIX (#12 — category/unit master sync incomplete, missed here): same
                    // gap already fixed in BulkTranslateActivity.saveAll()/RoomPurchaseRepository.
                    // renameUnitToEnglish()/DuplicateUnitFix — renameCategoryInProducts() is a
                    // raw SQL UPDATE that never touches sync on its own, so every touched
                    // product must be re-read (post-rename) and enqueued too. Only the category
                    // master-list row was being pushed here, leaving every product under this
                    // category still showing the OLD name on other devices.
                    val touchedBarcodes = db.productDao().findByCategory(category.name).map { it.barcode }
                    val newCategory = Category(newName)
                    db.categoryDao().insert(newCategory)
                    db.productDao().renameCategoryInProducts(category.name, newName)
                    db.categoryDao().deleteByName(category.name)
                    // NEW (Units/Categories master-list sync): push both sides of the
                    // rename (new name added, old name removed) so other devices' master
                    // list stays in sync too.
                    SyncQueueHelper.enqueueCategory(db, newCategory, this@ItemsActivity)
                    SyncQueueHelper.enqueueDelete(db, "category", category.name, this@ItemsActivity)
                    touchedBarcodes.forEach { barcode ->
                        db.productDao().find(barcode)?.let { p -> SyncQueueHelper.enqueueProduct(db, p) }
                    }
                    if (touchedBarcodes.isNotEmpty()) SyncQueueHelper.trigger(this@ItemsActivity)
                    Toast.makeText(this@ItemsActivity, "Category renamed", Toast.LENGTH_SHORT).show()
                }
            }
            .setNegativeButton("Cancel", null)
            .show()
    }

    // ---- NEW: delete a category. If it still has products in it, they are
    // moved to "Items Not in Any Category" instead of being deleted, and the
    // user is warned about this before confirming. ----
    private fun confirmDeleteCategory(category: Category, productCount: Int) {
        val message = if (productCount > 0)
            "\"${category.name}\" has $productCount item(s). Deleting it will move them to \"Items Not in Any Category\". Continue?"
        else
            "Delete \"${category.name}\"? This cannot be undone."
        AlertDialog.Builder(this)
            .setTitle("Delete Category")
            .setMessage(message)
            .setPositiveButton("Delete") { _, _ ->
                lifecycleScope.launch {
                    val db = PosDatabase.get(this@ItemsActivity)
                    // FIX (#12 — category/unit master sync incomplete, missed here): see
                    // promptEditCategory() above — the moved-out products must be re-enqueued
                    // too, or other devices keep showing them under the deleted category.
                    val touchedBarcodes = if (productCount > 0) db.productDao().findByCategory(category.name).map { it.barcode } else emptyList()
                    if (productCount > 0) db.productDao().renameCategoryInProducts(category.name, "")
                    db.categoryDao().deleteByName(category.name)
                    // NEW (Units/Categories master-list sync): propagate the delete.
                    SyncQueueHelper.enqueueDelete(db, "category", category.name, this@ItemsActivity)
                    touchedBarcodes.forEach { barcode ->
                        db.productDao().find(barcode)?.let { p -> SyncQueueHelper.enqueueProduct(db, p) }
                    }
                    if (touchedBarcodes.isNotEmpty()) SyncQueueHelper.trigger(this@ItemsActivity)
                    Toast.makeText(this@ItemsActivity, "Category deleted", Toast.LENGTH_SHORT).show()
                }
            }
            .setNegativeButton("Cancel", null)
            .show()
    }

    // ================= CATEGORIES TAB (drill-down: products inside one category) =================
    private fun renderCategoryDetail(categoryName: String) {
        val displayName = categoryName.ifBlank { "Items Not in Any Category" }
        val rows = mutableListOf<View>()

        // ---- Back row + category title ----
        rows.add(LinearLayout(this).apply {
            orientation = LinearLayout.HORIZONTAL
            gravity = Gravity.CENTER_VERTICAL
            setPadding(4, 0, 4, 16)
            addView(LinearLayout(this@ItemsActivity).apply {
                orientation = LinearLayout.HORIZONTAL
                gravity = Gravity.CENTER_VERTICAL
                setPadding(10, 10, 20, 10)
                setOnClickListener { closeCategoryDetail() }
                addView(ImageView(this@ItemsActivity).apply {
                    setImageDrawable(tintedDrawable(R.drawable.ic_chevron_down, primary, 13))
                    rotation = 90f
                    val px = (13 * resources.displayMetrics.density).toInt()
                    layoutParams = LinearLayout.LayoutParams(px, px).apply { marginEnd = (6 * resources.displayMetrics.density).toInt() }
                })
                addView(TextView(this@ItemsActivity).apply {
                    text = "Categories"
                    textSize = 13f
                    setTextColor(Color.parseColor(primary))
                    setTypeface(typeface, Typeface.BOLD)
                })
            })
        })
        rows.add(TextView(this).apply {
            text = displayName
            textSize = 17f
            setTextColor(Color.parseColor(textDark))
            setTypeface(typeface, Typeface.BOLD)
            setPadding(4, 0, 4, 16)
        })

        val inCategory = allProducts.filter { it.category.ifBlank { "" } == categoryName }
        val filtered = if (searchQuery.isEmpty()) inCategory
        else inCategory.filter { it.matchesQuery(searchQuery) }

        if (filtered.isEmpty()) {
            rows.add(emptyState(if (inCategory.isEmpty()) "Is category mein koi item nahi" else "Koi matching item nahi mila"))
            listContainer.submitRows(rows)
            return
        }

        for (p in filtered) {
            rows.add(categoryProductRow(p))
        }
        listContainer.submitRows(rows)
    }

    private fun categoryProductRow(p: Product) = LinearLayout(this).apply {
        orientation = LinearLayout.VERTICAL
        setPadding(20, 16, 20, 16)
        background = strokedBg(border, cardBg, 14)
        layoutParams = LinearLayout.LayoutParams(
            LinearLayout.LayoutParams.MATCH_PARENT, LinearLayout.LayoutParams.WRAP_CONTENT
        ).apply { setMargins(0, 0, 0, 10) }

        addView(TextView(this@ItemsActivity).apply {
            text = p.name
            textSize = 14.5f
            setTextColor(Color.parseColor(textDark))
            setTypeface(typeface, Typeface.BOLD)
        })

        addView(TextView(this@ItemsActivity).apply {
            text = "Stock: ${p.formatStockBreakdown()}"
            textSize = 12f
            setTextColor(Color.parseColor(textGray))
            setPadding(0, 6, 0, 0)
            setCompoundDrawablesRelative(tintedDrawable(R.drawable.ic_chart, textGray, 12), null, null, null)
            compoundDrawablePadding = (5 * resources.displayMetrics.density).toInt()
        })

        val priceRow = LinearLayout(this@ItemsActivity).apply {
            orientation = LinearLayout.HORIZONTAL
            setPadding(0, 8, 0, 0)
        }
        priceRow.addView(priceCol("Sale Price", p.salePrice))
        priceRow.addView(priceCol("Purchase Price", p.cost))
        addView(priceRow)

        val actionsRow = LinearLayout(this@ItemsActivity).apply {
            orientation = LinearLayout.HORIZONTAL
            setPadding(0, 12, 0, 0)
        }
        actionsRow.addView(TextView(this@ItemsActivity).apply {
            text = "Edit"
            textSize = 12f
            setTextColor(Color.WHITE)
            setTypeface(typeface, Typeface.BOLD)
            background = roundedBg(primary, 30)
            setPadding(20, 10, 20, 10)
            setCompoundDrawablesRelative(tintedDrawable(R.drawable.ic_edit, "#FFFFFF", 13), null, null, null)
            compoundDrawablePadding = (6 * resources.displayMetrics.density).toInt()
            setOnClickListener {
                startActivity(Intent(this@ItemsActivity, ProductActivity::class.java).apply {
                    putExtra(ProductActivity.EXTRA_EDIT_BARCODE, p.barcode)
                })
            }
        })
        actionsRow.addView(View(this@ItemsActivity).apply { layoutParams = LinearLayout.LayoutParams(8, 1) })
        actionsRow.addView(TextView(this@ItemsActivity).apply {
            text = "Change Category"
            textSize = 12f
            setTextColor(Color.WHITE)
            setTypeface(typeface, Typeface.BOLD)
            background = roundedBg(teal, 30)
            setPadding(20, 10, 20, 10)
            setCompoundDrawablesRelative(tintedDrawable(R.drawable.ic_repeat, "#FFFFFF", 13), null, null, null)
            compoundDrawablePadding = (6 * resources.displayMetrics.density).toInt()
            setOnClickListener { promptChangeProductCategory(p) }
        })
        actionsRow.addView(View(this@ItemsActivity).apply { layoutParams = LinearLayout.LayoutParams(8, 1) })
        actionsRow.addView(TextView(this@ItemsActivity).apply {
            text = "Delete"
            textSize = 12f
            setTextColor(Color.WHITE)
            setTypeface(typeface, Typeface.BOLD)
            background = roundedBg(red, 30)
            setPadding(20, 10, 20, 10)
            setCompoundDrawablesRelative(tintedDrawable(R.drawable.ic_delete, "#FFFFFF", 13), null, null, null)
            compoundDrawablePadding = (6 * resources.displayMetrics.density).toInt()
            setOnClickListener { confirmDeleteProduct(p) }
        })
        addView(actionsRow)
    }

    // ---- NEW: change which category a single product belongs to, from a
    // simple pick-list of all existing categories plus "Items Not in Any
    // Category". Updates the product row immediately and, since the product
    // list is a live Flow, it disappears from the current category's view
    // right away if a different category was picked. ----
    private fun promptChangeProductCategory(p: Product) {
        val options = mutableListOf("Items Not in Any Category")
        options.addAll(allCategories.map { it.name })

        AlertDialog.Builder(this)
            .setTitle("Move \"${p.name}\" to")
            .setItems(options.toTypedArray()) { _, index ->
                val newCategory = if (index == 0) "" else options[index]
                lifecycleScope.launch {
                    PosDatabase.get(this@ItemsActivity).productDao().upsert(p.copy(category = newCategory))
                    Toast.makeText(
                        this@ItemsActivity,
                        "\"${p.name}\" moved to ${newCategory.ifBlank { "Items Not in Any Category" }}",
                        Toast.LENGTH_SHORT
                    ).show()
                }
            }
            .setNegativeButton("Cancel", null)
            .show()
    }

    private fun confirmDeleteProduct(p: Product) {
        AlertDialog.Builder(this)
            .setTitle("Delete Product")
            .setMessage("Delete \"${p.name}\"? This cannot be undone.")
            .setPositiveButton("Delete") { _, _ ->
                lifecycleScope.launch {
                    val db = PosDatabase.get(this@ItemsActivity)
                    db.productDao().delete(p)
                    SyncQueueHelper.enqueueDelete(db, "product", p.barcode, this@ItemsActivity)
                    Toast.makeText(this@ItemsActivity, "Product deleted", Toast.LENGTH_SHORT).show()
                }
            }
            .setNegativeButton("Cancel", null)
            .show()
    }

    // ================= UNITS TAB =================
    private fun renderUnits() {
        val filtered = if (searchQuery.isEmpty()) allUnits
        else allUnits.filter { it.name.contains(searchQuery, ignoreCase = true) }

        val rows = mutableListOf<View>()
        if (filtered.isEmpty()) {
            rows.add(emptyState("Koi unit nahi mila"))
            listContainer.submitRows(rows)
            return
        }
        for (u in filtered) {
            rows.add(LinearLayout(this).apply {
                orientation = LinearLayout.HORIZONTAL
                gravity = Gravity.CENTER_VERTICAL
                setPadding(20, 18, 20, 18)
                background = strokedBg(border, cardBg, 14)
                layoutParams = LinearLayout.LayoutParams(
                    LinearLayout.LayoutParams.MATCH_PARENT, LinearLayout.LayoutParams.WRAP_CONTENT
                ).apply { setMargins(0, 0, 0, 10) }

                // ---- CHANGE (sada/plain like Parties/Transactions/Items tabs —
                // user asked to remove the leading icon here too): dropped the
                // ic_ruler icon that used to sit before the unit name. ----
                addView(TextView(this@ItemsActivity).apply {
                    text = u.name
                    textSize = 14f
                    setTextColor(Color.parseColor(textDark))
                    setTypeface(typeface, Typeface.BOLD)
                    layoutParams = LinearLayout.LayoutParams(0, LinearLayout.LayoutParams.WRAP_CONTENT, 1f)
                })

                // ---- Delete button for this unit ----
                addView(TextView(this@ItemsActivity).apply {
                    text = "Delete"
                    textSize = 12f
                    setTextColor(Color.WHITE)
                    setTypeface(typeface, Typeface.BOLD)
                    background = roundedBg(red, 30)
                    setPadding(22, 10, 22, 10)
                    setCompoundDrawablesRelative(tintedDrawable(R.drawable.ic_delete, "#FFFFFF", 13), null, null, null)
                    compoundDrawablePadding = (6 * resources.displayMetrics.density).toInt()
                    setOnClickListener { confirmDeleteUnit(u) }
                })
            })
        }
        listContainer.submitRows(rows)
    }

    private fun promptAddUnit() {
        val input = EditText(this).apply { setPadding(32, 24, 32, 24) }
        AlertDialog.Builder(this)
            .setTitle("New Unit")
            .setView(input)
            .setPositiveButton("Add") { _, _ ->
                val v = input.text.toString().trim()
                if (v.isNotEmpty()) lifecycleScope.launch {
                    val db = PosDatabase.get(this@ItemsActivity)
                    val newUnit = UnitType(v)
                    db.unitDao().insert(newUnit)
                    SyncQueueHelper.enqueueUnit(db, newUnit, this@ItemsActivity)
                }
            }
            .setNegativeButton("Cancel", null)
            .show()
    }

    private fun confirmDeleteUnit(u: UnitType) {
        AlertDialog.Builder(this)
            .setTitle("Delete Unit")
            .setMessage("Delete \"${u.name}\"? This cannot be undone.")
            .setPositiveButton("Delete") { _, _ ->
                lifecycleScope.launch {
                    PosDatabase.get(this@ItemsActivity).unitDao().delete(u)
                    Toast.makeText(this@ItemsActivity, "Unit deleted", Toast.LENGTH_SHORT).show()
                }
            }
            .setNegativeButton("Cancel", null)
            .show()
    }

    // ================= UI HELPERS =================
    private fun emptyState(text: String) = TextView(this).apply {
        this.text = text
        textSize = 13.5f
        setTextColor(Color.parseColor(textGray))
        gravity = Gravity.CENTER
        setPadding(0, 60, 0, 0)
    }

    // ---- Icon migration helper (matches ProductActivity/PartyReportsActivity pattern):
    // tints and sizes a R.drawable.ic_* vector so it can replace a raw emoji, either as a
    // standalone ImageView or as a TextView/Button's compound drawable. ----
    private fun tintedDrawable(iconRes: Int, tintHex: String, sizeDp: Int = 16): android.graphics.drawable.Drawable? {
        val d = androidx.core.content.ContextCompat.getDrawable(this, iconRes)?.mutate() ?: return null
        d.setTint(Color.parseColor(tintHex))
        val px = (sizeDp * resources.displayMetrics.density).toInt()
        d.setBounds(0, 0, px, px)
        return d
    }

    private fun tabButton(label: String, onClick: () -> Unit) = TextView(this).apply {
        text = label
        textSize = 12.5f
        gravity = Gravity.CENTER
        setTypeface(typeface, Typeface.BOLD)
        setPadding(0, 20, 0, 20)
        layoutParams = LinearLayout.LayoutParams(0, LinearLayout.LayoutParams.WRAP_CONTENT, 1f)
        setOnClickListener { onClick() }
    }

    private fun circleIcon(label: String, colorHex: String, sizeDp: Int) = TextView(this).apply {
        text = label
        textSize = 18f
        gravity = Gravity.CENTER
        background = ovalBg(colorHex)
        val px = (sizeDp * resources.displayMetrics.density).toInt()
        layoutParams = android.view.ViewGroup.LayoutParams(px, px)
    }

    private fun EditText.addTextChangedListener(onChanged: (String) -> Unit) {
        addTextChangedListener(object : TextWatcher {
            override fun beforeTextChanged(s: CharSequence?, a: Int, b: Int, c: Int) {}
            override fun onTextChanged(s: CharSequence?, a: Int, b: Int, c: Int) {}
            override fun afterTextChanged(s: Editable?) { onChanged(s?.toString() ?: "") }
        })
    }

    // ---------------- Rate List export (CSV) ----------------
    // Lets the shopkeeper review/audit every product's unit + wholesale + retail rate
    // (including 2nd/3rd unit conversions) in one spreadsheet instead of scrolling this
    // list and opening each product one at a time.

    private fun trimNum(v: Double): String =
        if (v == v.toLong().toDouble()) v.toLong().toString() else v.toString()

    private fun exportRateListCsv() {
        if (allProducts.isEmpty()) {
            Toast.makeText(this, "No products to export", Toast.LENGTH_SHORT).show()
            return
        }
        try {
            val stamp = java.text.SimpleDateFormat(
                "yyyy-MM-dd_HH-mm",
                java.util.Locale.getDefault()
            ).format(java.util.Date())
            val fileName = "IBTISAAM_Rate_List_$stamp.csv"

            val folder = java.io.File(getExternalFilesDir(null), "IBTISAAM Rate Lists").apply {
                if (!exists()) mkdirs()
            }
            val file = java.io.File(folder, fileName)

            fun esc(s: String) = "\"" + s.replace("\"", "\"\"") + "\""

            file.bufferedWriter(Charsets.UTF_8).use { w ->
                // UTF-8 BOM so Excel (which otherwise guesses the wrong encoding for a
                // plain .csv) shows English/Urdu product & category names correctly
                // instead of garbled characters.
                w.write('\uFEFF'.toString())
                w.write(
                    listOf(
                        "Code (don't edit)", "Name", "Category", "Unit",
                        "Wholesale Rate", "Retail Rate",
                        "2nd Unit", "1 Unit = Qty (2nd Unit)",
                        "3rd Unit", "1 (2nd Unit) = Qty (3rd Unit)"
                    ).joinToString(",")
                )
                w.newLine()
                allProducts.sortedBy { it.name.lowercase(java.util.Locale.getDefault()) }
                    .forEach { p ->
                        w.write(
                            listOf(
                                esc(p.barcode),
                                esc(p.name),
                                esc(p.category),
                                esc(p.unit),
                                trimNum(p.wholesalePrice),
                                trimNum(p.salePrice),
                                esc(p.secondaryUnit),
                                if (p.secondaryUnit.isNotBlank()) trimNum(p.secondaryUnitQty) else "",
                                esc(p.tertiaryUnit),
                                if (p.tertiaryUnit.isNotBlank()) trimNum(p.tertiaryUnitQty) else ""
                            ).joinToString(",")
                        )
                        w.newLine()
                    }
            }

            copyRateListToDownloads(file, fileName)
            openRateListDirectly(file)
        } catch (e: Exception) {
            e.printStackTrace()
            Toast.makeText(this, "Export failed", Toast.LENGTH_SHORT).show()
        }
    }

    /** Also drops a copy into the public Downloads folder so the file stays
     *  browsable/re-openable later even without re-sharing. */
    private fun copyRateListToDownloads(sourceFile: java.io.File, fileName: String) {
        try {
            val subFolder = "IBTISAAM Rate Lists"
            if (android.os.Build.VERSION.SDK_INT >= android.os.Build.VERSION_CODES.Q) {
                val resolver = contentResolver
                val values = android.content.ContentValues().apply {
                    put(android.provider.MediaStore.MediaColumns.DISPLAY_NAME, fileName)
                    put(android.provider.MediaStore.MediaColumns.MIME_TYPE, "text/csv")
                    put(
                        android.provider.MediaStore.MediaColumns.RELATIVE_PATH,
                        android.os.Environment.DIRECTORY_DOWNLOADS + "/" + subFolder
                    )
                }
                val uri = resolver.insert(
                    android.provider.MediaStore.Downloads.EXTERNAL_CONTENT_URI,
                    values
                )
                if (uri != null) {
                    resolver.openOutputStream(uri)?.use { out ->
                        java.io.FileInputStream(sourceFile).use { input -> input.copyTo(out) }
                    }
                }
            } else {
                @Suppress("DEPRECATION")
                val downloadsDir = java.io.File(
                    android.os.Environment.getExternalStoragePublicDirectory(
                        android.os.Environment.DIRECTORY_DOWNLOADS
                    ),
                    subFolder
                )
                if (!downloadsDir.exists()) downloadsDir.mkdirs()
                sourceFile.copyTo(java.io.File(downloadsDir, fileName), overwrite = true)
            }
        } catch (e: Exception) {
            e.printStackTrace()
        }
    }

    /** Opens the CSV directly in whatever app the phone already uses for
     *  spreadsheets (Excel, Sheets, WPS Office, etc.) — no Share menu in between.
     *  Falls back to the Share sheet only if no app on the device can open it
     *  directly (some phones need that route to pick a viewer). */
    private fun openRateListDirectly(file: java.io.File) {
        try {
            val uri = androidx.core.content.FileProvider.getUriForFile(
                this,
                "$packageName.fileprovider",
                file
            )
            val viewIntent = Intent(Intent.ACTION_VIEW).apply {
                setDataAndType(uri, "text/csv")
                addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
                addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
            }
            try {
                startActivity(viewIntent)
            } catch (notFound: android.content.ActivityNotFoundException) {
                // No app registered for "text/csv" specifically — try a generic type,
                // which some spreadsheet apps register instead.
                viewIntent.setDataAndType(uri, "*/*")
                startActivity(viewIntent)
            }
        } catch (e: Exception) {
            e.printStackTrace()
            Toast.makeText(
                this,
                "Rate List saved, but no app found to open it. Install Excel, Google Sheets or WPS Office to view/edit it.",
                Toast.LENGTH_LONG
            ).show()
        }
    }

    /** Splits one CSV line into fields, honoring double-quoted fields (which may
     *  contain commas or escaped "" quotes) — same format exportRateListCsv writes. */
    private fun parseCsvLine(line: String): List<String> {
        val fields = mutableListOf<String>()
        val cur = StringBuilder()
        var inQuotes = false
        var i = 0
        while (i < line.length) {
            val ch = line[i]
            when {
                inQuotes && ch == '"' && i + 1 < line.length && line[i + 1] == '"' -> {
                    cur.append('"'); i++
                }
                ch == '"' -> inQuotes = !inQuotes
                ch == ',' && !inQuotes -> { fields.add(cur.toString()); cur.setLength(0) }
                else -> cur.append(ch)
            }
            i++
        }
        fields.add(cur.toString())
        return fields
    }

    /** Reads back a Rate List CSV (after it was edited in Excel/Sheets) and applies
     *  the new unit/wholesale/retail rates onto the matching products here in the
     *  POS — matched by the hidden "Code" column, so a renamed product still updates
     *  correctly. Products edited on-device since export are safely overwritten by
     *  whatever the CSV row says (last edit wins), same as editing them by hand. */
    private fun importRateListCsv(uri: android.net.Uri) {
        lifecycleScope.launch {
            try {
                val lines = contentResolver.openInputStream(uri)?.use { input ->
                    input.bufferedReader(Charsets.UTF_8).readLines()
                } ?: run {
                    Toast.makeText(this@ItemsActivity, "Could not read file", Toast.LENGTH_SHORT).show()
                    return@launch
                }
                if (lines.size < 2) {
                    Toast.makeText(this@ItemsActivity, "File has no product rows", Toast.LENGTH_SHORT).show()
                    return@launch
                }

                val db = PosDatabase.get(this@ItemsActivity)
                var updated = 0
                var notFound = 0

                lines.drop(1).forEach { rawLine ->
                    if (rawLine.isBlank()) return@forEach
                    // Strip a leading UTF-8 BOM if this is the very first data line.
                    val line = rawLine.removePrefix("\uFEFF")
                    val f = parseCsvLine(line)
                    if (f.size < 6) return@forEach

                    val barcode = f[0].trim()
                    if (barcode.isBlank()) return@forEach
                    val existing = db.productDao().find(barcode)
                    if (existing == null) {
                        notFound++
                        return@forEach
                    }

                    val unit = f.getOrElse(3) { existing.unit }.trim().ifBlank { existing.unit }
                    val wholesale = f.getOrElse(4) { "" }.trim().toDoubleOrNull() ?: existing.wholesalePrice
                    val retail = f.getOrElse(5) { "" }.trim().toDoubleOrNull() ?: existing.salePrice
                    val secondaryUnit = f.getOrElse(6) { "" }.trim()
                    val secondaryUnitQty = f.getOrElse(7) { "" }.trim().toDoubleOrNull() ?: 0.0
                    val tertiaryUnit = f.getOrElse(8) { "" }.trim()
                    val tertiaryUnitQty = f.getOrElse(9) { "" }.trim().toDoubleOrNull() ?: 0.0

                    db.productDao().upsert(
                        existing.copy(
                            unit = unit,
                            wholesalePrice = wholesale,
                            salePrice = retail,
                            secondaryUnit = secondaryUnit,
                            secondaryUnitQty = secondaryUnitQty,
                            tertiaryUnit = tertiaryUnit,
                            tertiaryUnitQty = tertiaryUnitQty,
                            updatedAt = System.currentTimeMillis(),
                            dirty = true
                        )
                    )
                    updated++
                }

                val msg = if (notFound == 0) {
                    "Updated $updated product(s)"
                } else {
                    "Updated $updated product(s), $notFound not found (Code column changed?)"
                }
                Toast.makeText(this@ItemsActivity, msg, Toast.LENGTH_LONG).show()
            } catch (e: Exception) {
                e.printStackTrace()
                Toast.makeText(this@ItemsActivity, "Import failed: ${e.message}", Toast.LENGTH_LONG).show()
            }
        }
    }
}

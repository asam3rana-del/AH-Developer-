package com.grocerypos.v11.ui

import android.graphics.Color
import android.graphics.Typeface
import android.graphics.drawable.GradientDrawable
import android.os.Bundle
import android.util.Log
import android.view.Gravity
import android.view.View
import android.widget.LinearLayout
import android.widget.ScrollView
import android.widget.TextView
import android.widget.Toast
import androidx.lifecycle.lifecycleScope
import com.grocerypos.v11.PosDatabase
import com.grocerypos.v11.Product
import com.grocerypos.v11.R
import com.grocerypos.v11.SyncQueueHelper
import com.grocerypos.v11.ui.components.*
import kotlinx.coroutines.launch

/**
 * Bulk "Default Sale Unit" review — same one-at-a-time stepper pattern as
 * BulkTranslateActivity's Items queue, but for Product.defaultUnitIndex
 * instead of searchTag. Goes through every already-added product that (a) has
 * more than one unit tier and (b) hasn't had a default explicitly picked yet
 * (defaultUnitIndex == -1), shows what Auto would currently pick for it (see
 * SaleCart.kt's autoDefaultUnitIndexFor()) already highlighted, and lets the
 * shopkeeper tap a different chip to override it. Tapping "Keep Auto & Next"
 * just advances — nothing is written, so the product stays on Auto and can
 * still change behavior later if its category-based Auto rule changes. Tapping
 * a specific unit chip then Save & Next writes that tier as the permanent
 * override, same as picking one in ProductUnitDialog's own default-unit row.
 */
class BulkDefaultUnitActivity : ThemedActivity() {

    private var bg = "#F3F2FA"
    private var cardBg = "#FFFFFF"
    private var primary = "#4A3AFF"
    private var primaryDark = "#3527D6"
    private var textDark = "#1A1A2E"
    private var textGray = "#8A8A9E"
    private var border = "#E7E5F3"
    private var teal = "#0F9B8E"
    private var tealDark = "#0C7C71"

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

    private fun loadThemeColors() {
        val p = com.grocerypos.v11.util.ThemeManager.palette(this)
        bg = p.bg
        cardBg = p.cardWhite
        primary = p.flatPurpleFg
        primaryDark = p.flatPurpleFg
        textDark = p.textDark
        textGray = p.textMuted
        border = p.border
        teal = p.flatTealFg
        tealDark = p.flatTealFg
    }

    companion object {
        private const val TAG = "BulkDefaultUnit"
    }

    private var queue: MutableList<Product> = mutableListOf()
    private var total: Int = 0
    // -1 = "Keep Auto" is currently highlighted for the product on screen;
    // 0/1/2 = that tier is highlighted instead. Reset every time the stepper
    // advances to a new product, pre-set to what Auto would pick.
    private var chosenIndex: Int = -1

    private lateinit var progressText: TextView
    private lateinit var card: LinearLayout
    private lateinit var nameLabel: TextView
    private lateinit var categoryLabel: TextView
    private lateinit var chipRow: LinearLayout
    private lateinit var saveNextBtn: TextView
    private lateinit var allDoneText: TextView
    private lateinit var loadingText: TextView

    override fun onCreate(b: Bundle?) {
        super.onCreate(b)
        loadThemeColors()

        val root = LinearLayout(this).apply {
            orientation = LinearLayout.VERTICAL
            setPadding(24, 48, 24, 40)
            setBackgroundColor(Color.parseColor(bg))
        }

        val header = LinearLayout(this).apply {
            orientation = LinearLayout.VERTICAL
            setPadding(26, 22, 26, 22)
            background = GradientDrawable(
                GradientDrawable.Orientation.TL_BR,
                intArrayOf(Color.parseColor(primary), Color.parseColor(primaryDark))
            ).apply { cornerRadius = 22f }
            layoutParams = LinearLayout.LayoutParams(
                LinearLayout.LayoutParams.MATCH_PARENT, LinearLayout.LayoutParams.WRAP_CONTENT
            ).apply { setMargins(0, 0, 0, 20) }
        }
        header.addView(TextView(this).apply {
            text = "Default Sale Unit"
            setLeadingIcon(R.drawable.ic_ruler, "#FFFFFF", 18, 8)
            textSize = 19f
            setTextColor(Color.WHITE)
            setTypeface(typeface, Typeface.BOLD)
        })
        header.addView(TextView(this).apply {
            text = "Products with more than one unit already have a suggestion picked for you below — tap Save & Next to confirm it, or pick a different unit first. One product at a time, no need to open each one from Items."
            textSize = 12f
            setTextColor(Color.parseColor("#DAD5FF"))
            setPadding(0, 6, 0, 0)
        })
        root.addView(header)

        loadingText = TextView(this).apply {
            text = "Loading…"
            textSize = 13.5f
            setTextColor(Color.parseColor(textGray))
            gravity = Gravity.CENTER
            setPadding(0, 40, 0, 40)
        }
        root.addView(loadingText)

        progressText = TextView(this).apply {
            textSize = 12f
            setTextColor(Color.parseColor(textGray))
            setPadding(4, 0, 0, 10)
            visibility = View.GONE
        }
        root.addView(progressText)

        card = LinearLayout(this).apply {
            orientation = LinearLayout.VERTICAL
            setPadding(18, 18, 18, 18)
            background = strokedBg(border, cardBg, 14)
            visibility = View.GONE
        }
        nameLabel = TextView(this).apply {
            textSize = 15.5f
            setTypeface(typeface, Typeface.BOLD)
            setTextColor(Color.parseColor(textDark))
        }
        card.addView(nameLabel)
        categoryLabel = TextView(this).apply {
            textSize = 12f
            setTextColor(Color.parseColor(textGray))
            setPadding(0, 3, 0, 0)
        }
        card.addView(categoryLabel)
        card.addView(spacer(14))
        chipRow = LinearLayout(this).apply {
            orientation = LinearLayout.HORIZONTAL
        }
        card.addView(chipRow)
        card.addView(spacer(16))
        saveNextBtn = TextView(this).apply {
            text = "SAVE & NEXT"
            setLeadingIcon(R.drawable.ic_save, "#FFFFFF", 15, 6)
            textSize = 13.5f
            gravity = Gravity.CENTER
            setTextColor(Color.WHITE)
            setTypeface(typeface, Typeface.BOLD)
            background = GradientDrawable(
                GradientDrawable.Orientation.TL_BR,
                intArrayOf(Color.parseColor(teal), Color.parseColor(tealDark))
            ).apply { cornerRadius = 14f }
            setPadding(0, 22, 0, 22)
            setOnClickListener { saveCurrentAndAdvance() }
        }
        card.addView(saveNextBtn)
        root.addView(card)

        allDoneText = TextView(this).apply {
            text = "All products reviewed"
            setCompoundDrawablesRelative(null, null, tintedDrawable(R.drawable.ic_check, teal, 16), null)
            compoundDrawablePadding = (6 * resources.displayMetrics.density).toInt()
            textSize = 14f
            setTextColor(Color.parseColor(textGray))
            gravity = Gravity.CENTER
            setPadding(0, 60, 0, 60)
            visibility = View.GONE
        }
        root.addView(allDoneText)

        setContentView(ScrollView(this).apply {
            setBackgroundColor(Color.parseColor(bg))
            addView(root)
        })

        loadQueue()
    }

    private fun loadQueue() {
        lifecycleScope.launch {
            try {
                val db = PosDatabase.get(this@BulkDefaultUnitActivity)
                queue = db.productDao().productsNeedingDefaultUnitReview().toMutableList()
                total = queue.size
                loadingText.visibility = View.GONE
                showCurrent()
            } catch (e: Exception) {
                Log.e(TAG, "loadQueue failed", e)
                loadingText.visibility = View.GONE
                Toast.makeText(
                    this@BulkDefaultUnitActivity,
                    "Could not load products: ${e.message ?: "unknown error"}",
                    Toast.LENGTH_LONG
                ).show()
            }
        }
    }

    private fun tierNamesFor(product: Product): List<String> {
        val names = mutableListOf(product.unit)
        if (product.secondaryUnit.isNotEmpty()) {
            names.add(product.secondaryUnit)
            if (product.tertiaryUnit.isNotEmpty() && product.tertiaryUnitQty > 0) {
                names.add(product.tertiaryUnit)
            }
        }
        return names
    }

    private fun showCurrent() {
        val current = queue.firstOrNull()
        if (current == null) {
            card.visibility = View.GONE
            progressText.visibility = View.GONE
            allDoneText.visibility = View.VISIBLE
            return
        }
        allDoneText.visibility = View.GONE
        card.visibility = View.VISIBLE
        progressText.visibility = View.VISIBLE

        val doneCount = total - queue.size
        progressText.text = "${doneCount + 1} of $total"
        nameLabel.text = current.name
        categoryLabel.text = current.category.ifBlank { "General" }

        // Pre-highlight whatever Auto would pick right now, so confirming the
        // suggestion is just one tap on Save & Next.
        chosenIndex = autoDefaultUnitIndexFor(current)
        renderChips(current)
    }

    private fun renderChips(product: Product) {
        val tierNames = tierNamesFor(product)
        chipRow.removeAllViews()
        val options = listOf(-1 to "Auto") + tierNames.mapIndexed { index, label -> index to label }
        options.forEachIndexed { i, (indexValue, label) ->
            val isSelected = indexValue == chosenIndex
            chipRow.addView(TextView(this).apply {
                text = label
                textSize = 12.5f
                setTypeface(typeface, Typeface.BOLD)
                setPadding(20, 12, 20, 12)
                setTextColor(if (isSelected) Color.WHITE else Color.parseColor(primary))
                background = if (isSelected)
                    GradientDrawable().apply { setColor(Color.parseColor(primary)); cornerRadius = 30f }
                else
                    strokedBg(primary, cardBg, 30)
                layoutParams = LinearLayout.LayoutParams(-2, -2).apply {
                    setMargins(if (i == 0) 0 else 8, 0, 0, 0)
                }
                setOnClickListener {
                    chosenIndex = indexValue
                    renderChips(product)
                }
            })
        }
    }

    // Saves the currently-shown product's chosen tier (or leaves it on Auto if
    // "Auto" chip is still selected — a no-op write, since it's already -1),
    // then advances to the next product in the queue.
    private fun saveCurrentAndAdvance() {
        val current = queue.firstOrNull() ?: return
        saveNextBtn.isEnabled = false
        lifecycleScope.launch {
            try {
                if (chosenIndex != -1) {
                    val db = PosDatabase.get(this@BulkDefaultUnitActivity)
                    db.productDao().updateDefaultUnitIndex(current.barcode, chosenIndex, System.currentTimeMillis())
                    db.productDao().find(current.barcode)?.let { updated ->
                        SyncQueueHelper.enqueueProduct(db, updated)
                    }
                    SyncQueueHelper.trigger(this@BulkDefaultUnitActivity)
                }
                queue.removeAt(0)
                showCurrent()
            } catch (e: Exception) {
                Log.e(TAG, "saveCurrentAndAdvance failed", e)
                Toast.makeText(
                    this@BulkDefaultUnitActivity,
                    "Could not save: ${e.message ?: "unknown error"}",
                    Toast.LENGTH_LONG
                ).show()
            } finally {
                saveNextBtn.isEnabled = true
            }
        }
    }
}

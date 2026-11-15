package com.grocerypos.v11.ui.components

import android.graphics.Color
import android.graphics.Typeface
import android.graphics.drawable.GradientDrawable
import android.view.Gravity
import android.view.View
import android.widget.LinearLayout
import android.widget.TextView
import androidx.appcompat.app.AppCompatActivity
import com.grocerypos.v11.ui.theme.AppColors

/**
 * Shared header bar (back chevron + icon badge + title/subtitle on a gradient
 * banner) — was copy-pasted near-identically into HistoryActivity,
 * BalanceSheetActivity, PartyReportsActivity, ReportsActivity, and
 * StockReportActivity (item #24 — architecture duplication).
 *
 * Back-button behaviour defaults to finish(). [primaryHex]/[primaryDarkHex]
 * default to the shared AppColors palette but can be overridden if a screen
 * ever needs a different gradient. [onBack] is optional — StockMovementActivity
 * needed the back chevron to pop out of a drill-down (product detail) rather
 * than always finishing the Activity, so it passes a custom lambda; every
 * other caller omits it and keeps the plain finish() behaviour.
 */
fun AppCompatActivity.premiumHeader(
    icon: String,
    title: String,
    subtitle: String,
    primaryHex: String = AppColors.primary,
    primaryDarkHex: String = AppColors.primaryDark,
    onBack: (() -> Unit)? = null
): LinearLayout {
    val header = LinearLayout(this).apply {
        orientation = LinearLayout.HORIZONTAL
        gravity = Gravity.CENTER_VERTICAL
        setPadding(26, 22, 26, 22)
        background = GradientDrawable(
            GradientDrawable.Orientation.TL_BR,
            intArrayOf(Color.parseColor(primaryHex), Color.parseColor(primaryDarkHex))
        ).apply { cornerRadius = 22f }
        layoutParams = LinearLayout.LayoutParams(
            LinearLayout.LayoutParams.MATCH_PARENT, LinearLayout.LayoutParams.WRAP_CONTENT
        ).apply { setMargins(0, 0, 0, 20) }
        applyElevation(this, 10f)
    }
    header.addView(TextView(this).apply {
        text = "\u2039"
        textSize = 20f
        setTextColor(Color.WHITE)
        setTypeface(typeface, Typeface.BOLD)
        gravity = Gravity.CENTER
        background = ovalBg("#33FFFFFF")
        val px = (36 * resources.displayMetrics.density).toInt()
        layoutParams = android.view.ViewGroup.LayoutParams(px, px)
        setOnClickListener { onBack?.invoke() ?: finish() }
    })
    header.addView(View(this).apply { layoutParams = LinearLayout.LayoutParams(14, 1) })
    header.addView(circleIcon(icon, "#5C4DFF", 42))
    header.addView(View(this).apply { layoutParams = LinearLayout.LayoutParams(16, 1) })
    val headerCol = LinearLayout(this).apply {
        orientation = LinearLayout.VERTICAL
        layoutParams = LinearLayout.LayoutParams(0, LinearLayout.LayoutParams.WRAP_CONTENT, 1f)
    }
    headerCol.addView(TextView(this).apply {
        text = title
        textSize = 19f
        setTextColor(Color.WHITE)
        setTypeface(typeface, Typeface.BOLD)
    })
    headerCol.addView(TextView(this).apply {
        text = subtitle
        textSize = 11f
        setTextColor(Color.parseColor("#D8D3FF"))
        setPadding(0, 4, 0, 0)
    })
    header.addView(headerCol)
    return header
}

fun AppCompatActivity.circleIcon(label: String, colorHex: String, sizeDp: Int): TextView =
    TextView(this).apply {
        text = label
        textSize = 18f
        gravity = Gravity.CENTER
        background = ovalBg(colorHex)
        val px = (sizeDp * resources.displayMetrics.density).toInt()
        layoutParams = android.view.ViewGroup.LayoutParams(px, px)
    }

// ---- Vector-icon variants (item-6 UI improvement pass): same header/badge, but takes a
// drawable resource instead of an emoji string. Added as an overload rather than replacing
// the String version above, since premiumHeader()/circleIcon() are shared across five screens
// (History, BalanceSheet, PartyReports, Reports, StockReport) and only some have been migrated
// off emoji so far — the String overload stays until every caller has moved over. ----
fun AppCompatActivity.premiumHeader(
    iconRes: Int,
    title: String,
    subtitle: String,
    primaryHex: String = AppColors.primary,
    primaryDarkHex: String = AppColors.primaryDark,
    onBack: (() -> Unit)? = null
): LinearLayout {
    val header = LinearLayout(this).apply {
        orientation = LinearLayout.HORIZONTAL
        gravity = Gravity.CENTER_VERTICAL
        setPadding(26, 22, 26, 22)
        background = GradientDrawable(
            GradientDrawable.Orientation.TL_BR,
            intArrayOf(Color.parseColor(primaryHex), Color.parseColor(primaryDarkHex))
        ).apply { cornerRadius = 22f }
        layoutParams = LinearLayout.LayoutParams(
            LinearLayout.LayoutParams.MATCH_PARENT, LinearLayout.LayoutParams.WRAP_CONTENT
        ).apply { setMargins(0, 0, 0, 20) }
        applyElevation(this, 10f)
    }
    header.addView(TextView(this).apply {
        text = "\u2039"
        textSize = 20f
        setTextColor(Color.WHITE)
        setTypeface(typeface, Typeface.BOLD)
        gravity = Gravity.CENTER
        background = ovalBg("#33FFFFFF")
        val px = (36 * resources.displayMetrics.density).toInt()
        layoutParams = android.view.ViewGroup.LayoutParams(px, px)
        setOnClickListener { onBack?.invoke() ?: finish() }
    })
    header.addView(View(this).apply { layoutParams = LinearLayout.LayoutParams(14, 1) })
    header.addView(circleIconDrawable(iconRes, "#5C4DFF", 42))
    header.addView(View(this).apply { layoutParams = LinearLayout.LayoutParams(16, 1) })
    val headerCol = LinearLayout(this).apply {
        orientation = LinearLayout.VERTICAL
        layoutParams = LinearLayout.LayoutParams(0, LinearLayout.LayoutParams.WRAP_CONTENT, 1f)
    }
    headerCol.addView(TextView(this).apply {
        text = title
        textSize = 19f
        setTextColor(Color.WHITE)
        setTypeface(typeface, Typeface.BOLD)
    })
    headerCol.addView(TextView(this).apply {
        text = subtitle
        textSize = 11f
        setTextColor(Color.parseColor("#D8D3FF"))
        setPadding(0, 4, 0, 0)
    })
    header.addView(headerCol)
    return header
}

fun AppCompatActivity.circleIconDrawable(iconRes: Int, colorHex: String, sizeDp: Int): android.widget.ImageView =
    android.widget.ImageView(this).apply {
        val d = androidx.core.content.ContextCompat.getDrawable(this@circleIconDrawable, iconRes)?.mutate()
        d?.setTint(Color.WHITE)
        setImageDrawable(d)
        scaleType = android.widget.ImageView.ScaleType.CENTER
        background = ovalBg(colorHex)
        val px = (sizeDp * resources.displayMetrics.density).toInt()
        layoutParams = android.view.ViewGroup.LayoutParams(px, px)
    }

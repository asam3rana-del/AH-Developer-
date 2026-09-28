package com.grocerypos.v11.ui.components

import android.graphics.Color
import android.graphics.Typeface
import android.graphics.drawable.Drawable
import android.graphics.drawable.GradientDrawable
import android.view.Gravity
import android.view.View
import android.view.ViewGroup
import android.widget.ImageView
import android.widget.LinearLayout
import android.widget.TextView
import androidx.appcompat.app.AppCompatActivity
import androidx.core.content.ContextCompat
import com.grocerypos.v11.R
import com.grocerypos.v11.ui.theme.AppColors

/**
 * Shared "menu row" design (icon-in-pastel-circle + label + chevron/trailing) —
 * this was SettingsActivity's own private `menuRow()`/`expandableMenuRow()`/
 * `iconBadge()` set (its main POINT OF SALE screen: Parties/Items/Reports/
 * Sale/Purchase/Expense/Cash & Bank/etc rows). Pulled out here, unchanged
 * pixel-for-pixel, so every other screen in the app can build rows and tiles
 * that look identical instead of each screen having its own row style.
 *
 * Usage: `import com.grocerypos.v11.ui.components.*` in any Activity, then
 * call `menuRow(...)` / `expandableMenuRow(...)` / `iconBadge(...)` directly —
 * these are AppCompatActivity extension functions, same pattern as
 * premiumHeader() in PremiumHeader.kt.
 *
 * Colors default to the static AppColors palette but every call site is
 * expected to pass its own ThemeManager.palette(this)-derived hex values
 * (cardHex/borderHex/textHex/etc.) so dark mode keeps working exactly like it
 * already does on Settings — same convention as premiumHeader()'s
 * primaryHex/primaryDarkHex params.
 */

/** Tinted vector drawable, sized in dp — identical helper that used to be copy-pasted into ~20 screens. */
fun AppCompatActivity.tintedDrawable(iconRes: Int, tintHex: String, sizeDp: Int = 16): Drawable? {
    val d = ContextCompat.getDrawable(this, iconRes)?.mutate() ?: return null
    d.setTint(Color.parseColor(tintHex))
    val px = (sizeDp * resources.displayMetrics.density).toInt()
    d.setBounds(0, 0, px, px)
    return d
}

/** Same lightening approach as CashActivity's stat-card tint / SettingsActivity's menu-row badges. */
fun lightenHex(colorHex: String, factor: Float = 0.82f): String {
    val base = Color.parseColor(colorHex)
    val r = (Color.red(base) + (255 - Color.red(base)) * factor).toInt().coerceIn(0, 255)
    val g = (Color.green(base) + (255 - Color.green(base)) * factor).toInt().coerceIn(0, 255)
    val bl = (Color.blue(base) + (255 - Color.blue(base)) * factor).toInt().coerceIn(0, 255)
    return String.format("#%02X%02X%02X", r, g, bl)
}

/**
 * Pastel circle badge with a centered tinted icon — the badge used on every
 * menuRow/tile/dashboard-card in the app. [bgHex] defaults to an
 * auto-lightened [colorHex] (Settings' original behaviour); pass an explicit
 * [bgHex] when a screen already has its own theme-tuned pastel tone (e.g.
 * MainActivity's dark-mode-aware flatXxxBg vars) so it keeps that exact
 * color while still using this one shared badge shape/size/icon-centering.
 */
fun AppCompatActivity.iconBadge(iconRes: Int, colorHex: String, bgHex: String = lightenHex(colorHex), sizeDp: Int = 44, iconSizeDp: Int = 20): ImageView =
    ImageView(this).apply {
        setImageDrawable(tintedDrawable(iconRes, colorHex, iconSizeDp))
        scaleType = ImageView.ScaleType.CENTER
        background = GradientDrawable().apply {
            shape = GradientDrawable.OVAL
            setColor(Color.parseColor(bgHex))
        }
        val px = (sizeDp * resources.displayMetrics.density).toInt()
        layoutParams = ViewGroup.LayoutParams(px, px)
    }

/** Puts a small tinted vector icon before a TextView's text — same look as Settings' field labels,
 *  usable on any TextView (not just inside an Activity) since it only needs `context`/`resources`. */
fun TextView.setLeadingIcon(iconRes: Int, tintHex: String, sizeDp: Int = 16, paddingDp: Int = 8) {
    val d = ContextCompat.getDrawable(context, iconRes)?.mutate()
    d?.setTint(Color.parseColor(tintHex))
    val px = (sizeDp * resources.displayMetrics.density).toInt()
    d?.setBounds(0, 0, px, px)
    setCompoundDrawablesRelative(d, null, null, null)
    compoundDrawablePadding = (paddingDp * resources.displayMetrics.density).toInt()
}

private fun AppCompatActivity.menuChevron(tintHex: String): ImageView =
    ImageView(this).apply { setImageDrawable(tintedDrawable(R.drawable.ic_chevron_down, tintHex, 18)) }

/** Plain white rounded/bordered card container — same shape menuRow()/expandableMenuRow() sit inside. */
fun AppCompatActivity.premiumRowCard(cardHex: String = AppColors.cardBg, borderHex: String = AppColors.border): LinearLayout =
    LinearLayout(this).apply {
        orientation = LinearLayout.VERTICAL
        background = strokedBg(borderHex, cardHex, 18)
        layoutParams = LinearLayout.LayoutParams(
            LinearLayout.LayoutParams.MATCH_PARENT, LinearLayout.LayoutParams.WRAP_CONTENT
        ).apply { setMargins(0, 0, 0, 14) }
        applyElevation(this, 3f)
    }

/** A simple, non-expanding premium row: icon-in-circle + label (+ optional chevron / trailing text). */
fun AppCompatActivity.menuRow(
    iconRes: Int,
    label: String,
    showChevron: Boolean = false,
    trailingText: String? = null,
    textColorHex: String = AppColors.textDark,
    iconBgHex: String = AppColors.teal,
    chevronHex: String = AppColors.teal,
    cardHex: String = AppColors.cardBg,
    borderHex: String = AppColors.border,
    onClick: () -> Unit
): LinearLayout {
    val row = premiumRowCard(cardHex, borderHex).apply {
        orientation = LinearLayout.HORIZONTAL
        gravity = Gravity.CENTER_VERTICAL
        setPadding(18, 17, 18, 17)
        isClickable = true
        isFocusable = true
    }
    row.addView(iconBadge(iconRes, iconBgHex))
    row.addView(spacerH(16))
    row.addView(TextView(this).apply {
        text = label
        textSize = 14.5f
        setTextColor(Color.parseColor(textColorHex))
        setTypeface(typeface, Typeface.BOLD)
        layoutParams = LinearLayout.LayoutParams(0, LinearLayout.LayoutParams.WRAP_CONTENT, 1f)
    })
    if (trailingText != null) {
        row.addView(TextView(this).apply {
            text = trailingText
            textSize = 18f
            setTextColor(Color.parseColor(chevronHex))
            setTypeface(typeface, Typeface.BOLD)
        })
    } else if (showChevron) {
        row.addView(menuChevron(chevronHex))
    }
    row.setOnClickListener { onClick() }
    return row
}

/** A premium row with an optional subtitle line that expands/collapses a target view when tapped. */
fun AppCompatActivity.expandableMenuRow(
    iconRes: Int,
    label: String,
    subtitle: String? = null,
    target: View,
    iconBgHex: String = AppColors.primary,
    textColorHex: String = AppColors.textDark,
    subtitleColorHex: String = AppColors.textGray,
    chevronHex: String = AppColors.teal,
    cardHex: String = AppColors.cardBg,
    borderHex: String = AppColors.border
): LinearLayout {
    val row = premiumRowCard(cardHex, borderHex).apply {
        orientation = LinearLayout.HORIZONTAL
        gravity = Gravity.CENTER_VERTICAL
        setPadding(18, 17, 18, 17)
        isClickable = true
        isFocusable = true
    }
    row.addView(iconBadge(iconRes, iconBgHex))
    row.addView(spacerH(16))

    val textCol = LinearLayout(this).apply {
        orientation = LinearLayout.VERTICAL
        layoutParams = LinearLayout.LayoutParams(0, LinearLayout.LayoutParams.WRAP_CONTENT, 1f)
    }
    textCol.addView(TextView(this).apply {
        text = label
        textSize = 14.5f
        setTextColor(Color.parseColor(textColorHex))
        setTypeface(typeface, Typeface.BOLD)
    })
    if (subtitle != null) {
        textCol.addView(TextView(this).apply {
            text = subtitle
            textSize = 11f
            setTextColor(Color.parseColor(subtitleColorHex))
            setPadding(0, 2, 0, 0)
        })
    }
    row.addView(textCol)

    val chevron = menuChevron(chevronHex)
    row.addView(chevron)

    row.setOnClickListener {
        val expanding = target.visibility != View.VISIBLE
        target.visibility = if (expanding) View.VISIBLE else View.GONE
        chevron.rotation = if (expanding) 180f else 0f
    }
    return row
}

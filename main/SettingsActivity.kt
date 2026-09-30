package com.grocerypos.v11.ui

import android.annotation.SuppressLint
import android.bluetooth.BluetoothDevice
import android.content.Intent
import android.graphics.Color
import android.graphics.Typeface
import android.graphics.drawable.GradientDrawable
import android.net.Uri
import android.os.Build
import android.os.Bundle
import android.provider.OpenableColumns
import android.text.InputType
import android.view.Gravity
import android.view.View
import android.view.ViewGroup
import android.view.ViewOutlineProvider
import android.widget.*
import androidx.activity.result.ActivityResultLauncher
import androidx.activity.result.contract.ActivityResultContracts
import androidx.core.content.ContextCompat
import androidx.appcompat.app.AlertDialog
import androidx.appcompat.app.AppCompatActivity
import androidx.lifecycle.lifecycleScope
import android.content.ClipData
import android.content.ClipboardManager
import android.content.Context
import com.grocerypos.v11.AppSetting
import com.grocerypos.v11.BranchConfigStore
import com.grocerypos.v11.PasswordHasher
import com.grocerypos.v11.PosDatabase
import com.grocerypos.v11.R
import com.grocerypos.v11.SyncQueueHelper
import com.grocerypos.v11.User
import com.grocerypos.v11.sync.SyncApi
import com.grocerypos.v11.util.BackupHelper
import com.grocerypos.v11.BackupPasswordStore
import com.grocerypos.v11.util.PrinterHelper
import com.grocerypos.v11.ui.theme.AppColors
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import java.text.SimpleDateFormat
import java.util.Locale
import com.grocerypos.v11.ui.components.*

class SettingsActivity : AppCompatActivity() {

    // ================= PALETTE (matches Product/Purchase/Sale premium look) =================
    // Pulled from ThemeManager so this screen respects dark mode. Header was a navy→navyLight
    // gradient; now flat (navyLight = navy) like the rest of the app's flattened headers.
    // CHANGED (user asked: main brand color across Sale/Purchase/Items/Settings/
    // Reports should match the "Today's profit" blue on the dashboard): header now
    // uses flatBlueFg instead of the old deep navy.
    private var bg = "#F4F6F8"
    internal var cardWhite = "#FFFFFF"
    private var navy = "#1450C7"
    private var navyLight = "#1450C7"
    internal var teal = "#0F9B8E"
    internal var red = "#E5484D"
    internal var amber = "#FF8A00"
    internal var amberBg = "#FAEEDA"
    private var badgeRed = "#E5484D"
    internal var textDark = "#0B2545"
    internal var textGray = "#7C8798"
    internal var border = "#E3E8EE"
    internal var fieldFill = "#FAFBFC"
    private var headerSubtitleColor = "#9FB4CC"

    private fun loadThemeColors() {
        val p = com.grocerypos.v11.util.ThemeManager.palette(this)
        bg = p.bg
        cardWhite = p.cardWhite
        navy = p.flatBlueFg
        navyLight = p.flatBlueFg
        teal = p.flatTealFg
        red = p.red
        amber = p.flatAmberFg
        amberBg = p.flatAmberBg
        badgeRed = p.red
        textDark = p.textDark
        textGray = p.textMuted
        border = p.border
        fieldFill = p.fieldFill
        headerSubtitleColor = p.headerSubtitleColor
    }

    private lateinit var currentUsernameField: EditText
    private lateinit var newUsernameField: EditText
    private lateinit var newPasswordField: EditText
    private lateinit var printerStatusText: TextView
    private lateinit var printerStatusDot: TextView
    private lateinit var loginMethodGroup: RadioGroup
    private lateinit var passwordOnlyRadio: RadioButton
    private lateinit var fingerprintOnlyRadio: RadioButton
    private lateinit var bothRadio: RadioButton
    private lateinit var noPasswordRadio: RadioButton
    private lateinit var otpRadio: RadioButton

    // Shop Information fields
    private lateinit var shopNameField: EditText
    private lateinit var phoneField: EditText

    // Header shop name label (kept in sync with the Shop Information "Shop Name" field)
    private lateinit var shopNameHeaderText: TextView

    // NEW: Sync Now row — connected/offline status indicator
    internal lateinit var syncRowDot: TextView
    internal lateinit var syncRowStatusText: TextView

    private val BT_PERMISSION_REQUEST_CODE = 501

    // FIX (restore reliability): Android 11+ blocks normal file-manager apps from
    // browsing into Android/data/<package>/files, which is where Restore's list
    // reads backups from — so a backup copied there by hand often silently fails
    // to appear/restore. This launcher lets the user pick a .db file from ANYWHERE
    // (Downloads, a cloud app, etc.) via the system picker, which is exempt from
    // that restriction, and restores directly from it — no manual file-copying needed.
    private lateinit var importBackupLauncher: ActivityResultLauncher<Array<String>>

    override fun onCreate(b: Bundle?) {
        setTheme(R.style.Theme_SettingsSheet)
        super.onCreate(b)
        loadThemeColors()

        importBackupLauncher = registerForActivityResult(ActivityResultContracts.OpenDocument()) { uri ->
            uri?.let { confirmRestoreFromUri(it) }
        }

        window.setBackgroundDrawable(android.graphics.drawable.ColorDrawable(Color.parseColor("#66000000")))

        val root = LinearLayout(this).apply {
            orientation = LinearLayout.VERTICAL
            setBackgroundColor(Color.parseColor(bg))
        }

        // ================= PREMIUM GRADIENT HEADER =================
        root.addView(buildHeader())

        val list = LinearLayout(this).apply {
            orientation = LinearLayout.VERTICAL
            setPadding(16, 8, 16, 10)
        }

        // ---- Parties (real) ----
        list.addView(menuRow(R.drawable.ic_people, "Parties", showChevron = true, iconBgHex = AppColors.teal) {
            startActivity(Intent(this@SettingsActivity, PartyDashboardActivity::class.java))
        })

        // ---- Items (real) ----
        list.addView(menuRow(R.drawable.ic_list, "Items", iconBgHex = AppColors.teal) {
            startActivity(Intent(this@SettingsActivity, ItemsActivity::class.java))
        })

        // ---- Reports (real) ----
        list.addView(menuRow(R.drawable.ic_trending, "Reports", iconBgHex = AppColors.teal) {
            startActivity(Intent(this@SettingsActivity, ReportsActivity::class.java))
        })

        // ---- Sale (real) ----
        list.addView(menuRow(R.drawable.ic_receipt, "Sale", showChevron = true, iconBgHex = AppColors.teal) {
            startActivity(Intent(this@SettingsActivity, SaleActivity::class.java))
        })

        // ---- Purchase (real) ----
        list.addView(menuRow(R.drawable.ic_cart, "Purchase", showChevron = true, iconBgHex = AppColors.teal) {
            startActivity(Intent(this@SettingsActivity, PurchaseActivity::class.java))
        })

        // ---- Expense (no screen yet — reflection fallback kept in case it's added later) ----
        list.addView(menuRow(R.drawable.ic_briefcase, "Expense", trailingText = "+") {
            tryOpenActivity("com.grocerypos.v11.ui.ExpenseActivity", "Expense")
        })

        // ---- Cash & Bank (real) ----
        list.addView(menuRow(R.drawable.ic_bank, "Cash & Bank", showChevron = true) {
            startActivity(Intent(this@SettingsActivity, CashActivity::class.java))
        })

        // FIX: Shell Ledger — the screen and its full Room backend already existed
        // (ShellLedgerActivity.kt / ShellCustomer / ShellTransaction /
        // ShopEmptyShellLog) but had no manifest entry and no menu row, so there was
        // no way to reach it from anywhere in the app. Wired up here + AndroidManifest.
        list.addView(menuRow(R.drawable.ic_box, "Shell Ledger", showChevron = true) {
            startActivity(Intent(this@SettingsActivity, ShellLedgerActivity::class.java))
        })

        // ---- Sync Now (now shows live Connected/Offline status) ----
        list.addView(buildSyncRow())

        // ADDED (multi-tenant support): lets this device be pointed at its own
        // Firebase project instead of always using whatever this build shipped with —
        // see CloudConfigStore.kt for why. Sync Now above stays disabled/no-op until
        // this is filled in (or this build already has a usable default baked in).
        list.addView(menuRow(R.drawable.ic_cloud, "Cloud Sync Setup", showChevron = true) {
            openCloudSyncSetupDialog()
        })

        // ADDED (sync recoverability): shows the audit log SyncApi.kt now writes to —
        // mainly conflicts (two devices editing the same record while both offline) and
        // push failures, so if something looks wrong after a sync, there's a trail to
        // check instead of it being a silent mystery.
        list.addView(menuRow(R.drawable.ic_receipt, "Sync History", showChevron = true) {
            openSyncHistoryDialog()
        })

        list.addView(spacer(10))

        // ---- Settings (expandable — holds all the real settings sections) ----
        val settingsContent = buildSettingsContent()
        settingsContent.visibility = View.GONE
        val settingsRow = expandableMenuRow(R.drawable.ic_settings, "Settings", target = settingsContent, iconBgHex = AppColors.teal)
        list.addView(settingsRow)
        list.addView(settingsContent)

        // ---- Backup/Restore (expandable) ----
        val backupContent = buildBackupContent()
        backupContent.visibility = View.GONE
        val backupRow = expandableMenuRow(
            R.drawable.ic_archive, "Backup/Restore",
            subtitle = "Auto backup not enabled.",
            target = backupContent,
            iconBgHex = AppColors.teal
        )
        list.addView(backupRow)
        list.addView(backupContent)

        list.addView(spacer(10))

        // ---- Logout ----
        list.addView(menuRow(R.drawable.ic_logout, "Logout", textColorHex = red, iconBgHex = red) {
            doLogout()
        })

        list.addView(spacer(20))

        root.addView(ScrollView(this).apply {
            layoutParams = LinearLayout.LayoutParams(LinearLayout.LayoutParams.MATCH_PARENT, 0, 1f)
            setBackgroundColor(Color.parseColor(bg))
            addView(list)
        })

        setContentView(root)

        loadHeaderShopName()

        applyFloatingSheetLayout()
        window.decorView.post { applyFloatingSheetLayout() }
    }

    override fun onResume() {
        super.onResume()
        // Refresh the Connected/Offline indicator every time this sheet becomes visible
        // (e.g. user toggled Wi-Fi/mobile data while Settings was open in the background).
        if (::syncRowDot.isInitialized) refreshSyncStatus()
    }

    private fun comingSoon(label: String) {
        Toast.makeText(this, "$label — Coming Soon", Toast.LENGTH_SHORT).show()
    }

    /** Opens the given activity by class name if it exists in the app; falls back to a "Coming Soon" toast otherwise.
     *  Kept only for features that don't have a real screen yet (e.g. Expense) — anything confirmed to exist
     *  (Parties, Items, Reports, Sale, Purchase, Cash & Bank) is launched directly above instead. */
    private fun tryOpenActivity(activityClassName: String, label: String) {
        try {
            val clazz = Class.forName(activityClassName)
            startActivity(Intent(this, clazz))
        } catch (e: ClassNotFoundException) {
            comingSoon(label)
        }
    }

    private fun applyFloatingSheetLayout() {
        val screenWidth = resources.displayMetrics.widthPixels
        window.setGravity(Gravity.START)
        window.setLayout(
            (screenWidth * 0.80).toInt(),
            ViewGroup.LayoutParams.MATCH_PARENT
        )
    }

    private fun doLogout() {
        getSharedPreferences("session", MODE_PRIVATE).edit().clear().apply()
        startActivity(Intent(this@SettingsActivity, LoginActivity::class.java))
        finish()
    }

    // ================= SYNC =================

    /** True if the device currently has an active network with internet capability.
     *  This is a connectivity check only (not a Firestore reachability check) — it tells
     *  the user whether the app *can* sync right now, matching how PurchaseActivity's
     *  header sync chip works. */
    // ================= PREMIUM GRADIENT HEADER (matches Product/Purchase/Sale headers) =================
    private fun buildHeader(): LinearLayout {
        val header = LinearLayout(this).apply {
            orientation = LinearLayout.HORIZONTAL
            gravity = Gravity.CENTER_VERTICAL
            setPadding(26, 48, 22, 28)
            background = gradientBg(navy, navyLight, cornerBottom = 30)
            applyElevation(this, 10f)
        }

        val iconCircle = FrameLayout(this).apply {
            val px = (56 * resources.displayMetrics.density).toInt()
            layoutParams = LinearLayout.LayoutParams(px, px)
            background = GradientDrawable().apply {
                shape = GradientDrawable.OVAL
                setColor(Color.WHITE)
                setStroke((1.5 * resources.displayMetrics.density).toInt(), Color.parseColor("#DCE3F0"))
            }
            applyElevation(this, 3f)
        }
        iconCircle.addView(ImageView(this).apply {
            setImageDrawable(tintedDrawable(R.drawable.ic_store, navy, 26))
            scaleType = ImageView.ScaleType.CENTER
            layoutParams = FrameLayout.LayoutParams(FrameLayout.LayoutParams.MATCH_PARENT, FrameLayout.LayoutParams.MATCH_PARENT)
        })
        header.addView(iconCircle)

        val textCol = LinearLayout(this).apply {
            orientation = LinearLayout.VERTICAL
            setPadding(18, 0, 0, 0)
            layoutParams = LinearLayout.LayoutParams(0, LinearLayout.LayoutParams.WRAP_CONTENT, 1f)
        }
        shopNameHeaderText = TextView(this).apply {
            text = "My Shop"
            textSize = 18f
            setTextColor(Color.WHITE)
            setTypeface(typeface, Typeface.BOLD)
            maxLines = 1
            ellipsize = android.text.TextUtils.TruncateAt.END
        }
        textCol.addView(shopNameHeaderText)
        textCol.addView(TextView(this).apply {
            text = "POINT OF SALE"
            textSize = 10.5f
            setTextColor(Color.parseColor(headerSubtitleColor))
            setTypeface(typeface, Typeface.BOLD)
            letterSpacing = 0.12f
            setPadding(0, 6, 0, 0)
        })
        header.addView(textCol)

        return header
    }

    /** Loads the saved shop name and reflects it at the top of the header (falls back to the default label). */
    private fun loadHeaderShopName() {
        lifecycleScope.launch {
            val db = PosDatabase.get(this@SettingsActivity)
            val name = db.appSettingDao().get("shop_name")?.value
            if (!name.isNullOrBlank()) {
                shopNameHeaderText.text = name
            }
        }
    }

    // ================= MENU ROW HELPERS (premium card rows) =================

    /** A simple, non-expanding premium card row: icon-in-circle + label (+ optional chevron / trailing text). */
    private fun menuRow(
        iconRes: Int,
        label: String,
        showChevron: Boolean = false,
        trailingText: String? = null,
        textColorHex: String = textDark,
        iconBgHex: String = teal,
        onClick: () -> Unit
    ): LinearLayout {
        val row = premiumCard().apply {
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
                setTextColor(Color.parseColor(teal))
                setTypeface(typeface, Typeface.BOLD)
            })
        } else if (showChevron) {
            row.addView(chevronText())
        }
        row.setOnClickListener { onClick() }
        return row
    }

    /** A premium card row with an optional subtitle line that expands/collapses a target view when tapped. */
    private fun expandableMenuRow(
        iconRes: Int,
        label: String,
        subtitle: String? = null,
        target: View
    ): LinearLayout {
        val row = premiumCard().apply {
            orientation = LinearLayout.HORIZONTAL
            gravity = Gravity.CENTER_VERTICAL
            setPadding(18, 17, 18, 17)
            isClickable = true
            isFocusable = true
        }
        row.addView(iconBadge(iconRes, navy))
        row.addView(spacerH(16))

        val textCol = LinearLayout(this).apply {
            orientation = LinearLayout.VERTICAL
            layoutParams = LinearLayout.LayoutParams(0, LinearLayout.LayoutParams.WRAP_CONTENT, 1f)
        }
        textCol.addView(TextView(this).apply {
            text = label
            textSize = 14.5f
            setTextColor(Color.parseColor(textDark))
            setTypeface(typeface, Typeface.BOLD)
        })
        if (subtitle != null) {
            textCol.addView(TextView(this).apply {
                text = subtitle
                textSize = 11f
                setTextColor(Color.parseColor(textGray))
                setPadding(0, 2, 0, 0)
            })
        }
        row.addView(textCol)

        val chevron = chevronText()
        row.addView(chevron)

        row.setOnClickListener {
            val expanding = target.visibility != View.VISIBLE
            target.visibility = if (expanding) View.VISIBLE else View.GONE
            chevron.rotation = if (expanding) 180f else 0f
        }
        return row
    }

    // ---- Vector-icon helpers (replace emoji throughout this screen with tinted drawables
    // from res/drawable, per the item-6 UI improvement pass) — same pattern as ProductActivity. ----
    private fun tintedDrawable(iconRes: Int, tintHex: String, sizeDp: Int = 16): android.graphics.drawable.Drawable? {
        val d = ContextCompat.getDrawable(this, iconRes)?.mutate() ?: return null
        d.setTint(Color.parseColor(tintHex))
        val px = (sizeDp * resources.displayMetrics.density).toInt()
        d.setBounds(0, 0, px, px)
        return d
    }

    internal fun TextView.setLeadingIcon(iconRes: Int, tintHex: String, sizeDp: Int = 16, paddingDp: Int = 8) {
        setCompoundDrawablesRelative(tintedDrawable(iconRes, tintHex, sizeDp), null, null, null)
        compoundDrawablePadding = (paddingDp * resources.displayMetrics.density).toInt()
    }

    internal fun iconBadge(iconRes: Int, colorHex: String) = ImageView(this).apply {
        setImageDrawable(tintedDrawable(iconRes, colorHex, 20))
        scaleType = ImageView.ScaleType.CENTER
        background = GradientDrawable().apply {
            shape = GradientDrawable.OVAL
            setColor(Color.parseColor(lightenTint(colorHex)))
        }
        val px = (44 * resources.displayMetrics.density).toInt()
        layoutParams = android.view.ViewGroup.LayoutParams(px, px)
    }

    private fun chevronText() = ImageView(this).apply {
        setImageDrawable(tintedDrawable(R.drawable.ic_chevron_down, teal, 18))
    }

    internal fun spacerH(widthDp: Int) = View(this).apply {
        val px = (widthDp * resources.displayMetrics.density).toInt()
        layoutParams = LinearLayout.LayoutParams(px, 1)
    }

    // ================= EXPANDABLE "SETTINGS" CONTENT (all the original sections) =================
    private fun buildSettingsContent(): LinearLayout {
        val container = LinearLayout(this).apply {
            orientation = LinearLayout.VERTICAL
            setPadding(0, 4, 0, 8)
        }

        // ---- Shop Info ----
        // FIX ("Address header footer currency tax ye field khatam kr do"): the
        // Address / Receipt Footer / Currency / Tax % fields are removed from this
        // screen — only Shop Name and Phone remain editable here now. Their stored
        // app_settings values (shop_address / receipt_footer / currency /
        // tax_percent) are left as whatever they already were — printing (which
        // reads shop_address/receipt_footer) already treats a blank value as "skip
        // this line" / falls back to the default thank-you note, so nothing else
        // needed to change there.
        val shopCard = premiumCard(R.drawable.ic_store, "Shop Information")
        shopNameField = plainField("Shop Name")
        phoneField = plainField("Phone")

        shopCard.addView(iconFieldBox(R.drawable.ic_store, "Shop Name", shopNameField))
        shopCard.addView(spacer(10))
        shopCard.addView(iconFieldBox(R.drawable.ic_phone, "Phone", phoneField))
        shopCard.addView(spacer(12))
        shopCard.addView(primaryButton("SAVE SETTINGS", navy) { saveShopSettings() })
        container.addView(shopCard)
        loadShopSettings()

        // ---- Printer ----
        val printerCard = premiumCard(R.drawable.ic_printer, "Printer Setup (58mm Bluetooth)")
        val statusRow = LinearLayout(this).apply {
            orientation = LinearLayout.HORIZONTAL
            gravity = Gravity.CENTER_VERTICAL
            background = strokedBg(border, fieldFill, 12)
            setPadding(16, 12, 16, 12)
        }
        printerStatusDot = TextView(this).apply {
            text = "●"
            textSize = 14f
            setTextColor(Color.parseColor(red))
        }
        statusRow.addView(printerStatusDot)
        statusRow.addView(spacerH(10))
        printerStatusText = TextView(this).apply {
            text = "No printer selected"
            textSize = 13f
            setTextColor(Color.parseColor(textDark))
            setTypeface(typeface, Typeface.BOLD)
        }
        statusRow.addView(printerStatusText)
        printerCard.addView(statusRow)
        printerCard.addView(spacer(12))
        loadPrinterStatus()

        val printerBtnRow = LinearLayout(this).apply { orientation = LinearLayout.HORIZONTAL }
        printerBtnRow.addView(secondaryButton("SELECT PRINTER", navy) { onSelectPrinterClicked() }.apply {
            layoutParams = LinearLayout.LayoutParams(0, LinearLayout.LayoutParams.WRAP_CONTENT, 1f).apply { setMargins(0, 0, 6, 0) }
        })
        printerBtnRow.addView(secondaryButton("TEST PRINT", teal) { onTestPrintClicked() }.apply {
            layoutParams = LinearLayout.LayoutParams(0, LinearLayout.LayoutParams.WRAP_CONTENT, 1f).apply { setMargins(6, 0, 0, 0) }
        })
        printerCard.addView(printerBtnRow)
        printerCard.addView(spacer(8))
        printerCard.addView(secondaryButton("PRINT WIDTH (garbled print? try 384)", navy) { onPrintWidthClicked() })
        container.addView(printerCard)

        // ---- Security (Login Method) ----
        val securityCard = premiumCard(R.drawable.ic_lock, "Security — Login Method")
        loginMethodGroup = RadioGroup(this).apply { orientation = LinearLayout.VERTICAL }
        passwordOnlyRadio = radioOption("Password Only")
        fingerprintOnlyRadio = radioOption("Fingerprint Only")
        bothRadio = radioOption("Both (Password + Fingerprint)")
        // "No Password" — app opens straight to the dashboard, no login screen at all
        // (see LoginActivity.onCreate — it checks this setting before building any UI).
        noPasswordRadio = radioOption("No Password (App won't lock)")
        // NEW: "OTP (Phone Number)" — activates LoginActivity's existing otpSection /
        // Firebase Phone Auth flow (applyLoginMethod's "otp" branch), which previously
        // had no way to be turned on since this radio didn't exist.
        otpRadio = radioOption("OTP (Phone Number)")
        loginMethodGroup.addView(passwordOnlyRadio)
        loginMethodGroup.addView(fingerprintOnlyRadio)
        loginMethodGroup.addView(bothRadio)
        loginMethodGroup.addView(noPasswordRadio)
        loginMethodGroup.addView(otpRadio)
        securityCard.addView(loginMethodGroup)

        loginMethodGroup.setOnCheckedChangeListener { _, checkedId ->
            val method = when (checkedId) {
                fingerprintOnlyRadio.id -> "fingerprint"
                bothRadio.id -> "both"
                noPasswordRadio.id -> "none"
                otpRadio.id -> "otp"
                else -> "password"
            }
            lifecycleScope.launch {
                val db = PosDatabase.get(this@SettingsActivity)
                db.appSettingDao().set(AppSetting("login_method", method))
                com.grocerypos.v11.AppLock.updateCachedLoginMethod(method)
            }
        }
        container.addView(securityCard)
        loadLoginMethodSetting()

        // ---- Change Username / Password ----
        val loginCard = premiumCard(R.drawable.ic_key, "Change Login (Username / Password)")
        val session = getSharedPreferences("session", MODE_PRIVATE)
        val loggedInUsername = session.getString("username", "") ?: ""

        currentUsernameField = plainField("Current Username").apply {
            setText(loggedInUsername)
            isEnabled = false
            setTextColor(Color.parseColor(textGray))
        }
        newUsernameField = plainField("New Username (blank = keep same)")
        newPasswordField = plainField("New Password (blank = keep same)").apply {
            inputType = InputType.TYPE_CLASS_TEXT or InputType.TYPE_TEXT_VARIATION_PASSWORD
        }

        loginCard.addView(iconFieldBox(R.drawable.ic_person, "Current Username", currentUsernameField, muted = true))
        loginCard.addView(spacer(10))
        loginCard.addView(iconFieldBox(R.drawable.ic_add, "New Username", newUsernameField))
        loginCard.addView(spacer(10))
        loginCard.addView(passwordFieldBox(R.drawable.ic_lock, "New Password", newPasswordField))
        loginCard.addView(spacer(12))
        loginCard.addView(primaryButton("UPDATE LOGIN", navy) { updateLogin(loggedInUsername) })
        container.addView(loginCard)

        // ---- Language ----
        val languageCard = premiumCard(R.drawable.ic_globe, "Language")
        val langRow = LinearLayout(this).apply { orientation = LinearLayout.HORIZONTAL }
        val englishBtn = pillToggleButton("English")
        val urduBtn = pillToggleButton("اردو")
        fun refreshLanguageButtons() {
            val isUrdu = com.grocerypos.v11.util.Loc.isUrdu(this)
            englishBtn.background = if (!isUrdu) roundedBg(navy, 30) else strokedBg(border, fieldFill, 30)
            englishBtn.setTextColor(if (!isUrdu) Color.WHITE else Color.parseColor(textGray))
            urduBtn.background = if (isUrdu) roundedBg(navy, 30) else strokedBg(border, fieldFill, 30)
            urduBtn.setTextColor(if (isUrdu) Color.WHITE else Color.parseColor(textGray))
        }
        englishBtn.setOnClickListener {
            com.grocerypos.v11.util.Loc.setLanguage(this, "en")
            refreshLanguageButtons()
            recreate()
        }
        urduBtn.setOnClickListener {
            com.grocerypos.v11.util.Loc.setLanguage(this, "ur")
            refreshLanguageButtons()
            recreate()
        }
        englishBtn.layoutParams = LinearLayout.LayoutParams(0, LinearLayout.LayoutParams.WRAP_CONTENT, 1f).apply { setMargins(0, 0, 5, 0) }
        urduBtn.layoutParams = LinearLayout.LayoutParams(0, LinearLayout.LayoutParams.WRAP_CONTENT, 1f).apply { setMargins(5, 0, 0, 0) }
        langRow.addView(englishBtn)
        langRow.addView(urduBtn)
        languageCard.addView(langRow)
        refreshLanguageButtons()
        container.addView(languageCard)

        // ---- Users ----
        val usersCard = premiumCard(R.drawable.ic_people, "Users & Account")
        usersCard.addView(secondaryButton("MANAGE USERS", navy) {
            startActivity(Intent(this@SettingsActivity, UserManagementActivity::class.java))
        })
        container.addView(usersCard)

        return container
    }

    // ================= EXPANDABLE "BACKUP/RESTORE" CONTENT =================
    private fun buildBackupContent(): LinearLayout {
        val container = LinearLayout(this).apply {
            orientation = LinearLayout.VERTICAL
            setPadding(0, 4, 0, 8)
        }
        val backupCard = premiumCard(R.drawable.ic_archive, "Backup & Restore")
        backupCard.addView(primaryButton("BACKUP NOW", teal) { onBackupClicked() })
        backupCard.addView(spacer(10))
        backupCard.addView(primaryButton("RESTORE BACKUP", red) { onRestoreClicked() })
        backupCard.addView(spacer(10))
        backupCard.addView(primaryButton("IMPORT BACKUP FILE", navy) { importBackupLauncher.launch(arrayOf("*/*")) })
        backupCard.addView(spacer(10))
        backupCard.addView(primaryButton("BACKUP PASSWORD DEKHEIN", navy) { onViewBackupPasswordClicked() })
        backupCard.addView(spacer(6))
        backupCard.addView(TextView(this).apply {
            text = "Backups ab encrypted hoti hain (.ibbackup). BACKUP PASSWORD DEKHEIN se apna password kahin surakshit likh kar rakh lein — dusre phone par ya app reinstall ke baad restore karne ke liye zaroori hoga."
            textSize = 11f
            setTextColor(Color.parseColor(textGray))
        })
        backupCard.addView(spacer(6))
        backupCard.addView(TextView(this).apply {
            text = "Agar RESTORE BACKUP list mein sahi backup nahi dikh raha (jaise app reinstall karne ke baad), to IMPORT BACKUP FILE se Downloads ya kahin bhi se backup file seedha select kar ke restore karein."
            textSize = 11f
            setTextColor(Color.parseColor(textGray))
        })
        backupCard.addView(spacer(12))
        backupCard.addView(LinearLayout(this).apply {
            orientation = LinearLayout.HORIZONTAL
            background = strokedBg("#F4C9CB", "#FDEEEE", 12)
            setPadding(16, 12, 16, 12)
            addView(ImageView(this@SettingsActivity).apply {
                setImageDrawable(tintedDrawable(R.drawable.ic_warning, red, 16))
                val px = (16 * resources.displayMetrics.density).toInt()
                layoutParams = LinearLayout.LayoutParams(px, px).apply {
                    marginEnd = (8 * resources.displayMetrics.density).toInt()
                }
            })
            addView(TextView(this@SettingsActivity).apply {
                text = "Restore purani backup laata hai aur is waqt ka sara naya data (jo backup ke baad add hua) permanently mita deta hai. Sirf tab use karein jab aapko waqai purani state par jaana ho."
                textSize = 11.5f
                setTextColor(Color.parseColor(red))
                layoutParams = LinearLayout.LayoutParams(0, LinearLayout.LayoutParams.WRAP_CONTENT, 1f)
            })
        })
        container.addView(backupCard)
        return container
    }

    // ================= UI HELPERS =================

    /** Premium card container — matches Product/Purchase/Sale's premiumCard() pattern. */
    internal fun premiumCard() = LinearLayout(this).apply {
        orientation = LinearLayout.VERTICAL
        background = strokedBg(border, cardWhite, 18)
        layoutParams = LinearLayout.LayoutParams(
            LinearLayout.LayoutParams.MATCH_PARENT, LinearLayout.LayoutParams.WRAP_CONTENT
        ).apply { setMargins(0, 0, 0, 14) }
        applyElevation(this, 3f)
    }

    /** Premium card with a small icon-badge section title inside — used for the Settings sub-sections. */
    private fun premiumCard(iconRes: Int, title: String) = premiumCard().apply {
        setPadding(20, 18, 20, 18)
        addView(sectionLabel(iconRes, title))
        addView(spacer(4))
    }

    private fun sectionLabel(iconRes: Int, label: String) = LinearLayout(this).apply {
        orientation = LinearLayout.HORIZONTAL
        gravity = Gravity.CENTER_VERTICAL
        setPadding(0, 0, 0, 14)
        addView(ImageView(this@SettingsActivity).apply {
            setImageDrawable(tintedDrawable(iconRes, teal, 15))
            val px = (15 * resources.displayMetrics.density).toInt()
            layoutParams = LinearLayout.LayoutParams(px, px).apply {
                marginEnd = (8 * resources.displayMetrics.density).toInt()
            }
        })
        addView(TextView(this@SettingsActivity).apply {
            text = label
            textSize = 13.5f
            setTextColor(Color.parseColor(teal))
            setTypeface(typeface, Typeface.BOLD)
            letterSpacing = 0.01f
        })
    }

    private fun microLabel(label: String) = TextView(this).apply {
        text = label.uppercase()
        textSize = 10f
        setTextColor(Color.parseColor(textGray))
        setTypeface(typeface, Typeface.BOLD)
        setPadding(0, 0, 0, 4)
        letterSpacing = 0.03f
    }

    private fun plainField(hint: String) = EditText(this).apply {
        this.hint = hint
        setHintTextColor(Color.parseColor(textGray))
        setTextColor(Color.parseColor(textDark))
        background = null
        textSize = 14.5f
    }

    /** Icon-prefixed labeled field box — matches ProductActivity's fieldBox(icon) pattern. */
    private fun iconFieldBox(iconRes: Int, label: String, field: EditText, muted: Boolean = false) = LinearLayout(this).apply {
        orientation = LinearLayout.VERTICAL
        background = strokedBg(border, if (muted) "#F1F3F5" else fieldFill, 12)
        setPadding(16, 10, 16, 10)
        addView(microLabel(label))
        val row = LinearLayout(this@SettingsActivity).apply { orientation = LinearLayout.HORIZONTAL; gravity = Gravity.CENTER_VERTICAL }
        row.addView(ImageView(this@SettingsActivity).apply {
            setImageDrawable(tintedDrawable(iconRes, textGray, 15))
            val px = (15 * resources.displayMetrics.density).toInt()
            layoutParams = LinearLayout.LayoutParams(px, px).apply {
                marginEnd = (8 * resources.displayMetrics.density).toInt()
            }
        })
        (field.parent as? ViewGroup)?.removeView(field)
        field.layoutParams = LinearLayout.LayoutParams(0, LinearLayout.LayoutParams.WRAP_CONTENT, 1f)
        row.addView(field)
        addView(row)
    }

    private fun passwordFieldBox(iconRes: Int, label: String, field: EditText) = LinearLayout(this).apply {
        orientation = LinearLayout.VERTICAL
        background = strokedBg(border, fieldFill, 12)
        setPadding(16, 10, 16, 10)
        addView(microLabel(label))
        val row = LinearLayout(this@SettingsActivity).apply { orientation = LinearLayout.HORIZONTAL; gravity = Gravity.CENTER_VERTICAL }
        row.addView(ImageView(this@SettingsActivity).apply {
            setImageDrawable(tintedDrawable(iconRes, textGray, 15))
            val px = (15 * resources.displayMetrics.density).toInt()
            layoutParams = LinearLayout.LayoutParams(px, px).apply {
                marginEnd = (8 * resources.displayMetrics.density).toInt()
            }
        })
        (field.parent as? ViewGroup)?.removeView(field)
        field.layoutParams = LinearLayout.LayoutParams(0, LinearLayout.LayoutParams.WRAP_CONTENT, 1f)
        row.addView(field)

        val toggle = TextView(this@SettingsActivity).apply {
            text = "SHOW"
            textSize = 10.5f
            setTypeface(typeface, Typeface.BOLD)
            setTextColor(Color.WHITE)
            background = roundedBg(teal, 20)
            setPadding(16, 6, 16, 6)
            var visible = false
            setOnClickListener {
                visible = !visible
                field.inputType = if (visible)
                    InputType.TYPE_CLASS_TEXT or InputType.TYPE_TEXT_VARIATION_VISIBLE_PASSWORD
                else
                    InputType.TYPE_CLASS_TEXT or InputType.TYPE_TEXT_VARIATION_PASSWORD
                field.setSelection(field.text.length)
                text = if (visible) "HIDE" else "SHOW"
            }
        }
        row.addView(spacerH(8))
        row.addView(toggle)
        addView(row)
    }

    private fun radioOption(label: String) = RadioButton(this).apply {
        text = label
        setTextColor(Color.parseColor(textDark))
        textSize = 13.5f
        setPadding(8, 10, 0, 10)
    }

    private fun primaryButton(label: String, colorHex: String, onClick: () -> Unit) = Button(this).apply {
        text = label
        setTextColor(Color.WHITE)
        textSize = 13.5f
        isAllCaps = false
        setTypeface(typeface, Typeface.BOLD)
        background = roundedBg(colorHex, 14)
        setPadding(0, 20, 0, 20)
        setOnClickListener { onClick() }
        applyElevation(this, 3f)
    }

    private fun secondaryButton(label: String, colorHex: String, onClick: () -> Unit) = Button(this).apply {
        text = label
        setTextColor(Color.parseColor(colorHex))
        textSize = 12.5f
        isAllCaps = false
        setTypeface(typeface, Typeface.BOLD)
        background = strokedBg(colorHex, cardWhite, 14)
        setPadding(0, 16, 0, 16)
        setOnClickListener { onClick() }
    }

    /** Pill-style toggle button — matches the unit chip / spinner pill pattern used elsewhere. */
    private fun pillToggleButton(label: String) = Button(this).apply {
        text = label
        textSize = 12.5f
        isAllCaps = false
        setTypeface(typeface, Typeface.BOLD)
        setPadding(0, 14, 0, 14)
        minHeight = 0
        stateListAnimator = null
    }

    private fun gradientBg(startHex: String, endHex: String, cornerTop: Int = 0, cornerBottom: Int = 0) = GradientDrawable(
        GradientDrawable.Orientation.TL_BR, intArrayOf(Color.parseColor(startHex), Color.parseColor(endHex))
    ).apply {
        val density = resources.displayMetrics.density
        cornerRadii = floatArrayOf(
            cornerTop * density, cornerTop * density,
            cornerTop * density, cornerTop * density,
            cornerBottom * density, cornerBottom * density,
            cornerBottom * density, cornerBottom * density
        )
    }

    /** Same lightening approach as CashActivity's stat-card tint — used for menu-row icon badges. */
    private fun lightenTint(colorHex: String): String {
        val base = Color.parseColor(colorHex)
        val factor = 0.82f
        val r = (Color.red(base) + (255 - Color.red(base)) * factor).toInt().coerceIn(0, 255)
        val g = (Color.green(base) + (255 - Color.green(base)) * factor).toInt().coerceIn(0, 255)
        val bl = (Color.blue(base) + (255 - Color.blue(base)) * factor).toInt().coerceIn(0, 255)
        return String.format("#%02X%02X%02X", r, g, bl)
    }

    // spacer() now comes from the shared UiHelpers.kt (item #24 dedup) — was a
    // byte-identical private copy here before.

    // ================= SHOP INFO SAVE/LOAD =================
    private fun loadShopSettings() {
        lifecycleScope.launch {
            val db = PosDatabase.get(this@SettingsActivity)
            shopNameField.setText(db.appSettingDao().get("shop_name")?.value ?: "")
            phoneField.setText(db.appSettingDao().get("shop_phone")?.value ?: "")
        }
    }

    private fun saveShopSettings() {
        lifecycleScope.launch {
            val db = PosDatabase.get(this@SettingsActivity)
            val newShopName = shopNameField.text.toString().trim()
            val newPhone = phoneField.text.toString().trim()
            db.appSettingDao().set(AppSetting("shop_name", newShopName))
            db.appSettingDao().set(AppSetting("shop_phone", newPhone))
            // NEW (App Settings sync): push these shop-identity fields so every
            // device shares the same name/phone — see
            // SyncQueueHelper.SYNCED_APP_SETTING_KEYS for exactly which keys sync
            // (printer/login/session settings deliberately stay local-only).
            SyncQueueHelper.enqueueAppSetting(db, AppSetting("shop_name", newShopName))
            SyncQueueHelper.enqueueAppSetting(db, AppSetting("shop_phone", newPhone), this@SettingsActivity)
            if (newShopName.isNotEmpty()) {
                shopNameHeaderText.text = newShopName
            }
            Toast.makeText(this@SettingsActivity, "Settings saved", Toast.LENGTH_SHORT).show()
        }
    }

    // ================= SECURITY (LOGIN METHOD) =================
    private fun loadLoginMethodSetting() {
        lifecycleScope.launch {
            val db = PosDatabase.get(this@SettingsActivity)
            when (db.appSettingDao().get("login_method")?.value ?: "password") {
                "fingerprint" -> fingerprintOnlyRadio.isChecked = true
                "both" -> bothRadio.isChecked = true
                "none" -> noPasswordRadio.isChecked = true
                "otp" -> otpRadio.isChecked = true
                else -> passwordOnlyRadio.isChecked = true
            }
        }
    }

    // ================= PRINTER =================
    private fun loadPrinterStatus() {
        lifecycleScope.launch {
            val db = PosDatabase.get(this@SettingsActivity)
            val printerName = db.appSettingDao().get("printer_name")?.value
            if (!printerName.isNullOrEmpty()) {
                printerStatusText.text = "Selected: $printerName"
                printerStatusDot.setTextColor(Color.parseColor(teal))
            } else {
                printerStatusText.text = "No printer selected"
                printerStatusDot.setTextColor(Color.parseColor(red))
            }
        }
    }

    @SuppressLint("MissingPermission")
    private fun onSelectPrinterClicked() {
        if (!PrinterHelper.hasBluetoothPermission(this)) {
            PrinterHelper.requestBluetoothPermission(this, BT_PERMISSION_REQUEST_CODE)
            Toast.makeText(this, "Bluetooth permission dein, phir dobara SELECT PRINTER dabayein", Toast.LENGTH_LONG).show()
            return
        }

        val devices: List<BluetoothDevice> = PrinterHelper.pairedDevices(this)
        if (devices.isEmpty()) {
            Toast.makeText(
                this,
                "Koi paired Bluetooth printer nahi mila. Pehle phone ki Bluetooth Settings se printer ko pair karein.",
                Toast.LENGTH_LONG
            ).show()
            return
        }

        val names = devices.map { it.name ?: it.address }.toTypedArray()
        AlertDialog.Builder(this)
            .setTitle("Select 58mm Printer")
            .setItems(names) { _, which ->
                val device = devices[which]
                savePrinter(device.name ?: "Printer", device.address)
            }
            .setNegativeButton("Cancel", null)
            .show()
    }

    private fun savePrinter(printerName: String, mac: String) {
        lifecycleScope.launch {
            val db = PosDatabase.get(this@SettingsActivity)
            db.appSettingDao().set(AppSetting("printer_name", printerName))
            db.appSettingDao().set(AppSetting("printer_mac", mac))
            db.appSettingDao().set(AppSetting("printer_width", "58"))
            printerStatusText.text = "Selected: $printerName"
            printerStatusDot.setTextColor(Color.parseColor(teal))
            Toast.makeText(this@SettingsActivity, "Printer saved: $printerName", Toast.LENGTH_SHORT).show()
        }
    }

    private fun onTestPrintClicked() {
        lifecycleScope.launch {
            val db = PosDatabase.get(this@SettingsActivity)
            val mac = db.appSettingDao().get("printer_mac")?.value
            if (mac.isNullOrEmpty()) {
                Toast.makeText(this@SettingsActivity, "Pehle printer select karein", Toast.LENGTH_SHORT).show()
                return@launch
            }
            val shopName = db.appSettingDao().get("shop_name")?.value ?: "My Shop"
            val dots = PrinterHelper.normalizeDotsWidth(db.appSettingDao().get("printer_dots")?.value?.toIntOrNull())
            // Goes through the same raster pipeline real bills use (the old plain-text
            // test could pass even when bill printing was broken), and off the UI thread.
            val ok = withContext(Dispatchers.IO) {
                PrinterHelper.testPrintRaster(
                    this@SettingsActivity,
                    PrinterHelper.PrinterType.BLUETOOTH,
                    mac,
                    shopName,
                    dots
                )
            }
            Toast.makeText(
                this@SettingsActivity,
                if (ok) "Test print bhej diya ($dots dots)" else "Print fail ho gaya. Printer on hai aur range mein hai check karein.",
                Toast.LENGTH_LONG
            ).show()
        }
    }

    /** Lets the owner pick the printer head width. 384 = standard 58mm; 576 = 80mm. */
    private fun onPrintWidthClicked() {
        lifecycleScope.launch {
            val db = PosDatabase.get(this@SettingsActivity)
            val current = PrinterHelper.normalizeDotsWidth(db.appSettingDao().get("printer_dots")?.value?.toIntOrNull())
            val options = intArrayOf(384, 448, 512, 576)
            val labels = arrayOf(
                "384 dots — standard 58mm (recommended)",
                "448 dots",
                "512 dots",
                "576 dots — 80mm printer"
            )
            AlertDialog.Builder(this@SettingsActivity)
                .setTitle("Print Width")
                .setSingleChoiceItems(labels, options.indexOf(current).coerceAtLeast(0)) { dialog, which ->
                    lifecycleScope.launch {
                        db.appSettingDao().set(AppSetting("printer_dots", options[which].toString()))
                        Toast.makeText(
                            this@SettingsActivity,
                            "Print width ${options[which]} dots save ho gayi. TEST PRINT karke check karein.",
                            Toast.LENGTH_LONG
                        ).show()
                    }
                    dialog.dismiss()
                }
                .setNegativeButton("Cancel", null)
                .show()
        }
    }

    // ================= BACKUP / RESTORE =================
    // FIX (perf): backupNow() does a WAL checkpoint + file copy + AES encryption + a
    // second copy into Downloads — all real disk/CPU work that used to run directly
    // on the main thread here, freezing the UI for the duration of every backup.
    // Moved onto Dispatchers.IO; only the Toast/share (UI work) hops back to Main.
    private fun onBackupClicked() {
        lifecycleScope.launch {
            val file = withContext(Dispatchers.IO) { BackupHelper.backupNow(this@SettingsActivity) }
            if (file != null) {
                Toast.makeText(this@SettingsActivity, "Backup ho gaya: ${file.name}", Toast.LENGTH_LONG).show()
                BackupHelper.shareBackup(this@SettingsActivity, file)
            } else {
                Toast.makeText(this@SettingsActivity, "Backup fail: ${BackupHelper.lastError}", Toast.LENGTH_LONG).show()
            }
        }
    }

    /** Shows the current backup password (view/copy) — the owner should save this
     * somewhere safe outside the phone; it's needed to restore a backup on a
     * different device, or after reinstalling the app. */
    private fun onViewBackupPasswordClicked() {
        val password = BackupPasswordStore.getOrCreate(this)
        val container = LinearLayout(this).apply {
            orientation = LinearLayout.VERTICAL
            setPadding(48, 24, 48, 0)
        }
        container.addView(TextView(this).apply {
            text = "Ye password aapki backup files ko decrypt karne ke liye chahiye — " +
                "isay kahin surakshit likh kar rakh lein (dusre phone par restore karne ke liye zaroori hai):"
            textSize = 13.5f
            setTextColor(Color.parseColor(textDark))
        })
        val passwordField = EditText(this).apply {
            setText(password)
            isFocusable = false
            isClickable = false
            setPadding(0, 32, 0, 0)
            textSize = 18f
            setTextColor(Color.parseColor(textDark))
        }
        container.addView(passwordField)

        AlertDialog.Builder(this)
            .setTitle("Backup Password")
            .setView(container)
            .setPositiveButton("Copy") { _, _ ->
                val clipboard = getSystemService(CLIPBOARD_SERVICE) as android.content.ClipboardManager
                clipboard.setPrimaryClip(android.content.ClipData.newPlainText("Backup Password", password))
                Toast.makeText(this, "Password copy ho gaya", Toast.LENGTH_SHORT).show()
            }
            .setNeutralButton("Change") { _, _ -> onChangeBackupPasswordClicked() }
            .setNegativeButton("Band Karein", null)
            .show()
    }

    private fun onChangeBackupPasswordClicked() {
        val field = EditText(this).apply {
            hint = "Naya password"
            setPadding(48, 32, 48, 0)
        }
        AlertDialog.Builder(this)
            .setTitle("Backup Password Badlein")
            .setMessage("Yaad rahe: purani backups is naye password se decrypt nahi hongi — unke liye purana password chahiye hoga.")
            .setView(field)
            .setPositiveButton("Save") { _, _ ->
                val newPass = field.text.toString().trim()
                if (newPass.length < 8) {
                    Toast.makeText(this, "Password kam se kam 8 characters ka ho", Toast.LENGTH_SHORT).show()
                } else {
                    BackupPasswordStore.setPassword(this, newPass)
                    Toast.makeText(this, "Password update ho gaya", Toast.LENGTH_SHORT).show()
                }
            }
            .setNegativeButton("Cancel", null)
            .show()
    }

    private fun onRestoreClicked() {
        val backups = BackupHelper.listBackups(this)
        if (backups.isEmpty()) {
            Toast.makeText(this, "Koi backup nahi mila", Toast.LENGTH_SHORT).show()
            return
        }
        val fmt = SimpleDateFormat("dd MMM yyyy, hh:mm a", Locale.getDefault())
        val labels = backups.mapIndexed { index, file ->
            val dateLabel = fmt.format(java.util.Date(file.lastModified()))
            if (index == 0) "$dateLabel  (most recent)" else dateLabel
        }.toTypedArray()

        AlertDialog.Builder(this)
            .setTitle("Select Backup to Restore")
            .setItems(labels) { _, which ->
                confirmRestore(backups[which], labels[which])
            }
            .setNegativeButton("Cancel", null)
            .show()
    }

    private fun confirmRestore(file: java.io.File, dateLabel: String) {
        val container = LinearLayout(this).apply {
            orientation = LinearLayout.VERTICAL
            setPadding(48, 24, 48, 0)
        }
        container.addView(TextView(this).apply {
            text = "Ye backup ($dateLabel) is waqt ke current data ko OVERWRITE kar dega.\n\n" +
                "Iska matlab: is backup ke baad add ki gayi tamam sales, purchases, aur baaki entries HAMESHA ke liye mit jayengi. Ye wapis nahi hoga."
            textSize = 13.5f
            setTextColor(Color.parseColor(textDark))
        })
        val checkBox = CheckBox(this).apply {
            text = "Mujhe samajh aa gaya, aage badhein"
            setTextColor(Color.parseColor(textDark))
            setPadding(0, 28, 0, 0)
        }
        container.addView(checkBox)

        val dialog = AlertDialog.Builder(this)
            .setTitle("Restore Backup?")
            .setView(container)
            .setPositiveButton("Restore", null)
            .setNegativeButton("Cancel", null)
            .create()

        dialog.setOnShowListener {
            val positiveBtn = dialog.getButton(AlertDialog.BUTTON_POSITIVE)
            positiveBtn.isEnabled = false
            positiveBtn.setTextColor(Color.parseColor(red))
            checkBox.setOnCheckedChangeListener { _, isChecked -> positiveBtn.isEnabled = isChecked }
            positiveBtn.setOnClickListener {
                dialog.dismiss()
                if (BackupHelper.needsPassword(file)) {
                    promptPasswordAndRestore { pass -> runRestore { BackupHelper.restore(this, file, pass) } }
                } else {
                    runRestore { BackupHelper.restore(this, file) }
                }
            }
        }
        dialog.show()
    }

    /** Prompts for the backup password, pre-filled with this device's saved one
     * (same-device restore is then just tap-confirm; a different/reinstalled
     * device needs the owner to type in the password they saved earlier). */
    private fun promptPasswordAndRestore(onPassword: (String) -> Unit) {
        val field = EditText(this).apply {
            setText(BackupPasswordStore.getOrCreate(this@SettingsActivity))
            setPadding(48, 32, 48, 0)
        }
        AlertDialog.Builder(this)
            .setTitle("Backup Password Dalein")
            .setView(field)
            .setPositiveButton("Restore") { _, _ -> onPassword(field.text.toString()) }
            .setNegativeButton("Cancel", null)
            .show()
    }

    // FIX (perf): restore also does real file I/O (+ decryption) — same main-thread
    // freeze issue as backup. Moved onto Dispatchers.IO.
    private fun runRestore(action: () -> Boolean) {
        lifecycleScope.launch {
            val ok = withContext(Dispatchers.IO) { action() }
            if (ok) {
                Toast.makeText(this@SettingsActivity, "Restore ho gaya. App ko dobara open karein.", Toast.LENGTH_LONG).show()
            } else {
                Toast.makeText(this@SettingsActivity, "Restore fail ho gaya — password check karein", Toast.LENGTH_LONG).show()
            }
        }
    }

    /** Same confirmation flow as [confirmRestore], but for a file picked via the
     * system document picker (see [importBackupLauncher]) instead of one already
     * sitting in the app's own Backups folder. */
    private fun confirmRestoreFromUri(uri: Uri) {
        val displayName = try {
            contentResolver.query(uri, null, null, null, null)?.use { cursor ->
                val nameIndex = cursor.getColumnIndex(OpenableColumns.DISPLAY_NAME)
                if (cursor.moveToFirst() && nameIndex >= 0) cursor.getString(nameIndex) else null
            }
        } catch (e: Exception) { null } ?: "selected file"

        val container = LinearLayout(this).apply {
            orientation = LinearLayout.VERTICAL
            setPadding(48, 24, 48, 0)
        }
        container.addView(TextView(this).apply {
            text = "Ye backup ($displayName) is waqt ke current data ko OVERWRITE kar dega.\n\n" +
                "Iska matlab: is backup ke baad add ki gayi tamam sales, purchases, aur baaki entries HAMESHA ke liye mit jayengi. Ye wapis nahi hoga.\n\n" +
                "Agar ye galat file hai to Cancel dabayein."
            textSize = 13.5f
            setTextColor(Color.parseColor(textDark))
        })
        val checkBox = CheckBox(this).apply {
            text = "Mujhe samajh aa gaya, aage badhein"
            setTextColor(Color.parseColor(textDark))
            setPadding(0, 28, 0, 0)
        }
        container.addView(checkBox)

        val dialog = AlertDialog.Builder(this)
            .setTitle("Restore Backup?")
            .setView(container)
            .setPositiveButton("Restore", null)
            .setNegativeButton("Cancel", null)
            .create()

        dialog.setOnShowListener {
            val positiveBtn = dialog.getButton(AlertDialog.BUTTON_POSITIVE)
            positiveBtn.isEnabled = false
            positiveBtn.setTextColor(Color.parseColor(red))
            checkBox.setOnCheckedChangeListener { _, isChecked -> positiveBtn.isEnabled = isChecked }
            positiveBtn.setOnClickListener {
                dialog.dismiss()
                // We can't tell if the picked file is encrypted until it's read, so
                // always ask for the password — restoreFromUri only uses it if the
                // file turns out to actually need one (ignored for old plain .db files).
                promptPasswordAndRestore { pass ->
                    runRestore { BackupHelper.restoreFromUri(this, uri, pass) }
                }
            }
        }
        dialog.show()
    }

    // ================= LOGIN =================
    private fun updateLogin(currentUsername: String) {
        if (currentUsername.isEmpty()) {
            Toast.makeText(this, "Login session nahi mila, dobara login karein", Toast.LENGTH_SHORT).show()
            return
        }
        val newUsername = newUsernameField.text.toString().trim()
        val newPassword = newPasswordField.text.toString()

        lifecycleScope.launch {
            val db = PosDatabase.get(this@SettingsActivity)
            val user = db.userDao().find(currentUsername)
            if (user == null) {
                Toast.makeText(this@SettingsActivity, "User nahi mila", Toast.LENGTH_SHORT).show()
                return@launch
            }

            val finalUsername = if (newUsername.isNotEmpty()) newUsername else user.username
            // FIX (Phase 4 - Security): a newly typed password is now hashed before
            // saving (previously stored as-typed, plain text). If left blank, the
            // existing passwordHash is kept unchanged either way.
            val finalPassword = if (newPassword.isNotEmpty()) PasswordHasher.hash(newPassword) else user.passwordHash

            val updatedUser = User(
                username = finalUsername,
                displayName = user.displayName,
                role = user.role,
                passwordHash = finalPassword,
                active = true,
                phone = user.phone
            )
            db.userDao().upsert(updatedUser)

            if (finalUsername != currentUsername) {
                db.userDao().delete(currentUsername)
                SyncQueueHelper.enqueueDelete(db, "user", SyncQueueHelper.userEntityId(user), this@SettingsActivity)
                getSharedPreferences("session", MODE_PRIVATE).edit()
                    .putString("username", finalUsername).apply()
                currentUsernameField.setText(finalUsername)
            }

            // ---- Queue this change so it pushes up to Firebase ----
            SyncQueueHelper.enqueue(
                db = db,
                entityType = "user",
                entityId = SyncQueueHelper.userEntityId(updatedUser),
                operation = "upsert",
                payloadJson = SyncQueueHelper.userJson(updatedUser)
            )
            SyncQueueHelper.trigger(this@SettingsActivity)

            Toast.makeText(this@SettingsActivity, "Login updated", Toast.LENGTH_SHORT).show()
            newUsernameField.text.clear()
            newPasswordField.text.clear()
        }
    }
}

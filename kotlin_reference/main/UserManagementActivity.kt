package com.grocerypos.v11.ui

import android.graphics.Color
import android.graphics.Typeface
import android.graphics.drawable.GradientDrawable
import android.os.Build
import android.os.Bundle
import android.text.InputType
import android.view.Gravity
import android.view.View
import android.view.ViewGroup
import android.view.ViewOutlineProvider
import android.widget.*
import androidx.appcompat.app.AlertDialog
import androidx.appcompat.app.AppCompatActivity
import androidx.biometric.BiometricManager
import androidx.biometric.BiometricPrompt
import androidx.core.content.ContextCompat
import androidx.lifecycle.lifecycleScope
import com.grocerypos.v11.PasswordHasher
import com.grocerypos.v11.PosDatabase
import com.grocerypos.v11.Audit
import com.grocerypos.v11.R
import com.grocerypos.v11.SyncQueueHelper
import com.grocerypos.v11.User
import kotlinx.coroutines.flow.collectLatest
import kotlinx.coroutines.launch
import com.grocerypos.v11.ui.components.*

class UserManagementActivity : AppCompatActivity() {

    // Pulled from ThemeManager so this screen respects dark mode. Header/button
    // gradients were two-tone (primary/primaryDark, green/#158A5C); now flat.
    private var bg = "#F3F2FA"
    private var cardBg = "#FFFFFF"
    private var primary = "#4A3AFF"
    private var primaryDark = "#4A3AFF"
    private var green = "#1FA971"
    private var red = "#E5484D"
    private var redDark = "#E5484D"
    private var blue = "#2F6FED"
    private var amber = "#F5A524"
    private var textDark = "#1A1A2E"
    private var textGray = "#8A8A9E"
    private var border = "#E7E5F3"
    private var fieldFill = "#FAFAFF"

    private fun loadThemeColors() {
        val p = com.grocerypos.v11.util.ThemeManager.palette(this)
        bg = p.bg
        cardBg = p.cardWhite
        primary = p.flatPurpleFg
        primaryDark = p.flatPurpleFg
        green = p.flatTealFg
        red = p.red
        redDark = p.red
        blue = p.flatBlueFg
        amber = p.flatAmberFg
        textDark = p.textDark
        textGray = p.textMuted
        border = p.border
        fieldFill = p.fieldFill
    }

    private lateinit var listContainer: LinearLayout
    private lateinit var usernameField: EditText
    private lateinit var displayNameField: EditText
    private lateinit var phoneField: EditText
    private lateinit var passwordField: EditText
    private lateinit var roleSpinner: Spinner
    private val roles = listOf("admin", "manager", "cashier")

    override fun onCreate(b: Bundle?) {
        super.onCreate(b)
        loadThemeColors()

        val session = getSharedPreferences("session", MODE_PRIVATE)
        val myRole = session.getString("role", "cashier") ?: "cashier"
        val myUsername = session.getString("username", "") ?: ""
        if (myRole != "admin") {
            Toast.makeText(this, "Sirf Admin is screen ko access kar sakta hai", Toast.LENGTH_LONG).show()
            finish()
            return
        }

        // LOCK: User Management is the most sensitive screen in the app (it can create
        // admins, reset passwords, delete users), so it's now gated behind its own
        // verify step every time it's opened — separate from whatever the app-wide
        // Settings > Security login method is set to. Fingerprint is tried first
        // automatically; if it's unavailable or the person fails/cancels it, the
        // password field right below is always there as a fallback. Only once
        // verify succeeds does buildManagementUi() actually construct the real screen.
        showLockScreen(myUsername)
    }

    // ================= LOCK SCREEN =================
    private lateinit var lockPasswordField: EditText
    private lateinit var lockErrorText: TextView

    private fun showLockScreen(myUsername: String) {
        val outer = LinearLayout(this).apply {
            orientation = LinearLayout.VERTICAL
            gravity = Gravity.CENTER
            setPadding(40, 60, 40, 60)
            setBackgroundColor(Color.parseColor(bg))
        }

        outer.addView(ImageView(this).apply {
            setImageDrawable(tintedDrawable(R.drawable.ic_lock, "#FFFFFF", 36))
            scaleType = ImageView.ScaleType.CENTER
            background = ovalBg(primary)
            val px = (86 * resources.displayMetrics.density).toInt()
            layoutParams = LinearLayout.LayoutParams(px, px).apply { gravity = Gravity.CENTER_HORIZONTAL }
        })
        outer.addView(spacer(22))
        outer.addView(TextView(this).apply {
            text = "Manage Users Locked"
            textSize = 18f
            gravity = Gravity.CENTER
            setTextColor(Color.parseColor(textDark))
            setTypeface(typeface, Typeface.BOLD)
        })
        outer.addView(TextView(this).apply {
            text = "Aage badhne ke liye verify karein"
            textSize = 12.5f
            gravity = Gravity.CENTER
            setTextColor(Color.parseColor(textGray))
            setPadding(0, 6, 0, 0)
        })
        outer.addView(spacer(30))

        val card = LinearLayout(this).apply {
            orientation = LinearLayout.VERTICAL
            setPadding(26, 26, 26, 26)
            background = strokedBg(border, cardBg, 18)
            layoutParams = LinearLayout.LayoutParams(
                LinearLayout.LayoutParams.MATCH_PARENT, LinearLayout.LayoutParams.WRAP_CONTENT
            )
            applyElevation(this, 4f)
        }

        card.addView(primaryButton("FINGERPRINT SE VERIFY KAREIN", primary, primaryDark, R.drawable.ic_fingerprint) {
            tryLockFingerprint(myUsername)
        })
        card.addView(spacer(18))
        card.addView(TextView(this).apply {
            text = "— ya password se —"
            textSize = 11f
            gravity = Gravity.CENTER
            setTextColor(Color.parseColor(textGray))
        })
        card.addView(spacer(14))

        lockPasswordField = EditText(this).apply {
            hint = "Apna password likhein"
            setHintTextColor(Color.parseColor(textGray))
            setTextColor(Color.parseColor(textDark))
            background = null
            inputType = 0x81 // text | password
        }
        card.addView(fieldBox(R.drawable.ic_key, lockPasswordField))
        card.addView(spacer(10))

        lockErrorText = TextView(this).apply {
            text = ""
            textSize = 11.5f
            setTextColor(Color.parseColor(red))
            visibility = View.GONE
        }
        card.addView(lockErrorText)
        card.addView(spacer(8))

        card.addView(primaryButton("UNLOCK", green, green, R.drawable.ic_lock_open) {
            verifyLockPassword(myUsername)
        })

        outer.addView(card)
        setContentView(ScrollView(this).apply {
            setBackgroundColor(Color.parseColor(bg))
            addView(outer, ViewGroup.LayoutParams(ViewGroup.LayoutParams.MATCH_PARENT, ViewGroup.LayoutParams.WRAP_CONTENT))
        })

        // Auto-open the fingerprint prompt as soon as the lock screen appears, same
        // pattern as LoginActivity's auto-detect for "fingerprint only" mode — the
        // password field underneath stays ready in case fingerprint isn't set up on
        // this device or the attempt fails.
        tryLockFingerprint(myUsername)
    }

    private fun tryLockFingerprint(myUsername: String) {
        val biometricManager = BiometricManager.from(this)
        val canAuthenticate = biometricManager.canAuthenticate(BiometricManager.Authenticators.BIOMETRIC_STRONG)
        if (canAuthenticate != BiometricManager.BIOMETRIC_SUCCESS) {
            // No fingerprint hardware/enrollment on this device — password fallback
            // below is the only path, so just let the person know once.
            return
        }

        val executor = ContextCompat.getMainExecutor(this)
        val biometricPrompt = BiometricPrompt(
            this, executor,
            object : BiometricPrompt.AuthenticationCallback() {
                override fun onAuthenticationSucceeded(result: BiometricPrompt.AuthenticationResult) {
                    super.onAuthenticationSucceeded(result)
                    buildManagementUi(myUsername)
                }

                override fun onAuthenticationError(errorCode: Int, errString: CharSequence) {
                    super.onAuthenticationError(errorCode, errString)
                    // Fingerprint failed/was cancelled — fall back silently to the
                    // password field that's already visible, no need to alarm the user.
                }

                override fun onAuthenticationFailed() {
                    super.onAuthenticationFailed()
                    Toast.makeText(this@UserManagementActivity, "Fingerprint match nahi hua, dobara try karein ya password likhein", Toast.LENGTH_SHORT).show()
                }
            }
        )

        val promptInfo = BiometricPrompt.PromptInfo.Builder()
            .setTitle("Fingerprint Verify Karein")
            .setSubtitle("Manage Users kholne ke liye apni fingerprint dikhayein")
            .setNegativeButtonText("Password Use Karein")
            .setAllowedAuthenticators(BiometricManager.Authenticators.BIOMETRIC_STRONG)
            .build()

        biometricPrompt.authenticate(promptInfo)
    }

    private fun verifyLockPassword(myUsername: String) {
        val typed = lockPasswordField.text.toString()
        if (typed.isEmpty()) {
            lockErrorText.text = "Password likhein"
            lockErrorText.visibility = View.VISIBLE
            return
        }
        lifecycleScope.launch {
            val me = PosDatabase.get(this@UserManagementActivity).userDao().find(myUsername)
            // FIX: match LoginActivity's backward-compat check — PasswordHasher.verify()
            // always returns false for a still-plain-text passwordHash (pre-hashing-update
            // accounts, e.g. the seeded admin), so it can't be the only check here or a
            // correct password would always be rejected as "Ghalat password".
            val passwordOk = if (me != null && PasswordHasher.isHashed(me.passwordHash)) {
                PasswordHasher.verify(typed, me.passwordHash)
            } else {
                me != null && me.passwordHash == typed
            }
            if (me != null && passwordOk) {
                if (!PasswordHasher.isHashed(me.passwordHash)) {
                    val migrated = me.copy(passwordHash = PasswordHasher.hash(typed))
                    PosDatabase.get(this@UserManagementActivity).userDao().upsert(migrated)
                    SyncQueueHelper.enqueueUser(PosDatabase.get(this@UserManagementActivity), migrated, this@UserManagementActivity)
                }
                buildManagementUi(myUsername)
            } else {
                lockErrorText.text = "Ghalat password"
                lockErrorText.visibility = View.VISIBLE
            }
        }
    }

    // ================= REAL SCREEN (only built after lock verify succeeds) =================
    private fun buildManagementUi(myUsername: String) {
        val root = LinearLayout(this).apply {
            orientation = LinearLayout.VERTICAL
            setPadding(24, 48, 24, 24)
            setBackgroundColor(Color.parseColor(bg))
        }

        val header = LinearLayout(this).apply {
            orientation = LinearLayout.HORIZONTAL
            gravity = Gravity.CENTER_VERTICAL
            setPadding(26, 22, 26, 22)
            background = GradientDrawable(
                GradientDrawable.Orientation.TL_BR,
                intArrayOf(Color.parseColor(primary), Color.parseColor(primaryDark))
            ).apply { cornerRadius = 22f }
            layoutParams = LinearLayout.LayoutParams(
                LinearLayout.LayoutParams.MATCH_PARENT, LinearLayout.LayoutParams.WRAP_CONTENT
            ).apply { setMargins(0, 0, 0, 20) }
            applyElevation(this, 10f)
        }
        header.addView(circleIconDrawable(R.drawable.ic_people, "#5C4DFF", 42))
        header.addView(spacerH(16))
        val headerCol = LinearLayout(this).apply {
            orientation = LinearLayout.VERTICAL
            layoutParams = LinearLayout.LayoutParams(0, LinearLayout.LayoutParams.WRAP_CONTENT, 1f)
        }
        headerCol.addView(TextView(this).apply {
            text = "Manage Users"
            textSize = 20f
            setTextColor(Color.WHITE)
            setTypeface(typeface, Typeface.BOLD)
        })
        headerCol.addView(TextView(this).apply {
            text = "Add, update, or remove staff logins"
            textSize = 11.5f
            setTextColor(Color.parseColor("#D8D3FF"))
            setPadding(0, 4, 0, 0)
        })
        header.addView(headerCol)
        root.addView(header)

        val formCard = sectionCard(R.drawable.ic_add, "Add / Update User")

        usernameField = EditText(this).apply {
            hint = "Username"
            setHintTextColor(Color.parseColor(textGray))
            setTextColor(Color.parseColor(textDark))
            background = null
        }
        displayNameField = EditText(this).apply {
            hint = "Display Name"
            setHintTextColor(Color.parseColor(textGray))
            setTextColor(Color.parseColor(textDark))
            background = null
        }
        phoneField = EditText(this).apply {
            hint = "Phone (+92XXXXXXXXXX) — for OTP login"
            setHintTextColor(Color.parseColor(textGray))
            setTextColor(Color.parseColor(textDark))
            background = null
            inputType = InputType.TYPE_CLASS_PHONE
        }
        passwordField = EditText(this).apply {
            hint = "Password"
            setHintTextColor(Color.parseColor(textGray))
            setTextColor(Color.parseColor(textDark))
            background = null
            inputType = 0x81
        }

        formCard.addView(fieldBox(R.drawable.ic_person, usernameField))
        formCard.addView(spacer(10))
        formCard.addView(fieldBox(R.drawable.ic_tag, displayNameField))
        formCard.addView(spacer(10))
        formCard.addView(fieldBox(R.drawable.ic_phone, phoneField))
        formCard.addView(spacer(10))
        formCard.addView(fieldBox(R.drawable.ic_lock, passwordField))
        formCard.addView(spacer(10))

        formCard.addView(TextView(this).apply {
            text = "Role"
            textSize = 12f
            setTextColor(Color.parseColor(textGray))
            setPadding(4, 0, 0, 6)
        })
        roleSpinner = Spinner(this).apply {
            adapter = ArrayAdapter(this@UserManagementActivity, android.R.layout.simple_spinner_dropdown_item, roles)
            background = strokedBg(border, fieldFill, 12)
            setPadding(18, 10, 18, 10)
        }
        formCard.addView(roleSpinner)
        formCard.addView(spacer(14))
        formCard.addView(primaryButton("ADD / UPDATE USER", primary, primaryDark, R.drawable.ic_check) { saveUser() })
        root.addView(formCard)
        root.addView(spacer(18))

        val listCard = sectionCard(R.drawable.ic_list, "All Users")
        listContainer = LinearLayout(this).apply { orientation = LinearLayout.VERTICAL }
        listCard.addView(listContainer)
        root.addView(listCard)
        root.addView(spacer(30))

        setContentView(ScrollView(this).apply {
            setBackgroundColor(Color.parseColor(bg))
            addView(root)
        })

        loadUsers(myUsername)
    }

    private fun saveUser() {
        val username = usernameField.text.toString().trim()
        val displayName = displayNameField.text.toString().trim()
        val phone = phoneField.text.toString().trim()
        val password = passwordField.text.toString()
        val role = roles[roleSpinner.selectedItemPosition]

        if (username.isEmpty() || displayName.isEmpty() || password.isEmpty()) {
            Toast.makeText(this, "Sab fields zaroori hain", Toast.LENGTH_SHORT).show()
            return
        }

        lifecycleScope.launch {
            val user = User(
                username = username,
                displayName = displayName,
                role = role,
                // FIX (Phase 4 - Security): password typed here is now hashed via
                // PasswordHasher before being saved (and before being pushed to the
                // sync queue) — previously stored and synced as plain text.
                passwordHash = PasswordHasher.hash(password),
                active = true,
                phone = phone
            )
            val db = PosDatabase.get(this@UserManagementActivity)
            db.userDao().upsert(user)

            SyncQueueHelper.enqueue(
                db = db,
                entityType = "user",
                entityId = SyncQueueHelper.userEntityId(user),
                operation = "upsert",
                payloadJson = SyncQueueHelper.userJson(user)
            )
            SyncQueueHelper.trigger(this@UserManagementActivity)

            Toast.makeText(this@UserManagementActivity, "User saved", Toast.LENGTH_SHORT).show()
            usernameField.text.clear()
            displayNameField.text.clear()
            phoneField.text.clear()
            passwordField.text.clear()
        }
    }

    private fun loadUsers(myUsername: String) {
        lifecycleScope.launch {
            PosDatabase.get(this@UserManagementActivity).userDao().all().collectLatest { users ->
                listContainer.removeAllViews()
                if (users.isEmpty()) {
                    listContainer.addView(TextView(this@UserManagementActivity).apply {
                        text = "Koi user nahi hai"
                        setTextColor(Color.parseColor(textGray))
                        setPadding(4, 8, 4, 8)
                    })
                }
                users.forEachIndexed { index, user ->
                    listContainer.addView(userRow(user, myUsername))
                    if (index != users.lastIndex) listContainer.addView(spacer(10))
                }
            }
        }
    }

    private fun userRow(user: User, myUsername: String): LinearLayout {
        val roleColor = when (user.role) {
            "admin" -> primary
            "manager" -> blue
            else -> amber
        }

        return LinearLayout(this).apply {
            orientation = LinearLayout.VERTICAL
            background = strokedBg(border, fieldFill, 14)
            setPadding(16, 14, 16, 14)

            val topRow = LinearLayout(this@UserManagementActivity).apply {
                orientation = LinearLayout.HORIZONTAL
                gravity = Gravity.CENTER_VERTICAL
            }

            topRow.addView(TextView(this@UserManagementActivity).apply {
                text = user.displayName.take(1).uppercase()
                textSize = 15f
                setTextColor(Color.WHITE)
                gravity = Gravity.CENTER
                setTypeface(typeface, Typeface.BOLD)
                background = ovalBg(roleColor)
                // ADDED: dim the avatar when the user is inactive, so it's visually
                // obvious at a glance without having to read the badge text.
                alpha = if (user.active) 1f else 0.4f
                val px = (36 * resources.displayMetrics.density).toInt()
                layoutParams = android.view.ViewGroup.LayoutParams(px, px)
            })
            topRow.addView(spacerH(14))

            val info = LinearLayout(this@UserManagementActivity).apply {
                orientation = LinearLayout.VERTICAL
                layoutParams = LinearLayout.LayoutParams(0, LinearLayout.LayoutParams.WRAP_CONTENT, 1f)
            }
            info.addView(TextView(this@UserManagementActivity).apply {
                text = "${user.displayName}  ·  ${user.username}"
                textSize = 14f
                setTextColor(Color.parseColor(if (user.active) textDark else textGray))
                setTypeface(typeface, Typeface.BOLD)
            })
            if (user.phone.isNotBlank()) {
                info.addView(TextView(this@UserManagementActivity).apply {
                    text = user.phone
                    textSize = 11.5f
                    setTextColor(Color.parseColor(textGray))
                    setPadding(0, 2, 0, 0)
                    setCompoundDrawablesRelative(tintedDrawable(R.drawable.ic_phone, textGray, 12), null, null, null)
                    compoundDrawablePadding = (5 * resources.displayMetrics.density).toInt()
                })
            }
            val badgeRow = LinearLayout(this@UserManagementActivity).apply { orientation = LinearLayout.HORIZONTAL }
            badgeRow.addView(roleBadge(user.role, roleColor))
            // ADDED: Active/Inactive status badge next to the role badge.
            badgeRow.addView(spacerH(6))
            badgeRow.addView(roleBadge(if (user.active) "Active" else "Inactive", if (user.active) green else textGray))
            info.addView(badgeRow)
            topRow.addView(info)
            addView(topRow)

            // ADDED: action row — Reset Password (any user) + Activate/Deactivate
            // toggle (any user except yourself, so you can never lock yourself out
            // by accident) + Delete (unchanged, still hidden for yourself).
            addView(spacer(10))
            val actionRow = LinearLayout(this@UserManagementActivity).apply {
                orientation = LinearLayout.HORIZONTAL
            }
            val weighted = LinearLayout.LayoutParams(0, LinearLayout.LayoutParams.WRAP_CONTENT, 1f)
            actionRow.addView(secondaryButton("Reset PW", blue, R.drawable.ic_key) { openResetPasswordDialog(user) }, weighted)
            actionRow.addView(spacerH(8))
            if (user.username != myUsername) {
                actionRow.addView(
                    secondaryButton(
                        if (user.active) "Deactivate" else "Activate",
                        if (user.active) amber else green,
                        if (user.active) R.drawable.ic_lock else R.drawable.ic_lock_open
                    ) { toggleActive(user) },
                    LinearLayout.LayoutParams(0, LinearLayout.LayoutParams.WRAP_CONTENT, 1f)
                )
                actionRow.addView(spacerH(8))
                actionRow.addView(
                    secondaryButton("DELETE", red, R.drawable.ic_delete) { confirmDelete(user) },
                    LinearLayout.LayoutParams(0, LinearLayout.LayoutParams.WRAP_CONTENT, 1f)
                )
            }
            addView(actionRow)
        }
    }

    // ADDED: lets an admin set a brand-new password for any user (including one who
    // forgot theirs) without needing to know the old one. Purely local — passwordHash
    // is deliberately never included in what gets synced (see SyncQueueHelper.userJson),
    // so this never enqueues a sync row; each device keeps its own password for a
    // given username, by design.
    private fun openResetPasswordDialog(user: User) {
        val newPasswordField = EditText(this).apply {
            hint = "New password"
            inputType = InputType.TYPE_CLASS_TEXT or InputType.TYPE_TEXT_VARIATION_PASSWORD
            setPadding(28, 22, 28, 22)
        }
        AlertDialog.Builder(this)
            .setTitle("Reset Password — ${user.displayName}")
            .setMessage("${user.username} ke liye naya password set karein.")
            .setView(newPasswordField)
            .setPositiveButton("Reset") { _, _ ->
                val newPassword = newPasswordField.text.toString()
                if (newPassword.length < 8) {
                    Toast.makeText(this, "Password kam az kam 8 characters ka ho", Toast.LENGTH_SHORT).show()
                    return@setPositiveButton
                }
                lifecycleScope.launch {
                    val db = PosDatabase.get(this@UserManagementActivity)
                    val updated = user.copy(passwordHash = PasswordHasher.hash(newPassword))
                    db.userDao().upsert(updated)
                    // Password hashes intentionally stay device-local and are never sent
                    // to Firestore. Record the event locally for auditability instead.
                    runCatching {
                        db.auditDao().insert(Audit(
                            username = getSharedPreferences("session", MODE_PRIVATE).getString("username", "admin") ?: "admin",
                            action = "password_reset",
                            reference = user.username,
                            details = "Password reset locally by admin",
                            createdAt = System.currentTimeMillis()
                        ))
                    }
                    Toast.makeText(this@UserManagementActivity, "Password reset ho gaya (is device par)", Toast.LENGTH_SHORT).show()
                }
            }
            .setNegativeButton("Cancel", null)
            .show()
    }

    // ADDED: flips a user's active flag. Unlike password, `active` IS part of the
    // synced payload (see userJson), so this enqueues like any other user edit —
    // deactivating someone on one device correctly deactivates them everywhere once
    // synced.
    private fun toggleActive(user: User) {
        val turningOff = user.active
        val action = if (turningOff) "Deactivate" else "Activate"
        AlertDialog.Builder(this)
            .setTitle("$action ${user.displayName}?")
            .setMessage(
                if (turningOff) "${user.username} ab login nahi kar sakega jab tak dobara activate na kiya jaye."
                else "${user.username} ab dobara login kar sakega."
            )
            .setPositiveButton(action) { _, _ ->
                lifecycleScope.launch {
                    val db = PosDatabase.get(this@UserManagementActivity)
                    val updated = user.copy(active = !user.active)
                    db.userDao().upsert(updated)
                    SyncQueueHelper.enqueue(
                        db = db,
                        entityType = "user",
                        entityId = SyncQueueHelper.userEntityId(updated),
                        operation = "upsert",
                        payloadJson = SyncQueueHelper.userJson(updated)
                    )
                    SyncQueueHelper.trigger(this@UserManagementActivity)
                    Toast.makeText(
                        this@UserManagementActivity,
                        if (updated.active) "User activated" else "User deactivated",
                        Toast.LENGTH_SHORT
                    ).show()
                }
            }
            .setNegativeButton("Cancel", null)
            .show()
    }

    private fun roleBadge(role: String, colorHex: String) = TextView(this).apply {
        text = role.replaceFirstChar { it.uppercase() }
        textSize = 10.5f
        setTextColor(Color.parseColor(colorHex))
        setTypeface(typeface, Typeface.BOLD)
        setPadding(14, 4, 14, 4)
        background = GradientDrawable().apply {
            setColor(Color.parseColor(colorHex).let { Color.argb(28, Color.red(it), Color.green(it), Color.blue(it)) })
            cornerRadius = 20f
        }
        val lp = LinearLayout.LayoutParams(LinearLayout.LayoutParams.WRAP_CONTENT, LinearLayout.LayoutParams.WRAP_CONTENT)
        lp.topMargin = 6
        layoutParams = lp
    }

    private fun confirmDelete(user: User) {
        AlertDialog.Builder(this)
            .setTitle("Delete User?")
            .setMessage("${user.displayName} (${user.username}) ko delete karna hai?")
            .setPositiveButton("Delete") { _, _ ->
                lifecycleScope.launch {
                    val db = PosDatabase.get(this@UserManagementActivity)
                    db.userDao().delete(user.username)

                    SyncQueueHelper.enqueue(
                        db = db,
                        entityType = "user",
                        entityId = SyncQueueHelper.userEntityId(user),
                        operation = "delete",
                        payloadJson = SyncQueueHelper.userJson(user)
                    )
                    SyncQueueHelper.trigger(this@UserManagementActivity)

                    Toast.makeText(this@UserManagementActivity, "User deleted", Toast.LENGTH_SHORT).show()
                }
            }
            .setNegativeButton("Cancel", null)
            .show()
    }

    // ---- Icons throughout this screen used to be raw emoji strings; now every icon slot
    // takes a R.drawable.ic_* resource and gets tinted/sized here, same pattern as
    // ProductActivity/PartyReportsActivity's icon migration. ----
    private fun tintedDrawable(iconRes: Int, tintHex: String, sizeDp: Int = 16): android.graphics.drawable.Drawable? {
        val d = ContextCompat.getDrawable(this, iconRes)?.mutate() ?: return null
        d.setTint(Color.parseColor(tintHex))
        val px = (sizeDp * resources.displayMetrics.density).toInt()
        d.setBounds(0, 0, px, px)
        return d
    }

    private fun sectionCard(iconRes: Int, title: String) = LinearLayout(this).apply {
        orientation = LinearLayout.VERTICAL
        setPadding(24, 22, 24, 22)
        background = strokedBg(border, cardBg, 18)
        layoutParams = LinearLayout.LayoutParams(
            LinearLayout.LayoutParams.MATCH_PARENT, LinearLayout.LayoutParams.WRAP_CONTENT
        )
        applyElevation(this, 3f)
        addView(sectionLabel(iconRes, title))
        addView(spacer(4))
    }

    private fun sectionLabel(iconRes: Int, label: String) = LinearLayout(this).apply {
        orientation = LinearLayout.HORIZONTAL
        gravity = Gravity.CENTER_VERTICAL
        setPadding(0, 0, 0, 12)
        addView(ImageView(this@UserManagementActivity).apply {
            setImageDrawable(tintedDrawable(iconRes, primary, 17))
            val px = (17 * resources.displayMetrics.density).toInt()
            layoutParams = LinearLayout.LayoutParams(px, px).apply { marginEnd = (8 * resources.displayMetrics.density).toInt() }
        })
        addView(TextView(this@UserManagementActivity).apply {
            text = label
            textSize = 14.5f
            setTextColor(Color.parseColor(textDark))
            setTypeface(typeface, Typeface.BOLD)
        })
    }

    private fun fieldBox(iconRes: Int, field: EditText) = LinearLayout(this).apply {
        orientation = LinearLayout.HORIZONTAL
        gravity = Gravity.CENTER_VERTICAL
        background = strokedBg(border, fieldFill, 12)
        setPadding(18, 4, 18, 4)
        addView(ImageView(this@UserManagementActivity).apply {
            setImageDrawable(tintedDrawable(iconRes, textGray, 16))
            val px = (16 * resources.displayMetrics.density).toInt()
            layoutParams = LinearLayout.LayoutParams(px, px).apply { marginEnd = (10 * resources.displayMetrics.density).toInt() }
        })
        field.layoutParams = LinearLayout.LayoutParams(0, LinearLayout.LayoutParams.WRAP_CONTENT, 1f)
        addView(field)
    }

    private fun primaryButton(label: String, colorHex: String, colorDarkHex: String, iconRes: Int? = null, onClick: () -> Unit) = Button(this).apply {
        text = label
        setTextColor(Color.WHITE)
        textSize = 14.5f
        isAllCaps = false
        setTypeface(typeface, Typeface.BOLD)
        background = GradientDrawable(
            GradientDrawable.Orientation.LEFT_RIGHT,
            intArrayOf(Color.parseColor(colorHex), Color.parseColor(colorDarkHex))
        ).apply { cornerRadius = 16f }
        setPadding(0, 24, 0, 24)
        if (iconRes != null) {
            setCompoundDrawablesRelative(tintedDrawable(iconRes, "#FFFFFF", 17), null, null, null)
            compoundDrawablePadding = (8 * resources.displayMetrics.density).toInt()
        }
        setOnClickListener { onClick() }
        applyElevation(this, 4f)
    }

    private fun secondaryButton(label: String, colorHex: String, iconRes: Int? = null, onClick: () -> Unit) = Button(this).apply {
        text = label
        setTextColor(Color.parseColor(colorHex))
        textSize = 11.5f
        isAllCaps = false
        setTypeface(typeface, Typeface.BOLD)
        background = strokedBg(colorHex, cardBg, 14)
        setPadding(20, 14, 20, 14)
        minWidth = 0
        minimumWidth = 0
        if (iconRes != null) {
            setCompoundDrawablesRelative(tintedDrawable(iconRes, colorHex, 14), null, null, null)
            compoundDrawablePadding = (6 * resources.displayMetrics.density).toInt()
        }
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

    // spacer() now comes from the shared UiHelpers.kt (item #24 dedup) — was a
    // byte-identical private copy here before.

    private fun spacerH(widthDp: Int) = View(this).apply {
        val px = (widthDp * resources.displayMetrics.density).toInt()
        layoutParams = LinearLayout.LayoutParams(px, 1)
    }
}

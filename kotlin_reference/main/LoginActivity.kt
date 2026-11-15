package com.grocerypos.v11.ui

import com.grocerypos.v11.SyncQueueHelper
import android.content.Intent
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
import com.google.firebase.FirebaseException
import com.google.firebase.auth.FirebaseAuth
import com.google.firebase.auth.PhoneAuthCredential
import com.google.firebase.auth.PhoneAuthOptions
import com.google.firebase.auth.PhoneAuthProvider
import com.grocerypos.v11.AppSetting
import com.grocerypos.v11.MainActivity
import com.grocerypos.v11.PasswordHasher
import com.grocerypos.v11.PosDatabase
import com.grocerypos.v11.R
import com.grocerypos.v11.User
import kotlinx.coroutines.launch
import java.util.concurrent.TimeUnit
import com.grocerypos.v11.ui.components.*

class LoginActivity : ThemedActivity() {

    // ================= PREMIUM COLOR PALETTE =================
    // Splash gradient stays fixed brand colors (shown before login, same for everyone).
    // Card surface below it now follows ThemeManager so the login card isn't stuck in
    // light mode if dark mode was already on (e.g. after logging out).
    private val gradientTop = "#1A237E"
    private val gradientBottom = "#3949AB"
    private var cardBg = "#FFFFFF"
    private val primary = "#4A3AFF"
    private val primaryDark = "#3527D6"
    private val green = "#1FA971"
    private var red = "#E5484D"
    private var textDark = "#1A1A2E"
    private var textGray = "#8A8A9E"
    private var border = "#E7E5F3"

    private fun loadThemeColors() {
        val p = com.grocerypos.v11.util.ThemeManager.palette(this)
        cardBg = p.cardWhite
        red = p.red
        textDark = p.textDark
        textGray = p.textMuted
        border = p.border
    }

    private lateinit var loggedInUser: User

    private lateinit var u: EditText
    private lateinit var p: EditText
    private lateinit var btn: Button
    private lateinit var fingerprintBtn: Button
    private lateinit var hint: TextView

    // ---- Phone OTP login (Firebase Auth) ----
    private val auth by lazy { FirebaseAuth.getInstance() }
    private var storedVerificationId: String = ""
    private lateinit var otpSection: LinearLayout
    private lateinit var otpPhoneField: EditText
    private lateinit var otpCodeField: EditText
    private lateinit var otpCodeBox: LinearLayout
    private lateinit var sendOtpBtn: Button
    private lateinit var verifyOtpBtn: Button

    override fun onCreate(b: Bundle?) {
        super.onCreate(b)
        loadThemeColors()

        // FIX (crash-catcher coverage): MainActivity used to be the only screen that checked
        // for a saved crash log, but when there's no session, MainActivity redirects to
        // LoginActivity and finishes BEFORE it ever reaches that check — so any crash that
        // happened while on LoginActivity (or before login) was never shown. LoginActivity now
        // checks too, so a crash on any screen is surfaced the next time the app is opened.
        com.grocerypos.v11.util.CrashHandler.getLastCrash(this)?.let { crashText -> showCrashDialog(crashText) }

        // FIX: "No Password" login method now short-circuits straight into the app —
        // this has to happen before any UI is built, otherwise the login card would
        // flash on screen for a moment even when no login is required.
        lifecycleScope.launch {
            val db = PosDatabase.get(this@LoginActivity)

            // FIX (Security): first-time setup no longer seeds a hardcoded
            // "admin" / "admin123" account. Instead, if no admin has ever been
            // created, the person is shown a one-time "Create Admin Account"
            // screen where they choose their own username/display name/password.
            // Only once that account is created do we move on to checking the
            // configured login method and showing the normal login screen.
            val seeded = db.appSettingDao().get("admin_seeded")
            if (seeded == null) {
                buildSetupUi()
                return@launch
            }

            val method = db.appSettingDao().get("login_method")?.value ?: "password"
            // FIX (logout infinite-loop / screen blink): "No Password" mode used to jump
            // straight to MainActivity here with NO session check at all. That's correct
            // while someone is already logged in (that's the whole point of this mode),
            // but right after Logout the session is empty — MainActivity would then bounce
            // straight back to LoginActivity, which would immediately bounce back to
            // MainActivity again, forever (the rapid Login<->Main flashing the user saw).
            // Now "none" only auto-skips the login screen when a session already exists;
            // with no session (e.g. just logged out) it falls through to the normal login
            // UI below so the person can sign in once, which sets a fresh session.
            if (method == "none") {
                val session = getSharedPreferences("session", MODE_PRIVATE)
                if (session.getString("username", null) != null) {
                    goToMain()
                    return@launch
                }
            }
            buildUi()
            applyLoginMethod(db)
        }
    }

    private fun goToMain() {
        startActivity(Intent(this@LoginActivity, MainActivity::class.java))
        finish()
    }

    // ---- Same crash dialog as MainActivity's, duplicated here (instead of shared) so this
    // file has no new cross-activity dependency — see the CrashHandler.getLastCrash() call in
    // onCreate() above for why LoginActivity needs its own copy. ----
    private fun showCrashDialog(crashText: String) {
        androidx.appcompat.app.AlertDialog.Builder(this)
            .setTitle("App crashed last time")
            .setMessage(if (crashText.length > 3000) crashText.take(3000) + "\n\n…(truncated, use Share for full text)" else crashText)
            .setPositiveButton("Share") { _, _ ->
                startActivity(Intent.createChooser(com.grocerypos.v11.util.CrashHandler.shareIntent(crashText), "Share crash log"))
                com.grocerypos.v11.util.CrashHandler.clearLastCrash(this)
            }
            .setNeutralButton("Copy") { _, _ ->
                val clipboard = getSystemService(CLIPBOARD_SERVICE) as android.content.ClipboardManager
                clipboard.setPrimaryClip(android.content.ClipData.newPlainText("crash", crashText))
                Toast.makeText(this, "Copied", Toast.LENGTH_SHORT).show()
            }
            .setNegativeButton("Dismiss") { _, _ -> com.grocerypos.v11.util.CrashHandler.clearLastCrash(this) }
            .setCancelable(false)
            .show()
    }

    // ================= FIRST-TIME ADMIN SETUP =================
    // Shown exactly once, before any login screen ever exists — replaces the old
    // silently-seeded "admin" / "admin123" default account. The person must choose
    // their own username, display name, and password before the app can be used.
    private fun buildSetupUi() {
        val outer = LinearLayout(this).apply {
            orientation = LinearLayout.VERTICAL
            gravity = Gravity.CENTER
            setPadding(36, 60, 36, 60)
            background = GradientDrawable(
                GradientDrawable.Orientation.TL_BR,
                intArrayOf(Color.parseColor(gradientTop), Color.parseColor(gradientBottom))
            )
        }

        outer.addView(circleIcon(R.drawable.ic_lock, "#FFFFFF", "#3949AB", 84))
        outer.addView(spacer(20))
        outer.addView(TextView(this).apply {
            text = "IBTISAAM Kiryana Store"
            textSize = 21f
            gravity = Gravity.CENTER
            setTextColor(Color.WHITE)
            setTypeface(typeface, Typeface.BOLD)
        })
        outer.addView(TextView(this).apply {
            text = "Pehli Dafa Setup"
            textSize = 12.5f
            gravity = Gravity.CENTER
            setTextColor(Color.parseColor("#C5CAE9"))
            setPadding(0, 6, 0, 0)
        })
        outer.addView(spacer(34))

        val card = LinearLayout(this).apply {
            orientation = LinearLayout.VERTICAL
            setPadding(30, 34, 30, 30)
            background = roundedBg(cardBg, 24)
            layoutParams = LinearLayout.LayoutParams(
                LinearLayout.LayoutParams.MATCH_PARENT, LinearLayout.LayoutParams.WRAP_CONTENT
            )
            applyElevation(this, 14f)
        }

        card.addView(TextView(this).apply {
            text = "Admin Account Banayein"
            textSize = 17f
            setTextColor(Color.parseColor(textDark))
            setTypeface(typeface, Typeface.BOLD)
        })
        card.addView(TextView(this).apply {
            text = "Ye aapka pehla aur sabse powerful account hoga"
            textSize = 12f
            setTextColor(Color.parseColor(textGray))
            setPadding(0, 4, 0, 22)
        })

        val displayNameField = EditText(this).apply {
            hint = "Apka Naam (e.g. Owner)"
            setHintTextColor(Color.parseColor(textGray))
            setTextColor(Color.parseColor(textDark))
            background = null
        }
        card.addView(fieldBox(R.drawable.ic_person, displayNameField))
        card.addView(spacer(14))

        val usernameField = EditText(this).apply {
            hint = "Username"
            setHintTextColor(Color.parseColor(textGray))
            setTextColor(Color.parseColor(textDark))
            background = null
        }
        card.addView(fieldBox(R.drawable.ic_person, usernameField))
        card.addView(spacer(14))

        val passwordField = EditText(this).apply {
            hint = "Password (kam az kam 6 characters)"
            setHintTextColor(Color.parseColor(textGray))
            setTextColor(Color.parseColor(textDark))
            background = null
            inputType = InputType.TYPE_CLASS_TEXT or InputType.TYPE_TEXT_VARIATION_PASSWORD
        }
        card.addView(passwordFieldBox(passwordField))
        card.addView(spacer(14))

        val confirmPasswordField = EditText(this).apply {
            hint = "Password Dobara Likhein"
            setHintTextColor(Color.parseColor(textGray))
            setTextColor(Color.parseColor(textDark))
            background = null
            inputType = InputType.TYPE_CLASS_TEXT or InputType.TYPE_TEXT_VARIATION_PASSWORD
        }
        card.addView(passwordFieldBox(confirmPasswordField))
        card.addView(spacer(10))

        val errorText = TextView(this).apply {
            textSize = 11.5f
            setTextColor(Color.parseColor(red))
            setPadding(4, 0, 4, 0)
            visibility = View.GONE
        }
        card.addView(errorText)
        card.addView(spacer(10))

        val createBtn = Button(this).apply {
            text = "ADMIN ACCOUNT BANAYEIN"
            setTextColor(Color.WHITE)
            textSize = 14.5f
            isAllCaps = false
            setTypeface(typeface, Typeface.BOLD)
            background = GradientDrawable(
                GradientDrawable.Orientation.LEFT_RIGHT,
                intArrayOf(Color.parseColor(primary), Color.parseColor(primaryDark))
            ).apply { cornerRadius = 16f }
            setPadding(0, 28, 0, 28)
            applyElevation(this, 6f)
            setLeadingIcon(R.drawable.ic_check, "#FFFFFF", 17, 8)
        }
        card.addView(createBtn)

        outer.addView(card)

        setContentView(ScrollView(this).apply {
            setBackgroundColor(Color.parseColor(gradientTop))
            addView(outer, FrameLayout.LayoutParams(FrameLayout.LayoutParams.MATCH_PARENT, FrameLayout.LayoutParams.WRAP_CONTENT))
        })

        createBtn.setOnClickListener {
            errorText.visibility = View.GONE
            val displayName = displayNameField.text.toString().trim()
            val username = usernameField.text.toString().trim()
            val password = passwordField.text.toString()
            val confirmPassword = confirmPasswordField.text.toString()

            val validationError = when {
                displayName.isEmpty() -> "Apna naam likhein"
                username.isEmpty() -> "Username likhein"
                username.contains(" ") -> "Username mein space nahi hona chahiye"
                password.length < 6 -> "Password kam az kam 6 characters ka ho"
                password != confirmPassword -> "Dono password match nahi karte"
                else -> null
            }

            if (validationError != null) {
                errorText.text = validationError
                errorText.visibility = View.VISIBLE
                return@setOnClickListener
            }

            lifecycleScope.launch {
                val db = PosDatabase.get(this@LoginActivity)

                val existing = db.userDao().find(username)
                if (existing != null) {
                    errorText.text = "Ye username pehle se mojood hai"
                    errorText.visibility = View.VISIBLE
                    return@launch
                }

                val newAdmin = User(
                    username = username,
                    displayName = displayName,
                    role = "admin",
                    passwordHash = PasswordHasher.hash(password),
                    active = true
                )
                db.userDao().upsert(newAdmin)
                SyncQueueHelper.enqueueUser(db, newAdmin, this@LoginActivity)
                db.appSettingDao().set(AppSetting("admin_seeded", "1"))
                db.appSettingDao().set(AppSetting("last_username", newAdmin.username))

                loggedInUser = newAdmin
                Toast.makeText(
                    this@LoginActivity,
                    "Admin account ban gaya. Khush amdeed, $displayName!",
                    Toast.LENGTH_LONG
                ).show()
                completeLogin()
            }
        }
    }

    private fun buildUi() {
        val outer = LinearLayout(this).apply {
            orientation = LinearLayout.VERTICAL
            gravity = Gravity.CENTER
            setPadding(36, 60, 36, 60)
            background = GradientDrawable(
                GradientDrawable.Orientation.TL_BR,
                intArrayOf(Color.parseColor(gradientTop), Color.parseColor(gradientBottom))
            )
        }

        // ================= LOGO / APP TITLE =================
        outer.addView(circleIcon(R.drawable.ic_store, "#FFFFFF", "#3949AB", 84))
        outer.addView(spacer(20))
        outer.addView(TextView(this).apply {
            text = "IBTISAAM Kiryana Store"
            textSize = 21f
            gravity = Gravity.CENTER
            setTextColor(Color.WHITE)
            setTypeface(typeface, Typeface.BOLD)
        })
        outer.addView(TextView(this).apply {
            text = "Point of Sale"
            textSize = 12.5f
            gravity = Gravity.CENTER
            setTextColor(Color.parseColor("#C5CAE9"))
            setPadding(0, 6, 0, 0)
        })
        outer.addView(spacer(34))

        // ================= LOGIN CARD =================
        val card = LinearLayout(this).apply {
            orientation = LinearLayout.VERTICAL
            setPadding(30, 34, 30, 30)
            background = roundedBg(cardBg, 24)
            layoutParams = LinearLayout.LayoutParams(
                LinearLayout.LayoutParams.MATCH_PARENT, LinearLayout.LayoutParams.WRAP_CONTENT
            )
            applyElevation(this, 14f)
        }

        card.addView(TextView(this).apply {
            text = "Welcome Back"
            textSize = 17f
            setTextColor(Color.parseColor(textDark))
            setTypeface(typeface, Typeface.BOLD)
        })
        card.addView(TextView(this).apply {
            text = "Login karke jaari rakhein"
            textSize = 12f
            setTextColor(Color.parseColor(textGray))
            setPadding(0, 4, 0, 22)
        })

        u = EditText(this).apply {
            hint = "Username"
            setHintTextColor(Color.parseColor(textGray))
            setTextColor(Color.parseColor(textDark))
            background = null
        }
        card.addView(fieldBox(R.drawable.ic_person, u))
        card.addView(spacer(14))

        p = EditText(this).apply {
            hint = "Password"
            setHintTextColor(Color.parseColor(textGray))
            setTextColor(Color.parseColor(textDark))
            background = null
            inputType = InputType.TYPE_CLASS_TEXT or InputType.TYPE_TEXT_VARIATION_PASSWORD
        }
        card.addView(passwordFieldBox(p))
        card.addView(spacer(22))

        btn = Button(this).apply {
            text = "LOGIN"
            setTextColor(Color.WHITE)
            textSize = 15f
            isAllCaps = false
            setTypeface(typeface, Typeface.BOLD)
            background = GradientDrawable(
                GradientDrawable.Orientation.LEFT_RIGHT,
                intArrayOf(Color.parseColor(primary), Color.parseColor(primaryDark))
            ).apply { cornerRadius = 16f }
            setPadding(0, 28, 0, 28)
            applyElevation(this, 6f)
            setLeadingIcon(R.drawable.ic_lock_open, "#FFFFFF", 17, 8)
        }
        card.addView(btn)
        card.addView(spacer(14))

        // "SHOW" fallback button — kept visible (not GONE) whenever fingerprint mode is
        // active so the person always has a manual way to re-open the prompt if the
        // auto-triggered one is dismissed, cancelled, or fails.
        fingerprintBtn = Button(this).apply {
            text = "UNLOCK WITH FINGERPRINT"
            setTextColor(Color.parseColor(green))
            textSize = 13.5f
            isAllCaps = false
            setTypeface(typeface, Typeface.BOLD)
            background = strokedBg(green, "#FFFFFF", 16)
            setPadding(0, 24, 0, 24)
            visibility = View.GONE
            setLeadingIcon(R.drawable.ic_lock_open, green, 15, 6)
        }
        card.addView(fingerprintBtn)

        // ---- Phone OTP section (only visible when login_method == "otp") ----
        otpSection = LinearLayout(this).apply {
            orientation = LinearLayout.VERTICAL
            visibility = View.GONE
        }

        otpPhoneField = EditText(this).apply {
            hint = "+92XXXXXXXXXX"
            setHintTextColor(Color.parseColor(textGray))
            setTextColor(Color.parseColor(textDark))
            background = null
            inputType = InputType.TYPE_CLASS_PHONE
        }
        otpSection.addView(fieldBox(R.drawable.ic_phone, otpPhoneField))
        otpSection.addView(spacer(14))

        sendOtpBtn = Button(this).apply {
            text = "SEND OTP"
            setTextColor(Color.WHITE)
            textSize = 14f
            isAllCaps = false
            setTypeface(typeface, Typeface.BOLD)
            background = GradientDrawable(
                GradientDrawable.Orientation.LEFT_RIGHT,
                intArrayOf(Color.parseColor(primary), Color.parseColor(primaryDark))
            ).apply { cornerRadius = 16f }
            setPadding(0, 24, 0, 24)
            setLeadingIcon(R.drawable.ic_send, "#FFFFFF", 16, 8)
        }
        otpSection.addView(sendOtpBtn)
        otpSection.addView(spacer(14))

        otpCodeField = EditText(this).apply {
            hint = "6-digit code"
            setHintTextColor(Color.parseColor(textGray))
            setTextColor(Color.parseColor(textDark))
            background = null
            inputType = InputType.TYPE_CLASS_NUMBER
        }
        otpCodeBox = fieldBox(R.drawable.ic_number, otpCodeField).apply { visibility = View.GONE }
        otpSection.addView(otpCodeBox)
        otpSection.addView(spacer(14))

        verifyOtpBtn = Button(this).apply {
            text = "VERIFY & LOGIN"
            setTextColor(Color.WHITE)
            textSize = 14f
            isAllCaps = false
            setTypeface(typeface, Typeface.BOLD)
            background = GradientDrawable().apply {
                setColor(Color.parseColor(green)); cornerRadius = 16f
            }
            setPadding(0, 24, 0, 24)
            visibility = View.GONE
            setLeadingIcon(R.drawable.ic_check, "#FFFFFF", 16, 8)
        }
        otpSection.addView(verifyOtpBtn)

        card.addView(otpSection)

        hint = TextView(this).apply {
            textSize = 11.5f
            setTextColor(Color.parseColor(textGray))
            gravity = Gravity.CENTER
            setPadding(0, 18, 0, 0)
        }
        card.addView(hint)

        outer.addView(card)

        setContentView(ScrollView(this).apply {
            setBackgroundColor(Color.parseColor(gradientTop))
            addView(outer, FrameLayout.LayoutParams(FrameLayout.LayoutParams.MATCH_PARENT, FrameLayout.LayoutParams.WRAP_CONTENT))
        })

        btn.setOnClickListener {
            lifecycleScope.launch {
                val db = PosDatabase.get(this@LoginActivity)
                val user = db.userDao().find(u.text.toString().trim())
                val typedPassword = p.text.toString()
                // FIX (Phase 4 - Security): passwords are now verified with
                // PasswordHasher.verify() (salted PBKDF2) instead of a plain `==`
                // comparison. Backward-compat: if an existing user record still has an
                // old plain-text passwordHash (pre-fix installs), it's accepted once on
                // a matching password and silently re-saved as a proper hash so every
                // account migrates automatically the first time it's used after update.
                val passwordOk = if (user != null && PasswordHasher.isHashed(user.passwordHash)) {
                    PasswordHasher.verify(typedPassword, user.passwordHash)
                } else {
                    user != null && user.passwordHash == typedPassword
                }
                if (user != null && passwordOk) {
                    if (!PasswordHasher.isHashed(user.passwordHash)) {
                        val migrated = user.copy(passwordHash = PasswordHasher.hash(typedPassword))
                        db.userDao().upsert(migrated)
                        SyncQueueHelper.enqueueUser(db, migrated, this@LoginActivity)
                    }
                    loggedInUser = user
                    db.appSettingDao().set(AppSetting("last_username", user.username))

                    val method = db.appSettingDao().get("login_method")?.value ?: "password"
                    if (method == "both") {
                        requireFingerprintThenProceed()
                    } else {
                        completeLogin()
                    }
                } else {
                    Toast.makeText(this@LoginActivity, "Invalid login", Toast.LENGTH_SHORT).show()
                }
            }
        }

        fingerprintBtn.setOnClickListener {
            lifecycleScope.launch { triggerFingerprintUnlock() }
        }

        sendOtpBtn.setOnClickListener {
            val phone = otpPhoneField.text.toString().trim()
            if (phone.isEmpty()) {
                Toast.makeText(this, "Phone number dalein", Toast.LENGTH_SHORT).show()
                return@setOnClickListener
            }
            val options = PhoneAuthOptions.newBuilder(auth)
                .setPhoneNumber(phone)
                .setTimeout(60L, TimeUnit.SECONDS)
                .setActivity(this)
                .setCallbacks(object : PhoneAuthProvider.OnVerificationStateChangedCallbacks() {
                    override fun onVerificationCompleted(credential: PhoneAuthCredential) {
                        verifyAndLogin(credential, phone)
                    }

                    override fun onVerificationFailed(e: FirebaseException) {
                        Toast.makeText(this@LoginActivity, "Failed: ${e.message}", Toast.LENGTH_LONG).show()
                    }

                    override fun onCodeSent(verificationId: String, token: PhoneAuthProvider.ForceResendingToken) {
                        storedVerificationId = verificationId
                        otpCodeBox.visibility = View.VISIBLE
                        verifyOtpBtn.visibility = View.VISIBLE
                        Toast.makeText(this@LoginActivity, "OTP bheja gaya", Toast.LENGTH_SHORT).show()
                    }
                })
                .build()
            PhoneAuthProvider.verifyPhoneNumber(options)
        }

        verifyOtpBtn.setOnClickListener {
            val code = otpCodeField.text.toString().trim()
            val phone = otpPhoneField.text.toString().trim()
            if (code.length == 6) {
                val credential = PhoneAuthProvider.getCredential(storedVerificationId, code)
                verifyAndLogin(credential, phone)
            } else {
                Toast.makeText(this, "6-digit code dalein", Toast.LENGTH_SHORT).show()
            }
        }
    }

    private fun askPasswordBeforeFirstPhoneLink(db: PosDatabase, user: User, phone: String) {
        val field = EditText(this).apply {
            hint = "${user.displayName} ka password"
            inputType = InputType.TYPE_CLASS_TEXT or InputType.TYPE_TEXT_VARIATION_PASSWORD
        }
        AlertDialog.Builder(this)
            .setTitle("Phone ko account se link karein")
            .setMessage("OTP verify ho gaya. Security ke liye ${user.displayName} ka current password bhi verify karein.")
            .setView(field)
            .setPositiveButton("Verify") { _, _ ->
                val typed = field.text.toString()
                val ok = if (PasswordHasher.isHashed(user.passwordHash)) {
                    PasswordHasher.verify(typed, user.passwordHash)
                } else {
                    user.passwordHash == typed
                }
                if (!ok) {
                    Toast.makeText(this, "Password ghalat hai — phone link nahi hua", Toast.LENGTH_LONG).show()
                    return@setPositiveButton
                }
                lifecycleScope.launch {
                    val linked = user.copy(phone = phone)
                    db.userDao().upsert(linked)
                    SyncQueueHelper.enqueueUser(db, linked, this@LoginActivity)
                    loggedInUser = linked
                    db.appSettingDao().set(AppSetting("last_username", linked.username))
                    Toast.makeText(this@LoginActivity, "Phone account se link ho gaya.", Toast.LENGTH_LONG).show()
                    completeLogin()
                }
            }
            .setNegativeButton("Cancel", null)
            .show()
    }

    /** Firebase se OTP verify hone ke baad, us phone number se local User record dhoondh kar login complete karta hai. */
    private fun verifyAndLogin(credential: PhoneAuthCredential, phone: String) {
        auth.signInWithCredential(credential).addOnCompleteListener(this) { task ->
            if (task.isSuccessful) {
                lifecycleScope.launch {
                    val db = PosDatabase.get(this@LoginActivity)
                    val user = db.userDao().findByPhone(phone)
                    if (user != null) {
                        loggedInUser = user
                        db.appSettingDao().set(AppSetting("last_username", user.username))
                        completeLogin()
                    } else if (db.userDao().activeCount() == 1 && db.userDao().soleActiveUserOrNull() != null) {
                        // SECURITY FIX: OTP ownership alone must not silently bind an
                        // arbitrary new phone number to the only admin account. Require
                        // the account password once, then save the verified phone.
                        val onlyUser = db.userDao().soleActiveUserOrNull()!!
                        askPasswordBeforeFirstPhoneLink(db, onlyUser, phone)
                    } else {
                        Toast.makeText(
                            this@LoginActivity,
                            "Ye number kisi staff se link nahi hai. Settings > Manage Users mein add karwayein.",
                            Toast.LENGTH_LONG
                        ).show()
                    }
                }
            } else {
                Toast.makeText(this, "OTP galat hai", Toast.LENGTH_SHORT).show()
            }
        }
    }

    /** Settings mein select kiye gaye login_method ke hisab se screen ke elements dikhata/chupata hai. */
    private suspend fun applyLoginMethod(db: com.grocerypos.v11.PosDatabase) {
        val method = db.appSettingDao().get("login_method")?.value ?: "password"
        val lastUsername = db.appSettingDao().get("last_username")?.value

        // Default: sab hide, jo method active hai wahi visible karega
        u.visibility = View.GONE
        p.visibility = View.GONE
        btn.visibility = View.GONE
        fingerprintBtn.visibility = View.GONE
        otpSection.visibility = View.GONE

        when (method) {
            "fingerprint" -> {
                if (lastUsername.isNullOrEmpty()) {
                    // Kabhi login nahi hua — pehli dafa password lena zaroori hai
                    u.visibility = View.VISIBLE
                    p.visibility = View.VISIBLE
                    btn.visibility = View.VISIBLE
                } else {
                    fingerprintBtn.visibility = View.VISIBLE
                    // FIX: auto-detect — the biometric prompt now opens by itself as soon as
                    // this screen appears, instead of waiting for a manual button tap.
                    triggerFingerprintUnlock()
                }
            }
            "both" -> {
                u.visibility = View.VISIBLE
                p.visibility = View.VISIBLE
                btn.visibility = View.VISIBLE
            }
            "otp" -> {
                otpSection.visibility = View.VISIBLE
            }
            else -> { // "password"
                u.visibility = View.VISIBLE
                p.visibility = View.VISIBLE
                btn.visibility = View.VISIBLE
            }
        }
    }

    /** Looks up the last logged-in user and opens the biometric prompt for them. */
    private suspend fun triggerFingerprintUnlock() {
        val db = PosDatabase.get(this@LoginActivity)
        val lastUsername = db.appSettingDao().get("last_username")?.value
        if (lastUsername.isNullOrEmpty()) {
            Toast.makeText(this@LoginActivity, "Pehli dafa password se login karein", Toast.LENGTH_LONG).show()
            return
        }
        val user = db.userDao().find(lastUsername)
        if (user == null) {
            Toast.makeText(this@LoginActivity, "User nahi mila, password se login karein", Toast.LENGTH_LONG).show()
            return
        }
        loggedInUser = user
        showBiometricPrompt()
    }

    /** "Both" mode mein password ke baad fingerprint bhi verify karta hai. */
    private fun requireFingerprintThenProceed() {
        val biometricManager = BiometricManager.from(this)
        val canAuthenticate = biometricManager.canAuthenticate(BiometricManager.Authenticators.BIOMETRIC_STRONG)

        if (canAuthenticate != BiometricManager.BIOMETRIC_SUCCESS) {
            Toast.makeText(this, "Fingerprint set nahi hai is device par, password se login ho raha hai", Toast.LENGTH_SHORT).show()
            completeLogin()
            return
        }
        showBiometricPrompt()
    }

    private fun showBiometricPrompt() {
        val executor = ContextCompat.getMainExecutor(this)
        val biometricPrompt = BiometricPrompt(
            this, executor,
            object : BiometricPrompt.AuthenticationCallback() {
                override fun onAuthenticationSucceeded(result: BiometricPrompt.AuthenticationResult) {
                    super.onAuthenticationSucceeded(result)
                    completeLogin()
                }

                override fun onAuthenticationError(errorCode: Int, errString: CharSequence) {
                    super.onAuthenticationError(errorCode, errString)
                    // Prompt was cancelled/failed to open — the manual fallback button
                    // stays visible so the person can retry without getting stuck.
                    Toast.makeText(this@LoginActivity, "Fingerprint verify nahi hua: $errString", Toast.LENGTH_LONG).show()
                }

                override fun onAuthenticationFailed() {
                    super.onAuthenticationFailed()
                    Toast.makeText(this@LoginActivity, "Fingerprint match nahi hua, dobara try karein", Toast.LENGTH_SHORT).show()
                }
            }
        )

        val promptInfo = BiometricPrompt.PromptInfo.Builder()
            .setTitle("Fingerprint Verify Karein")
            .setSubtitle("Login complete karne ke liye apni fingerprint dikhayein")
            .setNegativeButtonText("Cancel")
            .setAllowedAuthenticators(BiometricManager.Authenticators.BIOMETRIC_STRONG)
            .build()

        biometricPrompt.authenticate(promptInfo)
    }

    private fun completeLogin() {
        getSharedPreferences("session", MODE_PRIVATE)
            .edit()
            .putString("username", loggedInUser.username)
            .putString("role", loggedInUser.role)
            .apply()
        Toast.makeText(this, "Welcome ${loggedInUser.displayName}", Toast.LENGTH_SHORT).show()
        goToMain()
    }

    // ================= UI HELPERS =================
    private fun tintedDrawable(iconRes: Int, tintHex: String, sizeDp: Int = 16): android.graphics.drawable.Drawable? {
        val d = ContextCompat.getDrawable(this, iconRes)?.mutate() ?: return null
        d.setTint(Color.parseColor(tintHex))
        val px = (sizeDp * resources.displayMetrics.density).toInt()
        d.setBounds(0, 0, px, px)
        return d
    }

    private fun TextView.setLeadingIcon(iconRes: Int, tintHex: String, sizeDp: Int = 16, paddingDp: Int = 8) {
        setCompoundDrawablesRelative(tintedDrawable(iconRes, tintHex, sizeDp), null, null, null)
        compoundDrawablePadding = (paddingDp * resources.displayMetrics.density).toInt()
    }

    private fun fieldBox(iconRes: Int, field: EditText) = LinearLayout(this).apply {
        orientation = LinearLayout.HORIZONTAL
        gravity = Gravity.CENTER_VERTICAL
        background = strokedBg(border, "#FAFAFF", 12)
        setPadding(18, 4, 18, 4)
        addView(ImageView(this@LoginActivity).apply {
            setImageDrawable(tintedDrawable(iconRes, textGray, 15))
            val px = (15 * resources.displayMetrics.density).toInt()
            layoutParams = LinearLayout.LayoutParams(px, px).apply {
                marginEnd = (8 * resources.displayMetrics.density).toInt()
            }
        })
        (field.parent as? ViewGroup)?.removeView(field)
        field.layoutParams = LinearLayout.LayoutParams(0, LinearLayout.LayoutParams.WRAP_CONTENT, 1f)
        addView(field)
    }

    /** Same as fieldBox but adds a tappable eye icon to show/hide the password text. */
    private fun passwordFieldBox(field: EditText) = LinearLayout(this).apply {
        orientation = LinearLayout.HORIZONTAL
        gravity = Gravity.CENTER_VERTICAL
        background = strokedBg(border, "#FAFAFF", 12)
        setPadding(18, 4, 18, 4)
        addView(ImageView(this@LoginActivity).apply {
            setImageDrawable(tintedDrawable(R.drawable.ic_lock, textGray, 15))
            val px = (15 * resources.displayMetrics.density).toInt()
            layoutParams = LinearLayout.LayoutParams(px, px).apply {
                marginEnd = (8 * resources.displayMetrics.density).toInt()
            }
        })
        (field.parent as? ViewGroup)?.removeView(field)
        field.layoutParams = LinearLayout.LayoutParams(0, LinearLayout.LayoutParams.WRAP_CONTENT, 1f)
        addView(field)

        val toggle = ImageView(this@LoginActivity).apply {
            setImageDrawable(tintedDrawable(R.drawable.ic_eye, textGray, 18))
            setPadding(16, 0, 8, 0)
            var visible = false
            setOnClickListener {
                visible = !visible
                field.inputType = if (visible)
                    InputType.TYPE_CLASS_TEXT or InputType.TYPE_TEXT_VARIATION_VISIBLE_PASSWORD
                else
                    InputType.TYPE_CLASS_TEXT or InputType.TYPE_TEXT_VARIATION_PASSWORD
                field.setSelection(field.text.length)
                setImageDrawable(tintedDrawable(if (visible) R.drawable.ic_eye_off else R.drawable.ic_eye, textGray, 18))
            }
        }
        addView(toggle)
    }

    private fun circleIcon(iconRes: Int, colorHex: String, textColorHex: String, sizeDp: Int) = FrameLayout(this).apply {
        val px = (sizeDp * resources.displayMetrics.density).toInt()
        layoutParams = LinearLayout.LayoutParams(px, px).apply { gravity = Gravity.CENTER_HORIZONTAL }
        background = GradientDrawable().apply {
            shape = GradientDrawable.OVAL
            setColor(Color.parseColor(colorHex))
        }
        applyElevation(this, 10f)
        addView(ImageView(this@LoginActivity).apply {
            setImageDrawable(tintedDrawable(iconRes, textColorHex, (sizeDp * 0.42).toInt()))
            scaleType = ImageView.ScaleType.CENTER
            layoutParams = FrameLayout.LayoutParams(FrameLayout.LayoutParams.MATCH_PARENT, FrameLayout.LayoutParams.MATCH_PARENT)
        })
    }

    // spacer() now comes from the shared UiHelpers.kt (item #24 dedup) — was a
    // byte-identical private copy here before.
}

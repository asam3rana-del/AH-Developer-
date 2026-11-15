package com.grocerypos.v11.ui

import com.grocerypos.v11.R

/*
 * Settings screen — Cloud Sync subsystem: connectivity check, the "Sync Now"
 * row + its status dot, the resync-from-a-date-time long-press action, the
 * Sync History viewer, and the Cloud Sync Setup dialog. Split out of
 * SettingsActivity.kt as part of the "Oversized Activity files" cleanup (see
 * IMPROVEMENT-PLAN.md), same approach as the Sale/Product/Party screens:
 * extension functions on SettingsActivity, no behavior change.
 */

import android.content.ClipData
import android.content.ClipboardManager
import android.content.Context
import android.graphics.Color
import android.graphics.Typeface
import android.view.Gravity
import android.view.ViewGroup
import android.widget.Button
import android.widget.EditText
import android.widget.LinearLayout
import android.widget.ScrollView
import android.widget.TextView
import android.widget.Toast
import androidx.appcompat.app.AlertDialog
import androidx.lifecycle.lifecycleScope
import com.grocerypos.v11.*
import com.grocerypos.v11.sync.SyncApi
import com.grocerypos.v11.ui.components.*
import kotlinx.coroutines.launch

internal fun SettingsActivity.isNetworkConnected(): Boolean {
    val cm = getSystemService(Context.CONNECTIVITY_SERVICE) as android.net.ConnectivityManager
    val network = cm.activeNetwork ?: return false
    val caps = cm.getNetworkCapabilities(network) ?: return false
    return caps.hasCapability(android.net.NetworkCapabilities.NET_CAPABILITY_INTERNET)
}

/** Updates the small dot + label under "Sync Now" to reflect current connectivity
 *  AND whether this device even has a cloud project configured — see
 *  CloudConfigStore.kt. Previously this only checked network connectivity, so a
 *  device with no cloud project at all still showed a reassuring green
 *  "Connected" dot even though Sync Now could never do anything. */
internal fun SettingsActivity.refreshSyncStatus() {
    val online = isNetworkConnected()
    val cloudConfigured = com.grocerypos.v11.CloudConfigStore.firebaseApp(this) != null
    when {
        !cloudConfigured -> {
            syncRowDot.setTextColor(Color.parseColor(amber))
            syncRowStatusText.text = "Not set up — tap Cloud Sync Setup"
        }
        !BranchConfigStore.isConfigured() -> {
            syncRowDot.setTextColor(Color.parseColor(amber))
            syncRowStatusText.text = "Branch Code missing — tap Cloud Sync Setup"
        }
        online -> {
            syncRowDot.setTextColor(Color.parseColor(teal))
            syncRowStatusText.text = "Connected"
        }
        else -> {
            syncRowDot.setTextColor(Color.parseColor(red))
            syncRowStatusText.text = "Offline"
        }
    }
}

/** Builds the "Sync Now" row with a live Connected/Offline status line under the label,
 *  instead of the plain menuRow() used before. Tapping it still triggers SyncQueueHelper. */
internal fun SettingsActivity.buildSyncRow(): LinearLayout {
    val row = premiumCard().apply {
        orientation = LinearLayout.HORIZONTAL
        gravity = Gravity.CENTER_VERTICAL
        setPadding(18, 17, 18, 17)
        isClickable = true
        isFocusable = true
    }
    row.addView(iconBadge(R.drawable.ic_sync, teal))
    row.addView(spacerH(16))

    val textCol = LinearLayout(this).apply {
        orientation = LinearLayout.VERTICAL
        layoutParams = LinearLayout.LayoutParams(0, LinearLayout.LayoutParams.WRAP_CONTENT, 1f)
    }
    textCol.addView(TextView(this).apply {
        text = "Sync Now"
        textSize = 14.5f
        setTextColor(Color.parseColor(textDark))
        setTypeface(typeface, Typeface.BOLD)
    })

    val statusRow = LinearLayout(this).apply {
        orientation = LinearLayout.HORIZONTAL
        gravity = Gravity.CENTER_VERTICAL
        setPadding(0, 3, 0, 0)
    }
    syncRowDot = TextView(this).apply {
        text = "●"
        textSize = 9f
    }
    statusRow.addView(syncRowDot)
    statusRow.addView(spacerH(4))
    syncRowStatusText = TextView(this).apply {
        textSize = 11f
        setTextColor(Color.parseColor(textGray))
    }
    statusRow.addView(syncRowStatusText)
    textCol.addView(statusRow)
    row.addView(textCol)

    row.setOnClickListener { onSyncNowClicked() }
    // NEW: long-press "Sync Now" opens a small menu — either rewind the pull
    // checkpoint to a chosen date/time (existing), or force-push every local record
    // again from scratch (new — see resyncAllLocalDataClicked() below).
    row.setOnLongClickListener { showSyncNowLongPressMenu(); true }

    refreshSyncStatus()
    return row
}

internal fun SettingsActivity.onSyncNowClicked() {
    if (!isNetworkConnected()) {
        Toast.makeText(this, "No internet connection", Toast.LENGTH_SHORT).show()
        refreshSyncStatus()
        return
    }
    // FIX (was: "Sync failed: Job was cancelled"): this used to run
    // SyncRepository.syncNow() directly inside lifecycleScope.launch { ... }, which
    // is cancelled the instant this Activity is destroyed — leaving Settings,
    // rotating the screen, switching apps, or the screen turning off while a big
    // sync (e.g. hundreds of queued rows) was still mid-flight. That killed the
    // sync outright and surfaced as "Job was cancelled", which had nothing to do
    // with Firestore rules, the branch code, or connectivity — purely which
    // coroutine scope the work happened to be running on.
    //
    // The sync itself now runs inside a WorkManager job (SyncWorker.syncNowOnce),
    // which keeps running to completion regardless of what this screen does. We
    // just observe it here to show a toast — if the screen closes before it
    // finishes, the observer quietly stops (no crash) and the sync still completes
    // normally in the background; it just does so without a toast to show it to.
    Toast.makeText(this, "Syncing…", Toast.LENGTH_SHORT).show()
    com.grocerypos.v11.sync.SyncWorker.syncNowOnce(this)
    com.grocerypos.v11.sync.SyncWorker.observeManualSync(this).observe(this) { infos ->
        val info = infos.firstOrNull() ?: return@observe
        if (info.state.isFinished) {
            val summary = info.outputData.getString(com.grocerypos.v11.sync.SyncWorker.KEY_SUMMARY)
                ?: if (info.state == androidx.work.WorkInfo.State.SUCCEEDED) "Sync complete" else "Sync failed"
            Toast.makeText(this, summary, Toast.LENGTH_LONG).show()
            refreshSyncStatus()
        }
    }
}

/** Long-press "Sync Now" → small menu: rewind-and-repull from a date/time (existing),
 *  or force every local record to be pushed again from scratch (new). */
internal fun SettingsActivity.showSyncNowLongPressMenu() {
    val options = arrayOf(
        "Resync from a date/time (pull)",
        "Force full push — resend ALL local data (push)",
        "Fix back-dated Purchase/Sale cash entries",
        "Recalculate party balances (Customers/Suppliers)",
        "Delete cloud data with a wrong Branch ID (admin cleanup)"
    )
    android.app.AlertDialog.Builder(this)
        .setTitle("Sync Now — more options")
        .setItems(options) { _, which ->
            when (which) {
                0 -> showResyncFromDialog()
                1 -> resyncAllLocalDataClicked()
                2 -> fixBackdatedCashTransactionDatesClicked()
                3 -> recalculatePartyBalancesClicked()
                4 -> showDeleteByWrongBranchIdDialog()
            }
        }
        .show()
}

/** ADDED (admin cleanup): lets an admin type in a stray/foreign branchId value
 *  (spotted via Firebase Console — see SyncApi.BRANCH_SCOPED_COLLECTIONS) and wipe
 *  every document across the synced collections that carries it, WITHOUT touching
 *  this device's own branch data. Two-step: first scans and shows a per-collection
 *  count for the admin to review, then only deletes after they explicitly confirm
 *  on that exact count. Never touches branch_members or users. */
internal fun SettingsActivity.showDeleteByWrongBranchIdDialog() {
    val input = EditText(this).apply {
        hint = "e.g. dusri-branch"
        setPadding(40, 30, 40, 30)
    }
    android.app.AlertDialog.Builder(this)
        .setTitle("Delete cloud data by Branch ID")
        .setMessage(
            "Ye sirf us Branch ID ka data delete karega jo aap yahan likhenge — is " +
            "device ki apni branch ko haath nahi lagaya jayega. branch_members aur " +
            "users collections bhi touch nahi hongi. Pehle sirf SCAN hoga (kuch " +
            "delete nahi), aap count dekh kar confirm karenge tab hi delete hoga.\n\n" +
            "Wo galat Branch ID yahan likhein:"
        )
        .setView(input)
        .setPositiveButton("Scan") { _, _ ->
            val badId = input.text.toString().trim()
            if (badId.isEmpty()) {
                Toast.makeText(this, "Branch ID likhna zaroori hai.", Toast.LENGTH_SHORT).show()
                return@setPositiveButton
            }
            if (badId == BranchConfigStore.current) {
                Toast.makeText(this, "Ye to is device ki apni Branch ID hai — cancel kar diya.", Toast.LENGTH_LONG).show()
                return@setPositiveButton
            }
            Toast.makeText(this, "Scanning…", Toast.LENGTH_SHORT).show()
            lifecycleScope.launch {
                val counts = SyncApi.countDocsByBranchId(this@showDeleteByWrongBranchIdDialog, badId)
                if (counts.isEmpty()) {
                    Toast.makeText(this@showDeleteByWrongBranchIdDialog, "\"$badId\" ka koi document nahi mila.", Toast.LENGTH_LONG).show()
                    return@launch
                }
                val summary = counts.entries.joinToString("\n") { "${it.key}: ${it.value}" }
                val total = counts.values.sum()
                android.app.AlertDialog.Builder(this@showDeleteByWrongBranchIdDialog)
                    .setTitle("$total document(s) milay — delete karein?")
                    .setMessage("Branch ID \"$badId\":\n\n$summary\n\nYe permanent hai, wapas nahi aa sakta. Continue?")
                    .setPositiveButton("Delete") { _, _ ->
                        Toast.makeText(this@showDeleteByWrongBranchIdDialog, "Deleting…", Toast.LENGTH_SHORT).show()
                        lifecycleScope.launch {
                            val deleted = SyncApi.deleteDocsByBranchId(this@showDeleteByWrongBranchIdDialog, badId)
                            val deletedSummary = deleted.entries.joinToString("\n") { "${it.key}: ${it.value}" }
                            android.app.AlertDialog.Builder(this@showDeleteByWrongBranchIdDialog)
                                .setTitle("${deleted.values.sum()} document(s) delete ho gaye")
                                .setMessage(deletedSummary.ifEmpty { "Kuch delete nahi hua." })
                                .setPositiveButton("OK", null)
                                .show()
                        }
                    }
                    .setNegativeButton("Cancel", null)
                    .show()
            }
        }
        .setNegativeButton("Cancel", null)
        .show()
}

/** One-time repair for Customer.balance/Supplier.balance drifting away from what
 *  that party's own sale/purchase + payment rows add up to — see
 *  SyncQueueHelper.recalculatePartyBalances for the full reasoning. Safe to run
 *  more than once; shows exactly which parties changed and by how much so it
 *  doubles as a diagnostic for "this party's balance doesn't match any bill". */
internal fun SettingsActivity.recalculatePartyBalancesClicked() {
    android.app.AlertDialog.Builder(this)
        .setTitle("Party balances recalculate karein?")
        .setMessage(
            "Har Customer/Supplier ka balance unki apni sale/purchase bills aur payments se " +
            "dobara ginega, aur jahan stored balance match nahi karta wahan usay theek kar " +
            "dega. Opening balance touch nahi hoga. Continue?"
        )
        .setPositiveButton("Continue") { _, _ ->
            Toast.makeText(this, "Checking party balances…", Toast.LENGTH_SHORT).show()
            lifecycleScope.launch {
                val db = com.grocerypos.v11.PosDatabase.get(this@recalculatePartyBalancesClicked)
                val fixes = com.grocerypos.v11.SyncQueueHelper.recalculatePartyBalances(db, this@recalculatePartyBalancesClicked)
                if (fixes.isEmpty()) {
                    Toast.makeText(this@recalculatePartyBalancesClicked, "Koi mismatch nahi mila — sab balances pehle se theek hain.", Toast.LENGTH_LONG).show()
                } else {
                    val summary = fixes.joinToString("\n") { "${it.name}: Rs %.2f → Rs %.2f".format(it.oldBalance, it.newBalance) }
                    android.app.AlertDialog.Builder(this@recalculatePartyBalancesClicked)
                        .setTitle("${fixes.size} balance(s) theek kar di gayi")
                        .setMessage(summary)
                        .setPositiveButton("OK", null)
                        .show()
                }
                onSyncNowClicked()
            }
        }
        .setNegativeButton("Cancel", null)
        .show()
}

/** One-time repair for Purchase/Sale cash-drawer rows created before RoomPurchaseRepository/
 *  RoomSaleRepository started stamping them with the bill's own (possibly back-dated) date
 *  instead of "now" — see SyncQueueHelper.fixBackdatedCashTransactionDates for the full
 *  reasoning. Safe to run more than once. */
internal fun SettingsActivity.fixBackdatedCashTransactionDatesClicked() {
    android.app.AlertDialog.Builder(this)
        .setTitle("Fix back-dated cash entries?")
        .setMessage(
            "Jo Purchase/Sale back-date karke banayi gayi thi, unki Cash Register entry " +
            "check karke us bill ki asal tareekh par theek kar degi (jahan wo abhi bhi " +
            "\"aaj\" ki date par ghalat pari hai). Baaqi entries (payments, Quick Sale, " +
            "cash in/out) is se touch nahi hongi. Continue?"
        )
        .setPositiveButton("Continue") { _, _ ->
            Toast.makeText(this, "Checking cash entries…", Toast.LENGTH_SHORT).show()
            lifecycleScope.launch {
                val db = com.grocerypos.v11.PosDatabase.get(this@fixBackdatedCashTransactionDatesClicked)
                val fixed = com.grocerypos.v11.SyncQueueHelper.fixBackdatedCashTransactionDates(db, this@fixBackdatedCashTransactionDatesClicked)
                Toast.makeText(
                    this@fixBackdatedCashTransactionDatesClicked,
                    if (fixed > 0) "$fixed cash entries ki date theek kar di gayi." else "Koi galat date wali entry nahi mili — sab pehle se theek hai.",
                    Toast.LENGTH_LONG
                ).show()
                onSyncNowClicked()
            }
        }
        .setNegativeButton("Cancel", null)
        .show()
}

/** Re-queues every local customer/supplier/product/sale/purchase/payment/expense/
 *  cash_transaction/user for a fresh push, then runs Sync Now. Use when this
 *  device's local data is the one that should win over whatever is currently on
 *  the server (see SyncQueueHelper.resyncAllLocalData for the full reasoning) —
 *  e.g. old records got stuck as unresolved "conflicts" on a previous build and
 *  their queue rows are long gone, so a normal Sync Now has nothing left to retry. */
internal fun SettingsActivity.resyncAllLocalDataClicked() {
    android.app.AlertDialog.Builder(this)
        .setTitle("Force full push?")
        .setMessage(
            "Ye is device ka SARA local data (customers, products, sales, purchases, " +
            "payments, expenses, cash transactions, users, units, categories, zakat, returns, shop settings) dobara Firebase par bhejega " +
            "— cloud par jo bhi maujooda data hai, is device ka data usay overwrite kar " +
            "dega. Sirf tab use karo jab is device ka data 'asal' (sahi) ho aur cloud ka " +
            "data purana/galat ho. Continue?"
        )
        .setPositiveButton("Continue") { _, _ ->
            Toast.makeText(this, "Queuing all local data…", Toast.LENGTH_SHORT).show()
            lifecycleScope.launch {
                val db = com.grocerypos.v11.PosDatabase.get(this@resyncAllLocalDataClicked)
                com.grocerypos.v11.SyncQueueHelper.resyncAllLocalData(db)
                onSyncNowClicked()
            }
        }
        .setNegativeButton("Cancel", null)
        .show()
}

/** Long-press "Sync Now" → pick a date & time → rewinds the pull checkpoint to that
 *  moment and immediately resyncs, so anything the server has changed since that time
 *  gets re-pulled (recovers a window where sync wasn't working, e.g. "yesterday 11am
 *  onward"). Does not affect what's queued to be pushed — only what gets pulled. */
internal fun SettingsActivity.showResyncFromDialog() {
    val cal = java.util.Calendar.getInstance()
    android.app.DatePickerDialog(
        this,
        { _, y, m, d ->
            cal.set(java.util.Calendar.YEAR, y)
            cal.set(java.util.Calendar.MONTH, m)
            cal.set(java.util.Calendar.DAY_OF_MONTH, d)
            android.app.TimePickerDialog(
                this,
                { _, hour, minute ->
                    cal.set(java.util.Calendar.HOUR_OF_DAY, hour)
                    cal.set(java.util.Calendar.MINUTE, minute)
                    cal.set(java.util.Calendar.SECOND, 0)
                    com.grocerypos.v11.sync.SyncRepository.resetSyncCheckpoint(this, cal.timeInMillis)
                    val fmt = java.text.SimpleDateFormat("dd MMM, hh:mm a", java.util.Locale.getDefault())
                    Toast.makeText(
                        this,
                        "Resyncing from ${fmt.format(cal.time)}…",
                        Toast.LENGTH_LONG
                    ).show()
                    onSyncNowClicked()
                },
                cal.get(java.util.Calendar.HOUR_OF_DAY),
                cal.get(java.util.Calendar.MINUTE),
                false
            ).show()
        },
        cal.get(java.util.Calendar.YEAR),
        cal.get(java.util.Calendar.MONTH),
        cal.get(java.util.Calendar.DAY_OF_MONTH)
    ).apply { datePicker.calendarViewShown = true; datePicker.spinnersShown = false }.show()
}

// ADDED (multi-tenant support): admin pastes their own Firebase project's 4
// values here (from Firebase Console > Project Settings > General > Your apps).
// See CloudConfigStore.kt for exactly why this exists and how it's used.
// ADDED (sync recoverability): a simple read-only viewer for the audit log —
// conflicts and push failures first (most likely to need attention), then
// everything else, newest first. Purely local — doesn't touch Firestore.
internal fun SettingsActivity.openSyncHistoryDialog() {
    val container = LinearLayout(this).apply {
        orientation = LinearLayout.VERTICAL
        setPadding(24, 16, 24, 8)
    }
    val scroll = ScrollView(this).apply { addView(container) }
    val loading = TextView(this).apply {
        text = "Loading…"
        setPadding(4, 8, 4, 8)
        setTextColor(Color.parseColor(textGray))
    }
    container.addView(loading)

    // NEW: one-time "Clear History" — wipes the local audit log (purely a
    // diagnostic record of conflicts/push failures; never synced to the cloud
    // or to other devices), so old noise can be cleared out once things are fixed.
    val dialog = AlertDialog.Builder(this)
        .setTitle("Sync History")
        .setView(scroll)
        .setPositiveButton("Close", null)
        .setNegativeButton("Clear History") { _, _ ->
            lifecycleScope.launch {
                PosDatabase.get(this@openSyncHistoryDialog).auditDao().clearAll()
                Toast.makeText(this@openSyncHistoryDialog, "Sync history clear ho gayi", Toast.LENGTH_SHORT).show()
            }
        }
        .create()
    dialog.show()

    lifecycleScope.launch {
        val db = PosDatabase.get(this@openSyncHistoryDialog)
        val stuckItems = try {
            db.syncQueueDao().stuck()
        } catch (e: Exception) {
            emptyList()
        }
        val entries = try {
            db.auditDao().recent()
        } catch (e: Exception) {
            emptyList()
        }
        container.removeAllViews()

        // ADDED (risk-free POS): items that gave up retrying after 10 failed
        // attempts — shown first with a one-tap way to give them another chance,
        // e.g. after fixing whatever was wrong (internet, Firestore rules, etc).
        if (stuckItems.isNotEmpty()) {
            container.addView(LinearLayout(this@openSyncHistoryDialog).apply {
                orientation = LinearLayout.HORIZONTAL
                gravity = Gravity.CENTER_VERTICAL
                setPadding(16, 12, 16, 12)
                background = strokedBg(amber, amberBg, 12)
                layoutParams = LinearLayout.LayoutParams(
                    LinearLayout.LayoutParams.MATCH_PARENT, LinearLayout.LayoutParams.WRAP_CONTENT
                ).apply { setMargins(0, 0, 0, 12) }

                addView(TextView(this@openSyncHistoryDialog).apply {
                    text = "${stuckItems.size} item(s) 10 baar fail hone ke baad rukk gaye"
                    textSize = 12f
                    setTextColor(Color.parseColor(amber))
                    setTypeface(typeface, Typeface.BOLD)
                    layoutParams = LinearLayout.LayoutParams(0, LinearLayout.LayoutParams.WRAP_CONTENT, 1f)
                    setLeadingIcon(R.drawable.ic_warning, amber, 14, 6)
                })
                addView(TextView(this@openSyncHistoryDialog).apply {
                    text = "Retry Now"
                    textSize = 12f
                    setTextColor(Color.WHITE)
                    setTypeface(typeface, Typeface.BOLD)
                    background = roundedBg(amber, 20)
                    setPadding(20, 10, 20, 10)
                    setLeadingIcon(R.drawable.ic_sync, "#FFFFFF", 13, 5)
                    setOnClickListener {
                        lifecycleScope.launch {
                            db.syncQueueDao().resetAllStuck()
                            Toast.makeText(this@openSyncHistoryDialog, "Dobara try kiya jayega agli Sync Now par", Toast.LENGTH_SHORT).show()
                            dialog.dismiss()
                        }
                    }
                })
            })
        }

        if (entries.isEmpty()) {
            container.addView(TextView(this@openSyncHistoryDialog).apply {
                text = "Koi sync activity ya conflict abhi tak record nahi hua."
                setTextColor(Color.parseColor(textGray))
                setPadding(4, 8, 4, 8)
            })
            return@launch
        }

        val fmt = java.text.SimpleDateFormat("dd MMM, hh:mm a", java.util.Locale.getDefault())
        for (e in entries) {
            val isConflict = e.action == "sync_conflict"
            val isFailure = e.action == "sync_push_failed"
            val labelColor = when {
                isConflict -> amber
                isFailure -> red
                else -> textGray
            }
            container.addView(LinearLayout(this@openSyncHistoryDialog).apply {
                orientation = LinearLayout.VERTICAL
                setPadding(16, 12, 16, 12)
                background = strokedBg(border, if (isConflict || isFailure) amberBg else cardWhite, 12)
                layoutParams = LinearLayout.LayoutParams(
                    LinearLayout.LayoutParams.MATCH_PARENT, LinearLayout.LayoutParams.WRAP_CONTENT
                ).apply { setMargins(0, 0, 0, 8) }

                addView(TextView(this@openSyncHistoryDialog).apply {
                    text = when (e.action) {
                        "sync_conflict" -> "Conflict — ${e.reference}"
                        "sync_push_failed" -> "Push failed — ${e.reference}"
                        else -> e.reference
                    }
                    setTextColor(Color.parseColor(labelColor))
                    setTypeface(typeface, Typeface.BOLD)
                    textSize = 12.5f
                    when (e.action) {
                        "sync_conflict" -> setLeadingIcon(R.drawable.ic_warning, labelColor, 13, 5)
                        "sync_push_failed" -> setLeadingIcon(R.drawable.ic_close, labelColor, 13, 5)
                    }
                })
                if (e.details.isNotBlank()) {
                    addView(TextView(this@openSyncHistoryDialog).apply {
                        text = e.details
                        setTextColor(Color.parseColor(textDark))
                        textSize = 11.5f
                        setPadding(0, 4, 0, 0)
                    })
                }
                addView(TextView(this@openSyncHistoryDialog).apply {
                    text = fmt.format(java.util.Date(e.createdAt))
                    setTextColor(Color.parseColor(textGray))
                    textSize = 10.5f
                    setPadding(0, 4, 0, 0)
                })
            })
        }
    }
}

internal fun SettingsActivity.openCloudSyncSetupDialog() {
    val existing = com.grocerypos.v11.CloudConfigStore.get(this)

    val container = LinearLayout(this).apply {
        orientation = LinearLayout.VERTICAL
        setPadding(32, 24, 32, 8)
    }

    fun labeledField(label: String, prefill: String): EditText {
        container.addView(TextView(this).apply {
            text = label
            textSize = 11f
            setTextColor(Color.parseColor(textGray))
            setPadding(2, 14, 0, 4)
        })
        val field = EditText(this).apply {
            setText(prefill)
            setSingleLine(true)
            background = strokedBg(border, cardWhite, 10)
            setPadding(20, 18, 20, 18)
            textSize = 13.5f
        }
        container.addView(field)
        return field
    }

    container.addView(TextView(this).apply {
        text = "Firebase Console → Project Settings → General → Your apps (Android) → Config mein ye 4 values milengi. Khali chhod kar wapas is build ke default project par ja sakte hain (agar koi ho)."
        textSize = 11.5f
        setTextColor(Color.parseColor(textGray))
        setPadding(2, 0, 0, 4)
    })

    val projectIdField = labeledField("Project ID", existing?.projectId ?: "")
    val apiKeyField = labeledField("API Key", existing?.apiKey ?: "")
    val appIdField = labeledField("App ID", existing?.appId ?: "")
    val storageBucketField = labeledField("Storage Bucket", existing?.storageBucket ?: "")

    // ADDED (runtime branch config): each branch is now told apart by a code
    // entered here instead of a compile-time BuildConfig value baked into a
    // separate APK per branch — see BranchConfigStore.kt.
    container.addView(TextView(this).apply {
        text = "Is device ka Branch Code — har branch ke liye alag, jaise \"main-branch\" ya \"dusri-branch\". Sab devices jo ek hi branch ka data share karna chahte hain, unka code same hona chahiye."
        textSize = 11.5f
        setTextColor(Color.parseColor(textGray))
        setPadding(2, 10, 0, 4)
    })
    val branchIdField = labeledField("Branch Code", BranchConfigStore.current)

    // ADDED (branch approval): this device's Firebase Auth UID, so the shop
    // owner/admin can hand it off to whoever manages the Firebase console to
    // create the matching branch_members/{uid} document — see firestore.rules
    // and SyncApi.currentUid(). Without this document existing server-side, sync
    // will authenticate fine but every read/write gets rejected as permission-
    // denied — this field is what lets a human actually fix that.
    val uid = SyncApi.currentUid(this)
    container.addView(TextView(this).apply {
        text = "Device ID (admin ko share karein taake yeh device branch access ke liye approve ho sake)"
        textSize = 11f
        setTextColor(Color.parseColor(textGray))
        setPadding(2, 14, 0, 4)
    })
    val uidRow = LinearLayout(this).apply {
        orientation = LinearLayout.HORIZONTAL
        gravity = Gravity.CENTER_VERTICAL
    }
    uidRow.addView(TextView(this).apply {
        text = uid ?: "Pehle Save karein — pehli sync attempt ke baad ID yahan aayegi"
        textSize = 12.5f
        setTextColor(Color.parseColor(if (uid != null) textDark else textGray))
        setPadding(0, 0, 12, 0)
        layoutParams = LinearLayout.LayoutParams(0, ViewGroup.LayoutParams.WRAP_CONTENT, 1f)
    })
    if (uid != null) {
        uidRow.addView(Button(this).apply {
            text = "Copy"
            textSize = 11f
            setOnClickListener {
                val cm = getSystemService(Context.CLIPBOARD_SERVICE) as ClipboardManager
                cm.setPrimaryClip(ClipData.newPlainText("Device ID", uid))
                Toast.makeText(this@openCloudSyncSetupDialog, "Device ID copy ho gayi", Toast.LENGTH_SHORT).show()
            }
        })
    }
    container.addView(uidRow)

    val scroll = ScrollView(this).apply { addView(container) }

    val dialogBuilder = AlertDialog.Builder(this)
        // ADDED (build verification): app version shown right in the dialog title,
        // so after installing a new build it's a one-glance check whether this
        // device is actually running it — no guessing whether a rebuild/reinstall
        // actually took effect. See BuildConfig.VERSION_NAME (app/build.gradle.kts).
        .setTitle("Cloud Sync Setup (v${com.grocerypos.v11.BuildConfig.VERSION_NAME})")
        .setView(scroll)
        .setPositiveButton("Save") { _, _ ->
            val projectId = projectIdField.text.toString().trim()
            val apiKey = apiKeyField.text.toString().trim()
            val appId = appIdField.text.toString().trim()
            val storageBucket = storageBucketField.text.toString().trim()
            val branchId = branchIdField.text.toString().trim()

            if (projectId.isEmpty() || apiKey.isEmpty() || appId.isEmpty()) {
                Toast.makeText(this, "Project ID, API Key aur App ID zaroori hain", Toast.LENGTH_SHORT).show()
                return@setPositiveButton
            }
            if (!BranchConfigStore.isValid(branchId)) {
                Toast.makeText(this, "Branch Code 2-50 characters ka ho: A-Z, 0-9, _ ya -", Toast.LENGTH_LONG).show()
                return@setPositiveButton
            }

            fun doSave() {
                com.grocerypos.v11.CloudConfigStore.save(
                    this,
                    com.grocerypos.v11.CloudConfig(projectId, apiKey, appId, storageBucket)
                )
                BranchConfigStore.set(this, branchId)
                Toast.makeText(this, "Cloud project connected — ab Sync Now try karein", Toast.LENGTH_LONG).show()
                refreshSyncStatus()
            }

            // NEW (P1 security — item #4, Branch Change + Pending Queue Protection):
            // SyncApi.push() always re-stamps every queued record with
            // BranchConfigStore.current AT PUSH TIME (a deliberate earlier fix, for
            // healing entries that had a stale/blank branch id) — not the branch that
            // was active when the record was actually queued. That means switching
            // the Branch Code here while offline records are still waiting to sync
            // would silently push THIS branch's pending data into the NEWLY selected
            // branch's Firestore documents. Block a real branch change until the
            // queue is empty; a first-time setup (no branch configured yet) or saving
            // with the SAME branch code is unaffected.
            val oldBranch = BranchConfigStore.current
            val isRealBranchChange = BranchConfigStore.isConfigured() && branchId != oldBranch
            if (!isRealBranchChange) {
                doSave()
                return@setPositiveButton
            }
            lifecycleScope.launch {
                val pending = PosDatabase.get(this@openCloudSyncSetupDialog).syncQueueDao().pendingCount()
                if (pending > 0) {
                    AlertDialog.Builder(this@openCloudSyncSetupDialog)
                        .setTitle("Pending offline records")
                        .setMessage("Is device par abhi $pending record(s) '$oldBranch' branch ke liye sync hone baaki hain. Branch badalne se pehle inhe sync karna zaroori hai, warna ye ghalat branch mein chale jayenge.\n\nPehle 'Sync Now' try karein, sab records sync hone ke baad dobara Branch Code save karein.")
                        .setPositiveButton("Sync Now") { _, _ -> SyncQueueHelper.trigger(this@openCloudSyncSetupDialog) }
                        .setNegativeButton("Cancel", null)
                        .show()
                } else {
                    doSave()
                }
            }
        }
        .setNegativeButton("Cancel", null)

    // FIX (duplicate Cancel button): setNeutralButton used to always be added with
    // label "Cancel" whenever there was no existing config, which put two
    // identically-labelled Cancel buttons on the dialog side by side. Only add the
    // neutral button at all when there's something to actually disconnect.
    if (existing != null) {
        dialogBuilder.setNeutralButton("Disconnect") { _, _ ->
            // NEW (P1 security — item #4): same reasoning as the Save-button guard
            // above — disconnecting clears BranchConfigStore, so a later Save would
            // no longer see this as a "real branch change" and the guard above would
            // be bypassed. Check pending records here too before actually clearing.
            lifecycleScope.launch {
                val pending = PosDatabase.get(this@openCloudSyncSetupDialog).syncQueueDao().pendingCount()
                if (pending > 0) {
                    AlertDialog.Builder(this@openCloudSyncSetupDialog)
                        .setTitle("Pending offline records")
                        .setMessage("Is device par abhi $pending record(s) sync hone baaki hain. Disconnect karne se pehle inhe sync kar lein, warna ye baad mein ghalat branch mein chale ja sakte hain.")
                        .setPositiveButton("Sync Now") { _, _ -> SyncQueueHelper.trigger(this@openCloudSyncSetupDialog) }
                        .setNegativeButton("Disconnect Anyway") { _, _ ->
                            com.grocerypos.v11.CloudConfigStore.clear(this@openCloudSyncSetupDialog)
                            BranchConfigStore.clear(this@openCloudSyncSetupDialog)
                            Toast.makeText(this@openCloudSyncSetupDialog, "Cloud project aur Branch Code disconnect ho gaye", Toast.LENGTH_SHORT).show()
                            refreshSyncStatus()
                        }
                        .show()
                } else {
                    com.grocerypos.v11.CloudConfigStore.clear(this@openCloudSyncSetupDialog)
                    BranchConfigStore.clear(this@openCloudSyncSetupDialog)
                    Toast.makeText(this@openCloudSyncSetupDialog, "Cloud project aur Branch Code disconnect ho gaye", Toast.LENGTH_SHORT).show()
                    refreshSyncStatus()
                }
            }
        }
    }

    dialogBuilder.show()
}

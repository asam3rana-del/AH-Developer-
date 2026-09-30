package com.grocerypos.v11

import android.content.Context

/**
 * Runtime-configurable branch ID, replacing the old compile-time BuildConfig.BRANCH_ID.
 *
 * WHY THIS EXISTS: BuildConfig.BRANCH_ID meant every branch of a multi-branch shop
 * needed its own separately-built APK (see app/build.gradle.kts's old
 * buildConfigField("String", "BRANCH_ID", ...)). That doesn't scale — adding a new
 * branch meant a new build, and every device at a branch had to be flashed with the
 * matching APK. This store lets the branch code be entered once on-device, in
 * Settings > Cloud Sync Setup, the same way CloudConfigStore lets the Firebase
 * project be entered on-device instead of baked in at compile time.
 *
 * SECURITY NOTE: this value is NOT what grants a device access to a branch's data —
 * it's just what gets stamped onto documents this device pushes, and what pull()
 * filters by locally. The actual access control lives entirely server-side, in
 * Firestore's branch_members/{uid} mapping and the security rules that check against
 * it (see firestore.rules) — a device that enters the wrong branch code here simply
 * gets permission-denied by Firestore, it doesn't gain access to anything. Whoever
 * manages the Firebase console/admin script is the only place that can actually
 * grant a device access to a given branch's data.
 *
 * Generated/loaded once on app start and cached in memory (like DeviceTag), so it's
 * available synchronously wherever an ID needs to be built, without needing a
 * suspend function or a database call.
 */
object BranchConfigStore {
    private const val PREFS = "branch_config_prefs"
    private const val KEY_BRANCH_ID = "branch_id"

    // Fallback only used if init() somehow hasn't run yet when current is first read
    // (shouldn't happen — PosApplication.onCreate() calls init() before anything else
    // that could need it, same as DeviceTag).
    @Volatile private var cached: String = ""

    /** Call once from PosApplication.onCreate(). Existing installations keep their
     *  previously stored branch. New installations must choose a branch in Settings;
     *  there is intentionally no compile-time branch fallback. */
    fun init(context: Context) {
        val prefs = context.applicationContext.getSharedPreferences(PREFS, Context.MODE_PRIVATE)
        val stored = prefs.getString(KEY_BRANCH_ID, null)
        cached = stored?.trim()?.takeIf { isValid(it) } ?: ""
    }

    /** The branch code currently in effect on this device. Empty string means "not
     *  configured yet" — callers pushing/pulling should treat that the same way
     *  CloudConfigStore.isConfigured()==false is treated: nothing to sync. */
    val current: String get() = cached

    fun isConfigured(): Boolean = isValid(cached)

    /** Firestore document paths must never contain '/'. Keep branch codes predictable
     *  and safe: letters, numbers, underscore and hyphen only. */
    fun isValid(branchId: String): Boolean =
        branchId.trim().matches(Regex("[A-Za-z0-9_-]{2,50}"))

    fun set(context: Context, branchId: String) {
        val trimmed = branchId.trim()
        require(isValid(trimmed)) {
            "Branch Code must be 2-50 characters and contain only A-Z, a-z, 0-9, _ or -."
        }
        context.applicationContext.getSharedPreferences(PREFS, Context.MODE_PRIVATE)
            .edit().putString(KEY_BRANCH_ID, trimmed).apply()
        cached = trimmed
    }

    fun clear(context: Context) {
        context.applicationContext.getSharedPreferences(PREFS, Context.MODE_PRIVATE)
            .edit().remove(KEY_BRANCH_ID).apply()
        cached = ""
    }
}

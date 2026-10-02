package com.grocerypos.v11

import android.app.Activity
import android.app.Application
import android.content.Context
import android.content.Intent
import android.os.Bundle
import com.grocerypos.v11.ui.LoginActivity
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.launch

/**
 * Tracks whether the app as a whole (not just one Activity) has left the foreground, and — if
 * Settings > Security is set to "Fingerprint Only" or "Both" — forces the user back through
 * LoginActivity the next time ANY Activity comes to the front.
 *
 * Why a counter instead of relying on onPause/onResume of a single Activity: navigating between
 * two of the app's own screens (e.g. MainActivity -> SaleActivity) also fires onPause/onResume,
 * but that is NOT the user leaving the app. Every Activity's onStart/onStop increments/decrements
 * `startedCount`; it only reaches 0 when literally nothing from this app is visible anymore
 * (Home pressed, app switched away, screen locked, etc.) — that's the only case that should
 * trigger a re-lock.
 *
 * Must be registered once from the Application class (see PosApplication).
 *
 * FIX — double fingerprint prompt: onActivityStopped used to kick off an ASYNC coroutine to read
 * `login_method` from the database, then set `pendingReauth = true` whenever that query finished.
 * If the user left and came straight back before the query finished, the flag would land late and
 * arm itself in the background — then the very next screen the user opened from *inside* the app
 * (or MainActivity opening right after a successful login) would incorrectly see pendingReauth
 * already true and force ANOTHER fingerprint prompt, even though the user never left the app again.
 * Two changes fix this:
 *  1. `login_method` is now cached in memory (loaded once at startup, refreshed whenever Settings
 *     changes it) so the check in onActivityStopped is instant/synchronous — no more race.
 *  2. LoginActivity itself is excluded from arming pendingReauth, since its own stop/start events
 *     are part of the lock/unlock flow, not the user leaving the app.
 *
 * "No Password" login method: Settings > Security now offers a fourth option, "none", which
 * means the user wants to skip the lock screen entirely. cachedLoginMethod == "none" is treated
 * the same as "password" below — neither ever arms pendingReauth — so returning to the app from
 * the background goes straight back to whatever screen was open, no re-authentication prompt.
 * ("password" itself was already never re-locking on resume; the one-time login at app launch —
 * checked in MainActivity via the session username — is a separate flow this class doesn't touch.
 * Fully skipping THAT initial login screen for "none" would need a change inside LoginActivity's
 * own onCreate, which wasn't available to edit here.)
 *
 * FIX — process-kill bypass: `pendingReauth` used to live ONLY in this in-memory var. On a
 * low-memory device Android can (and often does) kill the app's process entirely while it's in
 * the background instead of just stopping it. When the user reopened the app, Android would spin
 * up a brand-new process and restore the last-open screen directly — a fresh `AppLock` object
 * with `pendingReauth = false`, so the fingerprint/password re-lock was silently skipped even
 * though Settings had "Fingerprint Only"/"Both" turned on. `pendingReauth` is now mirrored into a
 * SharedPreferences flag every time it's armed or consumed, and `register()` restores it from
 * that flag on startup — so a fresh process that resumes from a background-kill still re-locks.
 */
object AppLock {

    private const val PREFS_NAME = "app_lock_state"
    private const val KEY_PENDING_REAUTH = "pending_reauth"

    private var startedCount = 0

    @Volatile
    private var pendingReauth = false

    // In-memory cache of Settings > Security > Login Method ("none" / "password" / "fingerprint" / "both").
    // Read synchronously wherever needed so re-lock decisions never race with a DB query.
    @Volatile
    private var cachedLoginMethod: String = "password"

    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.IO)

    fun register(app: Application) {
        // Restore any re-lock that was armed before the process got killed in the background
        // (e.g. Android reclaiming memory) — this read is synchronous SharedPreferences, so it's
        // safe to do before the DB-backed cachedLoginMethod load below finishes.
        pendingReauth = app.getSharedPreferences(PREFS_NAME, Context.MODE_PRIVATE)
            .getBoolean(KEY_PENDING_REAUTH, false)

        // Load the current setting once at startup so the cache is correct from the first
        // background/foreground cycle onward.
        scope.launch {
            cachedLoginMethod = PosDatabase.get(app).appSettingDao().get("login_method")?.value ?: "password"
        }

        app.registerActivityLifecycleCallbacks(object : Application.ActivityLifecycleCallbacks {

            override fun onActivityStarted(activity: Activity) {
                startedCount++

                // The app just came back to the foreground after being fully backgrounded,
                // and the saved login method requires re-authentication. Redirect whichever
                // Activity is coming up straight to LoginActivity, clearing the task so Back
                // can't skip past it. LoginActivity itself is excluded so this doesn't loop.
                if (pendingReauth && activity !is LoginActivity) {
                    pendingReauth = false
                    persistPendingReauth(activity, false)
                    val intent = Intent(activity, LoginActivity::class.java).apply {
                        flags = Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_CLEAR_TASK
                    }
                    activity.startActivity(intent)
                    activity.finish()
                }
            }

            override fun onActivityStopped(activity: Activity) {
                startedCount--
                if (startedCount <= 0) {
                    startedCount = 0

                    // LoginActivity stopping is part of the lock/unlock flow itself (e.g. it's
                    // being replaced by MainActivity right after a successful login) — it is
                    // never "the user leaving the app", so it must not re-arm pendingReauth.
                    if (activity is LoginActivity) return

                    // Synchronous — no DB query, no race. The cache is kept fresh by register()'s
                    // initial load and by AppSettingsActivity calling updateCachedLoginMethod().
                    // "none" (No Password) and "password" both fall through here without arming
                    // pendingReauth — only "fingerprint"/"both" ever force a re-lock on resume.
                    if (cachedLoginMethod == "fingerprint" || cachedLoginMethod == "both") {
                        pendingReauth = true
                        persistPendingReauth(activity, true)
                    }
                }
            }

            override fun onActivityCreated(activity: Activity, savedInstanceState: Bundle?) {}
            override fun onActivityResumed(activity: Activity) {}
            override fun onActivityPaused(activity: Activity) {}
            override fun onActivitySaveInstanceState(activity: Activity, outState: Bundle) {}
            override fun onActivityDestroyed(activity: Activity) {}
        })
    }

    /**
     * Call this immediately whenever Settings > Security > Login Method is changed, so the
     * in-memory cache used by onActivityStopped stays correct without needing a fresh DB read.
     */
    fun updateCachedLoginMethod(method: String) {
        cachedLoginMethod = method
    }

    /**
     * Mirrors `pendingReauth` into SharedPreferences so it survives the process being killed
     * while backgrounded. Uses `applicationContext` off whatever Activity triggered the change,
     * so it never leaks an Activity reference.
     */
    private fun persistPendingReauth(activity: Activity, value: Boolean) {
        activity.applicationContext
            .getSharedPreferences(PREFS_NAME, Context.MODE_PRIVATE)
            .edit()
            .putBoolean(KEY_PENDING_REAUTH, value)
            .apply()
    }
}

package com.grocerypos.v11

import android.app.Application
import com.grocerypos.v11.sync.NetworkMonitor
import com.grocerypos.v11.sync.SyncRepository
import com.grocerypos.v11.sync.SyncWorker

/**
 * Single Application class for the app.
 *
 * Registers:
 * - SyncRepository.appContextRef (needed by sync push/pull)
 * - SyncWorker periodic background sync (every 15 minutes)
 * - NetworkMonitor (triggers an immediate sync when connectivity returns)
 * - AppLock (watches every Activity, forces re-auth per Settings > Security)
 * - BackupScheduler (automatic local .db backup at ~12 PM, ~9 PM, and whenever the
 *   app is closed/backgrounded — on top of the existing manual Backup button)
 *
 * IMPORTANT: AndroidManifest.xml's <application> tag must have
 * android:name=".PosApplication" — without that line the OS never instantiates
 * this class and NONE of the above run (this was previously the case; a
 * duplicate App.kt with its own onCreate() was silently dead code and has
 * been removed).
 */
class PosApplication : Application() {
    override fun onCreate() {
        super.onCreate()

        // FIX (crash-catcher coverage): installed first, before ANYTHING else in the app —
        // this way a crash on any screen (including LoginActivity, which never even reaches
        // MainActivity's onCreate when there's no session) is always captured.
        com.grocerypos.v11.util.CrashHandler.install(this)

        // FIX (multi-device sync): must run before anything that builds a sync entity
        // ID or a billNo — see DeviceTag.kt for why.
        DeviceTag.init(this)
        // FIX (runtime branch config): must run before anything that stamps a
        // "branchId" field or filters a pull by branch — see BranchConfigStore.kt.
        BranchConfigStore.init(this)
        SyncRepository.appContextRef = applicationContext

        // FIX (white-screen-no-log): if any one of these startup calls throws (sync worker
        // scheduling, network monitor registration, backup scheduling, etc.), it no longer
        // takes the whole app down before CrashHandler even got a chance to log anything
        // meaningful — each is now isolated so one bad call can't crash app startup.
        try {
            SyncWorker.schedulePeriodic(this)
        } catch (e: Exception) {
            android.util.Log.e("PosApplication", "SyncWorker.schedulePeriodic failed", e)
        }
        try {
            NetworkMonitor.register(this)
        } catch (e: Exception) {
            android.util.Log.e("PosApplication", "NetworkMonitor.register failed", e)
        }
        try {
            AppLock.register(this)
        } catch (e: Exception) {
            android.util.Log.e("PosApplication", "AppLock.register failed", e)
        }
        try {
            BackupScheduler.register(this)
        } catch (e: Exception) {
            android.util.Log.e("PosApplication", "BackupScheduler.register failed", e)
        }
        try {
            BackupScheduler.scheduleDailyCheckpoints(this)
        } catch (e: Exception) {
            android.util.Log.e("PosApplication", "BackupScheduler.scheduleDailyCheckpoints failed", e)
        }
    }
}

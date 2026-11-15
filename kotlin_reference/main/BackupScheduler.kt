package com.grocerypos.v11

import android.app.Activity
import android.app.Application
import android.content.Context
import android.os.Bundle
import androidx.work.*
import com.grocerypos.v11.util.BackupHelper
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.launch
import java.text.SimpleDateFormat
import java.util.*
import java.util.concurrent.TimeUnit

/**
 * Automatic offline backups, on top of the existing manual "Backup" button.
 *
 * Three triggers, matching the shop's 7 AM - 10 PM hours:
 *  1. ~12:00 PM checkpoint  (covers the morning)
 *  2. ~9:00 PM checkpoint   (covers the afternoon/evening, before closing)
 *  3. App close/background  (covers whatever happened after the 9 PM checkpoint,
 *     e.g. last-minute sales before the shop actually shuts)
 *
 * Each checkpoint only fires once per calendar day (tracked in SharedPreferences),
 * so re-opening the app after 9 PM doesn't spam backups.
 *
 * FIX (too many files): the app-close trigger used to call backupNow() unconditionally
 * on every single background/close — a cashier tapping Home and reopening the app
 * repeatedly through the day could generate dozens of near-identical backup files.
 * It now goes through BackupHelper.backupIfDue(), which skips the backup if the last
 * one (of any kind — checkpoint or close) ran less than 30 minutes ago.
 *
 * Uses the same BackupHelper.backupNow() as the manual button — same WAL checkpoint,
 * same destination folders (app Backups + Downloads) — just triggered automatically
 * instead of by a tap.
 */
object BackupScheduler {

    private const val PREFS = "auto_backup_prefs"
    private const val KEY_LAST_NOON_DATE = "last_noon_backup_date"
    private const val KEY_LAST_NIGHT_DATE = "last_night_backup_date"
    private const val WORK_NAME = "grocery_pos_backup_checkpoints"

    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.IO)
    private val dayFormat = SimpleDateFormat("yyyy-MM-dd", Locale.getDefault())

    // ---------- 1) Register app-close/background backup ----------

    private var startedCount = 0

    fun register(app: Application) {
        app.registerActivityLifecycleCallbacks(object : Application.ActivityLifecycleCallbacks {
            override fun onActivityStarted(activity: Activity) {
                startedCount++
            }

            override fun onActivityStopped(activity: Activity) {
                startedCount--
                if (startedCount <= 0) {
                    // Nothing from this app is visible anymore — app was minimized/closed.
                    runBackup(app.applicationContext)
                }
            }

            override fun onActivityCreated(activity: Activity, savedInstanceState: Bundle?) {}
            override fun onActivityResumed(activity: Activity) {}
            override fun onActivityPaused(activity: Activity) {}
            override fun onActivitySaveInstanceState(activity: Activity, outState: Bundle) {}
            override fun onActivityDestroyed(activity: Activity) {}
        })
    }

    // ---------- 2) Schedule the 12 PM / 9 PM checkpoint checks ----------

    /**
     * WorkManager can't guarantee an exact clock time, so instead of scheduling two
     * one-shot alarms (which Doze/battery-optimization can delay by hours anyway), this
     * runs a lightweight check every 15 minutes — same cadence as SyncWorker — and does
     * the actual backup the first time it notices the current time has passed 12:00 PM
     * or 9:00 PM for that day. Safe to call on every app start: ExistingPeriodicWorkPolicy.KEEP
     * means it won't duplicate or restart an already-scheduled check.
     */
    fun scheduleDailyCheckpoints(context: Context) {
        val request = PeriodicWorkRequestBuilder<BackupCheckpointWorker>(15, TimeUnit.MINUTES)
            .build()

        WorkManager.getInstance(context).enqueueUniquePeriodicWork(
            WORK_NAME,
            ExistingPeriodicWorkPolicy.KEEP,
            request
        )
    }

    /** Called by BackupCheckpointWorker every ~15 minutes. */
    fun checkCheckpoints(context: Context) {
        val cal = Calendar.getInstance()
        val today = dayFormat.format(cal.time)
        val hour = cal.get(Calendar.HOUR_OF_DAY)
        val minute = cal.get(Calendar.MINUTE)
        val prefs = context.getSharedPreferences(PREFS, Context.MODE_PRIVATE)

        // Noon checkpoint: anytime from 12:00 PM onward, once per day.
        val pastNoon = hour > 12 || (hour == 12)
        if (pastNoon && prefs.getString(KEY_LAST_NOON_DATE, "") != today) {
            BackupHelper.backupNow(context)
            prefs.edit().putString(KEY_LAST_NOON_DATE, today).apply()
        }

        // 9 PM checkpoint: anytime from 21:00 onward, once per day.
        val pastNine = hour >= 21
        if (pastNine && prefs.getString(KEY_LAST_NIGHT_DATE, "") != today) {
            BackupHelper.backupNow(context)
            prefs.edit().putString(KEY_LAST_NIGHT_DATE, today).apply()
        }

        // Suppress unused warning for minute (kept for potential future finer-grained checks).
        if (minute < 0) return
    }

    private fun runBackup(context: Context) {
        scope.launch {
            try {
                // Throttled: skipped if a backup already ran in the last 30 minutes,
                // so repeatedly minimizing/reopening the app doesn't flood the backup
                // folder with files.
                BackupHelper.backupIfDue(context, minGapMinutes = 30)
            } catch (e: Exception) {
                e.printStackTrace()
            }
        }
    }
}

/** Runs every 15 minutes in the background; delegates to BackupScheduler.checkCheckpoints(). */
class BackupCheckpointWorker(context: Context, params: WorkerParameters) :
    CoroutineWorker(context, params) {
    override suspend fun doWork(): Result {
        return try {
            BackupScheduler.checkCheckpoints(applicationContext)
            Result.success()
        } catch (e: Exception) {
            Result.retry()
        }
    }
}

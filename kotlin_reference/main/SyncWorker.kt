package com.grocerypos.v11.sync

import android.content.Context
import androidx.lifecycle.LiveData
import androidx.work.*
import java.util.concurrent.TimeUnit

class SyncWorker(context: Context, params: WorkerParameters) : CoroutineWorker(context, params) {
    // FIX (Job-was-cancelled bug): the actual network work now happens entirely
    // inside this CoroutineWorker's own scope, which WorkManager keeps alive
    // independently of any Activity — it is NOT cancelled just because Settings
    // gets closed, the screen rotates, or the app goes to the background. Previously
    // "Sync Now" ran SyncRepository.syncNow() directly inside SettingsActivity's
    // lifecycleScope, so leaving that screen mid-sync (easy to do with hundreds of
    // queued rows) killed the sync with a "Job was cancelled" error that had nothing
    // to do with Firestore rules or connectivity. Routing every manual sync through
    // here (see syncNowOnce()) fixes that regardless of which screen triggers it.
    override suspend fun doWork(): Result {
        return try {
            val result = SyncRepository.syncNow(applicationContext)
            // Stash a human-readable summary in the output data so a caller that's
            // still around (e.g. Settings' "Sync Now" row, via observeManualSync())
            // can show the user what actually happened — same text SyncResult.summary()
            // always produced, just no longer computed on a scope that might vanish
            // before it gets used.
            val output = workDataOf(KEY_SUMMARY to result.summary())
            if (result.pulledOk) Result.success(output) else Result.failure(output)
        } catch (e: Exception) {
            Result.failure(workDataOf(KEY_SUMMARY to "Sync failed: ${e.message ?: "unknown error"}"))
        }
    }

    companion object {
        private const val PERIODIC_WORK_NAME = "grocery_pos_periodic_sync"
        private const val ONE_TIME_WORK_NAME = "grocery_pos_manual_sync"

        /** Key into WorkInfo.outputData for the human-readable result of a manual
         *  sync — see observeManualSync(). */
        const val KEY_SUMMARY = "summary"

        /**
         * Call this once, e.g. in your Application.onCreate() or MainActivity.onCreate(),
         * to start automatic background sync every 15 minutes (WorkManager's minimum
         * interval for periodic work). Safe to call every app start — ExistingPeriodicWorkPolicy.KEEP
         * means it won't duplicate or restart an already-scheduled sync.
         */
        fun schedulePeriodic(context: Context) {
            val constraints = Constraints.Builder()
                .setRequiredNetworkType(NetworkType.CONNECTED)
                .build()

            val request = PeriodicWorkRequestBuilder<SyncWorker>(15, TimeUnit.MINUTES)
                .setConstraints(constraints)
                .build()

            WorkManager.getInstance(context).enqueueUniquePeriodicWork(
                PERIODIC_WORK_NAME,
                ExistingPeriodicWorkPolicy.KEEP,
                request
            )
        }

        /**
         * Call this for an immediate one-off sync, e.g. from a "Sync Now" button's
         * onClick, or right after login, or after saving a sale/customer/product.
         */
        fun syncNowOnce(context: Context) {
            val constraints = Constraints.Builder()
                .setRequiredNetworkType(NetworkType.CONNECTED)
                .build()

            val request = OneTimeWorkRequestBuilder<SyncWorker>()
                .setConstraints(constraints)
                .build()

            WorkManager.getInstance(context).enqueueUniqueWork(
                ONE_TIME_WORK_NAME,
                ExistingWorkPolicy.REPLACE,
                request
            )
        }

        /**
         * ADDED (Job-was-cancelled fix): lets a screen that just triggered
         * syncNowOnce() watch it finish and show the result — WITHOUT tying the
         * sync itself to that screen's lifecycle. Safe to call `.observe(this, ...)`
         * on the returned LiveData from any LifecycleOwner (e.g. an Activity): if
         * that screen is destroyed while the sync is still running, the OBSERVER is
         * torn down (as normal for LiveData), but the sync keeps running to
         * completion in WorkManager regardless — there's just nobody left to show a
         * toast to, which is the correct behavior (no crash, no wasted work).
         *
         * Typical use from an Activity:
         *   SyncWorker.syncNowOnce(this)
         *   SyncWorker.observeManualSync(this).observe(this) { infos ->
         *       val info = infos.firstOrNull() ?: return@observe
         *       if (info.state.isFinished) {
         *           val summary = info.outputData.getString(SyncWorker.KEY_SUMMARY) ?: "Sync complete"
         *           Toast.makeText(this, summary, Toast.LENGTH_LONG).show()
         *       }
         *   }
         */
        fun observeManualSync(context: Context): LiveData<List<WorkInfo>> =
            WorkManager.getInstance(context).getWorkInfosForUniqueWorkLiveData(ONE_TIME_WORK_NAME)

        // ---- ADDED: NetworkMonitor.kt calls SyncWorker.triggerNow(context) from its
        // onAvailable() callback (debounced — see NetworkMonitor.kt) the moment
        // connectivity comes back, so any sale/purchase/expense that queued up while
        // offline gets pushed right away instead of waiting for the next 15-minute
        // periodic run.
        //
        // FIX (RESOURCE_EXHAUSTED retry storm): this used to just call syncNowOnce(),
        // sharing its ExistingWorkPolicy.REPLACE — so a connectivity flap (dual-SIM
        // handoff, WiFi drop/reconnect) that fired while a push was already running
        // would CANCEL it mid-batch and restart from the same head-of-queue rows,
        // over and over, without any of the cancelled attempts ever reaching
        // markSynced()/markFailed(). That loop is what burned through the Firestore
        // daily quota in minutes and produced a wall of repeated "Push failed —
        // RESOURCE_EXHAUSTED" entries for the same 2-3 rows in Sync History.
        // KEEP means: if a sync is already enqueued or running, this call is a no-op
        // instead of a cancel-and-restart — the in-flight one is left to finish and
        // make real progress. The user's own "Sync Now" button (syncNowOnce, below)
        // keeps REPLACE deliberately: a manual tap should force a fresh attempt.
        fun triggerNow(context: Context) {
            val constraints = Constraints.Builder()
                .setRequiredNetworkType(NetworkType.CONNECTED)
                .build()

            val request = OneTimeWorkRequestBuilder<SyncWorker>()
                .setConstraints(constraints)
                .build()

            WorkManager.getInstance(context).enqueueUniqueWork(
                ONE_TIME_WORK_NAME,
                ExistingWorkPolicy.KEEP,
                request
            )
        }
    }
}

/*
===================================================================================
SETUP — do these two things to actually turn sync on. Neither is inside this file.
===================================================================================

1) Start periodic background sync once, e.g. in your Application class:

    class GroceryPosApp : Application() {
        override fun onCreate() {
            super.onCreate()
            SyncWorker.schedulePeriodic(this)
        }
    }

   (Make sure GroceryPosApp is registered as android:name in AndroidManifest.xml's
   <application> tag — if you don't have a custom Application class yet, add one.)

2) Add a "Sync Now" button anywhere useful (e.g. Settings screen, or the main
   dashboard) so the user can force an immediate sync instead of waiting up to
   15 minutes:

    syncNowButton.setOnClickListener {
        SyncWorker.syncNowOnce(this)
        Toast.makeText(this, "Syncing…", Toast.LENGTH_SHORT).show()
    }

===================================================================================
NOTE (kept for history, now stale — see SyncQueueHelper.kt): the section below
originally flagged that nothing enqueued rows into sync_queue. That gap is closed —
SyncQueueHelper.kt's enqueueX()/adjustCustomerBalance()/adjustSupplierBalance()/
increase|decreaseProductStock() wrappers are called from every insert/update call
site across the app (PartyTransactionActivity, RoomSaleRepository,
RoomPurchaseRepository, ExpenseActivity, etc. — see IMPROVEMENTS_APPLIED.md). Left
here only so the historical reasoning isn't lost; safe to delete this whole comment
block in a future cleanup pass.
===================================================================================
THE OTHER MISSING PIECE — nothing enqueues rows into sync_queue yet.
===================================================================================
SyncRepository only PUSHES what's already sitting in the sync_queue table. Right
now nothing writes to that table when you add/edit a customer, supplier, or
product — so the queue stays empty and push() has nothing to send.

Wherever you currently call e.g. customerDao().insert(customer), also enqueue a
sync_queue row right after, using the same Gson used elsewhere in the app:

    val entry = SyncQueueEntry(
        entityType = "customer",
        entityId = newId.toString(),      // or customer.serverId if you generate one
        operation = "upsert",
        payloadJson = Gson().toJson(mapOf(
            "serverId" to newId.toString(),
            "name" to customer.name,
            "phone" to customer.phone,
            "balance" to customer.balance,
            "creditLimit" to customer.creditLimit,
            "openingBalance" to customer.openingBalance,
            "updatedAt" to System.currentTimeMillis()
        ))
    )
    db.syncQueueDao().enqueue(entry)

Do the same after supplier and product inserts/updates (entityType = "supplier" /
"product"). This is the one piece that touches your existing Activity/ViewModel
code, so it wasn't safe for me to guess at without seeing those files — send them
if you want this wired in directly.
*/

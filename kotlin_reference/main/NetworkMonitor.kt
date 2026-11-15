package com.grocerypos.v11.sync

import android.content.Context
import android.net.ConnectivityManager
import android.net.Network
import android.net.NetworkCapabilities
import android.net.NetworkRequest
import java.util.concurrent.atomic.AtomicLong

// FIX (RESOURCE_EXHAUSTED retry storm): onAvailable() fires once PER NETWORK that
// becomes available, not once per "internet came back". On a dual-SIM phone (or
// any device that flaps between WiFi/mobile, or does a VoLTE/carrier handoff)
// this can fire several times within the same minute. Each call used to go
// straight to SyncWorker.triggerNow() -> syncNowOnce(), which enqueues with
// ExistingWorkPolicy.REPLACE — so a sync already mid-push got CANCELLED and
// restarted from the same head-of-queue items every time. None of those
// cancelled attempts ever reached markSynced()/markFailed(), so the exact same
// few rows got re-pushed over and over in a tight loop, burning through the
// Firestore daily write quota in minutes and producing a wall of back-to-back
// "RESOURCE_EXHAUSTED: Quota exceeded" entries in Sync History for the SAME
// 2-3 rows (e.g. a payment + a cash_transaction + a supplier update).
//
// Two independent guards fix this:
//  1. A short debounce here (below) so a burst of onAvailable() calls within
//     MIN_INTERVAL_MS of each other only triggers one sync attempt.
//  2. SyncWorker.triggerNow() now enqueues with ExistingWorkPolicy.KEEP instead
//     of REPLACE (see SyncWorker.kt) — so even if a burst gets past the
//     debounce, it can no longer cancel a sync that's already running; it just
//     no-ops until that one finishes. The user's own "Sync Now" button in
//     Settings still uses REPLACE deliberately, since forcing a fresh restart
//     is exactly what a manual tap should do.
object NetworkMonitor {
    private const val MIN_INTERVAL_MS = 20_000L // don't re-trigger more than once per 20s
    private val lastTriggeredAt = AtomicLong(0L)

    fun register(context: Context) {
        val cm = context.getSystemService(Context.CONNECTIVITY_SERVICE) as ConnectivityManager
        val request = NetworkRequest.Builder()
            .addCapability(NetworkCapabilities.NET_CAPABILITY_INTERNET)
            .build()
        val appContext = context.applicationContext
        cm.registerNetworkCallback(request, object : ConnectivityManager.NetworkCallback() {
            override fun onAvailable(network: Network) {
                val now = System.currentTimeMillis()
                val last = lastTriggeredAt.get()
                if (now - last < MIN_INTERVAL_MS) return
                if (!lastTriggeredAt.compareAndSet(last, now)) return // lost a race with another callback; that one will trigger instead
                SyncWorker.triggerNow(appContext)
            }
        })
    }
}

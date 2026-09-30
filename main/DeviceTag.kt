package com.grocerypos.v11

import android.content.Context
import java.util.UUID

/**
 * Short, random, per-installation tag used to keep Firestore document IDs unique
 * across multiple devices/registers that share the same branch.
 *
 * FIX (multi-device sync bug): billNo (PurchaseActivity's genBillNo) and the sync
 * entity IDs for customers/suppliers/expenses/cash transactions were all built from
 * a LOCAL autoincrement id (or a local sequence number) with no device component.
 * Two different devices at the same branch would independently generate the exact
 * same id/billNo the first time each of them created a record (e.g. both devices'
 * very first customer gets local id=1 -> both push to Firestore doc "customer:1"),
 * so one device's record would silently overwrite the other's in Firestore instead
 * of both existing side by side. Mixing this tag into those IDs makes them unique
 * per device, so two devices can never collide.
 *
 * Generated once on first app run and persisted in SharedPreferences (not Room),
 * so it is available synchronously wherever an ID needs to be built, without
 * needing a suspend function or a database call.
 */
object DeviceTag {
    private const val PREFS = "device_prefs"
    private const val KEY = "device_tag"

    // Fallback only used if init() somehow hasn't run yet when current is first read
    // (shouldn't happen — PosApplication.onCreate() calls init() before anything else
    // that could need it).
    @Volatile private var cached: String = "0000"

    /** Call once, e.g. first line of PosApplication.onCreate(). Safe to call again. */
    fun init(context: Context) {
        val prefs = context.applicationContext.getSharedPreferences(PREFS, Context.MODE_PRIVATE)
        var tag = prefs.getString(KEY, null)
        if (tag == null) {
            tag = UUID.randomUUID().toString().replace("-", "").take(4).uppercase()
            prefs.edit().putString(KEY, tag).apply()
        }
        cached = tag
    }

    val current: String get() = cached
}

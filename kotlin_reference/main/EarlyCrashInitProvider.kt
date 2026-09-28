package com.grocerypos.v11

import android.content.ContentProvider
import android.content.ContentValues
import android.database.Cursor
import android.net.Uri

/**
 * FIX (white-screen-no-log, take 2): PosApplication.onCreate() is NOT actually the earliest
 * point app code runs. Android's real startup order is:
 *   1. Application.attachBaseContext()
 *   2. every <provider> declared in the manifest gets its onCreate() called, INCLUDING
 *      libraries' own auto-merged providers — e.g. Firebase adds a hidden
 *      "FirebaseInitProvider" to the manifest automatically because this app uses
 *      FirebaseAuth (OTP login).
 *   3. Application.onCreate()  <-- this is where CrashHandler.install() was being called
 *
 * If something throws during step 2 (e.g. Firebase failing to initialize because of a
 * config/network/keystore problem), the app crashes before step 3 ever runs, so
 * CrashHandler was never installed yet — that's why the crash dialog + saved log stayed
 * empty even after the previous fix (PosApplication.onCreate installs it "first", but
 * still too late for a provider-level crash).
 *
 * A ContentProvider's onCreate() runs earlier than Application.onCreate(), so installing
 * the handler here — with a high initOrder so it's created before other providers — closes
 * that gap. This provider does nothing else; it's not a real data provider.
 */
class EarlyCrashInitProvider : ContentProvider() {

    override fun onCreate(): Boolean {
        val ctx = context
        if (ctx != null) {
            com.grocerypos.v11.util.CrashHandler.install(ctx)
        }
        return true
    }

    // ---- Not a real data provider — every other method is a no-op. ----
    override fun query(uri: Uri, projection: Array<String>?, selection: String?, selectionArgs: Array<String>?, sortOrder: String?): Cursor? = null
    override fun getType(uri: Uri): String? = null
    override fun insert(uri: Uri, values: ContentValues?): Uri? = null
    override fun delete(uri: Uri, selection: String?, selectionArgs: Array<String>?): Int = 0
    override fun update(uri: Uri, values: ContentValues?, selection: String?, selectionArgs: Array<String>?): Int = 0
}

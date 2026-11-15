package com.grocerypos.v11.util

import android.content.Context
import android.content.Intent
import android.util.Log
import java.io.File
import java.io.PrintWriter
import java.io.StringWriter
import java.text.SimpleDateFormat
import java.util.Date
import java.util.Locale

/**
 * Phone-only crash debugging (no Logcat / computer needed).
 *
 * How it works:
 * 1. CrashHandler.install(this) is called once, early in onCreate. It registers a global
 *    "uncaught exception" handler for the whole app.
 * 2. If ANYTHING crashes the app (any screen, any thread), the full stack trace + timestamp
 *    is written to a small text file in the app's private storage before the app closes.
 * 3. Next time an activity that calls CrashHandler.getLastCrash() opens, it finds that file
 *    and can show it in a dialog with Copy / Share buttons.
 *
 * For full coverage, call install() + check for a saved crash from the FIRST screen the app
 * opens (e.g. MainActivity / SplashActivity), not just PurchaseActivity — that way a crash on
 * any screen gets caught and shown next time you simply reopen the app.
 */
object CrashHandler {
    private const val TAG = "CrashHandler"
    private const val FILE_NAME = "last_crash.txt"
    private var installed = false

    fun install(context: Context) {
        if (installed) return
        installed = true
        val appContext = context.applicationContext
        val defaultHandler = Thread.getDefaultUncaughtExceptionHandler()
        Thread.setDefaultUncaughtExceptionHandler { thread, throwable ->
            try {
                val sw = StringWriter()
                throwable.printStackTrace(PrintWriter(sw))
                val stamp = SimpleDateFormat("dd/MM/yyyy hh:mm:ss a", Locale.getDefault()).format(Date())
                val text = "CRASH at $stamp\nThread: ${thread.name}\n\n$sw"
                File(appContext.filesDir, FILE_NAME).writeText(text)
                Log.e(TAG, text)
            } catch (e: Exception) {
                Log.e(TAG, "Failed to write crash log", e)
            }
            // Let the system still handle the crash normally (close the app) after we've saved it.
            if (defaultHandler != null) {
                defaultHandler.uncaughtException(thread, throwable)
            } else {
                android.os.Process.killProcess(android.os.Process.myPid())
                System.exit(10)
            }
        }
    }

    /** Returns the saved crash text (and deletes nothing yet), or null if there wasn't a crash. */
    fun getLastCrash(context: Context): String? {
        val file = File(context.applicationContext.filesDir, FILE_NAME)
        return if (file.exists()) file.readText() else null
    }

    fun clearLastCrash(context: Context) {
        File(context.applicationContext.filesDir, FILE_NAME).delete()
    }

    fun shareIntent(text: String): Intent = Intent(Intent.ACTION_SEND).apply {
        type = "text/plain"
        putExtra(Intent.EXTRA_SUBJECT, "IBTISAAM POS Crash Log")
        putExtra(Intent.EXTRA_TEXT, text)
    }
}

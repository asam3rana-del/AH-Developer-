package com.grocerypos.v11

import android.content.Context
import com.google.firebase.FirebaseApp
import com.google.firebase.FirebaseOptions

/**
 * Lets a shop owner point THIS install at their OWN Firebase project, entered as
 * plain text in Settings, instead of always using whatever project was baked into
 * this build's google-services.json at compile time.
 *
 * WHY THIS EXISTS: this codebase is meant to be sold to multiple, unrelated shop
 * owners. Without this, every copy of the app built from this repo would share the
 * SAME Firebase project (whatever google-services.json happens to be checked in) —
 * meaning every customer's sales/customers/products would land in one shared
 * database, readable by anyone who knows how to query it. That is a real data leak
 * between customers who have nothing to do with each other.
 *
 * With this, a customer who never opens the "Cloud Sync Setup" screen gets NO cloud
 * sync at all (Settings > Sync Now simply won't have anything to sync to) — the app
 * behaves as a fully offline, single-device POS until they deliberately enter their
 * own project's details. Two devices only ever sync with each other if BOTH have the
 * exact same config entered — login username/password has nothing to do with this;
 * it only controls who can operate a given device, never which cloud project that
 * device talks to.
 *
 * FALLBACK FOR THIS SPECIFIC BUILD: if nothing has been entered here yet, effective()
 * falls back to whatever FirebaseApp got auto-initialized from THIS build's own
 * google-services.json (if one is baked in) — so Ibtisaam's own devices keep syncing
 * exactly as before, with nothing extra to configure. A future build meant to be
 * resold to other shop owners should ship WITHOUT a real google-services.json (a
 * non-functional placeholder is fine) so that fallback has nothing usable to fall
 * back to, and every customer is forced to enter their own project before sync does
 * anything.
 */
data class CloudConfig(
    val projectId: String,
    val apiKey: String,
    val appId: String,
    val storageBucket: String
)

object CloudConfigStore {
    private const val PREFS = "cloud_config_prefs"
    private const val KEY_PROJECT_ID = "project_id"
    private const val KEY_API_KEY = "api_key"
    private const val KEY_APP_ID = "app_id"
    private const val KEY_STORAGE_BUCKET = "storage_bucket"

    private const val CUSTOM_APP_NAME = "custom_cloud"

    private fun prefs(context: Context) =
        context.applicationContext.getSharedPreferences(PREFS, Context.MODE_PRIVATE)

    /** The config the admin explicitly entered on THIS device, if any. */
    fun get(context: Context): CloudConfig? {
        val p = prefs(context)
        val projectId = p.getString(KEY_PROJECT_ID, null) ?: return null
        val apiKey = p.getString(KEY_API_KEY, null) ?: return null
        val appId = p.getString(KEY_APP_ID, null) ?: return null
        val storageBucket = p.getString(KEY_STORAGE_BUCKET, null) ?: ""
        return CloudConfig(projectId, apiKey, appId, storageBucket)
    }

    fun isConfigured(context: Context): Boolean = get(context) != null

    fun save(context: Context, config: CloudConfig) {
        prefs(context).edit()
            .putString(KEY_PROJECT_ID, config.projectId.trim())
            .putString(KEY_API_KEY, config.apiKey.trim())
            .putString(KEY_APP_ID, config.appId.trim())
            .putString(KEY_STORAGE_BUCKET, config.storageBucket.trim())
            .apply()
    }

    /** Removes this device's custom config (falls back to this build's default, if any). */
    fun clear(context: Context) {
        prefs(context).edit().clear().apply()
    }

    /**
     * The FirebaseOptions sync should actually use right now: the admin's own entered
     * config if present, otherwise this build's compiled-in default (if any). Returns
     * null if neither is available — callers must treat that as "sync not set up yet"
     * and not attempt to talk to Firestore at all.
     */
    fun effectiveOptions(context: Context): FirebaseOptions? {
        get(context)?.let {
            return FirebaseOptions.Builder()
                .setProjectId(it.projectId)
                .setApiKey(it.apiKey)
                .setApplicationId(it.appId)
                .setStorageBucket(it.storageBucket)
                .build()
        }
        return try {
            FirebaseApp.getInstance().options
        } catch (e: Exception) {
            null
        }
    }

    /**
     * The actual FirebaseApp instance to use for sync. When a custom config is set,
     * this is a separately-named FirebaseApp built at runtime from it (never touches
     * or conflicts with the build's default app). Returns null if nothing is
     * configured at all — callers must skip sync in that case.
     */
    fun firebaseApp(context: Context): FirebaseApp? {
        val custom = get(context)
        if (custom == null) {
            return try { FirebaseApp.getInstance() } catch (e: Exception) { null }
        }
        return try {
            FirebaseApp.getInstance(CUSTOM_APP_NAME)
        } catch (e: IllegalStateException) {
            val options = FirebaseOptions.Builder()
                .setProjectId(custom.projectId)
                .setApiKey(custom.apiKey)
                .setApplicationId(custom.appId)
                .setStorageBucket(custom.storageBucket)
                .build()
            FirebaseApp.initializeApp(context.applicationContext, options, CUSTOM_APP_NAME)
        }
    }
}

package com.grocerypos.v11.util

import android.content.ContentValues
import android.content.Context
import android.content.Intent
import android.net.Uri
import android.os.Build
import android.os.Environment
import android.provider.MediaStore
import androidx.core.content.FileProvider
import androidx.sqlite.db.SimpleSQLiteQuery
import com.grocerypos.v11.BackupPasswordStore
import com.grocerypos.v11.DeviceTag
import com.grocerypos.v11.PosDatabase
import java.io.File
import java.io.FileInputStream
import java.text.SimpleDateFormat
import java.util.Date
import java.util.Locale
import javax.crypto.Cipher
import javax.crypto.CipherInputStream
import javax.crypto.SecretKeyFactory
import javax.crypto.spec.IvParameterSpec
import javax.crypto.spec.PBEKeySpec
import javax.crypto.spec.SecretKeySpec

/**
 * Backs up / restores the Room database file.
 *
 * - Main copy (used for Restore): app-specific storage at
 *   Android/data/com.grocerypos.v11/files/IBTISAAM POS Backups (no permission needed).
 * - Extra copy (for the user to see/share easily): public
 *   Downloads/IBTISAAM POS Backups folder (its own named subfolder, not mixed loose
 *   into Downloads), saved via MediaStore so no storage permission is needed on any
 *   Android version.
 * - shareBackup(): opens the Android Share menu so the user can send a
 *   backup file to Google Drive, WhatsApp, Gmail, etc. with one tap.
 *
 * UPDATED: folder renamed from generic "Backups" to "IBTISAAM POS Backups" (the shop's
 * software name) so it's identifiable when browsing storage — especially on the public
 * Downloads side, where it used to sit as loose files mixed in with every other download.
 * Filenames now also include the device tag (see DeviceTag.kt) so, on a 2-device setup
 * (Admin + Cashier), it's obvious which device a given backup file came from.
 */
object BackupHelper {

    var lastError: String? = null

    private const val DB_NAME = "grocery_pos_v11.db"
    private const val FOLDER_NAME = "IBTISAAM POS Backups"
    private const val THROTTLE_PREFS = "backup_throttle_prefs"
    private const val KEY_LAST_BACKUP_AT = "last_backup_at_millis"

    // ---- Encryption ----
    // FIX (audit #2 — "backup encryption authenticated nahi hai"): new backups are
    // now written with BackupCrypto (AES-256-GCM — an authenticated cipher with a
    // built-in integrity tag), not the old AES-CBC below. CBC has no auth tag, so a
    // tampered/corrupted CBC file would silently "decrypt" into garbage instead of
    // failing loudly; GCM's decryptFile throws instead. The old MAGIC/deriveKey/
    // decryptFileLegacyCbc trio is kept ONLY so backups already made before this fix
    // (old .ibbackup files starting with "IBAKV001") can still be restored — no
    // shop's existing backups become unreadable. Every backup made from now on uses
    // BackupCrypto's "IBB1" GCM format instead (see backupNow() below).
    private val MAGIC = "IBAKV001".toByteArray(Charsets.US_ASCII)
    private const val SALT_LEN = 16
    private const val IV_LEN = 16
    private const val PBKDF2_ITERATIONS = 100_000
    private const val KEY_LEN_BITS = 256

    // First 16 bytes of every valid SQLite database file (the format's own magic
    // header, null terminator included) — used by restoreSafely() to confirm a
    // decrypted/copied temp file is really a database before it touches the live one.
    private val SQLITE_HEADER = "SQLite format 3\u0000".toByteArray(Charsets.US_ASCII)

    private fun deriveKey(password: String, salt: ByteArray): SecretKeySpec {
        val spec = PBEKeySpec(password.toCharArray(), salt, PBKDF2_ITERATIONS, KEY_LEN_BITS)
        val keyBytes = SecretKeyFactory.getInstance("PBKDF2WithHmacSHA256").generateSecret(spec).encoded
        return SecretKeySpec(keyBytes, "AES")
    }

    /** True if [file] is encrypted (either the new GCM format or an old CBC one),
     * false for a plain .db backup (or anything else) — checked by magic header
     * only, so this never needs the password. */
    fun needsPassword(file: File): Boolean {
        return isLegacyEncryptedBackup(file) || BackupCrypto.isEncryptedBackup(file)
    }

    private fun isLegacyEncryptedBackup(file: File): Boolean {
        return try {
            file.inputStream().use { input ->
                val header = ByteArray(MAGIC.size)
                input.read(header) == MAGIC.size && header.contentEquals(MAGIC)
            }
        } catch (e: Exception) {
            false
        }
    }

    /** Decrypts an old, pre-GCM-fix (.ibbackup, "IBAKV001") backup. Assumes
     * [source] has already been confirmed via [isLegacyEncryptedBackup]. */
    private fun decryptFileLegacyCbc(source: File, dest: File, password: String) {
        source.inputStream().use { rawIn ->
            val header = ByteArray(MAGIC.size)
            rawIn.read(header)
            val salt = ByteArray(SALT_LEN)
            rawIn.read(salt)
            val iv = ByteArray(IV_LEN)
            rawIn.read(iv)
            val cipher = Cipher.getInstance("AES/CBC/PKCS5Padding").apply {
                init(Cipher.DECRYPT_MODE, deriveKey(password, salt), IvParameterSpec(iv))
            }
            CipherInputStream(rawIn, cipher).use { cIn ->
                dest.outputStream().use { cIn.copyTo(it) }
            }
        }
    }

    /** Checks the file starts with SQLite's own magic header — i.e. it's actually
     * a database, not a half-decrypted mess from a wrong password or a truncated/
     * corrupted backup. Used by restoreSafely() before anything touches the live DB. */
    private fun isValidSqliteDb(file: File): Boolean {
        return try {
            if (file.length() < SQLITE_HEADER.size) return false
            file.inputStream().use { input ->
                val header = ByteArray(SQLITE_HEADER.size)
                input.read(header) == SQLITE_HEADER.size && header.contentEquals(SQLITE_HEADER)
            }
        } catch (e: Exception) {
            false
        }
    }

    /**
     * Decrypts/copies [backupFile] into a fresh temp file next to the live database,
     * validates it's really a SQLite database, and ONLY THEN atomically replaces the
     * live database with it. Assumes [PosDatabase.closeInstance] has already been
     * called by the caller. On any failure — wrong password, corrupted/tampered
     * backup, not actually a database — the live database is left completely
     * untouched and this returns false with [lastError] set.
     *
     * FIX (audit #3 — "wrong backup password restore dangerous hai"): the old
     * restore()/restoreFromUri() decrypted or copied straight into the live
     * dbFile's own FileOutputStream. In Kotlin/Java, opening a FileOutputStream on
     * an existing file truncates it to 0 bytes immediately — before a single byte
     * of the backup had been verified. So a wrong password or a corrupted backup
     * destroyed the live database on its way to failing, instead of leaving it
     * alone. Now every restore path goes through this one function: temp file ->
     * decrypt/copy -> validate SQLite header -> atomic replace.
     */
    private fun restoreSafely(context: Context, backupFile: File, pass: String?): Boolean {
        val dbFile = context.getDatabasePath(DB_NAME)
        val tempFile = File(dbFile.parentFile, "$DB_NAME.restore_tmp")
        return try {
            when {
                BackupCrypto.isEncryptedBackup(backupFile) -> {
                    if (pass.isNullOrEmpty()) {
                        lastError = "Password chahiye"
                        return false
                    }
                    BackupCrypto.decryptFile(backupFile, tempFile, pass)
                }
                isLegacyEncryptedBackup(backupFile) -> {
                    if (pass.isNullOrEmpty()) {
                        lastError = "Password chahiye"
                        return false
                    }
                    decryptFileLegacyCbc(backupFile, tempFile, pass)
                }
                else -> backupFile.copyTo(tempFile, overwrite = true)
            }

            if (!isValidSqliteDb(tempFile)) {
                lastError = "Backup file corrupt hai ya password ghalat hai"
                tempFile.delete()
                return false
            }

            // Same folder as dbFile => same filesystem => this rename is atomic,
            // not a byte-by-byte overwrite of the live file.
            if (!tempFile.renameTo(dbFile)) {
                // Rare fallback (e.g. cross-filesystem edge case): copy then clean up.
                tempFile.copyTo(dbFile, overwrite = true)
                tempFile.delete()
            }

            File(dbFile.path + "-wal").delete()
            File(dbFile.path + "-shm").delete()
            true
        } catch (e: Exception) {
            e.printStackTrace()
            lastError = e.message ?: e.toString()
            tempFile.delete()
            false
        }
    }

    fun backupFolder(context: Context): File {
        val dir = File(context.getExternalFilesDir(null), FOLDER_NAME)
        if (!dir.exists()) dir.mkdirs()
        return dir
    }

    /**
     * Copies the current database to the app's Backups folder AND to the
     * public Downloads folder, both with a timestamped, device-tagged name.
     * Returns the app-folder file (used internally for Restore/Share), or null on failure.
     *
     * FIX: Room runs in WAL (write-ahead logging) mode by default. Recent writes
     * (e.g. a purchase just added) live in the "<db>-wal" side file and are only
     * merged into the main .db file when SQLite performs a checkpoint. Copying
     * the raw .db file WITHOUT forcing a checkpoint first meant backups could
     * silently miss the most recent entries — and restoring such a backup would
     * wipe out anything added after the last checkpoint. We now force a full
     * checkpoint (via `PRAGMA wal_checkpoint(FULL)`) right before copying, so
     * the .db file always reflects every committed write at backup time.
     */
    fun backupNow(context: Context): File? {
        return try {
            val dbFile = context.getDatabasePath(DB_NAME)
            if (!dbFile.exists()) return null

            // Force WAL contents to be flushed into the main .db file so the
            // copy below is guaranteed to include every committed write,
            // including anything added moments ago.
            checkpointWal(context)

            val stamp = SimpleDateFormat("yyyy-MM-dd_HH-mm", Locale.getDefault()).format(Date())
            // Device tag (e.g. "A1B2") identifies which device this backup came from —
            // useful once there are 2 devices (Admin + Cashier) producing backups.
            // Extension is now .ibbackup since the file is encrypted, not a raw .db.
            val fileName = "IBTISAAM_${DeviceTag.current}_backup_$stamp.ibbackup"
            val password = BackupPasswordStore.getOrCreate(context)

            // 1) App-specific copy (used by Restore and Share) — encrypted with
            // AES-256-GCM (authenticated) via BackupCrypto, not the old CBC scheme.
            val destFile = File(backupFolder(context), fileName)
            BackupCrypto.encryptFile(dbFile, destFile, password)

            // 2) Public Downloads copy (for the user to see/share manually) — also
            // encrypted (copying the raw dbFile here would leak an unencrypted
            // database into a world-readable folder, defeating the password).
            copyToDownloads(context, destFile, fileName)

            // ADDED: records the moment ANY backup completes (manual button, checkpoint,
            // or app-close trigger all funnel through here) so backupIfDue() below has a
            // single, shared "when did we last actually back up" clock to throttle against.
            context.getSharedPreferences(THROTTLE_PREFS, Context.MODE_PRIVATE)
                .edit().putLong(KEY_LAST_BACKUP_AT, System.currentTimeMillis()).apply()

            destFile
        } catch (e: Exception) {
            e.printStackTrace()
            lastError = e.message ?: e.toString()
            null
        }
    }

    // ADDED: was referenced by BackupScheduler's app-close trigger (see its class doc)
    // but never actually existed in BackupHelper — every close call therefore failed
    // to compile, not just failed to throttle. Skips the backup entirely (returns null,
    // no WAL checkpoint, no file written) if the last backup of ANY kind — a noon/night
    // checkpoint, a previous close-trigger, or a manual tap of the backup button —
    // finished less than [minGapMinutes] minutes ago; otherwise delegates to backupNow()
    // exactly as before, which itself now stamps the throttle clock on completion.
    fun backupIfDue(context: Context, minGapMinutes: Int): File? {
        val prefs = context.getSharedPreferences(THROTTLE_PREFS, Context.MODE_PRIVATE)
        val lastBackupAt = prefs.getLong(KEY_LAST_BACKUP_AT, 0L)
        val minGapMillis = minGapMinutes * 60_000L
        if (System.currentTimeMillis() - lastBackupAt < minGapMillis) return null
        return backupNow(context)
    }

    /**
     * Forces SQLite to write everything currently sitting in the WAL file into
     * the main database file. Safe to call on the live, open database — it
     * does not close any connections.
     */
    private fun checkpointWal(context: Context) {
        try {
            val db = PosDatabase.get(context)
            db.query(SimpleSQLiteQuery("PRAGMA wal_checkpoint(FULL)")).use { it.moveToFirst() }
        } catch (e: Exception) {
            e.printStackTrace()
        }
    }

    /** Saves a copy of the given file into a named subfolder inside public Downloads. */
    private fun copyToDownloads(context: Context, sourceFile: File, fileName: String) {
        try {
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
                val resolver = context.contentResolver
                val values = ContentValues().apply {
                    put(MediaStore.MediaColumns.DISPLAY_NAME, fileName)
                    put(MediaStore.MediaColumns.MIME_TYPE, "application/octet-stream")
                    put(MediaStore.MediaColumns.RELATIVE_PATH, Environment.DIRECTORY_DOWNLOADS + "/" + FOLDER_NAME)
                }
                val uri = resolver.insert(MediaStore.Downloads.EXTERNAL_CONTENT_URI, values)
                if (uri != null) {
                    resolver.openOutputStream(uri)?.use { out ->
                        FileInputStream(sourceFile).use { input -> input.copyTo(out) }
                    }
                }
            } else {
                @Suppress("DEPRECATION")
                val downloadsDir = File(
                    Environment.getExternalStoragePublicDirectory(Environment.DIRECTORY_DOWNLOADS),
                    FOLDER_NAME
                )
                if (!downloadsDir.exists()) downloadsDir.mkdirs()
                val destFile = File(downloadsDir, fileName)
                sourceFile.copyTo(destFile, overwrite = true)
            }
        } catch (e: Exception) {
            e.printStackTrace()
        }
    }

    /**
     * Opens the Android Share menu (Google Drive, WhatsApp, Gmail, etc.)
     * for the given backup file. Call this right after backupNow(), or
     * from the Restore list, passing the file the user wants to send.
     */
    fun shareBackup(context: Context, file: File) {
        // FIX (Phase 5 - Stability): this was the one function in BackupHelper with no
        // try/catch — FileProvider.getUriForFile() can throw IllegalArgumentException
        // (e.g. file_paths.xml doesn't cover the file's folder) and startActivity() can
        // throw ActivityNotFoundException on a device with no share-capable app. Either
        // one previously crashed the app instead of just failing the share.
        try {
            val uri = FileProvider.getUriForFile(
                context,
                "${context.packageName}.fileprovider",
                file
            )
            val intent = Intent(Intent.ACTION_SEND).apply {
                type = "application/octet-stream"
                putExtra(Intent.EXTRA_STREAM, uri)
                addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
            }
            context.startActivity(Intent.createChooser(intent, "Backup kis app se bhejein?"))
        } catch (e: Exception) {
            e.printStackTrace()
            android.widget.Toast.makeText(context, "Backup share nahi ho saka.", android.widget.Toast.LENGTH_SHORT).show()
        }
    }

    /** Lists available backup files (from the app folder), most recent first.
     * Includes old plain .db backups made before encryption was added, alongside
     * new encrypted .ibbackup ones. */
    fun listBackups(context: Context): List<File> {
        return backupFolder(context)
            .listFiles { f -> f.extension == "ibbackup" || f.extension == "db" }
            ?.sortedByDescending { it.lastModified() }
            ?: emptyList()
    }

    /**
     * Restores the given backup file over the live database.
     * Closes the current Room instance first. The app should be restarted
     * after a successful restore so Room re-opens the restored file cleanly.
     *
     * [pass] is required when [needsPassword] is true for this file (new encrypted
     * .ibbackup backups); it's ignored for old plain .db backups.
     */
    fun restore(context: Context, backupFile: File, pass: String? = null): Boolean {
        PosDatabase.closeInstance()
        return restoreSafely(context, backupFile, pass)
    }

    /**
     * Restores from a content Uri returned by the system document picker
     * (ACTION_OPEN_DOCUMENT via [android.provider.DocumentsContract]). Unlike [restore],
     * this doesn't require the backup file to already sit inside the app's own
     * Backups folder — the picker can reach Downloads, a cloud-storage app, etc.
     * even on Android 11+, where a plain file manager is blocked from browsing
     * into Android/data/<package>/files by default. This is the reliable path for
     * "I reinstalled the app and need to bring back an old backup".
     *
     * We can't check [needsPassword] on a content Uri directly, so the picked file
     * is first copied to a cache temp file; [pass] is then only actually used if
     * that temp file turns out to be an encrypted .ibbackup (ignored for old plain
     * .db files).
     */
    fun restoreFromUri(context: Context, uri: Uri, pass: String? = null): Boolean {
        // Just the picked-content -> local-file copy step; restoreSafely() below
        // does its own separate temp file for the decrypt/validate/replace part.
        val pickedFile = File(context.cacheDir, "restore_picked_$DB_NAME")
        return try {
            val input = context.contentResolver.openInputStream(uri) ?: run {
                lastError = "Backup file khul nahi saki"
                return false
            }
            input.use { streamIn ->
                pickedFile.outputStream().use { streamOut -> streamIn.copyTo(streamOut) }
            }
            PosDatabase.closeInstance()
            restoreSafely(context, pickedFile, pass)
        } catch (e: Exception) {
            e.printStackTrace()
            lastError = e.message ?: e.toString()
            false
        } finally {
            pickedFile.delete()
        }
    }
}

package com.grocerypos.v11

import android.content.Context
import android.util.Base64
import java.security.KeyStore
import java.security.SecureRandom
import javax.crypto.Cipher
import javax.crypto.KeyGenerator
import javax.crypto.SecretKey
import javax.crypto.spec.GCMParameterSpec

/**
 * Stores the local backup password encrypted with an Android Keystore AES-256 key.
 * The password itself is never stored as plain SharedPreferences text.
 *
 * IMPORTANT: the Keystore key is device-local. This is intentional: the backup
 * password must still be written/saved by the owner if a backup is to be restored
 * on another phone. Losing/reinstalling the app does not make the old backup
 * undecryptable; the restore screen asks the owner for the password.
 */
object BackupPasswordStore {
    private const val PREFS = "backup_prefs"
    private const val KEY_PASSWORD = "backup_password_enc"
    private const val KEYSTORE = "AndroidKeyStore"
    private const val KEY_ALIAS = "ibtisaam_backup_password_key"
    private const val TRANSFORMATION = "AES/GCM/NoPadding"
    private const val IV_SIZE = 12

    private val CHARS = ('A'..'Z') + ('a'..'z') + ('0'..'9')

    fun getOrCreate(context: Context): String {
        val prefs = context.getSharedPreferences(PREFS, Context.MODE_PRIVATE)
        val encoded = prefs.getString(KEY_PASSWORD, null)
        if (!encoded.isNullOrBlank()) {
            runCatching { decrypt(encoded) }.getOrNull()?.let { return it }
        }
        val pass = generateRandomPassword()
        prefs.edit().putString(KEY_PASSWORD, encrypt(pass)).apply()
        return pass
    }

    fun setPassword(context: Context, newPassword: String) {
        require(newPassword.length >= 8) { "Backup password must be at least 8 characters." }
        context.getSharedPreferences(PREFS, Context.MODE_PRIVATE)
            .edit().putString(KEY_PASSWORD, encrypt(newPassword)).apply()
    }

    private fun key(): SecretKey {
        val ks = KeyStore.getInstance(KEYSTORE).apply { load(null) }
        val existing = ks.getKey(KEY_ALIAS, null) as? SecretKey
        if (existing != null) return existing
        val kg = KeyGenerator.getInstance("AES", KEYSTORE)
        kg.init(android.security.keystore.KeyGenParameterSpec.Builder(
            KEY_ALIAS,
            android.security.keystore.KeyProperties.PURPOSE_ENCRYPT or
                android.security.keystore.KeyProperties.PURPOSE_DECRYPT
        ).setBlockModes(android.security.keystore.KeyProperties.BLOCK_MODE_GCM)
            .setEncryptionPaddings(android.security.keystore.KeyProperties.ENCRYPTION_PADDING_NONE)
            .setKeySize(256)
            .build())
        return kg.generateKey()
    }

    private fun encrypt(value: String): String {
        // AndroidKeyStore AES/GCM keys are created with randomized encryption required
        // (the default), so the Keystore refuses a caller-supplied IV on ENCRYPT_MODE
        // ("Caller-provided IV not permitted"). Let the cipher generate its own IV
        // instead, then read it back via cipher.iv for storage alongside the ciphertext.
        val cipher = Cipher.getInstance(TRANSFORMATION)
        cipher.init(Cipher.ENCRYPT_MODE, key())
        val iv = cipher.iv
        val cipherText = cipher.doFinal(value.toByteArray(Charsets.UTF_8))
        return Base64.encodeToString(iv + cipherText, Base64.NO_WRAP)
    }

    private fun decrypt(encoded: String): String {
        val all = Base64.decode(encoded, Base64.NO_WRAP)
        require(all.size > IV_SIZE)
        val iv = all.copyOfRange(0, IV_SIZE)
        val cipherText = all.copyOfRange(IV_SIZE, all.size)
        val cipher = Cipher.getInstance(TRANSFORMATION)
        cipher.init(Cipher.DECRYPT_MODE, key(), GCMParameterSpec(128, iv))
        return String(cipher.doFinal(cipherText), Charsets.UTF_8)
    }

    private fun generateRandomPassword(length: Int = 16): String {
        val random = SecureRandom()
        return (1..length).map { CHARS[random.nextInt(CHARS.size)] }.joinToString("")
    }
}

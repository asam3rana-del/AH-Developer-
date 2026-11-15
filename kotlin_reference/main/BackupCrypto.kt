package com.grocerypos.v11.util

import java.io.File
import java.io.FileInputStream
import java.io.FileOutputStream
import java.security.SecureRandom
import javax.crypto.Cipher
import javax.crypto.SecretKeyFactory
import javax.crypto.spec.GCMParameterSpec
import javax.crypto.spec.PBEKeySpec
import javax.crypto.spec.SecretKeySpec

/**
 * AES-256-GCM file encryption for backups, keyed by a password rather than the
 * Android Keystore.
 *
 * IMPORTANT — why password-based and not Keystore-based: a Keystore key is tied to
 * this one device/app-install and can never be exported, so a Keystore-encrypted
 * backup could only ever be restored on the exact same phone. That defeats the whole
 * point of copying a backup out to WhatsApp/Drive/Downloads — the scenario those
 * copies exist for is the phone itself being lost, damaged, or replaced. A
 * password-based key can be typed in on a different device (or after reinstalling
 * the app) to restore there, as long as the shop owner has the password written down
 * somewhere safe — which is the normal, expected way backup software works.
 *
 * File format (all binary, written in this order):
 *   [4 bytes  ] magic "IBB1"
 *   [16 bytes ] PBKDF2 salt
 *   [12 bytes ] GCM IV (nonce)
 *   [remaining] AES-GCM ciphertext (includes the 16-byte auth tag at the end)
 *
 * The salt is random per backup, so the same password never derives the same raw
 * AES key twice — but the derived key only ever exists in memory during
 * encrypt/decrypt, never written to disk.
 */
object BackupCrypto {

    private val MAGIC = byteArrayOf('I'.code.toByte(), 'B'.code.toByte(), 'B'.code.toByte(), '1'.code.toByte())
    private const val SALT_LEN = 16
    private const val IV_LEN = 12
    private const val GCM_TAG_BITS = 128
    private const val PBKDF2_ITERATIONS = 120_000
    private const val KEY_LEN_BITS = 256

    private fun deriveKey(password: String, salt: ByteArray): SecretKeySpec {
        val factory = SecretKeyFactory.getInstance("PBKDF2WithHmacSHA256")
        val spec = PBEKeySpec(password.toCharArray(), salt, PBKDF2_ITERATIONS, KEY_LEN_BITS)
        val raw = factory.generateSecret(spec).encoded
        return SecretKeySpec(raw, "AES")
    }

    /** Encrypts [input] with [password], writing the result to [output]. */
    fun encryptFile(input: File, output: File, password: String) {
        val random = SecureRandom()
        val salt = ByteArray(SALT_LEN).also { random.nextBytes(it) }
        val iv = ByteArray(IV_LEN).also { random.nextBytes(it) }
        val key = deriveKey(password, salt)

        val cipher = Cipher.getInstance("AES/GCM/NoPadding")
        cipher.init(Cipher.ENCRYPT_MODE, key, GCMParameterSpec(GCM_TAG_BITS, iv))

        FileOutputStream(output).use { out ->
            out.write(MAGIC)
            out.write(salt)
            out.write(iv)
            FileInputStream(input).use { streamIn ->
                val buffer = ByteArray(64 * 1024)
                var read: Int
                while (streamIn.read(buffer).also { read = it } != -1) {
                    val encrypted = cipher.update(buffer, 0, read)
                    if (encrypted != null) out.write(encrypted)
                }
                val finalBytes = cipher.doFinal()
                if (finalBytes != null) out.write(finalBytes)
            }
        }
    }

    /**
     * Decrypts [input] (produced by [encryptFile]) with [password], writing the
     * plain database bytes to [output]. Throws if the password is wrong or the
     * file isn't a valid encrypted backup (auth tag check fails).
     */
    fun decryptFile(input: File, output: File, password: String) {
        FileInputStream(input).use { streamIn ->
            val magic = ByteArray(MAGIC.size)
            require(streamIn.read(magic) == magic.size && magic.contentEquals(MAGIC)) {
                "Ye file encrypted IBTISAAM backup nahi hai"
            }
            val salt = ByteArray(SALT_LEN).also { streamIn.read(it) }
            val iv = ByteArray(IV_LEN).also { streamIn.read(it) }
            val key = deriveKey(password, salt)

            val cipher = Cipher.getInstance("AES/GCM/NoPadding")
            cipher.init(Cipher.DECRYPT_MODE, key, GCMParameterSpec(GCM_TAG_BITS, iv))

            FileOutputStream(output).use { out ->
                val buffer = ByteArray(64 * 1024)
                var read: Int
                while (streamIn.read(buffer).also { read = it } != -1) {
                    val decrypted = cipher.update(buffer, 0, read)
                    if (decrypted != null) out.write(decrypted)
                }
                // Throws AEADBadTagException here if the password is wrong or the
                // file was tampered with/corrupted — caller should catch this.
                val finalBytes = cipher.doFinal()
                if (finalBytes != null) out.write(finalBytes)
            }
        }
    }

    /** Quick check (reads only the header) of whether a file looks like one of our encrypted backups. */
    fun isEncryptedBackup(file: File): Boolean {
        return try {
            FileInputStream(file).use { streamIn ->
                val magic = ByteArray(MAGIC.size)
                streamIn.read(magic) == magic.size && magic.contentEquals(MAGIC)
            }
        } catch (e: Exception) {
            false
        }
    }
}

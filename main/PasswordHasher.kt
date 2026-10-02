package com.grocerypos.v11

import java.security.SecureRandom
import javax.crypto.SecretKeyFactory
import javax.crypto.spec.PBEKeySpec

/**
 * FIX (Phase 4 - Security): User.passwordHash was previously storing (and comparing)
 * plain-text passwords despite its name — e.g. the seeded admin user was literally
 * `passwordHash = "admin123"`, and LoginActivity compared it with `==` against the
 * typed password. This utility replaces that with a salted PBKDF2 hash (120,000
 * rounds, HMAC-SHA256, matches Android's recommended javax.crypto APIs — no new
 * Gradle dependency needed).
 *
 * Stored format: "pbkdf2$<saltHex>$<hashHex>"  (the "pbkdf2$" prefix lets
 * verify() tell a hashed value apart from an old plain-text one so existing
 * installs can be migrated transparently on next successful login — see
 * LoginActivity.verifyAndMaybeMigrate()).
 */
object PasswordHasher {
    private const val PREFIX = "pbkdf2$"
    private const val ITERATIONS = 120_000
    private const val KEY_LENGTH = 256

    fun hash(plainPassword: String): String {
        val salt = ByteArray(16).also { SecureRandom().nextBytes(it) }
        val hash = pbkdf2(plainPassword, salt)
        return PREFIX + salt.toHex() + "$" + hash.toHex()
    }

    /** True if [stored] looks like our "pbkdf2$salt$hash" format (vs. old plain-text). */
    fun isHashed(stored: String): Boolean = stored.startsWith(PREFIX)

    /** Verifies [plainPassword] against a value produced by [hash]. */
    fun verify(plainPassword: String, stored: String): Boolean {
        if (!isHashed(stored)) return false
        val parts = stored.removePrefix(PREFIX).split("$")
        if (parts.size != 2) return false
        val salt = parts[0].hexToBytes()
        val expected = parts[1]
        val actual = pbkdf2(plainPassword, salt).toHex()
        return constantTimeEquals(actual, expected)
    }

    private fun pbkdf2(password: String, salt: ByteArray): ByteArray {
        val spec = PBEKeySpec(password.toCharArray(), salt, ITERATIONS, KEY_LENGTH)
        val factory = SecretKeyFactory.getInstance("PBKDF2WithHmacSHA256")
        return factory.generateSecret(spec).encoded
    }

    private fun constantTimeEquals(a: String, b: String): Boolean {
        if (a.length != b.length) return false
        var result = 0
        for (i in a.indices) result = result or (a[i].code xor b[i].code)
        return result == 0
    }

    private fun ByteArray.toHex(): String = joinToString("") { "%02x".format(it) }
    private fun String.hexToBytes(): ByteArray =
        ByteArray(length / 2) { i -> ((this[i * 2].digitToInt(16) shl 4) + this[i * 2 + 1].digitToInt(16)).toByte() }
}

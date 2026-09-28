package com.grocerypos.v11

import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotEquals
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * Tests for [PasswordHasher] — the login/user-management password hashing used
 * to replace the old plain-text `passwordHash` storage. Covers the properties
 * that actually matter for a login system: correct password verifies, wrong
 * password fails, salts are unique per hash, and old plain-text values are
 * correctly recognised as "not our format" (so LoginActivity's migration path
 * knows to re-hash them instead of comparing them as PBKDF2).
 */
class PasswordHasherTest {

    @Test
    fun `correct password verifies successfully`() {
        val stored = PasswordHasher.hash("MySecret123")
        assertTrue(PasswordHasher.verify("MySecret123", stored))
    }

    @Test
    fun `wrong password fails verification`() {
        val stored = PasswordHasher.hash("MySecret123")
        assertFalse(PasswordHasher.verify("WrongPassword", stored))
    }

    @Test
    fun `verification is case sensitive`() {
        val stored = PasswordHasher.hash("Password1")
        assertFalse(PasswordHasher.verify("password1", stored))
    }

    @Test
    fun `hashing the same password twice yields different output - unique salt`() {
        val first = PasswordHasher.hash("admin123")
        val second = PasswordHasher.hash("admin123")
        assertNotEquals(first, second)
        // But both must still verify correctly against the same plain password.
        assertTrue(PasswordHasher.verify("admin123", first))
        assertTrue(PasswordHasher.verify("admin123", second))
    }

    @Test
    fun `isHashed recognises our pbkdf2 format`() {
        val stored = PasswordHasher.hash("test")
        assertTrue(PasswordHasher.isHashed(stored))
    }

    @Test
    fun `isHashed returns false for legacy plain-text value`() {
        // This is the exact historical bug this class replaced: seeded admin
        // user had passwordHash = "admin123" stored as plain text.
        assertFalse(PasswordHasher.isHashed("admin123"))
    }

    @Test
    fun `verify returns false for a legacy plain-text stored value`() {
        // verify() must never accidentally succeed against an unhashed value —
        // migration (re-hashing) has to happen explicitly in LoginActivity,
        // not via a false-positive here.
        assertFalse(PasswordHasher.verify("admin123", "admin123"))
    }

    @Test
    fun `empty password can still be hashed and verified consistently`() {
        val stored = PasswordHasher.hash("")
        assertTrue(PasswordHasher.verify("", stored))
        assertFalse(PasswordHasher.verify("notempty", stored))
    }
}
